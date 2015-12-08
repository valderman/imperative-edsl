{-# LANGUAGE CPP #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Typed deep embedding of simple C expressions
--
-- This is a subset of C expression that don't require any control structures
-- and can be compiled to a single-line C expression (plus possibly include
-- statements).

module Language.Embedded.CExp where



import Data.Int
import Data.Maybe
import Data.Word
#if __GLASGOW_HASKELL__ < 710
import Data.Monoid
#endif
import Data.Typeable

#if MIN_VERSION_syntactic(3,0,0)
import Language.Syntactic
import Language.Syntactic.Functional (Denotation)
import Language.Syntactic.TH
#elif MIN_VERSION_syntactic(2,0,0)
import Data.Syntactic
import Data.Syntactic.Functional (Denotation)
#else
import Language.Syntactic
#endif

import Language.C.Quote.C
import Language.C.Syntax (Type, UnOp (..), BinOp (..), Exp (UnOp, BinOp))

import Language.C.Monad
import Language.Embedded.Expression



--------------------------------------------------------------------------------
-- * Types
--------------------------------------------------------------------------------

-- | Types supported by C
class (Show a, Eq a, Typeable a) => CType a
  where
    cType :: MonadC m => proxy a -> m Type

instance CType Bool   where cType _ = addSystemInclude "stdbool.h" >> return [cty| typename bool     |]
instance CType Int8   where cType _ = addSystemInclude "stdint.h"  >> return [cty| typename int8_t   |]
instance CType Int16  where cType _ = addSystemInclude "stdint.h"  >> return [cty| typename int16_t  |]
instance CType Int32  where cType _ = addSystemInclude "stdint.h"  >> return [cty| typename int32_t  |]
instance CType Int64  where cType _ = addSystemInclude "stdint.h"  >> return [cty| typename int64_t  |]
instance CType Word8  where cType _ = addSystemInclude "stdint.h"  >> return [cty| typename word8_t  |]
instance CType Word16 where cType _ = addSystemInclude "stdint.h"  >> return [cty| typename word16_t |]
instance CType Word32 where cType _ = addSystemInclude "stdint.h"  >> return [cty| typename word32_t |]
instance CType Word64 where cType _ = addSystemInclude "stdint.h"  >> return [cty| typename word64_t |]

instance CType Float  where cType _ = return [cty| float |]
instance CType Double where cType _ = return [cty| double |]



--------------------------------------------------------------------------------
-- * Expressions
--------------------------------------------------------------------------------

-- | Syntactic symbols for C
data Sym sig
  where
    -- Function or literal
#if MIN_VERSION_syntactic(2,0,0)
    Fun  :: Signature sig => String -> Denotation sig -> Sym sig
#else
    Fun  :: String -> Denotation sig -> Sym sig
#endif
    -- Unary operator
    UOp  :: UnOp -> (a -> b) -> Sym (a :-> Full b)
    -- Binary operator
    Op   :: BinOp -> (a -> b -> c) -> Sym (a :-> b :-> Full c)
    -- Type casting (ignored when generating code)
    Cast :: (a -> b) -> Sym (a :-> Full b)
    -- Variable (only for compilation)
    Var  :: String -> Sym (Full a)

data T sig
  where
    T :: CType (DenResult sig) => { unT :: Sym sig } -> T sig

-- | C expression
newtype CExp a = CExp {unCExp :: ASTF T a}

instance Syntactic (CExp a)
  where
    type Domain (CExp a)   = T
    type Internal (CExp a) = a
    desugar = unCExp
    sugar   = CExp

type instance VarPred CExp = CType

evalSym :: Sym sig -> Denotation sig
evalSym (Fun _ a) = a
evalSym (UOp _ f) = f
evalSym (Op  _ f) = f
evalSym (Cast f)  = f
evalSym (Var v)   = error $ "evalCExp: cannot evaluate variable " ++ v

-- | Evaluate an expression
evalCExp :: CExp a -> a
evalCExp (CExp e) = go e
  where
    go :: AST T sig -> Denotation sig
    go (Sym (T s)) = evalSym s
    go (f :$ a)    = go f $ go a

instance EvalExp CExp
  where
    litExp a = CExp $ Sym $ T $ Fun (show a) a
    evalExp  = evalCExp

-- | Compile an expression
compCExp :: forall m a . MonadC m => CExp a -> m Exp
compCExp = simpleMatch (go . unT) . unCExp
  where
    compCExp' :: ASTF T b -> m Exp
    compCExp' = compCExp . CExp

    go :: Sym sig -> Args (AST T) sig -> m Exp
    go (Var v) Nil = return [cexp| $id:v |]
    go (Fun lit _) Nil = case lit of
      "True"  -> addSystemInclude "stdbool.h" >> return [cexp| true |]
      "False" -> addSystemInclude "stdbool.h" >> return [cexp| false |]
      l       -> return [cexp| $id:l |]
    go (Fun fun _) args = do
      as <- sequence $ listArgs compCExp' args
      return [cexp| $id:fun($args:as) |]
    go (UOp op _) (a :* Nil) = do
      a' <- compCExp' a
      return $ UnOp op a' mempty
    go (Op op _) (a :* b :* Nil) = do
      a' <- compCExp' a
      b' <- compCExp' b
      return $ BinOp op a' b' mempty
    go (Cast f) (a :* Nil) = do
      a' <- compCExp' a
      return [cexp| $a' |]

instance CompExp CExp
  where
    varExp = CExp . Sym . T . Var . showVar
      where showVar v = 'v' : show v
    compExp  = compCExp
    compType = cType

-- | One-level constant folding: if all immediate sub-expressions are literals,
-- the expression is reduced to a single literal
constFold :: CExp a -> CExp a
constFold = CExp . match go . unCExp
  where
    go :: T sig -> Args (AST T) sig -> AST T (Full (DenResult sig))
    go (T s) as = res
      where
        e   = appArgs (Sym $ T s) as
        res = if and $ listArgs (isJust . viewLit . CExp) as
                then unCExp $ value $ evalCExp $ CExp e
                else e
  -- Deeper constant folding would require a way to witness `Show` for arbitrary
  -- sub-expressions. This is certainly doable, but seems to complicate things
  -- for not much gain (currently).

-- | Get the value of a literal expression
viewLit :: CExp a -> Maybe a
viewLit (CExp (Sym (T (Fun _ a)))) = Just a
viewLit _ = Nothing



--------------------------------------------------------------------------------
-- * User interface
--------------------------------------------------------------------------------

-- | Construct a literal expression
value :: CType a => a -> CExp a
value a = CExp $ Sym $ T $ Fun (show a) a

true, false :: CExp Bool
true  = value True
false = value False

instance (Num a, CType a) => Num (CExp a)
  where
    fromInteger = value . fromInteger

    a + b
      | Just 0 <- viewLit a = b
      | Just 0 <- viewLit b = a
      | otherwise           = constFold $ sugarSym (T $ Op Add (+)) a b

    a - b
      | Just 0 <- viewLit a = negate b
      | Just 0 <- viewLit b = a
      | otherwise           = constFold $ sugarSym (T $ Op Sub (-)) a b

    a * b
      | Just 0 <- viewLit a = value 0
      | Just 0 <- viewLit b = value 0
      | Just 1 <- viewLit a = b
      | Just 1 <- viewLit b = a
      | otherwise           = constFold $ sugarSym (T $ Op Mul (*)) a b

    negate a = constFold $ sugarSym (T $ UOp Negate negate) a

    abs    = error "abs not implemented for CExp"
    signum = error "signum not implemented for CExp"

instance (Fractional a, CType a) => Fractional (CExp a)
  where
    fromRational = value . fromRational
    a / b = constFold $ sugarSym (T $ Op Div (/)) a b

    recip = error "recip not implemented for CExp"

castAST :: forall a b . Typeable b => ASTF T a -> Maybe (ASTF T b)
castAST a = simpleMatch go a
  where
    go :: (DenResult sig ~ a) => T sig -> Args (AST T) sig -> Maybe (ASTF T b)
    go (T _) _ = gcast a

-- | Boolean negation
not_ :: CExp Bool -> CExp Bool
not_ (CExp (nt :$ a))
    | Just (T (UOp Lnot _)) <- prj nt
    , Just a' <- castAST a = CExp a'
not_ a = constFold $ sugarSym (T $ UOp Lnot not) a

-- | Equality
(<==>) :: Eq a => CExp a -> CExp a -> CExp Bool
a <==> b = constFold $ sugarSym (T $ Op Eq (==)) a b

-- | Integral type casting
i2n :: (Integral a, Num b, CType b) => CExp a -> CExp b
i2n a = constFold $ sugarSym (T $ Cast (fromInteger . toInteger)) a



--------------------------------------------------------------------------------
-- * Syntactic instances
--------------------------------------------------------------------------------

#if MIN_VERSION_syntactic(3,1,0)
deriveSymbol ''Sym
#elif MIN_VERSION_syntactic(2,0,0)
instance Symbol Sym
  where
    symSig (Fun _ _) = signature
    symSig (UOp _ _) = signature
    symSig (Op _ _)  = signature
    symSig (Cast _)  = signature
    symSig (Var _)   = signature
#endif

#if MIN_VERSION_syntactic(2,0,0)
instance Render Sym
  where
    renderSym (Fun name _) = name
    renderSym (UOp op _)   = show op
    renderSym (Op op _)    = show op
    renderSym (Cast _)     = "cast"
    renderSym (Var v)      = v
    renderArgs = renderArgsSmart

instance Equality Sym
  where
    equal = equalDefault
    hash  = hashDefault

instance StringTree Sym

instance Symbol T where symSig (T s) = symSig s

instance Render T
  where
    renderSym (T s)     = renderSym s
    renderArgs as (T s) = renderArgs as s

instance Equality T
  where
    equal (T s) (T t) = equal s t
    hash (T s)        = hash s

instance StringTree T
  where
    stringTreeSym as (T s) = stringTreeSym as s
#endif
