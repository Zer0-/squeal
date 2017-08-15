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
  , RankNTypes
  , ScopedTypeVariables
  , TypeApplications
  , TypeFamilies
  , TypeOperators
  , UndecidableInstances
#-}

module Squeal.PostgreSQL.PQ where

import Control.Exception.Lifted
import Control.Monad.Base
import Control.Monad.Except
import Control.Monad.Trans.Control
import Data.ByteString (ByteString)
import Data.Function ((&))
import Generics.SOP
import GHC.Exts hiding (fromList)
import GHC.TypeLits

import qualified Database.PostgreSQL.LibPQ as LibPQ

import Squeal.PostgreSQL.Binary
import Squeal.PostgreSQL.Statement
import Squeal.PostgreSQL.Schema

newtype Connection (schema :: [(Symbol,[(Symbol,ColumnType)])]) =
  Connection { unConnection :: LibPQ.Connection }

newtype PQ
  (schema0 :: [(Symbol,[(Symbol,ColumnType)])])
  (schema1 :: [(Symbol,[(Symbol,ColumnType)])])
  (m :: * -> *)
  (x :: *) =
    PQ { unPQ :: Connection schema0 -> m (x, Connection schema1) }
    deriving Functor

evalPQ :: Functor m => Connection schema0 -> PQ schema0 schema1 m x -> m x
evalPQ conn (PQ pq) = fmap fst $ pq conn

runPQ
  :: Functor m
  => Connection schema0
  -> PQ schema0 schema1 m x
  -> m (Connection schema1)
runPQ conn (PQ pq) = fmap snd $ pq conn

pqAp
  :: Monad m
  => PQ schema0 schema1 m (x -> y)
  -> PQ schema1 schema2 m x
  -> PQ schema0 schema2 m y
pqAp (PQ f) (PQ x) = PQ $ \ conn -> do
  (f', conn') <- f conn
  (x', conn'') <- x conn'
  return (f' x', conn'')

pqBind
  :: Monad m
  => (x -> PQ schema1 schema2 m y)
  -> PQ schema0 schema1 m x
  -> PQ schema0 schema2 m y
pqBind f (PQ x) = PQ $ \ conn -> do
  (x', conn') <- x conn
  unPQ (f x') conn'

pqThen
  :: Monad m
  => PQ schema1 schema2 m y
  -> PQ schema0 schema1 m x
  -> PQ schema0 schema2 m y
pqThen pq2 pq1 = pq1 & pqBind (\ _ -> pq2)

pqExec
  :: MonadBase IO io
  => Definition schema0 schema1
  -> PQ schema0 schema1 io (Maybe (Result '[]))
pqExec (UnsafeDefinition q) = PQ $ \ (Connection conn) -> do
  result <- liftBase $ LibPQ.exec conn q
  return (Result <$> result, Connection conn)

pqThenExec
  :: MonadBase IO io
  => Definition schema1 schema2
  -> PQ schema0 schema1 io x
  -> PQ schema0 schema2 io (Maybe (Result '[]))
pqThenExec = pqThen . pqExec

class Monad m => MonadPQ schema m | m -> schema where

  pqExecParams
    :: ToParams x params
    => Manipulation schema params ys -> x -> m (Maybe (Result ys))
  default pqExecParams
    :: (MonadTrans t, MonadPQ schema m1, m ~ t m1)
    => ToParams x params
    => Manipulation schema params ys -> x -> m (Maybe (Result ys))
  pqExecParams manipulation params = lift $ pqExecParams manipulation params

  pqExecNil :: Manipulation schema '[] ys -> m (Maybe (Result ys))
  pqExecNil statement = pqExecParams statement ()

instance MonadBase IO io => MonadPQ schema (PQ schema schema io) where

  pqExecParams (UnsafeManipulation q :: Manipulation schema ps ys) (params :: x) =
    PQ $ \ (Connection conn) -> do
      let
        toParam' bytes = (LibPQ.invalidOid,bytes,LibPQ.Binary)
        params' = fmap (fmap toParam') (hcollapse (toParams @x @ps params))
      result <- liftBase $ LibPQ.execParams conn q params' LibPQ.Binary
      return (Result <$> result, Connection conn)

instance Monad m => Applicative (PQ schema schema m) where
  pure x = PQ $ \ conn -> pure (x, conn)
  (<*>) = pqAp

instance Monad m => Monad (PQ schema schema m) where
  return = pure
  (>>=) = flip pqBind

instance MonadTrans (PQ schema schema) where
  lift m = PQ $ \ conn -> do
    x <- m
    return (x, conn)

instance MonadBase b m => MonadBase b (PQ schema schema m) where
  liftBase = lift . liftBase

type PQRun schema =
  forall m x. Monad m => PQ schema schema m x -> m (x, Connection schema)

pqliftWith :: Functor m => (PQRun schema -> m a) -> PQ schema schema m a
pqliftWith f = PQ $ \ conn ->
  fmap (\ x -> (x, conn)) (f $ \ pq -> unPQ pq conn)

instance MonadBaseControl b m => MonadBaseControl b (PQ schema schema m) where
  type StM (PQ schema schema m) x = StM m (x, Connection schema)
  liftBaseWith f =
    pqliftWith $ \ run -> liftBaseWith $ \ runInBase -> f $ runInBase . run
  restoreM = PQ . const . restoreM

connectdb :: MonadBase IO io => ByteString -> io (Connection schema)
connectdb = fmap Connection . liftBase . LibPQ.connectdb

finish :: MonadBase IO io => Connection schema -> io ()
finish = liftBase . LibPQ.finish . unConnection

withConnection
  :: MonadBaseControl IO io
  => ByteString
  -> (Connection schema -> io x)
  -> io x
withConnection connString action =
  bracket (connectdb connString) finish action

newtype Result (xs :: [(Symbol,ColumnType)])
  = Result { unResult :: LibPQ.Result }

newtype RowNumber = RowNumber { unRowNumber :: LibPQ.Row }

newtype ColumnNumber n cs c =
  UnsafeColumnNumber { getColumnNumber :: LibPQ.Column }

class KnownNat n => HasColumnNumber n columns column
  | n columns -> column where
  columnNumber :: ColumnNumber n columns column
  columnNumber =
    UnsafeColumnNumber . fromIntegral $ natVal' (proxy# :: Proxy# n)
instance {-# OVERLAPPING #-} HasColumnNumber 0 (column1:columns) column1
instance {-# OVERLAPPABLE #-}
  (KnownNat n, HasColumnNumber (n-1) columns column)
    => HasColumnNumber n (column' : columns) column

getValue
  :: (FromColumnValue colty y, MonadBase IO io)
  => RowNumber
  -> ColumnNumber n columns colty
  -> Result columns
  -> io y
getValue
  (RowNumber r)
  (UnsafeColumnNumber c :: ColumnNumber n columns colty)
  (Result result)
   = fromColumnValue @colty . K <$>
    liftBase (LibPQ.getvalue result r c)

getRow
  :: (FromRow columns y, MonadBase IO io)
  => RowNumber -> Result columns -> io y
getRow (RowNumber r) (Result result :: Result columns) = do
  let len = fromIntegral (lengthSList (Proxy @columns))
  row' <- traverse (liftBase . LibPQ.getvalue result r) [0 .. len - 1]
  case fromList row' of
    Nothing -> error "getRow: found unexpected length"
    Just row -> return $ fromRow @columns row