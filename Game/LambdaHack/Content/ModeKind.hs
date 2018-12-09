{-# LANGUAGE DeriveGeneric #-}
-- | The type of kinds of game modes.
module Game.LambdaHack.Content.ModeKind
  ( ModeKind(..), makeData
  , Caves, Roster(..), Outcome(..)
  , HiCondPoly, HiSummand, HiPolynomial, HiIndeterminant(..)
  , Player(..), LeaderMode(..), AutoLeader(..)
  , horrorGroup, genericEndMessages
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , validateSingle, validateAll
  , validateSingleRoster, validateSinglePlayer, hardwiredModeGroups
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import           Control.DeepSeq
import           Data.Binary
import qualified Data.Text as T
import           GHC.Generics (Generic)

import qualified Game.LambdaHack.Common.Ability as Ability
import           Game.LambdaHack.Common.ContentData
import qualified Game.LambdaHack.Common.Dice as Dice
import           Game.LambdaHack.Content.CaveKind (CaveKind)
import           Game.LambdaHack.Content.ItemKind (ItemKind)

-- | Game mode specification.
data ModeKind = ModeKind
  { msymbol :: Char            -- ^ a symbol
  , mname   :: Text            -- ^ short description
  , mfreq   :: Freqs ModeKind  -- ^ frequency within groups
  , mroster :: Roster          -- ^ players taking part in the game
  , mcaves  :: Caves           -- ^ arena of the game
  , mendMsg :: [(Outcome, Text)]
                               -- ^ messages displayed at particular game ends;
                               --   if no message, the screen is skipped
  , mdesc   :: Text            -- ^ description
  }
  deriving (Show, Generic)

instance NFData ModeKind

-- | Requested cave groups for particular level intervals.
type Caves = [([Int], [GroupName CaveKind])]

-- | The specification of players for the game mode.
data Roster = Roster
  { rosterList  :: [(Player, [(Int, Dice.Dice, GroupName ItemKind)])]
      -- ^ players in the particular team and levels, numbers and groups
      --   of their initial members
  , rosterEnemy :: [(Text, Text)]  -- ^ the initial enmity matrix
  , rosterAlly  :: [(Text, Text)]  -- ^ the initial aliance matrix
  }
  deriving (Show, Generic)

instance NFData Roster

-- | Outcome of a game.
data Outcome =
    Killed    -- ^ the faction was eliminated
  | Defeated  -- ^ the faction lost the game in another way
  | Camping   -- ^ game is supended
  | Conquer   -- ^ the player won by eliminating all rivals
  | Escape    -- ^ the player escaped the dungeon alive
  | Restart   -- ^ game is restarted
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

instance Binary Outcome

instance NFData Outcome

-- | Conditional polynomial representing score calculation for this player.
type HiCondPoly = [HiSummand]

type HiSummand = (HiPolynomial, [Outcome])

type HiPolynomial = [(HiIndeterminant, Double)]

data HiIndeterminant =
    HiConst
  | HiLoot
  | HiSprint
  | HiBlitz
  | HiSurvival
  | HiKill
  | HiLoss
  deriving (Show, Eq, Ord, Generic)

instance Binary HiIndeterminant

instance NFData HiIndeterminant

-- | Properties of a particular player.
data Player = Player
  { fname        :: Text        -- ^ name of the player
  , fgroups      :: [GroupName ItemKind]
                                -- ^ names of actor groups that may naturally
                                --   fall under player's control, e.g., upon
                                --   spawning or summoning
  , fskillsOther :: Ability.Skills
                                -- ^ fixed skill modifiers to the non-leader
                                --   actors; also summed with skills implied
                                --   by ftactic (which is not fixed)
  , fcanEscape   :: Bool        -- ^ the player can escape the dungeon
  , fneverEmpty  :: Bool        -- ^ the faction declared killed if no actors
  , fhiCondPoly  :: HiCondPoly  -- ^ score polynomial for the player
  , fhasGender   :: Bool        -- ^ whether actors have gender
  , ftactic      :: Ability.Tactic
                                -- ^ non-leaders behave according to this
                                --   tactic; can be changed during the game
  , fleaderMode  :: LeaderMode  -- ^ the mode of switching the leader
  , fhasUI       :: Bool        -- ^ does the faction have a UI client
                                --   (for control or passive observation)
  }
  deriving (Show, Eq, Generic)

instance Binary Player

instance NFData Player

-- | If a faction with @LeaderUI@ and @LeaderAI@ has any actor, it has a leader.
data LeaderMode =
    LeaderNull  -- ^ faction can have no leader, is whole under AI control
  | LeaderAI AutoLeader -- ^ leader under AI control
  | LeaderUI AutoLeader -- ^ leader under UI control, assumes @fhasUI@
  deriving (Show, Eq, Ord, Generic)

instance Binary LeaderMode

instance NFData LeaderMode

data AutoLeader = AutoLeader
  { autoDungeon :: Bool
      -- ^ leader switching between levels is automatically done by the server
      --   and client is not permitted to change to leaders from other levels
      --   (the frequency of leader level switching done by the server
      --   is controlled by @RuleKind.rleadLevelClips@);
      --   if the flag is @False@, server still does a subset
      --   of the automatic switching, e.g., when the old leader dies
      --   and no other actor of the faction resides on his level,
      --   but the client (particularly UI) is expected to do changes as well
  , autoLevel   :: Bool
      -- ^ client is discouraged from leader switching (e.g., because
      --   non-leader actors have the same skills as leader);
      --   server is guaranteed to switch leader within a level very rarely,
      --   e.g., when the old leader dies;
      --   if the flag is @False@, server still does a subset
      --   of the automatic switching, but the client is expected to do more,
      --   because it's advantageous for that kind of a faction
  }
  deriving (Show, Eq, Ord, Generic)

instance Binary AutoLeader

instance NFData AutoLeader

horrorGroup :: GroupName ItemKind
horrorGroup = "horror"

genericEndMessages :: [(Outcome, Text)]
genericEndMessages =
  [ (Killed, "Let's hope a rescue party arrives in time!" )
  , (Defeated, "Let's hope your new overlords let you live." )
  , (Camping, "See you soon, stronger and braver!" )
  , (Conquer, "Can it be done in a better style, though?" )
  , (Escape, "Can it be done more efficiently, though?" )
  , (Restart, "This time for real." ) ]

-- | Catch invalid game mode kind definitions.
validateSingle :: ModeKind -> [Text]
validateSingle ModeKind{..} =
  [ "mname longer than 20" | T.length mname > 20 ]
  ++ let f cave@(ns, l) =
           [ "not enough or too many levels for required cave groups:"
             <+> tshow cave
           | length ns /= length l ]
     in concatMap f mcaves
  ++ validateSingleRoster mcaves mroster

-- | Checks, in particular, that there is at least one faction with fneverEmpty
-- or the game would get stuck as soon as the dungeon is devoid of actors.
validateSingleRoster :: Caves -> Roster -> [Text]
validateSingleRoster caves Roster{..} =
  [ "no player keeps the dungeon alive"
  | all (not . fneverEmpty . fst) rosterList ]
  ++ [ "not exactly one UI client"
     | length (filter (fhasUI . fst) rosterList) /= 1 ]
  ++ concatMap (validateSinglePlayer . fst) rosterList
  ++ let checkPl field pl =
           [ pl <+> "is not a player name in" <+> field
           | all ((/= pl) . fname . fst) rosterList ]
         checkDipl field (pl1, pl2) =
           [ "self-diplomacy in" <+> field | pl1 == pl2 ]
           ++ checkPl field pl1
           ++ checkPl field pl2
     in concatMap (checkDipl "rosterEnemy") rosterEnemy
        ++ concatMap (checkDipl "rosterAlly") rosterAlly
  ++ let keys = concatMap fst caves
         f (_, l) = concatMap g l
         g i3@(ln, _, _) =
           [ "initial actor levels not among caves:" <+> tshow i3
           | ln `notElem` keys ]
     in concatMap f rosterList

validateSinglePlayer :: Player -> [Text]
validateSinglePlayer Player{..} =
  [ "fname empty:" <+> fname | T.null fname ]
  ++ [ "no UI client, but UI leader:" <+> fname
     | not fhasUI && case fleaderMode of
                       LeaderUI _ -> True
                       _ -> False ]
  ++ [ "fskillsOther not negative:" <+> fname
     | any ((>= 0) . snd) $ Ability.skillsToList fskillsOther ]

-- | Validate game mode kinds together.
validateAll :: ContentData CaveKind
            -> ContentData ItemKind
            -> [ModeKind]
            -> ContentData ModeKind
            -> [Text]
validateAll cocave coitem content comode =
  let caveGroups = concatMap snd . mcaves
      missingCave = filter (not . omemberGroup cocave)
                    $ concatMap caveGroups content
      f Roster{rosterList} =
        concatMap (\(p, l) -> delete horrorGroup (fgroups p)
                              ++ map (\(_, _, grp) -> grp) l)
                  rosterList
      missingRosterItems = filter (not . omemberGroup coitem)
                           $ concatMap (f . mroster) content
      hardwiredAbsent = filter (not . omemberGroup comode) hardwiredModeGroups
  in [ "cave groups not in content:" <+> tshow missingCave
     | not $ null missingCave ]
     ++ [ "roster item groups not in content:" <+> tshow missingRosterItems
        | not $ null missingRosterItems ]
     ++ [ "Hardwired groups not in content:" <+> tshow hardwiredAbsent
        | not $ null hardwiredAbsent ]

hardwiredModeGroups :: [GroupName ModeKind]
hardwiredModeGroups = [ "campaign scenario", "starting", "starting JS" ]

makeData :: ContentData CaveKind
         -> ContentData ItemKind
         -> [ModeKind]
         -> ContentData ModeKind
makeData cocave coitem =
  makeContentData "ModeKind" mname mfreq validateSingle
                  (validateAll cocave coitem)
