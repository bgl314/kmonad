{-# LANGUAGE CPP #-}
{-# LANGUAGE ExistentialQuantification #-}
{-
Place the following here:

- Types
- Classes
- Instances
- Smart constructors
- Basic lenses

-}


-- |

module System.Keyboard.Types where

import System.Keyboard.Prelude

import Data.Bits
import Foreign.Storable

import GHC.Enum (Enum(..))

{- NOTE: Basic -}

-- Text disambiguations
type Description = Text
type Name        = Text
type Keyname     = Text

{- NOTE: Generic ---------------------------------------------------------------
The central aim of this library is to provide OS-agnostic representation and
semantics for keyboard operations, across Windows, Mac, and Linux. All 3
operating systems function differently in how they represent standard events,
and how they represent keys.

The following section contains the generic representation that lies at the core
of this library:

We represent only presses and releases (not Linux's repeat events).

We represent keycodes as Word64's, since out of the 3 OSes the largest type is
Mac's (Word32, Word32), which we can fit into a Word64.

OS-specific types are in their own sections below.
-------------------------------------------------------------------------------}


{- NOTE: Switch ---------------------------------------------------------------}

-- | The two different transitions a 2-state machine (a key) can make.
data Switch
  = Press
  | Release
  deriving (Eq, Ord, Show)
makeClassyPrisms ''Switch

_IsPress :: HasSwitch a => Getter a Bool
_IsPress = switch . to (Press ==)



-- | A class describing how to get at a 'Switch' inside some structure
class HasSwitch a where switch :: Lens' a Switch

instance HasSwitch Switch where switch = id

instance Hashable Switch where
  hashWithSalt s = hashWithSalt s . (Press ==)

{- NOTE: Keycode --------------------------------------------------------------}

-- | The 'Keycode' type
newtype Keycode = Keycode { _uKeycode :: Word64 }
  deriving (Eq, Ord, Enum, Num, Hashable)
makeLenses ''Keycode

instance Show Keycode where show = showHex . _uKeycode

-- | A class describing how to get at a 'Keycode' inside some structure
class HasKeycode a where keycode :: Lens' a Keycode

instance HasKeycode Keycode where keycode = id

-- | A class used to describe how to convert between things and 'Keycode's
--
-- Note that not all instances of this class follow the iso-laws completely. The
-- keycode types for linux and windows are smaller than the underlying type of
-- 'Keycode'.
--
-- As long as you map between 1 OSes Keycode and the generic Keycode the iso
-- laws are followed, but if you start converting between OS representations,
-- this will break.
--
-- So:
-- yes: LinKeycode -> Keycode -> LinKeycode
-- no:  MacKeycode -> Keycode -> LinKeycode -> Keycode -> MacKeycode
--
-- This Iso' exists to make working inside 1 OS easy. It is not meant to support
-- intelligent conversion or generalization between OSes.
class IsKeycode a where _Keycode :: Iso' a Keycode
instance IsKeycode Keycode where _Keycode = id

{- NOTE: KeySwitch ------------------------------------------------------------}

-- | The 'KeySwitch' type describing a state-change of some key
newtype KeySwitch = KeySwitch { _uKeySwitch :: (Switch, Keycode) }
  deriving (Eq, Ord, Hashable, Show)
makeLenses ''KeySwitch

instance HasSwitch  KeySwitch where switch  = uKeySwitch . _1
instance HasKeycode KeySwitch where keycode = uKeySwitch . _2

-- | Constructor for 'KeySwitch' data
mkKeySwitch :: Switch -> Keycode -> KeySwitch
mkKeySwitch = curry KeySwitch

-- | A class used to describe how to convert between things and 'KeySwitch'es
--
-- Note that not all instances of this class follow the iso-laws completely.
-- LinKeyEvents, for example, contain timing information that is discarded.
-- However, we never use the timing information anywhere. So for all
-- semantically relevant information, the iso-laws are followed.
class IsKeySwitch a where _KeySwitch :: Iso' a KeySwitch
instance IsKeySwitch KeySwitch where _KeySwitch = id

{- NOTE: Linux -----------------------------------------------------------------

Linux signals events using a packet of data containing 5 values (see LinRawEvent
for documentation). In addition to the keycode-encoding, linux key event
handling differs from mac and windows in the following:

1. It includes a timestamp

We deal with this by representing this field in the record, but always setting
it to 0 for our internal representations. So for our generic encoding, it is
meaningless. We do however fill these fields with the correct data when we read
events from the kernel, in case someone wants to build on top of this in their
own app. To provide the ability to read these times, and to set times on
user-generated linux events we provide a lens into these fields.

This way we can forget about timing for our own uses, but allow people to still
access timing information if they want to use this library for their own
purposes.

2. It allows for repeat events in addition to press and release events

We deal with this by creating a 2nd type of event 'LinRepeatEvent', in addition
to 'LinKeyEvent', that represents repeat events. We don't deal with these any
further in our generic representation, but provide a KeyIO configuration setting
that allows the relaying or ignoring of repeat events.

3. It uses a sync event to signal driver-updates to the kernel

We deal with this by creating a 3d type of event 'LinSyncEvent'. We don't deal
with these any further in our generic representation, but provide a KeyIO
configuration setting that on the reader toggles the relaying of sync events,
and on the writer allows either manual or automatic syncing.

For more information on the the linux event representations, see:
https://www.kernel.org/doc/Documentation/input/input.txt

Linux event packet:
- s    : system-time seconds
- ns   : system-time nanoseconds
- type : 1 for key-event, 0 for sync event
- code : keycode
- val  : 0 for release, 1 for press, 2 for repeat, (and 0 again for sync)

-------------------------------------------------------------------------------}

{- NOTE: LinKeycode -----------------------------------------------------------}

-- | A keycode by/for Linux
newtype LinKeycode = LinKeycode { _uLinKeycode :: Word16 }
  deriving (Eq, Ord, Enum, Hashable)
makeLenses ''LinKeycode

instance Show LinKeycode where show = showHex . _uLinKeycode

instance IsKeycode LinKeycode where
  _Keycode = iso (Keycode . fi . _uLinKeycode) (LinKeycode . fi . _uKeycode)


{- NOTE: LinPacket ------------------------------------------------------------}

-- | A record representing the structure of a Linux input event.
--
-- This packet is constructed in such a way that it can be directly serialized
-- and deserialized with the kernel interface. It should not be used directly,
-- however, since both sync events and key events are represented by these
-- packets.
data LinPacket = LinPacket
  { _linS    :: !Word64  -- ^ The seconds component of system time
  , _linNS   :: !Word64  -- ^ The nanoseconds component of system time
  , _linType :: !Word16  -- ^ 0:sync, 1:key-event
  , _linCode :: !Word16  -- ^ The keycode indentifier of the key
  , _linVal  :: !Int32   -- ^ 0:release, 1:press, 2:release
  } deriving (Show, Eq)
makeClassy ''LinPacket

class IsLinPacket a where _LinPacket :: Iso' a LinPacket
instance IsLinPacket LinPacket where _LinPacket = id

-- | A packet of serializeable data representing a linux press or release event
newtype LinKeyEvent = LinKeyEvent { _uLinKeyEvent :: LinPacket }
  deriving (Show)
makeLenses ''LinKeyEvent

instance HasLinPacket LinKeyEvent where linPacket = uLinKeyEvent

instance HasSwitch LinKeyEvent where
  switch = lens
    (\l   -> bool Release Press (l^.linVal == 1))
    (\l s -> l & linVal .~ (if s^._IsPress then 1 else 0))

instance HasKeycode LinKeyEvent where
  keycode = lens
    (\l   -> l^.linCode.to (Keycode . fi))
    (\l c -> l & linCode .~ c^.re _Keycode.uLinKeycode)

instance IsKeySwitch LinKeyEvent where
  _KeySwitch = iso
    (\l -> mkKeySwitch   (l^.switch) (l^.keycode))
    (\s -> let c_ = s^.keycode.re _Keycode.to _uLinKeycode
               v_ = if s^._IsPress then 1 else 0
           in LinKeyEvent $ LinPacket 0 0 1 c_ v_)

-- | A packet of serializeable data representing a linux repeat event
newtype LinRepeatEvent = LinRepeatEvent { _uLinRepeatEvent :: LinPacket }
  deriving (Show, Eq)
makeLenses ''LinRepeatEvent

instance HasLinPacket LinRepeatEvent where linPacket = uLinRepeatEvent

-- | Smart constructor for 'LinRepeatEvent's
mkLinRepeatEvent :: LinKeycode -> LinRepeatEvent
mkLinRepeatEvent c = LinRepeatEvent $ LinPacket 0 0 1 (_uLinKeycode c) 2

-- | A packet of serializeable data representing a linux sync event
newtype LinSyncEvent = LinSyncEvent { _uLinSyncEvent :: LinPacket }
  deriving (Show, Eq)
makeLenses ''LinSyncEvent

instance HasLinPacket LinSyncEvent where linPacket = uLinSyncEvent

-- | A packet of serializeable data representing a linux sync event
newtype LinScanEvent = LinScanEvent { _uLinScanEvent :: LinPacket }
  deriving (Show, Eq)
makeLenses ''LinScanEvent

instance HasLinPacket LinScanEvent where linPacket = uLinScanEvent

-- | Smart constructor for 'LinSyncEvent's
mkLinSyncEvent :: LinSyncEvent
mkLinSyncEvent = LinSyncEvent $ LinPacket 0 0 0 0 0

{- NOTE: low-level API --------------------------------------------------------}

-- | Sum type of all events handled by the low-level Linux KeyIO API
data LowLinEvent
  = LowLinKeyEvent    LinKeyEvent
  | LowLinRepeatEvent LinRepeatEvent
  | LowLinScanEvent   LinScanEvent
  | LowLinSyncEvent   LinSyncEvent
  deriving (Show)

-- | Direct conversion between 'LowLinEvent' and 'LinPacket' for all possible
-- packets that we support.
instance IsLinPacket LowLinEvent where
  _LinPacket = iso to_ from_
    where
      to_ (LowLinKeyEvent e)    = e^.linPacket
      to_ (LowLinRepeatEvent e) = e^.linPacket
      to_ (LowLinSyncEvent e)   = e^.linPacket
      to_ (LowLinScanEvent e)   = e^.linPacket
      from_ p = if
        | p^.linType == 0 -> LowLinSyncEvent   . LinSyncEvent   $ p
        | p^.linVal  == 2 -> LowLinRepeatEvent . LinRepeatEvent $ p
        | p^.linType == 4 -> LowLinScanEvent   . LinScanEvent   $ p
        | otherwise       -> LowLinKeyEvent    . LinKeyEvent    $ p

instance HasLinPacket LowLinEvent where
  linPacket = _LinPacket

{- NOTE: Windows ---------------------------------------------------------------
The windows implementation is much simpler than the Linux implementation,
because we do not distinguish between Press/Release/Repeat/Sync events. We only
have key presses and releases, so we do not have to represent some intermediate
@Low@ type, all 'WinPacket's are automatically 'KeySwitch'es.
-------------------------------------------------------------------------------}

-- | In Windows we use 'Word32', the windows-native keycode type
newtype WinKeycode = WinKeycode { _uWinKeycode :: Word32 }
  deriving (Eq, Ord, Enum, Hashable)
makeLenses ''WinKeycode

instance IsKeycode WinKeycode where
  _Keycode = iso (Keycode . fi . _uWinKeycode) (WinKeycode . fi . _uKeycode)

instance Show WinKeycode where show = showHex . _uWinKeycode

data WinPacket = WinPacket
  { _winVal  :: Word8  -- ^ 0:press, 1:release
  , _winCode :: Word32 -- ^ The keycode identifier of the key
  } deriving (Show, Eq)
makeClassy ''WinPacket

-- | Storable instance for WinPacket because we use it for IO
instance Storable WinPacket where
  alignment _ = 4 -- lowest common denominator of: 1 4
  sizeOf    _ = 8 -- (1 + 3-padding) + 4
  peek p = WinPacket <$> peekByteOff p 0 <*> peekByteOff p 4
  poke p (WinPacket s c) = pokeByteOff p 0 s *> pokeByteOff p 4 c

instance HasSwitch WinPacket where
  switch = lens
    (\w   -> bool Press Release (w^.winVal == 0))
    (\w s -> w & winVal .~ (if s^._IsPress then 0 else 1))

instance HasKeycode WinPacket where
  keycode = lens
    (\w   -> w^.winCode.to (Keycode . fi))
    (\w c -> w & winCode .~ (c^.re _Keycode.uWinKeycode))

instance IsKeySwitch WinPacket where
  _KeySwitch = iso
    (\w -> mkKeySwitch (w^.switch) (w^.keycode))
    (\s -> let v_ = if s^._IsPress then 0 else 1
               c_ = s^.keycode.re _Keycode.to _uWinKeycode
           in WinPacket v_ c_)

{- NOTE: Mac -------------------------------------------------------------------
-------------------------------------------------------------------------------}


{- NOTE: MacKeycode -----------------------------------------------------------}

-- TODO: Write a better Show for mac
newtype MacKeycode = MacKeycode { _uMacKeycode :: (Word32, Word32) }
  deriving (Eq, Ord, Show)
makeLenses ''MacKeycode

instance Hashable MacKeycode where
  hashWithSalt s = hashWithSalt s . view _Keycode

instance IsKeycode MacKeycode where
  _Keycode = iso
    (Keycode    . (\(a, b) -> shiftL (fi a) 32 + (fi b)) . _uMacKeycode)
    (MacKeycode . (\c      -> (fi $ shiftR c 32, fi c))  . _uKeycode)

instance Enum MacKeycode where
  toEnum   = view (from _Keycode) . toEnum
  fromEnum = fromEnum . view _Keycode

{- NOTE: MacPacket ------------------------------------------------------------}
data MacPacket = MacPacket
  { _macVal  :: Word64
  , _macCode :: (Word32, Word32)
  } deriving (Eq, Ord, Show)

instance Storable MacPacket where
  alignment _ = 4
  sizeOf    _ = 16
  peek ptr = do
    s <- peekByteOff ptr 0
    p <- peekByteOff ptr 8
    u <- peekByteOff ptr 12
    return $ MacPacket s (p, u)
  poke ptr (MacPacket s (p, u)) = do
    pokeByteOff ptr 0 s
    pokeByteOff ptr 8 p
    pokeByteOff ptr 12 u

{- NOTE: OS-support types ------------------------------------------------------
Much of this library is OS-specific code. We would like to provide an
OS-agnostic interface to this code. That is why we gather the different
configurations into the following sum-types.
-------------------------------------------------------------------------------}

{- NOTE: Informative OS error -------------------------------------------------}

data OS = Linux | Mac | Windows deriving (Eq, Ord, Show)

-- | The OS under which we are compiled
currentOS :: OS
#if defined linux_HOST_OS
currentOS = Linux
#elif defined darwin_HOST_OS
currentOS = Mac
#elif defined mingw32_HOST_OS
currentOS = Windows
#endif

data OSException = FFIWrongOS Description OS
  deriving Show

instance Exception OSException where
  displayException (FFIWrongOS action target) = unpack . mconcat $
    [ "Tried to '", action, "' on <", tshow currentOS
    , ">. But this is only supported on <", tshow target, ">" ]

{- NOTE: Config sumtypes ------------------------------------------------------}


-- | Configuration for (k/d)ext keysink in Mac
--
-- Note that Mac has no configuration options,, but we maintain this type for
-- symmetry and ease of future extension.
data ExtCfg = ExtCfg deriving (Eq, Show)

instance Default ExtCfg where def = ExtCfg

{- NOTE: General output types -------------------------------------------------}

-- | A token hiding all the functionality required to put keys into the OS
data KeyO = KeyO
  { _emitKey   :: KeySwitch -> IO () -- ^ How to emit a switch event to OS
  , _repeatKey :: Keycode   -> IO () -- ^ How to signal OS to repeat a keyswitch
  }
makeLenses ''KeyO

-- | A class generalizing the concept of some config that allows opening a key sink
class CanOpenKeyO cfg where
  withKeyO :: forall m a. MonadUnliftIO m => cfg -> (KeyO -> m a) -> m a

-- | An existential wrapper hiding the concrete type of the output configuration
-- NOTE: do I need this?
data KeyOCfg = forall cfg. CanOpenKeyO cfg => KeyOCfg cfg
-- | How to auto-unwrap the wrapper
instance CanOpenKeyO KeyOCfg where withKeyO (KeyOCfg cfg) = withKeyO cfg

class HasKeyO env where keyO :: Getter env KeyO

type CanKeyO m env = (MonadIO m, MonadReader env m, HasKeyO env)



{- NOTE: General input types --------------------------------------------------}

-- | A token hiding all the functionality required to get keys from the OS
newtype KeyI = KeyI { _uKeyI :: IO KeySwitch }
makeLenses ''KeyI

class CanOpenKeyI cfg where
  withKeyI :: forall m a. MonadUnliftIO m => cfg -> (KeyI -> m a) -> m a

class HasKeyI env where keyI :: Getter env KeyI
instance HasKeyI KeyI where keyI = id


{- NOTE: Names -----------------------------------------------------------------

problem statement: we need:
- to read in keys by their name from config files
- display keys by their name during logging
- the keycode-name relationship is different per OS
- it is hard to figure out the keycodes for certain keys for certain OSes*
- this mapping needs to be easy to extend and modify for dev-reasons and locales

*: e.g.:
- what is Windows representation of pushing the Mac 'Fn' key? I don't know how
  to google this, and I don't have a Mac with windows on it.

solution:
- we define a collection of 'KeyCongruence's, that define standard names for
  semantic buttons like 'the `a` key'.
- create a table of these entries and use that for parsing, pretty-printing, and
  maybe between-OS-transformation (possible, but why?)

let's not worry about:
- speed: this is something that happens rarely and pre-app-loop.


--------------------------------------------------------------------------------

Now, let's think about the structure of the data:
- the keyname *must be unique*
- the description is only used for documentation and logging
- the codes can have duplicates and missing values*

*: e.g.:
- windows doesn't distinguish between `ret` and `kpret`, so the semantic buttons
  'return' and 'keypad return' map to the same keycode in Windows.

--------------------------------------------------------------------------------

Actually... we could move this decision to the edge by making IO:

data Keycode = Literal Word64 | Named NamedKey

sendEvent ::  Keycode -> IO ()

That way we can always invent a `winSendEvent (Named "kpret")` later without
having to touch any of the other code.


-------------------------------------------------------------------------------}

-- | A record describing
data KeyCongruence = KeyCongruence
  { _keyName        :: Keyname
  , _keyDescription :: Text
  , _keyLin         :: Maybe LinKeycode
  , _keyMac         :: Maybe MacKeycode
  , _keyWin         :: Maybe WinKeycode
  } deriving (Eq, Show)
makeLenses ''KeyCongruence

newtype KeyTable = KeyTable { _uKeyTable :: [KeyCongruence] }
  deriving (Show, Eq)

-- | Value indicating which key-locale to use.
data KeyLocale = EnUS | CustomLocale FilePath deriving (Eq, Show)

{- NOTE: Key-repeat types ------------------------------------------------------
-------------------------------------------------------------------------------}

-- | Settings that describe how to trigger key-repeat events
data KeyRepeatCfg = KeyRepeatCfg
  { _repeatDelay   :: Int  -- ^ How many milliseconds before we start repeating
  , _repeatRate    :: Int  -- ^ How many milliseconds between repeat events
  , _repeatEnabled :: Bool -- ^ Can be used to toggle repeating on and off
  } deriving (Eq, Show)
makeClassy ''KeyRepeatCfg
-- NOTE: I used to work with 'Maybe KeyRepeatCfg' without the 'repeatEnabled'
-- field, but that made the Default instance finicky. This is slightly less
-- beautiful, but easier to work with.

instance Default KeyRepeatCfg where
#if defined mingw32_HOST_OS
  -- NOTE: On Windows we *need* to provide key-repeat, because it doesn't happen
  -- automatically. On Linux's virtual console it doesn't either, but that is an
  -- edgecase that we should leave to users to configure.
  def = KeyRepeatCfg 300 100 True
#else
  def = KeyRepeatCfg 300 100 False
#endif

-- | Runtime environment for the key-repeat process
data KeyRepeatEnv = KeyRepeatEnv
  { _repeatCfg :: KeyRepeatCfg
  , _current   :: MVar (Maybe (Async ()))
  , _krKeyO      :: KeyO
  }
makeLenses ''KeyRepeatEnv

instance HasKeyO KeyRepeatEnv where keyO = krKeyO


{- NOTE: IO-types --------------------------------------------------------------
-------------------------------------------------------------------------------}

-- | A token containing all the functionality required to key keys from the OS
newtype KeyGetter = KeyGetter { _uKeyGetter :: IO KeySwitch }
makeLenses ''KeyGetter

-- class HasKeyGetter a where keyGetter :: Getter a KeyGetter
-- class HasKeyPutter a where keyPutter :: Getter a KeyO

  -- , _repeatCfg :: Maybe KeyRepeatCfg -- ^ Key-repeat settings

-- | The configuration options that can be passed to IOKitCfg.
newtype IOKitCfg = IOKitCfg
  { _productStr :: Maybe Text -- ^ A string to restrict which keyboard to capture
  } deriving Show
makeClassy ''IOKitCfg

instance Default IOKitCfg where def = IOKitCfg Nothing