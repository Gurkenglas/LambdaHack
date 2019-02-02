-- | General content types and operations.
module Game.LambdaHack.Common.Kind
  ( ContentId, ContentData, COps(..)
  , emptyCOps
  , okind, omemberGroup, oisSingletonGroup, ouniqGroup, opick
  , ofoldlWithKey', ofoldlGroup', omapVector, oimapVector
  , olength, linearInterpolation
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import           Game.LambdaHack.Common.ContentData
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Content.CaveKind
import           Game.LambdaHack.Content.ItemKind
import           Game.LambdaHack.Content.ModeKind
import           Game.LambdaHack.Content.PlaceKind
import           Game.LambdaHack.Content.RuleKind
import           Game.LambdaHack.Content.TileKind

-- | Operations for all content types, gathered together.
data COps = COps
  { cocave        :: ContentData CaveKind   -- server only
  , coitem        :: ContentData ItemKind
  , comode        :: ContentData ModeKind   -- server only
  , coplace       :: ContentData PlaceKind  -- server only, so far
  , corule        :: RuleContent
  , cotile        :: ContentData TileKind
  , coItemSpeedup :: IA.ItemSpeedup
  , coTileSpeedup :: TileSpeedup
  }

instance Show COps where
  show _ = "game content"

instance Eq COps where
  (==) _ _ = True

emptyCOps :: COps
emptyCOps = COps
  { cocave  = emptyContentData
  , coitem  = emptyContentData
  , comode  = emptyContentData
  , coplace = emptyContentData
  , corule  = emptyRuleContent
  , cotile  = emptyContentData
  , coItemSpeedup = IA.emptyItemSpeedup
  , coTileSpeedup = emptyTileSpeedup
  }
