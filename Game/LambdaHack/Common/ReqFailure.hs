{-# LANGUAGE DeriveGeneric #-}
-- | Possible causes of failure of request.
module Game.LambdaHack.Common.ReqFailure
  ( ReqFailure(..)
  , impossibleReqFailure, showReqFailure
  , permittedPrecious, permittedProject, permittedProjectAI, permittedApply
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import Data.Binary
import GHC.Generics (Generic)

import qualified Game.LambdaHack.Common.Ability as Ability
import           Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Time
import qualified Game.LambdaHack.Content.ItemKind as IK

-- | Possible causes of failure of request.
data ReqFailure =
    MoveUnskilled
  | MoveNothing
  | MeleeUnskilled
  | MeleeSelf
  | MeleeDistant
  | DisplaceUnskilled
  | DisplaceDistant
  | DisplaceAccess
  | DisplaceProjectiles
  | DisplaceDying
  | DisplaceBraced
  | DisplaceImmobile
  | DisplaceSupported
  | AlterUnskilled
  | AlterUnwalked
  | AlterDistant
  | AlterBlockActor
  | AlterBlockItem
  | AlterNothing
  | WaitUnskilled
  | YellUnskilled
  | MoveItemUnskilled
  | EqpOverfull
  | EqpStackFull
  | ApplyUnskilled
  | ApplyRead
  | ApplyOutOfReach
  | ApplyCharging
  | ApplyNoEffects
  | ItemNothing
  | ItemNotCalm
  | NotCalmPrecious
  | ProjectUnskilled
  | ProjectAimOnself
  | ProjectBlockTerrain
  | ProjectBlockActor
  | ProjectLobable
  | ProjectOutOfReach
  | TriggerNothing
  | NoChangeDunLeader
  deriving (Show, Eq, Generic)

instance Binary ReqFailure

impossibleReqFailure :: ReqFailure -> Bool
impossibleReqFailure reqFailure = case reqFailure of
  MoveUnskilled -> False  -- unidentified skill items
  MoveNothing -> True
  MeleeUnskilled -> False  -- unidentified skill items
  MeleeSelf -> True
  MeleeDistant -> True
  DisplaceUnskilled -> False  -- unidentified skill items
  DisplaceDistant -> True
  DisplaceAccess -> True
  DisplaceProjectiles -> True
  DisplaceDying -> True
  DisplaceBraced -> True
  DisplaceImmobile -> False  -- unidentified skill items
  DisplaceSupported -> False
  AlterUnskilled -> False  -- unidentified skill items
  AlterUnwalked -> False
  AlterDistant -> True
  AlterBlockActor -> True  -- adjacent actor always visible
  AlterBlockItem -> True  -- adjacent item always visible
  AlterNothing -> True
  WaitUnskilled -> False  -- unidentified skill items
  YellUnskilled -> False  -- unidentified skill items
  MoveItemUnskilled -> False  -- unidentified skill items
  EqpOverfull -> True
  EqpStackFull -> True
  ApplyUnskilled -> False  -- unidentified skill items
  ApplyRead -> False  -- unidentified skill items
  ApplyOutOfReach -> True
  ApplyCharging -> False  -- if aspect record unknown, charging unknown
  ApplyNoEffects -> False  -- if effects unknown, can't prevent it
  ItemNothing -> True
  ItemNotCalm -> False  -- unidentified skill items
  NotCalmPrecious -> False  -- unidentified skill items
  ProjectUnskilled -> False  -- unidentified skill items
  ProjectAimOnself -> True
  ProjectBlockTerrain -> True  -- adjacent terrain always visible
  ProjectBlockActor -> True  -- adjacent actor always visible
  ProjectLobable -> False  -- unidentified skill items
  ProjectOutOfReach -> True
  TriggerNothing -> True  -- terrain underneath always visible
  NoChangeDunLeader -> True

showReqFailure :: ReqFailure -> Text
showReqFailure reqFailure = case reqFailure of
  MoveUnskilled -> "unskilled actors cannot move"
  MoveNothing -> "wasting time on moving into obstacle"
  MeleeUnskilled -> "unskilled actors cannot melee"
  MeleeSelf -> "trying to melee oneself"
  MeleeDistant -> "trying to melee a distant foe"
  DisplaceUnskilled -> "unskilled actors cannot displace"
  DisplaceDistant -> "trying to displace a distant actor"
  DisplaceAccess -> "switching places without access"
  DisplaceProjectiles -> "trying to displace multiple actors"
  DisplaceDying -> "trying to displace a dying foe"
  DisplaceBraced -> "trying to displace a braced foe"
  DisplaceImmobile -> "trying to displace an immobile foe"
  DisplaceSupported -> "trying to displace a supported foe"
  AlterUnskilled -> "unskilled actors cannot alter tiles"
  AlterUnwalked -> "unskilled actors cannot enter tiles"
  AlterDistant -> "trying to alter a distant tile"
  AlterBlockActor -> "blocked by an actor"
  AlterBlockItem -> "jammed by an item"
  AlterNothing -> "wasting time on altering nothing"
  WaitUnskilled -> "unskilled actors cannot wait"
  YellUnskilled -> "actors unskilled in waiting cannot yell/yawn"
  MoveItemUnskilled -> "unskilled actors cannot move items"
  EqpOverfull -> "cannot equip any more items"
  EqpStackFull -> "cannot equip the whole item stack"
  ApplyUnskilled -> "unskilled actors cannot apply items"
  ApplyRead -> "activating this kind of items requires apply stat 2"
  ApplyOutOfReach -> "cannot apply an item out of reach"
  ApplyCharging -> "cannot apply an item that is still charging"
  ApplyNoEffects -> "cannot apply an item that produces no effects"
  ItemNothing -> "wasting time on void item manipulation"
  ItemNotCalm -> "you are too alarmed to use the shared stash"
  NotCalmPrecious -> "you are too alarmed to handle such an exquisite item"
  ProjectUnskilled -> "unskilled actors cannot aim"
  ProjectAimOnself -> "cannot aim at oneself"
  ProjectBlockTerrain -> "aiming obstructed by terrain"
  ProjectBlockActor -> "aiming blocked by an actor"
  ProjectLobable -> "lobbing an item requires fling stat 3"
  ProjectOutOfReach -> "cannot aim an item out of reach"
  TriggerNothing -> "wasting time on triggering nothing"
  NoChangeDunLeader -> "no manual level change for your team"

-- The item should not be applied nor thrown because it's too delicate
-- to operate when not calm or becuse it's too precious to identify by use.
permittedPrecious :: Bool -> Bool -> ItemFull -> Either ReqFailure Bool
permittedPrecious forced calmE itemFull@ItemFull{itemDisco} =
  let arItem = aspectRecordFull itemFull
      isPrecious = IA.checkFlag Ability.Precious arItem
  in if not forced && not calmE && isPrecious
     then Left NotCalmPrecious
     else Right $ IA.checkFlag Ability.Durable arItem
                  || case itemDisco of
                       ItemDiscoFull{} -> True
                       _ -> not isPrecious

-- Simplified, faster version, for inner AI loop.
permittedPreciousAI :: Bool -> ItemFull -> Bool
permittedPreciousAI calmE itemFull@ItemFull{itemDisco} =
  let arItem = aspectRecordFull itemFull
      isPrecious = IA.checkFlag Ability.Precious arItem
  in (calmE || not isPrecious)
     && IA.checkFlag Ability.Durable arItem
        || case itemDisco of
             ItemDiscoFull{} -> True
             _ -> not isPrecious

permittedProject :: Bool -> Int -> Bool -> ItemFull -> Either ReqFailure Bool
permittedProject forced skill calmE itemFull =
 let arItem = aspectRecordFull itemFull
 in if | not forced && skill < 1 -> Left ProjectUnskilled
       | not forced
         && IA.checkFlag Ability.Lobable arItem
         && skill < 3 -> Left ProjectLobable
       | otherwise ->
           let badSlot = case IA.aEqpSlot arItem of
                 Just Ability.EqpSlotShine -> False
                 Just _ -> True
                 Nothing -> IA.goesIntoEqp arItem
           in if badSlot
              then Right False
              else permittedPrecious forced calmE itemFull

-- Simplified, faster and more permissive version, for inner AI loop.
permittedProjectAI :: Int -> Bool -> ItemFull -> Bool
permittedProjectAI skill calmE itemFull =
 let arItem = aspectRecordFull itemFull
 in if | skill < 1 -> False
       | IA.checkFlag Ability.Lobable arItem
         && skill < 3 -> False
       | otherwise -> permittedPreciousAI calmE itemFull

permittedApply :: Time -> Int -> Bool-> ItemFull -> ItemQuant
               -> Either ReqFailure Bool
permittedApply localTime skill calmE
               itemFull@ItemFull{itemKind, itemSuspect} kit =
  if | skill < 1 -> Left ApplyUnskilled
     | skill < 2 && IK.isymbol itemKind `notElem` [',', '"'] ->
       Left ApplyUnskilled
     | skill < 3 && IK.isymbol itemKind == '?' -> Left ApplyRead
     -- If the item is discharged, neither the kinetic hit nor
     -- any effects activate, so there's no point applying.
     -- Note that if client doesn't know the timeout, here we may leak the fact
     -- that the item is still charging, but the client risks destruction
     -- if the item is, in fact, recharged and is not durable
     -- (likely in case of jewellery). So it's OK (the message may be
     -- somewhat alarming though).
     | not $ hasCharge localTime itemFull kit -> Left ApplyCharging
     | otherwise ->
       if null (IK.ieffects itemKind) && not itemSuspect
       then Left ApplyNoEffects
       else permittedPrecious False calmE itemFull
