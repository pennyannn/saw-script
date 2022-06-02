{- |
Module      : SAWScript.Crucible.LLVM.MethodSpecIR
Description : Provides type-checked representation for Crucible/LLVM function
              specifications and function for creating it from AST
              representation.
Maintainer  : atomb
Stability   : provisional
-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans  #-}

module SAWScript.Crucible.LLVM.MethodSpecIR
  ( LLVM
    -- * LLVMMethodId
  , LLVMMethodId(..)
  , llvmMethodParent
  , llvmMethodName
  , csName
  , csParentName
    -- * LLVMAllocSpec
  , LLVMAllocSpec(..)
  , LLVMAllocSpecInit(..)
  , allocSpecType
  , allocSpecAlign
  , allocSpecMut
  , allocSpecMd
  , allocSpecBytes
  , allocSpecFresh
  , allocSpecInit
  , mutIso
  , isMut
    -- * LLVMModule
  , LLVMModule -- abstract
  , modFilePath
  , modAST
  , modTrans
  , loadLLVMModule
  , showLLVMModule
    -- * CrucibleContext
  , LLVMCrucibleContext(..)
  , ccLLVMSimContext
  , ccLLVMModule
  , ccLLVMGlobals
  , ccBasicSS
  , ccBackend
  , ccLLVMModuleAST
  , ccLLVMModuleTrans
  , ccLLVMContext
  , ccTypeCtx
  , ccWithBackend
  , ccSym
    -- * PointsTo
  , LLVMPointsTo(..)
  , LLVMPointsToValue(..)
  , llvmPointsToProgramLoc
  , ppPointsTo
    -- * AllocGlobal
  , LLVMAllocGlobal(..)
  , ppAllocGlobal
    -- * Intrinsics
  , intrinsics
    -- * Initial CrucibleSetupMethodSpec
  , SetupError(..)
  , ppSetupError
  , resolveArgs
  , resolveRetTy
  , initialDefCrucibleMethodSpecIR
  , initialDeclCrucibleMethodSpecIR
  , initialCrucibleSetupState
  , initialCrucibleSetupStateDecl
    -- * AllLLVM
  , AllLLVM
  , mkAllLLVM
  , getAllLLVM
  , anySetupTerm
  , anySetupArray
  , anySetupCast
  , anySetupStruct
  , anySetupElem
  , anySetupField
  , anySetupUnion
  , anySetupNull
  , anySetupGlobal
  , anySetupGlobalInitializer
    -- * SomeLLVM
  , SomeLLVM
  , pattern SomeLLVM
  , mkSomeLLVM
  , getSomeLLVM
    -- * ResolvedState
  , LLVMResolvedState
  , ResolvedPath
  , ResolvedPathItem(..)
  , emptyResolvedState
  , rsAllocs
  , rsGlobals
  , markResolved
  , testResolved
  ) where

import           Control.Lens
import           Control.Monad (when)
import           Data.Functor.Compose (Compose(..))
import           Data.Map ( Map )
import qualified Data.Map as Map
import qualified Data.Text as Text
import           Data.Type.Equality (TestEquality(..))
import qualified Prettyprinter as PPL
import qualified Text.LLVM.AST as L
import qualified Text.LLVM.PP as L
import qualified Text.PrettyPrint.HughesPJ as PP

import qualified Data.LLVM.BitCode as LLVM

import qualified Cryptol.TypeCheck.AST as Cryptol
import qualified Cryptol.Utils.PP as Cryptol (pp)

import           Data.Parameterized.All (All(All))
import           Data.Parameterized.Some (Some(Some))
import qualified Data.Parameterized.Map as MapF

import           What4.ProgramLoc (ProgramLoc)

import qualified Lang.Crucible.FunctionHandle as Crucible (HandleAllocator)
import qualified Lang.Crucible.Simulator.ExecutionTree as Crucible (SimContext)
import qualified Lang.Crucible.Simulator.GlobalState as Crucible (SymGlobalState)
import qualified Lang.Crucible.Types as Crucible (SymbolRepr, knownSymbol)
import qualified Lang.Crucible.Simulator.Intrinsics as Crucible
  (IntrinsicClass(Intrinsic, muxIntrinsic), IntrinsicMuxFn(IntrinsicMuxFn))

import           SAWScript.Crucible.Common
import qualified SAWScript.Crucible.Common.MethodSpec as MS
import qualified SAWScript.Crucible.Common.Setup.Type as Setup

import qualified SAWScript.Crucible.LLVM.CrucibleLLVM as CL

import           SAWScript.Proof (TheoremNonce)

import           Verifier.SAW.Simulator.What4.ReturnTrip ( toSC, saw_ctx )

import           Verifier.SAW.Rewriter (Simpset)
import           Verifier.SAW.SharedTerm
import           Verifier.SAW.TypedTerm


--------------------------------------------------------------------------------
-- ** Language features

data LLVM (arch :: CL.LLVMArch)

type instance MS.HasSetupNull (LLVM _) = 'True
type instance MS.HasSetupStruct (LLVM _) = 'True
type instance MS.HasSetupArray (LLVM _) = 'True
type instance MS.HasSetupElem (LLVM _) = 'True
type instance MS.HasSetupField (LLVM _) = 'True
type instance MS.HasSetupCast (LLVM _) = 'True
type instance MS.HasSetupUnion (LLVM _) = 'True
type instance MS.HasSetupGlobal (LLVM _) = 'True
type instance MS.HasSetupGlobalInitializer (LLVM _) = 'True

type instance MS.HasGhostState (LLVM _) = 'True

type instance MS.TypeName (LLVM arch) = CL.Ident
type instance MS.ExtType (LLVM arch) = CL.MemType
type instance MS.CastType (LLVM arch) = L.Type

--------------------------------------------------------------------------------
-- *** LLVMMethodId

data LLVMMethodId =
  LLVMMethodId
    { _llvmMethodName   :: String
    , _llvmMethodParent :: Maybe String -- ^ Something to do with breakpoints...
    } deriving (Eq, Ord, Show)

makeLenses ''LLVMMethodId

csName :: Lens' (MS.CrucibleMethodSpecIR (LLVM arch)) String
csName = MS.csMethod . llvmMethodName

csParentName :: Lens' (MS.CrucibleMethodSpecIR (LLVM arch)) (Maybe String)
csParentName = MS.csMethod . llvmMethodParent

instance PPL.Pretty LLVMMethodId where
  pretty = PPL.pretty . view llvmMethodName

type instance MS.MethodId (LLVM _) = LLVMMethodId

--------------------------------------------------------------------------------
-- *** LLVMAllocSpec

-- | Allocation initialization policy
data LLVMAllocSpecInit
  = LLVMAllocSpecSymbolicInitialization
    -- ^ allocation is initialized with a fresh symbolic array of bytes
  | LLVMAllocSpecNoInitialization
    -- ^ allocation not initialized
  deriving (Eq, Ord, Show)

data LLVMAllocSpec =
  LLVMAllocSpec
    { _allocSpecMut   :: CL.Mutability
    , _allocSpecType  :: CL.MemType
    , _allocSpecAlign :: CL.Alignment
    , _allocSpecBytes :: Term
    , _allocSpecMd    :: MS.ConditionMetadata
    , _allocSpecFresh :: Bool -- ^ Whether declared with @crucible_fresh_pointer@
    , _allocSpecInit :: LLVMAllocSpecInit
    }
  deriving (Eq, Show)

makeLenses ''LLVMAllocSpec

type instance MS.AllocSpec (LLVM _) = LLVMAllocSpec

mutIso :: Iso' CL.Mutability Bool
mutIso =
  iso
    (\case
      CL.Mutable -> True
      CL.Immutable -> False)
    (\case
      True -> CL.Mutable
      False -> CL.Immutable)

isMut :: Lens' LLVMAllocSpec Bool
isMut = allocSpecMut . mutIso

--------------------------------------------------------------------------------
-- *** LLVMModule

-- | An 'LLVMModule' contains an LLVM module that has been parsed from
-- a bitcode file and translated to Crucible.
data LLVMModule arch =
  LLVMModule
  { _modFilePath :: FilePath
  , _modAST :: L.Module
  , _modTrans :: CL.ModuleTranslation arch
  }
-- NOTE: Type 'LLVMModule' is exported as an abstract type, and we
-- maintain the invariant that the 'FilePath', 'Module', and
-- 'ModuleTranslation' fields are all consistent with each other;
-- 'loadLLVMModule' is the only function that is allowed to create
-- values of type 'LLVMModule'.

-- | The file path that the LLVM module was loaded from.
modFilePath :: LLVMModule arch -> FilePath
modFilePath = _modFilePath

-- | The parsed AST of the LLVM module.
modAST :: LLVMModule arch -> L.Module
modAST = _modAST

-- | The Crucible translation of an LLVM module.
modTrans :: LLVMModule arch -> CL.ModuleTranslation arch
modTrans = _modTrans

-- | Load an LLVM module from the given bitcode file, then parse and
-- translate to Crucible.
loadLLVMModule ::
  (?transOpts :: CL.TranslationOptions) =>
  FilePath ->
  Crucible.HandleAllocator ->
  IO (Either LLVM.Error (Some LLVMModule))
loadLLVMModule file halloc =
  do parseResult <- LLVM.parseBitCodeFromFile file
     case parseResult of
       Left err -> return (Left err)
       Right llvm_mod ->
         do memVar <- CL.mkMemVar (Text.pack "saw:llvm_memory") halloc
            -- FIXME: do something with the translation warnings
            (Some mtrans, _warnings) <- CL.translateModule halloc memVar llvm_mod
            return (Right (Some (LLVMModule file llvm_mod mtrans)))

instance TestEquality LLVMModule where
  -- As 'LLVMModule' is an abstract type, we know that the values must
  -- have been created by a call to 'loadLLVMModule'. Furthermore each
  -- call to 'translateModule' generates a 'ModuleTranslation' that
  -- contains a fresh nonce; thus comparison of the 'modTrans' fields
  -- is sufficient to guarantee equality of two 'LLVMModule' values.
  testEquality m1 m2 = testEquality (modTrans m1) (modTrans m2)

type instance MS.Codebase (LLVM arch) = LLVMModule arch

showLLVMModule :: LLVMModule arch -> String
showLLVMModule (LLVMModule name m _) =
  unlines [ "Module: " ++ name
          , "Types:"
          , showParts L.ppTypeDecl (L.modTypes m)
          , "Globals:"
          , showParts ppGlobal' (L.modGlobals m)
          , "External references:"
          , showParts L.ppDeclare (L.modDeclares m)
          , "Definitions:"
          , showParts ppDefine' (L.modDefines m)
          ]
  where
    showParts pp xs = unlines $ map (show . PP.nest 2 . pp) xs
    ppGlobal' g =
      L.ppSymbol (L.globalSym g) PP.<+> PP.char '=' PP.<+>
      L.ppGlobalAttrs (L.globalAttrs g) PP.<+>
      L.ppType (L.globalType g)
    ppDefine' d =
      L.ppMaybe L.ppLinkage (L.defLinkage d) PP.<+>
      L.ppType (L.defRetType d) PP.<+>
      L.ppSymbol (L.defName d) PP.<>
      L.ppArgList (L.defVarArgs d) (map (L.ppTyped L.ppIdent) (L.defArgs d)) PP.<+>
      L.ppMaybe (\gc -> PP.text "gc" PP.<+> L.ppGC gc) (L.defGC d)

--------------------------------------------------------------------------------
-- ** Ghost state

instance Crucible.IntrinsicClass Sym MS.GhostValue where
  type Intrinsic Sym MS.GhostValue ctx = (Cryptol.Schema, Term)
  muxIntrinsic sym _ _namerep _ctx prd (thnSch,thn) (elsSch,els) =
    do when (thnSch /= elsSch) $ fail $ unlines $
         [ "Attempted to mux ghost variables of different types:"
         , show (Cryptol.pp thnSch)
         , show (Cryptol.pp elsSch)
         ]
       st <- sawCoreState sym
       let sc  = saw_ctx st
       prd' <- toSC sym st prd
       typ  <- scTypeOf sc thn
       res  <- scIte sc typ prd' thn els
       return (thnSch, res)

--------------------------------------------------------------------------------
-- ** CrucibleContext

type instance MS.CrucibleContext (LLVM arch) = LLVMCrucibleContext arch

data LLVMCrucibleContext arch =
  LLVMCrucibleContext
  { _ccLLVMModule      :: LLVMModule arch
  , _ccBackend         :: SomeOnlineBackend
  , _ccLLVMSimContext  :: Crucible.SimContext (SAWCruciblePersonality Sym) Sym CL.LLVM
  , _ccLLVMGlobals     :: Crucible.SymGlobalState Sym
  , _ccBasicSS         :: Simpset TheoremNonce
  }

makeLenses ''LLVMCrucibleContext

ccLLVMModuleAST :: LLVMCrucibleContext arch -> L.Module
ccLLVMModuleAST = modAST . _ccLLVMModule

ccLLVMModuleTrans :: LLVMCrucibleContext arch -> CL.ModuleTranslation arch
ccLLVMModuleTrans = modTrans . _ccLLVMModule

ccLLVMContext :: LLVMCrucibleContext arch -> CL.LLVMContext arch
ccLLVMContext = view CL.transContext . ccLLVMModuleTrans

ccTypeCtx :: LLVMCrucibleContext arch -> CL.TypeContext
ccTypeCtx = view CL.llvmTypeCtx . ccLLVMContext

ccWithBackend ::
  LLVMCrucibleContext arch ->
  (forall solver. OnlineSolver solver => Backend solver -> a) ->
  a
ccWithBackend cc k =
  case cc^.ccBackend of SomeOnlineBackend bak -> k bak

ccSym :: Getter (LLVMCrucibleContext arch) Sym
ccSym = to (\cc -> ccWithBackend cc backendGetSym)

--------------------------------------------------------------------------------
-- ** PointsTo

type instance MS.PointsTo (LLVM arch) = LLVMPointsTo arch

data LLVMPointsTo arch
  = LLVMPointsTo MS.ConditionMetadata (Maybe TypedTerm) (MS.SetupValue (LLVM arch)) (LLVMPointsToValue arch)
    -- | A variant of 'LLVMPointsTo' tailored to the @llvm_points_to_bitfield@
    -- command, which doesn't quite fit into the 'LLVMPointsToValue' paradigm.
    -- The 'String' represents the name of the field within the bitfield.
  | LLVMPointsToBitfield MS.ConditionMetadata (MS.SetupValue (LLVM arch)) String (MS.SetupValue (LLVM arch))

data LLVMPointsToValue arch
  = ConcreteSizeValue (MS.SetupValue (LLVM arch))
  | SymbolicSizeValue TypedTerm TypedTerm

-- | Return the 'ProgramLoc' corresponding to an 'LLVMPointsTo' statement.
llvmPointsToProgramLoc :: LLVMPointsTo arch -> ProgramLoc
llvmPointsToProgramLoc (LLVMPointsTo md _ _ _) = MS.conditionLoc md
llvmPointsToProgramLoc (LLVMPointsToBitfield md _ _ _) = MS.conditionLoc md

ppPointsTo :: LLVMPointsTo arch -> PPL.Doc ann
ppPointsTo (LLVMPointsTo _md cond ptr val) =
  MS.ppSetupValue ptr
  PPL.<+> PPL.pretty "points to"
  PPL.<+> PPL.pretty val
  PPL.<+> maybe PPL.emptyDoc (\tt -> PPL.pretty "if" PPL.<+> MS.ppTypedTerm tt) cond
ppPointsTo (LLVMPointsToBitfield _md ptr fieldName val) =
  MS.ppSetupValue ptr <> PPL.pretty ("." ++ fieldName)
  PPL.<+> PPL.pretty "points to (bitfield)"
  PPL.<+> MS.ppSetupValue val

instance PPL.Pretty (LLVMPointsTo arch) where
  pretty = ppPointsTo

instance PPL.Pretty (LLVMPointsToValue arch) where
  pretty = \case
    ConcreteSizeValue val -> MS.ppSetupValue val
    SymbolicSizeValue arr sz ->
      MS.ppTypedTerm arr PPL.<+> PPL.pretty "[" PPL.<+> MS.ppTypedTerm sz PPL.<+> PPL.pretty "]"

--------------------------------------------------------------------------------
-- ** AllocGlobal

type instance MS.AllocGlobal (LLVM arch) = LLVMAllocGlobal arch

data LLVMAllocGlobal arch = LLVMAllocGlobal ProgramLoc L.Symbol

ppAllocGlobal :: LLVMAllocGlobal arch -> PPL.Doc ann
ppAllocGlobal (LLVMAllocGlobal _loc (L.Symbol name)) =
  PPL.pretty "allocate global"
  PPL.<+> PPL.pretty name

instance PPL.Pretty (LLVMAllocGlobal arch) where
  pretty = ppAllocGlobal

--------------------------------------------------------------------------------
-- ** ???

intrinsics :: MapF.MapF Crucible.SymbolRepr (Crucible.IntrinsicMuxFn Sym)
intrinsics =
  MapF.insert
    (Crucible.knownSymbol :: Crucible.SymbolRepr MS.GhostValue)
    Crucible.IntrinsicMuxFn
    CL.llvmIntrinsicTypes

-------------------------------------------------------------------------------
-- ** Initial CrucibleSetupMethodSpec

data SetupError
  = InvalidReturnType L.Type
  | InvalidArgTypes [L.Type]

ppSetupError :: SetupError -> PPL.Doc ann
ppSetupError (InvalidReturnType t) =
  PPL.pretty "Can't lift return type" PPL.<+>
  PPL.viaShow (L.ppType t) PPL.<+>
  PPL.pretty "to a Crucible type."
ppSetupError (InvalidArgTypes ts) =
  PPL.pretty "Can't lift argument types " PPL.<+>
  PPL.encloseSep PPL.lparen PPL.rparen PPL.comma (map (PPL.viaShow . L.ppType) ts) PPL.<+>
  PPL.pretty "to Crucible types."

resolveArgs ::
  (?lc :: CL.TypeContext) =>
  [L.Type] ->
  Either SetupError [CL.MemType]
resolveArgs args = do
  -- TODO: make sure we resolve aliases
  let mtys = traverse CL.liftMemType args
  -- TODO: should the error message be propagated?
  either (\_ -> Left (InvalidArgTypes args)) Right mtys

resolveRetTy ::
  (?lc :: CL.TypeContext) =>
  L.Type ->
  Either SetupError (Maybe CL.MemType)
resolveRetTy ty = do
  -- TODO: make sure we resolve aliases
  let ret = CL.liftRetType ty
  -- TODO: should the error message be propagated?
  either (\_ -> Left (InvalidReturnType ty)) Right ret

initialDefCrucibleMethodSpecIR ::
  (?lc :: CL.TypeContext) =>
  LLVMModule arch ->
  L.Define ->
  ProgramLoc ->
  Maybe String ->
  Either SetupError (MS.CrucibleMethodSpecIR (LLVM arch))
initialDefCrucibleMethodSpecIR llvmModule def loc parent = do
  args <- resolveArgs (L.typedType <$> L.defArgs def)
  ret <- resolveRetTy (L.defRetType def)
  let L.Symbol nm = L.defName def
  let methId = LLVMMethodId nm parent
  return $ MS.makeCrucibleMethodSpecIR methId args ret loc llvmModule

initialDeclCrucibleMethodSpecIR ::
  (?lc :: CL.TypeContext) =>
  LLVMModule arch ->
  L.Declare ->
  ProgramLoc ->
  Maybe String ->
  Either SetupError (MS.CrucibleMethodSpecIR (LLVM arch))
initialDeclCrucibleMethodSpecIR llvmModule dec loc parent = do
  args <- resolveArgs (L.decArgs dec)
  ret <- resolveRetTy (L.decRetType dec)
  let L.Symbol nm = L.decName dec
  let methId = LLVMMethodId nm parent
  return $ MS.makeCrucibleMethodSpecIR methId args ret loc llvmModule

initialCrucibleSetupState ::
  (?lc :: CL.TypeContext) =>
  LLVMCrucibleContext arch ->
  L.Define ->
  ProgramLoc ->
  Maybe String ->
  Either SetupError (Setup.CrucibleSetupState (LLVM arch))
initialCrucibleSetupState cc def loc parent = do
  ms <- initialDefCrucibleMethodSpecIR (cc ^. ccLLVMModule) def loc parent
  return $ Setup.makeCrucibleSetupState emptyResolvedState cc ms

initialCrucibleSetupStateDecl ::
  (?lc :: CL.TypeContext) =>
  LLVMCrucibleContext arch ->
  L.Declare ->
  ProgramLoc ->
  Maybe String ->
  Either SetupError (Setup.CrucibleSetupState (LLVM arch))
initialCrucibleSetupStateDecl cc dec loc parent = do
  ms <- initialDeclCrucibleMethodSpecIR (cc ^. ccLLVMModule) dec loc parent
  return $ Setup.makeCrucibleSetupState emptyResolvedState cc ms

--------------------------------------------------------------------------------
-- ** AllLLVM/SomeLLVM

--------------------------------------------------------------------------------
-- *** AllLLVM

-- | Universal/polymorphic quantification over an 'LLVMArch'
--
-- The following type synonym and associated constructor/destructor are
-- equivalent to this definition:
-- @
-- data AllLLVM t =
--   MkAllLLVM { getAllLLVM :: forall arch. t (LLVM arch) }
-- @
-- But they preserve the instances from 'All' and 'Compose'.
type AllLLVM t = All (Compose t LLVM)

-- This doesn't work :(
--
-- pattern AllLLVM :: (forall arch. t (LLVM arch)) -> AllLLVM t
-- pattern AllLLVM x = All (Compose x)

mkAllLLVM :: forall t. (forall arch. t (LLVM arch)) -> AllLLVM t
mkAllLLVM x = All (Compose x)

getAllLLVM :: forall t. AllLLVM t -> (forall arch. t (LLVM arch))
getAllLLVM (All (Compose x)) = x

-- Constructors for 'SetupValue' which are architecture-polymorphic

anySetupTerm :: TypedTerm -> AllLLVM MS.SetupValue
anySetupTerm typedTerm = mkAllLLVM (MS.SetupTerm typedTerm)

anySetupArray :: [AllLLVM MS.SetupValue] -> AllLLVM MS.SetupValue
anySetupArray vals = mkAllLLVM (MS.SetupArray () $ map (\a -> getAllLLVM a) vals)

anySetupStruct :: Bool -> [AllLLVM MS.SetupValue] -> AllLLVM MS.SetupValue
anySetupStruct b vals = mkAllLLVM (MS.SetupStruct () b $ map (\a -> getAllLLVM a) vals)

anySetupElem :: AllLLVM MS.SetupValue -> Int -> AllLLVM MS.SetupValue
anySetupElem val idx = mkAllLLVM (MS.SetupElem () (getAllLLVM val) idx)

anySetupCast :: AllLLVM MS.SetupValue -> L.Type -> AllLLVM MS.SetupValue
anySetupCast val ty = mkAllLLVM (MS.SetupCast () (getAllLLVM val) ty)

anySetupField :: AllLLVM MS.SetupValue -> String -> AllLLVM MS.SetupValue
anySetupField val field = mkAllLLVM (MS.SetupField () (getAllLLVM val) field)

anySetupUnion :: AllLLVM MS.SetupValue -> String -> AllLLVM MS.SetupValue
anySetupUnion val uname = mkAllLLVM (MS.SetupUnion () (getAllLLVM val) uname)

anySetupNull :: AllLLVM MS.SetupValue
anySetupNull = mkAllLLVM (MS.SetupNull ())

anySetupGlobal :: String -> AllLLVM MS.SetupValue
anySetupGlobal globalName = mkAllLLVM (MS.SetupGlobal () globalName)

anySetupGlobalInitializer :: String -> AllLLVM MS.SetupValue
anySetupGlobalInitializer globalName =
  mkAllLLVM (MS.SetupGlobalInitializer () globalName)

--------------------------------------------------------------------------------
-- *** SomeLLVM

-- | Existential quantification over an 'LLVMArch'
--
-- The following type synonym and associated constructor/destructor are
-- equivalent to this definition:
-- @
-- data SomeLLVM t = forall arch. MkSomeLLVM (t (LLVM arch))
-- @
-- But they preserve the instances from 'Some' and 'Compose'.
type SomeLLVM t = Some (Compose t LLVM)

pattern SomeLLVM :: t (LLVM arch) -> SomeLLVM t
pattern SomeLLVM x = Some (Compose x)
{-# COMPLETE SomeLLVM #-}

mkSomeLLVM :: t (LLVM arch) -> SomeLLVM t
mkSomeLLVM x = Some (Compose x)

getSomeLLVM :: forall t. (forall arch. t (LLVM arch)) -> AllLLVM t
getSomeLLVM x = All (Compose x)

--------------------------------------------------------------------------------
-- *** ResolvedState

type instance MS.ResolvedState (LLVM arch) = LLVMResolvedState

data ResolvedPathItem
  = ResolvedField String
  | ResolvedElem Int
  | ResolvedCast L.Type
 deriving (Show, Eq, Ord)

type ResolvedPath = [ResolvedPathItem]

-- | A datatype to keep track of which parts of the simulator state
-- have been initialized already. For each allocation unit or global,
-- we keep a list of element-paths that identify the initialized
-- sub-components.
--
-- Note that the data collected and maintained by this datatype
-- represents a \"best-effort\" check that attempts to prevent
-- the user from stating unsatisfiable method specifications.
--
-- It will not prevent all cases of overlapping points-to
-- specifications, especially in the presence of pointer casts.
-- A typical result of overlapping specifications will be
-- successful (vacuous) verifications of functions resulting in
-- overrides that cannot be used at call sites (as their
-- preconditions are unsatisfiable).
data LLVMResolvedState =
  ResolvedState
    { _rsAllocs :: Map MS.AllocIndex [ResolvedPath]
    , _rsGlobals :: Map String [ResolvedPath]
    }
  deriving (Eq, Ord, Show)

emptyResolvedState :: LLVMResolvedState
emptyResolvedState = ResolvedState Map.empty Map.empty

makeLenses ''LLVMResolvedState

-- | Record the initialization of the pointer represented by the given
-- SetupValue.
markResolved ::
  MS.SetupValue (LLVM arch) ->
  ResolvedPath {-^ path within this object (if any) -} ->
  LLVMResolvedState ->
  LLVMResolvedState
markResolved val0 path0 rs = go path0 val0
  where
    go path val =
      case val of
        MS.SetupVar n         -> rs & rsAllocs %~ Map.alter (ins path) n
        MS.SetupGlobal _ name -> rs & rsGlobals %~ Map.alter (ins path) name
        MS.SetupElem _ v idx  -> go (ResolvedElem idx : path) v
        MS.SetupField _ v fld -> go (ResolvedField fld : path) v
        MS.SetupCast _ v tp   -> go (ResolvedCast tp : path) v
        _                     -> rs

    ins path Nothing = Just [path]
    ins path (Just paths) = Just (path : paths)

-- | Test whether the pointer represented by the given SetupValue has
-- been initialized already.
testResolved ::
  MS.SetupValue (LLVM arch) ->
  ResolvedPath {-^ path within this object (if any) -} ->
  LLVMResolvedState ->
  Bool
testResolved val0 path0 rs = go path0 val0
  where
    go path val =
      case val of
        MS.SetupVar n         -> test path (Map.lookup n (_rsAllocs rs))
        MS.SetupGlobal _ c    -> test path (Map.lookup c (_rsGlobals rs))
        MS.SetupElem _ v idx  -> go (ResolvedElem idx : path) v
        MS.SetupField _ v fld -> go (ResolvedField fld : path) v
        MS.SetupCast _ v tp   -> go (ResolvedCast tp : path) v
        _                     -> False

    test _ Nothing = False
    test path (Just paths) = any (overlap path) paths

    overlap (x : xs) (y : ys) = x == y && overlap xs ys
    overlap [] _ = True
    overlap _ [] = True
