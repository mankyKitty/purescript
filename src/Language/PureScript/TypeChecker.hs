-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.TypeChecker
-- Copyright   :  (c) Phil Freeman 2013
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

{-# LANGUAGE FlexibleInstances #-}

module Language.PureScript.TypeChecker (
    module T,
    typeCheckAll
) where

import Language.PureScript.TypeChecker.Monad as T
import Language.PureScript.TypeChecker.Kinds as T
import Language.PureScript.TypeChecker.Types as T
import Language.PureScript.TypeChecker.Synonyms as T

import Data.Maybe
import qualified Data.Map as M
import Control.Monad.State
import Control.Monad.Error
import Data.Either (rights, lefts)

import Language.PureScript.Types
import Language.PureScript.Names
import Language.PureScript.Kinds
import Language.PureScript.Declarations

typeCheckAll :: ModuleName -> [Declaration] -> Check ()
typeCheckAll _ [] = return ()
typeCheckAll moduleName (DataDeclaration name args dctors : rest) = do
  rethrow (("Error in type constructor " ++ show name ++ ":\n") ++) $ do
    env <- getEnv
    guardWith (show name ++ " is already defined") $ not $ M.member (moduleName, name) (types env)
    ctorKind <- kindsOf moduleName (Just name) args (mapMaybe snd dctors)
    putEnv $ env { types = M.insert (moduleName, name) (ctorKind, Data) (types env) }
    forM_ dctors $ \(dctor, maybeTy) ->
      rethrow (("Error in data constructor " ++ show name ++ ":\n") ++) $ do
        env' <- getEnv
        guardWith (show dctor ++ " is already defined") $ not $ M.member (moduleName, dctor) (dataConstructors env')
        let retTy = foldl TypeApp (TypeConstructor (Qualified (Just moduleName) name)) (map TypeVar args)
        let dctorTy = maybe retTy (\ty -> Function [ty] retTy) maybeTy
        let polyType = mkForAll args dctorTy
        putEnv $ env' { dataConstructors = M.insert (moduleName, dctor) polyType (dataConstructors env') }
  typeCheckAll moduleName rest
typeCheckAll moduleName (DataBindingGroupDeclaration tys : rest) = error (show tys)
typeCheckAll moduleName (TypeSynonymDeclaration name args ty : rest) = do
  rethrow (("Error in type synonym " ++ show name ++ ":\n") ++) $ do
    env <- getEnv
    guardWith (show name ++ " is already defined") $ not $ M.member (moduleName, name) (types env)
    kind <- kindsOf moduleName (Just name) args [ty]
    putEnv $ env { types = M.insert (moduleName, name) (kind, TypeSynonym) (types env)
                 , typeSynonyms = M.insert (moduleName, name) (args, ty) (typeSynonyms env) }
  typeCheckAll moduleName rest
typeCheckAll _ (TypeDeclaration _ _ : _) = error "Type declarations should have been removed"
typeCheckAll moduleName (ValueDeclaration name [] Nothing val : rest) = do
  rethrow (("Error in declaration " ++ show name ++ ":\n") ++) $ do
    env <- getEnv
    case M.lookup (moduleName, name) (names env) of
      Just _ -> throwError $ show name ++ " is already defined"
      Nothing -> do
        [ty] <- typesOf moduleName [(name, val)]
        putEnv (env { names = M.insert (moduleName, name) (ty, Value) (names env) })
  typeCheckAll moduleName rest
typeCheckAll _ (ValueDeclaration _ _ _ _ : _) = error "Binders were not desugared"
typeCheckAll moduleName (BindingGroupDeclaration vals : rest) = do
  rethrow (("Error in binding group " ++ show (map fst vals) ++ ":\n") ++) $ do
    forM_ (map fst vals) $ \name -> do
      env <- getEnv
      case M.lookup (moduleName, name) (names env) of
        Just _ -> throwError $ show name ++ " is already defined"
        Nothing -> return ()
    tys <- typesOf moduleName vals
    forM (zip (map fst vals) tys) $ \(name, ty) ->
      modifyEnv $ \env -> env { names = M.insert (moduleName, name) (ty, Value) (names env) }
  typeCheckAll moduleName rest
typeCheckAll moduleName (ExternDataDeclaration name kind : rest) = do
  env <- getEnv
  guardWith (show name ++ " is already defined") $ not $ M.member (moduleName, name) (types env)
  putEnv $ env { types = M.insert (moduleName, name) (kind, TypeSynonym) (types env) }
  typeCheckAll moduleName rest
typeCheckAll moduleName (ExternMemberDeclaration member name ty : rest) = do
  rethrow (("Error in foreign import member declaration " ++ show name ++ ":\n") ++) $ do
    env <- getEnv
    kind <- kindOf moduleName ty
    guardWith "Expected kind *" $ kind == Star
    case M.lookup (moduleName, name) (names env) of
      Just _ -> throwError $ show name ++ " is already defined"
      Nothing -> case ty of
        _ | isSingleArgumentFunction ty -> do
          putEnv (env { names = M.insert (moduleName, name) (ty, Extern) (names env)
                      , members = M.insert (moduleName, name) member (members env) })
          | otherwise -> throwError "Foreign member declarations must have function types, with an single argument."
  typeCheckAll moduleName rest
  where
    isSingleArgumentFunction (Function [_] _) = True
    isSingleArgumentFunction (ForAll _ t) = isSingleArgumentFunction t
    isSingleArgumentFunction _ = False
typeCheckAll moduleName (ExternDeclaration name ty : rest) = do
  rethrow (("Error in foreign import declaration " ++ show name ++ ":\n") ++) $ do
    env <- getEnv
    kind <- kindOf moduleName ty
    guardWith "Expected kind *" $ kind == Star
    case M.lookup (moduleName, name) (names env) of
      Just _ -> throwError $ show name ++ " is already defined"
      Nothing -> putEnv (env { names = M.insert (moduleName, name) (ty, Extern) (names env) })
  typeCheckAll moduleName rest
typeCheckAll moduleName (FixityDeclaration _ name : rest) = do
  typeCheckAll moduleName rest
  env <- getEnv
  guardWith ("Fixity declaration with no binding: " ++ name) $ M.member (moduleName, Op name) $ names env
typeCheckAll currentModule (ImportDeclaration moduleName idents : rest) = do
  env <- getEnv
  rethrow errorMessage $ do
    guardWith ("Module " ++ show moduleName ++ " does not exist") $ moduleExists env
    case idents of
      Nothing -> do
        bindIdents (map snd $ filterModule (names env)) env
        bindTypes (map snd $ filterModule (types env)) env
      Just idents' -> do
        bindIdents (lefts idents') env
        bindTypes (rights idents') env
  typeCheckAll currentModule rest
 where errorMessage = (("Error in import declaration " ++ show moduleName ++ ":\n") ++)
       filterModule = filter ((== moduleName) . fst) . M.keys
       moduleExists env = not (null (filterModule (names env))) || not (null (filterModule (types env)))
       bindIdents idents' env =
         forM_ idents' $ \ident -> do
           guardWith (show currentModule ++ "." ++ show ident ++ " is already defined") $ (currentModule, ident) `M.notMember` names env
           case (moduleName, ident) `M.lookup` names env of
             Just (pt, _) -> modifyEnv (\e -> e { names = M.insert (currentModule, ident) (pt, Alias moduleName ident) (names e) })
             Nothing -> throwError (show moduleName ++ "." ++ show ident ++ " is undefined")
       bindTypes pns env =
         forM_ pns $ \pn -> do
           guardWith (show currentModule ++ "." ++ show pn ++ " is already defined") $ (currentModule, pn) `M.notMember` types env
           case (moduleName, pn) `M.lookup` types env of
             Nothing -> throwError (show moduleName ++ "." ++ show pn ++ " is undefined")
             Just (k, _) -> do
               modifyEnv (\e -> e { types = M.insert (currentModule, pn) (k, DataAlias moduleName pn) (types e) })
               let keys = map (snd . fst) . filter (\(_, fn) -> fn `constructs` pn) . M.toList . dataConstructors $ env
               forM_ keys $ \dctor -> do
                 guardWith (show currentModule ++ "." ++ show dctor ++ " is already defined") $ (currentModule, dctor) `M.notMember` dataConstructors env
                 case (moduleName, dctor) `M.lookup` dataConstructors env of
                   Just ctorTy -> modifyEnv (\e -> e { dataConstructors = M.insert (currentModule, dctor) ctorTy (dataConstructors e) })
                   Nothing -> throwError (show moduleName ++ "." ++ show dctor ++ " is undefined")
       constructs (TypeConstructor (Qualified (Just mn) pn')) pn
         = mn == moduleName && pn' == pn
       constructs (ForAll _ ty) pn = ty `constructs` pn
       constructs (Function _ ty) pn = ty `constructs` pn
       constructs (TypeApp ty _) pn = ty `constructs` pn
       constructs fn _ = error $ "Invalid arguments to construct" ++ show fn

