{-# LANGUAGE RankNTypes #-}
-- | Screen overlays.
module Game.LambdaHack.Client.UI.Overlay
  ( -- * AttrLine
    AttrLine, emptyAttrLine, textToAL, textFgToAL, stringToAL, (<+:>)
    -- * Overlay
  , Overlay, IntOverlay
  , splitAttrLine, indentSplitAttrLine, glueLines, updateLine
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , linesAttr, splitAttrPhrase
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import qualified Data.Text as T

import           Game.LambdaHack.Common.Point
import qualified Game.LambdaHack.Definition.Color as Color
import           Game.LambdaHack.Definition.Defs

-- * AttrLine

-- | Line of colourful text.
type AttrLine = [Color.AttrCharW32]

emptyAttrLine :: Int -> AttrLine
emptyAttrLine w = replicate w Color.spaceAttrW32

textToAL :: Text -> AttrLine
textToAL !t =
  let f c l = let !ac = Color.attrChar1ToW32 c
              in ac : l
  in T.foldr f [] t

textFgToAL :: Color.Color -> Text -> AttrLine
textFgToAL !fg !t =
  let f ' ' l = Color.spaceAttrW32 : l
                  -- for speed and simplicity (testing if char is a space)
                  -- we always keep the space @White@
      f c l = let !ac = Color.attrChar2ToW32 fg c
              in ac : l
  in T.foldr f [] t

stringToAL :: String -> AttrLine
stringToAL = map Color.attrChar1ToW32

infixr 6 <+:>  -- matches Monoid.<>
(<+:>) :: AttrLine -> AttrLine -> AttrLine
(<+:>) [] l2 = l2
(<+:>) l1 [] = l1
(<+:>) l1 l2 = l1 ++ [Color.spaceAttrW32] ++ l2

-- * Overlay

-- | A series of screen lines that either fit the width of the screen
-- or are intended for truncation when displayed. The length of overlay
-- may exceed the length of the screen, unlike in @SingleFrame@.
type Overlay = [AttrLine]

-- | A series of screen lines with points at which they should ber overlayed
-- over the base frame or a blank screen, depending on context.
-- The point is represented as in integer that is an index into the
-- frame character array.
-- The lines either fit the width of the screen or are intended
-- for truncation when displayed. The positions of lines may fall outside
-- the length of the screen, too, unlike in @SingleFrame@. Then they are
-- simply not shown.
type IntOverlay = [(PointI, AttrLine)]

-- | Split a string into lines. Avoids ending the line with
-- a character other than space. Space characters are removed
-- from the start, but never from the end of lines. Newlines are respected.
--
-- Note that we only split wrt @White@ space, nothing else.
splitAttrLine :: X -> AttrLine -> Overlay
splitAttrLine w l =
  concatMap (splitAttrPhrase w . dropWhile (== Color.spaceAttrW32))
  $ linesAttr l

indentSplitAttrLine :: X -> AttrLine -> Overlay
indentSplitAttrLine w l =
  -- First line could be split at @w@, not @w - 1@, but it's good enough.
  let ts = splitAttrLine (w - 1) l
  in case ts of
    [] -> []
    hd : tl -> hd : map ([Color.spaceAttrW32] ++) tl

linesAttr :: AttrLine -> Overlay
linesAttr l | null l = []
            | otherwise = h : if null t then [] else linesAttr (tail t)
 where (h, t) = span (/= Color.retAttrW32) l

-- We consider only these, because they are short and form a closed category.
nonbreakableRev :: [AttrLine]
nonbreakableRev = map stringToAL ["eht", "a", "na", "ehT", "A", "nA"]

breakAtSpace :: AttrLine -> (AttrLine, AttrLine)
breakAtSpace lRev =
  let (pre, post) = break (== Color.spaceAttrW32) lRev
  in case post of
    c : rest | c == Color.spaceAttrW32 ->
      if any (`isPrefixOf` rest) nonbreakableRev
      then let (pre2, post2) = breakAtSpace rest
           in (pre ++ c : pre2, post2)
      else (pre, post)
    _ -> (pre, post)  -- no space found, give up

splitAttrPhrase :: X -> AttrLine -> Overlay
splitAttrPhrase w xs
  | w >= length xs = [xs]  -- no problem, everything fits
  | otherwise =
      let (pre, postRaw) = splitAt w xs
          preRev = reverse pre
          ((ppre, ppost), post) = case postRaw of
            c : rest | c == Color.spaceAttrW32
                       && not (any (`isPrefixOf` preRev) nonbreakableRev) ->
              (([], preRev), rest)
            _ -> (breakAtSpace preRev, postRaw)
          testPost = dropWhileEnd (== Color.spaceAttrW32) ppost
      in if null testPost
         then pre : splitAttrPhrase w post
         else reverse ppost : splitAttrPhrase w (reverse ppre ++ post)

glueLines :: Overlay -> Overlay -> Overlay
glueLines ov1 ov2 = reverse $ glue (reverse ov1) ov2
 where glue [] l = l
       glue m [] = m
       glue (mh : mt) (lh : lt) = reverse lt ++ (mh <+:> lh) : mt

-- @f@ should not enlarge the line beyond screen width.
updateLine :: Int -> (AttrLine -> AttrLine) -> Overlay -> Overlay
updateLine n f ov =
  let upd k (l : ls) = if k == 0
                       then f l : ls
                       else l : upd (k - 1) ls
      upd _ [] = []
  in upd n ov
