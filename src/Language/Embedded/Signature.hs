{-# LANGUAGE GADTs #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Language.Embedded.Signature where

import Data.Proxy

import Language.C.Monad
import Language.Embedded.Expression

import Language.C.Quote.C
import Language.C.Syntax (Id(..),Exp(..),Type)


-- * Language

-- | Signature annotations
data Ann exp a where
  Empty  :: Ann exp a
  Native :: (VarPred exp a) => exp len -> Ann exp [a]
  Named  :: String -> Ann exp a

-- | Signatures
data Signature exp a where
  Ret    :: (VarPred exp a) => String -> exp a -> Signature exp a
  Ptr    :: (VarPred exp a) => String -> exp a -> Signature exp a
  Lam    :: (VarPred exp a) => Ann exp a -> (exp a -> Signature exp b)
         -> Signature exp (a -> b)


-- * Combinators

lam :: (VarPred exp a)
    => (exp a -> Signature exp b) -> Signature exp (a -> b)
lam f = Lam Empty $ \x -> f x

name :: (VarPred exp a)
     => String -> (exp a -> Signature exp b) -> Signature exp (a -> b)
name s f = Lam (Named s) $ \x -> f x

ret,ptr :: (VarPred exp a)
        => String -> exp a -> Signature exp a
ret = Ret
ptr = Ptr

arg :: (VarPred exp a)
    => Ann exp a -> (exp a -> exp b) -> (exp b -> Signature exp c) -> Signature exp (a -> c)
arg s g f = Lam s $ \x -> f (g x)



-- * Compilation

-- | Compile a function @Signature@ to C code
translateFunction :: forall m exp a. (MonadC m, CompExp exp)
                  => Signature exp a -> m ()
translateFunction sig = go sig (return ())
  where
    go :: forall d. Signature exp d -> m () -> m ()
    go (Ret n a) prelude = do
      t <- compType a
      inFunctionTy t n $ do
        prelude
        e <- compExp a
        addStm [cstm| return $e; |]
    go (Ptr n a) prelude = do
      t <- compType a
      inFunction n $ do
        prelude
        e <- compExp a
        addParam [cparam| $ty:t *out |]
        addStm [cstm| *out = $e; |]
    go fun@(Lam Empty f) prelude = do
      t <- compTypePP (Proxy :: Proxy exp) (argProxy fun)
      v <- fmap varExp freshId
      Var n _ <- compExp v
      go (f v) $ prelude >> addParam [cparam| $ty:t $id:n |]
    go fun@(Lam n@(Native l) f) prelude = do
      t <- compTypePP (Proxy :: Proxy exp) (elemProxy n fun)
      i <- freshId
      let w = varExp i
      Var (Id m _) _ <- compExp w
      let n = m ++ "_buf"
      withAlias i ('&':m) $ go (f w) $ do
        prelude
        len <- compExp l
        addLocal [cdecl| struct array $id:m = { .buffer = $id:n
                                              , .length=$len
                                              , .elemSize=sizeof($ty:t)
                                              , .bytes=sizeof($ty:t)*$len
                                              }; |]
        addParam [cparam| $ty:t * $id:n |]
    go fun@(Lam (Named s) f) prelude = do
      t <- compTypePP (Proxy :: Proxy exp) (argProxy fun)
      i <- freshId
      withAlias i s $ go (f $ varExp i) $ prelude >> addParam [cparam| $ty:t $id:s |]

    argProxy :: Signature exp (b -> c) -> Proxy b
    argProxy _ = Proxy

    elemProxy :: Ann exp [b] -> Signature exp ([b] -> c) -> Proxy b
    elemProxy _ _ = Proxy

