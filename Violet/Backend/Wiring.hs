module Violet.Backend.Wiring where

import Clash.Prelude

import qualified Violet.Backend.Bypass
import qualified Violet.Backend.Gpr
import qualified Violet.Backend.Branch
import qualified Violet.Backend.Commit
import qualified Violet.Backend.DCache
import qualified Violet.Backend.IntAlu
import qualified Violet.Backend.Issue
import qualified Violet.Backend.Pipe
import qualified Violet.Backend.Fifo
import qualified Violet.Backend.Ctrl

import qualified Violet.Types.Fifo as FifoT
import qualified Violet.Types.Fetch as FetchT
import qualified Violet.Types.Pipe as PipeT
import qualified Violet.Types.Memory as MemoryT
import qualified Violet.Types.Branch as BranchT
import qualified Violet.Types.DecodeDep as DepT
import qualified Violet.Types.Gpr as GprT
import qualified Violet.Types.Ctrl as CtrlT
import qualified Violet.Types.Issue as IssueT
import qualified Violet.Types.Commit as CommitT
import qualified Violet.Types.DCache as DCacheT

wiring :: HiddenClockResetEnable dom
       => DCacheT.DCacheImpl a
       => a
       -> Signal dom (FifoT.FifoItem, FifoT.FifoItem)
       -> Signal dom CtrlT.SystemBusIn
       -> Signal dom (FetchT.BackendCmd, CommitT.CommitLog, FifoT.FifoPushCap, CtrlT.SystemBusOut)
wiring dcacheImpl frontPush sysIn = bundle $ (backendCmd, commitLog, fifoPushCap, sysOut)
    where
        (frontPush1, frontPush2) = unbundle frontPush
        (issueInput1, issueInput2, fifoPushCap) = unbundle $ Violet.Backend.Fifo.fifo $ bundle (frontPush1, frontPush2, fifoPopReq)
        (bypassInput, recovery, immRecovery, fifoPopReq) = unbundle $ Violet.Backend.Issue.issue $ bundle (issueInput1, issueInput2, ctrlBusy)
        gprFetch = Violet.Backend.Gpr.gpr $ bundle (bundle (issueInput1, issueInput2), gprWritePort1, gprWritePort2)
        (fuActivation, gprPort1, gprPort2) = Violet.Backend.Bypass.bypass bypassInput gprFetch commitPipe1 commitPipe2
        commitPipe1 = Violet.Backend.Pipe.completionPipe immRecovery commitStagesIn1
        commitPipe2 = Violet.Backend.Pipe.completionPipe immRecovery commitStagesIn2
        recoveryPipe = Violet.Backend.Pipe.recoveryPipe recoveryStagesIn
        intAlu1 = Violet.Backend.IntAlu.intAlu (fmap IssueT.fuInt1 fuActivation) gprPort1
        intAlu2 = Violet.Backend.IntAlu.intAlu (fmap IssueT.fuInt2 fuActivation) gprPort2
        branchUnit = Violet.Backend.Branch.branch (fmap IssueT.fuBranch fuActivation) gprPort1
        (dcacheUnit, dcWeReq) = Violet.Backend.DCache.dcache dcacheImpl (fmap IssueT.fuMem fuActivation) gprPort1 dcWeCommit
        (ctrlUnit, ctrlBusy, sysOut) = unbundle $ Violet.Backend.Ctrl.ctrl (fmap IssueT.fuCtrl fuActivation) gprPort1 earlyExc sysIn

        (gprWritePort1, gprWritePort2, backendCmd, dcWeCommit, commitLog, earlyExc) = unbundle $ Violet.Backend.Commit.commit $ bundle (last commitPipe1, last commitPipe2, last recoveryPipe, dcWeReq)
        commitStagesIn1 =
            selectCommit (selectCommit intAlu1 branchUnit) ctrlUnit
            :> commitPipe1 !! 0
            :> selectCommit (commitPipe1 !! 1) dcacheUnit
            :> Nil
        commitStagesIn2 =
            intAlu2
            :> commitPipe2 !! 0
            :> commitPipe2 !! 1
            :> Nil
        recoveryStagesIn =
            recovery
            :> recoveryPipe !! 0
            :> recoveryPipe !! 1
            :> Nil

selectCommit :: HiddenClockResetEnable dom
             => Signal dom PipeT.Commit
             -> Signal dom PipeT.Commit
             -> Signal dom PipeT.Commit
selectCommit a b = fmap f $ bundle (a, b)
    where
        f (a, b) = case (a, b) of
            (left, PipeT.Bubble) -> left
            (_, right) -> right