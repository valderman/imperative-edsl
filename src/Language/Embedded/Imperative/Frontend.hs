{-# LANGUAGE CPP #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE UndecidableInstances #-}

-- Front end for imperative instructions
--
-- These instructions are general imperative constructs independent of the back
-- end, except for the stuff under \"External function calls\" which is
-- C-specific.

module Language.Embedded.Imperative.Frontend where



import Prelude hiding (break)

import Data.Array.IO
import Data.IORef
import Data.Typeable
import System.IO.Unsafe

#if __GLASGOW_HASKELL__ < 708
import Data.Proxy
#endif
import Language.C.Quote.C

import Control.Monad.Operational.Higher
import System.IO.Fake
import Language.Embedded.Expression
import Language.Embedded.Imperative.CMD
import Language.Embedded.Imperative.Frontend.General
import Language.Embedded.Imperative.Args



--------------------------------------------------------------------------------
-- * References
--------------------------------------------------------------------------------

-- | Create an uninitialized reference
newRef :: (VarPred (IExp instr) a, RefCMD (IExp instr) :<: instr) => ProgramT instr m (Ref a)
newRef = singleE NewRef

-- | Create an initialized reference
initRef :: (VarPred (IExp instr) a, RefCMD (IExp instr) :<: instr) =>
    IExp instr a -> ProgramT instr m (Ref a)
initRef = singleE . InitRef

-- | Get the contents of a reference
getRef :: (VarPred (IExp instr) a, RefCMD (IExp instr) :<: instr) =>
    Ref a -> ProgramT instr m (IExp instr a)
getRef = singleE . GetRef

-- | Set the contents of a reference
setRef :: (VarPred (IExp instr) a, RefCMD (IExp instr) :<: instr) =>
    Ref a -> IExp instr a -> ProgramT instr m ()
setRef r = singleE . SetRef r

-- | Modify the contents of reference
modifyRef
    :: ( VarPred (IExp instr) a
       , EvalExp (IExp instr)
       , CompExp (IExp instr)
       , RefCMD (IExp instr) :<: instr
       , Monad m
       )
    => Ref a -> (IExp instr a -> IExp instr a) -> ProgramT instr m ()
modifyRef r f = setRef r . f =<< unsafeFreezeRef r

-- | Freeze the contents of reference (only safe if the reference is never
-- written to after the freezing)
unsafeFreezeRef :: (VarPred (IExp instr) a, RefCMD (IExp instr) :<: instr) =>
    Ref a -> ProgramT instr m (IExp instr a)
unsafeFreezeRef = singleE . UnsafeFreezeRef

-- | Read the value of a reference without returning in the monad
--
-- WARNING: Don't use this function unless you really know what you are doing.
-- It is almost always better to use 'unsafeFreezeRef' instead.
--
-- 'veryUnsafeFreezeRef' behaves predictably when doing code generation, but it
-- can give strange results when evaluating in 'IO', as explained here:
--
-- <http://fun-discoveries.blogspot.se/2015/09/strictness-can-fix-non-termination.html>
veryUnsafeFreezeRef :: (VarPred exp a, EvalExp exp, CompExp exp) =>
    Ref a -> exp a
veryUnsafeFreezeRef (RefEval r) = litExp $! unsafePerformIO $! readIORef r
veryUnsafeFreezeRef (RefComp v) = varExp v



--------------------------------------------------------------------------------
-- * Arrays
--------------------------------------------------------------------------------

-- | Create an uninitialized an array
newArr
    :: ( pred a
       , pred i
       , Integral i
       , Ix i
       , ArrCMD (IExp instr) :<: instr
       , pred ~ VarPred (IExp instr)
       )
    => IExp instr i -> ProgramT instr m (Arr i a)
newArr n = singleE $ NewArr n

newArr_
    :: ( pred a
       , pred i
       , Integral i
       , Ix i
       , ArrCMD (IExp instr) :<: instr
       , pred ~ VarPred (IExp instr)
       )
    => ProgramT instr m (Arr i a)
newArr_ = singleE $ NewArr_

-- | Set the contents of an array
getArr
    :: ( VarPred (IExp instr) a
       , ArrCMD (IExp instr) :<: instr
       , Integral i
       , Ix i
       )
    => IExp instr i -> Arr i a -> ProgramT instr m (IExp instr a)
getArr i arr = singleE $ GetArr i arr

-- | Set the contents of an array
setArr
    :: ( VarPred (IExp instr) a
       , ArrCMD (IExp instr) :<: instr
       , Integral i
       , Ix i
       )
    => IExp instr i -> IExp instr a -> Arr i a -> ProgramT instr m ()
setArr i a arr = singleE (SetArr i a arr)



--------------------------------------------------------------------------------
-- * Control flow
--------------------------------------------------------------------------------

-- | Conditional statement
iff :: (ControlCMD (IExp instr) :<: instr)
    => IExp instr Bool      -- ^ Condition
    -> ProgramT instr m ()  -- ^ True branch
    -> ProgramT instr m ()  -- ^ False branch
    -> ProgramT instr m ()
iff b t f = singleE $ If b t f

-- | Conditional statement that returns an expression
ifE
    :: ( VarPred (IExp instr) a
       , ControlCMD (IExp instr) :<: instr
       , RefCMD (IExp instr)     :<: instr
       , Monad m
       )
    => IExp instr Bool                  -- ^ Condition
    -> ProgramT instr m (IExp instr a)  -- ^ True branch
    -> ProgramT instr m (IExp instr a)  -- ^ False branch
    -> ProgramT instr m (IExp instr a)
ifE b t f = do
    r <- newRef
    iff b (t >>= setRef r) (f >>= setRef r)
    getRef r

-- | While loop
while :: (ControlCMD (IExp instr) :<: instr)
    => ProgramT instr m (IExp instr Bool)  -- ^ Continue condition
    -> ProgramT instr m ()                 -- ^ Loop body
    -> ProgramT instr m ()
while b t = singleE $ While b t

-- | For loop
for
    :: ( ControlCMD (IExp instr) :<: instr
       , Integral n
       , VarPred (IExp instr) n
       )
    => IxRange (IExp instr n)                 -- ^ Index range
    -> (IExp instr n -> ProgramT instr m ())  -- ^ Loop body
    -> ProgramT instr m ()
for range = singleE . For range

-- | Break out from a loop
break :: (ControlCMD (IExp instr) :<: instr) => ProgramT instr m ()
break = singleE Break



--------------------------------------------------------------------------------
-- * File handling
--------------------------------------------------------------------------------

-- | Open a file
fopen :: (FileCMD (IExp instr) :<: instr) => FilePath -> IOMode -> ProgramT instr m Handle
fopen file = singleE . FOpen file

-- | Close a file
fclose :: (FileCMD (IExp instr) :<: instr) => Handle -> ProgramT instr m ()
fclose = singleE . FClose

-- | Check for end of file
feof :: (VarPred (IExp instr) Bool, FileCMD (IExp instr) :<: instr) =>
    Handle -> ProgramT instr m (IExp instr Bool)
feof = singleE . FEof

class PrintfType r
  where
    type PrintfExp r :: * -> *
    fprf :: Handle -> String -> [PrintfArg (PrintfExp r)] -> r

instance (FileCMD (IExp instr) :<: instr, a ~ ()) => PrintfType (ProgramT instr m a)
  where
    type PrintfExp (ProgramT instr m a) = IExp instr
    fprf h form as = singleE $ FPrintf h form (reverse as)

instance (Formattable a, VarPred exp a, PrintfType r, exp ~ PrintfExp r) =>
    PrintfType (exp a -> r)
  where
    type PrintfExp (exp a -> r) = exp
    fprf h form as = \a -> fprf h form (PrintfArg a : as)

-- | Print to a handle. Accepts a variable number of arguments.
fprintf :: PrintfType r => Handle -> String -> r
fprintf h format = fprf h format []

-- | Put a single value to a handle
fput :: forall instr a m
    .  (Formattable a, VarPred (IExp instr) a, FileCMD (IExp instr) :<: instr)
    => Handle
    -> String        -- ^ Prefix
    -> IExp instr a  -- ^ Expression to print
    -> String        -- ^ Suffix
    -> ProgramT instr m ()
fput hdl prefix a suffix =
    fprintf hdl (prefix ++ formatSpecifier (Proxy :: Proxy a) ++ suffix) a

-- | Get a single value from a handle
fget
    :: ( Formattable a
       , VarPred (IExp instr) a
       , FileCMD (IExp instr) :<: instr
       )
    => Handle -> ProgramT instr m (IExp instr a)
fget = singleE . FGet

-- | Print to @stdout@. Accepts a variable number of arguments.
printf :: PrintfType r => String -> r
printf = fprintf stdout



--------------------------------------------------------------------------------
-- * Abstract objects
--------------------------------------------------------------------------------

-- | Create a pointer to an abstract object. The only thing one can do with such
-- objects is to pass them to 'callFun' or 'callProc'.
newObject :: (ObjectCMD (IExp instr) :<: instr)
    => String  -- ^ Object type
    -> ProgramT instr m Object
newObject = singleE . NewObject

-- | Call a function to create a pointed object
initObject :: (ObjectCMD (IExp instr) :<: instr)
    => String                 -- ^ Function name
    -> String                 -- ^ Object type
    -> [FunArg (IExp instr)]  -- ^ Arguments
    -> ProgramT instr m Object
initObject fun ty args = singleE $ InitObject fun True ty args

-- | Call a function to create an object
initUObject :: (ObjectCMD (IExp instr) :<: instr)
    => String                 -- ^ Function name
    -> String                 -- ^ Object type
    -> [FunArg (IExp instr)]  -- ^ Arguments
    -> ProgramT instr m Object
initUObject fun ty args = singleE $ InitObject fun False ty args



--------------------------------------------------------------------------------
-- * External function calls (C-specific)
--------------------------------------------------------------------------------

-- | Add an @#include@ statement to the generated code
addInclude :: (CallCMD (IExp instr) :<: instr) => String -> ProgramT instr m ()
addInclude = singleE . AddInclude

-- | Add a global definition to the generated code
--
-- Can be used conveniently as follows:
--
-- > {-# LANGUAGE QuasiQuotes #-}
-- >
-- > import Language.Embedded.Imperative
-- > import Language.C.Quote.C
-- >
-- > prog = do
-- >     ...
-- >     addDefinition myCFunction
-- >     ...
-- >   where
-- >     myCFunction = [cedecl|
-- >       void my_C_function( ... )
-- >       {
-- >           // C code
-- >           // goes here
-- >       }
-- >       |]
addDefinition :: (CallCMD (IExp instr) :<: instr) => Definition -> ProgramT instr m ()
addDefinition = singleE . AddDefinition

-- | Declare an external function
addExternFun :: (VarPred exp res, CallCMD exp :<: instr, exp ~ IExp instr)
    => String           -- ^ Function name
    -> proxy (exp res)  -- ^ Proxy for expression and result type
    -> [FunArg exp]     -- ^ Arguments (only used to determine types)
    -> ProgramT instr m ()
addExternFun fun res args = singleE $ AddExternFun fun res args

-- | Declare an external procedure
addExternProc :: (CallCMD exp :<: instr, exp ~ IExp instr)
    => String        -- ^ Procedure name
    -> [FunArg exp]  -- ^ Arguments (only used to determine types)
    -> ProgramT instr m ()
addExternProc proc args = singleE $ AddExternProc proc args

-- | Call a function
callFun :: (VarPred (IExp instr) a, CallCMD (IExp instr) :<: instr)
    => String                 -- ^ Function name
    -> [FunArg (IExp instr)]  -- ^ Arguments
    -> ProgramT instr m (IExp instr a)
callFun fun as = singleE $ CallFun fun as

-- | Call a procedure
callProc :: (CallCMD (IExp instr) :<: instr)
    => String                 -- ^ Procedure name
    -> [FunArg (IExp instr)]  -- ^ Arguments
    -> ProgramT instr m ()
callProc fun as = singleE $ CallProc fun as

-- | Declare and call an external function
externFun :: forall instr m exp res
    .  (VarPred exp res, CallCMD exp :<: instr, exp ~ IExp instr, Monad m)
    => String        -- ^ Function name
    -> [FunArg exp]  -- ^ Arguments
    -> ProgramT instr m (exp res)
externFun fun args = do
    addExternFun fun (Proxy :: Proxy (exp res)) args
    callFun fun args

-- | Declare and call an external procedure
externProc :: (CallCMD exp :<: instr, exp ~ IExp instr, Monad m)
    => String        -- ^ Procedure name
    -> [FunArg exp]  -- ^ Arguments
    -> ProgramT instr m ()
externProc proc args = do
    addExternProc proc args
    callProc proc args

-- | Get current time as number of seconds passed today
getTime :: (VarPred (IExp instr) Double, CallCMD (IExp instr) :<: instr, Monad m) =>
    ProgramT instr m (IExp instr Double)
getTime = do
    addInclude "<sys/time.h>"
    addInclude "<sys/resource.h>"
    addDefinition getTimeDef
    callFun "get_time" []
  where
    getTimeDef = [cedecl|
      double get_time()
      {
          struct timeval t;
          struct timezone tzp;
          gettimeofday(&t, &tzp);
          return t.tv_sec + t.tv_usec*1e-6;
      }
      |]
      -- From http://stackoverflow.com/questions/2349776/how-can-i-benchmark-c-code-easily

-- Arguments

-- | Constant string argument
strArg :: String -> FunArg exp
strArg = FunArg . StrArg

-- | Value argument
valArg :: VarPred exp a => exp a -> FunArg exp
valArg = FunArg . ValArg

-- | Reference argument
refArg :: VarPred exp a => Ref a -> FunArg exp
refArg = FunArg . RefArg

-- | Array argument
arrArg :: VarPred exp a => Arr n a -> FunArg exp
arrArg = FunArg . ArrArg

-- | Abstract object argument
objArg :: Object -> FunArg exp
objArg = FunArg . ObjArg

-- | Modifier that takes the address of another argument
addr :: FunArg exp -> FunArg exp
addr = FunArg . Addr



--------------------------------------------------------------------------------
-- * Running programs
--------------------------------------------------------------------------------

-- | Run a program in 'IO'. Note that not all instructions are supported for
-- running in 'IO'. For example, calls to external C functions are not
-- supported.
runIO :: (Interp instr IO, HFunctor instr) => Program instr a -> IO a
runIO = interpret

-- | Like 'runIO' but with explicit input/output connected to @stdin@/@stdout@
captureIO :: (Interp instr IO, HFunctor instr)
    => Program instr a  -- ^ Program to run
    -> String           -- ^ Faked @stdin@
    -> IO String        -- ^ Captured @stdout@
captureIO = fakeIO . runIO

