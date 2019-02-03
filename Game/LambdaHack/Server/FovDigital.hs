-- | DFOV (Digital Field of View) implemented according to specification at <http://roguebasin.roguelikedevelopment.org/index.php?title=Digital_field_of_view_implementation>.
-- This fast version of the algorithm, based on "PFOV", has AFAIK
-- never been described nor implemented before.
module Game.LambdaHack.Server.FovDigital
  ( scan
    -- * Scanning coordinate system
  , Bump(..)
    -- * Assorted minor operations
#ifdef EXPOSE_INTERNAL
    -- * Current scan parameters
  , Distance, Progress
    -- * Geometry in system @Bump@
  , Line(..), ConvexHull, Edge, EdgeInterval
    -- * Internal operations
  , steeper, addHull
  , dline, dsteeper, intersect, _debugSteeper, _debugLine
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude hiding (intersect)

import qualified Data.EnumSet as ES
import qualified Data.IntSet as IS

import           Game.LambdaHack.Core.Point
import qualified Game.LambdaHack.Core.PointArray as PointArray

-- | Distance from the (0, 0) point where FOV originates.
type Distance = Int
-- | Progress along an arc with a constant distance from (0, 0).
type Progress = Int

-- | Rotated and translated coordinates of 2D points, so that the points fit
-- in a single quadrant area (e, g., quadrant I for Permissive FOV, hence both
-- coordinates positive; adjacent diagonal halves of quadrant I and II
-- for Digital FOV, hence y positive).
-- The special coordinates are written using the standard mathematical
-- coordinate setup, where quadrant I, with x and y positive,
-- is on the upper right.
data Bump = B
  { bx :: Int
  , by :: Int
  }
  deriving Show

-- | Straight line between points.
data Line = Line Bump Bump
  deriving Show

-- | Convex hull represented as a list of points.
type ConvexHull   = [Bump]
-- | An edge (comprising of a line and a convex hull)
-- of the area to be scanned.
type Edge         = (Line, ConvexHull)
-- | The area left to be scanned, delimited by edges.
type EdgeInterval = (Edge, Edge)

-- | Calculates the list of tiles, in @Bump@ coordinates, visible from (0, 0),
-- within the given sight range.
scan :: ES.EnumSet Point
     -> Distance         -- ^ visiblity distance
     -> PointArray.Array Bool
     -> (Bump -> PointI)  -- ^ coordinate transformation
     -> ES.EnumSet Point
{-# INLINE scan #-}
scan accScan r fovClear tr = assert (r > 0 `blame` r) $
  -- The scanned area is a square, which is a sphere in the chessboard metric.
  dscan accScan 1 ( (Line (B 1 0) (B (-r) r), [B 0 0])
                  , (Line (B 0 0) (B (r+1) r), [B 1 0]) )
 where
  isClear :: PointI -> Bool
  {-# INLINE isClear #-}
  isClear = PointArray.accessI fovClear

  fastSetInsert :: PointI -> ES.EnumSet Point -> ES.EnumSet Point
  {-# INLINE fastSetInsert #-}
  fastSetInsert pI set =
    ES.intSetToEnumSet $ IS.insert pI $ ES.enumSetToIntSet set

  dscan :: ES.EnumSet Point -> Distance -> EdgeInterval -> ES.EnumSet Point
  dscan !accDscan !d ( s0@(!sl{-shallow line-}, !sHull)
                     , e0@(!el{-steep line-}, !eHull) ) =

    let !ps0 = let (n, k) = intersect sl d  -- minimal progress to consider
               in n `div` k
        !pe = let (n, k) = intersect el d   -- maximal progress to consider
                -- Corners obstruct view, so the steep line, constructed
                -- from corners, is itself not a part of the view,
                -- so if its intersection with the line of diagonals is only
                -- at a corner, choose the diamond leading to a smaller view.
              in -1 + n `divUp` k
        outside =
          if d < r
          then let !trBump = bump ps0
                   !accBump = fastSetInsert trBump accDscan
               in if isClear trBump
                  then mscanVisible accBump s0 (ps0+1)  -- start visible
                  else mscanShadowed accBump (ps0+1)    -- start in shadow
          else foldl' (\acc ps -> fastSetInsert (bump ps) acc)
                      accDscan [ps0..pe]

        bump :: Progress -> PointI
        bump px = tr $ B px d

        -- We're in a visible interval.
        mscanVisible :: ES.EnumSet Point -> Edge -> Progress -> ES.EnumSet Point
        mscanVisible !acc s@(!_line, !hull) !ps =
          if ps <= pe
          then let !trBump = bump ps
                   !accBump = fastSetInsert trBump acc
               in if isClear trBump  -- not entering shadow
                  then mscanVisible accBump s (ps+1)
                  else let steepBump = B ps d
                           cmp :: Bump -> Bump -> Ordering
                           {-# INLINE cmp #-}
                           cmp = flip $ dsteeper steepBump
                           nep = maximumBy cmp hull
                           neHull = addHull cmp steepBump eHull
                           ne = (dline nep steepBump, neHull)
                           accNew = dscan accBump (d+1) (s, ne)
                       in mscanShadowed accNew (ps+1)
          else dscan acc (d+1) (s, e0)  -- reached end, scan next

        -- We're in a shadowed interval.
        mscanShadowed :: ES.EnumSet Point -> Progress -> ES.EnumSet Point
        mscanShadowed !acc !ps =
          if ps <= pe
          then let !trBump = bump ps
                   !accBump = fastSetInsert trBump acc
               in if not $ isClear trBump  -- not moving out of shadow
                  then mscanShadowed accBump (ps+1)
                  else let shallowBump = B ps d
                           cmp :: Bump -> Bump -> Ordering
                           {-# INLINE cmp #-}
                           cmp = dsteeper shallowBump
                           nsp = maximumBy cmp eHull
                           nsHull = addHull cmp shallowBump sHull
                           ns = (dline nsp shallowBump, nsHull)
                       in mscanVisible accBump ns (ps+1)
          else acc  -- reached end while in shadow

    in assert (r >= d && d >= 0 && pe >= ps0 `blame` (r,d,s0,e0,ps0,pe))
         outside

-- | Check if the line from the second point to the first is more steep
-- than the line from the third point to the first. This is related
-- to the formal notion of gradient (or angle), but hacked wrt signs
-- to work fast in this particular setup. Returns True for ill-defined lines.
steeper :: Bump -> Bump -> Bump -> Ordering
{-# INLINE steeper #-}
steeper (B xf yf) (B x1 y1) (B x2 y2) =
  compare ((yf - y2)*(xf - x1)) ((yf - y1)*(xf - x2))

-- | Extends a convex hull of bumps with a new bump. Nothing needs to be done
-- if the new bump already lies within the hull. The first argument is
-- typically `steeper`, optionally negated, applied to the second argument.
addHull :: (Bump -> Bump -> Ordering)  -- ^ a comparison function
        -> Bump                        -- ^ a new bump to consider
        -> ConvexHull  -- ^ a convex hull of bumps represented as a list
        -> ConvexHull
{-# INLINE addHull #-}
addHull cmp new = (new :) . go
 where
  go (a:b:cs) | cmp b a /= GT = go (b:cs)
  go l = l

-- | Create a line from two points. Debug: check if well-defined.
dline :: Bump -> Bump -> Line
{-# INLINE dline #-}
dline p1 p2 =
  let line = Line p1 p2
  in
#ifdef WITH_EXPENSIVE_ASSERTIONS
    assert (uncurry blame $ _debugLine line)
#endif
      line

-- | Compare steepness of @(p1, f)@ and @(p2, f)@.
-- Debug: Verify that the results of 2 independent checks are equal.
dsteeper :: Bump -> Bump -> Bump -> Ordering
{-# INLINE dsteeper #-}
dsteeper = \f p1 p2 ->
  let res = steeper f p1 p2
  in
#ifdef WITH_EXPENSIVE_ASSERTIONS
     assert (res == _debugSteeper f p1 p2)
#endif
     res

-- | The X coordinate, represented as a fraction, of the intersection of
-- a given line and the line of diagonals of diamonds at distance
-- @d@ from (0, 0).
intersect :: Line -> Distance -> (Int, Int)
{-# INLINE intersect #-}
intersect (Line (B x y) (B xf yf)) d =
#ifdef WITH_EXPENSIVE_ASSERTIONS
  assert (allB (>= 0) [y, yf])
#endif
    ((d - y)*(xf - x) + x*(yf - y), yf - y)
{-
Derivation of the formula:
The intersection point (xt, yt) satisfies the following equalities:
yt = d
(yt - y) (xf - x) = (xt - x) (yf - y)
hence
(yt - y) (xf - x) = (xt - x) (yf - y)
(d - y) (xf - x) = (xt - x) (yf - y)
(d - y) (xf - x) + x (yf - y) = xt (yf - y)
xt = ((d - y) (xf - x) + x (yf - y)) / (yf - y)

General remarks:
A diamond is denoted by its left corner. Hero at (0, 0).
Order of processing in the first quadrant rotated by 45 degrees is
 45678
  123
   @
so the first processed diamond is at (-1, 1). The order is similar
as for the restrictive shadow casting algorithm and reversed wrt PFOV.
The line in the curent state of mscan is called the shallow line,
but it's the one that delimits the view from the left, while the steep
line is on the right, opposite to PFOV. We start scanning from the left.

The Point coordinates are cartesian. The Bump coordinates are cartesian,
translated so that the hero is at (0, 0) and rotated so that he always
looks at the first (rotated 45 degrees) quadrant. The (Progress, Distance)
cordinates coincide with the Bump coordinates, unlike in PFOV.
-}

-- | Debug functions for DFOV:

-- | Debug: calculate steeper for DFOV in another way and compare results.
_debugSteeper :: Bump -> Bump -> Bump -> Ordering
{-# INLINE _debugSteeper #-}
_debugSteeper f@(B _xf yf) p1@(B _x1 y1) p2@(B _x2 y2) =
  assert (allB (>= 0) [yf, y1, y2]) $
  let (n1, k1) = intersect (Line p1 f) 0
      (n2, k2) = intersect (Line p2 f) 0
  in compare (k1 * n2) (n1 * k2)

-- | Debug: check if a view border line for DFOV is legal.
_debugLine :: Line -> (Bool, String)
{-# INLINE _debugLine #-}
_debugLine line@(Line (B x1 y1) (B x2 y2))
  | not (allB (>= 0) [y1, y2]) =
      (False, "negative coordinates: " ++ show line)
  | y1 == y2 && x1 == x2 =
      (False, "ill-defined line: " ++ show line)
  | y1 == y2 =
      (False, "horizontal line: " ++ show line)
  | crossL0 =
      (False, "crosses the X axis below 0: " ++ show line)
  | crossG1 =
      (False, "crosses the X axis above 1: " ++ show line)
  | otherwise = (True, "")
 where
  (n, k)  = line `intersect` 0
  (q, r)  = if k == 0 then (0, 0) else n `divMod` k
  crossL0 = q < 0  -- q truncated toward negative infinity
  crossG1 = q >= 1 && (q > 1 || r /= 0)
