module Violet.IP.StaticDM where

import Clash.Prelude

import Violet.Types.DCache
import qualified Debug.Trace
import qualified Violet.Types.Gpr as GprT
import qualified Violet.Types.Issue as IssueT
import qualified Violet.Types.Fetch as FetchT
import qualified Violet.Types.Pipe as PipeT

type RamBits = 14
type ReadPort = MemAddr
type WritePort = Maybe (MemAddr, MemData, WriteMask)

type ReadMini = (Selector, SignExtension)

data StaticDM = StaticDM
    deriving (Generic, NFDataX)

instance DCacheImpl StaticDM where
    issueAccess _ req1 req2 weCommit = (commitPort1, commitPort2, weReq)
        where
            -- stage 1
            readPort1 = fmap transformReadPort req1
            readPort2 = fmap transformReadPort req2
            writePort = fmap transformWritePort req1

            -- stage 2
            rawReadResult1 = mkRam readPort1 writeCommitPort
            rawReadResult2 = mkRam readPort2 writeCommitPort
            readMini1 = register Nothing (fmap transformReadMini req1)
            readMini2 = register Nothing (fmap transformReadMini req2)
            delayedPC1 = register 0 (fmap transformPC req1)
            delayedPC2 = register 0 (fmap transformPC req2)
            delayedRd1 = register 0 (fmap transformRd req1)
            delayedRd2 = register 0 (fmap transformRd req2)
            delayedReadPort1 = register 0 readPort1
            delayedReadPort2 = register 0 readPort2
            forwardedReadResult1 = writeForward delayedReadPort1 rawReadResult1 writePortFinal
            forwardedReadResult2 = writeForward delayedReadPort2 rawReadResult2 writePortFinal
            readResult1 = fmap transformReadResult $ bundle (forwardedReadResult1, readMini1)
            readResult2 = fmap transformReadResult $ bundle (forwardedReadResult2, readMini2)
            commitPort1 = fmap transformCommitPort $ bundle (delayedPC1, delayedRd1, readResult1, writePortD1, delayedReadPort1)
            commitPort2 = fmap transformCommitPort $ bundle (delayedPC2, delayedRd2, readResult2, pure Nothing, delayedReadPort2)
            writePortD1 = register Nothing writePort

            -- Commit stage doesn't handle DCache exception and write disable in the same cycle.
            -- So we need to handle it here.
            writePortD1Gated = fmap f $ bundle (writePortD1, commitPort1)
                where
                    f (wp, cp) = case cp of
                        PipeT.Exc _ -> Nothing
                        _ -> wp
            
            -- stage 3
            writePortFinal = register Nothing writePortD1Gated
            weReq = register NoWrite (fmap transformWeReq writePortD1Gated)
            writeCommitPort = fmap transformWriteCommit $ bundle (writePortFinal, weCommit)

            transformReadPort req = case req of
                Just (_, addr, ReadAccess (_, _, _)) -> addr
                _ -> 0
            transformWritePort req = case req of
                Just (_, addr, WriteAccess (v, mask)) -> Just (addr, v, mask)
                _ -> Nothing
            transformReadMini req = case req of
                Just (_, _, ReadAccess (_, sel, ext)) -> Just (sel, ext)
                _ -> Nothing
            transformPC req = case req of
                Just (pc, _, _) -> pc
                _ -> 0
            transformRd req = case req of
                Just (_, _, ReadAccess (i, _, _)) -> i
                _ -> 0
            transformReadResult :: ((BitVector 8, BitVector 8, BitVector 8, BitVector 8), Maybe ReadMini) -> Maybe (BitVector 32)
            transformReadResult (_, Nothing) = Nothing
            transformReadResult ((ram3, ram2, ram1, ram0), Just (sel, signExt)) = Just r
                where
                    ext8 = case signExt of
                        UseZeroExtend -> zeroExtend
                        UseSignExtend -> signExtend
                    ext16 = case signExt of
                        UseZeroExtend -> zeroExtend
                        UseSignExtend -> signExtend
                    r = case sel of
                        SelByte0 -> ext8 ram0
                        SelByte1 -> ext8 ram1
                        SelByte2 -> ext8 ram2
                        SelByte3 -> ext8 ram3
                        SelHalf0 -> ext16 (ram1 ++# ram0)
                        SelHalf1 -> ext16 (ram3 ++# ram2)
                        SelWord -> ram3 ++# ram2 ++# ram1 ++# ram0
            transformCommitPort (pc, rd, readRes, writePort, readPort) = case (readRes, writePort, readPort) of
                (_, Just (waddr, wdata, _), _) | isIoAddr waddr -> PipeT.Exc (pc, PipeT.EarlyExc $ PipeT.IOMemWrite pc waddr wdata)
                (_, _, raddr) | isIoAddr raddr -> PipeT.Exc (pc, PipeT.EarlyExc $ PipeT.IOMemRead pc rd raddr)
                (Just x, _, _) -> PipeT.Ok (pc, Just (PipeT.GPR rd x), Nothing)
                (_, Just _, _) -> PipeT.Ok (pc, Nothing, Nothing)
                _ -> PipeT.Bubble
            transformWriteCommit (writePort, weCommit) = case weCommit of
                CanWrite -> writePort
                NoWrite -> Nothing
            transformWeReq (Just _) = CanWrite
            transformWeReq Nothing = NoWrite

writeForward :: HiddenClockResetEnable dom
             => Signal dom ReadPort
             -> Signal dom (BitVector 8, BitVector 8, BitVector 8, BitVector 8)
             -> Signal dom WritePort
             -> Signal dom (BitVector 8, BitVector 8, BitVector 8, BitVector 8)
writeForward rp input wp = fmap forwardOne $ bundle (wp, rp, input)
    where
        forwardOne (Nothing, rp, x) = x
        forwardOne ((Just (waddr, wdata, wmask)), rp, (b3, b2, b1, b0)) = if valid then (nb3, nb2, nb1, nb0) else (b3, b2, b1, b0)
            where
                valid = slice d31 d2 waddr == slice d31 d2 rp
                nb0 = if testBit wmask 0 then slice d7 d0 wdata else b0
                nb1 = if testBit wmask 1 then slice d15 d8 wdata else b1
                nb2 = if testBit wmask 2 then slice d23 d16 wdata else b2
                nb3 = if testBit wmask 3 then slice d31 d24 wdata else b3

mkRam :: HiddenClockResetEnable dom
      => Signal dom ReadPort
      -> Signal dom WritePort
      -> Signal dom (BitVector 8, BitVector 8, BitVector 8, BitVector 8)
mkRam readPort writePort = bundle (ram3, ram2, ram1, ram0)
    where
        ram0 = mkByteRam (slice d7 d0) (\x -> testBit x 0) "dm.0.txt" readPort writePort
        ram1 = mkByteRam (slice d15 d8) (\x -> testBit x 1) "dm.1.txt" readPort writePort
        ram2 = mkByteRam (slice d23 d16) (\x -> testBit x 2) "dm.2.txt" readPort writePort
        ram3 = mkByteRam (slice d31 d24) (\x -> testBit x 3) "dm.3.txt" readPort writePort

mkByteRam :: HiddenClockResetEnable dom
          => (BitVector 32 -> BitVector 8)
          -> (WriteMask -> Bool)
          -> String
          -> Signal dom MemAddr
          -> Signal dom (Maybe (MemAddr, MemData, WriteMask))
          -> Signal dom (BitVector 8)
mkByteRam getRange getWe fileName readPort writePort = readResult
    where
        rawAddr = fmap ramIndex readPort
        rawWrite = fmap extractWrite writePort
        readResult = readNew (blockRamFilePow2 fileName) rawAddr rawWrite
        extractWrite x = case x of
            Just (addr, v, mask) -> if getWe mask then Just (ramIndex addr, getRange v) else Nothing
            _ -> Nothing

ramIndex :: MemAddr
         -> Unsigned RamBits
ramIndex x = unpack $ slice (SNat :: SNat (2 + RamBits - 1)) (SNat :: SNat 2) x

isIoAddr :: MemAddr -> Bool
isIoAddr x = slice d31 d28 x == 0xf
