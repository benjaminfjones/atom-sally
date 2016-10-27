-- |
-- Module      :  Language.Sally.Translation
-- Copyright   :  Galois, Inc. 2016
-- License     :  BSD3
--
-- Maintainer  :  bjones@galois.com
-- Stability   :  experimental
-- Portability :  unknown
--
-- Translation from Atom's AST to Sally's AST.
--
{-# LANGUAGE OverloadedStrings #-}

module Language.Sally.Translation (
    translaborate
  , TrConfig(..)
) where

import Control.Arrow (second)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Sequence ((|>))
import qualified Data.Sequence as Seq
import Data.List ((\\))
import qualified Data.Text.Lazy as T
import System.Exit

import qualified Language.Atom.Types as ATyp
import qualified Language.Atom.Analysis    as AAna
import qualified Language.Atom.Elaboration as AEla
import qualified Language.Atom.Expressions as AExp
import qualified Language.Atom.UeMap       as AUe

import Language.Sally.Config
import Language.Sally.Types

import Debug.Trace

-- Entry Point from Atom -------------------------------------------------------

-- | Elaborate and translate an atom description to Sally. The 'TrResult' can
-- then be printed or written to disk.
translaborate :: Name
              -> TrConfig
              -> AEla.Atom ()
              -> IO (TrResult)
translaborate name config atom' = do
  let aname = T.unpack . textFromName $ name
  res <- AEla.elaborate AUe.emptyMap aname atom'
  case res of
   Nothing -> do
     putStrLn "ERROR: Design rule checks failed."
     exitWith (ExitFailure 1)
   Just (umap, (state, rules, chans, _ass, _cov, _prob)) ->
     return (translate config name state umap rules chans)


-- Main Translation Code -------------------------------------------------------

-- | Main translation function.
translate :: TrConfig
          -> Name
          -> AEla.StateHierarchy
          -> AUe.UeMap
          -> [AEla.Rule]
          -> [AEla.ChanInfo]
          -> TrResult
translate conf name hier umap rules chans =
  TrResult { tresConsts = tresConsts'
           , tresState  = tresState'
           , tresInit   = tresInit'
           , tresTrans  = tresTrans'
           , tresSystem = tresSystem'
           }
  where
    tresConsts'   = []  -- TODO support defined constants
    tresState'    = trState  conf name hier rules chans
    tresInit'     = trInit   conf name hier
    tresTrans'    = trRules  conf name tresState' umap rules
    tresSystem'   = trSystem conf name

-- | Translate types from Atom to Sally. Currently the unsigned int /
-- bitvector types are not supported.
trType :: AExp.Type -> SallyBaseType
trType t = case t of
  AExp.Bool   -> SBool
  AExp.Int8   -> SInt
  AExp.Int16  -> SInt
  AExp.Int32  -> SInt
  AExp.Int64  -> SInt
  AExp.Float  -> SReal
  AExp.Double -> SReal
  AExp.Word8  -> SInt
  AExp.Word16 -> SInt
  AExp.Word32 -> SInt
  AExp.Word64 -> SInt

trTypeConst :: AExp.Const -> SallyBaseType
trTypeConst = trType . AExp.typeOf

trConst :: AExp.Const -> SallyConst
trConst (AExp.CBool   x) = SConstBool x
trConst (AExp.CInt8   x) = SConstInt  (fromIntegral x)
trConst (AExp.CInt16  x) = SConstInt  (fromIntegral x)
trConst (AExp.CInt32  x) = SConstInt  (fromIntegral x)
trConst (AExp.CInt64  x) = SConstInt  (fromIntegral x)
trConst (AExp.CWord8  x) = SConstInt  (fromIntegral x)
trConst (AExp.CWord16 x) = SConstInt  (fromIntegral x)
trConst (AExp.CWord32 x) = SConstInt  (fromIntegral x)
trConst (AExp.CWord64 x) = SConstInt  (fromIntegral x)
trConst (AExp.CFloat  x) = SConstReal (toRational x)
trConst (AExp.CDouble x) = SConstReal (toRational x)

trConstE :: AExp.Const -> SallyExpr
trConstE = SELit . trConst

-- | Define the default value to initialize variables of the given expression
-- type to.
trInitForType :: AExp.Type -> SallyExpr
trInitForType t = SELit $ case t of
  AExp.Bool   -> SConstBool False
  AExp.Int8   -> SConstInt 0
  AExp.Int16  -> SConstInt 0
  AExp.Int32  -> SConstInt 0
  AExp.Int64  -> SConstInt 0
  AExp.Word8  -> SConstInt 0
  AExp.Word16 -> SConstInt 0
  AExp.Word32 -> SConstInt 0
  AExp.Word64 -> SConstInt 0
  AExp.Float  -> SConstReal 0
  AExp.Double -> SConstReal 0

trName :: ATyp.Name -> Name
trName = nameFromS

-- | Produce a state type declaration from the 'StateHierarchy' in Atom.
trState :: TrConfig
        -> Name
        -> AEla.StateHierarchy
        -> [AEla.Rule]
        -> [AEla.ChanInfo]
        -> SallyState
trState _conf name sh rules chans = SallyState (mkStateTypeName name) vars invars
  where
    invars = synthInvars  -- TODO expose input variables to DSL
    vars = if AEla.isHierarchyEmpty sh then []
           else go Nothing sh

    -- TODO (Maybe Name) for prefix is a little awkward here
    go :: Maybe Name -> AEla.StateHierarchy -> [(Name, SallyBaseType)]
    go prefix (AEla.StateHierarchy nm items) =
      concatMap (go (Just $ prefix `bangPrefix` (trName nm))) items
    go prefix (AEla.StateVariable nm c) =
      [(prefix `bangPrefix` (trName nm), trTypeConst c)]
    go prefix (AEla.StateChannel nm t) =
      let (chanVar, chanReady) = mkChanStateNames (prefix `bangPrefix` (trName nm))
      in [(chanVar, trType t), (chanReady, SBool)]
    go _prefix (AEla.StateArray _ _) = error "atom-sally does not yet support arrays"

    synthInvars :: [(Name, SallyBaseType)]
    synthInvars =
      -- declare one boolean input variable per CHANNEL, used to provide
      -- non-deterministic values on faulty channels
         trace (show name ++ ": " ++ show (length chans) ++ " chans") $  -- XXX
         [ (mkFaultChanValueName (AEla.cinfoId  c)
                                 (trName . uglyHack . AEla.cinfoName $ c), SBool)
         | c <- chans ]
      -- declare one boolean input variable per NODE, these are latched at the
      -- start of the trace and determine which nodes are faulty
      ++ [ (mkFaultNodeName (AEla.ruleId r) name, SBool)
         | r@(AEla.Rule{}) <- rules ]

bangPrefix :: Maybe Name -> Name -> Name
bangPrefix mn n = maybe n (`bangNames` n) mn

-- | Produce a predicate describing the initial state of the system.
trInit :: TrConfig -> Name -> AEla.StateHierarchy -> SallyStateFormula
trInit _conf name sh = SallyStateFormula (mkInitStateName name)
                                        (mkStateTypeName name)
                                        spred
  where
    spred = simplifyAnds $ if AEla.isHierarchyEmpty sh then (SPConst True)
                           else go Nothing sh

    -- general level call
    go :: Maybe Name -> AEla.StateHierarchy -> SallyPred
    go prefix (AEla.StateHierarchy nm items) =
      SPAnd (Seq.fromList $ map (go (Just $ prefix `bangPrefix` (trName nm))) items)
    go prefix (AEla.StateVariable nm c) =
      SPEq (varExpr' (prefix `bangPrefix` (trName nm))) (trConstE c)
    go prefix (AEla.StateChannel nm t) =
      let (chanVar, chanReady) = mkChanStateNames (prefix `bangPrefix` (trName nm))
      in SPAnd (  Seq.empty
               |> SPEq (varExpr' chanVar) (trInitForType t)
               |> SPEq (varExpr' chanReady) (trInitForType AExp.Bool))
    go _prefix (AEla.StateArray _ _) = error "atom-sally does not yet support arrays"

-- | Collect the state type name, initial states name, and master transition
-- name into a 'SallySystem' record.
trSystem :: TrConfig -> Name -> SallySystem
trSystem _conf name = SallySystem (mkTSystemName name)
                                  (mkStateTypeName name)
                                  (mkInitStateName name)
                                  (mkMasterTransName name)

-- | Translate Atom 'Rule's into 'SallyTransition's. One transition is
-- produced per rule, plus one master transition for use in defining the
-- transition system as a whole.
--
-- Note: Assertion and Coverage rules are ignored.
trRules :: TrConfig
        -> Name
        -> SallyState
        -> AUe.UeMap
        -> [AEla.Rule]
        -> [SallyTransition]
trRules _conf name st umap rules = (catMaybes $ map trRule rules) ++ [master]
  where trRule :: AEla.Rule -> Maybe SallyTransition
        trRule r@(AEla.Rule{}) = Just $ SallyTransition (mkTName r)
                                                        (mkStateTypeName name)
                                                        (mkLetBinds r)
                                                        (mkPred r)
        trRule _ = Nothing  -- skip assertions and coverage

        -- master transition is (for now) the disjunction of all minor
        -- transitions
        -- TODO add non-deterministic single transitions
        master = SallyTransition (mkMasterTransName name)
                                 (mkStateTypeName name)
                                 []
                                 (masterPred)
        minorTrans = map (SPExpr . SEVar . varFromName . mkTName) rules
        masterPred = simplifyOrs $ SPOr (Seq.fromList minorTrans)

        mkTName :: AEla.Rule -> Name
        mkTName r@(AEla.Rule{}) = mkTransitionName (AEla.ruleId r) name
        mkTName _ = error "impossible! assert or coverage rule found in mkTName"

        getUEs :: AEla.Rule -> [(AUe.Hash, SallyVar)]
        getUEs r = map (second trExprRef) . AAna.topo umap $ AEla.allUEs r

        mkLetBinds :: AEla.Rule -> [SallyLet]
        mkLetBinds r@(AEla.Rule{}) =
          let ues = getUEs r
          in map (\(h, v) -> (v, trUExpr umap ues h)) ues
        mkLetBinds _ = error "impossible! assert or coverage rule found in mkLetBinds"

        -- TODO Avoid the ugly name mangling hack here by having variables
        -- in Atom carry not a name, but a structured heirarchy of names that
        -- can be flattened differently depending on the compile target
        mkPred :: AEla.Rule -> SallyPred
        mkPred r@(AEla.Rule{}) =
          let ues = getUEs r
              lkErr h = "trRules: failed to lookup untyped expr " ++ show h
              lk h = fromMaybe (error $ lkErr h) $ lookup h ues

              vName muv = case muv of
                AUe.MUV _ n _    -> trName . uglyHack $ n
                AUe.MUVArray{}   -> error "trRules: arrays are not supported"
                AUe.MUVExtern{}  -> error "trRules: external vars are not supported"
                AUe.MUVChannel{} -> error "trRules: Chan can't appear in lhs of assign"
                AUe.MUVChannelReady{} ->
                  error "trRules: Chan can't appear in lhs of assign"
              handleAssign (muv, h) = SPEq (varExpr' (nextName . vName $ muv))
                                           (SEVar . lk $ h)
              handleLeftovers n = SPEq (varExpr' (nextName n))
                                       (varExpr' (stateName n))
              -- all state variables
              stVars = map fst (sVars st)
              -- state vars in this rule
              stVarsUsed = map (vName . fst) $ AEla.ruleAssigns r
              leftovers = stVars \\ stVarsUsed
              ops = map handleAssign (AEla.ruleAssigns r)
                 ++ map handleLeftovers leftovers

          in simplifyAnds $ SPAnd (Seq.fromList ops)
          -- TODO Important! add next. = state. for all other state vars, i.e.
          --      the ones which are not involved in an assignment
        mkPred _ = error "impossible! assert or coverage rule found in mkPred"

-- | s/\./!/g
uglyHack :: String -> String
uglyHack = map dotToBang
  where dotToBang '.' = '!'
        dotToBang c   = c

-- Translate Expressions -------------------------------------------------------

trUExpr :: AUe.UeMap -> [(AUe.Hash, SallyVar)] -> AUe.Hash -> SallyExpr
trUExpr umap ues h =
  case AUe.getUE h umap of
    AUe.MUVRef (AUe.MUV _ k _) -> varExpr' . stateName . trName . uglyHack $ k
    AUe.MUVRef (AUe.MUVArray _ _)  -> aLangErr "arrays"
    AUe.MUVRef (AUe.MUVExtern k _) -> aLangErr $ "external variable " ++ k
    AUe.MUVRef (AUe.MUVChannel _ k _) ->
      varExpr' . stateName . fst . mkChanStateNames . trName . uglyHack $ k
    AUe.MUVRef (AUe.MUVChannelReady _ k) ->
      varExpr' . stateName . snd . mkChanStateNames . trName . uglyHack $ k
    AUe.MUCast _ _     -> aLangErr "casting"
    AUe.MUConst x      -> SELit (trConst x)
    AUe.MUAdd _ _      -> addExpr a b
    AUe.MUSub _ _      -> subExpr a b
    AUe.MUMul _ _      -> multExpr a b
    AUe.MUDiv _ _      -> aLangErr "division"
    AUe.MUMod _ _      -> aLangErr "modular arithmetic"
    AUe.MUNot _        -> notExpr a
    AUe.MUAnd _        -> andExprs ops
    AUe.MUBWNot _      -> aLangErr "bitwise operations & bitvectors"
    AUe.MUBWAnd  _ _   -> aLangErr "bitwise operations & bitvectors"
    AUe.MUBWOr   _ _   -> aLangErr "bitwise operations & bitvectors"
    AUe.MUBWXor  _ _   -> aLangErr "bitwise operations & bitvectors"
    AUe.MUBWShiftL _ _ -> aLangErr "bitwise operations & bitvectors"
    AUe.MUBWShiftR _ _ -> aLangErr "bitwise operations & bitvectors"
    AUe.MUEq  _ _      -> eqExpr a b
    AUe.MULt  _ _      -> ltExpr a b
    AUe.MUMux _ _ _    -> muxExpr a b c
    AUe.MUF2B _        -> aLangErr "cast to Word32"
    AUe.MUD2B _        -> aLangErr "cast to Word64"
    AUe.MUB2F _        -> aLangErr "cast to Float"
    AUe.MUB2D _        -> aLangErr "cast to Double"
    -- math.h functions are not supported
    AUe.MUPi           -> mathHErr "M_PI"
    AUe.MUExp   _      -> mathHErr "exp"
    AUe.MULog   _      -> mathHErr "log"
    AUe.MUSqrt  _      -> mathHErr "sqrt"
    AUe.MUPow   _ _    -> mathHErr "pow"
    AUe.MUSin   _      -> mathHErr "sin"
    AUe.MUAsin  _      -> mathHErr "asin"
    AUe.MUCos   _      -> mathHErr "cos"
    AUe.MUAcos  _      -> mathHErr "acos"
    AUe.MUSinh  _      -> mathHErr "sinh"
    AUe.MUCosh  _      -> mathHErr "cosh"
    AUe.MUAsinh _      -> mathHErr "asinh"
    AUe.MUAcosh _      -> mathHErr "acosh"
    AUe.MUAtan  _      -> mathHErr "atan"
    AUe.MUAtanh _      -> mathHErr "atanh"
  where lkErr k = "trExpr: failed to lookup untyped expr " ++ show k
        lk k = fromMaybe (error $ lkErr k) $ lookup k ues
        aLangErr s = error $ "trExpr: Atom language feature " ++ s ++ " is not supported"
        mathHErr s = error $ "trExpr: math.h function " ++ s ++ " is not supported"
        ops = map (SEVar . lk) $ AUe.ueUpstream h umap
        a  = head ops
        b  = ops !! 1
        c  = ops !! 2


-- Name Generation Utilities ---------------------------------------------------

-- | name --> @name_state_type@
mkStateTypeName :: Name -> Name
mkStateTypeName = (`scoreNames` "state_type")

-- | name --> @name_initial_state@
mkInitStateName :: Name -> Name
mkInitStateName = (`scoreNames` "initial_state")

-- | name --> @name_transition@
mkMasterTransName :: Name -> Name
mkMasterTransName = (`scoreNames` "transition")

-- | name --> (@name!var@, @name!ready@)
mkChanStateNames :: Name -> (Name, Name)
mkChanStateNames name = (chanVar, chanReady)
  where chanVar   = name `bangNames` "var"
        chanReady = name `bangNames` "ready"

-- | i name --> @name_transition_i@
mkTransitionName :: Int -> Name -> Name
mkTransitionName i name = name `scoreNames` "transition" `scoreNames`
                          nameFromS (show i)

-- | i cname aname --> @aname_transition_fault_value_cname_i@
mkFaultChanValueName :: Int -> Name -> Name
mkFaultChanValueName i cnm =
  cnm `bangNames` "fault_value" `bangNames` nameFromS (show i)

-- | i name --> @name_transition_fault_node_i@
mkFaultNodeName :: Int -> Name -> Name
mkFaultNodeName i nm =
  nm `bangNames` "faulty_node" `bangNames` nameFromS (show i)

-- | Translate a shared expression reference (an Int) to a variable, e.g.
-- @temp!0@.
trExprRef :: Int -> SallyVar
trExprRef i = varFromName $ nameFromT "temp" `bangNames` nameFromS (show i)

-- | name --> name_transition_system
mkTSystemName :: Name -> Name
mkTSystemName = (`scoreNames` "transition_system")
