module Orange.Types.DCache where

import Clash.Prelude
import qualified Orange.Types.Gpr as GprT
import qualified Orange.Types.Pipe as PipeT
import qualified Orange.Types.Fetch as FetchT

data WriteEnable = CanWrite | NoWrite
    deriving (Generic, NFDataX)
type WriteMask = BitVector 4
data Selector = SelByte0 | SelByte1 | SelByte2 | SelByte3 | SelHalf0 | SelHalf1 | SelWord
    deriving (Generic, NFDataX)
data SignExtension = UseZeroExtend | UseSignExtend
    deriving (Generic, NFDataX)

data Access = WriteAccess (GprT.RegValue, WriteMask) | ReadAccess (GprT.RegIndex, Selector, SignExtension)
    deriving (Generic, NFDataX)

type MemAddr = GprT.RegValue
type MemData = GprT.RegValue

class DCacheImpl a where
    issueAccess :: HiddenClockResetEnable dom
                => a
                -> Signal dom (Maybe (FetchT.PC, MemAddr, Access))
                -> Signal dom WriteEnable
                -> (Signal dom PipeT.Commit, Signal dom WriteEnable)