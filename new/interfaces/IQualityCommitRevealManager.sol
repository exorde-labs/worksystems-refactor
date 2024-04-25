// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "./IWorkerManager.sol";
import "./IDataQuality.sol";

interface IQualityCommitRevealManager {
    struct VoteSubmission {
        bool commited;
        bool revealed;
        uint128 vote;
        string extra;
        uint32 batchCount;
    }

    struct DataItemVote {
        // Dynamic arrays of uint8
        uint8[] indices;
        uint8[] statuses;
        // Additional attributes - replace these with your actual attribute types and names
        bytes32 extra;
        bytes32 _id;
    }
    function DataEnded(uint128 _DataBatchId, IWorkerManager.TaskType taskType) external view returns (bool);
    function getUnrevealedQualityWorkers(uint128 _DataBatchId) external view returns (uint16);
    function getUncommittedQualityWorkers(uint128 _DataBatchId) external view returns (uint16);
    function getWorkersPerQualityBatch(uint128 _DataBatchId) external view returns (address[] memory);
    function getQualitySubmissions(uint128 _DataBatchId, address worker_addr) external view returns (DataItemVote memory);
    function didReveal(address _voter, uint128 _DataBatchId, IWorkerManager.TaskType taskType) external view returns (bool);
    function CommitPeriodActive(uint128 _DataBatchId, IWorkerManager.TaskType taskType) external view returns (bool);
    function RevealPeriodActive(uint128 _DataBatchId, IWorkerManager.TaskType taskType) external view returns (bool);
    function isExpired(uint256 _terminationDate) external view returns (bool);    
    function getProcessedBatch(uint128 _DataBatchId) external view returns (IDataQuality.BatchMetadata memory);
    function getProcessBatchInfo(uint128 _DataBatchId) external view returns (IDataQuality.BatchMetadata memory);
    function getVoteSubmission(uint128 _DataBatchId, address worker_addr, IWorkerManager.TaskType taskType) external view returns (VoteSubmission memory);
}
