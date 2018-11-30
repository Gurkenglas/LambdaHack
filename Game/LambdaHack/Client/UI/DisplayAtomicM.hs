{-# LANGUAGE TupleSections #-}
-- | Display atomic commands received by the client.
module Game.LambdaHack.Client.UI.DisplayAtomicM
  ( displayRespUpdAtomicUI, displayRespSfxAtomicUI
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , updateItemSlot, markDisplayNeeded, lookAtMove
  , actorVerbMU, aidVerbMU, aidVerbDuplicateMU, itemVerbMU, itemAidVerbMU
  , createActorUI, destroyActorUI, spotItem, moveActor, displaceActorUI
  , moveItemUI, quitFactionUI, displayGameOverLoot, displayGameOverAnalytics
  , discover, ppSfxMsg, strike
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.Char as Char
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import           Data.Key (mapWithKeyM_)
import qualified Data.Ord as Ord
import qualified Data.Text as T
import           Data.Tuple
import           GHC.Exts (inline)
import qualified NLP.Miniutter.English as MU

import           Game.LambdaHack.Atomic
import           Game.LambdaHack.Client.ClientOptions
import           Game.LambdaHack.Client.MonadClient
import           Game.LambdaHack.Client.State
import           Game.LambdaHack.Client.UI.ActorUI
import           Game.LambdaHack.Client.UI.Animation
import           Game.LambdaHack.Client.UI.Content.Screen
import           Game.LambdaHack.Client.UI.ContentClientUI
import           Game.LambdaHack.Client.UI.EffectDescription
import           Game.LambdaHack.Client.UI.FrameM
import           Game.LambdaHack.Client.UI.HandleHelperM
import           Game.LambdaHack.Client.UI.ItemDescription
import           Game.LambdaHack.Client.UI.ItemSlot
import qualified Game.LambdaHack.Client.UI.Key as K
import           Game.LambdaHack.Client.UI.MonadClientUI
import           Game.LambdaHack.Client.UI.Msg
import           Game.LambdaHack.Client.UI.MsgM
import           Game.LambdaHack.Client.UI.Overlay
import           Game.LambdaHack.Client.UI.SessionUI
import           Game.LambdaHack.Client.UI.SlideshowM
import           Game.LambdaHack.Client.UI.UIOptions
import qualified Game.LambdaHack.Common.Ability as Ability
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.Analytics
import qualified Game.LambdaHack.Common.Color as Color
import           Game.LambdaHack.Common.Container
import qualified Game.LambdaHack.Common.Dice as Dice
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Flavour
import           Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Level
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.Point
import           Game.LambdaHack.Common.ReqFailure
import           Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import           Game.LambdaHack.Common.Time
import           Game.LambdaHack.Content.CaveKind (cdesc)
import qualified Game.LambdaHack.Content.ItemKind as IK
import           Game.LambdaHack.Content.ModeKind
import           Game.LambdaHack.Content.RuleKind
import qualified Game.LambdaHack.Content.TileKind as TK

-- * RespUpdAtomicUI

-- | Visualize atomic updates sent to the client. This is done
-- in the global state after the command is executed and after
-- the client state is modified by the command.
-- Don't modify client state (except a few fields), but only client
-- session (e.g., by displaying messages). This is enforced by types.
displayRespUpdAtomicUI :: MonadClientUI m => Bool -> UpdAtomic -> m ()
{-# INLINE displayRespUpdAtomicUI #-}
displayRespUpdAtomicUI verbose cmd = case cmd of
  -- Create/destroy actors and items.
  UpdCreateActor aid body _ -> createActorUI True aid body
  UpdDestroyActor aid body _ -> destroyActorUI True aid body
  UpdCreateItem iid _item kit c -> do
    recordItemLid iid c
    updateItemSlot c iid
    case c of
      CActor aid store ->
        case store of
          COrgan -> do
            arItem <- getsState $ aspectRecordFromIid iid
            if IA.checkFlag Ability.Condition arItem then do
              bag <- getsState $ getContainerBag c
              let more = case EM.lookup iid bag of
                    Nothing -> False
                    Just kit2 -> fst kit2 /= fst kit
                  verb = MU.Text $
                    "become" <+> case fst kit of
                                   1 -> if more then "more" else ""
                                   k -> (if more then "additionally" else "")
                                        <+> tshow k <> "-fold"
              -- This describes all such items already among organs,
              -- which is useful, because it shows "charging".
              itemAidVerbMU aid verb iid (Left Nothing) COrgan
            else do
              ownerFun <- partActorLeaderFun
              let wown = ppContainerWownW ownerFun True c
              itemVerbMU iid kit (MU.Text $ makePhrase $ "grow" : wown) c
          _ -> do
            ownerFun <- partActorLeaderFun
            let wown = ppContainerWownW ownerFun True c
            itemVerbMU iid kit (MU.Text $ makePhrase $ "appear" : wown) c
      CEmbed lid _ -> markDisplayNeeded lid
      CFloor lid _ -> do
        itemVerbMU iid kit (MU.Text $ "appear" <+> ppContainer c) c
        markDisplayNeeded lid
      CTrunk{} -> error $ "" `showFailure` c
    stopPlayBack
  UpdDestroyItem iid _ kit c -> do
    itemVerbMU iid kit "disappear" c
    lid <- getsState $ lidFromC c
    markDisplayNeeded lid
  UpdSpotActor aid body _ -> createActorUI False aid body
  UpdLoseActor aid body _ -> destroyActorUI False aid body
  UpdSpotItem verbose2 iid _ kit c -> spotItem verbose2 iid kit c
  {-
  UpdLoseItem False _ _ _ _ -> return ()
  -- The message is rather cryptic, so let's disable it until it's decided
  -- if anemy inventories should be displayed, etc.
  UpdLoseItem True iid _ kit c@(CActor aid store) | store /= CSha -> do
    -- Actor putting an item into shared stash, most probably.
    side <- getsClient sside
    b <- getsState $ getActorBody aid
    subject <- partActorLeader aid b
    let ownW = ppCStoreWownW store subject
        verb = MU.Text $ makePhrase $ "be removed from" : ownW
    when (bfid b == side) $ itemVerbMU iid kit verb c
  -}
  UpdLoseItem{} -> return ()
  UpdSpotItemBag c bag _ ->
    mapWithKeyM_ (\iid kit -> spotItem True iid kit c) bag
  UpdLoseItemBag{} -> return ()
  -- Move actors and items.
  UpdMoveActor aid source target -> moveActor aid source target
  UpdWaitActor{} -> return ()
  UpdDisplaceActor source target -> displaceActorUI source target
  UpdMoveItem iid k aid c1 c2 -> moveItemUI iid k aid c1 c2
  -- Change actor attributes.
  UpdRefillHP _ 0 -> return ()
  UpdRefillHP aid n -> do
    CCUI{coscreen} <- getsSession sccui
    when verbose $
      aidVerbMU aid $ MU.Text $ (if n > 0 then "heal" else "lose")
                                <+> tshow (abs n `divUp` oneM) <> "HP"
    b <- getsState $ getActorBody aid
    bUI <- getsSession $ getActorUI aid
    arena <- getArenaUI
    side <- getsClient sside
    if | bproj b && (EM.null (beqp b) || isNothing (btrajectory b)) ->
           return ()  -- ignore caught proj or one hitting a wall
       | bhp b <= 0 && n < 0
         && (bfid b == side && not (bproj b) || arena == blid b) -> do
         let (firstFall, hurtExtra) = case (bfid b == side, bproj b) of
               (True, True) -> ("drop down", "tumble down")
               (True, False) -> ("fall down", "fall to pieces")
               (False, True) -> ("plummet", "crash")
               (False, False) -> ("collapse", "be reduced to a bloody pulp")
             verbDie = if alreadyDeadBefore then hurtExtra else firstFall
             alreadyDeadBefore = bhp b - n <= 0
         subject <- partActorLeader aid bUI
         let msgDie = makeSentence [MU.SubjectVerbSg subject verbDie]
         msgAdd msgDie
         -- We show death anims only if not dead already before this refill.
         let deathAct
               | alreadyDeadBefore =
                 twirlSplash coscreen (bpos b, bpos b) Color.Red Color.Red
               | bfid b == side = deathBody coscreen (bpos b)
               | otherwise = shortDeathBody coscreen (bpos b)
         unless (bproj b) $ animate (blid b) deathAct
       | otherwise -> do
         when (n >= bhp b && bhp b > 0) $
           actorVerbMU aid bUI "return from the brink of death"
         mleader <- getsClient sleader
         if Just aid == mleader then do
           actorMaxSk <- getsState $ getActorMaxSkills aid
           -- Regenerating actors never stop gaining HP, so we need to stop
           -- reporting it after they reach full HP for the first time.
           when (bhp b >= xM (Ability.getSk Ability.SkMaxHP actorMaxSk)
                 && bhp b - n < xM (Ability.getSk Ability.SkMaxHP
                                                  actorMaxSk)) $ do
             msgAdd "You recover your health fully."
             stopPlayBack
         else when (bfid b == side) $
           markDisplayNeeded (blid b)
  UpdRefillCalm aid calmDelta -> do
    side <- getsClient sside
    body <- getsState $ getActorBody aid
    when (bfid body == side) $
      if | calmDelta > 0 ->  -- regeneration or effect
           markDisplayNeeded (blid body)
         | calmDelta == minusM1 -> do
           fact <- getsState $ (EM.! side) . sfactionD
           s <- getState
           let closeFoe (!p, aid2) =  -- mimics isHeardFoe
                 let b = getActorBody aid2 s
                 in inline chessDist p (bpos body) <= 3
                    && not (waitedOrSleptLastTurn b)  -- uncommon
                    && inline isFoe side fact (bfid b)  -- costly
               anyCloseFoes = any closeFoe $ EM.assocs $ lbig
                                           $ sdungeon s EM.! blid body
           unless anyCloseFoes $ do  -- obvious where the feeling comes from
             duplicated <- aidVerbDuplicateMU aid "hear something"
             unless duplicated stopPlayBack
         | otherwise ->  -- low deltas from hits; displayed elsewhere
           return ()
  UpdTrajectory _ _ mt ->  -- if projectile dies just after, force one frame
    when (maybe True (null . fst) mt) pushFrame
  -- Change faction attributes.
  UpdQuitFaction fid _ toSt manalytics -> quitFactionUI fid toSt manalytics
  UpdLeadFaction fid (Just source) (Just target) -> do
    fact <- getsState $ (EM.! fid) . sfactionD
    lidV <- viewedLevelUI
    when (isAIFact fact) $ markDisplayNeeded lidV
    -- This faction can't run with multiple actors, so this is not
    -- a leader change while running, but rather server changing
    -- their leader, which the player should be alerted to.
    when (noRunWithMulti fact) stopPlayBack
    actorD <- getsState sactorD
    case EM.lookup source actorD of
      Just sb | bhp sb <= 0 -> assert (not $ bproj sb) $ do
        -- Regardless who the leader is, give proper names here, not 'you'.
        sbUI <- getsSession $ getActorUI source
        tbUI <- getsSession $ getActorUI target
        let subject = partActor tbUI
            object  = partActor sbUI
        msgAdd $ makeSentence [ MU.SubjectVerbSg subject "take command"
                              , "from", object ]
      _ -> return ()
    lookAtMove target
  UpdLeadFaction _ Nothing (Just target) -> lookAtMove target
  UpdLeadFaction{} -> return ()
  UpdDiplFaction fid1 fid2 _ toDipl -> do
    name1 <- getsState $ gname . (EM.! fid1) . sfactionD
    name2 <- getsState $ gname . (EM.! fid2) . sfactionD
    let showDipl Unknown = "unknown to each other"
        showDipl Neutral = "in neutral diplomatic relations"
        showDipl Alliance = "allied"
        showDipl War = "at war"
    msgAdd $ name1 <+> "and" <+> name2 <+> "are now" <+> showDipl toDipl <> "."
  UpdTacticFaction{} -> return ()
  UpdAutoFaction fid b -> do
    side <- getsClient sside
    lidV <- viewedLevelUI
    markDisplayNeeded lidV
    when (fid == side) $ setFrontAutoYes b
  UpdRecordKill{} -> return ()
  -- Alter map.
  UpdAlterTile lid p fromTile toTile -> do
    markDisplayNeeded lid
    COps{cotile} <- getsState scops
    let feats = TK.tfeature $ okind cotile fromTile
        toAlter feat =
          case feat of
            TK.OpenTo tgroup -> Just tgroup
            TK.CloseTo tgroup -> Just tgroup
            TK.ChangeTo tgroup -> Just tgroup
            _ -> Nothing
        groupsToAlterTo = mapMaybe toAlter feats
        freq = map fst $ filter (\(_, q) -> q > 0)
               $ TK.tfreq $ okind cotile toTile
    when (null $ intersect freq groupsToAlterTo) $ do
      -- Player notices @fromTile can't be altered into @toTIle@,
      -- which is uncanny, so we produce a message.
      -- This happens when the player missed an earlier search of the tile
      -- performed by another faction.
      let subject = ""  -- a hack, we we don't handle adverbs well
          verb = "turn into"
          msg = makeSentence
            [ "the", MU.Text $ TK.tname $ okind cotile fromTile
            , "at position", MU.Text $ tshow p
            , "suddenly"  -- adverb
            , MU.SubjectVerbSg subject verb
            , MU.AW $ MU.Text $ TK.tname $ okind cotile toTile ]
      msgAdd msg
  UpdAlterExplorable lid _ -> markDisplayNeeded lid
  UpdAlterGold{} -> return ()  -- not displayed on HUD
  UpdSearchTile aid _p toTile -> do
    COps{cotile} <- getsState scops
    subject <- partAidLeader aid
    let fromTile = fromJust $ Tile.hideAs cotile toTile
        subject2 = MU.Text $ TK.tname $ okind cotile fromTile
        object = MU.Text $ TK.tname $ okind cotile toTile
    let msg = makeSentence [ MU.SubjectVerbSg subject "reveal"
                           , "that the"
                           , MU.SubjectVerbSg subject2 "be"
                           , MU.AW object ]
    unless (subject2 == object) $ msgAdd msg
  UpdHideTile{} -> return ()
  UpdSpotTile{} -> return ()
  UpdLoseTile{} -> return ()
  UpdSpotEntry{} -> return ()
  UpdLoseEntry{} -> return ()
  UpdAlterSmell{} -> return ()
  UpdSpotSmell{} -> return ()
  UpdLoseSmell{} -> return ()
  -- Assorted.
  UpdTimeItem{} -> return ()
  UpdAgeGame{} -> do
    sdisplayNeeded <- getsSession sdisplayNeeded
    time <- getsState stime
    let clipN = time `timeFit` timeClip
        clipInTurn = let r = timeTurn `timeFit` timeClip
                     in assert (r >= 5) r
        clipMod = clipN `mod` clipInTurn
        ping = clipMod == 0
    when (sdisplayNeeded || ping) pushFrame
  UpdUnAgeGame{} -> return ()
  UpdDiscover c iid _ _ -> discover c iid
  UpdCover{} -> return ()  -- don't spam when doing undo
  UpdDiscoverKind{} -> return ()  -- don't spam when server tweaks stuff
  UpdCoverKind{} -> return ()  -- don't spam when doing undo
  UpdDiscoverAspect{} -> return ()  -- don't spam when server tweaks stuff
  UpdCoverAspect{} -> return ()  -- don't spam when doing undo
  UpdDiscoverServer{} -> error "server command leaked to client"
  UpdCoverServer{} -> error "server command leaked to client"
  UpdPerception{} -> return ()
  UpdRestart fid _ _ _ _ -> do
    COps{cocave, corule} <- getsState scops
    sstart <- getsSession sstart
    when (sstart == 0) resetSessionStart
    history <- getsSession shistory
    if lengthHistory history == 0 then do
      let title = rtitle corule
      msgAdd $ "Welcome to" <+> title <> "!"
      -- Generate initial history. Only for UI clients.
      sUIOptions <- getsSession sUIOptions
      shistory <- defaultHistory $ uHistoryMax sUIOptions
      modifySession $ \sess -> sess {shistory}
    else
      recordHistory
    lid <- getArenaUI
    lvl <- getLevel lid
    mode <- getGameMode
    curChal <- getsClient scurChal
    fact <- getsState $ (EM.! fid) . sfactionD
    let loneMode = case ginitial fact of
          [] -> True
          [(_, 1, _)] -> True
          _ -> False
    msgAdd $ "New game started in" <+> mname mode <+> "mode."
             <+> mdesc mode <+> cdesc (okind cocave $ lkind lvl)
             <+> if cwolf curChal && not loneMode
                 then "Being a lone wolf, you start without companions."
                 else ""
    when (lengthHistory history > 1) $ fadeOutOrIn False
    setFrontAutoYes $ isAIFact fact
    when (isAIFact fact) $ do
      -- Prod the frontend to flush frames and start showing them continuously.
      slides <- reportToSlideshow []
      void $ getConfirms ColorFull [K.spaceKM, K.escKM] slides
  UpdRestartServer{} -> return ()
  UpdResume fid _ -> do
    COps{cocave} <- getsState scops
    resetSessionStart
    fact <- getsState $ (EM.! fid) . sfactionD
    setFrontAutoYes $ isAIFact fact
    unless (isAIFact fact) $ do
      lid <- getArenaUI
      lvl <- getLevel lid
      mode <- getGameMode
      promptAdd0 $ "Continuing" <+> mname mode <> "."
                   <+> mdesc mode <+> cdesc (okind cocave $ lkind lvl)
                   <+> "Are you up for the challenge?"
      slides <- reportToSlideshow [K.spaceKM, K.escKM]
      km <- getConfirms ColorFull [K.spaceKM, K.escKM] slides
      if km == K.escKM
      then addPressedControlEsc
      else promptAdd0 "Prove yourself!"
  UpdResumeServer{} -> return ()
  UpdKillExit{} -> frontendShutdown
  UpdWriteSave -> when verbose $ promptAdd1 "Saving backup."
  UpdHearFid _ hearMsg -> do
    mleader <- getsClient sleader
    case mleader of
      Just{} -> return ()  -- will display stuff when leader moves
      Nothing -> do
        lidV <- viewedLevelUI
        markDisplayNeeded lidV
        recordHistory
    msg <- ppHearMsg hearMsg
    msgAdd msg

updateItemSlot :: MonadClientUI m => Container -> ItemId -> m ()
updateItemSlot c iid = do
  arItem <- getsState $ aspectRecordFromIid iid
  let slore = IA.loreFromContainer arItem c
      incrementPrefix l2 iid2 m = EM.insert l2 iid2 $
        case EM.lookup l2 m of
          Nothing -> m
          Just iidOld ->
            let lNew = SlotChar (slotPrefix l2 + 1) (slotChar l2)
            in incrementPrefix lNew iidOld m
  slots@(ItemSlots itemSlots) <- getsSession sslots
  case lookup iid $ map swap $ EM.assocs $ itemSlots EM.! slore of
    Nothing -> do
      side <- getsClient sside
      mbody <- case c of
        CActor aid _ -> do
          b <- getsState $ getActorBody aid
          return $! if bfid b == side then Just b else Nothing
        _ -> return Nothing
      partySet <- getsState $ partyItemSet slore side mbody
      let l = assignSlot partySet slore slots
          newSlots =
            ItemSlots $ EM.adjust (incrementPrefix l iid) slore itemSlots
      modifySession $ \sess -> sess {sslots = newSlots}
    Just _l -> return ()  -- slot already assigned

markDisplayNeeded :: MonadClientUI m => LevelId -> m ()
markDisplayNeeded lid = do
  lidV <- viewedLevelUI
  when (lidV == lid) $ modifySession $ \sess -> sess {sdisplayNeeded = True}

lookAtMove :: MonadClientUI m => ActorId -> m ()
lookAtMove aid = do
  body <- getsState $ getActorBody aid
  side <- getsClient sside
  aimMode <- getsSession saimMode
  when (not (bproj body)
        && bfid body == side
        && isNothing aimMode) $ do  -- aiming does a more extensive look
    itemsBlurb <- lookAtItems True (bpos body) aid
    msgAdd itemsBlurb
  fact <- getsState $ (EM.! bfid body) . sfactionD
  adjBigAssocs <- getsState $ adjacentBigAssocs body
  adjProjAssocs <- getsState $ adjacentProjAssocs body
  if not (bproj body) && bfid body == side then do
    let foe (_, b2) = isFoe (bfid body) fact (bfid b2)
        adjFoes = filter foe $ adjBigAssocs ++ adjProjAssocs
    unless (null adjFoes) stopPlayBack
  else when (isFoe (bfid body) fact side) $ do
    let our (_, b2) = bfid b2 == side
        adjOur = filter our adjBigAssocs
    unless (null adjOur) stopPlayBack

actorVerbMU :: MonadClientUI m => ActorId -> ActorUI -> MU.Part -> m ()
actorVerbMU aid bUI verb = do
  subject <- partActorLeader aid bUI
  msgAdd $ makeSentence [MU.SubjectVerbSg subject verb]

aidVerbMU :: MonadClientUI m => ActorId -> MU.Part -> m ()
aidVerbMU aid verb = do
  bUI <- getsSession $ getActorUI aid
  actorVerbMU aid bUI verb

aidVerbDuplicateMU :: MonadClientUI m => ActorId -> MU.Part -> m Bool
aidVerbDuplicateMU aid verb = do
  bUI <- getsSession $ getActorUI aid
  subject <- partActorLeader aid bUI
  msgAddDuplicate $ makeSentence [MU.SubjectVerbSg subject verb]

itemVerbMU :: MonadClientUI m
           => ItemId -> ItemQuant -> MU.Part -> Container -> m ()
itemVerbMU iid kit@(k, _) verb c = assert (k > 0) $ do
  lid <- getsState $ lidFromC c
  localTime <- getsState $ getLocalTime lid
  itemFull <- getsState $ itemToFull iid
  side <- getsClient sside
  factionD <- getsState sfactionD
  let arItem = aspectRecordFull itemFull
      subject = partItemWs side factionD k localTime itemFull kit
      msg | k > 1 && not (IA.checkFlag Ability.Condition arItem) =
              makeSentence [MU.SubjectVerb MU.PlEtc MU.Yes subject verb]
          | otherwise = makeSentence [MU.SubjectVerbSg subject verb]
  msgAdd msg

-- We assume the item is inside the specified container.
-- So, this function can't be used for, e.g., @UpdDestroyItem@.
itemAidVerbMU :: MonadClientUI m
              => ActorId -> MU.Part
              -> ItemId -> Either (Maybe Int) Int -> CStore
              -> m ()
itemAidVerbMU aid verb iid ek cstore = do
  body <- getsState $ getActorBody aid
  bag <- getsState $ getBodyStoreBag body cstore
  side <- getsClient sside
  factionD <- getsState sfactionD
  -- The item may no longer be in @c@, but it was
  case iid `EM.lookup` bag of
    Nothing -> error $ "" `showFailure` (aid, verb, iid, cstore)
    Just kit@(k, _) -> do
      itemFull <- getsState $ itemToFull iid
      let lid = blid body
      localTime <- getsState $ getLocalTime lid
      subject <- partAidLeader aid
      let object = case ek of
            Left (Just n) ->
              assert (n <= k `blame` (aid, verb, iid, cstore))
              $ partItemWs side factionD n localTime itemFull kit
            Left Nothing ->
              let (name, powers) =
                    partItem side factionD localTime itemFull kit
              in MU.Phrase [name, powers]
            Right n ->
              assert (n <= k `blame` (aid, verb, iid, cstore))
              $ let (name1, powers) =
                      partItemShort side factionD localTime itemFull kit
                    name = if n == 1 then name1 else MU.CarWs n name1
                in MU.Phrase ["the", name, powers]
          msg = makeSentence [MU.SubjectVerbSg subject verb, object]
      msgAdd msg

createActorUI :: MonadClientUI m => Bool -> ActorId -> Actor -> m ()
createActorUI born aid body = do
  CCUI{coscreen} <- getsSession sccui
  side <- getsClient sside
  factionD <- getsState sfactionD
  let fact = factionD EM.! bfid body
  globalTime <- getsState stime
  localTime <- getsState $ getLocalTime $ blid body
  itemFull@ItemFull{itemBase, itemKind} <- getsState $ itemToFull (btrunk body)
  let arItem = aspectRecordFull itemFull
  mbUI <- getsSession $ EM.lookup aid . sactorUI
  bUI <- case mbUI of
    Just bUI -> return bUI
    Nothing -> do
      UIOptions{uHeroNames} <- getsSession sUIOptions
      let baseColor = flavourToColor $ jflavour itemBase
          basePronoun | not (bproj body)
                        && IK.isymbol itemKind == '@'
                        && fhasGender (gplayer fact) = "he"
                      | otherwise = "it"
          nameFromNumber fn k = if k == 0
                                then makePhrase [MU.Ws $ MU.Text fn, "Captain"]
                                else fn <+> tshow k
          heroNamePronoun k =
            if gcolor fact /= Color.BrWhite
            then (nameFromNumber (fname $ gplayer fact) k, "he")
            else fromMaybe (nameFromNumber (fname $ gplayer fact) k, "he")
                 $ lookup k uHeroNames
      (n, bsymbol) <-
        if | bproj body -> return (0, if IA.checkFlag Ability.Blast arItem
                                      then IK.isymbol itemKind
                                      else '*')
           | baseColor /= Color.BrWhite -> return (0, IK.isymbol itemKind)
           | otherwise -> do
             sactorUI <- getsSession sactorUI
             let hasNameK k bUI = bname bUI == fst (heroNamePronoun k)
                                  && bcolor bUI == gcolor fact
                 findHeroK k = isJust $ find (hasNameK k) (EM.elems sactorUI)
                 mhs = map findHeroK [0..]
                 n = fromJust $ elemIndex False mhs
             return (n, if 0 < n && n < 10 then Char.intToDigit n else '@')
      let (bname, bpronoun) =
            if | bproj body ->
                 let adj = case btrajectory body of
                       Just (tra, _) | length tra < 5 -> "falling"
                       _ -> "flying"
                     -- Not much detail about a fast flying item.
                     (object1, object2) =
                       partItemActor (bfid body) factionD localTime
                                     itemFull (1, [])
                 in (makePhrase [adj, object1, object2], basePronoun)
               | baseColor /= Color.BrWhite ->
                 let the | IA.checkFlag Ability.Unique arItem = "the"
                         | otherwise = ""
                 in (the <+> IK.iname itemKind, basePronoun)
               | otherwise -> heroNamePronoun n
          bcolor | bproj body = if IA.checkFlag Ability.Blast arItem
                                then baseColor
                                else Color.BrWhite
                 | baseColor == Color.BrWhite = gcolor fact
                 | otherwise = baseColor
          bUI = ActorUI{..}
      modifySession $ \sess ->
        sess {sactorUI = EM.insert aid bUI $ sactorUI sess}
      return bUI
  let verb = MU.Text $
        if born
        then if globalTime == timeZero
             then "be here"
             else "appear" <+> if bfid body == side then "" else "suddenly"
        else "be spotted"
  mapM_ (\(iid, store) -> do
           let c = if not (bproj body) && iid == btrunk body
                   then CTrunk (bfid body) (blid body) (bpos body)
                   else CActor aid store
           void $ updateItemSlot c iid
           recordItemLid iid c)
        ((btrunk body, CEqp)  -- store will be overwritten, unless projectile
         : filter ((/= btrunk body) . fst) (getCarriedIidCStore body))
  when (bfid body /= side) $ do
    when (not (bproj body) && isFoe (bfid body) fact side) $
      -- Aim even if nobody can shoot at the enemy. Let's home in on him
      -- and then we can aim or melee. We set permit to False, because it's
      -- technically very hard to check aimability here, because we are
      -- in-between turns and, e.g., leader's move has not yet been taken
      -- into account.
      modifySession $ \sess -> sess {sxhair = TEnemy aid}
    stopPlayBack
  -- Don't spam if the actor was already visible (but, e.g., on a tile that is
  -- invisible this turn (in that case move is broken down to lose+spot)
  -- or on a distant tile, via teleport while the observer teleported, too).
  lastLost <- getsSession slastLost
  if ES.member aid lastLost || bproj body then
    markDisplayNeeded (blid body)
  else do
    actorVerbMU aid bUI verb
    animate (blid body) $ actorX coscreen (bpos body)

destroyActorUI :: MonadClientUI m => Bool -> ActorId -> Actor -> m ()
destroyActorUI destroy aid b = do
  trunk <- getsState $ getItemBody $ btrunk b
  let baseColor = flavourToColor $ jflavour trunk
  unless (baseColor == Color.BrWhite) $  -- keep setup for heroes, etc.
    modifySession $ \sess -> sess {sactorUI = EM.delete aid $ sactorUI sess}
  let affect tgt = case tgt of
        TEnemy a | a == aid ->
          if destroy then
            -- If *really* nothing more interesting, the actor will
            -- go to last known location to perhaps find other foes.
            TPoint TAny (blid b) (bpos b)
          else
            -- If enemy only hides (or we stepped behind obstacle) find him.
            TPoint (TEnemyPos a) (blid b) (bpos b)
        _ -> tgt
  modifySession $ \sess -> sess {sxhair = affect $ sxhair sess}
  unless (bproj b) $
    modifySession $ \sess -> sess {slastLost = ES.insert aid $ slastLost sess}
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  let gameOver = isJust $ gquit fact  -- we are the UI faction, so we determine
  unless gameOver $ do
    when (bfid b == side && not (bproj b)) $ do
      stopPlayBack
      let upd = ES.delete aid
      modifySession $ \sess -> sess {sselected = upd $ sselected sess}
      when destroy $ do
        displayMore ColorBW "Alas!"
        mleader <- getsClient sleader
        when (isJust mleader)
          -- This is especially handy when the dead actor was a leader
          -- on a different level than the new one:
          clearAimMode
    -- If pushed, animate spotting again, to draw attention to pushing.
    markDisplayNeeded (blid b)

spotItem :: MonadClientUI m
         => Bool -> ItemId -> ItemQuant -> Container -> m ()
spotItem verbose iid kit c = do
  -- This is due to a move, or similar, which will be displayed,
  -- so no extra @markDisplayNeeded@ needed here and in similar places.
  recordItemLid iid c
  ItemSlots itemSlots <- getsSession sslots
  arItem <- getsState $ aspectRecordFromIid iid
  let slore = IA.loreFromContainer arItem c
  case lookup iid $ map swap $ EM.assocs $ itemSlots EM.! slore of
    Nothing -> do  -- never seen or would have a slot
      void $ updateItemSlot c iid
      case c of
        CFloor lid p -> do
          sxhairOld <- getsSession sxhair
          case sxhairOld of
            TEnemy{} -> return ()  -- probably too important to overwrite
            TPoint TEnemyPos{} _ _ -> return ()
            _ -> do
              -- Don't steal xhair if it's only an item on another level.
              -- For enemies, OTOH, capture xhair to alarm player.
              lidV <- viewedLevelUI
              when (lid == lidV) $ do
                bag <- getsState $ getFloorBag lid p
                modifySession $ \sess ->
                  sess {sxhair = TPoint (TItem bag) lidV p}
          itemVerbMU iid kit "be located" c
          stopPlayBack
        _ -> return ()
    _ -> return ()  -- this item or another with the same @iid@
                    -- seen already (has a slot assigned), so old news
  when verbose $ case c of
    CActor aid store | store `elem` [CEqp, CInv, CGround, CSha] -> do
      -- Actor fetching an item from or to shared stash, most probably.
      bUI <- getsSession $ getActorUI aid
      subject <- partActorLeader aid bUI
      let ownW = ppCStoreWownW False store subject
          verb = MU.Text $ makePhrase $ "be added to" : ownW
      itemVerbMU iid kit verb c
    _ -> return ()

recordItemLid :: MonadClientUI m => ItemId -> Container -> m ()
recordItemLid iid c = do
  mjlid <- getsSession $ EM.lookup iid . sitemUI
  when (isNothing mjlid) $ do
    lid <- getsState $ lidFromC c
    modifySession $ \sess ->
      sess {sitemUI = EM.insert iid lid $ sitemUI sess}

moveActor :: MonadClientUI m => ActorId -> Point -> Point -> m ()
moveActor aid source target = do
  -- If source and target tile distant, assume it's a teleportation
  -- and display an animation. Note: jumps and pushes go through all
  -- intervening tiles, so won't be considered. Note: if source or target
  -- not seen, the (half of the) animation would be boring, just a delay,
  -- not really showing a transition, so we skip it (via 'breakUpdAtomic').
  -- The message about teleportation is sometimes shown anyway, just as the X.
  CCUI{coscreen} <- getsSession sccui
  body <- getsState $ getActorBody aid
  if adjacent source target
  then markDisplayNeeded (blid body)
  else do
    let ps = (source, target)
    animate (blid body) $ teleport coscreen ps
  lookAtMove aid

displaceActorUI :: MonadClientUI m => ActorId -> ActorId -> m ()
displaceActorUI source target = do
  CCUI{coscreen} <- getsSession sccui
  sb <- getsState $ getActorBody source
  sbUI <- getsSession $ getActorUI source
  tb <- getsState $ getActorBody target
  tbUI <- getsSession $ getActorUI target
  spart <- partActorLeader source sbUI
  tpart <- partActorLeader target tbUI
  let msg = makeSentence [MU.SubjectVerbSg spart "displace", tpart]
  msgAdd msg
  when (bfid sb /= bfid tb) $ do
    lookAtMove source
    lookAtMove target
  mleader <- getsClient sleader
  side <- getsClient sside
  -- Ours involved, but definitely not requested by player via UI.
  when (side `elem` [bfid sb, bfid tb] && mleader /= Just source) stopPlayBack
  let ps = (bpos tb, bpos sb)
  animate (blid sb) $ swapPlaces coscreen ps

moveItemUI :: MonadClientUI m
           => ItemId -> Int -> ActorId -> CStore -> CStore
           -> m ()
moveItemUI iid k aid cstore1 cstore2 = do
  let verb = verbCStore cstore2
  b <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid b) . sfactionD
  let underAI = isAIFact fact
  mleader <- getsClient sleader
  ItemSlots itemSlots <- getsSession sslots
  case lookup iid $ map swap $ EM.assocs $ itemSlots EM.! SItem of
    Just _l ->
      -- So far organs can't be put into backpack, so no need to call
      -- @updateItemSlot@ to add or reassign lore category.
      if cstore1 == CGround && Just aid == mleader && not underAI then
        itemAidVerbMU aid (MU.Text verb) iid (Right k) cstore2
      else when (not (bproj b) && bhp b > 0) $  -- don't announce death drops
        itemAidVerbMU aid (MU.Text verb) iid (Left $ Just k) cstore2
    Nothing -> error $
      "" `showFailure` (iid, k, aid, cstore1, cstore2)

quitFactionUI :: MonadClientUI m
              => FactionId -> Maybe Status
              -> Maybe (FactionAnalytics, GenerationAnalytics)
              -> m ()
quitFactionUI fid toSt manalytics = do
  ClientOptions{sexposeItems} <- getsClient soptions
  fact <- getsState $ (EM.! fid) . sfactionD
  let fidName = MU.Text $ gname fact
      person = if fhasGender $ gplayer fact then MU.PlEtc else MU.Sg3rd
      horror = isHorrorFact fact
  side <- getsClient sside
  when (side == fid && maybe False ((/= Camping) . stOutcome) toSt) $ do
    tellGameClipPS
    resetGameStart
  let msgIfSide _ | fid /= side = Nothing
      msgIfSide s = Just s
      (startingPart, partingPart) = case toSt of
        _ | horror ->
          -- Ignore summoned actors' factions.
          (Nothing, Nothing)
        Just Status{stOutcome=Killed} ->
          ( Just "be eliminated"
          , msgIfSide "Let's hope another party can save the day!" )
        Just Status{stOutcome=Defeated} ->
          ( Just "be decisively defeated"
          , msgIfSide "Let's hope your new overlords let you live." )
        Just Status{stOutcome=Camping} ->
          ( Just "order save and exit"
          , Just $ if fid == side
                   then "See you soon, stronger and braver!"
                   else "See you soon, stalwart warrior!" )
        Just Status{stOutcome=Conquer} ->
          ( Just "vanquish all foes"
          , msgIfSide "Can it be done in a better style, though?" )
        Just Status{stOutcome=Escape} ->
          ( Just "achieve victory"
          , msgIfSide "Can it be done better, though?" )
        Just Status{stOutcome=Restart, stNewGame=Just gn} ->
          ( Just $ MU.Text $ "order mission restart in"
                             <+> fromGroupName gn <+> "mode"
          , Just $ if fid == side
                   then "This time for real."
                   else "Somebody couldn't stand the heat." )
        Just Status{stOutcome=Restart, stNewGame=Nothing} ->
          error $ "" `showFailure` (fid, toSt)
        Nothing -> (Nothing, Nothing)  -- server wipes out Camping for savefile
  case startingPart of
    Nothing -> return ()
    Just sp -> msgAdd $ makeSentence [MU.SubjectVerb person MU.Yes fidName sp]
  case (toSt, partingPart) of
    (Just status, Just pp) -> do
      isNoConfirms <- isNoConfirmsGame
      go <- if isNoConfirms && fmap stOutcome toSt /= Just Camping
            then return False
            else do
              void $ displaySpaceEsc ColorFull ""
              return True
      when (side == fid) recordHistory
        -- we are going to exit or restart, so record and clear, but only once
      when go $ do
        (itemBag, total) <- getsState $ calculateTotal side
        case manalytics of
          Nothing -> return ()
          Just (factionAn, generationAn) -> do
            cycleLore []
              [ displayGameOverLoot (itemBag, total) generationAn
              , displayGameOverAnalytics factionAn generationAn
              , displayGameOverLore SEmbed True generationAn
              , displayGameOverLore SOrgan True generationAn
              , displayGameOverLore STmp sexposeItems generationAn
              , displayGameOverLore SBlast True generationAn ]
        unless isNoConfirms $ do
          -- Show score for any UI client after any kind of game exit,
          -- even though it's saved only for human UI clients at game over
          -- (that is not a noConfirms or benchmark game).
          scoreSlides <- scoreToSlideshow total status
          void $ getConfirms ColorFull [K.spaceKM, K.escKM] scoreSlides
        -- The last prompt stays onscreen during shutdown, etc.
        promptAdd0 pp
        partingSlide <- reportToSlideshow [K.spaceKM, K.escKM]
        void $ getConfirms ColorFull [K.spaceKM, K.escKM] partingSlide
      unless (fmap stOutcome toSt == Just Camping) $
        fadeOutOrIn True
    _ -> return ()

displayGameOverLoot :: MonadClientUI m
                    => (ItemBag, Int) -> GenerationAnalytics -> m K.KM
displayGameOverLoot (heldBag, total) generationAn = do
  ClientOptions{sexposeItems} <- getsClient soptions
  COps{coitem} <- getsState scops
  ItemSlots itemSlots <- getsSession sslots
  let currencyName = IK.iname $ okind coitem $ ouniqGroup coitem "currency"
      lSlotsRaw = EM.filter (`EM.member` heldBag) $ itemSlots EM.! SItem
      generationItem = generationAn EM.! SItem
      (itemBag, lSlots) =
        if sexposeItems
        then let generationBag = EM.map (\k -> (-k, [])) generationItem
                 bag = heldBag `EM.union` generationBag
                 slots = EM.fromAscList $ zip allSlots $ EM.keys bag
             in (bag, slots)
        else (heldBag, lSlotsRaw)
      promptFun iid itemFull2 k =
        let worth = itemPrice 1 $ itemKind itemFull2
            lootMsg = if worth == 0 then "" else
              makeSentence $
                ["this treasure specimen is worth"]
                ++ (if k > 1 then [ MU.Cardinal k, "times"] else [])
                ++ [MU.CarWs worth $ MU.Text currencyName]
            holdsMsg =
              let n = generationItem EM.! iid
              in makePhrase
                   [ "You hold"
                   , MU.CarWs (max 0 k) "piece out of"
                   , MU.Cardinal n
                   , "scattered:" ]
        in lootMsg <+> holdsMsg
  dungeonTotal <- getsState sgold
  let promptGold = spoilsBlurb currencyName total dungeonTotal
      prompt = promptGold
               <+> (if sexposeItems
                    then "Non-positive count means none held but this many generated."
                    else "")
      examItem = displayItemLore itemBag 0 promptFun
  viewLoreItems False "GameOverLoot" lSlots itemBag prompt examItem

displayGameOverAnalytics :: MonadClientUI m
                         => FactionAnalytics -> GenerationAnalytics
                         -> m K.KM
displayGameOverAnalytics factionAn generationAn = do
  ClientOptions{sexposeActors} <- getsClient soptions
  side <- getsClient sside
  ItemSlots itemSlots <- getsSession sslots
  let ourAn = akillCounts
              $ EM.findWithDefault emptyAnalytics side factionAn
      foesAn = EM.unionsWith (+)
               $ concatMap EM.elems $ catMaybes
               $ map (`EM.lookup` ourAn) [KillKineticMelee .. KillOtherPush]
      trunkBagRaw = EM.map (, []) foesAn
      lSlotsRaw = EM.filter (`EM.member` trunkBagRaw) $ itemSlots EM.! STrunk
      killedBag = EM.fromList $ map (\iid -> (iid, trunkBagRaw EM.! iid))
                                    (EM.elems lSlotsRaw)
      generationTrunk = generationAn EM.! STrunk
      (trunkBag, lSlots) =
        if sexposeActors
        then let generationBag = EM.map (\k -> (-k, [])) generationTrunk
                 bag = killedBag `EM.union` generationBag
                 slots = EM.fromAscList $ zip allSlots $ EM.keys bag
             in (bag, slots)
        else (killedBag, lSlotsRaw)
      promptFun :: ItemId -> ItemFull-> Int -> Text
      promptFun iid _ k =
        let n = generationTrunk EM.! iid
        in "You recall the adversary, which you killed"
           <+> tshow (max 0 k) <+> "out of"
           <+> tshow n <+> "reported:"
      prompt = "Your team vanquished the following adversaries."
               <+> (if sexposeActors
                    then "Non-positive count means none killed but this many reported."
                    else "")
      examItem = displayItemLore trunkBag 0 promptFun
  viewLoreItems False "GameOverAnalytics" lSlots trunkBag prompt examItem

displayGameOverLore :: MonadClientUI m
                    => SLore -> Bool -> GenerationAnalytics -> m K.KM
displayGameOverLore slore exposeCount generationAn = do
  let generationLore = generationAn EM.! slore
      generationBag = EM.map (\k -> (if exposeCount then k else 1, []))
                             generationLore
      slots = EM.fromAscList $ zip allSlots $ EM.keys generationBag
      promptFun :: ItemId -> ItemFull-> Int -> Text
      promptFun _ _ k =
        makeSentence
          [ "this", MU.Text (ppSLore slore), "manifested during your quest"
          , if k /= 1 then MU.CarWs k "time" else "one time" ]
      prompt = makeSentence [ "you experienced the following variety of"
                            , MU.Ws $ MU.Text (headingSLore slore) ]
      examItem = displayItemLore generationBag 0 promptFun
  viewLoreItems False ("GameOverLore" ++ show slore)
                slots generationBag prompt examItem

discover :: MonadClientUI m => Container -> ItemId -> m ()
discover c iid = do
  COps{coitem} <- getsState scops
  lid <- getsState $ lidFromC c
  globalTime <- getsState stime
  localTime <- getsState $ getLocalTime lid
  itemFull <- getsState $ itemToFull iid
  bag <- getsState $ getContainerBag c
  side <- getsClient sside
  factionD <- getsState sfactionD
  (isOurOrgan, nameWhere) <- case c of
    CActor aidOwner storeOwner -> do
      bOwner <- getsState $ getActorBody aidOwner
      bOwnerUI <- getsSession $ getActorUI aidOwner
      let name = if bproj bOwner || bfid bOwner == side
                 then []
                 else ppCStoreWownW True storeOwner (partActor bOwnerUI)
      return (bfid bOwner == side && storeOwner == COrgan, name)
    _ -> return (False, [])
  let kit = EM.findWithDefault (1, []) iid bag
      knownName = partItemMediumAW side factionD localTime itemFull kit
      -- Make sure the two names in the message differ.
      name = IK.iname $ okind coitem $ case jkind $ itemBase itemFull of
        IdentityObvious ik -> ik
        IdentityCovered _ix ik -> ik  -- fake kind; we talk about appearances
      flav = flavourToName $ jflavour $ itemBase itemFull
      unknownName = MU.Phrase $ [MU.Text flav, MU.Text name] ++ nameWhere
      msg = makeSentence
        ["the", MU.SubjectVerbSg unknownName "turn out to be", knownName]
  unless (globalTime == timeZero  -- don't spam about initial equipment
          || isOurOrgan) $  -- assume own faction organs known intuitively
    msgAdd msg

ppHearMsg :: MonadClientUI m => HearMsg -> m Text
ppHearMsg hearMsg = case hearMsg of
  HearUpd local cmd -> do
    COps{coTileSpeedup} <- getsState scops
    let sound = case cmd of
          UpdDestroyActor{} -> "shriek"
          UpdCreateItem{} -> "clatter"
          UpdTrajectory{} -> "thud"  -- Something hits a non-walkable tile.
          UpdAlterTile _ _ _ toTile -> if Tile.isDoor coTileSpeedup toTile
                                       then "creaking sound"
                                       else "rumble"
          UpdAlterExplorable _ k -> if k > 0 then "grinding noise"
                                             else "fizzing noise"
          _ -> error $ "" `showFailure` cmd
        distant = if local then [] else ["distant"]
        msg = makeSentence [ "you hear"
                           , MU.AW $ MU.Phrase $ distant ++ [sound] ]
    return $! msg
  HearStrike ik -> do
    COps{coitem} <- getsState scops
    let verb = IK.iverbHit $ okind coitem ik
        msg = makeSentence [ "you hear something", MU.Text verb, "someone"]
    return $! msg
  HearSummon isProj grp p -> do
    let verb = if isProj then "something lure" else "somebody summon"
        object = if p == 1  -- works, because exact number sent, not dice
                 then MU.Text $ fromGroupName grp
                 else MU.Ws $ MU.Text $ fromGroupName grp
    return $! makeSentence ["you hear", verb, object]
  HearTaunt t ->
    return $! makeSentence ["you overhear", MU.Text t]

-- * RespSfxAtomicUI

-- | Display special effects (text, animation) sent to the client.
-- Don't modify client state (except a few fields), but only client
-- session (e.g., by displaying messages). This is enforced by types.
displayRespSfxAtomicUI :: MonadClientUI m => SfxAtomic -> m ()
{-# INLINE displayRespSfxAtomicUI #-}
displayRespSfxAtomicUI sfx = case sfx of
  SfxStrike source target iid store ->
    strike False source target iid store
  SfxRecoil source target _ _ -> do
    spart <- partAidLeader source
    tpart <- partAidLeader target
    msgAdd $ makeSentence [MU.SubjectVerbSg spart "shrink away from", tpart]
  SfxSteal source target iid store ->
    strike True source target iid store
  SfxRelease source target _ _ -> do
    spart <- partAidLeader source
    tpart <- partAidLeader target
    msgAdd $ makeSentence [MU.SubjectVerbSg spart "release", tpart]
  SfxProject aid iid cstore ->
    itemAidVerbMU aid "fling" iid (Left $ Just 1) cstore
  SfxReceive aid iid cstore ->
    itemAidVerbMU aid "receive" iid (Left $ Just 1) cstore
  SfxApply aid iid cstore -> do
    CCUI{coscreen=ScreenContent{rapplyVerbMap}} <- getsSession sccui
    ItemFull{itemKind} <- getsState $ itemToFull iid
    let actionPart = case EM.lookup (IK.isymbol itemKind) rapplyVerbMap of
          Just verb -> MU.Text verb
          Nothing -> "use"
    itemAidVerbMU aid actionPart iid (Left $ Just 1) cstore
  SfxCheck aid iid cstore ->
    itemAidVerbMU aid "deapply" iid (Left $ Just 1) cstore
  SfxTrigger aid p -> do
    COps{cotile} <- getsState scops
    b <- getsState $ getActorBody aid
    lvl <- getLevel $ blid b
    let name = TK.tname $ okind cotile $ lvl `at` p
        verb = if p == bpos b then "walk over" else "exploit"
          -- TODO: "struggle" when harmful, "wade through" when deep, etc.
          -- possibly use the verb from the first embedded item,
          -- but it's meant to go with the item as subject, no the actor
          -- TODO: "harass" when somebody else suffers the effect
    aidVerbMU aid $ MU.Text $ verb <+> name
  SfxShun aid _p ->
    aidVerbMU aid "shun it"
  SfxEffect fidSource aid effect hpDelta -> do
    CCUI{coscreen} <- getsSession sccui
    b <- getsState $ getActorBody aid
    bUI <- getsSession $ getActorUI aid
    side <- getsClient sside
    mleader <- getsClient sleader
    let fid = bfid b
        isOurCharacter = fid == side && not (bproj b)
        isOurAlive = isOurCharacter && bhp b > 0
        isOurLeader = Just aid == mleader
    case effect of
        IK.Burn{} -> do
          if isOurAlive
          then actorVerbMU aid bUI "feel burned"
          else actorVerbMU aid bUI "look burned"
          let ps = (bpos b, bpos b)
          animate (blid b) $ twirlSplash coscreen ps Color.BrRed Color.Brown
        IK.Explode{} -> return ()  -- lots of visual feedback
        IK.RefillHP p | p == 1 -> return ()  -- no spam from regeneration
        IK.RefillHP p | p == -1 -> return ()  -- no spam from poison
        IK.RefillHP{} | hpDelta > 0 -> do
          if isOurAlive then
            actorVerbMU aid bUI "feel healthier"
          else
            actorVerbMU aid bUI "look healthier"
          let ps = (bpos b, bpos b)
          animate (blid b) $ twirlSplash coscreen ps Color.BrGreen Color.Green
        IK.RefillHP{} -> do
          if isOurAlive then
            actorVerbMU aid bUI "feel wounded"
          else
            actorVerbMU aid bUI "look wounded"
          let ps = (bpos b, bpos b)
          animate (blid b) $ twirlSplash coscreen ps Color.BrRed Color.Red
        IK.RefillCalm{} | bproj b -> return ()
        IK.RefillCalm p | p == 1 -> return ()  -- no spam from regen items
        IK.RefillCalm p | p > 0 ->
          if isOurAlive then
            actorVerbMU aid bUI "feel calmer"
          else
            actorVerbMU aid bUI "look calmer"
        IK.RefillCalm _ ->
          if isOurAlive then
            actorVerbMU aid bUI "feel agitated"
          else
            actorVerbMU aid bUI "look agitated"
        IK.Dominate -> do
          -- For subsequent messages use the proper name, never "you".
          let subject = partActor bUI
          if fid /= fidSource then do
            -- Before domination, possibly not seen if actor (yet) not ours.
            if | bcalm b == 0 ->  -- sometimes only a coincidence, but nm
                 aidVerbMU aid $ MU.Text "yield, under extreme pressure"
               | isOurAlive ->
                 aidVerbMU aid $ MU.Text "black out, dominated by foes"
               | otherwise ->
                 aidVerbMU aid $ MU.Text "decide abrubtly to switch allegiance"
            fidName <- getsState $ gname . (EM.! fid) . sfactionD
            let verb = "be no longer controlled by"
            msgAdd $ makeSentence
              [MU.SubjectVerbSg subject verb, MU.Text fidName]
            when isOurAlive $ displayMoreKeep ColorFull ""
          else do
            -- After domination, possibly not seen, if actor (already) not ours.
            fidSourceName <- getsState $ gname . (EM.! fidSource) . sfactionD
            let verb = "be now under"
            msgAdd $ makeSentence
              [MU.SubjectVerbSg subject verb, MU.Text fidSourceName, "control"]
          stopPlayBack
        IK.Impress -> actorVerbMU aid bUI "be awestruck"
        IK.PutToSleep -> actorVerbMU aid bUI "be put to sleep"
        IK.Yell -> actorVerbMU aid bUI "start"
        IK.Summon grp p -> do
          let verb = if bproj b then "lure" else "summon"
              object = (if p == 1  -- works, because exact number sent, not dice
                        then MU.AW
                        else MU.Ws) $ MU.Text $ fromGroupName grp
          actorVerbMU aid bUI $ MU.Phrase [verb, object]
        IK.Ascend up -> do
          COps{cocave} <- getsState scops
          actorVerbMU aid bUI $ MU.Text $
            "find a way" <+> if up then "upstairs" else "downstairs"
          when isOurLeader $ do
            destinations <- getsState $ whereTo (blid b) (bpos b) up
                                        . sdungeon
            case destinations of
              (lid, _) : _ -> do  -- only works until different levels possible
                lvl <- getLevel lid
                msgAdd $ cdesc $ okind cocave $ lkind lvl
              [] -> return ()  -- spell fizzles; normally should not be sent
        IK.Escape{} -> return ()
        IK.Paralyze{} -> actorVerbMU aid bUI "be paralyzed"
        IK.ParalyzeInWater{} -> actorVerbMU aid bUI "move with difficulty"
        IK.InsertMove d -> if Dice.supDice d >= 10
                           then actorVerbMU aid bUI "act with extreme speed"
                           else actorVerbMU aid bUI "move swiftly"
        IK.Teleport t | Dice.supDice t <= 9 -> actorVerbMU aid bUI "blink"
        IK.Teleport{} -> actorVerbMU aid bUI "teleport"
        IK.CreateItem{} -> return ()
        IK.DropItem _ _ COrgan _ -> return ()
        IK.DropItem{} -> actorVerbMU aid bUI "be stripped"
        IK.PolyItem -> do
          subject <- partActorLeader aid bUI
          let ppstore = MU.Text $ ppCStoreIn CGround
          msgAdd $ makeSentence
            [ MU.SubjectVerbSg subject "repurpose", "what lies", ppstore
            , "to a common item of the current level" ]
        IK.RerollItem -> do
          subject <- partActorLeader aid bUI
          let ppstore = MU.Text $ ppCStoreIn CGround
          msgAdd $ makeSentence
            [ MU.SubjectVerbSg subject "reshape", "what lies", ppstore
            , "striving for the highest possible standards" ]
        IK.DupItem -> do
          subject <- partActorLeader aid bUI
          let ppstore = MU.Text $ ppCStoreIn CGround
          msgAdd $ makeSentence
            [MU.SubjectVerbSg subject "multiply", "what lies", ppstore]
        IK.Identify -> do
          subject <- partActorLeader aid bUI
          pronoun <- partPronounLeader aid bUI
          msgAdd $ makeSentence
            [ MU.SubjectVerbSg subject "look at"
            , MU.WownW pronoun $ MU.Text "inventory"
            , "intensely" ]
        IK.Detect d _ -> do
          subject <- partActorLeader aid bUI
          let verb = MU.Text $ detectToVerb d
              object = MU.Ws $ MU.Text $ detectToObject d
          msgAdd $ makeSentence [MU.SubjectVerbSg subject verb, object]
          displayMore ColorFull ""
        IK.SendFlying{} -> actorVerbMU aid bUI "be sent flying"
        IK.PushActor{} -> actorVerbMU aid bUI "be pushed"
        IK.PullActor{} -> actorVerbMU aid bUI "be pulled"
        IK.DropBestWeapon -> actorVerbMU aid bUI "be disarmed"
        IK.ActivateInv{} -> return ()
        IK.ApplyPerfume ->
          msgAdd "The fragrance quells all scents in the vicinity."
        IK.OneOf{} -> return ()
        IK.OnSmash{} -> error $ "" `showFailure` sfx
        IK.VerbMsg t -> actorVerbMU aid bUI $ MU.Text t
        IK.Composite{} -> error $ "" `showFailure` sfx
  SfxMsgFid _ sfxMsg -> do
    mleader <- getsClient sleader
    case mleader of
      Just{} -> return ()  -- will display stuff when leader moves
      Nothing -> do
        lidV <- viewedLevelUI
        markDisplayNeeded lidV
        recordHistory
    msg <- ppSfxMsg sfxMsg
    msgAdd msg
  SfxSortSlots -> sortSlots
  SfxCollideTile source pos -> do
    COps{cotile} <- getsState scops
    sb <- getsState $ getActorBody source
    lvl <- getLevel $ blid sb
    sbUI <- getsSession $ getActorUI source
    spart <- partActorLeader source sbUI
    let object = MU.AW $ MU.Text $ TK.tname $ okind cotile $ lvl `at` pos
    msgAdd $! makeSentence
      [MU.SubjectVerbSg spart "painfully collide", "with", object]
  SfxTaunt voluntary aid -> do
    sbUI <- getsSession $ getActorUI aid
    spart <- partActorLeader aid sbUI
    (_heardSubject, verb) <- displayTaunt voluntary rndToActionForget aid
    msgAdd $! makeSentence [MU.SubjectVerbSg spart (MU.Text verb)]

ppSfxMsg :: MonadClientUI m => SfxMsg -> m Text
ppSfxMsg sfxMsg = case sfxMsg of
  SfxUnexpected reqFailure -> return $!
    "Unexpected problem:" <+> showReqFailure reqFailure <> "."
  SfxExpected itemName reqFailure -> return $!
    "The" <+> itemName <+> "is not triggered:"
    <+> showReqFailure reqFailure <> "."
  SfxFizzles -> return "It didn't work."
  SfxNothingHappens -> return "Nothing happens."
  SfxVoidDetection d -> do
    let object = detectToObject d
        noNewObject | T.null object = ["nothing new"]
                    | otherwise = ["no new", MU.Text object]
    return $! makeSentence $ noNewObject ++ ["detected"]
  SfxUnimpressed aid -> do
    msbUI <- getsSession $ EM.lookup aid . sactorUI
    case msbUI of
      Nothing -> return ""
      Just sbUI -> do
        let subject = partActor sbUI
            verb = "is unimpressed"
        return $! makeSentence [subject, verb]
  SfxSummonLackCalm aid -> do
    msbUI <- getsSession $ EM.lookup aid . sactorUI
    case msbUI of
      Nothing -> return ""
      Just sbUI -> do
        let subject = partActor sbUI
            verb = "lack Calm to summon"
        return $! makeSentence [subject, verb]
  SfxSummonTooManyOwn aid -> do
    msbUI <- getsSession $ EM.lookup aid . sactorUI
    case msbUI of
      Nothing -> return ""
      Just sbUI -> do
        let subject = partActor sbUI
            verb = "can't keep track of his numerous friends, let alone summon any more"
        return $! makeSentence [subject, verb]
  SfxSummonTooManyAll aid -> do
    msbUI <- getsSession $ EM.lookup aid . sactorUI
    case msbUI of
      Nothing -> return ""
      Just sbUI -> do
        let subject = partActor sbUI
            verb = "can't keep track of everybody around, let alone summon anyone else"
        return $! makeSentence [subject, verb]
  SfxLevelNoMore -> return "No more levels in this direction."
  SfxLevelPushed -> return "You notice somebody pushed to another level."
  SfxBracedImmune aid -> do
    msbUI <- getsSession $ EM.lookup aid . sactorUI
    case msbUI of
      Nothing -> return ""
      Just sbUI -> do
        let subject = partActor sbUI
            verb = "is braced and so immune to translocation"
        return $! makeSentence [subject, verb]
  SfxEscapeImpossible ->
    return "Escaping outside is unthinkable for members of this faction."
  SfxStasisProtects -> return "Paralysis and speed surge require recovery time."
  SfxWaterParalysisResisted -> return ""  -- don't spam
  SfxTransImpossible -> return "Translocation not possible."
  SfxIdentifyNothing -> return "Nothing to identify."
  SfxPurposeNothing -> return $!
    "The purpose of repurpose cannot be availed without an item"
    <+> ppCStoreIn CGround <> "."
  SfxPurposeTooFew maxCount itemK -> return $!
    "The purpose of repurpose is served by" <+> tshow maxCount
    <+> "pieces of this item, not by" <+> tshow itemK <> "."
  SfxPurposeUnique -> return "Unique items can't be repurposed."
  SfxPurposeNotCommon -> return "Only ordinary common items can be repurposed."
  SfxRerollNothing -> return $!
    "The shape of reshape cannot be assumed without an item"
    <+> ppCStoreIn CGround <> "."
  SfxRerollNotRandom -> return "Only items of variable shape can be reshaped."
  SfxDupNothing -> return $!
    "Mutliplicity won't rise above zero without an item"
    <+> ppCStoreIn CGround <> "."
  SfxDupUnique -> return "Unique items can't be multiplied."
  SfxDupValuable -> return "Valuable items can't be multiplied."
  SfxColdFish -> return "Healing attempt from another faction is thwarted by your cold fish attitude."
  SfxTimerExtended lid aid iid cstore delta -> do
    aidSeen <- getsState $ memActor aid lid
    if aidSeen then do
      b <- getsState $ getActorBody aid
      bUI <- getsSession $ getActorUI aid
      aidPhrase <- partActorLeader aid bUI
      factionD <- getsState sfactionD
      localTime <- getsState $ getLocalTime (blid b)
      itemFull <- getsState $ itemToFull iid
      bagAfter <- getsState $ getBodyStoreBag b cstore
      let kit = (1, [])
          (name, powers) = partItem (bfid b) factionD localTime itemFull kit
          storeOwn = ppCStoreWownW True cstore aidPhrase
          cond = [ "condition"
                 | IA.checkFlag Ability.Condition $ aspectRecordFull itemFull ]
          oldDelta = case iid `EM.lookup` bagAfter of
            Just (_, timerAfter : _) ->
              let totalDelta = timeDeltaToFrom timerAfter localTime
              in timeDeltaSubtract totalDelta delta
            _ -> Delta timeZero
      return $! makeSentence $
        ["the", name, powers] ++ cond ++ storeOwn ++ ["will now last longer"]
        ++ [ MU.Text $ "(" <> tshow (timeDeltaInSeconds oldDelta) <> "s + "
                       <> tshow (timeDeltaInSeconds delta) <> "s)"
           | oldDelta /= Delta timeZero ]
    else return ""
  SfxCollideActor lid source target -> do
    sourceSeen <- getsState $ memActor source lid
    targetSeen <- getsState $ memActor target lid
    if sourceSeen && targetSeen then do
      sbUI <- getsSession $ getActorUI source
      tbUI <- getsSession $ getActorUI target
      spart <- partActorLeader source sbUI
      tpart <- partActorLeader target tbUI
      return $! makeSentence
        [MU.SubjectVerbSg spart "painfully collide", "with", tpart]
    else return ""

strike :: MonadClientUI m
       => Bool -> ActorId -> ActorId -> ItemId -> CStore -> m ()
strike catch source target iid cstore = assert (source /= target) $ do
  CCUI{coscreen} <- getsSession sccui
  tb <- getsState $ getActorBody target
  tbUI <- getsSession $ getActorUI target
  sourceSeen <- getsState $ memActor source (blid tb)
  (ps, hurtMult, dmg) <-
   if sourceSeen then do
    hurtMult <- getsState $ armorHurtBonus source target
    sb <- getsState $ getActorBody source
    sbUI <- getsSession $ getActorUI source
    spart <- partActorLeader source sbUI
    tpart <- partActorLeader target tbUI
    spronoun <- partPronounLeader source sbUI
    tpronoun <- partPronounLeader target tbUI
    localTime <- getsState $ getLocalTime (blid tb)
    bag <- getsState $ getBodyStoreBag sb cstore
    itemFullWeapon <- getsState $ itemToFull iid
    let kitWeapon = EM.findWithDefault (1, []) iid bag
    side <- getsClient sside
    factionD <- getsState sfactionD
    eqpOrgKit <- getsState $ kitAssocs target [CEqp, COrgan]
    orgKit <- getsState $ kitAssocs target [COrgan]
    let notCond (_, (itemFull2, _)) =
          not $ IA.checkFlag Ability.Condition $ aspectRecordFull itemFull2
        isOrdinaryCond (_, (itemFull2, _)) =
          isJust $ lookup "condition" $ IK.ifreq $ itemKind itemFull2
        rateArmor (iidArmor, (itemFull2, (k, _))) =
          ( k * IA.getSkill Ability.SkArmorMelee (aspectRecordFull itemFull2)
          , ( iidArmor
            , itemKind itemFull2 ) )
        eqpAndOrgArmor = map rateArmor $ filter notCond eqpOrgKit
        condArmor = map rateArmor $ filter isOrdinaryCond orgKit
        verb | catch = "catch"
             | otherwise = MU.Text $ IK.iverbHit $ itemKind itemFullWeapon
        partItemChoice =
          if iid `EM.member` borgan sb
          then partItemShortWownW side factionD spronoun localTime
          else partItemShortAW side factionD localTime
        sleepy = if bwatch tb `elem` [WSleep, WWake] then "a sleepy" else ""
        -- In the case of forceful hit, we mention neither attacker's bonuses
        -- nor victim's maluses. The player may indeed be left guessing.
        subtly = if IK.idamage (itemKind itemFullWeapon) == 0
                 then if not (bproj sb) then "delicately" else ""
                 else if hurtMult >= 120 then "forcefully" else ""
        msg | bhp tb <= 0  -- incapacitated, so doesn't actively block
              || hurtMult > 90  -- at most minor armor
              || bproj sb && bproj tb  -- too much spam when explosions collide
              || IK.idamage (itemKind itemFullWeapon) == 0 =
              -- In this case either no items increase armor enough,
              -- or the bonuses and maluses cancel out, so it would be
              -- a lot of talk about a negligible total effect.
              makeSentence $
                [MU.SubjectVerbSg spart verb, sleepy, tpart, subtly]
                ++ if bproj sb
                   then []
                   else ["with", partItemChoice itemFullWeapon kitWeapon]
            | otherwise =
          -- This sounds goofy when the victim falls down immediately,
          -- but there is no easy way to prevent that. And it's consistent.
          -- If/when death blow instead sets HP to 1 and only the next below 1,
          -- we can check here for HP==1; also perhaps actors with HP 1 should
          -- not be able to block.
          let sActs = MU.Phrase $
                if | bproj sb && hurtMult >= 70 ->  -- strong, for a projectile
                     [MU.SubjectVerbSg spart verb, sleepy, tpart]
                   | bproj sb ->
                     [MU.SubjectVerbSg spart "connect"]
                   | otherwise ->
                     [ MU.SubjectVerbSg spart verb, sleepy, tpart
                     , "with", partItemChoice itemFullWeapon kitWeapon ]
              butEvenThough = if catch then ", even though" else ", but"
              actionPhrase =
                MU.SubjectVerbSg tpart
                $ if bproj sb
                  then if waitedLastTurn tb
                       then "deflect it"
                       else "fend it off"  -- ward it off
                  else if waitedLastTurn tb
                       then "block"
                       else "parry"
              howWell =
                if | hurtMult >= 50 ->  -- braced or big bonuses
                     if bproj sb then "clumsily" else "partly"
                   | hurtMult > 1 ->  -- braced and/or huge bonuses
                     if waitedLastTurn tb then "doggedly" else "nonchalantly"
                   | otherwise ->         -- 1% got through, which can
                     "almost completely"  -- still be deadly, if fast missile
              withWhat | null eqpAndOrgArmor = []
                       | otherwise =
                let (armor, (iidArmor, itemKind)) =
                      maximumBy (Ord.comparing fst) eqpAndOrgArmor
                in if armor >= 15
                   then let name | iidArmor == btrunk tb = "trunk"
                                 | otherwise = MU.Text $ IK.iname itemKind
                        in [ "with", MU.WownW tpronoun name ]
                   else []
              tmpInfluenceDot | null condArmor = "."
                              | otherwise =
                let (armor, (_, itemKind)) =
                      maximumBy (Ord.comparing $ abs . fst) condArmor
                    name = IK.iname itemKind
                in if | armor >= 15 -> ", thanks to being" <+> name <> "."
                      | armor <= -15 -> ", despite being" <+> name <> "."
                      | otherwise -> "."
          in makePhrase
               ([ MU.Capitalize sActs <> butEvenThough
                , actionPhrase
                , howWell ]
                ++ withWhat)
             <> tmpInfluenceDot
    msgAdd msg
    return ((bpos tb, bpos sb), hurtMult, IK.idamage (itemKind itemFullWeapon))
   else return ((bpos tb, bpos tb), 100, 1)
  let anim | dmg == 0 = subtleHit coscreen $ snd ps
           | hurtMult > 90 = twirlSplash coscreen ps Color.BrRed Color.Red
           | hurtMult > 1 = blockHit coscreen ps Color.BrRed Color.Red
           | otherwise = blockMiss coscreen ps
  animate (blid tb) anim
