{-# OPTIONS -fno-warn-orphans #-}
{-# LANGUAGE FlexibleContexts, FlexibleInstances #-}
-- | Basic type classes for game actions.
-- This module should not be imported anywhere except in 'Action'
-- and 'TypeAction'.
module Game.LambdaHack.ActionClass where

import Control.Monad.Reader.Class
import Control.Monad.Writer.Strict (WriterT (WriterT), runWriterT, lift)
import Data.Monoid

import Game.LambdaHack.Action.Frontend
import Game.LambdaHack.Binding
import Game.LambdaHack.Config
import Game.LambdaHack.Msg
import Game.LambdaHack.State

-- | The information that is constant across a client playing session,
-- including many consecutive games in a single session,
-- but is completely disregarded and reset when a new playing session starts.
data Session = Session
  { sfs       :: !FrontendSession  -- ^ frontend session information
  , sbinding  :: !Binding          -- ^ binding of keys to commands
  , sconfigUI :: !ConfigUI         -- ^ the UI config for this session
  }

-- | The bottom of the action monads class semilattice.
class (Monad m, Functor m, Show (m ())) => MonadActionRoot m where
  -- Set the current exception handler. First argument is the handler,
  -- second is the computation the handler scopes over.
  tryWith     :: (Msg -> m a) -> m a -> m a
  -- Abort with the given message.
  abortWith   :: Msg -> m a

instance (Monoid a, MonadActionRoot m) => MonadActionRoot (WriterT a m) where
  tryWith exc m =
    WriterT $ tryWith (\msg -> runWriterT (exc msg)) (runWriterT m)
  abortWith   = lift . abortWith

instance MonadActionRoot m => Show (WriterT a m b) where
  show _ = "an action"

class (MonadReader Pers m, MonadActionRoot m) => MonadServerRO m where
  getGlobal   :: m State
  getsGlobal  :: (State -> a) -> m a
  getServer   :: m StateServer
  getsServer  :: (StateServer -> a) -> m a

instance (Monoid a, MonadServerRO m) => MonadServerRO (WriterT a m) where
  getGlobal   = lift getGlobal
  getsGlobal  = lift . getsGlobal
  getServer   = lift getServer
  getsServer  = lift . getsServer

class MonadActionRoot m => MonadClientRO m where
  getsSession :: (Session -> a) -> m a
  getClient   :: m StateClient
  getsClient  :: (StateClient -> a) -> m a
  getLocal    :: m State
  getsLocal   :: (State -> a) -> m a

instance (Monoid a, MonadClientRO m) => MonadClientRO (WriterT a m) where
  getsSession = lift . getsSession
  getClient   = lift getClient
  getsClient  = lift . getsClient
  getLocal    = lift getLocal
  getsLocal   = lift . getsLocal

class MonadServerRO m => MonadActionRO m where
  getDict     :: m ClientDict
  getsDict    :: (ClientDict -> a) -> m a

instance (Monoid a, MonadActionRO m) => MonadActionRO (WriterT a m) where
  getDict     = lift getDict
  getsDict    = lift . getsDict

class MonadActionRoot m => MonadActionIO m where
  -- We do not provide a MonadIO instance, so that outside of Action/
  -- nobody can subvert the action monads by invoking arbitrary IO.
  liftIO :: IO a -> m a

instance (Monoid a, MonadActionIO m) => MonadActionIO (WriterT a m) where
  liftIO = lift . liftIO

class (MonadActionIO m, MonadServerRO m) => MonadServer m where
  modifyGlobal :: (State -> State) -> m ()
  putGlobal    :: State -> m ()
  modifyServer :: (StateServer -> StateServer) -> m ()
  putServer    :: StateServer -> m ()

instance (Monoid a, MonadServer m) => MonadServer (WriterT a m) where
  modifyGlobal = lift . modifyGlobal
  putGlobal    = lift . putGlobal
  modifyServer = lift . modifyServer
  putServer    = lift . putServer

class (MonadActionIO m, MonadClientRO m) => MonadClient m where
  modifyClient :: (StateClient -> StateClient) -> m ()
  putClient    :: StateClient -> m ()
  modifyLocal  :: (State -> State) -> m ()
  putLocal     :: State -> m ()

instance (Monoid a, MonadClient m) => MonadClient (WriterT a m) where
  modifyClient = lift . modifyClient
  putClient    = lift . putClient
  modifyLocal  = lift . modifyLocal
  putLocal     = lift . putLocal

class (MonadActionIO m, MonadActionRO m, MonadServer m) => MonadAction m where
  modifyDict   :: (ClientDict -> ClientDict) -> m ()
  putDict      :: ClientDict -> m ()

instance (Monoid a, MonadAction m) => MonadAction (WriterT a m) where
  modifyDict   = lift . modifyDict
  putDict      = lift . putDict
