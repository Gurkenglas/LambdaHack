{-# LANGUAGE DeriveGeneric #-}
-- | The type of kinds of rooms, halls and passages.
module Game.LambdaHack.Content.PlaceKind
  ( PlaceKind(..), makeData
  , Cover(..), Fence(..)
  , PlaceEntry(..), EntryMap, deadEndId
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , validateSingle, validateAll
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import           Control.DeepSeq
import           Data.Binary
import           Data.Char (chr)
import qualified Data.EnumMap.Strict as EM
import qualified Data.Text as T
import           GHC.Generics (Generic)

import Game.LambdaHack.Common.ContentData
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Content.TileKind (TileKind)

-- | Parameters for the generation of small areas within a dungeon level.
data PlaceKind = PlaceKind
  { psymbol       :: Char          -- ^ a symbol
  , pname         :: Text          -- ^ short description, singular or plural
  , pfreq         :: Freqs PlaceKind  -- ^ frequency within groups
  , prarity       :: Rarity        -- ^ rarity on given depths
  , pcover        :: Cover         -- ^ how to fill whole place using the corner
  , pfence        :: Fence         -- ^ whether to fence place with solid border
  , ptopLeft      :: [Text]        -- ^ plan of the top-left corner of the place
  , poverrideDark :: [(Char, GroupName TileKind)]  -- ^ dark legend override
  , poverrideLit  :: [(Char, GroupName TileKind)]  -- ^ lit legend override
  }
  deriving (Show, Generic)  -- No Eq and Ord to make extending logically sound

instance NFData PlaceKind

-- | A method of filling the whole area (except for CVerbatim and CMirror,
-- which are just placed in the middle of the area) by transforming
-- a given corner.
data Cover =
    CAlternate  -- ^ reflect every other corner, overlapping 1 row and column
  | CStretch    -- ^ fill symmetrically 4 corners and stretch their borders
  | CReflect    -- ^ tile separately and symmetrically quarters of the place
  | CVerbatim   -- ^ just build the given interior, without filling the area
  | CMirror     -- ^ build the given interior in one of 4 mirrored variants
  deriving (Show, Eq, Generic)

instance NFData Cover

-- | The choice of a fence type for the place.
data Fence =
    FWall   -- ^ put a solid wall fence around the place
  | FFloor  -- ^ leave an empty space, like the room's floor
  | FGround -- ^ leave an empty space, like the cave's ground
  | FNone   -- ^ skip the fence and fill all with the place proper
  deriving (Show, Eq, Generic)

instance NFData Fence

data PlaceEntry =
    PEntry (ContentId PlaceKind)
  | PAround (ContentId PlaceKind)
  | PEnd (ContentId PlaceKind)
  deriving (Show, Eq, Generic)

instance Binary PlaceEntry

-- | Entries of places on the map.
type EntryMap = EM.EnumMap Point PlaceEntry

deadEndId :: ContentId PlaceKind
{-# INLINE deadEndId #-}
deadEndId = ContentId 0

validateOverride :: [(Char, GroupName TileKind)] -> [Text]
validateOverride ov =
  let symbols = sort $ map fst ov
      duplicated = filter (uncurry (==)) $ zip symbols (chr 0 : symbols)
  in if null duplicated
     then []
     else [ "duplicated override symbols:"
            <+> T.pack (intersperse ' ' $ map fst duplicated) ]

-- | Catch invalid place kind definitions. In particular, verify that
-- the top-left corner map is rectangular and not empty.
validateSingle :: PlaceKind -> [Text]
validateSingle PlaceKind{..} =
  let dxcorner = case ptopLeft of
        [] -> 0
        l : _ -> T.length l
  in [ "top-left corner empty" | dxcorner == 0 ]
     ++ [ "top-left corner not rectangular"
        | any (/= dxcorner) (map T.length ptopLeft) ]
     ++ validateRarity prarity
     ++ validateOverride poverrideDark
     ++ validateOverride poverrideLit

-- | Validate all place kinds.
validateAll :: ContentData TileKind -> [PlaceKind] -> ContentData PlaceKind
            -> [Text]
validateAll cotile content _ =
  let overrides place = poverrideDark place ++ poverrideLit place
      missingOverride = filter (not . omemberGroup cotile)
                        $ concatMap (map snd . overrides) content
  in [ "override tile groups not in content:" <+> tshow missingOverride
     | not $ null missingOverride ]

makeData :: ContentData TileKind -> [PlaceKind] -> ContentData PlaceKind
makeData cotile =
  makeContentData "PlaceKind" pname pfreq validateSingle (validateAll cotile)
