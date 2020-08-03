// SPDX-License-Identifier: Apache-2.0
// Copyright 2017 Loopring Technology Limited.
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./libexchange/ExchangeAdmins.sol";
import "./libexchange/ExchangeBalances.sol";
import "./libexchange/ExchangeBlocks.sol";
import "./libexchange/ExchangeDeposits.sol";
import "./libexchange/ExchangeGenesis.sol";
import "./libexchange/ExchangeMode.sol";
import "./libexchange/ExchangeTokens.sol";
import "./libexchange/ExchangeWithdrawals.sol";
import "./libtransactions/TransferTransaction.sol";

import "../lib/EIP712.sol";
import "../lib/MathUint.sol";

import "../iface/IAgentRegistry.sol";
import "../iface/IExchangeV3.sol";


/// @title An Implementation of IExchangeV3.
/// @dev This contract supports upgradability proxy, therefore its constructor
///      must do NOTHING.
/// @author Brecht Devos - <brecht@loopring.org>
/// @author Daniel Wang  - <daniel@loopring.org>
contract ExchangeV3 is IExchangeV3
{
    bytes32 constant public genesisMerkleRoot = 0x160ca280c25b71c85d58fc0dd7b9eb42268c73c8812333da3cc2bdc8af3ee7b7;

    using MathUint              for uint;
    using ExchangeAdmins        for ExchangeData.State;
    using ExchangeBalances      for ExchangeData.State;
    using ExchangeBlocks        for ExchangeData.State;
    using ExchangeDeposits      for ExchangeData.State;
    using ExchangeGenesis       for ExchangeData.State;
    using ExchangeMode          for ExchangeData.State;
    using ExchangeTokens        for ExchangeData.State;
    using ExchangeWithdrawals   for ExchangeData.State;

    ExchangeData.State private state;

    modifier onlyWhenUninitialized()
    {
        require(owner == address(0) && state.id == 0, "INITIALIZED");
        _;
    }

    modifier onlyFromUserOrAgent(address owner)
    {
        require(
            owner == msg.sender ||
            state.agentRegistry != IAgentRegistry(address(0)) &&
            state.agentRegistry.isAgent(owner, msg.sender),
            "UNAUTHORIZED"
        );
        _;
    }

    /// @dev The constructor must do NOTHING to support proxy.
    constructor() {}

    function version()
        public
        override
        pure
        returns (string memory)
    {
        return "3.6.0";
    }

    // -- Initialization --
    function initialize(
        address _loopring,
        address _owner,
        uint    _id
        )
        external
        override
        nonReentrant
        onlyWhenUninitialized
    {
        require(address(0) != _owner, "ZERO_ADDRESS");
        owner = _owner;

        state.initializeGenesisBlock(
            _id,
            _loopring,
            genesisMerkleRoot,
            EIP712.hash(EIP712.Domain("Loopring Protocol", version(), address(this)))
        );
    }

    function setAgentRegistry(address _agentRegistry)
        external
        override
        nonReentrant
        onlyOwner
    {
        require(_agentRegistry != address(0), "ZERO_ADDRESS");
        require(state.agentRegistry == IAgentRegistry(0), "ALREADY_SET");
        state.agentRegistry = IAgentRegistry(_agentRegistry);
    }

    function getAgentRegistry()
        external
        override
        view
        returns (IAgentRegistry)
    {
        return state.agentRegistry;
    }

    function setDepositContract(address _depositContract)
        external
        override
        nonReentrant
        onlyOwner
    {
        require(_depositContract != address(0), "ZERO_ADDRESS");
        // Only used for initialization
        require(state.depositContract == IDepositContract(0), "ALREADY_SET");
        state.depositContract = IDepositContract(_depositContract);
    }

    function getDepositContract()
        external
        override
        view
        returns (IDepositContract)
    {
        return state.depositContract;
    }

    // -- Constants --
    function getConstants()
        external
        override
        pure
        returns(ExchangeData.Constants memory)
    {
        return ExchangeData.Constants(
            uint(ExchangeData.SNARK_SCALAR_FIELD()),
            uint(ExchangeData.MAX_OPEN_FORCED_REQUESTS()),
            uint(ExchangeData.MAX_AGE_FORCED_REQUEST_UNTIL_WITHDRAW_MODE()),
            uint(ExchangeData.TIMESTAMP_HALF_WINDOW_SIZE_IN_SECONDS()),
            uint(ExchangeData.MAX_NUM_ACCOUNTS()),
            uint(ExchangeData.MAX_NUM_TOKENS()),
            uint(ExchangeData.MIN_AGE_PROTOCOL_FEES_UNTIL_UPDATED()),
            uint(ExchangeData.MIN_TIME_IN_SHUTDOWN()),
            uint(ExchangeData.TX_DATA_AVAILABILITY_SIZE()),
            uint(ExchangeData.MAX_AGE_DEPOSIT_UNTIL_WITHDRAWABLE_UPPERBOUND())
        );
    }

    // -- Mode --
    function isInWithdrawalMode()
        external
        override
        view
        returns (bool)
    {
        return state.isInWithdrawalMode();
    }

    function isShutdown()
        external
        override
        view
        returns (bool)
    {
        return state.isShutdown();
    }

    // -- Tokens --

    function registerToken(
        address tokenAddress,
        uint    tid
        )
        external
        override
        nonReentrant
        onlyOwner
        returns (uint16)
    {
        return state.registerToken(tokenAddress, tid);
    }

    function getTokenID(
        address tokenAddress,
        uint    tid
        )
        external
        override
        view
        returns (uint16)
    {
        return state.getTokenID(tokenAddress, tid);
    }

    function getTokenAddress(
        uint16 tokenID
        )
        external
        override
        view
        returns (address, uint)
    {
        return state.getTokenAddress(tokenID);
    }

    // -- Stakes --
    function getExchangeStake()
        external
        override
        view
        returns (uint)
    {
        return state.loopring.getExchangeStake(state.id);
    }

    function withdrawExchangeStake(
        address recipient
        )
        external
        override
        nonReentrant
        onlyOwner
        returns (uint)
    {
        return state.withdrawExchangeStake(recipient);
    }

    function withdrawProtocolFeeStake(
        address recipient,
        uint amount
        )
        external
        override
        nonReentrant
        onlyOwner
    {
        state.loopring.withdrawProtocolFeeStake(state.id, recipient, amount);
    }

    function getProtocolFeeLastWithdrawnTime(
        address tokenAddress,
        uint    tid
        )
        external
        override
        view
        returns (uint)
    {
        return state.protocolFeeLastWithdrawnTime[tokenAddress][tid];
    }

    function burnExchangeStake()
        external
        override
        nonReentrant
    {
        // Allow burning the complete exchange stake when the exchange gets into withdrawal mode
        if(state.isInWithdrawalMode()) {
            // Burn the complete stake of the exchange
            uint stake = state.loopring.getExchangeStake(state.id);
            state.loopring.burnExchangeStake(state.id, stake);
        }
    }

    // -- Blocks --
    function getMerkleRoot()
        external
        override
        view
        returns (bytes32)
    {
        return state.merkleRoot;
    }

    function getBlockHeight()
        external
        override
        view
        returns (uint)
    {
        return state.blocks.length;
    }

    function getBlockInfo(uint blockIdx)
        external
        override
        view
        returns (ExchangeData.BlockInfo memory)
    {
        return state.blocks[blockIdx];
    }

    function submitBlocks(
        ExchangeData.Block[] calldata blocks,
        address payable feeRecipient
        )
        external
        override
        nonReentrant
        onlyOwner
    {
        state.submitBlocks(
            blocks,
            feeRecipient
        );
    }

    function getNumAvailableForcedSlots()
        external
        override
        view
        returns (uint)
    {
        return state.getNumAvailableForcedSlots();
    }

    // -- Deposits --

    function deposit(
        address from,
        address to,
        address tokenAddress,
        uint    tid,
        uint96  amount,
        bytes   calldata auxiliaryData
        )
        external
        payable
        override
        nonReentrant
        onlyFromUserOrAgent(from)
    {
        state.deposit(from, to, tokenAddress, tid, amount, auxiliaryData);
    }

    // -- Withdrawals --

    function forceWithdraw(
        address owner,
        address token,
        uint    tid,
        uint32  accountID
        )
        external
        override
        nonReentrant
        payable
        onlyFromUserOrAgent(owner)
    {
        state.forceWithdraw(owner, token, tid, accountID);
    }

    function withdrawProtocolFees(
        address token,
        uint    tid
        )
        external
        override
        nonReentrant
        payable
    {
        state.forceWithdraw(address(0), token, tid, ExchangeData.ACCOUNTID_PROTOCOLFEE());
    }

    // We still alow anyone to withdraw these funds for the account owner
    function withdrawFromMerkleTree(
        ExchangeData.MerkleProof calldata merkleProof
        )
        external
        override
        nonReentrant
    {
        state.withdrawFromMerkleTree(merkleProof);
    }

    function withdrawFromDepositRequest(
        address owner,
        address token,
        uint    tid
        )
        external
        override
        nonReentrant
    {
        state.withdrawFromDepositRequest(
            owner,
            token,
            tid
        );
    }

    function withdrawFromApprovedWithdrawals(
        address[] calldata owners,
        address[] calldata tokens,
        uint[]    calldata tids
        )
        external
        override
        nonReentrant
    {
        state.withdrawFromApprovedWithdrawals(
            owners,
            tokens,
            tids
        );
    }

    function getAmountWithdrawable(
        address owner,
        address token,
        uint    tid
        )
        external
        override
        view
        returns (uint)
    {
        uint16 tokenID = state.getTokenID(token, tid);
        return state.amountWithdrawable[owner][tokenID];
    }

    function notifyForcedRequestTooOld(
        uint32  accountID,
        address token,
        uint    tid
        )
        external
        override
        nonReentrant
    {
        uint16 tokenID = state.getTokenID(token, tid);
        ExchangeData.ForcedWithdrawal storage withdrawal = state.pendingForcedWithdrawals[accountID][tokenID];
        require(withdrawal.timestamp != 0, "WITHDRAWAL_NOT_TOO_OLD");

        // Check if the withdrawal has indeed exceeded the time limit
        require(block.timestamp >= withdrawal.timestamp + ExchangeData.MAX_AGE_FORCED_REQUEST_UNTIL_WITHDRAW_MODE(), "WITHDRAWAL_NOT_TOO_OLD");

        // Enter withdrawal mode
        state.withdrawalModeStartTime = block.timestamp;

        emit WithdrawalModeActivated(state.withdrawalModeStartTime);
    }

    function approveOffchainTransfer(
        address from,
        address to,
        address token,
        uint    tid,
        uint96  amount,
        address feeToken,
        uint    feeTid,
        uint96  fee,
        uint    data,
        uint32  validUntil,
        uint32  storageID
        )
        external
        override
        nonReentrant
        onlyFromUserOrAgent(from)
    {
        // uint16 tokenID = state.getTokenID(token, tid);
        // uint16 feeTokenID = state.getTokenID(feeToken, feeTid);
        // TransferTransaction.Transfer memory transfer = TransferTransaction.Transfer({
        //     from: from,
        //     to: to,
        //     tokenID: tokenID,
        //     amount: amount,
        //     feeTokenID: feeTokenID,
        //     fee: fee,
        //     data: data,
        //     validUntil: validUntil,
        //     storageID: storageID
        // });
        // bytes32 txHash = TransferTransaction.hash(state.DOMAIN_SEPARATOR, transfer);
        // state.approvedTx[transfer.from][txHash] = true;
        // emit TransactionApproved(transfer.from, txHash);
    }

    function setWithdrawalRecipient(
        address from,
        address to,
        address token,
        uint    tid,
        uint96  amount,
        uint32  nonce,
        address newRecipient
        )
        external
        override
        nonReentrant
        onlyFromUserOrAgent(from)
    {
        uint16 tokenID = state.getTokenID(token, tid);
        require(state.withdrawalRecipient[from][to][tokenID][amount][nonce] == address(0), "CANNOT_OVERRIDE_RECIPIENT_ADDRESS");
        state.withdrawalRecipient[from][to][tokenID][amount][nonce] = newRecipient;
    }

    function onchainTransferFrom(
        address from,
        address to,
        address token,
        uint    tid,
        uint    amount
        )
        external
        override
        nonReentrant
        onlyFromUserOrAgent(from)
    {
        state.depositContract.transfer(from, to, token, tid, amount);
    }

    function approveTransaction(
        address owner,
        bytes32 transactionHash
        )
        external
        override
        nonReentrant
        onlyFromUserOrAgent(owner)
    {
        state.approvedTx[owner][transactionHash] = true;
        emit TransactionApproved(owner, transactionHash);
    }

    function isTransactionApproved(
        address owner,
        bytes32 transactionHash
        )
        external
        override
        view
        returns (bool)
    {
        return state.approvedTx[owner][transactionHash];
    }

    // -- Admins --
    function setMaxAgeDepositUntilWithdrawable(
        uint32 newValue
        )
        external
        override
        nonReentrant
        onlyOwner
        returns (uint32)
    {
        return state.setMaxAgeDepositUntilWithdrawable(newValue);
    }

    function getMaxAgeDepositUntilWithdrawable()
        external
        override
        view
        returns (uint32)
    {
        return state.maxAgeDepositUntilWithdrawable;
    }

    function shutdown()
        external
        override
        nonReentrant
        onlyOwner
        returns (bool success)
    {
        require(!state.isInWithdrawalMode(), "INVALID_MODE");
        require(!state.isShutdown(), "ALREADY_SHUTDOWN");
        state.shutdownModeStartTime = block.timestamp;
        emit Shutdown(state.shutdownModeStartTime);
        return true;
    }

    function getProtocolFeeValues()
        external
        override
        view
        returns (
            uint32 syncedAt,
            uint8  takerFeeBips,
            uint8  makerFeeBips,
            uint8  previousTakerFeeBips,
            uint8  previousMakerFeeBips
        )
    {
        syncedAt = state.protocolFeeData.syncedAt;
        takerFeeBips = state.protocolFeeData.takerFeeBips;
        makerFeeBips = state.protocolFeeData.makerFeeBips;
        previousTakerFeeBips = state.protocolFeeData.previousTakerFeeBips;
        previousMakerFeeBips = state.protocolFeeData.previousMakerFeeBips;
    }
}
