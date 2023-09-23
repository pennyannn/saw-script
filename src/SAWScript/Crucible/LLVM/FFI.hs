{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE ViewPatterns      #-}

module SAWScript.Crucible.LLVM.FFI
  ( llvm_ffi_setup
  ) where

import           Control.Monad
import           Control.Monad.Trans
import           Data.Bits                            (finiteBitSize)
import           Data.List
import qualified Data.Map                             as Map
import           Data.Maybe
import           Data.Text                            (Text)
import qualified Data.Text                            as Text
import           Foreign.C.Types                      (CSize)

import qualified Text.LLVM.AST                        as LLVM

import           Cryptol.Eval.Type
import           Cryptol.TypeCheck.FFI.FFIType
import           Cryptol.TypeCheck.Solver.InfNat
import           Cryptol.TypeCheck.Type
import           Cryptol.Utils.Ident
import           Cryptol.Utils.PP                     (pretty)
import           Cryptol.Utils.RecordMap

import           SAWScript.Builtins
import           SAWScript.Crucible.Common.MethodSpec
import           SAWScript.Crucible.LLVM.Builtins
import           SAWScript.Crucible.LLVM.MethodSpecIR
import           SAWScript.LLVMBuiltins
import           SAWScript.Panic
import           SAWScript.Value
import           Verifier.SAW.CryptolEnv
import           Verifier.SAW.OpenTerm
import           Verifier.SAW.Recognizer
import           Verifier.SAW.SharedTerm
import           Verifier.SAW.TypedTerm

-- | Generate a @LLVMSetup@ spec that can be used to verify the given term
-- containing a Cryptol foreign function fully applied to any type arguments.
llvm_ffi_setup :: TypedTerm -> LLVMCrucibleSetupM ()
llvm_ffi_setup TypedTerm { ttTerm = appTerm } = do
  cryEnv <- lll $ rwCryptol <$> getMergedEnv
  sc <- lll getSharedContext
  case asConstant funTerm of
    Just (ec, funDef)
      | Just FFIFunType {..} <- Map.lookup (ecName ec) (eFFITypes cryEnv) -> do
        when (isNothing funDef) do
          throw "Cannot verify foreign function with no Cryptol implementation"
        tenv <- buildTypeEnv ffiTParams tyArgTerms
        sizeArgs <- lio $ traverse (mkSizeArg sc) tyArgTerms
        (argTerms, inArgss) <- unzip <$> zipWithM
          (\i -> setupInArg tenv ("in" <> Text.pack (show i)))
          [0 :: Integer ..]
          ffiArgTypes
        let inArgs = concat inArgss
        (outArgs, post) <- setupRet sc tenv ffiRetType
        llvm_execute_func (sizeArgs ++ inArgs ++ outArgs)
        post $ applyOpenTermMulti (closedOpenTerm appTerm) argTerms
    _ ->
      throw "Not a (monomorphic instantiation of a) Cryptol foreign function"

  where

  (funTerm, tyArgTerms) = asApplyAll appTerm

  throw :: String -> LLVMCrucibleSetupM a
  throw msg = do
    funTermStr <- lll $ show_term funTerm
    throwLLVM' "llvm_ffi_setup" $
      "Cannot generate FFI setup for " ++ funTermStr ++ ":\n" ++ msg

  buildTypeEnv :: [TParam] -> [Term] -> LLVMCrucibleSetupM TypeEnv
  buildTypeEnv [] [] = pure mempty
  buildTypeEnv (param:params) (argTerm:argTerms) =
    case asCtorParams argTerm of
      Just (primName -> "Cryptol.TCNum", [], [asNat -> Just n]) ->
        bindTypeVar (TVBound param) (Left (Nat (toInteger n))) <$>
          buildTypeEnv params argTerms
      _ -> do
        argTermStr <- lll $ show_term argTerm
        throw $ "Not a numeric literal type argument: " ++ argTermStr
  buildTypeEnv params [] = throw $
    "Foreign function not fully instantiated;\n"
    ++ "Missing type arguments for: " ++ intercalate ", " (map pretty params)
  buildTypeEnv [] _ = throw "Too many type arguments"

  mkSizeArg :: SharedContext -> Term -> IO (AllLLVM SetupValue)
  mkSizeArg sc tyArgTerm = do
    anySetupOpenTerm sc $
      applyGlobalOpenTerm "Cryptol.ecNumber"
        [ closedOpenTerm tyArgTerm
        , vectorTypeOpenTerm sizeBitSize boolTypeOpenTerm
        , applyGlobalOpenTerm "Cryptol.PLiteralSeqBool"
            [ctorOpenTerm "Cryptol.TCNum" [sizeBitSize]]
        ]
    where
    sizeBitSize = natOpenTerm $
      fromIntegral $ finiteBitSize (undefined :: CSize)

  setupInArg :: TypeEnv -> Text -> FFIType ->
    LLVMCrucibleSetupM (OpenTerm, [AllLLVM SetupValue])
  setupInArg tenv = go
    where
    go name ffiType =
      case ffiType of
        FFIBool -> throw "Bit not supported"
        FFIBasic ffiBasicType -> do
          llvmType <- convertBasicType ffiBasicType
          x <- llvm_fresh_var name llvmType
          pure (closedOpenTerm (ttTerm x), [anySetupTerm x])
        FFIArray lengths ffiBasicType -> do
          len <- getArrayLen tenv lengths
          llvmType <- convertBasicType ffiBasicType
          let arrType = llvm_array len llvmType
          arr <- llvm_fresh_var name arrType
          ptr <- llvm_alloc_readonly arrType
          llvm_points_to True ptr (anySetupTerm arr)
          pure (closedOpenTerm (ttTerm arr), [ptr])
        FFITuple ffiTypes ->
          tupleInArgs <$> zipWithM
            (\i -> go (name <> "." <> Text.pack (show i)))
            [0 :: Integer ..]
            ffiTypes
        FFIRecord ffiTypeMap ->
          tupleInArgs <$> traverse
            (\(field, ty) -> go (name <> "." <> identText field) ty)
            (displayFields ffiTypeMap)
    tupleInArgs (unzip -> (terms, inArgss)) =
      (tupleOpenTerm' terms, concat inArgss)

  setupRet :: SharedContext -> TypeEnv -> FFIType ->
    LLVMCrucibleSetupM ([AllLLVM SetupValue], OpenTerm -> LLVMCrucibleSetupM ())
  setupRet sc tenv ffiType =
    case ffiType of
      FFIBool -> throw "Bit not supported"
      FFIBasic _ -> do
        let post ret = llvm_return =<< lio (anySetupOpenTerm sc ret)
        pure ([], post)
      _ -> setupOutArg sc tenv ffiType

  setupOutArg :: SharedContext -> TypeEnv -> FFIType ->
    LLVMCrucibleSetupM ([AllLLVM SetupValue], OpenTerm -> LLVMCrucibleSetupM ())
  setupOutArg sc tenv = go
    where
    go ffiType =
      case ffiType of
        FFIBool -> throw "Bit not supported"
        FFIBasic ffiBasicType -> do
          llvmType <- convertBasicType ffiBasicType
          simpleOutArg llvmType
        FFIArray lengths ffiBasicType -> do
          len <- getArrayLen tenv lengths
          llvmType <- convertBasicType ffiBasicType
          simpleOutArg (llvm_array len llvmType)
        FFITuple ffiTypes -> do
          (outArgss, posts) <- mapAndUnzipM go ffiTypes
          let len = fromIntegral $ length ffiTypes
              post ret = zipWithM_
                (\i p -> p (projTupleOpenTerm' i len ret))
                [0..]
                posts
          pure (concat outArgss, post)
        FFIRecord ffiTypeMap -> do
          -- The FFI passes record elements by display order, while SAW
          -- represents records by tuples in canonical order
          (outArgss, posts) <- mapAndUnzipM go (displayElements ffiTypeMap)
          let canonFields = map fst $ canonicalFields ffiTypeMap
              len = fromIntegral $ length canonFields
              post ret = zipWithM_
                (\field p -> do
                  let ix = fromIntegral
                        case elemIndex field canonFields of
                          Just i -> i
                          Nothing -> panic "setupOutArg"
                            ["Bad record field access"]
                  p (projTupleOpenTerm' ix len ret))
                (displayOrder ffiTypeMap)
                posts
          pure (concat outArgss, post)
    simpleOutArg llvmType = do
      ptr <- llvm_alloc llvmType
      let post ret = llvm_points_to True ptr =<< lio (anySetupOpenTerm sc ret)
      pure ([ptr], post)

  getArrayLen :: TypeEnv -> [Type] -> LLVMCrucibleSetupM Int
  getArrayLen tenv lengths =
    case lengths of
      [len] -> pure $ fromInteger $ finNat' $ evalNumType tenv len
      _     -> throw "Multidimensional arrays not supported"

  convertBasicType :: FFIBasicType -> LLVMCrucibleSetupM LLVM.Type
  convertBasicType (FFIBasicVal ffiBasicValType) =
    case ffiBasicValType of
      FFIWord n ffiWordSize
        | n == size -> pure $ llvm_int size
        | otherwise -> throw
          "Only exact machine-sized bitvectors (8, 16, 32, 64 bits) supported"
        where
        size :: Integral a => a
        size =
          case ffiWordSize of
            FFIWord8  -> 8
            FFIWord16 -> 16
            FFIWord32 -> 32
            FFIWord64 -> 64
      FFIFloat _ _ ffiFloatSize -> pure
        case ffiFloatSize of
          FFIFloat32 -> llvm_float
          FFIFloat64 -> llvm_double
  convertBasicType (FFIBasicRef _) =
    throw "GMP types (Integer, Z) not supported"

anySetupOpenTerm :: SharedContext -> OpenTerm -> IO (AllLLVM SetupValue)
anySetupOpenTerm sc openTerm =
  anySetupTerm <$> (mkTypedTerm sc =<< completeOpenTerm sc openTerm)

lll :: TopLevel a -> LLVMCrucibleSetupM a
lll x = LLVMCrucibleSetupM $ lift $ lift x

lio :: IO a -> LLVMCrucibleSetupM a
lio x = LLVMCrucibleSetupM $ liftIO x
