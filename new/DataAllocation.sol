// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "./interfaces/IWorkerManager.sol";
import "./interfaces/IParametersManager.sol";
import "./interfaces/IDataQuality.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract DataAllocation {
    IWorkerManager public workerManager;
    IParametersManager public parametersManager;

    uint16 constant MAX_WORKER_ALLOCATED_PER_BATCH = 30;

    event WorkAllocated(uint128 indexed batchID, address worker);

    constructor(address _workerManagerAddress, address _parametersManagerAddress) {
        require(_workerManagerAddress != address(0), "WorkerManager address cannot be zero.");
        require(_parametersManagerAddress != address(0), "ParametersManager address cannot be zero.");
        workerManager = IWorkerManager(_workerManagerAddress);
        parametersManager = IParametersManager(_parametersManagerAddress);
    }

    /**
     * @dev Allocates work to a set of selected workers from the available pool.
     * This function selects workers, updates the allocated batch state, and assigns work to the selected workers.
     * @param _allocatedBatchCursor The cursor indicating the current allocated batch.
     * @param _processedBatch The storage reference to the BatchMetadata struct being updated.
     * @param _processBatchInfo The storage reference to the ProcessMetadata struct being updated.
     * @param _taskType The type of task (Quality or Relevance) for work allocation.
     */
    function AllocateWork(
        uint128 _allocatedBatchCursor,
        IDataQuality.BatchMetadata storage _processedBatch,
        IDataQuality.ProcessMetadata storage _processBatchInfo,
        IWorkerManager.TaskType _taskType
    ) internal {
        require(
            _processedBatch.complete,
            "Can't allocate work, the current batch is not complete"
        );
        require(
            !_processedBatch.allocated_to_work,
            "Can't allocate work, the current batch is already allocated"
        );

        uint16 selectedWorkersCount = getSelectedWorkersCount();
        updateAllocatedBatchState(_processedBatch, _processBatchInfo, selectedWorkersCount);

        // 1. Select workers
        address[] memory selectedWorkers = selectWorkers(selectedWorkersCount);

        // 2. Allocate work to selected workers
        allocateWorkToWorkers(selectedWorkers, _allocatedBatchCursor, _taskType);
    }

    /**
     * @dev Calculates the number of workers to be selected for allocation.
     * @return The number of workers to be selected for work allocation.
     */
    function getSelectedWorkersCount() private view returns (uint16) {
        uint16 availableWorkersCount = uint16(workerManager.getAvailableWorkersLength());
        uint256 minConsensusWorkerCount = parametersManager.get_QUALITY_MIN_CONSENSUS_WORKER_COUNT();
        uint256 maxConsensusWorkerCount = parametersManager.get_QUALITY_MAX_CONSENSUS_WORKER_COUNT();

        uint16 selectedWorkersCount = uint16(
            Math.max(
                Math.min(availableWorkersCount, maxConsensusWorkerCount),
                minConsensusWorkerCount
            )
        );

        require(
            selectedWorkersCount <= MAX_WORKER_ALLOCATED_PER_BATCH,
            "Selected workers count must be at most MAX_WORKER_ALLOCATED_PER_BATCH"
        );

        return selectedWorkersCount;
    }

    /**
     * @dev Updates the allocated batch state with the selected workers' count.
     * @param _processedBatch The storage reference to the BatchMetadata struct being updated.
     * @param _processBatchInfo The storage reference to the ProcessMetadata struct being updated.
     * @param _selectedWorkersCount The number of selected workers for the current batch.
     */
    function updateAllocatedBatchState(
        IDataQuality.BatchMetadata storage _processedBatch,
        IDataQuality.ProcessMetadata storage _processBatchInfo,
        uint16 _selectedWorkersCount
    ) internal {
        _processBatchInfo.uncommited_quality_workers = _selectedWorkersCount;
        _processBatchInfo.unrevealed_quality_workers = _selectedWorkersCount;

        uint64 qualityCommitEndDate = uint64(block.timestamp + parametersManager.get_QUALITY_COMMIT_ROUND_DURATION());
        uint64 qualityRevealEndDate = uint64(qualityCommitEndDate + parametersManager.get_QUALITY_REVEAL_ROUND_DURATION());
        uint64 relevanceCommitEndDate = uint64(block.timestamp + parametersManager.get_QUALITY_COMMIT_ROUND_DURATION());
        uint64 relevanceRevealEndDate = uint64(relevanceCommitEndDate + parametersManager.get_QUALITY_REVEAL_ROUND_DURATION());

        _processedBatch.allocated_to_work = true;
        _processBatchInfo.quality_commitEndDate = qualityCommitEndDate;
        _processBatchInfo.quality_revealEndDate = qualityRevealEndDate;
        _processBatchInfo.relevance_commitEndDate = relevanceCommitEndDate;
        _processBatchInfo.relevance_revealEndDate = relevanceRevealEndDate;
    }

    /**
     * @dev Selects a set of workers from the available pool based on a specified count.
     * @param _selectedWorkersCount The number of workers to be selected for work allocation.
     * @return An array of addresses representing the selected workers.
     */
    function selectWorkers(uint16 _selectedWorkersCount) private view returns (address[] memory) {
        address[] memory availableWorkers = workerManager.getAvailableWorkers();
        uint256 availableWorkersCount = availableWorkers.length;

        require(
            _selectedWorkersCount >= 1 && availableWorkersCount >= 1,
            "Not enough available workers for allocation"
        );

        address[] memory selectedWorkers = new address[](_selectedWorkersCount);

        for (uint16 i = 0; i < _selectedWorkersCount; i++) {
            uint256 randomIndex = uint256(keccak256(abi.encodePacked(block.timestamp, i))) % availableWorkersCount;
            selectedWorkers[i] = availableWorkers[randomIndex];
        }

        return selectedWorkers;
    }

    /**
     * @dev Allocates work to the specified set of workers and updates their state.
     * @param _selectedWorkers An array of addresses representing the selected workers to be assigned work.
     * @param _allocatedBatchCursor The cursor indicating the current allocated batch.
     * @param _taskType The type of task (Quality or Relevance) for work allocation.
     */
    function allocateWorkToWorkers(
        address[] memory _selectedWorkers,
        uint128 _allocatedBatchCursor,
        IWorkerManager.TaskType _taskType
    ) internal {
        for (uint256 i = 0; i < _selectedWorkers.length; i++) {
            address worker = _selectedWorkers[i];

            // Swap worker from available to busy
            workerManager.SwapFromAvailableToBusyWorkers(worker);

            emit WorkAllocated(_allocatedBatchCursor, worker);
        }
    }
}