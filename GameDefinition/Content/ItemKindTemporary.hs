-- | Temporary aspect pseudo-item definitions.
module Content.ItemKindTemporary
  ( temporaries
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import Game.LambdaHack.Common.Color
import Game.LambdaHack.Common.Dice
import Game.LambdaHack.Common.Flavour
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Content.ItemKind

temporaries :: [ItemKind]
temporaries =
  [tmpStrengthened, tmpWeakened, tmpProtectedMelee, tmpProtectedRanged, tmpVulnerable, tmpFast20, tmpSlow10, tmpFarSighted, tmpNoctovision, tmpKeenSmelling, tmpResolute, tmpDrunk, tmpRegenerating, tmpPoisoned, tmpSlow10Resistant, tmpPoisonResistant]

tmpStrengthened,    tmpWeakened, tmpProtectedMelee, tmpProtectedRanged, tmpVulnerable, tmpFast20, tmpSlow10, tmpFarSighted, tmpNoctovision, tmpKeenSmelling, tmpResolute, tmpDrunk, tmpRegenerating, tmpPoisoned, tmpSlow10Resistant, tmpPoisonResistant :: ItemKind

-- The @name@ is be used in item description, so it should be an adjective
-- describing the temporary set of aspects.
tmpAs :: Text -> [Aspect] -> ItemKind
tmpAs name aspects = ItemKind
  { isymbol  = '+'
  , iname    = name
  , ifreq    = [(toGroupName name, 1), ("temporary conditions", 1)]
  , iflavour = zipPlain [BrWhite]
  , icount   = 1
  , irarity  = [(1, 1)]
  , iverbHit = "affect"
  , iweight  = 0
  , idamage  = toDmg 0
  , iaspects = -- timeout is 0; activates and vanishes soon,
               -- depending on initial timer setting
               aspects
  , ieffects = let tmp = Temporary $ "be no longer" <+> name
               in [Periodic, Recharging tmp, OnSmash tmp]
  , ifeature = [Identified, Fragile, Durable]  -- hack: destroy on drop
  , idesc    = ""
  , ikit     = []
  }

tmpStrengthened = tmpAs "strengthened" [AddHurtMelee 20]
tmpWeakened = tmpAs "weakened" [AddHurtMelee (-20)]
tmpProtectedMelee = tmpAs "protected melee" [AddArmorMelee 50]
tmpProtectedRanged = tmpAs "protected ranged" [AddArmorRanged 25]
tmpVulnerable = tmpAs "defenseless" [ AddArmorMelee (-50)
                                    , AddArmorRanged (-25) ]
tmpFast20 = tmpAs "fast 20" [AddSpeed 20]
tmpSlow10 = tmpAs "slow 10" [AddSpeed (-10)]
tmpFarSighted = tmpAs "far-sighted" [AddSight 5]
tmpNoctovision = tmpAs "shiny-eyed" [AddNocto 2]
tmpKeenSmelling = tmpAs "keen-smelling" [AddSmell 2]
tmpResolute = tmpAs "resolute" [AddMaxCalm 60]
tmpDrunk = tmpAs "drunk" [ AddHurtMelee 30  -- fury
                         , AddArmorMelee (-20)
                         , AddArmorRanged (-20)
                         , AddSight (-8)
                         ]
tmpRegenerating =
  let tmp = tmpAs "regenerating" []
  in tmp { icount = 7 + d 5
         , ieffects = Recharging (RefillHP 1) : ieffects tmp
         }
tmpPoisoned =
  let tmp = tmpAs "poisoned" []
  in tmp { icount = 7 + d 5
         , ieffects = Recharging (RefillHP (-1)) : ieffects tmp
         }
tmpSlow10Resistant =
  let tmp = tmpAs "slow resistant" []
  in tmp { icount = 7 + d 5
         , ieffects = Recharging (DropItem COrgan "slow 10") : ieffects tmp
         }
tmpPoisonResistant =
  let tmp = tmpAs "poison resistant" []
  in tmp { icount = 7 + d 5
         , ieffects = Recharging (DropItem COrgan "poisoned") : ieffects tmp
         }
