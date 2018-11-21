-- | Descripitons of items.
module Game.LambdaHack.Client.UI.ItemDescription
  ( partItem, partItemShort, partItemActor, partItemHigh, partItemWs
  , partItemWsRanged, partItemShortAW, partItemMediumAW, partItemShortWownW
  , viewItem, itemDesc
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , show64With2, partItemN, textAllPowers, partItemWsR
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.EnumMap.Strict as EM
import           Data.Int (Int64)
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU

import           Game.LambdaHack.Client.UI.EffectDescription
import           Game.LambdaHack.Client.UI.Overlay
import qualified Game.LambdaHack.Common.Ability as Ability
import qualified Game.LambdaHack.Common.Color as Color
import           Game.LambdaHack.Common.Container
import qualified Game.LambdaHack.Common.Dice as Dice
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Flavour
import           Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.Time
import qualified Game.LambdaHack.Content.ItemKind as IK

show64With2 :: Int64 -> Text
show64With2 n =
  let k = 100 * n `div` oneM
      l = k `div` 100
      x = k - l * 100
  in tshow l
     <> if | x == 0 -> ""
           | x < 10 -> ".0" <> tshow x
           | otherwise -> "." <> tshow x

-- | The part of speech describing the item parameterized by the number
-- of effects/aspects to show.
partItemN :: FactionId -> FactionDict -> Bool -> DetailLevel -> Int
          -> Time -> ItemFull -> ItemQuant
          -> (Bool, Bool, MU.Part, MU.Part)
partItemN side factionD ranged detailLevel maxWordsToShow localTime
          itemFull@ItemFull{itemBase, itemKind, itemSuspect}
          (itemK, itemTimer) =
  let flav = flavourToName $ jflavour itemBase
      arItem = aspectRecordFull itemFull
      timeout = IA.aTimeout arItem
      timeoutTurns = timeDeltaScale (Delta timeTurn) timeout
      temporary = not (null itemTimer) && timeout == 0
      charging startT = timeShift startT timeoutTurns > localTime
      it1 = filter charging itemTimer
      lenCh = length it1
      charges | lenCh == 0 || temporary = ""
              | itemK == 1 && lenCh == 1 = "(charging)"
              | itemK == lenCh = "(all charging)"
              | otherwise = "(" <> tshow lenCh <+> "charging)"
      skipRecharging = detailLevel <= DetailLow && lenCh >= itemK
      (powerTsRaw, rangedDamage) =
        textAllPowers detailLevel skipRecharging itemFull
      powerTs = powerTsRaw ++ if ranged then rangedDamage else []
      lsource = case jfid itemBase of
        Just fid | IK.iname itemKind `elem` ["impressed"] ->
          ["by" <+> if fid == side
                    then "us"
                    else gname (factionD EM.! fid)]
        _ -> []
      ts = lsource
           ++ take maxWordsToShow powerTs
           ++ ["(...)" | length powerTs > maxWordsToShow && maxWordsToShow > 0]
           ++ [charges | maxWordsToShow > 1]
      unique = IA.checkFlag Ability.Unique arItem
      name | temporary = "temporarily" <+> IK.iname itemKind
           | itemSuspect = flav <+> IK.iname itemKind
           | otherwise = IK.iname itemKind
      capName = if unique
                then MU.Capitalize $ MU.Text name
                else MU.Text name
  in ( not (null lsource) || temporary
     , unique, capName, MU.Phrase $ map MU.Text ts )

-- TODO: simplify the code a lot
textAllPowers :: DetailLevel -> Bool -> ItemFull -> ([Text], [Text])
textAllPowers detailLevel skipRecharging
              itemFull@ItemFull{itemKind, itemDisco} =
  let arItem = aspectRecordFull itemFull
      aspectsFull = case itemDisco of
        ItemDiscoMean IA.KindMean{..} | kmConst ->
          IA.aspectRecordToList kmMean  -- exact and collated
        ItemDiscoMean{} -> IK.iaspects itemKind
          -- doesn't completely lose the @Odds@ case, so better than
          -- the above, even if does not collate multiple skill bonuses
        ItemDiscoFull iAspect -> IA.aspectRecordToList iAspect
      timeoutAspect :: IK.Aspect -> Bool
      timeoutAspect IK.Timeout{} = True
      timeoutAspect _ = False
      -- Dice needed, not @Int@, so @arItem@ not consulted directly.
      -- If item not known fully and timeout under @Odds@, it's ignored.
      mtimeout = find timeoutAspect aspectsFull
      elab = IA.aELabel arItem
      periodic = IA.checkFlag Ability.Periodic arItem
      hurtMeleeAspect :: IK.Aspect -> Bool
      hurtMeleeAspect (IK.AddSkill Ability.SkHurtMelee _) = True
      hurtMeleeAspect _ = False
      active = IA.goesIntoEqp arItem
      splitA :: Bool -> DetailLevel -> [IK.Aspect] -> [Text]
      splitA secondPass detLev aspects =
        let ppA = kindAspectToSuffix
            ppE = effectToSuffix detLev
            reduce_a = maybe "?" tshow . Dice.reduceDice
            restEs | secondPass = []
                   | detLev >= DetailHigh
                     || not (IA.checkFlag Ability.MinorEffects arItem) =
                     IK.ieffects itemKind
                   | otherwise = []
            rechargingTs = T.intercalate " " $ filter (not . T.null)
                           $ map ppE $ IK.stripRecharging restEs
            onSmashTs = T.intercalate " " $ filter (not . T.null)
                        $ map ppE $ IK.stripOnSmash restEs
            durable = IA.checkFlag Ability.Durable arItem
            fragile = IA.checkFlag Ability.Fragile arItem
            noFraDur as = as `notElem` [ IK.SetFlag Ability.Durable
                                       , IK.SetFlag Ability.Fragile ]
            displayedAs | durable && fragile = filter noFraDur aspects
                        | otherwise = aspects
            aes = if active
                  then map ppA displayedAs ++ map ppE restEs
                  else map ppE restEs ++ map ppA displayedAs
            periodicOrTimeout =
              if | skipRecharging || secondPass || T.null rechargingTs -> ""
                 | periodic -> case mtimeout of
                     Nothing | durable && not fragile ->
                       "(each turn:" <+> rechargingTs <> ")"
                     Nothing ->
                       "(each turn until gone:" <+> rechargingTs <> ")"
                     Just (IK.Timeout t) ->
                       "(every" <+> reduce_a t <> ":"
                       <+> rechargingTs <> ")"
                     _ -> error $ "" `showFailure` mtimeout
                 | otherwise -> case mtimeout of
                     Nothing -> ""
                     Just (IK.Timeout t) ->
                       "(timeout" <+> reduce_a t <> ":"
                       <+> rechargingTs <> ")"
                     _ -> error $ "" `showFailure` mtimeout
            onSmash = if T.null onSmashTs then ""
                      else "(on smash:" <+> onSmashTs <> ")"
            -- Dice needed, not @Int@, so @arItem@ not consulted directly.
            -- If item not known fully and @AbHurtMelee@ under @Odds@,
            -- it's ignored.
            damage = case find hurtMeleeAspect aspects of
              _ | secondPass -> ""
              Just (IK.AddSkill Ability.SkHurtMelee hurtMelee) ->
                (if IK.idamage itemKind == 0
                 then "0d0"
                 else tshow (IK.idamage itemKind))
                <> affixDice hurtMelee <> "%"
              _ -> if IK.idamage itemKind == 0
                   then ""
                   else tshow (IK.idamage itemKind)
        in if detLev >= DetailHigh
              || detLev >= DetailMedium && T.null elab
           then [periodicOrTimeout] ++ [damage] ++ aes
                ++ [onSmash | detLev >= DetailAll]
           else [damage]
      IK.ThrowMod{IK.throwVelocity} = IA.aToThrow arItem
      speed = speedFromWeight (IK.iweight itemKind) throwVelocity
      meanDmg = ceiling $ Dice.meanDice (IK.idamage itemKind)
      minDeltaHP = xM meanDmg `divUp` 100
      aHurtMeleeOfItem = IA.getSkill Ability.SkHurtMelee arItem
      pmult = 100 + min 99 (max (-99) aHurtMeleeOfItem)
      prawDeltaHP = fromIntegral pmult * minDeltaHP
      pdeltaHP = modifyDamageBySpeed prawDeltaHP speed
      rangedDamageDesc = if pdeltaHP == 0
                         then []
                         else ["{avg" <+> show64With2 pdeltaHP <+> "ranged}"]
        -- Note that avg melee damage would be too complex to display here,
        -- because in case of @MOwned@ the owner is different than leader,
        -- so the value would be different than when viewing the item.
      splitTry secondPass ass =
        let splits = map (\det -> splitA secondPass det ass)
                         [minBound..maxBound]
            splitsToTry = drop (fromEnum detailLevel) splits
        in case filter (/= []) splitsToTry of
             detNonEmpty : _ -> detNonEmpty
             [] -> []
      aspectDescs =
        let aMain IK.AddSkill{} = True
            aMain _ = False
            (aspectsMain, aspectsAux) = partition aMain aspectsFull
        in filter (/= "")
           $ elab
             : splitTry False aspectsMain
             ++ if detailLevel >= DetailAll
                then splitTry True aspectsAux
                else []
  in (aspectDescs, rangedDamageDesc)

-- | The part of speech describing the item.
partItem :: FactionId -> FactionDict -> Time -> ItemFull -> ItemQuant
         -> (Bool, Bool, MU.Part, MU.Part)
partItem side factionD = partItemN side factionD False DetailMedium 4

partItemShort :: FactionId -> FactionDict -> Time -> ItemFull -> ItemQuant
              -> (Bool, Bool, MU.Part, MU.Part)
partItemShort side factionD = partItemN side factionD False DetailLow 4

partItemActor :: FactionId -> FactionDict -> Time -> ItemFull -> ItemQuant
              -> (Bool, Bool, MU.Part, MU.Part)
partItemActor side factionD = partItemN side factionD False DetailLow 0

partItemHigh :: FactionId -> FactionDict -> Time -> ItemFull -> ItemQuant
             -> (Bool, Bool, MU.Part, MU.Part)
partItemHigh side factionD = partItemN side factionD False DetailAll 100

-- The @count@ can be different than @itemK@ in @ItemFull@, e.g., when picking
-- a subset of items to drop.
partItemWsR :: FactionId -> FactionDict -> Bool -> Int -> Time -> ItemFull
            -> ItemQuant
            -> (Bool, MU.Part)
partItemWsR side factionD ranged count localTime itemFull kit =
  let (temporary, unique, name, powers) =
        partItemN side factionD ranged DetailMedium 4 localTime itemFull kit
      arItem = aspectRecordFull itemFull
      tmpCondition = IA.looksLikeCondition arItem
  in ( temporary
     , if | temporary && count == 1 -> MU.Phrase [name, powers]
          | temporary ->
              MU.Phrase [MU.Text $ tshow count <> "-fold", name, powers]
          | unique && count == 1 -> MU.Phrase ["the", name, powers]
          | tmpCondition && count == 1 -> MU.Phrase [name, powers]
          | tmpCondition ->
              let maxCount = Dice.supDice $ IK.icount $ itemKind itemFull
                  percent = 100 * count `divUp` maxCount
                  amount = tshow count <> "-strong"
                           <+> "(" <> tshow percent <> "%)"
              in MU.Phrase [MU.Text amount, name, powers]
          | otherwise -> MU.Phrase [MU.CarWs count name, powers] )

partItemWs :: FactionId -> FactionDict -> Int -> Time -> ItemFull -> ItemQuant
           -> (Bool, MU.Part)
partItemWs side factionD = partItemWsR side factionD False

partItemWsRanged :: FactionId -> FactionDict -> Int -> Time -> ItemFull
                 -> ItemQuant
                 -> (Bool, MU.Part)
partItemWsRanged side factionD = partItemWsR side factionD True

partItemShortAW :: FactionId -> FactionDict -> Time -> ItemFull -> ItemQuant
                -> MU.Part
partItemShortAW side factionD localTime itemFull kit =
  let (_, unique, name, _) = partItemShort side factionD localTime itemFull kit
  in if unique
     then MU.Phrase ["the", name]
     else MU.AW name

partItemMediumAW :: FactionId -> FactionDict -> Time -> ItemFull -> ItemQuant
                 -> MU.Part
partItemMediumAW side factionD localTime itemFull kit =
  let (_, unique, name, powers) =
        partItemN side factionD False DetailMedium 100 localTime itemFull kit
  in if unique
     then MU.Phrase ["the", name, powers]
     else MU.AW $ MU.Phrase [name, powers]

partItemShortWownW :: FactionId -> FactionDict -> MU.Part -> Time -> ItemFull
                   -> ItemQuant
                   -> MU.Part
partItemShortWownW side factionD partA localTime itemFull kit =
  let (_, _, name, _) = partItemShort side factionD localTime itemFull kit
  in MU.WownW partA name

viewItem :: ItemFull -> Color.AttrCharW32
{-# INLINE viewItem #-}
viewItem itemFull =
  Color.attrChar2ToW32 (flavourToColor $ jflavour $ itemBase itemFull)
                       (IK.isymbol $ itemKind itemFull)

itemDesc :: Bool -> FactionId -> FactionDict -> Int -> CStore -> Time -> LevelId
         -> ItemFull -> ItemQuant
         -> AttrLine
itemDesc markParagraphs side factionD aHurtMeleeOfOwner store localTime jlid
         itemFull@ItemFull{itemBase, itemKind, itemDisco, itemSuspect} kit =
  let (_, unique, name, powers) =
        partItemHigh side factionD localTime itemFull kit
      arItem = aspectRecordFull itemFull
      npowers = makePhrase [name, powers]
      IK.ThrowMod{IK.throwVelocity, IK.throwLinger} = IA.aToThrow arItem
      speed = speedFromWeight (IK.iweight itemKind) throwVelocity
      range = rangeFromSpeedAndLinger speed throwLinger
      tspeed | IA.looksLikeCondition arItem || IK.iweight itemKind == 0 = ""
             | speed < speedLimp = "When thrown, it drops at once."
             | speed < speedWalk = "When thrown, it travels only one meter and drops immediately."
             | otherwise =
               "When thrown, it flies with speed of"
               <+> tshow (fromSpeed speed `div` 10)
               <> if throwLinger /= 100
                  then " m/s and range" <+> tshow range <+> "m."
                  else " m/s."
      tsuspect = ["You are unsure what it does." | itemSuspect]
      (desc, aspectSentences, damageAnalysis) =
        let aspects = case itemDisco of
              ItemDiscoMean IA.KindMean{..} | kmConst ->
                IA.aspectRecordToList kmMean  -- exact and collated
              ItemDiscoMean{} -> IK.iaspects itemKind
                -- doesn't completely lose the @Odds@ case, so better than
                -- the above, even if does not collate multiple skill bonuses
              ItemDiscoFull iAspect -> IA.aspectRecordToList iAspect
            sentences = tsuspect ++ mapMaybe aspectToSentence aspects
            aHurtMeleeOfItem = IA.getSkill Ability.SkHurtMelee arItem
            meanDmg = ceiling $ Dice.meanDice (IK.idamage itemKind)
            dmgAn = if meanDmg <= 0 then "" else
              let multRaw = aHurtMeleeOfOwner
                            + if store `elem` [CEqp, COrgan]
                              then 0
                              else aHurtMeleeOfItem
                  mult = 100 + min 99 (max (-99) multRaw)
                  minDeltaHP = xM meanDmg `divUp` 100
                  rawDeltaHP = fromIntegral mult * minDeltaHP
                  pmult = 100 + min 99 (max (-99) aHurtMeleeOfItem)
                  prawDeltaHP = fromIntegral pmult * minDeltaHP
                  pdeltaHP = modifyDamageBySpeed prawDeltaHP speed
                  mDeltaHP = modifyDamageBySpeed minDeltaHP speed
              in "Against defenceless targets you would inflict around"
                   -- rounding and non-id items
                 <+> tshow meanDmg
                 <> "*" <> tshow mult <> "%"
                 <> "=" <> show64With2 rawDeltaHP
                 <+> "melee damage (min" <+> show64With2 minDeltaHP
                 <> ") and"
                 <+> tshow meanDmg
                 <> "*" <> tshow pmult <> "%"
                 <> "*" <> "speed^2"
                 <> "/" <> tshow (fromSpeed speedThrust `divUp` 10) <> "^2"
                 <> "=" <> show64With2 pdeltaHP
                 <+> "ranged damage (min" <+> show64With2 mDeltaHP
                 <> ") with it"
                 <> if Dice.infDice (IK.idamage itemKind)
                       == Dice.supDice (IK.idamage itemKind)
                    then "."
                    else "on average."
        in (IK.idesc itemKind, T.intercalate " " sentences, tspeed <+> dmgAn)
      weight = IK.iweight itemKind
      (scaledWeight, unitWeight)
        | weight > 1000 =
          (tshow $ fromIntegral weight / (1000 :: Double), "kg")
        | otherwise = (tshow weight, "g")
      onLevel = "on level" <+> tshow (abs $ fromEnum jlid) <> "."
      discoFirst = (if unique then "Discovered" else "First seen")
                   <+> onLevel
      whose fid = gname (factionD EM.! fid)
      sourceDesc =
        case jfid itemBase of
          Just fid | IA.looksLikeCondition arItem ->
            "Caused by" <+> (if fid == side then "us" else whose fid)
            <> ". First observed" <+> onLevel
          Just fid ->
            "Coming from" <+> whose fid
            <> "." <+> discoFirst
          _ -> discoFirst
      ikitNames = map (fromGroupName . fst) $ filter ((== COrgan) . snd)
                                            $ IK.ikit itemKind
      ikitDesc | null ikitNames = ""
               | otherwise = makeSentence
        [ "the actor also has organs of this kind:"
        , MU.Text $ T.intercalate ", " ikitNames ]
      colorSymbol = viewItem itemFull
      blurb =
        ((" "
          <> npowers
          <> (if markParagraphs then ":\n\n" else ": ")
          <> desc
          <> (if markParagraphs && not (T.null desc) then "\n\n" else ""))
         <+> (if weight > 0
              then makeSentence
                     ["Weighs around", MU.Text scaledWeight <> unitWeight]
              else ""))
        <+> aspectSentences
        <+> sourceDesc
        <+> damageAnalysis
        <> (if markParagraphs && not (T.null ikitDesc) then "\n\n" else "\n")
        <> ikitDesc
  in colorSymbol : textToAL blurb
