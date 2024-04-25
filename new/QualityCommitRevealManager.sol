// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

/**
 * @title QualityCommitRevealManager
 * @author Mathias Dail - CTO @ Exorde Labs 2024
 */

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./FuelRetriever.sol";
import "./interfaces/IParametersManager.sol";
import "./interfaces/IDataQuality.sol";
import "./interfaces/IStakeManager.sol";
import "./interfaces/IAddressManager.sol";
import "./interfaces/IWorkerManager.sol";
import "./interfaces/IRewardManager.sol";
import "./interfaces/IReputation.sol";
import "./interfaces/IRepManager.sol";
import "./interfaces/IDataSpotting.sol";
import "./RandomSubsets.sol";
import "libs/hashing.sol";
/**
 * @title WorkerManager
 * @dev Manages worker registrations, stake handling
 * @notice This contract allows workers to register, stake, and be allocated to batches of work.
 */
contract QualityCommitReveal {

    using hashing for *;
    // Assuming other necessary structs and state variables here based on the provided contract details

    IWorkerManager public workerManager;

    // Constructor to set the WorkerManager contract address
    constructor(address _workerManagerAddress) {
        require(_workerManagerAddress != address(0), "WorkerManager address cannot be zero.");
        workerManager = IWorkerManager(_workerManagerAddress);
    }

    // ------ User Submissions & Voting related structure
    mapping(uint128 => mapping(address => IDataQuality.VoteSubmission))
        public UserQualityVoteSubmission;
    mapping(uint128 => mapping(address => IDataQuality.VoteSubmission))
        public UserRelevanceVoteSubmission;
    // 1. Quality structures
    mapping(uint128 => mapping(address => bytes32))
        public QualityHashes;
    //  BatchID => (UserAddress => lists (index, value))
    mapping(uint128 => mapping(address => IDataQuality.DataItemVote))
        public QualitySubmissions;

    // 2. Relevance Structures
    mapping(uint128 => mapping(address => bytes32))
        public UserEncryptedBaseCounts;
    mapping(uint128 => mapping(address => bytes32))
        public UserEncryptedDuplicates;
    mapping(uint128 => mapping(address => bytes32))
        public UserEncryptedBountiesCounts;
        
    //  BatchID => (UserAddress => lists (index, value))
    mapping(uint128 => mapping(address => IDataQuality.DataItemVote))
        public UserClearCounts;
    mapping(uint128 => mapping(address => IDataQuality.DataItemVote))
        public UserClearDuplicatesIndices;
    mapping(uint128 => mapping(address => IDataQuality.DataItemVote))
        public UserClearBountiesCounts;

    mapping(address => IDataQuality.WorkerStatus) public WorkersStatus;
    mapping(uint128 => address[]) public WorkersPerQualityBatch;
    mapping(uint128 => address[]) public WorkersPerRelevanceBatch;
    mapping(uint128 => uint16) public QualityBatchCommitedVoteCount;
    mapping(uint128 => uint16) public QualityBatchRevealedVoteCount;
    mapping(uint128 => uint16) public RelevanceBatchCommitedVoteCount;
    mapping(uint128 => uint16) public RelevanceBatchRevealedVoteCount;
    
    mapping(uint128 => IDataQuality.ProcessMetadata) public ProcessBatchInfo; 
    // ------ Backend Data Stores
    mapping(uint128 => IDataQuality.QualityData) public InputFilesMap; // maps DataID to QualityData struct
    // Validation related events
    event QualityCheckCommitted(uint256 indexed DataBatchId, address indexed sender);
    event QualityCheckRevealed(uint256 indexed DataBatchId, address indexed sender);
    event RelevanceCheckCommitted(uint256 indexed DataBatchId, address indexed sender);
    event RelevanceCheckRevealed(uint256 indexed DataBatchId, address indexed sender);


    // ------ Addresses & Interfaces
    IParametersManager public Parameters;
    /** @notice returns BatchId modulo MAX_INDEX_RANGE_BATCHS
     */
    uint128 CommitBatchCounter = 0;
    uint128 public MAX_INDEX_RANGE_BATCHS = 10000;
    uint128 public MAX_INDEX_RANGE_ITEMS = 10000 * 30;
    uint16 public QUALITY_FILE_SIZE_MIN = 1000;
    
    bool public InstantRevealRewards = true;
    uint16 public InstantRevealRewardsDivider = 1;
    // Constants : DEBUG only
    bool public STAKING_REQUIREMENT_TOGGLE_ENABLED = false;

    function _ModB(uint128 BatchId) private view returns (uint128) {
        return BatchId % MAX_INDEX_RANGE_BATCHS;
    }

    /** @notice returns SpotId modulo MAX_INDEX_RANGE_ITEMS
     */
    function _ModS(uint128 SpotId) private view returns (uint128) {
        return SpotId % MAX_INDEX_RANGE_ITEMS;
    }

    /**
     * @notice Refill the msg.sender with sFuel. Skale gasless "gas station network" equivalent
     */
    function _retrieveSFuel() internal {
        require(
            IParametersManager(address(0)) != Parameters,
            "Parameters Manager must be set."
        );
        address sFuelAddress;
        sFuelAddress = Parameters.getsFuelSystem();
        require(sFuelAddress != address(0), "sFuel: null Address Not Valid");
        (bool success1, ) = sFuelAddress.call(
            abi.encodeWithSignature(
                "retrieveSFuel(address)",
                payable(msg.sender)
            )
        );
        (bool success2, ) = sFuelAddress.call(
            abi.encodeWithSignature(
                "retrieveSFuel(address payable)",
                payable(msg.sender)
            )
        );
        require(
            (success1 || success2),
            "receiver rejected _retrieveSFuel call"
        );
    }
    /**
     * @notice Commits quality-check-vote on a ProcessedBatch
     * @param _DataBatchId ProcessedBatch ID
     * @param quality_signature_hash encrypted hash of the submitted indices and values
     * @param extra_ extra information (for indexing / archival purpose)
     */
    function commitQualityCheck(
        uint128 _DataBatchId,
        bytes32 quality_signature_hash, 
        string memory extra_
    ) public  {
        uint128 effective_batch_id = _ModB(_DataBatchId);
        require(
            IParametersManager(address(0)) != Parameters,
            "Parameters Manager must be set."
        );
        require(
            CommitPeriodActive(_DataBatchId, IWorkerManager.TaskType.Quality),
            "commit period needs to be open for this batchId"
        );
        require(
            !UserQualityVoteSubmission[effective_batch_id][msg.sender].commited,
            "User has already commited to this batchId"
        );
        require(
            workerManager.isWorkerAllocatedToBatch(_DataBatchId, msg.sender, IWorkerManager.TaskType.Quality),
            "User needs to be allocated to this batch to commit on it"
        );
        require(
            Parameters.getAddressManager() != address(0),
            "AddressManager is null in Parameters"
        );

        // ---  Master/SubWorker Stake Management
        //_numTokens The number of tokens to be committed towards the target QualityData
        if (STAKING_REQUIREMENT_TOGGLE_ENABLED) {
            // uint256 _numTokens = Parameters.get_QUALITY_MIN_STAKE();
            // address _selectedAddress = workerManager.SelectAddressForUser(
            //     msg.sender,
            //     _numTokens
            // );
            // if tx sender has a master, then interact with his master's stake, or himself
            // if (SystemStakedTokenBalance[_selectedAddress] < _numTokens) {
            //     uint256 remainder = _numTokens -
            //         SystemStakedTokenBalance[_selectedAddress];
            //     requestAllocatedStake(remainder, _selectedAddress);
            // }
            //// TODO
        }

        // ----------------------- USER STATE UPDATE -----------------------        
        QualityHashes[effective_batch_id][msg.sender] = quality_signature_hash;
        UserQualityVoteSubmission[effective_batch_id][msg.sender].extra = extra_; //1 slot
        QualityBatchCommitedVoteCount[effective_batch_id] += 1;

        // ----------------------- WORKER STATE UPDATE -----------------------
        ProcessBatchInfo[effective_batch_id].uncommited_quality_workers =
            ProcessBatchInfo[effective_batch_id].uncommited_quality_workers -
            1;
        UserQualityVoteSubmission[effective_batch_id][msg.sender].commited = true;

        _retrieveSFuel();
        emit QualityCheckCommitted(_DataBatchId, msg.sender);
    }

    /**
     * @notice Reveals quality-check-vote on a ProcessedBatch
     * @param _DataBatchId ProcessedBatch ID
     * @param clearSubmissions_ clear hash of the submitted IPFS vote
     * @param salt_ arbitraty integer used to hash the previous commit & verify the reveal
     */
    function revealQualityCheck(
        uint64 _DataBatchId,
        uint8[] memory clearIndices_,
        uint8[] memory clearSubmissions_,
        uint128 salt_
    ) public  {
        uint128 effective_batch_id = _ModB(_DataBatchId);
        // Make sure the reveal period is active
        require(
            RevealPeriodActive(effective_batch_id, IWorkerManager.TaskType.Relevance),
            "Reveal period not open for this DataID"
        );
        require(
            workerManager.isWorkerAllocatedToBatch(effective_batch_id, msg.sender, IWorkerManager.TaskType.Quality),
            "User needs to be allocated to this batch to reveal on it"
        );
        require(
            UserRelevanceVoteSubmission[effective_batch_id][msg.sender].commited,
            "User has not commited before, thus can't reveal"
        );
        require(
            !UserRelevanceVoteSubmission[effective_batch_id][msg.sender].revealed,
            "User has already revealed, thus can't reveal"
        );
        // check _encryptedIndices and _encryptedSubmissions are of same length
        require(
            clearIndices_.length == clearSubmissions_.length,
            "clearIndices_ and clearSubmissions_ length mismatch"
        );
        // check if hash(clearIndices_, clearSubmissions_, salt_) == QualityHashes(commited_values)
        require(
            hashing.hashTwoUint8Arrays(clearIndices_, clearSubmissions_, salt_) ==
                QualityHashes[effective_batch_id][msg.sender],
            "hash(clearIndices_, clearSubmissions_, salt_) != QualityHashes(commited_values)"
        );

        // ----------------------- STORE SUBMITTED DATA --------------------
        QualitySubmissions[effective_batch_id][msg.sender].indices = clearIndices_;
        QualitySubmissions[effective_batch_id][msg.sender].statuses = clearSubmissions_;

        // ----------------------- USER/STATS STATE UPDATE -----------------------
        UserRelevanceVoteSubmission[effective_batch_id][msg.sender].revealed = true;
        if (clearSubmissions_.length == 0) {
            UserRelevanceVoteSubmission[effective_batch_id][msg.sender].vote = 0;
        } else {
            UserRelevanceVoteSubmission[effective_batch_id][msg.sender].vote = 1;
        }
        RelevanceBatchRevealedVoteCount[effective_batch_id] += 1;

        // ----------------------- WORKER STATE UPDATE -----------------------
        IWorkerManager.WorkerState memory worker_state = workerManager.getWorkerState(msg.sender);
        ProcessBatchInfo[effective_batch_id].unrevealed_quality_workers =
            ProcessBatchInfo[effective_batch_id].unrevealed_quality_workers -
            1;

        worker_state.last_interaction_date = uint64(block.timestamp);

        if (worker_state.registered) {
            workerManager.SwapFromBusyToAvailableWorkers(msg.sender);
        }

        if (InstantRevealRewards) {
            address reveal_author_ = msg.sender;
            IAddressManager _AddressManager = IAddressManager(
                Parameters.getAddressManager()
            );
            IRepManager _RepManager = IRepManager(Parameters.getRepManager());
            IRewardManager _RewardManager = IRewardManager(
                Parameters.getRewardManager()
            );
            address reveal_author_master_ = _AddressManager.FetchHighestMaster(
                reveal_author_
            );
            uint256 repAmount = (Parameters
                .get_QUALITY_MIN_REP_DataValidation() * QUALITY_FILE_SIZE_MIN) /
                InstantRevealRewardsDivider;
            uint256 rewardAmount = (Parameters
                .get_QUALITY_MIN_REWARD_DataValidation() *
                QUALITY_FILE_SIZE_MIN) / InstantRevealRewardsDivider;
            require(
                _RepManager.mintReputationForWork(
                    repAmount,
                    reveal_author_master_,
                    ""
                ),
                "could not reward REP in revealQualityCheck, 1.a"
            );
            require(
                _RewardManager.ProxyAddReward(
                    rewardAmount,
                    reveal_author_master_
                ),
                "could not reward token in revealQualityCheck, 1.b"
            );
        }

        _retrieveSFuel();
        emit QualityCheckRevealed(_DataBatchId, msg.sender);
    }

    /////////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////         Relevance Check      ////////////////////////////
    /////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Commits Relevance-check-vote on a ProcessedBatch
     * @param _DataBatchId ProcessedBatch ID
     * @param counts_signature_hash encrypted hash of the list of indices, values (and salt)
     * @param bounties_signature_hash encrypted hash of the list of indices, values (and salt)
     * @param duplicates_signature_hash encrypted hash of the list of indices, values (and salt)
     * @param _BatchCount Batch Count in number of items (in the aggregated IPFS hash)
     * @param extra_ extra information (for indexing / archival purpose)
     */
    function commitRelevanceCheck(
        uint128 _DataBatchId,
        bytes32 counts_signature_hash,
        bytes32 bounties_signature_hash,
        bytes32 duplicates_signature_hash, 
        uint32 _BatchCount,
        string memory extra_
    ) public  {        
        uint128 effective_batch_id = _ModB(_DataBatchId);
        require(
            IParametersManager(address(0)) != Parameters,
            "Parameters Manager must be set."
        );
        require(
            CommitPeriodActive(effective_batch_id, IWorkerManager.TaskType.Quality),
            "commit period needs to be open for this batchId"
        );
        require(
            !UserRelevanceVoteSubmission[effective_batch_id][msg.sender].commited,
            "User has already commited to this batchId"
        );
        require(
            workerManager.isWorkerAllocatedToBatch(effective_batch_id, msg.sender, IWorkerManager.TaskType.Relevance),
            "User needs to be allocated to this batch to commit on it"
        );

        // ---  Master/SubWorker Stake Management
        //_numTokens The number of tokens to be committed towards the target QualityData
        if (STAKING_REQUIREMENT_TOGGLE_ENABLED) {
            // uint256 _numTokens = Parameters.get_QUALITY_MIN_STAKE();
            // address _selectedAddress = workerManager.SelectAddressForUser(
            //     msg.sender,
            //     _numTokens
            // );
            // if tx sender has a master, then interact with his master's stake, or himself
            // if (SystemStakedTokenBalance[_selectedAddress] < _numTokens) {
            //     uint256 remainder = _numTokens -
            //         SystemStakedTokenBalance[_selectedAddress];
            //     requestAllocatedStake(remainder, _selectedAddress);
            // }
            // TODO
        }
        // ----------------------- STORE HASHES  -----------------------
        // Store encrypted hash for the 3 arrays
        UserEncryptedBaseCounts[effective_batch_id][msg.sender] = counts_signature_hash;
        UserEncryptedBountiesCounts[effective_batch_id][msg.sender] = bounties_signature_hash;
        UserEncryptedDuplicates[effective_batch_id][msg.sender] = duplicates_signature_hash;
        
        // ----------------------- USER STATE UPDATE -----------------------
        UserRelevanceVoteSubmission[effective_batch_id][msg.sender]
            .batchCount = _BatchCount; //1 slot
        UserRelevanceVoteSubmission[effective_batch_id][msg.sender].extra = extra_; //1 slot
        RelevanceBatchCommitedVoteCount[effective_batch_id] += 1;

        // ----------------------- WORKER STATE UPDATE -----------------------
        ProcessBatchInfo[effective_batch_id].uncommited_quality_workers =
            ProcessBatchInfo[effective_batch_id].uncommited_quality_workers -
            1;
        UserRelevanceVoteSubmission[effective_batch_id][msg.sender].commited = true;

        _retrieveSFuel();
        emit RelevanceCheckCommitted(effective_batch_id, msg.sender);
    }

    /**
     * @notice Reveals quality-check-vote on a ProcessedBatch
     * @param _DataBatchId ProcessedBatch ID
     * @param base_counts_indices_ list of uint8 representing base count indices
     * @param base_counts_values_ list of uint8 representing base count values
     * @param bounties_counts_indices_ list of uint8 representing bounties count indices
     * @param bounties_counts_values_ list of uint8 representing bounties count values
     * @param duplicates_counts_indices_ list of uint8 representing duplicate count indices
     * @param duplicates_counts_values_ list of uint8 representing base count values
     * @param salt_ arbitraty integer used to hash the previous commit & verify the reveal
     */
    function revealRelevanceCheck(
        uint64 _DataBatchId,
        uint8[] memory base_counts_indices_,
        uint8[] memory base_counts_values_,
        uint8[] memory bounties_counts_indices_,
        uint8[] memory bounties_counts_values_,
        uint8[] memory duplicates_counts_indices_,
        uint8[] memory duplicates_counts_values_,
        uint128 salt_
    ) public  {
        uint128 effective_batch_id = _ModB(_DataBatchId);
        // Make sure the reveal period is active
        require(
            RevealPeriodActive(effective_batch_id, IWorkerManager.TaskType.Relevance),
            "Reveal period not open for this DataID"
        );
        require(
            workerManager.isWorkerAllocatedToBatch(effective_batch_id, msg.sender, IWorkerManager.TaskType.Relevance),
            "User needs to be allocated to this batch to reveal on it"
        );
        require(
            UserRelevanceVoteSubmission[effective_batch_id][msg.sender].commited,
            "User has not commited before, thus can't reveal"
        );
        require(
            !UserRelevanceVoteSubmission[effective_batch_id][msg.sender].revealed,
            "User has already revealed, thus can't reveal"
        );
        // check countsclearIndices_ and counts_clearValues are of same length
        require(
            base_counts_indices_.length == base_counts_values_.length,
            "countsclearIndices_ length mismatch"
        );
        // check bountiesclearIndices_ and bounties_clearValues are of same length
        require(
            bounties_counts_indices_.length == bounties_counts_values_.length,
            "bountiesclearIndices_ length mismatch"
        );
        // check duplicatesclearIndices_ and duplicates_clearValues are of same length
        require(
            duplicates_counts_indices_.length == duplicates_counts_values_.length,
            "duplicatesclearIndices_ length mismatch"
        );
        // Handling Counts
        require(
            hashing.hashTwoUint8Arrays(base_counts_indices_, base_counts_values_, salt_) ==
                UserEncryptedBaseCounts[effective_batch_id][msg.sender],
            "Base arrays don't match the previously commited hash"
        );
        // Handling Bounties
        require(
            hashing.hashTwoUint8Arrays(base_counts_indices_, bounties_counts_values_, salt_) ==
                UserEncryptedBountiesCounts[effective_batch_id][msg.sender],
            "Bounties arrays don't match the previously commited hash"
        );
        // Handling Duplicates counts
        require(
            hashing.hashTwoUint8Arrays(duplicates_counts_indices_, duplicates_counts_values_, salt_) ==
                UserEncryptedDuplicates[effective_batch_id][msg.sender],
            "Duplicate arrays don't match the previously commited hash"
        );

        // ----------------------- STORE THE SUBMITTED VALUES  -----------------------
        // Store encrypted hash for the 3 arrays

        // ----------------------- USER STATE UPDATE -----------------------
        UserRelevanceVoteSubmission[effective_batch_id][msg.sender].revealed = true;
        UserRelevanceVoteSubmission[effective_batch_id][msg.sender].vote = 1;
        RelevanceBatchRevealedVoteCount[effective_batch_id] += 1;

        // ----------------------- WORKER STATE UPDATE -----------------------
        IWorkerManager.WorkerState memory worker_state = workerManager.getWorkerState(msg.sender);
        ProcessBatchInfo[effective_batch_id].unrevealed_quality_workers =
            ProcessBatchInfo[effective_batch_id].unrevealed_quality_workers -
            1;

        worker_state.last_interaction_date = uint64(block.timestamp);

        if (worker_state.registered) {
            workerManager.SwapFromBusyToAvailableWorkers(msg.sender);
        }

        if (InstantRevealRewards) {
            address reveal_author_ = msg.sender;
            IAddressManager _AddressManager = IAddressManager(
                Parameters.getAddressManager()
            );
            IRepManager _RepManager = IRepManager(Parameters.getRepManager());
            IRewardManager _RewardManager = IRewardManager(
                Parameters.getRewardManager()
            );
            address reveal_author_master_ = _AddressManager.FetchHighestMaster(
                reveal_author_
            );
            uint256 repAmount = (Parameters
                .get_QUALITY_MIN_REP_DataValidation() * QUALITY_FILE_SIZE_MIN) /
                InstantRevealRewardsDivider;
            uint256 rewardAmount = (Parameters
                .get_QUALITY_MIN_REWARD_DataValidation() *
                QUALITY_FILE_SIZE_MIN) / InstantRevealRewardsDivider;
            require(
                _RepManager.mintReputationForWork(
                    repAmount,
                    reveal_author_master_,
                    ""
                ),
                "could not reward REP in revealQualityCheck, 1.a"
            );
            require(
                _RewardManager.ProxyAddReward(
                    rewardAmount,
                    reveal_author_master_
                ),
                "could not reward token in revealQualityCheck, 1.b"
            );
        }

        _retrieveSFuel();
        emit RelevanceCheckRevealed(effective_batch_id, msg.sender);
    }


    /**
     * @dev Checks if a QualityData exists
     * @param _DataBatchId The DataID whose existance is to be evaluated.
     * @return exists Boolean Indicates whether a QualityData exists for the provided DataID
     */
    function DataExists(uint128 _DataBatchId)
        public
        view
        returns (bool exists)
    {
        return CommitBatchCounter > _DataBatchId;
    }


    /**
     * @notice Determines DataCommitEndDate
     * @return commitEndDate indication of whether Dataing period is over
     */
    function DataCommitEndDate(uint128 _DataBatchId, IWorkerManager.TaskType taskType)
        public
        view
        returns (uint256 commitEndDate)
    {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");
        if (taskType == IWorkerManager.TaskType.Quality) {
            return ProcessBatchInfo[_ModB(_DataBatchId)].quality_commitEndDate;
        } else if (taskType == IWorkerManager.TaskType.Relevance) {
            return ProcessBatchInfo[_ModB(_DataBatchId)].relevance_commitEndDate;
        }
    }

    /**
     * @notice Determines DataRevealEndDate
     * @return revealEndDate indication of whether Dataing period is over
     */
    function DataRevealEndDate(uint128 _DataBatchId, IWorkerManager.TaskType taskType)
        public
        view
        returns (uint256 revealEndDate)
    {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");

        if (taskType == IWorkerManager.TaskType.Quality) {
            return ProcessBatchInfo[_ModB(_DataBatchId)].quality_revealEndDate;
        } else if (taskType == IWorkerManager.TaskType.Relevance) {
            return ProcessBatchInfo[_ModB(_DataBatchId)].relevance_revealEndDate;
        }
    }

    /**
     * @notice Checks if the commit period is still active for the specified QualityData
     * @dev Checks isExpired for the specified QualityData's commitEndDate
     * @param _DataBatchId Integer identifier associated with target QualityData
     * @return active Boolean indication of isCommitPeriodActive for target QualityData
     */
    function CommitPeriodActive(uint128 _DataBatchId, IWorkerManager.TaskType taskType)
        public
        view
        returns (bool active)
    {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");

        if (taskType == IWorkerManager.TaskType.Quality) {
            return
                !isExpired(ProcessBatchInfo[_ModB(_DataBatchId)].quality_commitEndDate) &&
                (ProcessBatchInfo[_ModB(_DataBatchId)].uncommited_quality_workers > 0);
        } else if (taskType == IWorkerManager.TaskType.Relevance) {
            return
                !isExpired(ProcessBatchInfo[_ModB(_DataBatchId)].relevance_commitEndDate) &&
                (ProcessBatchInfo[_ModB(_DataBatchId)].uncommited_relevance_workers > 0);
        }
    }

    /**
     * @notice Checks if the commit period is over
     * @dev Checks isExpired for the specified QualityData's commitEndDate
     * @param _DataBatchId Integer identifier associated with target QualityData
     * @return active Boolean indication of isCommitPeriodOver for target QualityData
     */
    function CommitPeriodOver(uint128 _DataBatchId, IWorkerManager.TaskType taskType)
        public
        view
        returns (bool active)
    {
        if (!DataExists(_DataBatchId)) {
            return false;
        } else {
            // a commitPeriod is over if time has expired OR if revealPeriod for the same _DataBatchId is true
            
            if (taskType == IWorkerManager.TaskType.Quality) {
                return
                    isExpired(ProcessBatchInfo[_ModB(_DataBatchId)].quality_commitEndDate) ||
                    RevealPeriodActive(_DataBatchId, taskType);
            } else if (taskType == IWorkerManager.TaskType.Relevance) {
                return
                    isExpired(ProcessBatchInfo[_ModB(_DataBatchId)].relevance_commitEndDate) ||
                    RevealPeriodActive(_DataBatchId, taskType);
            }
        }
    }

    /**
     * @notice Checks if the commit period is still active for the specified QualityData
     * @dev Checks isExpired for the specified QualityData's commitEndDate
     * @param _DataBatchId Integer identifier associated with target QualityData
     * @return remainingTime Integer
     */
    function remainingCommitDuration(uint128 _DataBatchId, IWorkerManager.TaskType taskType)
        public
        view
        returns (uint256 remainingTime)
    {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");
        uint64 _remainingTime = 0;
        if (CommitPeriodActive(_DataBatchId, taskType)) {
            if(taskType == IWorkerManager.TaskType.Quality) {
                _remainingTime =
                    ProcessBatchInfo[_ModB(_DataBatchId)].quality_commitEndDate -
                    uint64(block.timestamp);
            } else if(taskType == IWorkerManager.TaskType.Relevance) {
                _remainingTime =
                    ProcessBatchInfo[_ModB(_DataBatchId)].relevance_commitEndDate -
                    uint64(block.timestamp);
            }
        }
        return _remainingTime;
    }

    /**
     * @notice Checks if the reveal period is still active for the specified QualityData
     * @dev Checks isExpired for the specified QualityData's revealEndDate
     * @param _DataBatchId Integer identifier associated with target QualityData
     */
    function RevealPeriodActive(uint128 _DataBatchId, IWorkerManager.TaskType taskType)
        public
        view
        returns (bool active)
    {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");

        if(taskType == IWorkerManager.TaskType.Quality) {
            return
                !isExpired(ProcessBatchInfo[_ModB(_DataBatchId)].quality_revealEndDate) &&
                !CommitPeriodActive(_DataBatchId, taskType);
        } else if(taskType == IWorkerManager.TaskType.Relevance) {
            return
                !isExpired(ProcessBatchInfo[_ModB(_DataBatchId)].relevance_revealEndDate) &&
                !CommitPeriodActive(_DataBatchId, taskType);
        }
    }

    /**
     * @notice Checks if the reveal period is over
     * @dev Checks isExpired for the specified QualityData's revealEndDate
     * @param _DataBatchId Integer identifier associated with target QualityData
     */
    function RevealPeriodOver(uint128 _DataBatchId, IWorkerManager.TaskType taskType)
        public
        view
        returns (bool active)
    {
        if (!DataExists(_DataBatchId)) {
            return false;
        } else {
            
            if(taskType == IWorkerManager.TaskType.Quality) {
                // a commitPeriod is Over if : time has expired OR if revealPeriod for the same _DataBatchId is true
                return
                    isExpired(ProcessBatchInfo[_ModB(_DataBatchId)].quality_revealEndDate) ||
                    ProcessBatchInfo[_ModB(_DataBatchId)].unrevealed_quality_workers == 0;
            } else if(taskType == IWorkerManager.TaskType.Relevance) {
                // a commitPeriod is Over if : time has expired OR if revealPeriod for the same _DataBatchId is true
                return
                    isExpired(ProcessBatchInfo[_ModB(_DataBatchId)].relevance_revealEndDate) ||
                    ProcessBatchInfo[_ModB(_DataBatchId)].unrevealed_relevance_workers == 0;
            }
        }
    }

    /**
     * @notice Checks if the commit period is still active for the specified QualityData
     * @dev Checks isExpired for the specified QualityData's commitEndDate
     * @param _DataBatchId Integer identifier associated with target QualityData
     * @return remainingTime Integer indication of isQualityCommitPeriodActive for target QualityData
     */
    function RemainingRevealDuration(uint128 _DataBatchId, IWorkerManager.TaskType taskType)
        public
        view
        returns (uint256 remainingTime)
    {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");
        uint256 _remainingTime = 0;
        if(taskType == IWorkerManager.TaskType.Quality) {
            if (RevealPeriodActive(_DataBatchId, taskType)) {
                _remainingTime =
                    ProcessBatchInfo[_ModB(_DataBatchId)].quality_revealEndDate -
                    block.timestamp;
            }
        } else if(taskType == IWorkerManager.TaskType.Relevance) {
            if (RevealPeriodActive(_DataBatchId, taskType)) {
                _remainingTime =
                    ProcessBatchInfo[_ModB(_DataBatchId)].relevance_revealEndDate -
                    block.timestamp;
            }
        }
        return _remainingTime;
    }

    /**
     * @dev Checks if user has committed for specified QualityData
     * @param _voter Address of user to check against
     * @param _DataBatchId Integer identifier associated with target QualityData
     * @return committed Boolean indication of whether user has committed
     */
    function didCommit(address _voter, uint128 _DataBatchId, IWorkerManager.TaskType taskType)
        public
        view
        returns (bool committed)
    {
        if (taskType == IWorkerManager.TaskType.Quality) {
            return UserQualityVoteSubmission[_ModB(_DataBatchId)][_voter].commited;
        } else if (taskType == IWorkerManager.TaskType.Relevance) {
            return UserRelevanceVoteSubmission[_ModB(_DataBatchId)][_voter].commited;
        }
    }

    /**
     * @dev Checks if user has revealed for specified QualityData
     * @param _voter Address of user to check against
     * @param _DataBatchId Integer identifier associated with target QualityData
     * @return revealed Boolean indication of whether user has revealed
     */
    function didReveal(address _voter, uint128 _DataBatchId, IWorkerManager.TaskType taskType)
        public
        view
        returns (bool revealed)
    {
        if (taskType == IWorkerManager.TaskType.Quality) {
            return UserQualityVoteSubmission[_ModB(_DataBatchId)][_voter].revealed;
        } else if (taskType == IWorkerManager.TaskType.Relevance) {
            return UserRelevanceVoteSubmission[_ModB(_DataBatchId)][_voter].revealed;
        }
    }

    /**
     * @notice Determines if QualityData is over
     * @dev Checks isExpired for specified QualityData's revealEndDate
     * @return ended Boolean indication of whether Dataing period is over
     */
    function DataEnded(uint128 _DataBatchId, IWorkerManager.TaskType taskType) public view returns (bool ended) {
        if(taskType == IWorkerManager.TaskType.Quality) {
            return isExpired(ProcessBatchInfo[_ModB(_DataBatchId)].quality_revealEndDate) ||
            (CommitPeriodOver(_DataBatchId, taskType) &&
                QualityBatchCommitedVoteCount[_ModB(_DataBatchId)] == 0);
        } else if(taskType == IWorkerManager.TaskType.Relevance) {
            return isExpired(ProcessBatchInfo[_ModB(_DataBatchId)].relevance_revealEndDate) ||
            (CommitPeriodOver(_DataBatchId, taskType) &&
                RelevanceBatchCommitedVoteCount[_ModB(_DataBatchId)] == 0);
        }
    }
    
    /**
     * @dev Checks if an expiration date has been reached
     * @param _terminationDate Integer timestamp of date to compare current timestamp with
     * @return expired Boolean indication of whether the terminationDate has passed
     */
    function isExpired(uint256 _terminationDate)
        public
        view
        returns (bool expired)
    {
        return (block.timestamp > _terminationDate);
    }

}