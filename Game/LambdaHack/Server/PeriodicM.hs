-- | Server operations performed periodically in the game loop
-- and related operations.
module Game.LambdaHack.Server.PeriodicM
  ( spawnMonster, addAnyActor, dominateFidSfx
  , advanceTime, overheadActorTime, swapTime
  , leadLevelSwitch, udpateCalm
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.Int (Int64)

import Game.LambdaHack.Atomic
import qualified Game.LambdaHack.Common.Ability as Ability
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Frequency
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Perception
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Content.ItemKind (ItemKind)
import qualified Game.LambdaHack.Content.ItemKind as IK
import Game.LambdaHack.Content.ModeKind
import qualified Game.LambdaHack.Content.TileKind as TK
import Game.LambdaHack.Server.CommonM
import Game.LambdaHack.Server.ItemM
import Game.LambdaHack.Server.MonadServer
import Game.LambdaHack.Server.State

-- TODO: civilians would have 'it' pronoun
-- | Spawn, possibly, a monster according to the level's actor groups.
-- We assume heroes are never spawned.
spawnMonster :: (MonadAtomic m, MonadServer m) => m ()
spawnMonster = do
  arenas <- getsServer sarenas
  -- Do this on only one of the arenas to prevent micromanagement,
  -- e.g., spreading leaders across levels to bump monster generation.
  arena <- rndToAction $ oneOf arenas
  totalDepth <- getsState stotalDepth
  -- TODO: eliminate the defeated and victorious faction from lactorFreq;
  -- then fcanEscape and fneverEmpty make sense for spawning factions
  Level{ldepth, lactorCoeff, lactorFreq} <- getLevel arena
  lvlSpawned <- getsServer $ fromMaybe 0 . EM.lookup arena . snumSpawned
  rc <- rndToAction
        $ monsterGenChance ldepth totalDepth lvlSpawned lactorCoeff
  when rc $ do
    modifyServer $ \ser ->
      ser {snumSpawned = EM.insert arena (lvlSpawned + 1) $ snumSpawned ser}
    localTime <- getsState $ getLocalTime arena
    maid <- addAnyActor lactorFreq arena localTime Nothing
    case maid of
      Nothing -> return ()
      Just aid -> do
        b <- getsState $ getActorBody aid
        mleader <- getsState $ gleader . (EM.! bfid b) . sfactionD
        when (isNothing mleader) $ supplantLeader (bfid b) aid

addAnyActor :: (MonadAtomic m, MonadServer m)
            => Freqs ItemKind -> LevelId -> Time -> Maybe Point
            -> m (Maybe ActorId)
addAnyActor actorFreq lid time mpos = do
  -- We bootstrap the actor by first creating the trunk of the actor's body
  -- contains the constant properties.
  cops <- getsState scops
  lvl <- getLevel lid
  factionD <- getsState sfactionD
  lvlSpawned <- getsServer $ fromMaybe 0 . EM.lookup lid . snumSpawned
  m4 <- rollItem lvlSpawned lid actorFreq
  case m4 of
    Nothing -> return Nothing
    Just (itemKnown, trunkFull, itemDisco, seed, _) -> do
      let ik = itemKind itemDisco
          freqNames = map fst $ IK.ifreq ik
          f fact = fgroup (gplayer fact)
          factNames = map f $ EM.elems factionD
          fidName = case freqNames `intersect` factNames of
            [] -> head factNames  -- fall back to an arbitrary faction
            fName : _ -> fName
          g (_, fact) = fgroup (gplayer fact) == fidName
          mfid = find g $ EM.assocs factionD
          fid = fst $ fromMaybe (assert `failure` (factionD, fidName)) mfid
      pers <- getsServer sperFid
      let allPers = ES.unions $ map (totalVisible . (EM.! lid))
                    $ EM.elems $ EM.delete fid pers  -- expensive :(
          mobile = any (`elem` freqNames) ["mobile", "horror"]
      pos <- case mpos of
        Just pos -> return pos
        Nothing -> do
          fact <- getsState $ (EM.! fid) . sfactionD
          rollPos <- getsState $ rollSpawnPos cops allPers mobile lid lvl fact
          rndToAction rollPos
      let container = CTrunk fid lid pos
      trunkId <- registerItem trunkFull itemKnown seed container False
      addActorIid trunkId trunkFull False fid pos lid id "it" time

rollSpawnPos :: Kind.COps -> ES.EnumSet Point
             -> Bool -> LevelId -> Level -> Faction -> State
             -> Rnd Point
rollSpawnPos Kind.COps{coTileSpeedup} visible
             mobile lid lvl@Level{ltile, lxsize, lysize} fact s = do
  let inhabitants = actorRegularList (isAtWar fact) lid s
      distantSo df p _ = all (\b -> df $ chessDist (bpos b) p) inhabitants
      middlePos = Point (lxsize `div` 2) (lysize `div` 2)
      distantMiddle d p _ = chessDist p middlePos < d
      condList | mobile =
        [ distantSo (<= 10)  -- try hard to harass enemies
        , distantSo (<= 15)
        , distantSo (<= 20)
        ]
               | otherwise =
        [ distantMiddle 5
        , distantMiddle 10
        , distantMiddle 20
        , distantMiddle 50
        , distantMiddle 100
        ]
  -- Not considering TK.OftenActor, because monsters emerge from hidden ducts,
  -- which are easier to hide in crampy corridors that lit halls.
  findPosTry2 (if mobile then 500 else 100) ltile
    ( \p t -> Tile.isWalkable coTileSpeedup t
              && not (Tile.isNoActor coTileSpeedup t)
              && null (posToAidsLvl p lvl))
    condList
    (\p t -> distantSo (> 4) p t  -- otherwise actors in dark rooms swarmed
             && not (p `ES.member` visible))  -- visibility and plausibility
    [ \p t -> distantSo (> 3) p t
              && not (p `ES.member` visible)
    , \p t -> distantSo (> 2) p t -- otherwise actors hit on entering level
              && not (p `ES.member` visible)
    , \p _ -> not (p `ES.member` visible)
    ]

dominateFidSfx :: (MonadAtomic m, MonadServer m)
               => FactionId -> ActorId -> m Bool
dominateFidSfx fid target = do
  tb <- getsState $ getActorBody target
  -- Actors that don't move freely can't be dominated, for otherwise,
  -- when they are the last survivors, they could get stuck
  -- and the game wouldn't end.
  actorAspect <- getsServer sactorAspect
  let ar = actorAspect EM.! target
      actorMaxSk = aSkills ar
      -- Check that the actor can move, also between levels and through doors.
      -- Otherwise, it's too awkward for human player to control.
      canMove = EM.findWithDefault 0 Ability.AbMove actorMaxSk > 0
                && EM.findWithDefault 0 Ability.AbAlter actorMaxSk
                   >= fromEnum TK.talterForStairs
  if canMove && not (bproj tb) then do
    let execSfx = execSfxAtomic $ SfxEffect fid target IK.Dominate 0
    execSfx
    dominateFid fid target
    execSfx
    return True
  else
    return False

dominateFid :: (MonadAtomic m, MonadServer m) => FactionId -> ActorId -> m ()
dominateFid fid target = do
  Kind.COps{coitem=Kind.Ops{okind}, cotile} <- getsState scops
  tb0 <- getsState $ getActorBody target
  deduceKilled target  -- the actor body exists and his items are not dropped
  -- TODO: some messages after game over below? Compare with dieSer.
  electLeader (bfid tb0) (blid tb0) target
  fact <- getsState $ (EM.! bfid tb0) . sfactionD
  -- Prevent the faction's stash from being lost in case they are not spawners.
  when (isNothing $ gleader fact) $ moveStores False target CSha CInv
  tb <- getsState $ getActorBody target
  ais <- getsState $ getCarriedAssocs tb
  actorAspect <- getsServer sactorAspect
  getItem <- getsState $ flip getItemBody
  discoKind <- getsServer sdiscoKind
  let ar = actorAspect EM.! target
      isImpression iid = case EM.lookup (jkindIx $ getItem iid) discoKind of
        Just KindMean{kmKind} ->
          let grp = "impressed"
          in maybe False (> 0) $ lookup grp $ IK.ifreq (okind kmKind)
        Nothing -> assert `failure` iid
      dropAllImpressions = EM.filterWithKey (\iid _ -> not $ isImpression iid)
      addImpression bag = do  -- add some nostalgia for old faction
        let grp = toGroupName $ "impressed by" <+> gname fact
            litemFreq = [(grp, 1)]
        m5 <- rollItem 0 (blid tb) litemFreq
        let (itemKnown, itemFull, _, seed, _) =
              fromMaybe (assert `failure` (blid tb, litemFreq)) m5
        iid <- onlyRegisterItem itemFull itemKnown seed
        return $! EM.insert iid (1, []) bag
      borganNoImpression = dropAllImpressions $ borgan tb
  borgan <- addImpression borganNoImpression
  btime <-
    getsServer $ (EM.! target) . (EM.! blid tb) . (EM.! bfid tb) . sactorTime
  execUpdAtomic $ UpdLoseActor target tb ais
  let bNew = tb { bfid = fid
                , bcalm = max 0 $ xM (aMaxCalm ar) `div` 2
                , borgan}
  execUpdAtomic $ UpdSpotActor target bNew ais
  modifyServer $ \ser ->
    ser {sactorTime = updateActorTime fid (blid tb) target btime
                      $ sactorTime ser}
  let discoverSeed (iid, cstore) = do
        seed <- getsServer $ (EM.! iid) . sitemSeedD
        let c = CActor target cstore
        execUpdAtomic $ UpdDiscoverSeed c iid seed
      aic = getCarriedIidCStore tb
  mapM_ discoverSeed aic
  mleaderOld <- getsState $ gleader . (EM.! fid) . sfactionD
  -- Keep the leader if he is on stairs. We don't want to clog stairs.
  keepLeader <- case mleaderOld of
    Nothing -> return False
    Just leaderOld -> do
      body <- getsState $ getActorBody leaderOld
      lvl <- getLevel $ blid body
      return $! Tile.isStair cotile $ lvl `at` bpos body
  unless keepLeader $
    -- Focus on the dominated actor, by making him a leader.
    supplantLeader fid target

-- | Advance the move time for the given actor
advanceTime :: (MonadAtomic m, MonadServer m) => ActorId -> Int -> m ()
advanceTime aid percent = do
  b <- getsState $ getActorBody aid
  actorAspect <- getsServer sactorAspect
  let ar = actorAspect EM.! aid
      t = timeDeltaPercent (ticksPerMeter $ bspeed b ar) percent
  -- @t@ may be negative; that's OK.
  modifyServer $ \ser ->
    ser {sactorTime = ageActor (bfid b) (blid b) aid t $ sactorTime ser}

-- Add communication overhead time delta to all non-projectile, non-dying
-- faction's actors (except the leader). Effectively, this limits moves of
-- a faction to 10, regardless of the number of actors and their speeds.
-- To discourage micromanagement distributing actors among active arenas,
-- overhead applies to all actors in active arenas.
--
-- Leader is immune from overhead and so he is faster than other faction
-- members and of equal speed to leaders of other factions (of equal
-- base speed) regardless how numerous the faction is.
-- Thanks to this, there is no problem with leader of a numerous faction
-- having very long UI turns, introducing UI lag.
overheadActorTime :: (MonadAtomic m, MonadServer m) => FactionId -> m ()
overheadActorTime fid = do
  actorTime <- getsServer $ (EM.! fid) . sactorTime
  s <- getState
  mleader <- getsState $ gleader . (EM.! fid) . sfactionD
  arenas <- getsServer sarenas
  let f !aid !time =
        let body = getActorBody aid s
        in if isNothing (btrajectory body)
              && bhp body > 0
              && Just aid /= mleader  -- leader fast, for UI to be fast
           then timeShift time (Delta timeClip)
           else time
      g !acc !lid = EM.adjust (EM.mapWithKey f) lid acc
      actorTimeNew = foldl' g actorTime arenas
  modifyServer $ \ser ->
    ser {sactorTime = EM.insert fid actorTimeNew $ sactorTime ser}

-- | Swap the relative move times of two actors (e.g., when switching
-- a UI leader).
swapTime :: (MonadAtomic m, MonadServer m) => ActorId -> ActorId -> m ()
swapTime source target = do
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  slvl <- getsState $ getLocalTime (blid sb)
  tlvl <- getsState $ getLocalTime (blid tb)
  btime_sb <- getsServer $ (EM.! source) . (EM.! blid sb) . (EM.! bfid sb) . sactorTime
  btime_tb <- getsServer $ (EM.! target) . (EM.! blid tb) . (EM.! bfid tb) . sactorTime
  let lvlDelta = slvl `timeDeltaToFrom` tlvl
      bDelta = btime_sb `timeDeltaToFrom` btime_tb
      sdelta = timeDeltaSubtract lvlDelta bDelta
      tdelta = timeDeltaReverse sdelta
  -- Equivalent, for the assert:
  let !_A = let sbodyDelta = btime_sb `timeDeltaToFrom` slvl
                tbodyDelta = btime_tb `timeDeltaToFrom` tlvl
                sgoal = slvl `timeShift` tbodyDelta
                tgoal = tlvl `timeShift` sbodyDelta
                sdelta' = sgoal `timeDeltaToFrom` btime_sb
                tdelta' = tgoal `timeDeltaToFrom` btime_tb
            in assert (sdelta == sdelta' && tdelta == tdelta'
                       `blame` ( slvl, tlvl, btime_sb, btime_tb
                               , sdelta, sdelta', tdelta, tdelta' )) ()
  when (sdelta /= Delta timeZero) $ modifyServer $ \ser ->
    ser {sactorTime = ageActor (bfid sb) (blid sb) source sdelta $ sactorTime ser}
  when (tdelta /= Delta timeZero) $ modifyServer $ \ser ->
    ser {sactorTime = ageActor (bfid tb) (blid tb) target tdelta $ sactorTime ser}

udpateCalm :: (MonadAtomic m, MonadServer m) => ActorId -> Int64 -> m ()
udpateCalm target deltaCalm = do
  tb <- getsState $ getActorBody target
  actorAspect <- getsServer sactorAspect
  let ar = actorAspect EM.! target
      calmMax64 = xM $ aMaxCalm ar
  execUpdAtomic $ UpdRefillCalm target deltaCalm
  when (bcalm tb < calmMax64
        && bcalm tb + deltaCalm >= calmMax64) $
    return ()  -- TODO: reset some mental afflictions, fears, when we have any

leadLevelSwitch :: (MonadAtomic m, MonadServer m) => m ()
leadLevelSwitch = do
  Kind.COps{cotile} <- getsState scops
  let canSwitch fact = fst (autoDungeonLevel fact)
                       -- a hack to help AI, until AI client can switch levels
                       || case fleaderMode (gplayer fact) of
                            LeaderNull -> False
                            LeaderAI _ -> True
                            LeaderUI _ -> False
      flipFaction fact | not $ canSwitch fact = return ()
      flipFaction fact =
        case gleader fact of
          Nothing -> return ()
          Just leader -> do
            body <- getsState $ getActorBody leader
            lvl2 <- getLevel $ blid body
            let leaderStuck = waitedLastTurn body
                t = lvl2 `at` bpos body
            -- Keep the leader: he is on stairs and not stuck
            -- and we don't want to clog stairs or get pushed to another level.
            unless (not leaderStuck && Tile.isStair cotile t) $ do
              s <- getState
              let ourLvl (lid, lvl) =
                    ( lid
                    , EM.size (lfloor lvl)
                    , -- Drama levels skipped, hence @Regular@.
                      actorRegularIds (== bfid body) lid s )
              ours <- getsState $ map ourLvl . EM.assocs . sdungeon
              -- Non-humans, being born in the dungeon, have a rough idea of
              -- the number of items left on the level and will focus
              -- on levels they started exploring and that have few items
              -- left. This is to to explore them completely, leave them
              -- once and for all and concentrate forces on another level.
              -- In addition, sole stranded actors tend to become leaders
              -- so that they can join the main force ASAP.
              let freqList = [ (k, (lid, a))
                             | (lid, itemN, a : rest) <- ours
                             , not leaderStuck || lid /= blid body
                             , let len = 1 + min 10 (length rest)
                                   k = 1000000 `div` (3 * itemN + len) ]
              unless (null freqList) $ do
                (lid, a) <- rndToAction $ frequency
                                        $ toFreq "leadLevel" freqList
                unless (lid == blid body) $  -- flip levels rather than actors
                  supplantLeader (bfid body) a
  factionD <- getsState sfactionD
  mapM_ flipFaction $ EM.elems factionD
