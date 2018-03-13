{-|
Module: Squeal.PostgreSQL.PQ
Description: PQ monad
Copyright: (c) Eitan Chatav, 2017
Maintainer: eitan@morphism.tech
Stability: experimental

`Squeal.PostgreSQL.PQ` is where Squeal statements come to actually get run by
`LibPQ`. It contains a `PQ` indexed monad transformer to run `Definition`s and
a `MonadPQ` constraint for running a `Manipulation` or `Query`.
-}

{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
{-# LANGUAGE
    DataKinds
  , DefaultSignatures
  , FunctionalDependencies
  , PolyKinds
  , DeriveFunctor
  , FlexibleContexts
  , FlexibleInstances
  , MagicHash
  , MultiParamTypeClasses
  , OverloadedStrings
  , RankNTypes
  , ScopedTypeVariables
  , TypeApplications
  , TypeFamilies
  , TypeInType
  , TypeOperators
  , UndecidableInstances
#-}

module Squeal.PostgreSQL.PQ
  ( -- * Connection
    connectdb
  , finish
  , withConnection
    -- * PQ
  , PQ (PQ, runPQ)
  , execPQ
  , pqEmbed
  , pqAp
  , pqBind
  , pqJoin
  , pqThen
  , define
  , thenDefine
    -- * MonadPQ
  , MonadPQ (..)
  , PQRun
  , pqliftWith
    -- * Result
  , RowNumber (RowNumber, unRowNumber)
  , ColumnNumber (UnsafeColumnNumber, getColumnNumber)
  , HasColumnNumber (columnNumber)
  , getValue
  , getRow
  , getRows
  , ntuples
  , nextRow
  , firstRow
  , liftResult
  -- * Re-export
  , LibPQ.Connection
  , LibPQ.Result
  ) where

import Control.Exception.Lifted
import Control.Monad.Base
import Control.Monad.Except
import Control.Monad.Trans.Control
import Data.ByteString (ByteString)
import Data.Foldable
import Data.Function ((&))
import Data.Kind
import Data.Monoid
import Data.Traversable
import Generics.SOP
import GHC.Exts hiding (fromList)
import GHC.TypeLits

import qualified Database.PostgreSQL.LibPQ as LibPQ

import Squeal.PostgreSQL.Binary
import Squeal.PostgreSQL.Definition
import Squeal.PostgreSQL.Manipulation
import Squeal.PostgreSQL.Query
import Squeal.PostgreSQL.Schema

-- For `MonadPQ` transformer instances
import Control.Monad.Trans.Identity
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.Cont
import Control.Monad.Trans.List

import qualified Control.Monad.Trans.State.Lazy as Lazy
import qualified Control.Monad.Trans.State.Strict as Strict
import qualified Control.Monad.Trans.Writer.Lazy as Lazy
import qualified Control.Monad.Trans.Writer.Strict as Strict
import qualified Control.Monad.Trans.RWS.Lazy as Lazy
import qualified Control.Monad.Trans.RWS.Strict as Strict

{- | Makes a new connection to the database server.

This function opens a new database connection using the parameters taken
from the string conninfo.

The passed string can be empty to use all default parameters, or it can
contain one or more parameter settings separated by whitespace.
Each parameter setting is in the form keyword = value. Spaces around the equal
sign are optional. To write an empty value or a value containing spaces,
surround it with single quotes, e.g., keyword = 'a value'. Single quotes and
backslashes within the value must be escaped with a backslash, i.e., ' and \.

To specify the schema you wish to connect with, use type application.

>>> :set -XDataKinds
>>> :set -XPolyKinds
>>> :set -XTypeOperators
>>> type Schema = '["tab" ::: '[] :=> '["col" ::: 'NoDef :=> 'Null 'PGint2]]
>>> :set -XTypeApplications
>>> :set -XOverloadedStrings
>>> conn <- connectdb @Schema "host=localhost port=5432 dbname=exampledb"

Note that, for now, squeal doesn't offer any protection from connecting
with the wrong schema!
-}
connectdb
  :: forall schema io
   . MonadBase IO io
  => ByteString -- ^ conninfo
  -> io (K LibPQ.Connection schema)
connectdb = fmap K . liftBase . LibPQ.connectdb

-- | Closes the connection to the server.
finish :: MonadBase IO io => K LibPQ.Connection schema -> io ()
finish = liftBase . LibPQ.finish . unK

-- | Do `connectdb` and `finish` before and after a computation.
withConnection
  :: forall schema0 schema1 io x
   . MonadBaseControl IO io
  => ByteString
  -> (K LibPQ.Connection schema0 -> io (x, K LibPQ.Connection schema1))
  -> io x
withConnection connString action = do
  (x, _conn) <- bracket (connectdb connString) finish action
  return x

-- | We keep track of the schema via an Atkey indexed state monad transformer,
-- `PQ`.
newtype PQ
  (schema0 :: TablesType)
  (schema1 :: TablesType)
  (m :: Type -> Type)
  (x :: Type) =
    PQ { runPQ :: K LibPQ.Connection schema0 -> m (K x schema1) }

instance Monad m => Functor (PQ schema0 schema1 m) where
  fmap f (PQ pq) = PQ $ \ conn -> do
    K x <- pq conn
    return $ K (f x)

-- | Run a `PQ` and discard the result but keep the `Connection`. 
execPQ
  :: Functor m
  => PQ schema0 schema1 m x
  -> K LibPQ.Connection schema0
  -> m (K LibPQ.Connection schema1)
execPQ (PQ pq) conn = fmap (mapKK (\ _ -> unK conn)) $ pq conn

pqEmbed
  :: Monad m
  => PQ schema0 schema1 m x
  -> PQ (table ': schema0) (table : schema1) m x
pqEmbed (PQ pq) = PQ $ \ (K conn) -> do
  K x <- pq (K conn)
  return $ K x

-- | indexed analog of `<*>`
pqAp
  :: Monad m
  => PQ schema0 schema1 m (x -> y)
  -> PQ schema1 schema2 m x
  -> PQ schema0 schema2 m y
pqAp (PQ f) (PQ x) = PQ $ \ conn -> do
  K f' <- f conn
  K x' <- x (K (unK conn))
  return $ K (f' x')

-- | indexed analog of `join`
pqJoin
  :: Monad m
  => PQ schema0 schema1 m (PQ schema1 schema2 m y)
  -> PQ schema0 schema2 m y
pqJoin pq = pq & pqBind id

pqBind
  :: Monad m
  => (x -> PQ schema1 schema2 m y)
  -> PQ schema0 schema1 m x
  -> PQ schema0 schema2 m y
pqBind f (PQ x) = PQ $ \ conn -> do
  K x' <- x conn
  runPQ (f x') (K (unK conn))

-- | indexed analog of flipped `>>`
pqThen
  :: Monad m
  => PQ schema1 schema2 m y
  -> PQ schema0 schema1 m x
  -> PQ schema0 schema2 m y
pqThen pq2 pq1 = pq1 & pqBind (\ _ -> pq2)

-- | Run a `Definition` with `LibPQ.exec`, we expect that libpq obeys the law
--
-- @define statement1 & thenDefine statement2 = define (statement1 >>> statement2)@
define
  :: MonadBase IO io
  => Definition schema0 schema1
  -> PQ schema0 schema1 io (K LibPQ.Result '[])
define (UnsafeDefinition q) = PQ $ \ (K conn) -> do
  resultMaybe <- liftBase $ LibPQ.exec conn q
  case resultMaybe of
    Nothing -> error
      "define: LibPQ.exec returned no results"
    Just result -> return $ K (K result)

-- | Chain together `define` actions.
thenDefine
  :: MonadBase IO io
  => Definition schema1 schema2
  -> PQ schema0 schema1 io x
  -> PQ schema0 schema2 io (K LibPQ.Result '[])
thenDefine = pqThen . define

{- | `MonadPQ` is an `mtl` style constraint, similar to
`Control.Monad.State.Class.MonadState`, for using `LibPQ` to

* `manipulateParams` runs a `Manipulation` with params from a type
   with a `ToParams` constraint. It calls `LibPQ.execParams` and
   doesn't afraid of anything.

* `manipulate` is like `manipulateParams` for a parameter-free statement.

* `runQueryParams` is like `manipulateParams` for query statements.

* `traversePrepared` has the same type signature as a composition of
  `traverse` and `manipulateParams` but provides an optimization by
  preparing the statement with `LibPQ.prepare` and then traversing a
  `Traversable` container with `LibPQ.execPrepared`. The temporary prepared
  statement is then deallocated.

* `forPrepared` is a flipped `traversePrepared`

* `traversePrepared_` is like `traversePrepared` but works on `Foldable`
  containers and returns unit.

* `forPrepared_` is a flipped `traversePrepared_`.

* `liftPQ` lets you lift actions from `LibPQ` that require a connection
  into your monad.

To define an instance, you can minimally define only `manipulateParams`,
`traversePrepared`, `traversePrepared_` and `liftPQ`. Monad transformers get
a default instance.

-}
class Monad pq => MonadPQ schema pq | pq -> schema where
  manipulateParams
    :: ToParams x params
    => Manipulation schema params ys
    -- ^ `insertInto`, `update` or `deleteFrom`
    -> x -> pq (K LibPQ.Result ys)
  default manipulateParams
    :: (MonadTrans t, MonadPQ schema pq1, pq ~ t pq1)
    => ToParams x params
    => Manipulation schema params ys
    -- ^ `insertInto`, `update` or `deleteFrom`
    -> x -> pq (K LibPQ.Result ys)
  manipulateParams manipulation params = lift $
    manipulateParams manipulation params

  manipulate :: Manipulation schema '[] ys -> pq (K LibPQ.Result ys)
  manipulate statement = manipulateParams statement ()

  runQueryParams
    :: ToParams x params
    => Query schema params ys
    -- ^ `select` and friends
    -> x -> pq (K LibPQ.Result ys)
  runQueryParams = manipulateParams . queryStatement

  runQuery
    :: Query schema '[] ys
    -- ^ `select` and friends
    -> pq (K LibPQ.Result ys)
  runQuery q = runQueryParams q ()

  traversePrepared
    :: (ToParams x params, Traversable list)
    => Manipulation schema params ys
    -- ^ `insertInto`, `update` or `deleteFrom`
    -> list x -> pq (list (K LibPQ.Result ys))
  default traversePrepared
    :: (MonadTrans t, MonadPQ schema pq1, pq ~ t pq1)
    => (ToParams x params, Traversable list)
    => Manipulation schema params ys -> list x -> pq (list (K LibPQ.Result ys))
  traversePrepared manipulation params = lift $
    traversePrepared manipulation params

  forPrepared
    :: (ToParams x params, Traversable list)
    => list x
    -> Manipulation schema params ys
    -- ^ `insertInto`, `update` or `deleteFrom`
    -> pq (list (K LibPQ.Result ys))
  forPrepared = flip traversePrepared

  traversePrepared_
    :: (ToParams x params, Foldable list)
    => Manipulation schema params '[]
    -- ^ `insertInto`, `update` or `deleteFrom`
    -> list x -> pq ()
  default traversePrepared_
    :: (MonadTrans t, MonadPQ schema pq1, pq ~ t pq1)
    => (ToParams x params, Foldable list)
    => Manipulation schema params '[]
    -- ^ `insertInto`, `update` or `deleteFrom`
    -> list x -> pq ()
  traversePrepared_ manipulation params = lift $
    traversePrepared_ manipulation params

  forPrepared_
    :: (ToParams x params, Foldable list)
    => list x
    -> Manipulation schema params '[]
    -- ^ `insertInto`, `update` or `deleteFrom`
    -> pq ()
  forPrepared_ = flip traversePrepared_

  liftPQ :: (LibPQ.Connection -> IO a) -> pq a
  default liftPQ
    :: (MonadTrans t, MonadPQ schema pq1, pq ~ t pq1)
    => (LibPQ.Connection -> IO a) -> pq a
  liftPQ = lift . liftPQ

instance MonadBase IO io => MonadPQ schema (PQ schema schema io) where

  manipulateParams
    (UnsafeManipulation q :: Manipulation schema ps ys) (params :: x) =
      PQ $ \ (K conn) -> do
        let
          toParam' bytes = (LibPQ.invalidOid,bytes,LibPQ.Binary)
          params' = fmap (fmap toParam') (hcollapse (toParams @x @ps params))
        resultMaybe <- liftBase $ LibPQ.execParams conn q params' LibPQ.Binary
        case resultMaybe of
          Nothing -> error
            "manipulateParams: LibPQ.execParams returned no results"
          Just result -> return $ K (K result)

  traversePrepared
    (UnsafeManipulation q :: Manipulation schema xs ys) (list :: list x) =
      PQ $ \ (K conn) -> liftBase $ do
        let temp = "temporary_statement"
        prepResultMaybe <- LibPQ.prepare conn temp q Nothing
        case prepResultMaybe of
          Nothing -> error
            "traversePrepared: LibPQ.prepare returned no results"
          Just prepResult -> do
            status <- LibPQ.resultStatus prepResult
            unless (status == LibPQ.CommandOk) . error $
              "traversePrepared: LibPQ.prepare status " <> show status
        results <- for list $ \ params -> do
          let
            toParam' bytes = (bytes,LibPQ.Binary)
            params' = fmap (fmap toParam') (hcollapse (toParams @x @xs params))
          resultMaybe <- LibPQ.execPrepared conn temp params' LibPQ.Binary
          case resultMaybe of
            Nothing -> error
              "traversePrepared: LibPQ.execParams returned no results"
            Just result -> return $ K result
        deallocResultMaybe <- LibPQ.exec conn ("DEALLOCATE " <> temp <> ";")
        case deallocResultMaybe of
          Nothing -> error
            "traversePrepared: LibPQ.exec DEALLOCATE returned no results"
          Just deallocResult -> do
            status <- LibPQ.resultStatus deallocResult
            unless (status == LibPQ.CommandOk) . error $
              "traversePrepared: DEALLOCATE status " <> show status
        return (K results)

  traversePrepared_
    (UnsafeManipulation q :: Manipulation schema xs '[]) (list :: list x) =
      PQ $ \ (K conn) -> liftBase $ do
        let temp = "temporary_statement"
        prepResultMaybe <- LibPQ.prepare conn temp q Nothing
        case prepResultMaybe of
          Nothing -> error
            "traversePrepared_: LibPQ.prepare returned no results"
          Just prepResult -> do
            status <- LibPQ.resultStatus prepResult
            unless (status == LibPQ.CommandOk) . error $
              "traversePrepared: LibPQ.prepare status " <> show status
        for_ list $ \ params -> do
          let
            toParam' bytes = (bytes,LibPQ.Binary)
            params' = fmap (fmap toParam') (hcollapse (toParams @x @xs params))
          resultMaybe <- LibPQ.execPrepared conn temp params' LibPQ.Binary
          case resultMaybe of
            Nothing -> error
              "traversePrepared_: LibPQ.execParams returned no results"
            Just _result -> return ()
        deallocResultMaybe <- LibPQ.exec conn ("DEALLOCATE " <> temp <> ";")
        case deallocResultMaybe of
          Nothing -> error
            "traversePrepared: LibPQ.exec DEALLOCATE returned no results"
          Just deallocResult -> do
            status <- LibPQ.resultStatus deallocResult
            unless (status == LibPQ.CommandOk) . error $
              "traversePrepared: DEALLOCATE status " <> show status
        return (K ())

  liftPQ pq = PQ $ \ (K conn) -> do
    y <- liftBase $ pq conn
    return (K y)

instance MonadPQ schema m => MonadPQ schema (IdentityT m)
instance MonadPQ schema m => MonadPQ schema (ReaderT r m)
instance MonadPQ schema m => MonadPQ schema (Strict.StateT s m)
instance MonadPQ schema m => MonadPQ schema (Lazy.StateT s m)
instance (Monoid w, MonadPQ schema m) => MonadPQ schema (Strict.WriterT w m)
instance (Monoid w, MonadPQ schema m) => MonadPQ schema (Lazy.WriterT w m)
instance MonadPQ schema m => MonadPQ schema (MaybeT m)
instance MonadPQ schema m => MonadPQ schema (ExceptT e m)
instance (Monoid w, MonadPQ schema m) => MonadPQ schema (Strict.RWST r w s m)
instance (Monoid w, MonadPQ schema m) => MonadPQ schema (Lazy.RWST r w s m)
instance MonadPQ schema m => MonadPQ schema (ContT r m)
instance MonadPQ schema m => MonadPQ schema (ListT m)

instance Monad m => Applicative (PQ schema schema m) where
  pure x = PQ $ \ _conn -> pure (K x)
  (<*>) = pqAp

instance Monad m => Monad (PQ schema schema m) where
  return = pure
  (>>=) = flip pqBind

instance MonadTrans (PQ schema schema) where
  lift m = PQ $ \ _conn -> do
    x <- m
    return (K x)

instance MonadBase b m => MonadBase b (PQ schema schema m) where
  liftBase = lift . liftBase

-- | A snapshot of the state of a `PQ` computation.
type PQRun schema =
  forall m x. Monad m => PQ schema schema m x -> m (K x schema)

-- | Helper function in defining `MonadBaseControl` instance for `PQ`.
pqliftWith :: Functor m => (PQRun schema -> m a) -> PQ schema schema m a
pqliftWith f = PQ $ \ conn ->
  fmap K (f $ \ pq -> runPQ pq conn)

instance MonadBaseControl b m => MonadBaseControl b (PQ schema schema m) where
  type StM (PQ schema schema m) x = StM m (K x schema)
  liftBaseWith f =
    pqliftWith $ \ run -> liftBaseWith $ \ runInBase -> f $ runInBase . run
  restoreM = PQ . const . restoreM

-- | Just newtypes around a `CInt`
newtype RowNumber = RowNumber { unRowNumber :: LibPQ.Row }

-- | In addition to being newtypes around a `CInt`, a `ColumnNumber` is
-- parameterized by a `Nat`ural number and acts as an index into a row.
newtype ColumnNumber (n :: Nat) (cs :: [k]) (c :: k) =
  UnsafeColumnNumber { getColumnNumber :: LibPQ.Column }

-- | >>> getColumnNumber (columnNumber @5 @'[_,_,_,_,_,_])
-- Col 5
class KnownNat n => HasColumnNumber n columns column
  | n columns -> column where
  columnNumber :: ColumnNumber n columns column
  columnNumber =
    UnsafeColumnNumber . fromIntegral $ natVal' (proxy# :: Proxy# n)
instance {-# OVERLAPPING #-} HasColumnNumber 0 (column1:columns) column1
instance {-# OVERLAPPABLE #-}
  (KnownNat n, HasColumnNumber (n-1) columns column)
    => HasColumnNumber n (column' : columns) column

-- | Get a single value corresponding to a given row and column number
-- from a `Result`.
getValue
  :: (FromColumnValue colty y, MonadBase IO io)
  => RowNumber -- ^ row
  -> ColumnNumber n columns colty -- ^ col
  -> K LibPQ.Result columns -- ^ result
  -> io y
getValue
  (RowNumber r)
  (UnsafeColumnNumber c :: ColumnNumber n columns colty)
  (K result)
   = fmap (fromColumnValue @colty . K) $ liftBase $ do
      numRows <- LibPQ.ntuples result
      when (numRows < r) $ error $
        "getValue: expected at least " <> show r <> "rows but only saw "
        <> show numRows
      LibPQ.getvalue result r c

-- | Get a row corresponding to a given row number from a `Result`.
getRow
  :: (FromRow columns y, MonadBase IO io)
  => RowNumber
  -- ^ row
  -> K LibPQ.Result columns
  -- ^ result
  -> io y
getRow (RowNumber r) (K result :: K LibPQ.Result columns) = liftBase $ do
  numRows <- LibPQ.ntuples result
  when (numRows < r) $ error $
    "getRow: expected at least " <> show r <> "rows but only saw "
    <> show numRows
  let len = fromIntegral (lengthSList (Proxy @columns))
  row' <- traverse (LibPQ.getvalue result r) [0 .. len - 1]
  case fromList row' of
    Nothing -> error "getRow: found unexpected length"
    Just row -> return $ fromRow @columns row

-- | Returns the number of rows (tuples) in the query result.
ntuples :: MonadBase IO io => K LibPQ.Result columns -> io RowNumber
ntuples (K result) = liftBase $ RowNumber <$> LibPQ.ntuples result

-- | Intended to be used for unfolding in streaming libraries, `nextRow`
-- takes a total number of rows (which can be found with `ntuples`)
-- and a `Result` and given a row number if it's too large returns `Nothing`,
-- otherwise returning the row along with the next row number.
nextRow
  :: (FromRow columns y, MonadBase IO io)
  => RowNumber -- ^ total number of rows
  -> K LibPQ.Result columns -- ^ result
  -> RowNumber -- ^ row number
  -> io (Maybe (RowNumber,y))
nextRow (RowNumber total) (K result :: K LibPQ.Result columns) (RowNumber r)
  = liftBase $ if r >= total then return Nothing else do
    let len = fromIntegral (lengthSList (Proxy @columns))
    row' <- traverse (LibPQ.getvalue result r) [0 .. len - 1]
    case fromList row' of
      Nothing -> error "nextRow: found unexpected length"
      Just row -> return $ Just (RowNumber (r+1), fromRow @columns row)

-- | Get all rows from a `Result`.
getRows
  :: (FromRow columns y, MonadBase IO io)
  => K LibPQ.Result columns -- ^ result
  -> io [y]
getRows (K result :: K LibPQ.Result columns) = liftBase $ do
  let len = fromIntegral (lengthSList (Proxy @columns))
  numRows <- LibPQ.ntuples result
  for [0 .. numRows - 1] $ \ r -> do
    row' <- traverse (LibPQ.getvalue result r) [0 .. len - 1]
    case fromList row' of
      Nothing -> error "getRows: found unexpected length"
      Just row -> return $ fromRow @columns row

-- | Get the first row if possible from a `Result`.
firstRow
  :: (FromRow columns y, MonadBase IO io)
  => K LibPQ.Result columns -- ^ result
  -> io (Maybe y)
firstRow (K result :: K LibPQ.Result columns) = liftBase $ do
  numRows <- LibPQ.ntuples result
  if numRows <= 0 then return Nothing else do
    let len = fromIntegral (lengthSList (Proxy @columns))
    row' <- traverse (LibPQ.getvalue result 0) [0 .. len - 1]
    case fromList row' of
      Nothing -> error "firstRow: found unexpected length"
      Just row -> return . Just $ fromRow @columns row

-- | Lifts actions on results from `LibPQ`.
liftResult
  :: MonadBase IO io
  => (LibPQ.Result -> IO x)
  -> K LibPQ.Result results -> io x
liftResult f (K result) = liftBase $ f result
