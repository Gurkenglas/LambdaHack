-- | Generation of caves (not yet inhabited dungeon levels) from cave kinds.
module Game.LambdaHack.Cave
  ( Cave(..), SecretMapXY, ItemMapXY, TileMapXY, buildCave )
  where

import Control.Monad
import qualified Data.Map as M
import qualified Data.List as L

import Game.LambdaHack.Geometry
import Game.LambdaHack.Area
import Game.LambdaHack.AreaRnd
import Game.LambdaHack.Item
import Game.LambdaHack.Random
import qualified Game.LambdaHack.Tile as Tile
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Content.CaveKind
import Game.LambdaHack.Content.TileKind

-- All maps here are sparse. In case of the tile map, the default tile
-- is specified in the cave kind specification.

type SecretMapXY = M.Map (X, Y) Tile.SecretStrength

type ItemMapXY = M.Map (X, Y) Item

type TileMapXY = M.Map (X, Y) (Kind.Id TileKind)

-- TODO: dmonsters :: [(X, Y), actorKind]  -- ^ fixed monsters on the level
data Cave = Cave
  { dkind     :: !(Kind.Id CaveKind)  -- ^ the kind of the cave
  , dsecret   :: SecretMapXY
  , ditem     :: ItemMapXY
  , dmap      :: TileMapXY
  , dmeta     :: String
  }
  deriving Show

buildCave :: Kind.COps -> Int -> Kind.Id CaveKind -> Rnd Cave
buildCave cops@Kind.COps{cocave=Kind.Ops{okind}} n ci =
  let CaveKind{clayout} = okind ci
  in case clayout of
       CaveRogue -> caveRogue cops n ci
       CaveEmpty -> caveEmpty cops n ci
       CaveNoise -> caveNoise cops n ci

-- | Cave consisting of only one, empty room.
caveEmpty :: Kind.COps -> Int -> Kind.Id CaveKind -> Rnd Cave
caveEmpty Kind.COps{cotile, cocave=Kind.Ops{okind}} _ ci = do
  wallId  <- Tile.wallId cotile
  let CaveKind{cxsize, cysize} = okind ci
      room = (1, 1, cxsize - 2, cysize - 2)
      dmap = caveBorder wallId room
      cave = Cave
        { dkind = ci
        , dsecret = M.empty
        , ditem = M.empty
        , dmap
        , dmeta = "empty room"
        }
  return cave

-- | Cave consisting of only one room with randomly distributed pillars.
caveNoise :: Kind.COps -> Int -> Kind.Id CaveKind -> Rnd Cave
caveNoise Kind.COps{cotile, cocave=Kind.Ops{okind}} _ ci = do
  wallId  <- Tile.wallId cotile
  let CaveKind{cxsize, cysize} = okind ci
      room = (1, 1, cxsize - 2, cysize - 2)
      em = caveBorder wallId room
  nri <- rollDice (fromIntegral (cysize `div` 5), 3)
  lr <- replicateM (cxsize * nri) $ do
    xy <- xyInArea (1, 1, cxsize - 2, cysize - 2)
    -- Each pillar can be from different rock type.
    rock <- Tile.wallId cotile
    return (xy, rock)
  let insertRock lm (xy, rock) = M.insert xy rock lm
      dmap = L.foldl' insertRock em lr
      cave = Cave
        { dkind = ci
        , dsecret = M.empty
        , ditem = M.empty
        , dmap
        , dmeta = "noise room"
        }
  return cave

-- | If the room has size 1, it is at most a start of a corridor.
-- Equal floor and wall tiles in the whole room.
digRoom :: Kind.Id TileKind -> Kind.Id TileKind -> Room -> TileMapXY -> TileMapXY
digRoom floorId wallId (x0, y0, x1, y1) lmap
  | x0 == x1 && y0 == y1 = lmap
  | otherwise =
  let rm = [ ((x, y), floorId) | x <- [x0..x1], y <- [y0..y1] ]
           ++ [ ((x, y), wallId) | x <- [x0-1, x1+1], y <- [y0..y1] ]
           ++ [ ((x, y), wallId) | x <- [x0-1..x1+1], y <- [y0-1, y1+1] ]
  in M.union (M.fromList rm) lmap

caveBorder :: Kind.Id TileKind -> Room -> TileMapXY
caveBorder wallId (x0, y0, x1, y1) =
  M.fromList $ [ ((x, y), wallId) | x <- [x0-1, x1+1], y <- [y0..y1] ] ++
               [ ((x, y), wallId) | x <- [x0-1..x1+1], y <- [y0-1, y1+1] ]

{-
Rogue cave is generated by an algorithm inspired by the original Rogue,
as follows:

  * The available area is divided into a 3 by 3 grid
    where each of the 9 grid cells has approximately the same size.

  * In each of the 9 grid cells one room is placed at a random location.
    The minimum size of a room is 2 by 2 floor tiles. A room is surrounded
    by walls, and the walls still have to fit into the assigned grid cells.

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
-- | Cave generated by an algorithm inspired by the original Rogue,
caveRogue :: Kind.COps -> Int -> Kind.Id CaveKind -> Rnd Cave
caveRogue Kind.COps{cotile, cocave=Kind.Ops{okind}} n ci = do
  let cfg@CaveKind{cxsize, cysize} = okind ci
  lgrid@(gx, gy) <- levelGrid cfg
  lminroom <- minRoomSize cfg
  let gs = grid lgrid (0, 0, cxsize - 1, cysize - 1)
  -- grid locations of "no-rooms"
  nrnr <- noRooms cfg lgrid
  nr   <- replicateM nrnr $ xyInArea (0, 0, gx - 1, gy - 1)
  rs0  <- mapM (\ (i, r) -> do
                   r' <- if i `elem` nr
                         then mkRoom (border cfg) (1, 1) r
                         else mkRoom (border cfg) lminroom r
                   return (i, r')) gs
  let rooms :: [Area]
      rooms = L.map snd rs0
  dlrooms <- mapM (\ r -> darkRoomChance cfg n
                          >>= \ c -> return (r, not c)) rooms
  let rs = M.fromList rs0
  connects <- connectGrid lgrid
  addedConnects <- replicateM (extraConnects cfg lgrid) (randomConnection lgrid)
  let allConnects = L.nub (addedConnects ++ connects)
  cs <- mapM (\ (p0, p1) -> do
                 let r0 = rs M.! p0
                     r1 = rs M.! p1
                 connectRooms r0 r1) allConnects
  lrooms <- foldM (\ m (r, dl) -> do
                      floorId <- (if dl
                                  then Tile.floorLightId
                                  else Tile.floorDarkId) cotile
                      wallId  <- Tile.wallId cotile
                      return $ digRoom floorId wallId r m) M.empty dlrooms
  floorDarkId <- Tile.floorDarkId cotile
  openingId <- Tile.openingId cotile
  let lcorridors = M.unions (L.map (digCorridors floorDarkId) cs)
      lm = M.unionWith (mergeCorridor openingId cotile)
             lcorridors lrooms
  -- convert openings into doors
  doorOpenId <- Tile.doorOpenId cotile
  doorClosedId <- Tile.doorClosedId cotile
  doorSecretId <- Tile.doorSecretId cotile
  (dmap, secretMap) <-
    let f (l, le) ((x, y), t) =
          if Tile.isOpening cotile t
          then do
            -- Openings have a certain chance to be doors;
            -- doors have a certain chance to be open; and
            -- closed doors have a certain chance to be secret
            rb <- doorChance cfg
            ro <- doorOpenChance cfg
            if not rb
              then return (l, le)
              else if ro
                   then return (M.insert (x, y) doorOpenId l, le)
                   else do
                     rsc <- doorSecretChance cfg
                     if not rsc
                       then return (M.insert (x, y) doorClosedId l, le)
                       else do
                         rs1 <- rollDice (csecretStrength cfg)
                         return (M.insert (x, y) doorSecretId l,
                                 M.insert (x, y) (Tile.SecretStrength rs1) le)
          else return (l, le)
    in foldM f (lm, M.empty) (M.toList lm)
  let cave = Cave
        { dkind = ci
        , dsecret = secretMap
        , ditem = M.empty
        , dmap
        , dmeta = show allConnects
        }
  return cave

type Corridor = [(X, Y)]
type Room = Area

-- | Create a random room according to given parameters.
mkRoom :: Int       -- ^ border columns
       -> (X, Y)    -- ^ minimum size
       -> Area      -- ^ this is an area, not the room itself
       -> Rnd Room  -- ^ upper-left and lower-right corner of the room
mkRoom bd (xm, ym) (x0, y0, x1, y1) = do
  (rx0, ry0) <- xyInArea (x0 + bd, y0 + bd, x1 - bd - xm + 1, y1 - bd - ym + 1)
  (rx1, ry1) <- xyInArea (rx0 + xm - 1, ry0 + ym - 1, x1 - bd, y1 - bd)
  return (rx0, ry0, rx1, ry1)

digCorridors :: Kind.Id TileKind -> Corridor -> TileMapXY
digCorridors tile (p1:p2:ps) =
  M.union corPos (digCorridors tile (p2:ps))
 where
  corXY  = fromTo p1 p2
  corPos = M.fromList $ L.zip corXY (repeat tile)
digCorridors _ _ = M.empty

mergeCorridor :: Kind.Id TileKind -> Kind.Ops TileKind -> Kind.Id TileKind
              -> Kind.Id TileKind -> Kind.Id TileKind
mergeCorridor _         cops _ t | Tile.isWalkable cops t = t
mergeCorridor openingId _    _ _                          = openingId
