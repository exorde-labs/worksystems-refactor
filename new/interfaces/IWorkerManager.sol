// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IWorkerManager {
    enum TaskType { Quality, Relevance }

    // ------ Worker State Structure : 2 slots
    struct WorkerState {
        uint128 allocated_quality_work_batch;
        uint128 allocated_relevance_work_batch;
        uint64 last_interaction_date;
        uint16 succeeding_novote_count;
        bool currently_working;
        bool registered;
        bool unregistration_request;
        bool isWorkerSeen;
        uint64 registration_date;
        uint64 allocated_batch_counter;
        uint64 majority_counter;
        uint64 minority_counter;
    }

    // ------ Worker Status Structure : 2 slots
    struct WorkerStatus {
        bool isActiveWorker;
        bool isAvailableWorker;
        bool isBusyWorker;
        bool isToUnregisterWorker;
        uint32 activeWorkersIndex;
        uint32 availableWorkersIndex;
        uint32 busyWorkersIndex;
        uint32 toUnregisterWorkersIndex;
    }
    
    /// @notice Checks if a worker is registered in the system.
    /// @param worker The address of the worker to check.
    /// @return bool True if the worker is registered, false otherwise.
    function isWorkerRegistered(address worker) external view returns (bool);

    /// @notice Returns the array of available workers addresses
    /// @return address[] The array of available workers addresses.
    function getAvailableWorkers() external view returns (address[] memory);

    /// @notice Gets the length of the available workers
    /// @return uint256 The length of the available workers.
    function getAvailableWorkersLength() external view returns (uint256);

    /// @notice Gets the length of the busy workers
    /// @return uint256 The length of the busy workers.
    function getBusyWorkersLength() external view returns (uint256);

    /// @notice Returns the array of busy workers addresses
    /// @return address[] The array of busy workers addresses.
    function getBusyWorkers() external view returns (address[] memory);

    /// @notice Checks if a worker is allocated to a specific batch for a given task.
    /// @param _DataBatchId The ID of the data batch.
    /// @param _worker The address of the worker.
    /// @param _task The type of task (Quality or Relevance).
    /// @return bool True if the worker is allocated to the batch for the specified task, false otherwise.
    function isWorkerAllocatedToBatch(uint128 _DataBatchId, address _worker, TaskType _task) external view returns (bool);

    /// @notice Registers a worker to the system.
    /// @dev This function would be implemented in the WorkerManager contract, not part of the interface.
    function RegisterWorker() external;

    /// @notice Unregisters a worker from the system.
    /// @dev This function would be implemented in the WorkerManager contract, not part of the interface.
    function UnregisterWorker() external;

    // //// @notice SelectAddressForUser function
    // function SelectAddressForUser(address _user) external view returns (address);

    //// @notice getWorkerState function
    function getWorkerState(address _worker) external view returns (WorkerState memory);

    //// @notice getWorkerStatus function
    function getWorkerStatus(address _worker) external view returns (WorkerStatus memory);

    //// @notice SwapFromAvailableToBusyWorkers function
    function SwapFromAvailableToBusyWorkers(address _worker) external;

    //// @notice SwapFromBusyToAvailableWorkers function
    function SwapFromBusyToAvailableWorkers(address _worker) external;
}
