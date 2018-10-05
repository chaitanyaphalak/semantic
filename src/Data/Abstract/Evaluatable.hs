{-# LANGUAGE GADTs, KindSignatures, RankNTypes, TypeOperators, UndecidableInstances, ScopedTypeVariables, InstanceSigs, ScopedTypeVariables #-}
module Data.Abstract.Evaluatable
( module X
, Evaluatable(..)
, ModuleEffects
, ValueEffects
, evaluate
, traceResolve
-- * Preludes
, HasPrelude(..)
-- * Postludes
, HasPostlude(..)
-- * Effects
, EvalError(..)
, throwEvalError
, runEvalError
, runEvalErrorWith
, UnspecializedError(..)
, runUnspecialized
, runUnspecializedWith
, throwUnspecializedError
) where

import Control.Abstract hiding (Load)
import Control.Abstract.Context as X
import Control.Abstract.Environment as X hiding (runEnvironmentError, runEnvironmentErrorWith)
import Control.Abstract.Evaluator as X hiding (LoopControl(..), Return(..), catchLoopControl, runLoopControl, catchReturn, runReturn)
import Control.Abstract.Heap as X hiding (runAddressError, runAddressErrorWith)
import Control.Abstract.Modules as X (Modules, ModuleResult, ResolutionError(..), load, lookupModule, listModulesInDir, require, resolve, throwResolutionError)
import Control.Abstract.Value as X hiding (Boolean(..), Function(..))
import Control.Abstract.ScopeGraph
import Data.Abstract.Declarations as X
import Data.Abstract.Environment as X
import Data.Abstract.BaseError as X
import Data.Abstract.FreeVariables as X
import Data.Abstract.Module
import Data.Abstract.ModuleTable as ModuleTable
import Data.Abstract.Name as X
import Data.Abstract.Ref as X
import Data.Coerce
import Data.Language
import Data.Scientific (Scientific)
import Data.Semigroup.App
import Data.Semigroup.Foldable
import Data.Sum
import Data.Term
import Prologue

-- | The 'Evaluatable' class defines the necessary interface for a term to be evaluated. While a default definition of 'eval' is given, instances with computational content must implement 'eval' to perform their small-step operational semantics.
class (Show1 constr, Foldable constr) => Evaluatable constr where
  eval :: ( AbstractValue address value effects
          , Declarations term
          , FreeVariables term
          , Member (Allocator address) effects
          , Member (Boolean value) effects
          , Member (Deref value) effects
          , Member (State (ScopeGraph address)) effects
          , Member (Exc (LoopControl value)) effects
          , Member (Exc (Return value)) effects
          , Member Fresh effects
          , Member (Function address value) effects
          , Member (Modules address value) effects
          , Member (Reader ModuleInfo) effects
          , Member (Reader PackageInfo) effects
          , Member (Reader Span) effects
          , Member (State Span) effects
          , Member (Resumable (BaseError (AddressError address value))) effects
          , Member (Resumable (BaseError (UnspecializedError value))) effects
          , Member (Resumable (BaseError EvalError)) effects
          , Member (Resumable (BaseError ResolutionError)) effects
          , Member (State (Heap address address value)) effects
          , Member Trace effects
          , Ord address
          )
       => SubtermAlgebra constr term (Evaluator address value effects (ValueRef address value))
  eval expr = do
    traverse_ subtermRef expr
    v <- throwUnspecializedError $ UnspecializedError ("Eval unspecialized for " <> liftShowsPrec (const (const id)) (const id) 0 expr "")
    rvalBox v


type ModuleEffects address value rest
  =  Exc (LoopControl value)
  ': Exc (Return value)
  ': State (ScopeGraph address)
  ': Deref value
  ': Allocator address
  ': Reader ModuleInfo
  ': rest

type ValueEffects address value rest
  =  Function address value
  ': Boolean value
  ': rest

evaluate :: forall address value valueEffects term  moduleEffects effects proxy lang. ( AbstractValue address value valueEffects
            , Declarations term
            , Effects effects
            , Evaluatable (Base term)
            , FreeVariables term
            , HasPostlude lang
            , HasPrelude lang
            , Member Fresh effects
            , Member (Allocator (Address address)) effects
            , Member (Modules address value) effects
            , Member (Reader (ModuleTable (NonEmpty (Module (ModuleResult address value))))) effects
            , Member (Reader PackageInfo) effects
            , Member (Reader Span) effects
            , Member (State Span) effects
            , Member (Resumable (BaseError (HeapError address))) effects
            , Member (Resumable (BaseError (AddressError address value))) effects
            , Member (Resumable (BaseError (ScopeError address))) effects
            , Member (Resumable (BaseError EvalError)) effects
            , Member (Resumable (BaseError ResolutionError)) effects
            , Member (Resumable (BaseError (UnspecializedError value))) effects
            , Member (State (Heap address address value)) effects
            , Member Trace effects
            , Ord address
            , Recursive term
            , moduleEffects ~ ModuleEffects address value effects
            , valueEffects ~ ValueEffects address value moduleEffects
            )
         => proxy lang
         -> (SubtermAlgebra Module      term (TermEvaluator term address value moduleEffects value)           -> SubtermAlgebra Module      term (TermEvaluator term address value moduleEffects value))
         -> (SubtermAlgebra (Base term) term (TermEvaluator term address value valueEffects (ValueRef address value)) -> SubtermAlgebra (Base term) term (TermEvaluator term address value valueEffects (ValueRef address value)))
         -> (forall x . Evaluator address value (Deref value ': Allocator address ': Reader ModuleInfo ': effects) x -> Evaluator address value (Reader ModuleInfo ': effects) x)
         -> (forall x . Evaluator address value valueEffects x -> Evaluator address value moduleEffects x)
         -> [Module term]
         -> TermEvaluator term address value effects (ModuleTable (NonEmpty (Module (ModuleResult address value))))
evaluate lang analyzeModule analyzeTerm runAllocDeref runValue modules = ((do
  (_, _) <- TermEvaluator . runInModule moduleInfoFromCallStack . runValue $ do
    definePrelude lang
    pure unit
  foldr run ask modules) :: TermEvaluator term address value effects (ModuleTable (NonEmpty (Module (ModuleResult address value)))))
  where
    run :: Module term -> TermEvaluator term address value effects a -> TermEvaluator term address value effects a
    run m rest = do
      evaluated <- (raiseHandler
        (runInModule (moduleInfo m))
        (analyzeModule (subtermRef . moduleBody)
        (evalModuleBody <$> m)) :: TermEvaluator term address value effects (ScopeGraph address, value))
      -- FIXME: this should be some sort of Monoidal insert à la the Heap to accommodate multiple Go files being part of the same module.
      local (ModuleTable.insert (modulePath (moduleInfo m)) ((evaluated <$ m) :| [])) rest

    evalModuleBody term = Subterm term (coerce runValue (do
      result <- foldSubterms (analyzeTerm (TermEvaluator . eval . fmap (second runTermEvaluator))) term >>= TermEvaluator . value
      result <$ TermEvaluator (postlude lang)))

    runInModule :: ModuleInfo -> Evaluator address value moduleEffects value -> Evaluator address value effects (ScopeGraph address, value)
    runInModule info
      = runReader info
      . runAllocDeref
      . runState lowerBound
      . runReturn
      . runLoopControl


traceResolve :: (Show a, Show b, Member Trace effects) => a -> b -> Evaluator address value effects ()
traceResolve name path = trace ("resolved " <> show name <> " -> " <> show path)


-- Preludes

class HasPrelude (language :: Language) where
  definePrelude :: ( AbstractValue address value effects
                   , HasCallStack
                   , Member (Allocator (Address address)) effects
                   , Member (Allocator address) effects
                   , Member (State (ScopeGraph address)) effects
                   , Member (Resumable (BaseError (ScopeError address))) effects
                   , Member (Resumable (BaseError (HeapError address))) effects
                   , Member (Deref value) effects
                   , Member Fresh effects
                   , Member (Function address value) effects
                   , Member (Reader ModuleInfo) effects
                   , Member (Reader Span) effects
                   , Member (Resumable (BaseError (AddressError address value))) effects
                   , Member (State (Heap address address value)) effects
                   , Member Trace effects
                   , Ord address
                   )
                => proxy language
                -> Evaluator address value effects ()
  definePrelude _ = pure ()

instance HasPrelude 'Go
instance HasPrelude 'Haskell
instance HasPrelude 'Java
instance HasPrelude 'PHP

instance HasPrelude 'Python where
  definePrelude _ =
    void $ define (Declaration (X.name "print")) builtInPrint

instance HasPrelude 'Ruby where
  definePrelude :: forall address value effects proxy. ( AbstractValue address value effects
                   , HasCallStack
                   , Member (Allocator (Address address)) effects
                   , Member (Allocator address) effects
                   , Member (State (ScopeGraph address)) effects
                   , Member (Resumable (BaseError (ScopeError address))) effects
                   , Member (Resumable (BaseError (HeapError address))) effects
                   , Member (Deref value) effects
                   , Member Fresh effects
                   , Member (Function address value) effects
                   , Member (Reader ModuleInfo) effects
                   , Member (Reader Span) effects
                   , Member (Resumable (BaseError (AddressError address value))) effects
                   , Member (State (Heap address address value)) effects
                   , Member Trace effects
                   , Ord address
                   )
                => proxy 'Ruby
                -> Evaluator address value effects ()
  definePrelude _ = do
    define (Declaration (X.name "puts")) builtInPrint

    defineClass (Declaration (X.name "Object")) [] $ do
      define (Declaration (X.name "inspect")) (lambda @address @value @effects @(Evaluator address value effects value) (pure (string "<object>")))

instance HasPrelude 'TypeScript where
  definePrelude _ =
    defineNamespace (Declaration (X.name "console")) $ do
      define (Declaration (X.name "log")) builtInPrint

instance HasPrelude 'JavaScript where
  definePrelude _ = do
    defineNamespace (Declaration (X.name "console")) $ do
      define (Declaration (X.name "log")) builtInPrint

-- Postludes

class HasPostlude (language :: Language) where
  postlude :: ( AbstractValue address value effects
              , HasCallStack
              , Member (Allocator (Address address)) effects
              , Member (Deref value) effects
              , Member Fresh effects
              , Member (Reader ModuleInfo) effects
              , Member (Reader Span) effects
              , Member Trace effects
              )
           => proxy language
           -> Evaluator address value effects ()
  postlude _ = pure ()

instance HasPostlude 'Go
instance HasPostlude 'Haskell
instance HasPostlude 'Java
instance HasPostlude 'PHP
instance HasPostlude 'Python
instance HasPostlude 'Ruby
instance HasPostlude 'TypeScript

instance HasPostlude 'JavaScript where
  postlude _ = trace "JS postlude"


-- Effects

-- | The type of error thrown when failing to evaluate a term.
data EvalError return where
  NoNameError :: EvalError Name
  -- Indicates that our evaluator wasn't able to make sense of these literals.
  IntegerFormatError  :: Text -> EvalError Integer
  FloatFormatError    :: Text -> EvalError Scientific
  RationalFormatError :: Text -> EvalError Rational
  DefaultExportError  :: EvalError ()
  ExportError         :: ModulePath -> Name -> EvalError ()

deriving instance Eq (EvalError return)
deriving instance Show (EvalError return)

instance Eq1 EvalError where
  liftEq _ NoNameError        NoNameError                  = True
  liftEq _ DefaultExportError DefaultExportError           = True
  liftEq _ (ExportError a b) (ExportError c d)             = (a == c) && (b == d)
  liftEq _ (IntegerFormatError a) (IntegerFormatError b)   = a == b
  liftEq _ (FloatFormatError a) (FloatFormatError b)       = a == b
  liftEq _ (RationalFormatError a) (RationalFormatError b) = a == b
  liftEq _ _ _                                             = False

instance Show1 EvalError where
  liftShowsPrec _ _ = showsPrec

runEvalError :: (Effectful m, Effects effects) => m (Resumable (BaseError EvalError) ': effects) a -> m effects (Either (SomeExc (BaseError EvalError)) a)
runEvalError = runResumable

runEvalErrorWith :: (Effectful m, Effects effects) => (forall resume . (BaseError EvalError) resume -> m effects resume) -> m (Resumable (BaseError EvalError) ': effects) a -> m effects a
runEvalErrorWith = runResumableWith

throwEvalError :: ( Member (Reader ModuleInfo) effects
                  , Member (Reader Span) effects
                  , Member (Resumable (BaseError EvalError)) effects
                  )
               => EvalError resume
               -> Evaluator address value effects resume
throwEvalError = throwBaseError


data UnspecializedError a b where
  UnspecializedError :: String -> UnspecializedError value value

deriving instance Eq (UnspecializedError a b)
deriving instance Show (UnspecializedError a b)

instance Eq1 (UnspecializedError a) where
  liftEq _ (UnspecializedError a) (UnspecializedError b) = a == b

instance Show1 (UnspecializedError a) where
  liftShowsPrec _ _ = showsPrec

runUnspecialized :: (Effectful (m value), Effects effects)
                 => m value (Resumable (BaseError (UnspecializedError value)) ': effects) a
                 -> m value effects (Either (SomeExc (BaseError (UnspecializedError value))) a)
runUnspecialized = runResumable

runUnspecializedWith :: (Effectful (m value), Effects effects)
                     => (forall resume . BaseError (UnspecializedError value) resume -> m value effects resume)
                     -> m value (Resumable (BaseError (UnspecializedError value)) ': effects) a
                     -> m value effects a
runUnspecializedWith = runResumableWith

throwUnspecializedError :: ( Member (Resumable (BaseError (UnspecializedError value))) effects
                           , Member (Reader ModuleInfo) effects
                           , Member (Reader Span) effects
                           )
                        => UnspecializedError value resume
                        -> Evaluator address value effects resume
throwUnspecializedError = throwBaseError


-- Instances

-- | If we can evaluate any syntax which can occur in a 'Sum', we can evaluate the 'Sum'.
instance (Apply Evaluatable fs, Apply Show1 fs, Apply Foldable fs) => Evaluatable (Sum fs) where
  eval = apply @Evaluatable eval

-- | Evaluating a 'TermF' ignores its annotation, evaluating the underlying syntax.
instance (Evaluatable s, Show a) => Evaluatable (TermF s a) where
  eval = eval . termFOut


-- NOTE: Use 'Data.Syntax.Statements' instead of '[]' if you need imperative eval semantics.
--
-- | '[]' is treated as an imperative sequence of statements/declarations s.t.:
--
--   1. Each statement’s effects on the store are accumulated;
--   2. Each statement can affect the environment of later statements (e.g. by 'modify'-ing the environment); and
--   3. Only the last statement’s return value is returned.
instance Evaluatable [] where
  -- 'nonEmpty' and 'foldMap1' enable us to return the last statement’s result instead of 'unit' for non-empty lists.
  eval = maybe (rvalBox unit) (runApp . foldMap1 (App . subtermRef)) . nonEmpty
