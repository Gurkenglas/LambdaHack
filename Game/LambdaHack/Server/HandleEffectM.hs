{-# LANGUAGE TupleSections #-}
-- | Handle effects. They are most often caused by requests sent by clients
-- but sometimes also caused by projectiles or periodically activated items.
module Game.LambdaHack.Server.HandleEffectM
  ( applyItem, kineticEffectAndDestroy, effectAndDestroyAndAddKill
  , itemEffectEmbedded, highestImpression, dominateFidSfx
  , dropAllItems, pickDroppable
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , UseResult(..)
  , applyKineticDamage, effectAndDestroy
  , refillHP, cutCalm, imperishableKit, itemEffectDisco, effectSem
  , effectBurn, effectExplode, effectRefillHP, effectRefillCalm
  , effectDominate, dominateFid, effectImpress, effectPutToSleep, effectSummon
  , effectAscend, findStairExit, switchLevels1, switchLevels2, effectEscape
  , effectParalyze, effectInsertMove, effectTeleport, effectCreateItem
  , effectDropItem, dropCStoreItem, effectPolyItem, effectIdentify, identifyIid
  , effectDetect, effectDetectX
  , effectSendFlying, sendFlyingVector, effectDropBestWeapon
  , effectActivateInv, effectTransformContainer, effectApplyPerfume, effectOneOf
  , effectVerbMsg, effectComposite
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import           Data.Bits (xor)
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import qualified Data.HashMap.Strict as HM
import           Data.Int (Int64)
import           Data.Key (mapWithKeyM_)
import qualified Data.Ord as Ord
import qualified Data.Text as T

import           Game.LambdaHack.Atomic
import qualified Game.LambdaHack.Common.Ability as Ability
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.Analytics
import           Game.LambdaHack.Common.Container
import qualified Game.LambdaHack.Common.Dice as Dice
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Level
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.Perception
import           Game.LambdaHack.Common.Point
import           Game.LambdaHack.Common.Random
import           Game.LambdaHack.Common.ReqFailure
import           Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import           Game.LambdaHack.Common.Time
import           Game.LambdaHack.Common.Vector
import           Game.LambdaHack.Content.ItemKind (ItemKind)
import qualified Game.LambdaHack.Content.ItemKind as IK
import           Game.LambdaHack.Content.ModeKind
import           Game.LambdaHack.Content.RuleKind
import           Game.LambdaHack.Server.CommonM
import           Game.LambdaHack.Server.ItemM
import           Game.LambdaHack.Server.ItemRev
import           Game.LambdaHack.Server.MonadServer
import           Game.LambdaHack.Server.PeriodicM
import           Game.LambdaHack.Server.ServerOptions
import           Game.LambdaHack.Server.State

-- * Semantics of effects

data UseResult = UseDud | UseId | UseUp
 deriving (Eq, Ord)

applyItem :: MonadServerAtomic m => ActorId -> ItemId -> CStore -> m ()
applyItem aid iid cstore = do
  execSfxAtomic $ SfxApply aid iid cstore
  let c = CActor aid cstore
  -- Treated as if the actor hit himself with the item as a weapon,
  -- incurring both the kinetic damage and effect, hence the same call
  -- as in @reqMelee@.
  kineticEffectAndDestroy True aid aid aid iid c

applyKineticDamage :: MonadServerAtomic m
                   => ActorId -> ActorId -> ItemId -> m Bool
applyKineticDamage source target iid = do
  itemKind <- getsState $ getIidKindServer iid
  if IK.idamage itemKind == 0 then return False else do  -- speedup
    sb <- getsState $ getActorBody source
    hurtMult <- getsState $ armorHurtBonus source target
    totalDepth <- getsState stotalDepth
    Level{ldepth} <- getLevel (blid sb)
    dmg <- rndToAction $ castDice ldepth totalDepth $ IK.idamage itemKind
    let rawDeltaHP = fromIntegral hurtMult * xM dmg `divUp` 100
        speedDeltaHP = case btrajectory sb of
          Just (_, speed) -> - modifyDamageBySpeed rawDeltaHP speed
          Nothing -> - rawDeltaHP
    if speedDeltaHP < 0 then do  -- damage the target, never heal
      refillHP source target speedDeltaHP
      return True
    else return False

refillHP :: MonadServerAtomic m => ActorId -> ActorId -> Int64 -> m ()
refillHP source target speedDeltaHP = assert (speedDeltaHP /= 0) $ do
  tbOld <- getsState $ getActorBody target
  actorMaxSk <- getsState $ getActorMaxSkills target
  -- We ignore light poison, tiny blasts and similar -1HP per turn annoyances.
  let serious = speedDeltaHP < minusM && source /= target && not (bproj tbOld)
      hpMax = Ability.getSk Ability.SkMaxHP actorMaxSk
      deltaHP0 | serious = -- if overfull, at least cut back to max
                           min speedDeltaHP (xM hpMax - bhp tbOld)
               | otherwise = speedDeltaHP
      deltaHP = if | deltaHP0 > 0 && bhp tbOld > xM 999 ->  -- UI limit
                     tenthM  -- avoid nop, to avoid loops
                   | deltaHP0 < 0 && bhp tbOld < - xM 999 ->
                     -tenthM
                   | otherwise -> deltaHP0
  execUpdAtomic $ UpdRefillHP target deltaHP
  when serious $ cutCalm target
  -- If leader just lost all HP, change the leader to let players rescue him,
  -- especially if he's slowed by the attackers.
  tb <- getsState $ getActorBody target
  when (bhp tb <= 0 && bhp tbOld > 0) $ do
    mleader <- getsState $ gleader . (EM.! bfid tb) . sfactionD
    when (Just target == mleader) $ do
      allOurs <- getsState $ fidActorNotProjGlobalAssocs (bfid tb)
      let positiveHP (_, b) = bhp b > 0
          -- Only consider actors with positive HP.
          positive = filter positiveHP allOurs
      onLevel <- getsState $ fidActorRegularIds (bfid tb) (blid tb)
      case onLevel ++ map fst positive of
        [] -> return ()
        aid : _ -> execUpdAtomic $ UpdLeadFaction (bfid tb) mleader $ Just aid

cutCalm :: MonadServerAtomic m => ActorId -> m ()
cutCalm target = do
  tb <- getsState $ getActorBody target
  actorMaxSk <- getsState $ getActorMaxSkills target
  let upperBound = if hpTooLow tb actorMaxSk
                   then 2  -- to trigger domination on next attack, etc.
                   else xM $ Ability.getSk Ability.SkMaxCalm actorMaxSk
      deltaCalm = min minusM2 (upperBound - bcalm tb)
  -- HP loss decreases Calm by at least @minusM2@ to avoid "hears something",
  -- which is emitted when decreasing Calm by @minusM1@.
  updateCalm target deltaCalm

-- Here kinetic damage is applied. This is necessary so that the same
-- AI benefit calculation may be used for flinging and for applying items.
kineticEffectAndDestroy :: MonadServerAtomic m
                        => Bool -> ActorId -> ActorId -> ActorId
                        -> ItemId -> Container
                        -> m ()
kineticEffectAndDestroy voluntary killer source target iid c = do
  bag <- getsState $ getContainerBag c
  case iid `EM.lookup` bag of
    Nothing -> error $ "" `showFailure` (source, target, iid, c)
    Just kit -> do
      itemFull <- getsState $ itemToFull iid
      tbOld <- getsState $ getActorBody target
      localTime <- getsState $ getLocalTime (blid tbOld)
      let recharged = hasCharge localTime itemFull kit
      -- If neither kinetic hit nor any effect is activated, there's no chance
      -- the items can be destroyed or even timeout changes, so we abort early.
      when recharged $ do
        kineticPerformed <- applyKineticDamage source target iid
        tb <- getsState $ getActorBody target
        -- Sometimes victim heals just after we registered it as killed,
        -- but that's OK, an actor killed two times is similar enough
        -- to two killed.
        when (kineticPerformed  -- speedup
              && bhp tb <= 0 && bhp tbOld > 0) $ do
          sb <- getsState $ getActorBody source
          arWeapon <- getsState $ (EM.! iid) . sdiscoAspect
          let killHow | not (bproj sb) =
                        if voluntary then KillKineticMelee else KillKineticPush
                      | IA.checkFlag Ability.Blast arWeapon = KillKineticBlast
                      | otherwise = KillKineticRanged
          addKillToAnalytics killer killHow (bfid tbOld) (btrunk tbOld)
        effectAndDestroyAndAddKill voluntary killer False kineticPerformed
                                   source target iid c
                                   False (itemFull, kit)

effectAndDestroyAndAddKill :: MonadServerAtomic m
                           => Bool -> ActorId -> Bool -> Bool
                           -> ActorId -> ActorId -> ItemId -> Container
                           -> Bool ->  ItemFullKit
                           -> m ()
effectAndDestroyAndAddKill voluntary killer onSmashOnly kineticPerformed
                           source target iid container
                           periodic (itemFull, kit) = do
  tbOld <- getsState $ getActorBody target
  effectAndDestroy onSmashOnly kineticPerformed source target iid container
                   periodic (itemFull, kit)
  tb <- getsState $ getActorBody target
  -- Sometimes victim heals just after we registered it as killed,
  -- but that's OK, an actor killed two times is similar enough to two killed.
  when (bhp tb <= 0 && bhp tbOld > 0) $ do
    sb <- getsState $ getActorBody source
    arWeapon <- getsState $ (EM.! iid) . sdiscoAspect
    let killHow | not (bproj sb) =
                  if voluntary then KillOtherMelee else KillOtherPush
                | IA.checkFlag Ability.Blast arWeapon = KillOtherBlast
                | otherwise = KillOtherRanged
    addKillToAnalytics killer killHow (bfid tbOld) (btrunk tbOld)

effectAndDestroy :: MonadServerAtomic m
                 => Bool -> Bool -> ActorId -> ActorId -> ItemId -> Container
                 -> Bool -> ItemFullKit
                 -> m ()
effectAndDestroy onSmashOnly kineticPerformed
                 source target iid container periodic
                 ( itemFull@ItemFull{itemBase, itemDisco, itemKind}
                 , (itemK, itemTimer) ) = do
  let effs = if onSmashOnly
             then IK.strengthOnSmash itemKind
             else IK.ieffects itemKind
      arItem = itemAspect itemDisco
      timeout = IA.aTimeout arItem
  lid <- getsState $ lidFromC container
  localTime <- getsState $ getLocalTime lid
  let it1 = let timeoutTurns = timeDeltaScale (Delta timeTurn) timeout
                charging startT = timeShift startT timeoutTurns > localTime
            in filter charging itemTimer
      len = length it1
      recharged = len < itemK || onSmashOnly
  -- If the item has no charges and the effects are not @OnSmash@
  -- we speed up by shortcutting early, because we don't need to activate
  -- effects and we know kinetic hit was not performed (no charges to do so).
  when recharged $ do
    let it2 = if timeout /= 0 && recharged
              then if periodic && IA.checkFlag Ability.Fragile arItem
                   then replicate (itemK - length it1) localTime ++ it1
                           -- copies are spares only; one fires, all discharge
                   else localTime : it1
                           -- copies all fire, turn by turn; one discharges
              else itemTimer
        kit2 = (1, take 1 it2)
        !_A = assert (len <= itemK `blame` (source, target, iid, container)) ()
    -- We use up the charge even if eventualy every effect fizzles. Tough luck.
    -- At least we don't destroy the item in such case.
    -- Also, we ID it regardless.
    unless (itemTimer == it2) $
      execUpdAtomic $ UpdTimeItem iid container itemTimer it2
    -- We have to destroy the item before the effect affects the item
    -- or the actor holding it or standing on it (later on we could
    -- lose track of the item and wouldn't be able to destroy it) .
    -- This is OK, because we don't remove the item type from various
    -- item dictionaries, just an individual copy from the container,
    -- so, e.g., the item can be identified after it's removed.
    let imperishable = imperishableKit periodic itemFull
    unless imperishable $
      execUpdAtomic $ UpdLoseItem False iid itemBase kit2 container
    -- At this point, the item is potentially no longer in container
    -- @container@, so beware of assuming so in the code below.
    triggered <-
      if not recharged
      then return $ if kineticPerformed then UseUp else UseDud
      else do
        -- If the item activation is not periodic, but the item itself is,
        -- only the first effect gets activated (and the item may be destroyed,
        -- unlike with periodic activations).
        let effsManual =
              if not periodic && IA.checkFlag Ability.Periodic arItem
              then take 1 effs  -- may be empty
              else effs
        triggeredEffect <- itemEffectDisco source target iid itemKind container
                                           periodic effsManual
        let trig = if kineticPerformed then UseUp else triggeredEffect
        sb <- getsState $ getActorBody source
        -- Announce no effect, which is rare and wastes time, so noteworthy.
        unless (trig == UseUp  -- effects triggered; feedback comes from them
                || periodic  -- don't spam via fizzled periodic effects
                || bproj sb  -- don't spam, projectiles can be very numerous
                ) $
          execSfxAtomic $ SfxMsgFid (bfid sb) $
            if any IK.forApplyEffect effsManual
            then SfxFizzles  -- something didn't work, despite promising effects
            else SfxNothingHappens  -- fully expected
        return trig
    -- If none of item's effects nor a kinetic hit were performed,
    -- we recreate the item (assuming we deleted the item above).
    -- Regardless, we don't rewind the time, because some info is gained
    -- (that the item does not exhibit any effects in the given context).
    unless (imperishable || triggered == UseUp) $
      execUpdAtomic $ UpdSpotItem False iid itemBase kit2 container

imperishableKit :: Bool -> ItemFull -> Bool
imperishableKit periodic itemFull =
  let arItem = aspectRecordFull itemFull
  in IA.checkFlag Ability.Durable arItem
     || periodic && not (IA.checkFlag Ability.Fragile arItem)

-- The item is triggered exactly once. If there are more copies,
-- they are left to be triggered next time.
itemEffectEmbedded :: MonadServerAtomic m
                   => Bool -> ActorId -> LevelId -> Point -> ItemId -> m ()
itemEffectEmbedded voluntary aid lid tpos iid = do
  -- First embedded item may move actor to another level, so @lid@
  -- may be unequal to @blid sb@.
  let c = CEmbed lid tpos
  -- Treated as if the actor hit himself with the embedded item as a weapon,
  -- incurring both the kinetic damage and effect, hence the same call
  -- as in @reqMelee@. Information whether this happened due to being pushed
  -- is preserved, but how did the pushing is lost, so we blame the victim.
  kineticEffectAndDestroy voluntary aid aid aid iid c

-- | The source actor affects the target actor, with a given item.
-- If any of the effects fires up, the item gets identified.
-- Note that using raw damage (beating the enemy with the magic wand,
-- for example) does not identify the item.
--
-- Note that if we activate a durable item, e.g., armor, from the ground,
-- it will get identified, which is perfectly fine, until we want to add
-- sticky armor that can't be easily taken off (and, e.g., has some maluses).
itemEffectDisco :: MonadServerAtomic m
                => ActorId -> ActorId -> ItemId -> ItemKind -> Container
                -> Bool -> [IK.Effect]
                -> m UseResult
itemEffectDisco source target iid itemKind c periodic effs = do
  urs <- mapM (effectSem source target iid c periodic) effs
  discoAspect <- getsState sdiscoAspect
  let arItem = discoAspect EM.! iid
      ur = case urs of
        [] -> UseDud  -- there was no effects
        _ -> maximum urs
  -- Note: @UseId@ suffices for identification, @UseUp@ is not necessary.
  when (ur >= UseId && not (IA.onlyMinorEffects arItem itemKind)) $ do
    kindId <- getsState $ getIidKindIdServer iid
    execUpdAtomic $ UpdDiscover c iid kindId arItem
  return ur

-- | Source actor affects target actor, with a given effect and it strength.
-- Both actors are on the current level and can be the same actor.
-- The item may or may not still be in the container.
-- The boolean result indicates if the effect actually fired up,
-- as opposed to fizzled.
effectSem :: MonadServerAtomic m
          => ActorId -> ActorId -> ItemId -> Container -> Bool
          -> IK.Effect
          -> m UseResult
effectSem source target iid c periodic effect = do
  let recursiveCall = effectSem source target iid c periodic
  sb <- getsState $ getActorBody source
  pos <- getsState $ posFromC c
  -- @execSfx@ usually comes last in effect semantics, but not always
  -- and we are likely to introduce more variety.
  let execSfx = execSfxAtomic $ SfxEffect (bfid sb) target effect 0
  case effect of
    IK.Burn nDm -> effectBurn nDm source target
    IK.Explode t -> effectExplode execSfx t source target
    IK.RefillHP p -> effectRefillHP p source target
    IK.RefillCalm p -> effectRefillCalm execSfx p source target
    IK.Dominate -> effectDominate source target
    IK.Impress -> effectImpress recursiveCall execSfx source target
    IK.PutToSleep -> effectPutToSleep execSfx target
    IK.Yell -> effectYell execSfx target
    IK.Summon grp nDm -> effectSummon grp nDm iid source target periodic
    IK.Ascend p -> effectAscend recursiveCall execSfx p source target pos
    IK.Escape{} -> effectEscape source target
    IK.Paralyze nDm -> effectParalyze execSfx nDm source target
    IK.ParalyzeInWater nDm -> effectParalyzeInWater execSfx nDm source target
    IK.InsertMove nDm -> effectInsertMove execSfx nDm source target
    IK.Teleport nDm -> effectTeleport execSfx nDm source target
    IK.CreateItem store grp tim ->
      effectCreateItem (Just $ bfid sb) Nothing target store grp tim
    IK.DropItem n k store grp -> effectDropItem execSfx iid n k store grp target
    IK.PolyItem -> effectPolyItem execSfx iid source target
    IK.RerollItem -> effectRerollItem execSfx iid source target
    IK.DupItem -> effectDupItem execSfx iid source target
    IK.Identify -> effectIdentify execSfx iid source target
    IK.Detect d radius -> effectDetect execSfx d radius target pos
    IK.SendFlying tmod ->
      effectSendFlying execSfx tmod source target c Nothing
    IK.PushActor tmod ->
      effectSendFlying execSfx tmod source target c (Just True)
    IK.PullActor tmod ->
      effectSendFlying execSfx tmod source target c (Just False)
    IK.DropBestWeapon -> effectDropBestWeapon execSfx iid target
    IK.ActivateInv symbol -> effectActivateInv execSfx iid source target symbol
    IK.ApplyPerfume -> effectApplyPerfume execSfx target
    IK.OneOf l -> effectOneOf recursiveCall l
    IK.OnSmash _ -> return UseDud  -- ignored under normal circumstances
    IK.VerbMsg _ -> effectVerbMsg execSfx source iid c
    IK.Composite l -> effectComposite recursiveCall l

-- * Individual semantic functions for effects

-- ** Burn

-- Damage from fire. Not affected by armor.
effectBurn :: MonadServerAtomic m
           => Dice.Dice -> ActorId -> ActorId -> m UseResult
effectBurn nDm source target = do
  tb <- getsState $ getActorBody target
  totalDepth <- getsState stotalDepth
  Level{ldepth} <- getLevel (blid tb)
  n0 <- rndToAction $ castDice ldepth totalDepth nDm
  let n = max 1 n0  -- avoid 0 and negative burn
      deltaHP = - xM n
  sb <- getsState $ getActorBody source
  -- Display the effect more accurately.
  let reportedEffect = IK.Burn $ Dice.intToDice n
  execSfxAtomic $ SfxEffect (bfid sb) target reportedEffect deltaHP
  refillHP source target deltaHP
  return UseUp

-- ** Explode

effectExplode :: MonadServerAtomic m
              => m () -> GroupName ItemKind -> ActorId -> ActorId -> m UseResult
effectExplode execSfx cgroup source target = do
  execSfx
  tb <- getsState $ getActorBody target
  let itemFreq = [(cgroup, 1)]
      -- Explosion particles are placed among organs of the victim:
      container = CActor target COrgan
  m2 <- rollAndRegisterItem (blid tb) itemFreq container False Nothing
  let (iid, (ItemFull{itemBase, itemKind}, (itemK, _))) =
        fromMaybe (error $ "" `showFailure` cgroup) m2
      Point x y = bpos tb
      semirandom = T.length (IK.idesc itemKind)
      projectN k100 (n, _) = do
        -- We pick a point at the border, not inside, to have a uniform
        -- distribution for the points the line goes through at each distance
        -- from the source. Otherwise, e.g., the points on cardinal
        -- and diagonal lines from the source would be more common.
        let veryrandom = (k100 `xor` (semirandom + n)) `mod` 5
            fuzz = 5 + veryrandom
            k | itemK >= 8 && n < 4 = 0  -- speed up if only a handful remains
              | n < 16 && n >= 12 = 12
              | n < 12 && n >= 8 = 8
              | n < 8 && n >= 4 = 4
              | otherwise = min n 16  -- fire in groups of 16 including old duds
            psDir4 =
              [ Point (x - 12) (y + 12)
              , Point (x + 12) (y + 12)
              , Point (x - 12) (y - 12)
              , Point (x + 12) (y - 12) ]
            psDir8 =
              [ Point (x - 12) y
              , Point (x + 12) y
              , Point x (y + 12)
              , Point x (y - 12) ]
            psFuzz =
              [ Point (x - 12) $ y + fuzz
              , Point (x + 12) $ y + fuzz
              , Point (x - 12) $ y - fuzz
              , Point (x + 12) $ y - fuzz
              , flip Point (y - 12) $ x + fuzz
              , flip Point (y + 12) $ x + fuzz
              , flip Point (y - 12) $ x - fuzz
              , flip Point (y + 12) $ x - fuzz ]
            randomReverse = if veryrandom `mod` 2 == 0 then id else reverse
            ps = take k $ concat $
              randomReverse
                [ zip (repeat True)  -- diagonal particles don't reach that far
                  $ take 4 (drop ((k100 + itemK + fuzz) `mod` 4) $ cycle psDir4)
                , zip (repeat False)  -- only some cardinal reach far
                  $ take 4 (drop ((k100 + n) `mod` 4) $ cycle psDir8) ]
              ++ [zip (repeat True)
                  $ take 8 (drop ((k100 + fuzz) `mod` 8) $ cycle psFuzz)]
        forM_ ps $ \(centerRaw, tpxy) -> do
          let center = centerRaw && itemK >= 8  -- if few, keep them regular
          mfail <- projectFail source target tpxy veryrandom center
                               iid COrgan True
          case mfail of
            Nothing -> return ()
            Just ProjectBlockTerrain -> return ()
            Just ProjectBlockActor | not $ bproj tb -> return ()
            Just failMsg ->
              execSfxAtomic $ SfxMsgFid (bfid tb) $ SfxUnexpected failMsg
      tryFlying 0 = return ()
      tryFlying k100 = do
        -- Explosion particles are placed among organs of the victim:
        bag2 <- getsState $ borgan . getActorBody target
        let mn2 = EM.lookup iid bag2
        case mn2 of
          Nothing -> return ()
          Just n2 -> do
            projectN k100 n2
            tryFlying $ k100 - 1
  -- Particles that fail to take off, bounce off obstacles up to 100 times
  -- in total, trying to fly in different directions.
  tryFlying 100
  bag3 <- getsState $ borgan . getActorBody target
  let mn3 = EM.lookup iid bag3
  -- Give up and destroy the remaining particles, if any.
  maybe (return ()) (\kit -> execUpdAtomic
                             $ UpdLoseItem False iid itemBase kit container) mn3
  return UseUp  -- we neglect verifying that at least one projectile got off

-- ** RefillHP

-- Unaffected by armor.
effectRefillHP :: MonadServerAtomic m
               => Int -> ActorId -> ActorId -> m UseResult
effectRefillHP power0 source target = do
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  curChalSer <- getsServer $ scurChalSer . soptions
  fact <- getsState $ (EM.! bfid tb) . sfactionD
  let power = if power0 <= -1 then power0 else max 1 power0  -- avoid 0
      deltaHP = xM power
  if | cfish curChalSer && deltaHP > 0
       && fhasUI (gplayer fact) && bfid sb /= bfid tb -> do
       execSfxAtomic $ SfxMsgFid (bfid tb) SfxColdFish
       return UseId
     | otherwise -> do
       let reportedEffect = IK.RefillHP power
       execSfxAtomic $ SfxEffect (bfid sb) target reportedEffect deltaHP
       refillHP source target deltaHP
       return UseUp

-- ** RefillCalm

effectRefillCalm :: MonadServerAtomic m
                 => m () -> Int -> ActorId -> ActorId -> m UseResult
effectRefillCalm execSfx power0 source target = do
  tb <- getsState $ getActorBody target
  actorMaxSk <- getsState $ getActorMaxSkills target
  let power = if power0 <= -1 then power0 else max 1 power0  -- avoid 0
      rawDeltaCalm = xM power
      calmMax = Ability.getSk Ability.SkMaxCalm actorMaxSk
      serious = rawDeltaCalm <= minusM2 && source /= target && not (bproj tb)
      deltaCalm0 | serious =  -- if overfull, at least cut back to max
                     min rawDeltaCalm (xM calmMax - bcalm tb)
                 | otherwise = rawDeltaCalm
      deltaCalm = if | deltaCalm0 > 0 && bcalm tb > xM 999 ->  -- UI limit
                       tenthM  -- avoid nop, to avoid loops
                     | deltaCalm0 < 0 && bcalm tb < - xM 999 ->
                       -tenthM
                     | otherwise -> deltaCalm0
  execSfx
  updateCalm target deltaCalm
  return UseUp

-- ** Dominate

-- The is another way to trigger domination (the normal way is by zeroed Calm).
-- Calm is here irrelevant. The other conditions are the same.
effectDominate :: MonadServerAtomic m => ActorId -> ActorId -> m UseResult
effectDominate source target = do
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  if | bproj tb -> return UseDud
     | bfid tb == bfid sb -> return UseDud  -- accidental hit; ignore
     | otherwise -> do
       fact <- getsState $ (EM.! bfid tb) . sfactionD
       hiImpression <- highestImpression tb
       let permitted = case hiImpression of
             Nothing -> False  -- no impression, no domination
             Just (hiImpressionFid, hiImpressionK) ->
                hiImpressionFid == bfid sb
                  -- highest impression needs to be by us
                && (fleaderMode (gplayer fact) /= LeaderNull
                    || hiImpressionK >= 10)
                     -- to tame/hack animal/robot, impress them a lot first
       if permitted then do
         b <- dominateFidSfx target (bfid sb)
         return $! if b then UseUp else UseDud
       else do
         execSfxAtomic $ SfxMsgFid (bfid sb) $ SfxUnimpressed target
         return UseDud

highestImpression :: MonadServerAtomic m
                  => Actor -> m (Maybe (FactionId, Int))
highestImpression tb = do
  getKind <- getsState $ flip getIidKindServer
  getItem <- getsState $ flip getItemBody
  let isImpression iid =
        maybe False (> 0) $ lookup "impressed" $ IK.ifreq $ getKind iid
      impressions = EM.filterWithKey (\iid _ -> isImpression iid) $ borgan tb
      f (_, (k, _)) = k
      maxImpression = maximumBy (Ord.comparing f) $ EM.assocs impressions
  if EM.null impressions
  then return Nothing
  else case jfid $ getItem $ fst maxImpression of
    Nothing -> return Nothing
    Just fid -> assert (fid /= bfid tb)
                $ return $ Just (fid, fst $ snd maxImpression)

dominateFidSfx :: MonadServerAtomic m => ActorId -> FactionId -> m Bool
dominateFidSfx target fid = do
  tb <- getsState $ getActorBody target
  let !_A = assert (not $ bproj tb) ()
  -- Actors that don't move freely can't be dominated, for otherwise,
  -- when they are the last survivors, they could get stuck and the game
  -- wouldn't end. Also, they are a hassle to guide through the dungeon.
  canTra <- getsState $ canTraverse target
  -- Being pushed protects from domination, for simplicity.
  -- A possible interesting exploit, but much help from content would be needed
  -- to make it practical.
  if isNothing (btrajectory tb) && canTra && bhp tb > 0 then do
    let execSfx = execSfxAtomic $ SfxEffect fid target IK.Dominate 0
    execSfx  -- if actor ours, possibly the last occasion to see him
    gameOver <- dominateFid fid target
    unless gameOver  -- avoid spam
      execSfx  -- see the actor as theirs, unless position not visible
    return True
  else
    return False

dominateFid :: MonadServerAtomic m => FactionId -> ActorId -> m Bool
dominateFid fid target = do
  tb0 <- getsState $ getActorBody target
  deduceKilled target
  electLeader (bfid tb0) (blid tb0) target
  fact <- getsState $ (EM.! bfid tb0) . sfactionD
  -- Drop all items so that domiation is not too nasty, especially
  -- if the dominated hero runs off or teleports away with gold
  -- or starts hitting with the most potent artifact weapon in the game.
  -- Prevent the faction's stash from being lost in case they are
  -- not spawners. Drop items while still of the original faction
  -- to mark them on the map for other party members to collect.
  when (isNothing $ gleader fact) $ moveStores False target CSha CInv
  dropAllItems target tb0
  tb <- getsState $ getActorBody target
  ais <- getsState $ getCarriedAssocsAndTrunk tb
  actorMaxSk <- getsState $ getActorMaxSkills target
  getKind <- getsState $ flip getIidKindServer
  let isImpression iid =
        maybe False (> 0) $ lookup "impressed" $ IK.ifreq $ getKind iid
      dropAllImpressions = EM.filterWithKey (\iid _ -> not $ isImpression iid)
      borganNoImpression = dropAllImpressions $ borgan tb
  -- Actor is not pushed nor projectile, so @sactorTime@ suffices.
  btime <-
    getsServer $ (EM.! target) . (EM.! blid tb) . (EM.! bfid tb) . sactorTime
  execUpdAtomic $ UpdLoseActor target tb ais
  let maxCalm = Ability.getSk Ability.SkMaxCalm actorMaxSk
      maxHp = Ability.getSk Ability.SkMaxHP actorMaxSk
      bNew = tb { bfid = fid
                , bcalm = max (xM 10) $ xM maxCalm `div` 2
                , bhp = min (xM maxHp) $ bhp tb + xM 10
                , borgan = borganNoImpression}
  aisNew <- getsState $ getCarriedAssocsAndTrunk bNew
  modifyServer $ \ser ->
    ser {sactorTime = updateActorTime fid (blid tb) target btime
                      $ sactorTime ser}
  execUpdAtomic $ UpdSpotActor target bNew aisNew
  -- Focus on the dominated actor, by making him a leader.
  supplantLeader fid target
  factionD <- getsState sfactionD
  let inGame fact2 = case gquit fact2 of
        Nothing -> True
        Just Status{stOutcome=Camping} -> True
        _ -> False
      gameOver = not $ any inGame $ EM.elems factionD
  if gameOver
  then return True  -- avoid the spam of identifying items at this point
  else do
    -- Add some nostalgia for the old faction.
    void $ effectCreateItem (Just $ bfid tb) (Just 10) target COrgan
                            "impressed" IK.timerNone
    -- Identify organs that won't get identified by use.
    getKindId <- getsState $ flip getIidKindIdServer
    let discoverIf (iid, cstore) = do
          let itemKindId = getKindId iid
              c = CActor target cstore
          discoverIfMinorEffects c iid itemKindId
        aic = (btrunk tb, COrgan)
              : filter ((/= btrunk tb) . fst) (getCarriedIidCStore tb)
    mapM_ discoverIf aic
    return False

-- | Drop all actor's items.
dropAllItems :: MonadServerAtomic m => ActorId -> Actor -> m ()
dropAllItems aid b = do
  mapActorCStore_ CInv (dropCStoreItem False CInv aid b maxBound) b
  mapActorCStore_ CEqp (dropCStoreItem False CEqp aid b maxBound) b

-- ** Impress

effectImpress :: MonadServerAtomic m
              => (IK.Effect -> m UseResult) -> m () -> ActorId -> ActorId
              -> m UseResult
effectImpress recursiveCall execSfx source target = do
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  if | bproj tb -> return UseDud
     | bfid tb == bfid sb ->
       -- Unimpress wrt others, but only once. The recursive Sfx suffices.
       recursiveCall $ IK.DropItem 1 1 COrgan "impressed"
     | otherwise -> do
       -- Actors that don't move freely and so are stupid, can't be impressed.
       canTra <- getsState $ canTraverse target
       if canTra then do
         unless (bhp tb <= 0)
           execSfx  -- avoid spam just before death
         effectCreateItem (Just $ bfid sb) (Just 1) target COrgan
                          "impressed" IK.timerNone
       else return UseDud  -- no message, because common and not crucial

-- ** PutToSleep

effectPutToSleep :: MonadServerAtomic m => m () -> ActorId -> m UseResult
effectPutToSleep execSfx target = do
  tb <- getsState $ getActorBody target
  if | bproj tb -> return UseDud
     | bwatch tb `elem` [WSleep, WWake] -> return UseId  -- can't increase sleep
     | otherwise -> do
       actorMaxSk <- getsState $ getActorMaxSkills target
       let maxCalm = xM $ Ability.getSk Ability.SkMaxCalm actorMaxSk
           deltaCalm = maxCalm - bcalm tb
       when (deltaCalm > 0) $
         updateCalm target deltaCalm  -- max Calm, but asleep vulnerability
       execSfx
       case bwatch tb of
         WWait n | n > 0 -> do
           nAll <- removeConditionSingle "braced" target
           let !_A = assert (nAll == 0) ()
           return ()
         _ -> return ()
       -- Forced sleep. No check if the actor can sleep naturally.
       addSleep target
       return UseUp

-- ** Yell

-- This is similar to 'reqYell', but also mentions that the actor is startled,
-- because, presumably, he yells involuntarily. It doesn't wake him up
-- via Calm instantly, just like yelling in a dream not always does.
effectYell :: MonadServerAtomic m => m () -> ActorId -> m UseResult
effectYell execSfx target = do
  tb <- getsState $ getActorBody target
  if bproj tb || bhp tb <= 0 then  -- avoid yelling projectiles or corpses
    return UseDud  -- the yell never manifested
  else do
    execSfx
    execSfxAtomic $ SfxTaunt False target
    when (deltaBenign $ bcalmDelta tb) $
      execUpdAtomic $ UpdRefillCalm target minusM
    return UseUp

-- ** Summon

-- Note that the Calm expended doesn't depend on the number of actors summoned.
effectSummon :: MonadServerAtomic m
             => GroupName ItemKind -> Dice.Dice -> ItemId
             -> ActorId -> ActorId -> Bool
             -> m UseResult
effectSummon grp nDm iid source target periodic = do
  -- Obvious effect, nothing announced.
  cops@COps{coTileSpeedup} <- getsState scops
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  sMaxSk <- getsState $ getActorMaxSkills source
  tMaxSk <- getsState $ getActorMaxSkills target
  totalDepth <- getsState stotalDepth
  lvl@Level{ldepth, lbig} <- getLevel (blid tb)
  nFriends <- getsState $ length . friendRegularAssocs (bfid sb) (blid sb)
  discoAspect <- getsState sdiscoAspect
  power0 <- rndToAction $ castDice ldepth totalDepth nDm
  let arItem = discoAspect EM.! iid
      power = max power0 1  -- KISS, always at least one summon
      -- We put @source@ instead of @target@ and @power@ instead of dice
      -- to make the message more accurate.
      effect = IK.Summon grp $ Dice.intToDice power
      execSfx = execSfxAtomic $ SfxEffect (bfid sb) source effect 0
      durable = IA.checkFlag Ability.Durable arItem
      deltaCalm = - xM 30
  -- Verify Calm only at periodic activations or if the item is durable.
  -- Otherwise summon uses up the item, which prevents summoning getting
  -- out of hand. I don't verify Calm otherwise, to prevent an exploit
  -- via draining one's calm on purpose when an item with good activation
  -- has a nasty summoning side-effect (the exploit still works on durables).
  if | (periodic || durable) && not (bproj sb)
       && (bcalm sb < - deltaCalm || not (calmEnough sb sMaxSk)) -> do
       unless (bproj sb) $
         execSfxAtomic $ SfxMsgFid (bfid sb) $ SfxSummonLackCalm source
       return UseId
     | nFriends >= 20 -> do
       -- We assume the actor tries to summon his teammates or allies.
       -- As he repeats such summoning, he is going to bump into this limit.
       -- If he summons others, see the next condition.
       unless (bproj sb) $
         execSfxAtomic $ SfxMsgFid (bfid sb) $ SfxSummonTooManyOwn source
       return UseId
     | EM.size lbig >= 200 -> do  -- lower than the 300 limit for spawning
       -- Even if the actor summons foes, he is prevented from exploiting it
       -- too many times and stopping natural monster spawning on the level
       -- (e.g., by filling the level with harmless foes).
       unless (bproj sb) $
         execSfxAtomic $ SfxMsgFid (bfid sb) $ SfxSummonTooManyAll source
       return UseId
     | otherwise -> do
       execSfx
       unless (bproj sb) $ updateCalm source deltaCalm
       let validTile t = not $ Tile.isNoActor coTileSpeedup t
           ps = nearbyFreePoints cops lvl validTile (bpos tb)
       localTime <- getsState $ getLocalTime (blid tb)
       -- Make sure summoned actors start acting after the victim.
       let actorTurn = ticksPerMeter $ gearSpeed tMaxSk
           targetTime = timeShift localTime actorTurn
           afterTime = timeShift targetTime $ Delta timeClip
       when (length (take power ps) < power) $
          debugPossiblyPrint
            "Server: effectSummon: failed to find enough free positions"
       bs <- forM (take power ps) $ \p -> do
         -- Mark as summoned to prevent immediate chain summoning.
         -- Summon from current depth, not deeper due to many spawns already.
         maid <- addAnyActor True 0 [(grp, 1)] (blid tb) afterTime (Just p)
         case maid of
           Nothing -> return False  -- suspect content; server debug elsewhere
           Just aid -> do
             b <- getsState $ getActorBody aid
             mleader <- getsState $ gleader . (EM.! bfid b) . sfactionD
             when (isNothing mleader) $ supplantLeader (bfid b) aid
             return True
       return $! if or bs then UseUp else UseId

-- ** Ascend

-- Note that projectiles can be teleported, too, for extra fun.
effectAscend :: MonadServerAtomic m
             => (IK.Effect -> m UseResult)
             -> m () -> Bool -> ActorId -> ActorId -> Point
             -> m UseResult
effectAscend recursiveCall execSfx up source target pos = do
  b1 <- getsState $ getActorBody target
  let lid1 = blid b1
  destinations <- getsState $ whereTo lid1 pos up . sdungeon
  sb <- getsState $ getActorBody source
  if | actorWaits b1 -> do
       execSfxAtomic $ SfxMsgFid (bfid sb) $ SfxBracedImmune target
       return UseId
     | null destinations -> do
       execSfxAtomic $ SfxMsgFid (bfid sb) SfxLevelNoMore
       -- We keep it useful even in shallow dungeons.
       recursiveCall $ IK.Teleport 30  -- powerful teleport
     | otherwise -> do
       (lid2, pos2) <- rndToAction $ oneOf destinations
       execSfx
       mbtime_bOld <-
         getsServer $ lookupActorTime (bfid b1) lid1 target . sactorTime
       mbtimeTraj_bOld <-
         getsServer $ lookupActorTime (bfid b1) lid1 target . strajTime
       pos3 <- findStairExit (bfid sb) up lid2 pos2
       let switch1 = void $ switchLevels1 (target, b1)
           switch2 = do
             -- Make the initiator of the stair move the leader,
             -- to let him clear the stairs for others to follow.
             let mlead = if bproj b1 then Nothing else Just target
             -- Move the actor to where the inhabitants were, if any.
             switchLevels2 lid2 pos3 (target, b1)
                           mbtime_bOld mbtimeTraj_bOld mlead
       -- The actor will be added to the new level,
       -- but there can be other actors at his new position.
       inhabitants <- getsState $ posToAidAssocs pos3 lid2
       case inhabitants of
         [] -> do
           switch1
           switch2
         (_, b2) : _ -> do
           -- Alert about the switch.
           -- Only tell one player, even if many actors, because then
           -- they are projectiles, so not too important.
           execSfxAtomic $ SfxMsgFid (bfid b2) SfxLevelPushed
           -- Move the actor out of the way.
           switch1
           -- Move the inhabitants out of the way and to where the actor was.
           let moveInh inh = do
                 -- Preserve the old leader, since the actor is pushed,
                 -- so possibly has nothing worhwhile to do on the new level
                 -- (and could try to switch back, if made a leader,
                 -- leading to a loop).
                 mbtime_inh <-
                   getsServer $ lookupActorTime (bfid (snd inh)) lid2 (fst inh)
                                . sactorTime
                 mbtimeTraj_inh <-
                   getsServer $ lookupActorTime (bfid (snd inh)) lid2 (fst inh)
                                . strajTime
                 inhMLead <- switchLevels1 inh
                 switchLevels2 lid1 (bpos b1) inh
                               mbtime_inh mbtimeTraj_inh inhMLead
           mapM_ moveInh inhabitants
           -- Move the actor to his destination.
           switch2
       return UseUp

findStairExit :: MonadStateRead m
              => FactionId -> Bool -> LevelId -> Point -> m Point
findStairExit side moveUp lid pos = do
  COps{coTileSpeedup} <- getsState scops
  fact <- getsState $ (EM.! side) . sfactionD
  lvl <- getLevel lid
  let defLanding = uncurry Vector $ if moveUp then (1, 0) else (-1, 0)
      center = uncurry Vector $ if moveUp then (-1, 0) else (1, 0)
      (mvs2, mvs1) = break (== defLanding) moves
      mvs = center : filter (/= center) (mvs1 ++ mvs2)
      ps = filter (Tile.isWalkable coTileSpeedup . (lvl `at`))
           $ map (shift pos) mvs
      posOcc :: State -> Int -> Point -> Bool
      posOcc s k p = case posToAidAssocs p lid s of
        [] -> k == 0
        (_, b) : _ | bproj b -> k == 3
        (_, b) : _ | isFoe side fact (bfid b) -> k == 1  -- non-proj foe
        _ -> k == 2  -- moving a non-projectile friend
  unocc <- getsState posOcc
  case concatMap (\k -> filter (unocc k) ps) [0..3] of
    [] -> error $ "" `showFailure` ps
    posRes : _ -> return posRes

switchLevels1 :: MonadServerAtomic m => (ActorId, Actor) -> m (Maybe ActorId)
switchLevels1 (aid, bOld) = do
  let side = bfid bOld
  mleader <- getsState $ gleader . (EM.! side) . sfactionD
  -- Prevent leader pointing to a non-existing actor.
  mlead <-
    if not (bproj bOld) && isJust mleader then do
      execUpdAtomic $ UpdLeadFaction side mleader Nothing
      return mleader
        -- outside of a client we don't know the real tgt of aid, hence fst
    else return Nothing
  -- Remove the actor from the old level.
  -- Onlookers see somebody disappear suddenly.
  -- @UpdDestroyActor@ is too loud, so use @UpdLoseActor@ instead.
  ais <- getsState $ getCarriedAssocsAndTrunk bOld
  execUpdAtomic $ UpdLoseActor aid bOld ais
  return mlead

switchLevels2 ::MonadServerAtomic m
              => LevelId -> Point -> (ActorId, Actor)
              -> Maybe Time -> Maybe Time -> Maybe ActorId
              -> m ()
switchLevels2 lidNew posNew (aid, bOld) mbtime_bOld mbtimeTraj_bOld mlead = do
  let lidOld = blid bOld
      side = bfid bOld
  let !_A = assert (lidNew /= lidOld `blame` "stairs looped" `swith` lidNew) ()
  -- Sync actor's items' timeouts with the new local time of the level.
  -- We need to sync organs and equipment due to periodic activations,
  -- but also inventory pack (as well as some organs and equipment),
  -- due to timeouts after use, e.g., for some weapons (they recharge also
  -- in the pack; however, this doesn't encourage micromanagement for periodic
  -- items, because the timeout is randomised upon move to equipment).
  --
  -- We don't rebase timeouts for items in stash, because they are
  -- used by many actors on levels with different local times,
  -- so there is no single rebase that would match all.
  -- This is not a big problem: after a single use by an actor the timeout is
  -- set to his current local time, so further uses by that actor have
  -- not anomalously short or long recharge times. If the recharge time
  -- is very long, the player has an option of moving the item from stash
  -- to pack and back, to reset the timeout. An abuse is possible when recently
  -- used item is put from inventory to stash and at once used on another level
  -- taking advantage of local time difference, but this only works once
  -- and using the item back again at the original level makes the recharge
  -- time longer, in turn.
  timeOld <- getsState $ getLocalTime lidOld
  timeLastActive <- getsState $ getLocalTime lidNew
  let delta = timeLastActive `timeDeltaToFrom` timeOld
      shiftByDelta = (`timeShift` delta)
      computeNewTimeout :: ItemQuant -> ItemQuant
      computeNewTimeout (k, it) = (k, map shiftByDelta it)
      rebaseTimeout :: ItemBag -> ItemBag
      rebaseTimeout = EM.map computeNewTimeout
      bNew = bOld { blid = lidNew
                  , bpos = posNew
                  , boldpos = Just posNew  -- new level, new direction
                  , borgan = rebaseTimeout $ borgan bOld
                  , beqp = rebaseTimeout $ beqp bOld
                  , binv = rebaseTimeout $ binv bOld }
  ais <- getsState $ getCarriedAssocsAndTrunk bOld
  -- Sync the actor time with the level time.
  -- This time shift may cause a double move of a foe of the same speed,
  -- but this is OK --- the foe didn't have a chance to move
  -- before, because the arena went inactive, so he moves now one more time.
  maybe (return ())
        (\btime_bOld ->
    modifyServer $ \ser ->
      ser {sactorTime = updateActorTime (bfid bNew) lidNew aid
                                        (shiftByDelta btime_bOld)
                        $ sactorTime ser})
        mbtime_bOld
  maybe (return ())
        (\btime_bOld ->
    modifyServer $ \ser ->
      ser {strajTime = updateActorTime (bfid bNew) lidNew aid
                                       (shiftByDelta btime_bOld)
                       $ strajTime ser})
        mbtimeTraj_bOld
  -- Materialize the actor at the new location.
  -- Onlookers see somebody appear suddenly. The actor himself
  -- sees new surroundings and has to reset his perception.
  execUpdAtomic $ UpdCreateActor aid bNew ais
  case mlead of
    Nothing -> return ()
    Just leader -> supplantLeader side leader

-- ** Escape

-- | The faction leaves the dungeon.
effectEscape :: MonadServerAtomic m => ActorId -> ActorId -> m UseResult
effectEscape source target = do
  -- Obvious effect, nothing announced.
  sb <- getsState $ getActorBody source
  b <- getsState $ getActorBody target
  let fid = bfid b
  fact <- getsState $ (EM.! fid) . sfactionD
  if | bproj b ->
       return UseDud  -- basically a misfire
     | not (fcanEscape $ gplayer fact) -> do
       execSfxAtomic $ SfxMsgFid (bfid sb) SfxEscapeImpossible
       return UseId
     | otherwise -> do
       deduceQuits (bfid b) $ Status Escape (fromEnum $ blid b) Nothing
       return UseUp

-- ** Paralyze

-- | Advance target actor time by this many time clips. Not by actor moves,
-- to hurt fast actors more.
effectParalyze :: MonadServerAtomic m
               => m () -> Dice.Dice -> ActorId -> ActorId -> m UseResult
effectParalyze execSfx nDm source target = do
  tb <- getsState $ getActorBody target
  if bproj tb then return UseDud else  -- shortcut for speed
    paralyze execSfx nDm source target

paralyze :: MonadServerAtomic m
         => m () -> Dice.Dice -> ActorId -> ActorId -> m UseResult
paralyze execSfx nDm source target = do
  tb <- getsState $ getActorBody target
  totalDepth <- getsState stotalDepth
  Level{ldepth} <- getLevel (blid tb)
  power0 <- rndToAction $ castDice ldepth totalDepth nDm
  let power = max power0 1  -- KISS, avoid special case
  actorStasis <- getsServer sactorStasis
  if | ES.member target actorStasis -> do
       sb <- getsState $ getActorBody source
       execSfxAtomic $ SfxMsgFid (bfid sb) SfxStasisProtects
       return UseId
     | otherwise -> do
       execSfx
       let t = timeDeltaScale (Delta timeClip) power
       -- Only the normal time, not the trajectory time, is affected.
       modifyServer $ \ser ->
         ser { sactorTime = ageActor (bfid tb) (blid tb) target t
                            $ sactorTime ser
             , sactorStasis = ES.insert target (sactorStasis ser) }
                 -- actor's time warped, so he is in stasis,
                 -- immune to further warps
       return UseUp

-- ** ParalyzeInWater

-- | Advance target actor time by this many time clips. Not by actor moves,
-- to hurt fast actors more. Due to water, so resistable.
effectParalyzeInWater :: MonadServerAtomic m
                      => m () -> Dice.Dice -> ActorId -> ActorId -> m UseResult
effectParalyzeInWater execSfx nDm source target = do
  tb <- getsState $ getActorBody target
  if bproj tb then return UseDud else do  -- shortcut for speed
    actorMaxSk <- getsState $ getActorMaxSkills target
    let swimmingOrFlying = max (Ability.getSk Ability.SkSwimming actorMaxSk)
                               (Ability.getSk Ability.SkFlying actorMaxSk)
    if Dice.supDice nDm > swimmingOrFlying
    then paralyze execSfx nDm source target  -- no help at all
    else do  -- fully resisted
      sb <- getsState $ getActorBody source
      execSfxAtomic $ SfxMsgFid (bfid sb) SfxWaterParalysisResisted
      return UseId

-- ** InsertMove

-- | Give target actor the given number of tenths of extra move. Don't give
-- an absolute amount of time units, to benefit slow actors more.
effectInsertMove :: MonadServerAtomic m
                 => m () -> Dice.Dice -> ActorId -> ActorId -> m UseResult
effectInsertMove execSfx nDm source target = do
  tb <- getsState $ getActorBody target
  actorMaxSk <- getsState $ getActorMaxSkills target
  totalDepth <- getsState stotalDepth
  Level{ldepth} <- getLevel (blid tb)
  actorStasis <- getsServer sactorStasis
  power0 <- rndToAction $ castDice ldepth totalDepth nDm
  let power = max power0 1  -- KISS, avoid special case
      actorTurn = ticksPerMeter $ gearSpeed actorMaxSk
      t = timeDeltaScale (timeDeltaPercent actorTurn 10) (-power)
  if | bproj tb -> return UseDud  -- shortcut for speed
     | ES.member target actorStasis -> do
       sb <- getsState $ getActorBody source
       execSfxAtomic $ SfxMsgFid (bfid sb) SfxStasisProtects
       return UseId
     | otherwise -> do
       execSfx
       -- Only the normal time, not the trajectory time, is affected.
       modifyServer $ \ser ->
         ser { sactorTime = ageActor (bfid tb) (blid tb) target t
                            $ sactorTime ser
             , sactorStasis = ES.insert target (sactorStasis ser) }
                 -- actor's time warped, so he is in stasis,
                 -- immune to further warps
       return UseUp

-- ** Teleport

-- | Teleport the target actor.
-- Note that projectiles can be teleported, too, for extra fun.
effectTeleport :: MonadServerAtomic m
               => m () -> Dice.Dice -> ActorId -> ActorId -> m UseResult
effectTeleport execSfx nDm source target = do
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  if actorWaits tb && source /= target
       -- immune only against not own effects, to enable teleport as beneficial
       -- necklace drawback; also consistent with sleep not protecting
  then do
    execSfxAtomic $ SfxMsgFid (bfid sb) $ SfxBracedImmune target
    return UseId
  else do
    COps{coTileSpeedup} <- getsState scops
    totalDepth <- getsState stotalDepth
    lvl@Level{ldepth} <- getLevel (blid tb)
    range <- rndToAction $ castDice ldepth totalDepth nDm
    let spos = bpos tb
        dMinMax !delta !pos =
          let d = chessDist spos pos
          in d >= range - delta && d <= range + delta
        dist !delta !pos _ = dMinMax delta pos
    mtpos <- rndToAction $ findPosTry 200 lvl
      (\p !t -> Tile.isWalkable coTileSpeedup t
                && not (Tile.isNoActor coTileSpeedup t)
                && not (occupiedBigLvl p lvl)
                && not (occupiedProjLvl p lvl))
      [ dist 1
      , dist $ 1 + range `div` 9
      , dist $ 1 + range `div` 7
      , dist $ 1 + range `div` 5
      , dist 5
      , dist 7
      , dist 9
      ]
    case mtpos of
      Nothing -> do  -- really very rare, so debug
        debugPossiblyPrint
          "Server: effectTeleport: failed to find any free position"
        execSfxAtomic $ SfxMsgFid (bfid sb) SfxTransImpossible
        return UseId
      Just tpos -> do
        execSfx
        execUpdAtomic $ UpdMoveActor target spos tpos
        return UseUp

-- ** CreateItem

effectCreateItem :: MonadServerAtomic m
                 => Maybe FactionId -> Maybe Int -> ActorId -> CStore
                 -> GroupName ItemKind -> IK.TimerDice
                 -> m UseResult
effectCreateItem jfidRaw mcount target store grp tim = do
  tb <- getsState $ getActorBody target
  totalDepth <- getsState stotalDepth
  Level{ldepth} <- getLevel (blid tb)
  let fscale unit nDm = do
        k0 <- rndToAction $ castDice ldepth totalDepth nDm
        let k = max 1 k0  -- KISS, don't freak out if dice permit 0
        return $! timeDeltaScale unit k
      fgame = fscale (Delta timeTurn)
      factor nDm = do
        actorMaxSk <- getsState $ getActorMaxSkills target
        -- A tiny bit added to make sure length 1 effect doesn't end before
        -- the end of first turn, which would make, e.g., speed, useless.
        let actorTurn =
              timeDeltaPercent (ticksPerMeter $ gearSpeed actorMaxSk) 101
        fscale actorTurn nDm
  delta <- IK.foldTimer (return $ Delta timeZero) fgame factor tim
  let c = CActor target store
  bagBefore <- getsState $ getBodyStoreBag tb store
  -- Power depth of new items unaffected by number of spawned actors.
  freq <- prepareItemKind 0 (blid tb) [(grp, 1)]
  m2 <- rollItemAspect freq (blid tb)
  let (itemKnownRaw, (itemFullRaw, kitRaw)) =
        fromMaybe (error $ "" `showFailure` (blid tb, freq, c)) m2
      -- Avoid too many different item identifiers (one for each faction)
      -- for blasts or common item generating tiles. Conditions are
      -- allowed to be duplicated, because they provide really useful info
      -- (perpetrator). However, if timer is none, they are not duplicated
      -- to make sure that, e.g., poisons stack with each other regardless
      -- of perpetrator and we don't get "no longer poisoned" message
      -- while still poisoned due to another faction. With timed aspects,
      -- e.g., slowness, the message is less misleading, and it's interesting
      -- that I'm twice slower due to aspects from two factions and not
      -- as deadly as being poisoned at twice the rate from two factions.
      jfid = if store == COrgan && not (IK.isTimerNone tim)
                || grp == "impressed"
             then jfidRaw
             else Nothing
      (itemKnown, itemFull) =
        let ItemKnown kindIx ar _ = itemKnownRaw
        in ( ItemKnown kindIx ar jfid
           , itemFullRaw {itemBase = (itemBase itemFullRaw) {jfid}} )
      kitNew = case mcount of
        Just itemK -> (itemK, [])
        Nothing -> kitRaw
  itemRev <- getsServer sitemRev
  let mquant = case HM.lookup itemKnown itemRev of
        Nothing -> Nothing
        Just iid -> (iid,) <$> iid `EM.lookup` bagBefore
  case mquant of
    Just (iid, (_, afterIt@(timer : rest))) | not $ IK.isTimerNone tim -> do
      -- Already has such items and timer change requested, so only increase
      -- the timer of the first item by the delta, but don't create items.
      let newIt = timer `timeShift` delta : rest
      if afterIt /= newIt then do
        execUpdAtomic $ UpdTimeItem iid c afterIt newIt
        -- It's hard for the client to tell this timer change from charge use,
        -- timer reset on pickup, etc., so we create the msg manually.
        execSfxAtomic $ SfxMsgFid (bfid tb)
                      $ SfxTimerExtended (blid tb) target iid store delta
        return UseUp
      else return UseDud  -- probably incorrect content, but let it be
    _ -> do
      -- No such items or some items, but void delta, so create items.
      -- If it's, e.g., a periodic poison, the new items will stack with any
      -- already existing items.
      iid <- registerItem (itemFull, kitNew) itemKnown c True
      -- If created not on the ground, ID it, because it won't be on pickup.
      when (store /= CGround) $
        discoverIfMinorEffects c iid (itemKindId itemFull)
      -- Now, if timer change requested, change the timer, but in the new items,
      -- possibly increased in number wrt old items.
      when (not $ IK.isTimerNone tim) $ do
        tb2 <- getsState $ getActorBody target
        bagAfter <- getsState $ getBodyStoreBag tb2 store
        localTime <- getsState $ getLocalTime (blid tb)
        let newTimer = localTime `timeShift` delta
            (afterK, afterIt) =
              fromMaybe (error $ "" `showFailure` (iid, bagAfter, c))
                        (iid `EM.lookup` bagAfter)
            newIt = replicate afterK newTimer
        when (afterIt /= newIt) $
          execUpdAtomic $ UpdTimeItem iid c afterIt newIt
      return UseUp

-- ** DropItem

-- | Make the target actor drop items in a store from the given group.
-- The item itself is immune (any copies).
effectDropItem :: MonadServerAtomic m
               => m () -> ItemId -> Int -> Int -> CStore
               -> GroupName ItemKind -> ActorId
               -> m UseResult
effectDropItem execSfx iidId ngroup kcopy store grp target = do
  tb <- getsState $ getActorBody target
  fact <- getsState $ (EM.! bfid tb) . sfactionD
  isRaw <- allGroupItems store grp target
  curChalSer <- getsServer $ scurChalSer . soptions
  factionD <- getsState sfactionD
  let is = filter ((/= iidId) . fst) isRaw
  if | bproj tb || null is -> return UseDud
     | ngroup == maxBound && kcopy == maxBound
       && store `elem` [CEqp, CInv, CSha]
       && fhasGender (gplayer fact)  -- hero in Allure's decontamination chamber
       && (cdiff curChalSer == 1     -- at lowest difficulty for its faction
           && any (fhasUI . gplayer . snd)
                  (filter (\(fi, fa) -> isFriend fi fa (bfid tb))
                          (EM.assocs factionD))
           || cdiff curChalSer == difficultyBound
              && any (fhasUI . gplayer  . snd)
                     (filter (\(fi, fa) -> isFoe fi fa (bfid tb))
                             (EM.assocs factionD))) ->
{-
A hardwired hack, because AI heroes don't cope with Allure's decontamination
chamber; beginners may struggle too, so this is trigered by difficulty.
- AI heroes don't switch leader to the hero past laboratory to equip
weapons from stash between the in-lab hero picks up the loot pile
and himself enters the decontamination chamber
- all consumables always end up in a pack and the whole pack
is always left behind, because consumables are not shared among
actors via shared stash (yet); we could pack consumables to stash
by default, but it's too confusing and risky for beginner players
and doesn't work for heroes that have not enough Calm ATM and AI
would still need to learn to spread consumables from stash to packs afterwards
- the items of the last actor would be lost anyway, unless AI
is taught the foolproof solution of this puzzle, which is yet a bit more
specific than the two general abilities described as desirable above
-}
       return UseUp
     | otherwise -> do
       unless (store == COrgan) execSfx
       mapM_ (uncurry (dropCStoreItem True store target tb kcopy))
             (take ngroup is)
       return UseUp

-- | Drop a single actor's item (though possibly multiple copies).
-- Note that if there are multiple copies, at most one explodes
-- to avoid excessive carnage and UI clutter (let's say,
-- the multiple explosions interfere with each other or perhaps
-- larger quantities of explosives tend to be packaged more safely).
-- Note also that @OnSmash@ effects are activated even if item discharged.
dropCStoreItem :: MonadServerAtomic m
               => Bool -> CStore -> ActorId -> Actor -> Int
               -> ItemId -> ItemQuant
               -> m ()
dropCStoreItem verbose store aid b kMax iid kit@(k, _) = do
  itemFull@ItemFull{itemBase} <- getsState $ itemToFull iid
  let arItem = aspectRecordFull itemFull
      c = CActor aid store
      fragile = IA.checkFlag Ability.Fragile arItem
      durable = IA.checkFlag Ability.Durable arItem
      isDestroyed = bproj b && (bhp b <= 0 && not durable || fragile)
                    || IA.checkFlag Ability.Condition arItem
  if isDestroyed then do
    let -- We don't know if it's voluntary,
        --so we conservatively assume it is and we blame @aid@.
        voluntary = True
        onSmashOnly = True
    effectAndDestroyAndAddKill
      voluntary aid onSmashOnly False aid aid iid c False (itemFull, kit)
    -- At most one copy was destroyed (or none if the item was discharged),
    -- so let's mop up.
    bag <- getsState $ getContainerBag c
    maybe (return ())
          (\(k1, it) ->
             let destroyedSoFar = k - k1
                 k2 = min (kMax - destroyedSoFar) k1
                 kit2 = (k2, take k2 it)
             in when (k2 > 0)
                $ execUpdAtomic $ UpdLoseItem False iid itemBase kit2 c)
          (EM.lookup iid bag)
  else do
    cDrop <- pickDroppable False aid b  -- drop over fog, etc.
    mvCmd <- generalMoveItem verbose iid (min kMax k) (CActor aid store) cDrop
    mapM_ execUpdAtomic mvCmd

pickDroppable :: MonadStateRead m => Bool -> ActorId -> Actor -> m Container
pickDroppable respectNoItem aid b = do
  cops@COps{coTileSpeedup} <- getsState scops
  lvl <- getLevel (blid b)
  let validTile t = not (respectNoItem && Tile.isNoItem coTileSpeedup t)
  if validTile $ lvl `at` bpos b
  then return $! CActor aid CGround
  else do
    let ps = nearbyFreePoints cops lvl validTile (bpos b)
    return $! case filter (adjacent $ bpos b) $ take 8 ps of
      [] -> CActor aid CGround  -- fallback; still correct, though not ideal
      pos : _ -> CFloor (blid b) pos

-- ** PolyItem

-- Can't apply to the item itself (any copies).
effectPolyItem :: MonadServerAtomic m
               => m () -> ItemId -> ActorId -> ActorId -> m UseResult
effectPolyItem execSfx iidId source target = do
  sb <- getsState $ getActorBody source
  let cstore = CGround
  kitAss <- getsState $ kitAssocs target [cstore]
  case filter ((/= iidId) . fst) kitAss of
    [] -> do
      execSfxAtomic $ SfxMsgFid (bfid sb) SfxPurposeNothing
      return UseId
    (iid, ( itemFull@ItemFull{itemBase, itemKindId, itemKind}
          , (itemK, itemTimer) )) : _ -> do
      let arItem = aspectRecordFull itemFull
          maxCount = Dice.supDice $ IK.icount itemKind
      if | IA.checkFlag Ability.Unique arItem -> do
           execSfxAtomic $ SfxMsgFid (bfid sb) SfxPurposeUnique
           return UseId
         | maybe True (<= 0) $ lookup "common item" $ IK.ifreq itemKind -> do
           execSfxAtomic $ SfxMsgFid (bfid sb) SfxPurposeNotCommon
           return UseId
         | itemK < maxCount -> do
           execSfxAtomic $ SfxMsgFid (bfid sb)
                         $ SfxPurposeTooFew maxCount itemK
           return UseId
         | otherwise -> do
           -- Only the required number of items is used up, not all of them.
           let c = CActor target cstore
               kit = (maxCount, take maxCount itemTimer)
           execSfx
           identifyIid iid c itemKindId
           execUpdAtomic $ UpdDestroyItem iid itemBase kit c
           effectCreateItem (Just $ bfid sb) Nothing
                            target cstore "common item" IK.timerNone

-- ** RerollItem

-- Can't apply to the item itself (any copies).
effectRerollItem :: MonadServerAtomic m
                 => m () -> ItemId -> ActorId -> ActorId -> m UseResult
effectRerollItem execSfx iidId source target = do
  COps{coItemSpeedup} <- getsState scops
  sb <- getsState $ getActorBody source
  let cstore = CGround  -- if ever changed, call @discoverIfMinorEffects@
  kitAss <- getsState $ kitAssocs target [cstore]
  case filter ((/= iidId) . fst) kitAss of
    [] -> do
      execSfxAtomic $ SfxMsgFid (bfid sb) SfxRerollNothing
      return UseId
    (iid, ( ItemFull{itemBase, itemKindId, itemKind}
          , kit )) : _ ->
      if | IA.kmConst $ IA.getKindMean itemKindId coItemSpeedup -> do
           execSfxAtomic $ SfxMsgFid (bfid sb) SfxRerollNotRandom
           return UseId
         | otherwise -> do
           let c = CActor target cstore
               freq = pure (itemKindId, itemKind)
           execSfx
           identifyIid iid c itemKindId
           execUpdAtomic $ UpdDestroyItem iid itemBase kit c
           dungeon <- getsState sdungeon
           let maxLid = fst $ maximumBy (Ord.comparing (ldepth . snd))
                            $ EM.assocs dungeon
           m2 <- rollItemAspect freq maxLid
           case m2 of
             Nothing -> error "effectRerollItem: can't create rerolled item"
             Just (itemKnown, (itemFull, _)) -> do
               void $ registerItem (itemFull, kit) itemKnown c True
               return UseUp

-- ** DupItem

-- Can't apply to the item itself (any copies).
effectDupItem :: MonadServerAtomic m
              => m () -> ItemId -> ActorId -> ActorId -> m UseResult
effectDupItem execSfx iidId source target = do
  sb <- getsState $ getActorBody source
  let cstore = CGround  -- beware of other options, e.g., creating in eqp
                        -- and not setting timeout to a random value
  kitAss <- getsState $ kitAssocs target [cstore]
  case filter ((/= iidId) . fst) kitAss of
    [] -> do
      execSfxAtomic $ SfxMsgFid (bfid sb) SfxDupNothing
      return UseId
    (iid, ( itemFull@ItemFull{itemBase, itemKindId, itemKind}
          , _ )) : _ -> do
      let arItem = aspectRecordFull itemFull
      if | IA.checkFlag Ability.Unique arItem -> do
           execSfxAtomic $ SfxMsgFid (bfid sb) SfxDupUnique
           return UseId
         | maybe False (> 0) $ lookup "valuable" $ IK.ifreq itemKind -> do
           execSfxAtomic $ SfxMsgFid (bfid sb) SfxDupValuable
           return UseId
         | otherwise -> do
           let c = CActor target cstore
           execSfx
           identifyIid iid c itemKindId
           execUpdAtomic $ UpdCreateItem iid itemBase (1, []) c
           return UseUp

-- ** Identify

effectIdentify :: MonadServerAtomic m
               => m () -> ItemId -> ActorId -> ActorId -> m UseResult
effectIdentify execSfx iidId source target = do
  COps{coItemSpeedup} <- getsState scops
  discoAspect <- getsState sdiscoAspect
  sb <- getsState $ getActorBody source
  s <- getsServer $ (EM.! bfid sb) . sclientStates
  let tryFull store as = case as of
        [] -> return False
        (iid, _) : rest | iid == iidId -> tryFull store rest  -- don't id itself
        (iid, ItemFull{itemBase, itemKindId, itemKind}) : rest -> do
          let arItem = discoAspect EM.! iid
              kindIsKnown = case jkind itemBase of
                IdentityObvious _ -> True
                IdentityCovered ix _ -> ix `EM.member` sdiscoKind s
          if iid `EM.member` sdiscoAspect s  -- already fully identified
             || IA.isHumanTrinket itemKind  -- hack; keep them non-identified
             || store == CGround && IA.onlyMinorEffects arItem itemKind
               -- will be identified when picked up, so don't bother
             || IA.kmConst (IA.getKindMean itemKindId coItemSpeedup)
                && kindIsKnown
               -- constant aspects and known kind; no need to identify further
          then tryFull store rest
          else do
            let c = CActor target store
            execSfx
            identifyIid iid c itemKindId
            return True
      tryStore stores = case stores of
        [] -> do
          execSfxAtomic $ SfxMsgFid (bfid sb) SfxIdentifyNothing
          return UseId  -- the message tells it's ID effect
        store : rest -> do
          allAssocs <- getsState $ fullAssocs target [store]
          go <- tryFull store allAssocs
          if go then return UseUp else tryStore rest
  tryStore [CGround, CEqp, CInv, CSha]

identifyIid :: MonadServerAtomic m
            => ItemId -> Container -> ContentId ItemKind -> m ()
identifyIid iid c itemKindId = do
  discoAspect <- getsState sdiscoAspect
  execUpdAtomic $ UpdDiscover c iid itemKindId $ discoAspect EM.! iid

-- ** Detect

effectDetect :: MonadServerAtomic m
             => m () -> IK.DetectKind -> Int -> ActorId -> Point -> m UseResult
effectDetect execSfx d radius target pos = do
  COps{coitem, coTileSpeedup} <- getsState scops
  b <- getsState $ getActorBody target
  lvl <- getLevel $ blid b
  s <- getState
  let lootPredicate p =
        p `EM.member` lfloor lvl
        || (case posToBigAssoc p (blid b) s of
              Nothing -> False
              Just (_, body) ->
                not (EM.null (beqp body) && EM.null (binv body)))
                  -- shared stash ignored, because hard to get
        || any embedHasLoot (EM.keys $ getEmbedBag (blid b) p s)
      embedHasLoot iid =
        let itemFull = itemToFull iid s
            IK.ItemKind{IK.ieffects} = itemKind itemFull
        in any effectHasLoot ieffects
      reported acc _ _ itemKind =
        acc && isNothing (lookup "unreported inventory" $ IK.ifreq itemKind)
      effectHasLoot (IK.CreateItem cstore grp _) =
        cstore `elem` [CGround, CEqp, CInv, CSha]
        && ofoldlGroup' coitem grp reported True
      effectHasLoot IK.PolyItem = True
      effectHasLoot IK.RerollItem = True
      effectHasLoot IK.DupItem = True
      effectHasLoot (IK.OneOf l) = any effectHasLoot l
      effectHasLoot (IK.OnSmash eff) = effectHasLoot eff
      effectHasLoot (IK.Composite l) = any effectHasLoot l
      effectHasLoot _ = False
      (predicate, action) = case d of
        IK.DetectAll -> (const True, const $ return False)
        IK.DetectActor -> ((`EM.member` lbig lvl), const $ return False)
        IK.DetectLoot -> (lootPredicate, const $ return False)
        IK.DetectExit ->
          let (ls1, ls2) = lstair lvl
          in ((`elem` ls1 ++ ls2 ++ lescape lvl), const $ return False)
        IK.DetectHidden ->
          let predicateH p = Tile.isHideAs coTileSpeedup $ lvl `at` p
              revealEmbed p = do
                embeds <- getsState $ getEmbedBag (blid b) p
                unless (EM.null embeds) $ do
                  let ais = map (\iid -> (iid, getItemBody iid s))
                                (EM.keys embeds)
                  execUpdAtomic $ UpdSpotItemBag (CEmbed (blid b) p) embeds ais
              actionH l = do
                let f p = when (p /= pos) $ do
                      let t = lvl `at` p
                      execUpdAtomic $ UpdSearchTile target p t
                      -- This is safe searching; embedded items
                      -- are not triggered, but they are revealed.
                      revealEmbed p
                      case EM.lookup p $ lentry lvl of
                        Nothing -> return ()
                        Just entry ->
                          execUpdAtomic $ UpdSpotEntry (blid b) [(p, entry)]
                mapM_ f l
                return $! not $ null l
          in (predicateH, actionH)
        IK.DetectEmbed -> ((`EM.member` lembed lvl), const $ return False)
  effectDetectX d predicate action execSfx radius target

effectDetectX :: MonadServerAtomic m
              => IK.DetectKind -> (Point -> Bool) -> ([Point] -> m Bool)
              -> m () -> Int -> ActorId -> m UseResult
effectDetectX d predicate action execSfx radius target = do
  COps{corule=RuleContent{rXmax, rYmax}} <- getsState scops
  b <- getsState $ getActorBody target
  sperFidOld <- getsServer sperFid
  let perOld = sperFidOld EM.! bfid b EM.! blid b
      Point x0 y0 = bpos b
      perList = filter predicate
        [ Point x y
        | y <- [max 0 (y0 - radius) .. min (rYmax - 1) (y0 + radius)]
        , x <- [max 0 (x0 - radius) .. min (rXmax - 1) (x0 + radius)]
        ]
      extraPer = emptyPer {psight = PerVisible $ ES.fromDistinctAscList perList}
      inPer = diffPer extraPer perOld
  unless (nullPer inPer) $ do
    -- Perception is modified on the server and sent to the client
    -- together with all the revealed info.
    let perNew = addPer inPer perOld
        fper = EM.adjust (EM.insert (blid b) perNew) (bfid b)
    modifyServer $ \ser -> ser {sperFid = fper $ sperFid ser}
    execSendPer (bfid b) (blid b) emptyPer inPer perNew
  pointsModified <- action perList
  if not (nullPer inPer) || pointsModified then do
    execSfx
    -- Perception is reverted. This is necessary to ensure save and restore
    -- doesn't change game state.
    unless (nullPer inPer) $ do
      modifyServer $ \ser -> ser {sperFid = sperFidOld}
      execSendPer (bfid b) (blid b) inPer emptyPer perOld
  else
    execSfxAtomic $ SfxMsgFid (bfid b) $ SfxVoidDetection d
  return UseUp  -- even if nothing spotted, in itself it's still useful data

-- ** SendFlying

-- | Send the target actor flying like a projectile. If the actors are adjacent,
-- the vector is directed outwards, if no, inwards, if it's the same actor,
-- boldpos is used, if it can't, a random outward vector of length 10
-- is picked.
effectSendFlying :: MonadServerAtomic m
                 => m () -> IK.ThrowMod -> ActorId -> ActorId -> Container
                 -> Maybe Bool
                 -> m UseResult
effectSendFlying execSfx IK.ThrowMod{..} source target c modePush = do
  v <- sendFlyingVector source target modePush
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  let eps = 0
      fpos = bpos tb `shift` v
      isEmbed = case c of
        CEmbed{} -> True
        _ -> False
  if bhp tb <= 0  -- avoid dragging around corpses
     || bproj tb && isEmbed then  -- fyling projectiles can't slip on the floor
    return UseDud  -- the impact never manifested
  else if actorWaits tb && isNothing (btrajectory tb) then do
    execSfxAtomic $ SfxMsgFid (bfid sb) $ SfxBracedImmune target
    return UseUp  -- waste it to prevent repeated throwing at immobile actors
  else do
   COps{corule=RuleContent{rXmax, rYmax}} <- getsState scops
   case bla rXmax rYmax eps (bpos tb) fpos of
    Nothing -> error $ "" `showFailure` (fpos, tb)
    Just [] -> error $ "projecting from the edge of level"
                       `showFailure` (fpos, tb)
    Just (pos : rest) -> do
      weightAssocs <- getsState $ fullAssocs target [CInv, CEqp, COrgan]
      let weight = sum $ map (IK.iweight . itemKind . snd) weightAssocs
          path = bpos tb : pos : rest
          (trajectory, (speed, _)) =
            -- Note that the @ThrowMod@ aspect of the actor's trunk is ignored.
            computeTrajectory weight throwVelocity throwLinger path
          ts = Just (trajectory, speed)
      if null trajectory
      then return UseId  -- e.g., actor is too heavy; but a jerk is noticeable
      else do
        execSfx
        -- Old and new trajectories are not added; the old one is replaced.
        unless (btrajectory tb == ts) $
          execUpdAtomic $ UpdTrajectory target (btrajectory tb) ts
        -- If propeller is a projectile, it pushes involuntarily,
        -- so its originator is to blame.
        -- However, we can't easily see whether a pushed non-projectile actor
        -- pushed another due to colliding or voluntarily, so we assign
        -- blame to him.
        originator <- if bproj sb
                      then getsServer $ EM.findWithDefault source source
                                        . strajPushedBy
                      else return source
        modifyServer $ \ser ->
          ser {strajPushedBy = EM.insert target originator $ strajPushedBy ser}
        -- In case of pre-existing pushing, don't touch the time
        -- so that the pending @advanceTimeTraj@ can do its job
        -- (it will, because non-empty trajectory is here set, unless, e.g.,
        -- subsequent effects from the same item change the trajectory).
        when (isNothing $ btrajectory tb) $ do
          -- Set flying time to almost now, so that the push happens ASAP,
          -- because it's the first one, so almost no delay is needed.
          localTime <- getsState $ getLocalTime (blid tb)
          -- But add a slight overhead to avoid displace-slide loops
          -- of 3 actors in a line.
          let overheadTime = timeShift localTime (Delta timeClip)
          modifyServer $ \ser ->
            ser {strajTime =
                   updateActorTime (bfid tb) (blid tb) target overheadTime
                   $ strajTime ser}
        return UseUp

sendFlyingVector :: MonadServerAtomic m
                 => ActorId -> ActorId -> Maybe Bool -> m Vector
sendFlyingVector source target modePush = do
  sb <- getsState $ getActorBody source
  let boldpos_sb = fromMaybe (bpos sb) (boldpos sb)
  if source == target then
    if boldpos_sb == bpos sb then rndToAction $ do
      z <- randomR (-10, 10)
      oneOf [Vector 10 z, Vector (-10) z, Vector z 10, Vector z (-10)]
    else
      return $! vectorToFrom (bpos sb) boldpos_sb
  else do
    tb <- getsState $ getActorBody target
    let pushV = vectorToFrom (bpos tb) (bpos sb)
        pullV = vectorToFrom (bpos sb) (bpos tb)
    return $! case modePush of
                Just True -> pushV
                Just False -> pullV
                Nothing | adjacent (bpos sb) (bpos tb) -> pushV
                Nothing -> pullV

-- ** DropBestWeapon

-- | Make the target actor drop his best weapon (stack).
-- The item itself is immune (any copies).
effectDropBestWeapon :: MonadServerAtomic m
                     => m () -> ItemId -> ActorId -> m UseResult
effectDropBestWeapon execSfx iidId target = do
  tb <- getsState $ getActorBody target
  if bproj tb then return UseDud else do
    localTime <- getsState $ getLocalTime (blid tb)
    kitAssRaw <- getsState $ kitAssocs target [CEqp]
    let kitAss = filter (\(iid, (i, _)) ->
                          IA.checkFlag Ability.Meleeable (aspectRecordFull i)
                          && iid /= iidId) kitAssRaw
    case strongestMelee Nothing localTime kitAss of
      (_, (iid, _)) : _ -> do
        execSfx
        let kit = beqp tb EM.! iid
        dropCStoreItem True CEqp target tb 1 iid kit  -- not the whole stack
        return UseUp
      [] ->
        return UseDud

-- ** ActivateInv

-- | Activate all items with the given symbol
-- in the target actor's equipment (there's no variant that activates
-- a random one, to avoid the incentive for carrying garbage).
-- Only one item of each stack is activated (and possibly consumed).
-- Won't activate the item itself (any copies).
effectActivateInv :: MonadServerAtomic m
                  => m () -> ItemId -> ActorId -> ActorId -> Char -> m UseResult
effectActivateInv execSfx iidId source target symbol = do
  let c = CActor target CInv
  effectTransformContainer execSfx iidId symbol c $ \iid _ ->
    -- We don't know if it's voluntary, so we conservatively assume it is
    -- and we blame @source@.
    kineticEffectAndDestroy True source target target iid c

effectTransformContainer :: forall m. MonadServerAtomic m
                         => m () -> ItemId -> Char -> Container
                         -> (ItemId -> ItemQuant -> m ())
                         -> m UseResult
effectTransformContainer execSfx iidId symbol c m = do
  getKind <- getsState $ flip getIidKindServer
  let hasSymbol (iid, _kit) = do
        let jsymbol = IK.isymbol $ getKind iid
        return $! jsymbol == symbol
  assocsCStore <- getsState $ EM.assocs . getContainerBag c
  is <- filter ((/= iidId) . fst) <$> if symbol == ' '
                                      then return assocsCStore
                                      else filterM hasSymbol assocsCStore
  if null is
  then return UseDud
  else do
    execSfx
    mapM_ (uncurry m) is
    -- Even if no item produced any visible effect, rummaging through
    -- the inventory uses up the effect and produced discernible vibrations.
    return UseUp

-- ** ApplyPerfume

effectApplyPerfume :: MonadServerAtomic m => m () -> ActorId -> m UseResult
effectApplyPerfume execSfx target = do
  tb <- getsState $ getActorBody target
  Level{lsmell} <- getLevel $ blid tb
  unless (EM.null lsmell) $ do
    execSfx
    let f p fromSm = execUpdAtomic $ UpdAlterSmell (blid tb) p fromSm timeZero
    mapWithKeyM_ f lsmell
  return UseUp  -- even if no smell before, the perfume is noticeable

-- ** OneOf

effectOneOf :: MonadServerAtomic m
            => (IK.Effect -> m UseResult) -> [IK.Effect] -> m UseResult
effectOneOf recursiveCall l = do
  let call1 = do
        ef <- rndToAction $ oneOf l
        recursiveCall ef
      call99 = replicate 99 call1
      f call result = do
        ur <- call
        -- We avoid 99 calls to a fizzling effect that only prints
        -- a failure message and IDs the item.
        if ur == UseDud then result else return ur
  foldr f (return UseDud) call99
  -- no @execSfx@, because individual effects sent them

-- ** VerbMsg

effectVerbMsg :: MonadServerAtomic m
              => m () -> ActorId -> ItemId -> Container -> m UseResult
effectVerbMsg execSfx source iid c = do
  b <- getsState $ getActorBody source
  itemFull <- getsState $ itemToFull iid
  let arItem = aspectRecordFull itemFull
      fragile = IA.checkFlag Ability.Fragile arItem
  unless (bproj b) $ do  -- don't spam when projectiles activate
    if fragile
    then do
      bag <- getsState $ getContainerBag c
      case iid `EM.lookup` bag of
        Just _ -> return ()  -- still some copies left
        Nothing -> execSfx  -- last copy just destroyed
    else execSfx
  return UseUp  -- speaking always successful; also needed to destroy conditions

-- ** Composite

effectComposite :: forall m. MonadServerAtomic m
                => (IK.Effect -> m UseResult) -> [IK.Effect] -> m UseResult
effectComposite recursiveCall l = do
  let f :: IK.Effect -> m UseResult -> m UseResult
      f eff result = do
        ur <- recursiveCall eff
        when (ur == UseUp) $ void result  -- UseResult comes from the first
        return ur
  foldr f (return UseDud) l
  -- no @execSfx@, because individual effects sent them
