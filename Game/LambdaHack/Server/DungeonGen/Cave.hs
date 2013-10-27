{-# LANGUAGE OverloadedStrings #-}
-- | Generation of caves (not yet inhabited dungeon levels) from cave kinds.
module Game.LambdaHack.Server.DungeonGen.Cave
  ( TileMapXY, ItemFloorXY, Cave(..), buildCave
  ) where

import Control.Monad
import qualified Data.EnumMap.Strict as EM
import qualified Data.List as L

import Game.LambdaHack.Common.Area
import qualified Game.LambdaHack.Common.Feature as F
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.PointXY
import Game.LambdaHack.Common.Random
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Content.CaveKind
import Game.LambdaHack.Content.TileKind
import Game.LambdaHack.Server.DungeonGen.AreaRnd
import Game.LambdaHack.Server.DungeonGen.Place hiding (TileMapXY)
import qualified Game.LambdaHack.Server.DungeonGen.Place as Place

-- | The map of tile kinds in a cave.
-- The map is sparse. The default tile that eventually fills the empty spaces
-- is specified in the cave kind specification with @cdefTile@.
type TileMapXY = Place.TileMapXY

-- | The map of starting items in tiles of a cave. The map is sparse.
-- Unspecified tiles have no starting items.
type ItemFloorXY = EM.EnumMap PointXY (Item, Int)

-- | The type of caves (not yet inhabited dungeon levels).
data Cave = Cave
  { dkind   :: !(Kind.Id CaveKind)  -- ^ the kind of the cave
  , dmap    :: TileMapXY            -- ^ tile kinds in the cave
  , ditem   :: ItemFloorXY          -- ^ starting items in the cave
  , dplaces :: [Place]              -- ^ places generated in the cave
  }
  deriving Show

{-
Rogue cave is generated by an algorithm inspired by the original Rogue,
as follows:

  * The available area is divided into a grid, e.g, 3 by 3,
    where each of the 9 grid cells has approximately the same size.

  * In each of the 9 grid cells one room is placed at a random position
    and with a random size, but larger than The minimum size,
    e.g, 2 by 2 floor tiles.

  * Rooms that are on horizontally or vertically adjacent grid cells
    may be connected by a corridor. Corridors consist of 3 segments of straight
    lines (either "horizontal, vertical, horizontal" or "vertical, horizontal,
    vertical"). They end in openings in the walls of the room they connect.
    It is possible that one or two of the 3 segments have length 0, such that
    the resulting corridor is L-shaped or even a single straight line.

  * Corridors are generated randomly in such a way that at least every room
    on the grid is connected, and a few more might be. It is not sufficient
    to always connect all adjacent rooms.
-}
-- TODO: fix identifier naming and split, after the code grows some more
-- | Cave generation by an algorithm inspired by the original Rogue,
buildCave :: Kind.COps         -- ^ content definitions
          -> Int               -- ^ depth of the level to generate
          -> Int               -- ^ maximum depth of the dungeon
          -> Kind.Id CaveKind  -- ^ cave kind to use for generation
          -> Rnd Cave
buildCave cops@Kind.COps{ cotile=cotile@Kind.Ops{ opick
                                                , ouniqGroup }
                        , cocave=Kind.Ops{okind} }
          ln depth ci = do
  let kc@CaveKind{..} = okind ci
  lgrid@(gx, gy) <- rollDiceXY cgrid
  lminplace <- rollDiceXY cminPlaceSize
  let gs = grid lgrid (0, 0, cxsize - 1, cysize - 1)
  mandatory1 <- replicateM (cnonVoidMin `div` 2) $
                  xyInArea (0, 0, gx `div` 3, gy - 1)
  mandatory2 <- replicateM (cnonVoidMin `divUp` 2) $
                  xyInArea (gx - 1 - (gx `div` 3), 0, gx - 1, gy - 1)
  places0 <- mapM (\ (i, r) -> do
                     rv <- chance cvoidChance
                     r' <- if rv && i `notElem` (mandatory1 ++ mandatory2)
                           then mkVoidRoom r
                           else mkRoom lminplace r
                     return (i, r')) gs
  connects <- connectGrid lgrid
  addedConnects <-
    if gx * gy > 1
    then let caux = round $ cauxConnects * fromIntegral (gx * gy)
         in replicateM caux (randomConnection lgrid)
    else return []
  let allConnects = L.union connects addedConnects  -- no duplicates
      places = EM.fromList places0
  cs <- mapM (\ (p0, p1) -> do
                 let r0 = places EM.! p0
                     r1 = places EM.! p1
                 connectPlaces r0 r1) allConnects
  let hardRockId = ouniqGroup "hard rock"
      fenceBounds = (1, 1, cxsize - 2, cysize - 2)
      fence = buildFence hardRockId fenceBounds
  pickedCorTile <- opick ccorridorTile (const True)
  let addPl (m, pls) (_, (x0, _, x1, _)) | x0 == x1 = return (m, pls)
      addPl (m, pls) (_, r) = do
        (tmap, place) <- buildPlace cops kc pickedCorTile ln depth r
        return (EM.union tmap m, place : pls)
  (lplaces, dplaces) <- foldM addPl (fence, []) places0
  let lcorridors = EM.unions (L.map (digCorridors pickedCorTile) cs)
      lm = EM.unionWith (mergeCorridor cotile) lcorridors lplaces
  -- Convert wall openings into doors, possibly.
  let f l (p, t) =
        if not $ Tile.hasFeature cotile F.Suspect t
        then return l  -- no opening to start with
        else do
          -- Openings have a certain chance to be doors
          -- and doors have a certain chance to be open.
          rd <- chance cdoorChance
          if not rd then
            return $ EM.insert p pickedCorTile l  -- opening kept
          else do
            ro <- chance copenChance
            doorClosedId <- Tile.revealAs cotile t
            if not ro then
              return $ EM.insert p doorClosedId l
            else do
              doorOpenId <- Tile.openTo cotile doorClosedId
              return $ EM.insert p doorOpenId l
  dmap <- foldM f lm (EM.assocs lm)
  let cave = Cave
        { dkind = ci
        , ditem = EM.empty
        , dmap
        , dplaces
        }
  return cave

digCorridors :: Kind.Id TileKind -> Corridor -> TileMapXY
digCorridors tile (p1:p2:ps) =
  EM.union corPos (digCorridors tile (p2:ps))
 where
  corXY  = fromTo p1 p2
  corPos = EM.fromList $ L.zip corXY (repeat tile)
digCorridors _ _ = EM.empty

mergeCorridor :: Kind.Ops TileKind -> Kind.Id TileKind -> Kind.Id TileKind
              -> Kind.Id TileKind
mergeCorridor cotile _ = Tile.hiddenAs cotile
