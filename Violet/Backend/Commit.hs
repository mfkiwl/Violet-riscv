module Violet.Backend.Commit where

import Clash.Prelude
import qualified Violet.Types.Gpr as GprT
import qualified Violet.Types.Fetch as FetchT
import qualified Violet.Types.Pipe as PipeT
import qualified Violet.Types.DCache as DCacheT
import qualified Violet.Types.Commit as CommitT

data CommitState = NormalOperation | EarlyExceptionPending PipeT.EarlyException | ExceptionPending
    deriving (Generic, NFDataX, Eq)
data PrevExceptionState = HadException | HadEarlyException PipeT.EarlyException | NoException
    deriving (Generic, NFDataX, Eq)
data Resolution = ExcResolved | ExcNotResolved
    deriving (Generic, NFDataX, Eq)

commit' :: CommitState
        -> (PipeT.Commit, PipeT.Commit, PipeT.Recovery, DCacheT.WriteEnable)
        -> (
                CommitState,
                (
                    GprT.WritePort, GprT.WritePort, FetchT.BackendCmd, DCacheT.WriteEnable, CommitT.CommitLog,
                    Maybe PipeT.EarlyException
                )
            )
commit' s (cp1, cp2, rp, dcWe) = (s', out)
    where
        (pc1, wp1, bcmd1, earlyExc1, resolution1) = transformCommit cp1
        (pc2_, wp2_, bcmd2, earlyExc2, _) = transformCommit cp2

        hadException = case (s, rp, resolution1) of
            (ExceptionPending, PipeT.IsRecovery, _) -> NoException
            (NormalOperation, _, _) -> NoException
            (EarlyExceptionPending _, _, ExcResolved) -> NoException
            (EarlyExceptionPending e, _, ExcNotResolved) -> HadEarlyException e
            _ -> HadException

        -- Don't commit port 2 if port 1 has exception
        -- `ExcResolved` implies `FetchT.ApplyBranch` so we don't need to explicitly select on it here
        wp2 = case (bcmd1, earlyExc1) of
            (FetchT.NoCmd, Nothing) -> wp2_
            _ -> Nothing
        pc2 = case (bcmd1, earlyExc1) of
            (FetchT.NoCmd, Nothing) -> pc2_
            _ -> Nothing

        -- Select the "earlier" backend command
        bcmd = case bcmd1 of
            FetchT.ApplyBranch _ -> bcmd1
            _ -> bcmd2

        s' = case (hadException, bcmd, earlyExc1, earlyExc2) of
            (NoException, FetchT.NoCmd, Nothing, Nothing) -> NormalOperation
            (NoException, _, Just e, _) -> EarlyExceptionPending e
            (NoException, _, _, Just e) -> EarlyExceptionPending e
            (HadEarlyException e, _, _, _) -> EarlyExceptionPending e
            _ -> ExceptionPending

        log = CommitT.CommitLog {
            CommitT.pc1 = pc1,
            CommitT.pc2 = pc2,
            CommitT.writePort1 = wp1,
            CommitT.writePort2 = wp2
        }

        -- DCache only commits on port 1 so we don't need to discard its result
        out = case hadException of
            HadException -> (Nothing, Nothing, FetchT.NoCmd, DCacheT.NoWrite, CommitT.emptyCommitLog, Nothing)
            HadEarlyException e -> (Nothing, Nothing, FetchT.NoCmd, DCacheT.NoWrite, CommitT.emptyCommitLog, Just e)
            NoException -> (wp1, wp2, bcmd, dcWe, log, Nothing)

commit :: HiddenClockResetEnable dom
       => Signal dom (PipeT.Commit, PipeT.Commit, PipeT.Recovery, DCacheT.WriteEnable)
       -> Signal dom (GprT.WritePort, GprT.WritePort, FetchT.BackendCmd, DCacheT.WriteEnable, CommitT.CommitLog, Maybe PipeT.EarlyException)
commit = mealy commit' NormalOperation

transformCommit :: PipeT.Commit -> (Maybe FetchT.PC, GprT.WritePort, FetchT.BackendCmd, Maybe PipeT.EarlyException, Resolution)
transformCommit (PipeT.Ok (pc, Just (PipeT.GPR i v))) = (Just pc, Just (i, v), FetchT.NoCmd, Nothing, ExcNotResolved)
transformCommit (PipeT.Ok (pc, Nothing)) = (Just pc, Nothing, FetchT.NoCmd, Nothing, ExcNotResolved)
transformCommit PipeT.Bubble = (Nothing, Nothing, FetchT.NoCmd, Nothing, ExcNotResolved)
transformCommit (PipeT.Exc (pc, e)) = case e of
    PipeT.EarlyExcResolution (nextPC, Just (PipeT.GPR i v)) -> (Just pc, Just (i, v), FetchT.ApplyBranch (nextPC, (pc, FetchT.NoPref)), Nothing, ExcResolved)
    PipeT.EarlyExcResolution (nextPC, Nothing) -> (Just pc, Nothing, FetchT.ApplyBranch (nextPC, (pc, FetchT.NoPref)), Nothing, ExcResolved)
    PipeT.BranchLink nextPC idx linkPC -> (Just pc, Just (idx, linkPC), FetchT.ApplyBranch (nextPC, (pc, FetchT.NoPref)), Nothing, ExcNotResolved)
    PipeT.BranchFalsePos nextPC -> (Just pc, Nothing, FetchT.ApplyBranch (nextPC, (pc, FetchT.NotTaken)), Nothing, ExcNotResolved)
    PipeT.BranchFalseNeg nextPC -> (Just pc, Nothing, FetchT.ApplyBranch (nextPC, (pc, FetchT.Taken)), Nothing, ExcNotResolved)
    PipeT.EarlyExc e -> (Nothing, Nothing, FetchT.NoCmd, Just e, ExcNotResolved)