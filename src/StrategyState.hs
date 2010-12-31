module StrategyState where

import Data.List as L
import Data.Map as M
import Data.Set as S

import Geometry
import Level
import Monster
import Random
import Perception
import Strategy
import State

strategy :: Monster -> State -> Perception -> Strategy Dir
strategy m@(Monster { mtype = mt, mloc = me, mdir = mdir })
         (state@(State { splayer = player@(Monster { mloc = ploc }),
                         stime   = time,
                         slevel  = lvl@(Level { lmonsters = ms, lsmell = nsmap, lmap = lmap }) }))
         per =
    case mt of
      Eye     -> slowEye
      FastEye -> fastEye
      Nose    -> nose
      _       -> onlyAccessible moveRandomly
  where
    -- we check if the monster is visible by the player rather than if the
    -- player is visible by the monster -- this is more efficient, but
    -- won't be correct in the general situation
    playerVisible      =  me `S.member` pvisible per
    playerAdjacent     =  adjacent me ploc
    towardsPlayer      =  towards (me, ploc)
    onlyTowardsPlayer  =  only (\ x -> distance (towardsPlayer, x) <= 1)
    lootPresent        =  (\ x -> not $ L.null $ titems $ lmap `at` x)
    onlyLootPresent    =  onlyMoves lootPresent me
    onlyPreservesDir   =  only (\ x -> maybe True (\ d -> distance (neg d, x) > 1) mdir)
    onlyUnoccupied     =  onlyMoves (unoccupied ms lmap) me
    onlyAccessible     =  onlyMoves (accessible lmap me) me
    onlyOpenable       =  onlyMoves (openable 10 lmap) me
    smells             =  L.map fst $
                          L.sortBy (\ (_,s1) (_,s2) -> compare s2 s1) $
                          L.filter (\ (_,s) -> s > 0) $
                          L.map (\ x -> (x, nsmap ! (me `shift` x) - time `max` 0)) moves

    eye                =  onlyUnoccupied $
                            playerVisible .=> onlyTowardsPlayer moveRandomly
                            .| lootPresent me .=> return (0,0)
                            .| onlyLootPresent moveRandomly
                            .| onlyPreservesDir moveRandomly

    slowEye            =  playerAdjacent .=> return towardsPlayer
                          .| not playerVisible .=> onlyOpenable eye
                          .| onlyAccessible eye

    fastEye            =  playerAdjacent .=> return towardsPlayer
                          .| onlyAccessible eye

    nose               =  playerAdjacent .=> return towardsPlayer
                          .| (onlyAccessible $
                              lootPresent me .=> return (0,0)
                              .| foldr (.|) reject (L.map return smells)
                              .| onlyLootPresent moveRandomly
                              .| moveRandomly)

onlyMoves :: (Dir -> Bool) -> Loc -> Strategy Dir -> Strategy Dir
onlyMoves p l = only (\ x -> p (l `shift` x))

moveRandomly :: Strategy Dir
moveRandomly = liftFrequency $ uniform moves

wait :: Strategy Dir
wait = return (0,0)
