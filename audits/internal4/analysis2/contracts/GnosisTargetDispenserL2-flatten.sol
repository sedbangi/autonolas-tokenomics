// Sources flattened with hardhat v2.17.1 https://hardhat.org

// SPDX-License-Identifier: MIT

// File contracts/interfaces/IBridgeErrors.sol

// Original license: SPDX_License_Identifier: MIT
pragma solidity ^0.8.25;

interface IBridgeErrors {
    /// @dev Only `manager` has a privilege, but the `sender` was provided.
    /// @param sender Sender address.
    /// @param manager Required sender address as a manager.
    error ManagerOnly(address sender, address manager);

    /// @dev Only `owner` has a privilege, but the `sender` was provided.
    /// @param sender Sender address.
    /// @param owner Required sender address as an owner.
    error OwnerOnly(address sender, address owner);

    /// @dev Provided zero address.
    error ZeroAddress();

    /// @dev Zero value when it has to be different from zero.
    error ZeroValue();

    /// @dev Provided incorrect data length.
    /// @param expected Expected minimum data length.
    /// @param provided Provided data length.
    error IncorrectDataLength(uint256 expected, uint256 provided);

    /// @dev Received lower value than the expected one.
    /// @param provided Provided value is lower.
    /// @param expected Expected value.
    error LowerThan(uint256 provided, uint256 expected);

    /// @dev Value overflow.
    /// @param provided Overflow value.
    /// @param max Maximum possible value.
    error Overflow(uint256 provided, uint256 max);

    /// @dev Target bridge relayer is incorrect.
    /// @param provided Provided relayer address.
    /// @param expected Expected relayer address.
    error TargetRelayerOnly(address provided, address expected);

    /// @dev Message sender from another chain is incorrect.
    /// @param provided Provided message sender address.
    /// @param expected Expected message sender address.
    error WrongMessageSender(address provided, address expected);

    /// @dev Chain Id originating the call is incorrect.
    /// @param provided Provided chain Id.
    /// @param expected Expected chain Id.
    error WrongChainId(uint256 provided, uint256 expected);

    /// @dev Target and its corresponding amount are not found in the queue.
    /// @param target Target address.
    /// @param amount Token amount.
    /// @param batchNonce Reference batch nonce.
    error TargetAmountNotQueued(address target, uint256 amount, uint256 batchNonce);

    /// @dev Insufficient token balance.
    /// @param provided Provided balance.
    /// @param expected Expected available amount.
    error InsufficientBalance(uint256 provided, uint256 expected);

    /// @dev Failure of a transfer.
    /// @param token Address of a token.
    /// @param from Address `from`.
    /// @param to Address `to`.
    /// @param amount Token amount.
    error TransferFailed(address token, address from, address to, uint256 amount);

    /// @dev Delivery hash has been already processed.
    /// @param deliveryHash Delivery hash.
    error AlreadyDelivered(bytes32 deliveryHash);

    /// @dev Wrong amount received / provided.
    /// @param provided Provided amount.
    /// @param expected Expected amount.
    error WrongAmount(uint256 provided, uint256 expected);

    /// @dev Provided token address is incorrect.
    /// @param provided Provided token address.
    /// @param expected Expected token address.
    error WrongTokenAddress(address provided, address expected);

    /// @dev The contract is paused.
    error Paused();

    /// @dev The contract is unpaused.
    error Unpaused();

    // @dev Reentrancy guard.
    error ReentrancyGuard();

    /// @dev Account address is incorrect.
    /// @param account Account address.
    error WrongAccount(address account);
}

// File contracts/staking/DefaultTargetDispenserL2.sol
// Staking interface
interface IStaking {
    /// @dev Deposits OLAS tokens to the staking contract.
    /// @param amount OLAS amount.
    function deposit(uint256 amount) external;
}

// Staking factory interface
interface IStakingFactory {
    /// @dev Verifies staking proxy instance and gets emissions amount.
    /// @param instance Staking proxy instance.
    /// @return amount Emissions amount.
    function verifyInstanceAndGetEmissionsAmount(address instance) external view returns (uint256 amount);
}

// Necessary ERC20 token interface
interface IToken {
    /// @dev Gets the amount of tokens owned by a specified account.
    /// @param account Account address.
    /// @return Amount of tokens owned.
    function balanceOf(address account) external view returns (uint256);

    /// @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
    /// @param spender Account address that will be able to transfer tokens on behalf of the caller.
    /// @param amount Token amount.
    /// @return True if the function execution is successful.
    function approve(address spender, uint256 amount) external returns (bool);

    /// @dev Transfers the token amount.
    /// @param to Address to transfer to.
    /// @param amount The amount to transfer.
    /// @return True if the function execution is successful.
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title DefaultTargetDispenserL2 - Smart contract for processing tokens and data received on L2, and data sent back to L1.
/// @author Aleksandr Kuperman - <aleksandr.kuperman@valory.xyz>
/// @author Andrey Lebedev - <andrey.lebedev@valory.xyz>
/// @author Mariapia Moscatiello - <mariapia.moscatiello@valory.xyz>
abstract contract DefaultTargetDispenserL2 is IBridgeErrors {
    event OwnerUpdated(address indexed owner);
    event FundsReceived(address indexed sender, uint256 value);
    event StakingTargetDeposited(address indexed target, uint256 amount);
    event AmountWithheld(address indexed target, uint256 amount);
    event StakingRequestQueued(bytes32 indexed queueHash, address indexed target, uint256 amount,
        uint256 batchNonce, uint256 paused);
    event MessagePosted(uint256 indexed sequence, address indexed messageSender, address indexed l1Processor,
        uint256 amount);
    event MessageReceived(address indexed sender, uint256 chainId, bytes data);
    event WithheldAmountSynced(address indexed sender, uint256 amount);
    event Drain(address indexed owner, uint256 amount);
    event TargetDispenserPaused();
    event TargetDispenserUnpaused();
    event Migrated(address indexed sender, address indexed newL2TargetDispenser, uint256 amount);

    // receiveMessage selector (Ethereum chain)
    bytes4 public constant RECEIVE_MESSAGE = bytes4(keccak256(bytes("receiveMessage(bytes)")));
    // Maximum chain Id as per EVM specs
    uint256 public constant MAX_CHAIN_ID = type(uint64).max / 2 - 36;
    // Gas limit for sending a message to L1
    // This is safe as the value is approximately 3 times bigger than observed ones on numerous chains
    uint256 public constant GAS_LIMIT = 300_000;
    // OLAS address
    address public immutable olas;
    // Staking proxy factory address
    address public immutable stakingFactory;
    // L2 Relayer address that receives the message across the bridge from the source L1 network
    address public immutable l2MessageRelayer;
    // Deposit processor address on L1 that is authorized to propagate the transaction execution across the bridge
    address public immutable l1DepositProcessor;
    // Deposit processor chain Id
    uint256 public immutable l1SourceChainId;
    // Amount of OLAS withheld due to service staking target invalidity
    uint256 public withheldAmount;
    // Nonce for each staking batch
    uint256 public stakingBatchNonce;
    // Owner address (Timelock or bridge mediator)
    address public owner;
    // Pause switcher
    uint8 public paused;
    // Reentrancy lock
    uint8 internal _locked;

    // Queueing hashes of (target, amount, stakingBatchNonce)
    mapping(bytes32 => bool) public stakingQueueingNonces;

    /// @dev DefaultTargetDispenserL2 constructor.
    /// @param _olas OLAS token address on L2.
    /// @param _stakingFactory Service staking proxy factory address.
    /// @param _l2MessageRelayer L2 message relayer bridging contract address.
    /// @param _l1DepositProcessor L1 deposit processor address.
    /// @param _l1SourceChainId L1 source chain Id.
    constructor(
        address _olas,
        address _stakingFactory,
        address _l2MessageRelayer,
        address _l1DepositProcessor,
        uint256 _l1SourceChainId
    ) {
        // Check for zero addresses
        if (_olas == address(0) || _stakingFactory == address(0) || _l2MessageRelayer == address(0)
            || _l1DepositProcessor == address(0)) {
            revert ZeroAddress();
        }

        // Check for a zero value
        if (_l1SourceChainId == 0) {
            revert ZeroValue();
        }

        // Check for overflow value
        if (_l1SourceChainId > MAX_CHAIN_ID) {
            revert Overflow(_l1SourceChainId, MAX_CHAIN_ID);
        }

        // Immutable parameters assignment
        olas = _olas;
        stakingFactory = _stakingFactory;
        l2MessageRelayer = _l2MessageRelayer;
        l1DepositProcessor = _l1DepositProcessor;
        l1SourceChainId = _l1SourceChainId;

        // State variables assignment
        owner = msg.sender;
        paused = 1;
        _locked = 1;
    }

    /// @dev Processes the data received from L1.
    /// @param data Bytes message data sent from L1.
    function _processData(bytes memory data) internal {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Decode received data
        (address[] memory targets, uint256[] memory amounts) = abi.decode(data, (address[], uint256[]));

        uint256 batchNonce = stakingBatchNonce;
        uint256 localWithheldAmount = 0;
        uint256 localPaused = paused;

        // Traverse all the targets
        for (uint256 i = 0; i < targets.length; ++i) {
            address target = targets[i];
            uint256 amount = amounts[i];

            // Check the target validity address and staking parameters, and get emissions amount
            // This is a low level call since it must never revert
            bytes memory verifyData = abi.encodeCall(IStakingFactory.verifyInstanceAndGetEmissionsAmount, target);
            (bool success, bytes memory returnData) = stakingFactory.call(verifyData);

            uint256 limitAmount;
            // If the function call was successful, check the return value
            if (success && returnData.length == 32) {
                limitAmount = abi.decode(returnData, (uint256));
            }

            // If the limit amount is zero, withhold OLAS amount and continue
            if (limitAmount == 0) {
                // Withhold OLAS for further usage
                localWithheldAmount += amount;
                emit AmountWithheld(target, amount);

                // Proceed to the next target
                continue;
            }

            // Check the amount limit and adjust, if necessary
            if (amount > limitAmount) {
                uint256 targetWithheldAmount = amount - limitAmount;
                localWithheldAmount += targetWithheldAmount;
                amount = limitAmount;

                emit AmountWithheld(target, targetWithheldAmount);
            }

            // Check the OLAS balance and the contract being unpaused
            if (IToken(olas).balanceOf(address(this)) >= amount && localPaused == 1) {
                // Approve and transfer OLAS to the service staking target
                IToken(olas).approve(target, amount);
                IStaking(target).deposit(amount);

                emit StakingTargetDeposited(target, amount);
            } else {
                // Hash of target + amount + batchNonce
                bytes32 queueHash = keccak256(abi.encode(target, amount, batchNonce));
                // Queue the hash for further redeem
                stakingQueueingNonces[queueHash] = true;

                emit StakingRequestQueued(queueHash, target, amount, batchNonce, localPaused);
            }
        }
        // Increase the staking batch nonce
        stakingBatchNonce = batchNonce + 1;

        // Adjust withheld amount, if at least one target has not passed the validity check
        if (localWithheldAmount > 0) {
            withheldAmount += localWithheldAmount;
        }

        _locked = 1;
    }

    /// @dev Sends message to L1 to sync the withheld amount.
    /// @param amount Amount to sync.
    /// @param bridgePayload Payload data for the bridge relayer.
    function _sendMessage(uint256 amount, bytes memory bridgePayload) internal virtual;

    /// @dev Receives a message from L1.
    /// @param messageRelayer L2 bridge message relayer address.
    /// @param sourceProcessor L1 deposit processor address.
    /// @param data Bytes message data sent from L1.
    function _receiveMessage(
        address messageRelayer,
        address sourceProcessor,
        bytes memory data
    ) internal virtual {
        // Check L2 message relayer address
        if (messageRelayer != l2MessageRelayer) {
            revert TargetRelayerOnly(messageRelayer, l2MessageRelayer);
        }

        // Check L1 deposit processor address
        if (sourceProcessor != l1DepositProcessor) {
            revert WrongMessageSender(sourceProcessor, l1DepositProcessor);
        }

        emit MessageReceived(l1DepositProcessor, l1SourceChainId, data);

        // Process the data
        _processData(data);
    }

    /// @dev Changes the owner address.
    /// @param newOwner Address of a new owner.
    function changeOwner(address newOwner) external {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for the zero address
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }

        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    /// @dev Redeems queued staking incentive.
    /// @param target Staking target address.
    /// @param amount Staking incentive amount.
    /// @param batchNonce Batch nonce.
    function redeem(address target, uint256 amount, uint256 batchNonce) external {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Pause check
        if (paused == 2) {
            revert Paused();
        }

        // Hash of target + amount + batchNonce
        bytes32 queueHash = keccak256(abi.encode(target, amount, batchNonce));
        bool queued = stakingQueueingNonces[queueHash];
        // Check if the target and amount are queued
        if (!queued) {
            revert TargetAmountNotQueued(target, amount, batchNonce);
        }

        // Get the current contract OLAS balance
        uint256 olasBalance = IToken(olas).balanceOf(address(this));
        if (olasBalance >= amount) {
            // Approve and transfer OLAS to the service staking target
            IToken(olas).approve(target, amount);
            IStaking(target).deposit(amount);

            emit StakingTargetDeposited(target, amount);

            // Remove processed queued nonce
            stakingQueueingNonces[queueHash] = false;
        } else {
            // OLAS balance is not enough for redeem
            revert InsufficientBalance(olasBalance, amount);
        }

        _locked = 1;
    }

    /// @dev Processes the data manually provided by the DAO in order to restore the data that was not delivered from L1.
    /// @notice Here are possible bridge failure scenarios and the way to act via the DAO vote:
    ///         - Both token and message delivery fails: re-send OLAS to the contract (separate vote), call this function;
    ///         - Token transfer succeeds, message fails: call this function;
    ///         - Token transfer fails, message succeeds: re-send OLAS to the contract (separate vote).
    /// @param data Bytes message data that was not delivered from L1.
    function processDataMaintenance(bytes memory data) external {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Process the data
        _processData(data);
    }

    /// @dev Syncs withheld token amount with L1.
    /// @param bridgePayload Payload data for the bridge relayer.
    function syncWithheldTokens(bytes memory bridgePayload) external payable {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Pause check
        if (paused == 2) {
            revert Paused();
        }

        // Check the withheld amount to be greater than zero
        uint256 amount = withheldAmount;
        if (amount == 0) {
            revert ZeroValue();
        }

        // Zero the withheld amount
        withheldAmount = 0;

        // Send a message to sync the withheld amount
        _sendMessage(amount, bridgePayload);

        emit WithheldAmountSynced(msg.sender, amount);

        _locked = 1;
    }

    /// @dev Pause the contract.
    function pause() external {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        paused = 2;
        emit TargetDispenserPaused();
    }

    /// @dev Unpause the contract
    function unpause() external {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        paused = 1;
        emit TargetDispenserUnpaused();
    }

    /// @dev Drains contract native funds.
    /// @notice For cross-bridge leftovers and incorrectly sent funds.
    /// @return amount Drained amount to the owner address.
    function drain() external returns (uint256 amount) {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check for the owner address
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Drain the slashed funds
        amount = address(this).balance;
        if (amount == 0) {
            revert ZeroValue();
        }

        // Send funds to the owner
        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) {
            revert TransferFailed(address(0), address(this), msg.sender, amount);
        }

        emit Drain(msg.sender, amount);

        _locked = 1;
    }

    /// @dev Migrates funds to a new specified L2 target dispenser contract address.
    /// @notice The contract must be paused to prevent other interactions.
    ///         The owner is be zeroed, the contract becomes paused and in the reentrancy state for good.
    ///         No further write interaction with the contract is going to be possible.
    ///         If the withheld amount is nonzero, it is regulated by the DAO directly on the L1 side.
    ///         If there are outstanding queued requests, they are processed by the DAO directly on the L2 side.
    function migrate(address newL2TargetDispenser) external {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check for the owner address
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check that the contract is paused
        if (paused == 1) {
            revert Unpaused();
        }

        // Check that the migration address is a contract
        if (newL2TargetDispenser.code.length == 0) {
            revert WrongAccount(newL2TargetDispenser);
        }

        // Check that the new address is not the current one
        if (newL2TargetDispenser == address(this)) {
            revert WrongAccount(address(this));
        }

        // Get OLAS token amount
        uint256 amount = IToken(olas).balanceOf(address(this));
        // Transfer amount to the new L2 target dispenser
        if (amount > 0) {
            bool success = IToken(olas).transfer(newL2TargetDispenser, amount);
            if (!success) {
                revert TransferFailed(olas, address(this), newL2TargetDispenser, amount);
            }
        }

        // Zero the owner
        owner = address(0);

        emit Migrated(msg.sender, newL2TargetDispenser, amount);

        // _locked is now set to 2 for good
    }

    /// @dev Receives native network token.
    receive() external payable {
        emit FundsReceived(msg.sender, msg.value);
    }
}


// File contracts/staking/GnosisTargetDispenserL2.sol
interface IBridge {
    // Contract: AMB Contract Proxy Home
    // Source: https://github.com/omni/tokenbridge-contracts/blob/908a48107919d4ab127f9af07d44d47eac91547e/contracts/upgradeable_contracts/arbitrary_message/MessageDelivery.sol#L22
    // Doc: https://docs.gnosischain.com/bridges/Token%20Bridge/amb-bridge
    /// @dev Requests message relay to the opposite network
    /// @param target Executor address on the other side.
    /// @param data Calldata passed to the executor on the other side.
    /// @param maxGasLimit Gas limit used on the other network for executing a message.
    /// @return Message Id.
    function requireToPassMessage(address target, bytes memory data, uint256 maxGasLimit) external returns (bytes32);

    // Source: https://github.com/omni/omnibridge/blob/c814f686487c50462b132b9691fd77cc2de237d3/contracts/interfaces/IAMB.sol#L14
    // Doc: https://docs.gnosischain.com/bridges/Token%20Bridge/amb-bridge#security-considerations-for-receiving-a-call
    function messageSender() external returns (address);
}

/// @title GnosisTargetDispenserL2 - Smart contract for processing tokens and data received on Gnosis L2, and data sent back to L1.
/// @author Aleksandr Kuperman - <aleksandr.kuperman@valory.xyz>
/// @author Andrey Lebedev - <andrey.lebedev@valory.xyz>
/// @author Mariapia Moscatiello - <mariapia.moscatiello@valory.xyz>
contract GnosisTargetDispenserL2 is DefaultTargetDispenserL2 {
    // Bridge payload length
    uint256 public constant BRIDGE_PAYLOAD_LENGTH = 32;
    // L2 token relayer address
    address public immutable l2TokenRelayer;

    /// @dev GnosisTargetDispenserL2 constructor.
    /// @param _olas OLAS token address.
    /// @param _proxyFactory Service staking proxy factory address.
    /// @param _l2MessageRelayer L2 message relayer bridging contract address (AMBHomeProxy).
    /// @param _l1DepositProcessor L1 deposit processor address.
    /// @param _l1SourceChainId L1 source chain Id.
    /// @param _l2TokenRelayer L2 token relayer address (HomeOmniBridgeProxy).
    constructor(
        address _olas,
        address _proxyFactory,
        address _l2MessageRelayer,
        address _l1DepositProcessor,
        uint256 _l1SourceChainId,
        address _l2TokenRelayer
    )
        DefaultTargetDispenserL2(_olas, _proxyFactory, _l2MessageRelayer, _l1DepositProcessor, _l1SourceChainId)
    {
        // Check for zero address
        if (_l2TokenRelayer == address(0)) {
            revert ZeroAddress();
        }

        l2TokenRelayer = _l2TokenRelayer;
    }

    /// @inheritdoc DefaultTargetDispenserL2
    function _sendMessage(uint256 amount, bytes memory bridgePayload) internal override {
        // Check for the bridge payload length
        if (bridgePayload.length != BRIDGE_PAYLOAD_LENGTH) {
            revert IncorrectDataLength(BRIDGE_PAYLOAD_LENGTH, bridgePayload.length);
        }

        // Get the gas limit from the bridge payload
        uint256 gasLimitMessage = abi.decode(bridgePayload, (uint256));

        // Check the gas limit value
        if (gasLimitMessage < GAS_LIMIT) {
            gasLimitMessage = GAS_LIMIT;
        }

        // Assemble AMB data payload
        bytes memory data = abi.encodeWithSelector(RECEIVE_MESSAGE, abi.encode(amount));

        // Send message to L1
        bytes32 iMsg = IBridge(l2MessageRelayer).requireToPassMessage(l1DepositProcessor, data, gasLimitMessage);

        emit MessagePosted(uint256(iMsg), msg.sender, l1DepositProcessor, amount);
    }

    /// @dev Processes a message received from the AMB Contract Proxy (Home) contract.
    /// @param data Bytes message data sent from the AMB Contract Proxy (Home) contract.
    function receiveMessage(bytes memory data) external {
        // Get L1 deposit processor address
        address processor = IBridge(l2MessageRelayer).messageSender();

        // Process the data
        _receiveMessage(msg.sender, processor, data);
    }

    // Source: https://github.com/omni/omnibridge/blob/c814f686487c50462b132b9691fd77cc2de237d3/contracts/upgradeable_contracts/BasicOmnibridge.sol#L464
    // Source: https://github.com/omni/omnibridge/blob/master/contracts/interfaces/IERC20Receiver.sol
    /// @dev Processes the data received together with the token transfer from L1.
    /// @param data Bytes message data sent from L1.
    function onTokenBridged(address, uint256, bytes calldata data) external {
        // Check for the message to come from the L2 token relayer
        if (msg.sender != l2TokenRelayer) {
            revert TargetRelayerOnly(msg.sender, l2TokenRelayer);
        }

        // Process the data
        _receiveMessage(l2MessageRelayer, l1DepositProcessor, data);
    }
}
