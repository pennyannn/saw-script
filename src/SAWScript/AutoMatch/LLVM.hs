{-# LANGUAGE LambdaCase #-}

module SAWScript.AutoMatch.LLVM where

import Control.Monad.State hiding (mapM)

import Text.LLVM hiding (parseDataLayout, Array, Double, Float, FloatType, Void)
import Verifier.LLVM.Codebase hiding ( Global, ppSymbol, ppIdent
                                     , globalSym, globalType )
--import qualified Verifier.LLVM.Codebase as CB
--import Verifier.LLVM.Codebase.LLVMContext
import Verifier.LLVM.Backend.SAW
--import Verifier.LLVM.Codebase.DataLayout
--import Verifier.LLVM.Codebase.AST
--import Verifier.LLVM.Simulator
--import Verifier.LLVM.Simulator.Internals

--import Verifier.SAW.FiniteValue
import Verifier.SAW.SharedTerm
--import Verifier.SAW.SCTypeCheck

--import SAWScript.CongruenceClosure hiding (mapM)
import SAWScript.Builtins
--import SAWScript.LLVMExpr
--import SAWScript.LLVMMethodSpecIR
--import SAWScript.LLVMMethodSpec
--import SAWScript.Options
--import SAWScript.Proof
--import SAWScript.TypedTerm
import SAWScript.Utils
import SAWScript.Value as SV

import Data.Maybe

--import SAWScript.AutoMatch
import SAWScript.AutoMatch.Declaration
import SAWScript.AutoMatch.Util

import SAWScript.AutoMatch

getDeclsLLVM :: SharedContext SAWCtx -> LLVMModule -> {- LLVMSetup () -> -} IO [Decl]
getDeclsLLVM sc (LLVMModule _file mdl) {- _setup -} =

  let dataLayout = parseDataLayout $ modDataLayout mdl
      symbols = map defName (modDefines mdl)
  in do
    (sbe, _mem, _scLLVM) <- createSAWBackend' sawProxy dataLayout sc
    (warnings, cb) <- mkCodebase sbe dataLayout mdl
    forM_ warnings $ putStrLn . ("WARNING: " ++) . show
    return . catMaybes . for symbols $ \symbol ->
      symDefineToDecl =<< lookupDefine symbol cb

   where

      symDefineToDecl symDefine =
         let Symbol name = sdName symDefine
             args = mapM (\(Ident an, at) -> Arg an <$> memTypeToStdType at) $ sdArgs symDefine
             retType = memTypeToStdType =<< sdRetType symDefine
         in Decl name <$> retType <*> args

      memTypeToStdType t = case t of
         IntType 8  -> Just Char
         IntType 16 -> Just Short
         IntType 32 -> Just Int
         IntType 64 -> Just Long
         FloatType  -> Just Float
         DoubleType -> Just Double
         PtrType VoidType ->
            Just $ Pointer Void
         PtrType (MemType memType) ->
            Pointer <$> memTypeToStdType memType
         ArrayType _size memType ->
            Array <$> memTypeToStdType memType
         _ -> Nothing

printMatchesLLVM :: SharedContext SAWCtx -> LLVMModule -> LLVMModule -> {- LLVMSetup () -> -} IO ()
printMatchesLLVM sc leftModule rightModule {- _setup -} = do
   leftDecls  <- getDeclsLLVM sc leftModule
   rightDecls <- getDeclsLLVM sc rightModule
   print =<< interactIO (matchModules leftDecls rightDecls)
