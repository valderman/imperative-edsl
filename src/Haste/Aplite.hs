{-# LANGUAGE ScopedTypeVariables, OverloadedStrings, BangPatterns #-}
module Haste.Aplite
  ( -- * Creating Aplite functions
    Aplite, ApliteExport, ApliteCMD, aplite, compile
    -- * Tuning Aplite code to the browser environment
  , CodeTuning (..), CodeStyle (..), CodeHeader (..), defaultTuning, asmjsTuning
    -- * Aplite language stuff
  , CExp, ArrView
  , Bits (..)
  , true, false, not_, (#&&), (#||), (#==), (#!=), (#<), (#>), (#<=), (#>=)
  , quot_, round_, floor_, ceiling_, i2n, i2b, f2n, (#%), share
-- not supported yet!  , cond, (?), (#!)
  , module Language.Embedded.Imperative
  , module Data.Int
  , module Data.Word
  , module Data.Array.IO
  ) where
import Control.Monad.Operational.Higher
import Language.JS.Print
import Language.JS.Export
import Language.Embedded.Backend.JS
import Haste.Foreign
import Haste.Prim (veryUnsafePerformIO)
import Haste (JSString)

import Language.JS.Expression
import Language.Embedded.Imperative
import Data.Bits
import Data.Int
import Data.Word
import Data.Array.IO

type Aplite a = Program ApliteCMD (CExp a)

type ApliteExport a =
  ( FFI (HaskellSig a)
  , Export (ApliteSig a)
  , UnIO (HaskellSig a)
  , a ~ NoIO (HaskellSig a)
  )

share :: JSType a => CExp a -> Aplite a
share x = initRef x >>= unsafeFreezeRef

aplite :: forall a. ApliteExport a => CodeTuning -> ApliteSig a -> a
aplite t !prog = unIO $! prog'
  where
    prog' :: HaskellSig a
    prog' = ffi $! compile t prog

type family HaskellSig a where
  HaskellSig (a -> b) = (a -> HaskellSig b)
  HaskellSig a        = IO a

type family ApliteSig a where
  ApliteSig (a -> b)       = (ApliteArg a -> ApliteSig b)
  ApliteSig (IOUArray i e) = Program ApliteCMD (Arr i e)
  ApliteSig a              = Aplite a

type family ApliteArg a where
  ApliteArg Double         = CExp Double
  ApliteArg Int            = CExp Int32 -- NB: only valid for 32 bit arch!
  ApliteArg Int32          = CExp Int32
  ApliteArg Word           = CExp Word32 -- NB: only valid for 32 bit arch!
  ApliteArg Word32         = CExp Word32
  ApliteArg Bool           = CExp Bool
  ApliteArg (IOUArray i e) = Arr i e

type family InterpCMD f where
  InterpCMD (a -> b) = InterpCMD b
  InterpCMD a        = a

class UnIO a where
  type NoIO a
  unIO :: a -> NoIO a

instance UnIO (IO a) where
  type NoIO (IO a) = a
  unIO = veryUnsafePerformIO

instance UnIO b => UnIO (a -> b) where
  type NoIO (a -> b) = a -> NoIO b
  unIO f = \x -> unIO (f x)

class ArrView a where
  arrView :: a -> JSString

instance ArrView Double where arrView _ = "f64"
instance ArrView Int    where arrView _ = "i32"
instance ArrView Int32  where arrView _ = "i32"
instance ArrView Word   where arrView _ = "w32"
instance ArrView Word32 where arrView _ = "w32"

instance forall i e. ArrView e => ToAny (IOUArray i e) where
  toAny x =
    veryUnsafePerformIO $ uarrToAny (arrView (undefined :: e)) (toOpaque x)

uarrToAny :: JSString -> Opaque (IOUArray i e) -> IO JSAny
uarrToAny = ffi "(function(v,a){return a.d['v'][v];})"

anyToUArr :: JSAny -> IO (Opaque (IOUArray i e))
anyToUArr =
  ffi "(function(a){return new T4(0,0,a['length']-1,0,wrapByteArr(a['buffer']));})"

instance forall i e. ArrView e => FromAny (IOUArray i e) where
  fromAny x = fromOpaque <$> anyToUArr x