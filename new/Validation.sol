// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IReputation.sol";
import "./interfaces/IRepManager.sol";
import "./interfaces/IDataSpotting.sol";
import "./interfaces/IDataQuality.sol";
import "./interfaces/IRewardManager.sol";
import "./interfaces/IStakeManager.sol";
import "./interfaces/IAddressManager.sol";
import "./interfaces/IParametersManager.sol";
import "./interfaces/IWorkerManager.sol";
import "./interfaces/IQualityCommitRevealManager.sol";
import "./RandomSubsets.sol";

contract Validation is Ownable, Pausable, RandomSubsets {
    // State variables
    IWorkerManager public workerManager;
    IParametersManager public Parameters;
    IQualityCommitRevealManager public qualityCommitRevealManager;

    // -- Batches Counters
    uint128 public DataNonce = 0;
    uint128 public LastBatchCounter = 1;
    uint256 public LastRandomSeed = 0;
    uint256 public AllTxsCounter = 0;
    uint256 public AllItemCounter = 0;
    uint128 public BatchDeletionCursor = 1;
    uint128 public BatchCheckingCursor = 1;
    uint128 public AllocatedBatchCursor = 1;
    // ------------ Rewards & Work allocation related
    bool public STAKING_REQUIREMENT_TOGGLE_ENABLED = false;
    bool public InstantRevealRewards = true;
    uint16 public InstantRevealRewardsDivider = 1;
    uint16 public MaxPendingDataBatchCount = 250;
    // Data random integrity check parameters
    uint128 public _Quality_subset_count = 2;
    uint128 public _Quality_coverage = 5;
    uint16 public QUALITY_FILE_SIZE_MIN = 1000;
    uint256 public MAX_ONGOING_JOBS = 500;
    uint256 public NB_BATCH_TO_TRIGGER_GARBAGE_COLLECTION = 1000;
    uint256 private MIN_OFFSET_DELETION_CURSOR = 50;


    uint128 public MAX_INDEX_RANGE_BATCHS = 10000;
    uint128 public MAX_INDEX_RANGE_ITEMS = 10000 * 30;

    // Mappings and data structures
    mapping(uint128 => IDataQuality.QualityData) public InputFilesMap;
    mapping(uint128 => IDataQuality.BatchMetadata) public ProcessedBatch;
    mapping(uint128 => IDataQuality.ProcessMetadata) public ProcessBatchInfo;
    // structure to store the subsets for each batch
    mapping(uint128 => uint128[][]) public RandomQualitySubsets;

    // ------ Quality input flow management
    uint64 public LastAllocationTime = 0;
    uint16 constant NB_TIMEFRAMES = 15;
    uint16 constant MAX_MASTER_DEPTH = 3;
    IDataBase.TimeframeCounter[NB_TIMEFRAMES] public ItemFlowManager;
    // Events
    event _QualitySubmitted(
        uint256 indexed DataID,
        string file_hash,
        address indexed sender
    );

    // Constructor
    constructor(address _workerManagerAddress, address _qualityCommitRevealManagerAddress) {
        require(_workerManagerAddress != address(0), "WorkerManager address cannot be zero.");
        require(_qualityCommitRevealManagerAddress != address(0), "QualityCommitRevealManager address cannot be zero.");
        workerManager = IWorkerManager(_workerManagerAddress);
        qualityCommitRevealManager = IQualityCommitRevealManager(_qualityCommitRevealManagerAddress);
    }

    // Functions
    function pushData(IDataSpotting.BatchMetadata memory batch_) external returns (bool) {
        // Reads from QualityCommitRevealManager: None
        // Writes to QualityCommitRevealManager: None
        // Reads from WorkerManager: None
        // Writes to WorkerManager: None

        require(
            msg.sender == Parameters.getSpottingSystem(),
            "only the appointed DataSpotting contract can push data to Quality"
        );
        IDataSpotting.BatchMetadata memory SpotBatch = batch_;

        // ADDING NEW CHECKED QUALITY BATCH AS A NEW ITEM IN OUR QUALITY BATCH
        InputFilesMap[DataNonce] = IDataQuality.QualityData({
            ipfs_hash: SpotBatch.batchIPFSfile,
            author: msg.sender,
            timestamp: uint64(block.timestamp),
            unverified_item_count: SpotBatch.item_count
        });

        uint128 _batch_counter = LastBatchCounter;
        // UPDATE STREAMING DATA BATCH STRUCTURE
        IDataQuality.BatchMetadata storage current_data_batch = ProcessedBatch[
            _ModB(_batch_counter)
        ];
        if (current_data_batch.counter < Parameters.get_QUALITY_DATA_BATCH_SIZE()) {
            current_data_batch.counter += 1;
        }
        if (current_data_batch.counter >= Parameters.get_QUALITY_DATA_BATCH_SIZE()) {
            // batch is complete trigger new work round, new batch
            current_data_batch.complete = true;
            current_data_batch.quality_checked = false;
            current_data_batch.relevance_checked = false;
            LastBatchCounter += 1;
            delete ProcessedBatch[_ModB(LastBatchCounter)];
            // we indicate that the first Quality of the new batch, is the one we just built
            ProcessedBatch[_ModB(_batch_counter)].start_idx = DataNonce;
        }

        DataNonce = DataNonce + 1;
        emit _QualitySubmitted(DataNonce, SpotBatch.batchIPFSfile, msg.sender);
        AllTxsCounter += 1;
        return false;
    }

    function TriggerUpdate(uint128 iteration_count, IWorkerManager.TaskType taskType) public {
        // Reads from QualityCommitRevealManager: None
        // Writes to QualityCommitRevealManager: None
        // Reads from WorkerManager: None
        // Writes to WorkerManager: None

        require(
            IParametersManager(address(0)) != Parameters,
            "Parameters Manager must be set."
        );
        updateItemCount();
        TriggerValidation(iteration_count, taskType);
        // Log off waiting users first
        processLogoffRequests(iteration_count);
        TriggerAllocations(iteration_count, taskType);
        _retrieveSFuel();
    }

    function TriggerAllocations(uint128 iteration_count, IWorkerManager.TaskType taskType) public {
        // Reads from QualityCommitRevealManager: None
        // Writes to QualityCommitRevealManager: None
        // Reads from WorkerManager:
        //   - getAvailableWorkers()
        // Writes to WorkerManager:
        //   - SwapFromAvailableToBusyWorkers(address _worker)

        require(taskType == IWorkerManager.TaskType.Quality || IWorkerManager.TaskType == IWorkerManager.TaskType.Relevance, "TaskType must be set.");
        require(
            IParametersManager(address(0)) != Parameters,
            "Parameters Manager must be set."
        );
        // Log off waiting users first
        processLogoffRequests(iteration_count);
        // Then iterate as much as possible in the batches.
        if ((LastRandomSeed != getRandom())) {
            for (uint128 i = 0; i < iteration_count; i++) {
                bool progress = false;
                // IF CURRENT BATCH IS COMPLETE AND NOT ALLOCATED TO WORKERS TO BE CHECKED, THEN ALLOCATE!
                if (
                    ProcessedBatch[_ModB(AllocatedBatchCursor)].allocated_to_work != true &&
                    workerManager.getAvailableWorkers().length >= Parameters.get_QUALITY_MIN_CONSENSUS_WORKER_COUNT() &&
                    ProcessedBatch[_ModB(AllocatedBatchCursor)].complete &&
                    (AllocatedBatchCursor - BatchCheckingCursor <= MAX_ONGOING_JOBS)
                ) {
                    AllocateWork(taskType);
                    progress = true;
                }
                if (!progress) {
                    // break from the loop if no more progress
                    break;
                }
            }
        }
        _retrieveSFuel();
    }

    function updateItemCount() public {
        // Reads from QualityCommitRevealManager: None
        // Writes to QualityCommitRevealManager: None
        // Reads from WorkerManager: None
        // Writes to WorkerManager: None

        require(
            IParametersManager(address(0)) != Parameters,
            "Parameters Manager must be set."
        );
        // Implement the logic to update the global sliding counter of validated data
    }

    function TriggerValidation(uint128 iteration_count, IWorkerManager.TaskType taskType) public {
        // Reads from QualityCommitRevealManager:
        //   - DataEnded(uint128 _DataBatchId, taskType)
        //   - getUnrevealedQualityWorkers(uint128 _DataBatchId)
        //   - getWorkersPerQualityBatch(uint128 _DataBatchId)
        //   - getQualitySubmissions(uint128 _DataBatchId, address worker_addr)
        // Writes to QualityCommitRevealManager: None
        // Reads from WorkerManager:
        //   - isWorkerAllocatedToBatch(uint128 _DataBatchId, address _worker, IWorkerManager.TaskType _task)
        // Writes to WorkerManager: None

        require(
            IParametersManager(address(0)) != Parameters,
            "Parameters Manager must be set."
        );

        uint128 PrevCursor = BatchCheckingCursor;
        for (uint128 i = 0; i < iteration_count; i++) {
            uint128 CurrentCursor = PrevCursor + i;

            // IF CURRENT BATCH IS ALLOCATED TO WORKERS AND VOTE HAS ENDED, TRIGGER VALIDATION
            if (ProcessedBatch[_ModB(CurrentCursor)].allocated_to_work &&
                (qualityCommitRevealManager.DataEnded(CurrentCursor, taskType) ||
                 (qualityCommitRevealManager.getUnrevealedQualityWorkers(CurrentCursor) == 0))) {

                // check if the batch is already validated
                if (!ProcessedBatch[_ModB(CurrentCursor)].quality_checked) {
                    ValidateBatch(CurrentCursor, taskType);
                }

                // increment BatchCheckingCursor if possible
                if (CurrentCursor == BatchCheckingCursor + 1) {
                    BatchCheckingCursor = BatchCheckingCursor + 1;
                    require(BatchCheckingCursor <= AllocatedBatchCursor, "BatchCheckingCursor <= AllocatedBatchCursor assert invalidated");
                }
            }

            // Garbage collect if the offset [Deletion - Checking Cursor] > NB_BATCH_TO_TRIGGER_GARBAGE_COLLECTION
            if (BatchDeletionCursor + NB_BATCH_TO_TRIGGER_GARBAGE_COLLECTION < BatchCheckingCursor) {
                deleteOldData(1);
            }
        }
    }

    function processLogoffRequests(uint128 iteration_count) internal {
        // Reads from QualityCommitRevealManager: None
        // Writes to QualityCommitRevealManager: None
        // Reads from WorkerManager: None
        // Writes to WorkerManager:
        //   - SwapFromBusyToAvailableWorkers(address _worker)
        //   - RemoveFromAvailableAndBusyWorkers(address _worker)

        // Implement the logic to process logoff requests for workers who have requested to unregister
    }

    function getRandom() internal view returns (uint256) {
        // Reads from QualityCommitRevealManager: None
        // Writes to QualityCommitRevealManager: None
        // Reads from WorkerManager: None
        // Writes to WorkerManager: None

        uint256 r = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp +
                        uint256(keccak256(abi.encodePacked(getSeed(),block.timestamp)))
                )
            )
        );
        return r;
    }

    
    /**
     * @dev Allocates Quality Work to a set of selected workers from the available pool.
     * This function selects workers, updates the allocated batch state, and assigns work to the selected workers.
     */
    function AllocateWork(IWorkerManager.TaskType taskType) internal {
        IDataQuality.BatchMetadata storage allocated_batch = ProcessedBatch[
            _ModB(AllocatedBatchCursor)
        ];
        IDataQuality.ProcessMetadata storage process_info = ProcessBatchInfo[
            _ModB(AllocatedBatchCursor)
        ];
        require(
            ProcessedBatch[_ModB(AllocatedBatchCursor)].complete,
            "Can't allocate work, the current batch is not complete"
        );
        require(
            !ProcessedBatch[_ModB(AllocatedBatchCursor)].allocated_to_work,
            "Can't allocate work, the current batch is already allocated"
        );

        if (
            (uint64(block.timestamp) - LastAllocationTime) >=
            Parameters.get_QUALITY_INTER_ALLOCATION_DURATION()
        ) {
            uint16 selected_k_workers = getSelectedWorkersCount();
            updateAllocatedBatchState(allocated_batch, process_info, selected_k_workers);
            // 1. Select workers
            address[] memory selected_workers_addresses = selectWorkers(
                selected_k_workers
            );
            // 2. Allocate Batch ID to selected workers

            // 3. If Quality, then allocate Quality work to selected workers
            
            if (taskType == IWorkerManager.TaskType.Quality) {
                uint128 _Quality_N = allocated_batch.counter * 100;
                uint128[][] memory allocated_random_subsets = getRandomSubsets(
                    _Quality_subset_count,
                    _Quality_N,
                    _Quality_coverage
                );
                // fill BatchSubset
                RandomQualitySubsets[
                    _ModB(AllocatedBatchCursor)
                ] = allocated_random_subsets;
            }
            // update selected workers states
            allocateWorkToWorkers(selected_workers_addresses, taskType);
            // post checks
            LastAllocationTime = uint64(block.timestamp);
            AllocatedBatchCursor += 1;
            LastRandomSeed = getRandom();
            AllTxsCounter += 1;
        }
    }

    
    /**
     * @notice Handle worker vote during the data batch validation.
     * @param worker_addr_ The address of the worker.
     * @param has_worker_voted_ True if the worker has voted, otherwise false.
     * @param isInMajority True if worker in Majority
     */
    function handleWorkerQualityParticipation(
        address worker_addr_,
        bool has_worker_voted_,
        bool isInMajority
    ) internal {
        // Access worker state
        WorkerState storage worker_state = WorkersState[worker_addr_];

        // If the worker has indeed voted (committed & revealed)
        if (has_worker_voted_) {
            // Reset the no-vote counter for the worker
            worker_state.succeeding_novote_count = 0;

            // Reward the worker if they voted with the majority
            if (isInMajority) {
                rewardWorker(worker_addr_);
                worker_state.majority_counter += 1;
            } else {
                worker_state.minority_counter += 1;
            }
        }
        // If the worker has not voted (never revealed)
        else {
            // Increment the succeeding no-vote count for the worker
            worker_state.succeeding_novote_count += 1;

            // Force log off the worker if they have not voted multiple times in a row
            if (
                worker_state.succeeding_novote_count >=
                Parameters.get_MAX_SUCCEEDING_NOVOTES()
            ) {
                worker_state.registered = false;
                PopFromBusyWorkers(worker_addr_);
                PopFromAvailableWorkers(worker_addr_);
            }

            // If the worker has revealed, they are available again (revealing releases a given worker)
            // If the worker has not revealed, then the worker is still busy, move them from Busy to Available
            if (worker_state.registered) {
                // Only if the worker is still registered
                PopFromBusyWorkers(worker_addr_);
                PushInAvailableWorkers(worker_addr_);
            }

            worker_state.currently_working = false;
        }
    }

    /**
     * @notice Update the state of a validated data batch.
     * @param DataBatchId DataBatchId
     * @param confirmed_statuses The confirmed list of statuses
     */
    function updateValidatedQualityBatchState(
        uint128 DataBatchId,
        IDataQuality.DataItemVote memory confirmed_statuses,
        IWorkerManager.TaskType
    ) internal {
       IDataQuality.BatchMetadata storage batch = ProcessedBatch[_ModB(DataBatchId)];
        ProcessMetadata storage process_info = ProcessBatchInfo[_ModB(DataBatchId)];
        // Update ProcessedBatch properties
        batch.quality_checked = true;

        // Update global counters
        AllTxsCounter += 1;
        NotCommitedCounter += process_info.uncommited_quality_workers;
        NotRevealedCounter += process_info.unrevealed_quality_workers;
    }

    /**
     * @dev Calculates the number of workers to be selected for allocation.
     * @return A uint16 representing the number of workers to be selected for work allocation.
     */
    function getSelectedWorkersCount() private view returns (uint16) {
        uint16 selected_k = uint16(
            Math.max(
                Math.min(
                    availableWorkers.length,
                    Parameters.get_QUALITY_MAX_CONSENSUS_WORKER_COUNT()
                ),
                Parameters.get_QUALITY_MIN_CONSENSUS_WORKER_COUNT()
            )
        );
        require(
            selected_k <= MAX_WORKER_ALLOCATED_PER_BATCH,
            "selected_k must be at most MAX_WORKER_ALLOCATED_PER_BATCH"
        );
        return selected_k;
    }

    /**
     * @dev Updates the allocated batch state with the selected workers' count.
     * @param allocated_batch A storage reference to the BatchMetadata struct being updated.
     * @param selected_k_workers A uint16 representing the number of selected workers for the current batch.
     */
    function updateAllocatedBatchState(
        IDataQuality.BatchMetadata storage allocated_batch,
        IDataQuality.ProcessMetadata storage process_info,
        uint16 selected_k_workers
    ) internal {
        process_info.uncommited_quality_workers = selected_k_workers;
        process_info.unrevealed_quality_workers = selected_k_workers;
        uint64 quality_commitEndDate = uint64(
            block.timestamp + Parameters.get_QUALITY_COMMIT_ROUND_DURATION()
        );
        uint64 quality_revealEndDate = uint64(
            quality_commitEndDate + Parameters.get_QUALITY_REVEAL_ROUND_DURATION()
        );
        uint64 relevance_commitEndDate = uint64(
            block.timestamp + Parameters.get_QUALITY_COMMIT_ROUND_DURATION()
        );
        uint64 relevance_revealEndDate = uint64(
            relevance_commitEndDate + Parameters.get_QUALITY_REVEAL_ROUND_DURATION()
        );
        allocated_batch.allocated_to_work = true;
        process_info.quality_commitEndDate = quality_commitEndDate;
        process_info.quality_revealEndDate = quality_revealEndDate;
        process_info.relevance_commitEndDate = relevance_commitEndDate;
        process_info.relevance_revealEndDate = relevance_revealEndDate;
    }

    /**
     * @dev Selects a set of workers from the available pool based on a specified count.
     * @param selected_k_workers A uint16 representing the number of workers to be selected for work allocation.
     * @return An array of addresses representing the selected workers.
     */
    function selectWorkers(uint16 selected_k_workers)
        private
        view
        returns (address[] memory)
    {
        uint256 n = availableWorkers.length;
        require(
            selected_k_workers >= 1 && n >= 1,
            "Fail during allocation: not enough workers"
        );
        uint256[] memory selected_workers_idx = random_selection(
            selected_k_workers,
            n
        );
        address[] memory selected_workers_addresses = new address[](
            selected_workers_idx.length
        );

        for (uint256 i = 0; i < selected_workers_idx.length; i++) {
            selected_workers_addresses[i] = availableWorkers[
                selected_workers_idx[i]
            ];
        }

        return selected_workers_addresses;
    }

    /**
     * @dev Allocates work to the specified set of workers and updates their state.
     * @param selected_workers_addresses An array of addresses representing the selected workers to be assigned work.
     */
    function allocateWorkToWorkers(address[] memory selected_workers_addresses, IWorkerManager.TaskType taskType)
        internal
    {
        uint128 _allocated_batch_cursor = AllocatedBatchCursor;
        // allocated workers per batch is always low (< 30). This loop can be considered O(1).
        for (uint256 i = 0; i < selected_workers_addresses.length; i++) {
            address selected_worker_ = selected_workers_addresses[i];
            WorkerState storage worker_state = WorkersState[selected_worker_];

            // clear existing values
            if (taskType == IWorkerManager.TaskType.Quality) {
                UserQualityVoteSubmission[_ModB(_allocated_batch_cursor)][selected_worker_]
                    .commited = false;
                UserQualityVoteSubmission[_ModB(_allocated_batch_cursor)][selected_worker_]
                    .revealed = false;
            } else if (taskType == IWorkerManager.TaskType.Relevance) {
                UserRelevanceVoteSubmission[_ModB(_allocated_batch_cursor)][selected_worker_]
                    .commited = false;
                UserRelevanceVoteSubmission[_ModB(_allocated_batch_cursor)][selected_worker_]
                    .revealed = false;
            }

            // swap worker from available to busy, not to be picked again while working
            PopFromAvailableWorkers(selected_worker_);
            PushInBusyWorkers(selected_worker_); // set worker as busy
            if (taskType == IWorkerManager.TaskType.Quality) {
                WorkersPerQualityBatch[_ModB(_allocated_batch_cursor)].push(
                    selected_worker_
                );
            } else if (taskType == IWorkerManager.TaskType.Relevance) {
                WorkersPerRelevanceBatch[_ModB(_allocated_batch_cursor)].push(
                    selected_worker_
                );
            }
            // allocation of work depends on the IWorkerManager.TaskType
            if (taskType == IWorkerManager.TaskType.Quality) {
                worker_state.allocated_quality_work_batch = _allocated_batch_cursor;
            } else if (taskType == IWorkerManager.TaskType.Relevance) {
                worker_state.allocated_relevance_work_batch = _allocated_batch_cursor;
            }
            worker_state.allocated_batch_counter += 1;
            worker_state.currently_working = true;

            emit _WorkAllocated(_allocated_batch_cursor, selected_worker_);
        }
    }

    /**
     * @notice To know if new work is available for worker's address user_
     * @param user_ user
     */
    function IsWorkAvailable(address user_, IWorkerManager.TaskType taskType) public view returns (bool) {
        bool new_work_available = false;
        WorkerState memory user_state = WorkersState[user_];
        if (taskType == IWorkerManager.TaskType.Quality){
            uint128 _currentUserBatch = user_state.allocated_quality_work_batch;
            if (_currentUserBatch == 0) {
                return false;
            }
            if (
                !didReveal(user_, _currentUserBatch, taskType) &&
                !CommitPeriodOver(_currentUserBatch, taskType)
            ) {
                new_work_available = true;
            }
        }
        else{
            uint128 _currentUserBatch = user_state.allocated_relevance_work_batch;
            if (_currentUserBatch == 0) {
                return false;
            }
            if (
                !didReveal(user_, _currentUserBatch, taskType) &&
                !CommitPeriodOver(_currentUserBatch, taskType)
            ) {
                new_work_available = true;
            }
        }
        return new_work_available;
    }


    // ================================================================================
    //                             Validate Data Batch
    // ================================================================================
    /**
     * @notice Validate data for the specified data batch.
     * @param _DataBatchId The ID of the data batch to be validated.
     */
    function ValidateBatch(uint128 _DataBatchId, TaskType taskType) internal {
        // BatchMetadata storage batch = ProcessedBatch[_ModB(_DataBatchId)];
        // ProcessMetadata storage process_info = ProcessBatchInfo[_ModB(_DataBatchId)];
        // 0. Check if initial conditions are met before validation process
        requireInitialQualityConditions(_DataBatchId, taskType);

        // 1. Get allocated workers
        address[] memory allocated_workers = WorkersPerQualityBatch[
            _ModB(_DataBatchId)
        ];

        if(taskType == TaskType.Quality){
            // 2. Gather user submissions and vote inputs for the ProcessedBatch
            DataItemVote[] memory proposed_Quality_statuses = getWorkersQualitySubmissions(
                _DataBatchId,
                allocated_workers
            );

            // 3. Compute the majority submission & vote for the ProcessedBatch
            (
                DataItemVote memory confirmed_statuses,
                address[] memory workers_in_majority
            ) = getQualityQuorum(allocated_workers, proposed_Quality_statuses);

            // 7. Iterate through the minority_workers first
            for (uint256 i = 0; i < workers_in_majority.length; i++) {
                address worker_addr = workers_in_majority[i];
                bool has_worker_voted = UserQualityVoteSubmission[_ModB(_DataBatchId)][
                    worker_addr
                ].revealed;
                // 8. Handle worker vote, update worker state and perform necessary actions
                handleWorkerQualityParticipation(worker_addr, has_worker_voted, true);
            }

            // 10. Update the ProcessedBatch state and counters based on the validation results
            updateValidatedQualityBatchState(_DataBatchId, confirmed_statuses, taskType);
            emit _BatchQualityValidated(_DataBatchId, confirmed_statuses);
        }
    }


    /**
     * @notice Ensure the initial conditions are met for the data batch validation.
     * @param _DataBatchId The ID of the data batch.
     */
    function requireInitialQualityConditions(
        uint128 _DataBatchId,
        TaskType taskType
    ) private view {
        require(
            IParametersManager(address(0)) != Parameters,
            "Parameters Manager must be set."
        );
        require(
            Parameters.getAddressManager() != address(0),
            "AddressManager is null in Parameters"
        );
        require(
            Parameters.getRepManager() != address(0),
            "RepManager is null in Parameters"
        );
        require(
            Parameters.getRewardManager() != address(0),
            "RewardManager is null in Parameters"
        );
        bool early_batch_end = false;
        if (taskType == TaskType.Quality && (ProcessBatchInfo[_ModB(_DataBatchId)].unrevealed_quality_workers == 0)) {
            early_batch_end = true;
        } 
        else if(taskType == TaskType.Relevance && (ProcessBatchInfo[_ModB(_DataBatchId)].unrevealed_relevance_workers == 0)) {
            early_batch_end = true;
        }
        require(
            DataEnded(_DataBatchId, taskType) || early_batch_end,
            "_DataBatchId has not ended, or not every voters have voted"
        ); // votes need to be closed
        require(!ProcessedBatch[_ModB(_DataBatchId)].quality_checked, "_DataBatchId is already validated"); // votes need to be closed
    }

    /**
     * @notice Gather user submissions and vote inputs for the data batch validation.
     * @param _DataBatchId The ID of the data batch.
     * @param allocated_workers Array of worker addresses allocated to the data batch.
     */
    function getWorkersQualitySubmissions(
        uint128 _DataBatchId,
        address[] memory allocated_workers
    ) public view returns (DataItemVote[] memory) {
        DataItemVote[] memory proposed_Quality_statuses = new DataItemVote[](
            allocated_workers.length
        );

        // Iterate through all allocated workers for their Quality submissions
        for (uint256 i = 0; i < allocated_workers.length; i++) {
            address worker_addr_ = allocated_workers[i];
            // Store the worker's submitted data
            proposed_Quality_statuses[i] = QualitySubmissions[_ModB(_DataBatchId)][
                worker_addr_
            ];
        }

        return (proposed_Quality_statuses);
    }

    /**
     * @notice Compute the majority quorum for the data batch validation.
     * @param allocated_workers Array of worker addresses allocated to the data batch.
     * @param workers_statuses Array of DataItemVote representing each worker's votes.
     * @return confirmed_statuses The list of confirmed statuses as DataItemVote.
     * @return workers_in_majority The list of addresses indicating which worker has voted like the majority.
     */
    function getQualityQuorum(
        address[] memory allocated_workers,
        DataItemVote[] memory workers_statuses
    )
        public
        pure
        returns (
            DataItemVote memory confirmed_statuses,
            address[] memory workers_in_majority
        )
    {
        // Find the maximum index
        uint256 maxIndex = 0;
        for (uint256 i = 0; i < workers_statuses.length; i++) {
            for (uint256 j = 0; j < workers_statuses[i].indices.length; j++) {
                if (workers_statuses[i].indices[j] > maxIndex) {
                    maxIndex = workers_statuses[i].indices[j];
                }
            }
        }

        // Initialize variables
        uint256[][] memory statusCounts = new uint256[][](maxIndex + 1);
        for (uint256 i = 0; i <= maxIndex; i++) {
            statusCounts[i] = new uint256[](NB_UNIQUE_QUALITY_STATUSES);
        }
        uint256[] memory indexCounts = new uint256[](maxIndex + 1);
        bool[] memory isInMajority = new bool[](allocated_workers.length);

        // Count statuses for each index
        for (uint256 i = 0; i < workers_statuses.length; i++) {
            for (uint256 j = 0; j < workers_statuses[i].indices.length; j++) {
                uint8 index = workers_statuses[i].indices[j];
                uint8 status = workers_statuses[i].statuses[j];
                statusCounts[index][uint256(status)]++;
                indexCounts[index]++;
            }
        }

        // Determine the majority status for each index
        confirmed_statuses.indices = new uint8[](maxIndex + 1);
        confirmed_statuses.statuses = new uint8[](maxIndex + 1);

        for (uint256 i = 0; i <= maxIndex; i++) {
            uint256 maxStatusCount = 0;
            uint256 maxStatus = 0;
            for (uint256 s = 0; s < 4; s++) {
                if (statusCounts[i][s] > maxStatusCount) {
                    maxStatusCount = statusCounts[i][s];
                    maxStatus = s;
                }
            }
            confirmed_statuses.indices[i] = uint8(i);
            confirmed_statuses.statuses[i] = uint8(maxStatus);
        }

        // Determine which workers are in the majority
        for (uint256 i = 0; i < allocated_workers.length; i++) {
            isInMajority[i] = true;
            for (uint256 j = 0; j < workers_statuses[i].indices.length; j++) {
                uint8 index = workers_statuses[i].indices[j];
                if (workers_statuses[i].statuses[j] != confirmed_statuses.statuses[index]) {
                    isInMajority[i] = false;
                    break;
                }
            }
        }

        // Collect addresses of workers in the majority
        uint256 count = 0;
        for (uint256 i = 0; i < isInMajority.length; i++) {
            if (isInMajority[i]) {
                count++;
            }
        }

        workers_in_majority = new address[](count);
        count = 0;
        for (uint256 i = 0; i < isInMajority.length; i++) {
            if (isInMajority[i]) {
                workers_in_majority[count] = allocated_workers[i];
                count++;
            }
        }

        return (confirmed_statuses, workers_in_majority);
    }


    /**
     * @notice Update the majority batch count.
     * @param batch_ BatchMetadata storage reference for the data batch.
     * @param majorityBatchCount The majority batch count.
     * @param isCheckPassed True if the validation check passed, otherwise false.
     * @return The majority batch count
     */
    function updateMajorityBatchCount(
        BatchMetadata storage batch_,
        uint32 majorityBatchCount,
        bool isCheckPassed
    ) internal view returns (uint32) {
        if (!isCheckPassed) {
            return QUALITY_FILE_SIZE_MIN;
        } else {
            return
                uint32(
                    Math.min(
                        uint32(batch_.counter * QUALITY_FILE_SIZE_MIN),
                        majorityBatchCount
                    )
                );
        }
    }

    /**
     * @notice Reward a worker for their participation in the data batch validation.
     * @param worker_addr_ The address of the worker to be rewarded.
     */
    function rewardWorker(address worker_addr_) internal {
        IAddressManager _AddressManager = IAddressManager(
            Parameters.getAddressManager()
        );
        IRepManager _RepManager = IRepManager(Parameters.getRepManager());
        // IRewardManager _RewardManager = IRewardManager(Parameters.getRewardManager());

        address worker_master_addr_ = _AddressManager.FetchHighestMaster(
            worker_addr_
        );
        require(
            _RepManager.mintReputationForWork(
                Parameters.get_QUALITY_MIN_REP_DataValidation(),
                worker_master_addr_,
                ""
            ),
            "could not reward REP in Validate, 1.a"
        );
    }

    /**
     * @notice Handle worker vote during the data batch validation.
     * @param worker_addr_ The address of the worker.
     * @param has_worker_voted_ True if the worker has voted, otherwise false.
     * @param isInMajority True if worker in Majority
     */
    function handleWorkerQualityParticipation(
        address worker_addr_,
        bool has_worker_voted_,
        bool isInMajority
    ) internal {
        // Access worker state
        WorkerState storage worker_state = WorkersState[worker_addr_];

        // If the worker has indeed voted (committed & revealed)
        if (has_worker_voted_) {
            // Reset the no-vote counter for the worker
            worker_state.succeeding_novote_count = 0;

            // Reward the worker if they voted with the majority
            if (isInMajority) {
                rewardWorker(worker_addr_);
                worker_state.majority_counter += 1;
            } else {
                worker_state.minority_counter += 1;
            }
        }
        // If the worker has not voted (never revealed)
        else {
            // Increment the succeeding no-vote count for the worker
            worker_state.succeeding_novote_count += 1;

            // Force log off the worker if they have not voted multiple times in a row
            if (
                worker_state.succeeding_novote_count >=
                Parameters.get_MAX_SUCCEEDING_NOVOTES()
            ) {
                worker_state.registered = false;
                PopFromBusyWorkers(worker_addr_);
                PopFromAvailableWorkers(worker_addr_);
            }

            // If the worker has revealed, they are available again (revealing releases a given worker)
            // If the worker has not revealed, then the worker is still busy, move them from Busy to Available
            if (worker_state.registered) {
                // Only if the worker is still registered
                PopFromBusyWorkers(worker_addr_);
                PushInAvailableWorkers(worker_addr_);
            }

            worker_state.currently_working = false;
        }
    }

    /**
     * @notice Update the state of a validated data batch.
     * @param DataBatchId DataBatchId
     * @param confirmed_statuses The confirmed list of statuses
     */
    function updateValidatedQualityBatchState(
        uint128 DataBatchId,
        DataItemVote memory confirmed_statuses,
        TaskType taskType
    ) internal {
        BatchMetadata storage batch = ProcessedBatch[_ModB(DataBatchId)];
        ProcessMetadata storage process_info = ProcessBatchInfo[_ModB(DataBatchId)];
        // Update ProcessedBatch properties
        batch.quality_checked = true;

        // Update global counters
        AllTxsCounter += 1;
        NotCommitedCounter += process_info.uncommited_quality_workers;
        NotRevealedCounter += process_info.unrevealed_quality_workers;
    }


    function _retrieveSFuel() internal {
        // Reads from QualityCommitRevealManager: None
        // Writes to QualityCommitRevealManager: None
        // Reads from WorkerManager: None
        // Writes to WorkerManager: None

        require(
            IParametersManager(address(0)) != Parameters,
            "Parameters Manager must be set."
        );
        address sFuelAddress = Parameters.getsFuelSystem();
        require(sFuelAddress != address(0), "sFuel: null Address Not Valid");

        // Attempting the retrieveSFuel call
        (bool success, ) = sFuelAddress.call(
            abi.encodeWithSignature("retrieveSFuel(address)", msg.sender)
        );
        require(success, "receiver rejected _retrieveSFuel call");
    }

    function _ModB(uint128 BatchId) private view returns (uint128) {
        // Reads from QualityCommitRevealManager: None
        // Writes to QualityCommitRevealManager: None
        // Reads from WorkerManager: None
        // Writes to WorkerManager: None

        return BatchId % MAX_INDEX_RANGE_BATCHS;
    }

    function _ModS(uint128 SpotId) private view returns (uint128) {
        // Reads from QualityCommitRevealManager: None
        // Writes to QualityCommitRevealManager: None
        // Reads from WorkerManager: None
        // Writes to WorkerManager: None

        return SpotId % MAX_INDEX_RANGE_ITEMS;
    }

    }