-- | The monad for writing to the main game state.
module Game.LambdaHack.Atomic.MonadStateWrite
  ( MonadStateWrite(..), AtomicFail(..), atomicFail
  , updateLevel, updateActor, updateFaction
  , moveActorMap, swapActorMap
  , insertBagContainer, insertItemContainer, insertItemActor
  , deleteBagContainer, deleteItemContainer, deleteItemActor
  , addAis, itemsMatch, addItemToActorMaxSkills, resetActorMaxSkills
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , insertItemFloor, insertItemEmbed
  , insertItemOrgan, insertItemEqp, insertItemInv, insertItemSha
  , deleteItemFloor, deleteItemEmbed
  , deleteItemOrgan, deleteItemEqp, deleteItemInv, deleteItemSha
  , rmFromBag
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Control.Exception as Ex
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import           Data.Key (mapWithKeyM_)

import qualified Game.LambdaHack.Common.Ability as Ability
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.Container
import           Game.LambdaHack.Common.Defs
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Level
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.Point
import           Game.LambdaHack.Common.State
import           Game.LambdaHack.Common.Types

-- | The monad for writing to the main game state. Atomic updates ('UpdAtomic')
-- are given semantics in this monad.
class MonadStateRead m => MonadStateWrite m where
  modifyState :: (State -> State) -> m ()
  putState :: State -> m ()

-- | Exception signifying that atomic action failed because
-- the information it carries is inconsistent with the client's state,
-- (e.g., because the client knows too little to understand the command
-- or already deduced the state change from earlier commands
-- or is confused, amnesiac or sees illusory actors or tiles).
-- Whenever we know the failure is logically impossible,
-- we don't throw the @AtomicFail@ exception, but insert a normal assertion
-- or @error@ call, which are never caught nor handled.
newtype AtomicFail = AtomicFail String
  deriving Show

instance Ex.Exception AtomicFail

atomicFail :: String -> a
atomicFail = Ex.throw . AtomicFail

-- INLIning offers no speedup, increases alloc and binary size.
-- EM.alter not necessary, because levels not removed, so little risk
-- of adjusting at absent index.
updateLevel :: MonadStateWrite m => LevelId -> (Level -> Level) -> m ()
updateLevel lid f = modifyState $ updateDungeon $ EM.adjust f lid

-- INLIning doesn't help despite probably canceling the alt indirection.
-- perhaps it's applied automatically due to INLINABLE.
updateActor :: MonadStateWrite m => ActorId -> (Actor -> Actor) -> m ()
updateActor aid f = do
  let alt Nothing = error $ "no body to update" `showFailure` aid
      alt (Just b) = Just $ f b
  modifyState $ updateActorD $ EM.alter alt aid

updateFaction :: MonadStateWrite m => FactionId -> (Faction -> Faction) -> m ()
updateFaction fid f = do
  let alt Nothing = error $ "no faction to update" `showFailure` fid
      alt (Just fact) = Just $ f fact
  modifyState $ updateFactionD $ EM.alter alt fid

moveActorMap :: MonadStateWrite m => ActorId -> Actor -> Actor -> m ()
moveActorMap aid body newBody = do
  let rmBig Nothing = error $ "actor already removed"
                              `showFailure` (aid, body)
      rmBig (Just _aid2) =
#ifdef WITH_EXPENSIVE_ASSERTIONS
        assert (aid == _aid2 `blame` "actor already removed"
                             `swith` (aid, body, _aid2))
#endif
        Nothing
      addBig Nothing = Just aid
      addBig (Just aid2) = error $ "an actor already present there"
                                   `showFailure` (aid, body, aid2)
      updBig = EM.alter addBig (bpos newBody)
               . EM.alter rmBig (bpos body)
  let rmProj Nothing = error $ "actor already removed"
                               `showFailure` (aid, body)
      rmProj (Just l) =
#ifdef WITH_EXPENSIVE_ASSERTIONS
        assert (aid `elem` l `blame` "actor already removed"
                             `swith` (aid, body, l))
#endif
        (let l2 = delete aid l
         in if null l2 then Nothing else Just l2)
      addProj Nothing = Just [aid]
      addProj (Just l) = Just $ aid : l
      updProj = EM.alter addProj (bpos newBody)
                . EM.alter rmProj (bpos body)
  updateLevel (blid body) $ if bproj body
                            then updateProjMap updProj
                            else updateBigMap updBig

swapActorMap :: MonadStateWrite m
             => ActorId -> Actor -> ActorId -> Actor -> m ()
swapActorMap source sbody target tbody = do
  let addBig aid1 aid2 Nothing =
        error $ "actor already removed"
                `showFailure` (aid1, aid2, source, sbody, target, tbody)
      addBig _aid1 aid2 (Just _aid) =
#ifdef WITH_EXPENSIVE_ASSERTIONS
        assert (_aid == _aid1 `blame` "wrong actor present"
                              `swith` (_aid, _aid1, aid2, sbody, tbody))
#endif
        (Just aid2)
      updBig = EM.alter (addBig source target) (bpos sbody)
               . EM.alter (addBig target source) (bpos tbody)
  if not (bproj sbody) && not (bproj tbody)
  then updateLevel (blid sbody) $ updateBigMap updBig
  else do
    moveActorMap source sbody tbody
    moveActorMap target tbody sbody

insertBagContainer :: MonadStateWrite m
                   => ItemBag -> Container -> m ()
insertBagContainer bag c = case c of
  CFloor lid pos -> do
    let alt Nothing = Just bag
        alt (Just bag2) = atomicFail $ "floor bag not empty"
                                       `showFailure` (bag2, lid, pos, bag)
    updateLevel lid $ updateFloor $ EM.alter alt pos
  CEmbed lid pos -> do
    let alt Nothing = Just bag
        alt (Just bag2) = atomicFail $ "embed bag not empty"
                                       `showFailure` (bag2, lid, pos, bag)
    updateLevel lid $ updateEmbed $ EM.alter alt pos
  CActor aid store ->
    -- Very unlikely case, so we prefer brevity over performance.
    mapWithKeyM_ (\iid kit -> insertItemActor iid kit aid store) bag
  CTrunk{} -> return ()

insertItemContainer :: MonadStateWrite m
                    => ItemId -> ItemQuant -> Container -> m ()
insertItemContainer iid kit c = case c of
  CFloor lid pos -> insertItemFloor iid kit lid pos
  CEmbed lid pos -> insertItemEmbed iid kit lid pos
  CActor aid store -> insertItemActor iid kit aid store
  CTrunk{} -> return ()

-- New @kit@ lands at the front of the list.
insertItemFloor :: MonadStateWrite m
                => ItemId -> ItemQuant -> LevelId -> Point -> m ()
insertItemFloor iid kit lid pos =
  let bag = EM.singleton iid kit
      mergeBag = EM.insertWith (EM.unionWith mergeItemQuant) pos bag
  in updateLevel lid $ updateFloor mergeBag

insertItemEmbed :: MonadStateWrite m
                => ItemId -> ItemQuant -> LevelId -> Point -> m ()
insertItemEmbed iid kit lid pos =
  let bag = EM.singleton iid kit
      mergeBag = EM.insertWith (EM.unionWith mergeItemQuant) pos bag
  in updateLevel lid $ updateEmbed mergeBag

insertItemActor :: MonadStateWrite m
                => ItemId -> ItemQuant -> ActorId -> CStore -> m ()
insertItemActor iid kit aid cstore = case cstore of
  CGround -> do
    b <- getsState $ getActorBody aid
    insertItemFloor iid kit (blid b) (bpos b)
  COrgan -> insertItemOrgan iid kit aid
  CEqp -> insertItemEqp iid kit aid
  CInv -> insertItemInv iid kit aid
  CSha -> do
    b <- getsState $ getActorBody aid
    insertItemSha iid kit (bfid b)

insertItemOrgan :: MonadStateWrite m
                => ItemId -> ItemQuant -> ActorId -> m ()
insertItemOrgan iid kit aid = do
  arItem <- getsState $ aspectRecordFromIid iid
  let bag = EM.singleton iid kit
      upd = EM.unionWith mergeItemQuant bag
  updateActor aid $ \b ->
    b { borgan = upd (borgan b)
      , bweapon = if IA.checkFlag Ability.Meleeable arItem
                  then bweapon b + 1
                  else bweapon b }

insertItemEqp :: MonadStateWrite m
              => ItemId -> ItemQuant -> ActorId -> m ()
insertItemEqp iid kit aid = do
  arItem <- getsState $ aspectRecordFromIid iid
  let bag = EM.singleton iid kit
      upd = EM.unionWith mergeItemQuant bag
  updateActor aid $ \b ->
    b { beqp = upd (beqp b)
      , bweapon = if IA.checkFlag Ability.Meleeable arItem
                  then bweapon b + 1
                  else bweapon b }

insertItemInv :: MonadStateWrite m
              => ItemId -> ItemQuant -> ActorId -> m ()
insertItemInv iid kit aid = do
  let bag = EM.singleton iid kit
      upd = EM.unionWith mergeItemQuant bag
  updateActor aid $ \b -> b {binv = upd (binv b)}

insertItemSha :: MonadStateWrite m
              => ItemId -> ItemQuant -> FactionId -> m ()
insertItemSha iid kit fid = do
  let bag = EM.singleton iid kit
      upd = EM.unionWith mergeItemQuant bag
  updateFaction fid $ \fact -> fact {gsha = upd (gsha fact)}

deleteBagContainer :: MonadStateWrite m
                   => ItemBag -> Container -> m ()
deleteBagContainer bag c = case c of
  CFloor lid pos -> do
    let alt Nothing = atomicFail $ "floor bag already empty"
                                   `showFailure` (lid, pos, bag)
        alt (Just bag2) = assert (bag == bag2) Nothing
    updateLevel lid $ updateFloor $ EM.alter alt pos
  CEmbed lid pos -> do
    let alt Nothing = atomicFail $ "embed bag already empty"
                                   `showFailure` (lid, pos, bag)
        alt (Just bag2) = assert (bag == bag2 `blame` (bag, bag2)) Nothing
    updateLevel lid $ updateEmbed $ EM.alter alt pos
  CActor aid store ->
    -- Very unlikely case, so we prefer brevity over performance.
    mapWithKeyM_ (\iid kit -> deleteItemActor iid kit aid store) bag
  CTrunk{} -> error $ "" `showFailure` c

deleteItemContainer :: MonadStateWrite m
                    => ItemId -> ItemQuant -> Container -> m ()
deleteItemContainer iid kit c = case c of
  CFloor lid pos -> deleteItemFloor iid kit lid pos
  CEmbed lid pos -> deleteItemEmbed iid kit lid pos
  CActor aid store -> deleteItemActor iid kit aid store
  CTrunk{} -> error $ "" `showFailure` c

deleteItemFloor :: MonadStateWrite m
                => ItemId -> ItemQuant -> LevelId -> Point -> m ()
deleteItemFloor iid kit lid pos =
  let rmFromFloor (Just bag) =
        let nbag = rmFromBag kit iid bag
        in if EM.null nbag then Nothing else Just nbag
      rmFromFloor Nothing = error $ "item already removed"
                                    `showFailure` (iid, kit, lid, pos)
  in updateLevel lid $ updateFloor $ EM.alter rmFromFloor pos

deleteItemEmbed :: MonadStateWrite m
                => ItemId -> ItemQuant -> LevelId -> Point -> m ()
deleteItemEmbed iid kit lid pos =
  let rmFromFloor (Just bag) =
        let nbag = rmFromBag kit iid bag
        in if EM.null nbag then Nothing else Just nbag
      rmFromFloor Nothing = error $ "item already removed"
                                    `showFailure` (iid, kit, lid, pos)
  in updateLevel lid $ updateEmbed $ EM.alter rmFromFloor pos

deleteItemActor :: MonadStateWrite m
                => ItemId -> ItemQuant -> ActorId -> CStore -> m ()
deleteItemActor iid kit aid cstore = case cstore of
  CGround -> do
    b <- getsState $ getActorBody aid
    deleteItemFloor iid kit (blid b) (bpos b)
  COrgan -> deleteItemOrgan iid kit aid
  CEqp -> deleteItemEqp iid kit aid
  CInv -> deleteItemInv iid kit aid
  CSha -> do
    b <- getsState $ getActorBody aid
    deleteItemSha iid kit (bfid b)

deleteItemOrgan :: MonadStateWrite m => ItemId -> ItemQuant -> ActorId -> m ()
deleteItemOrgan iid kit aid = do
  arItem <- getsState $ aspectRecordFromIid iid
  updateActor aid $ \b ->
    b { borgan = rmFromBag kit iid (borgan b)
      , bweapon = if IA.checkFlag Ability.Meleeable arItem
                  then bweapon b - 1
                  else bweapon b }

deleteItemEqp :: MonadStateWrite m => ItemId -> ItemQuant -> ActorId -> m ()
deleteItemEqp iid kit aid = do
  arItem <- getsState $ aspectRecordFromIid iid
  updateActor aid $ \b ->
    b { beqp = rmFromBag kit iid (beqp b)
      , bweapon = if IA.checkFlag Ability.Meleeable arItem
                  then bweapon b - 1
                  else bweapon b }

deleteItemInv :: MonadStateWrite m => ItemId -> ItemQuant -> ActorId -> m ()
deleteItemInv iid kit aid =
  updateActor aid $ \b -> b {binv = rmFromBag kit iid (binv b)}

deleteItemSha :: MonadStateWrite m => ItemId -> ItemQuant -> FactionId -> m ()
deleteItemSha iid kit fid =
  updateFaction fid $ \fact -> fact {gsha = rmFromBag kit iid (gsha fact)}

-- Removing the part of the kit from the back of the list,
-- so that @DestroyItem kit (CreateItem kit x) == x@.
rmFromBag :: ItemQuant -> ItemId -> ItemBag -> ItemBag
rmFromBag kit@(k, rmIt) iid bag =
  let rfb Nothing = error $ "rm from empty slot" `showFailure` (k, iid, bag)
      rfb (Just (n, it)) =
        case compare n k of
          LT -> error $ "rm more than there is"
                        `showFailure` (n, kit, iid, bag)
          EQ -> assert (rmIt == it `blame` (rmIt, it, n, kit, iid, bag)) Nothing
          GT -> assert (rmIt == take k it
                        `blame` (rmIt, take k it, n, kit, iid, bag))
                $ Just (n - k, take (n - k) it)
  in EM.alter rfb iid bag

-- Actor's items may or may not be already present in @sitemD@,
-- regardless if they are already present otherwise in the dungeon.
-- We re-add them all to save time determining which really need it.
-- If collision occurs, pick the item found on easier level.
addAis :: MonadStateWrite m => [(ItemId, Item)] -> m ()
addAis ais = do
  let h item1 item2 =
        assert (itemsMatch item1 item2
                `blame` "inconsistent added items"
                `swith` (item1, item2, ais))
               item2 -- keep the first found level
  forM_ ais $ \(iid, item) -> do
    let f = case jkind item of
          IdentityObvious _ -> id
          IdentityCovered ix _ ->
            updateItemIxMap $ EM.insertWith ES.union ix (ES.singleton iid)
    modifyState $ f . updateItemD (EM.insertWith h iid item)

itemsMatch :: Item -> Item -> Bool
itemsMatch item1 item2 =
  jkind item1 == jkind item2
  -- Note that nothing else needs to be the same, since items are merged
  -- and clients have different views on dungeon items than the server.

addItemToActorMaxSkills :: MonadStateWrite m
                        => ItemId -> Item -> Int -> ActorId -> m ()
addItemToActorMaxSkills iid itemBase k aid = do
  arItem <- getsState $ aspectRecordFromItem iid itemBase
  let f actorMaxSk =
        Ability.sumScaledSkills [(actorMaxSk, 1), (IA.aSkills arItem, k)]
  modifyState $ updateActorMaxSkills $ EM.adjust f aid

resetActorMaxSkills :: MonadStateWrite m => m ()
resetActorMaxSkills = do
  -- Each actor's equipment and organs would need to be inspected,
  -- the iid looked up, e.g., if it wasn't in old discoKind, but is in new,
  -- and then aspect record updated, so it's simpler and not much more
  -- expensive to generate new sactorMaxSkills. Optimize only after profiling.
  -- Also note this doesn't get invoked on the server, because it bails out
  -- earlier, upon noticing the item is already fully known.
  actorMaxSk <- getsState maxSkillsInDungeon
  modifyState $ updateActorMaxSkills $ const actorMaxSk
