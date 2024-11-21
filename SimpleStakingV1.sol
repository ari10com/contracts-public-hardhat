// SPDX-License-Identifier: MIT

pragma solidity =0.8.6;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '../Staking/IStakingDelegate.sol';
import "./Extension/FeeCollector.sol";

/**
 * @title Token Staking
 * @dev BEP20 compatible token.
 */
contract SimpleStakingV1 is Ownable, FeeCollector {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 lockedTimestamp;
    }

    struct PoolInfo {
        uint256 lastBlock;
        uint256 tokenPerShare;
        uint256 tokenRealStaked;
        uint256 tokenReceived;
        uint256 tokenRewarded;
        uint256 tokenTotalLimit;
        uint256 lockupTimerange;
    }

    IERC20 public token;
    IStakingDelegate public delegate;

    uint256 public startBlock;
    uint256 public closeBlock;

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    uint256 public maxPid;

    event Deposited(address indexed user, uint256 pid, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, uint256 pid, address indexed token, uint256 amount);
    event WithdrawnRemain(address indexed user, uint256 pid, address indexed token, uint256 amount);
    event StartBlockChanged(uint256 block);
    event CloseBlockChanged(uint256 block);

    constructor(uint256[] memory poolTimer, uint256[] memory poolLimit) {
        require(poolTimer.length == poolLimit.length, 'Staking: Invalid constructor parameters set!');

        for (uint i=0; i<poolTimer.length; i++) {
            addPool(poolTimer[i], poolLimit[i]);
        }
    }

    function setTokenAddress(IERC20 _token) public onlyOwner {
        require(address(_token) != address(0), 'Staking: token address needs to be different than zero!');
        require(address(token) == address(0), 'Staking: token already set!');
        token = _token;
    }

    function setStartBlock(uint256 _startBlock) public onlyOwner {
        require(startBlock == 0 || block.number < startBlock, 'Staking: start block already set');
        require(_startBlock > 0, 'Staking: start block needs to be higher than zero!');
        startBlock = _startBlock;
        emit StartBlockChanged(startBlock);
    }

    function setCloseBlock(uint256 _closeBlock) public onlyOwner {
        require(startBlock != 0, 'Staking: start block needs to be set first');
        require(closeBlock == 0 || block.number < closeBlock, 'Staking: close block already set');
        require(_closeBlock > startBlock, 'Staking: close block needs to be higher than start one!');
        closeBlock = _closeBlock;
        emit CloseBlockChanged(closeBlock);
    }

    function isStarted() public view returns (bool) {
        return startBlock != 0 && block.number >= startBlock;
    }

    function isStopped() public view returns (bool) {
        return closeBlock != 0 && block.number >= closeBlock;
    }

    function withdrawEmergency(address addr) public onlyOwner {
        uint256 possibleAmount;
        possibleAmount = token.balanceOf(address(this));
        if (possibleAmount > 0) {
            token.safeTransfer(addr, possibleAmount);
            emit WithdrawnRemain(addr, 0, address(token), possibleAmount);
        }
    }

    function withdrawRemaining() public onlyOwner {
        require(startBlock != 0, 'Staking: start block needs to be set first');
        require(closeBlock != 0, 'Staking: close block needs to be set first');
        require(block.number > closeBlock, 'Staking: withdrawal of remaining funds not ready yet');

        for (uint256 i=0; i<maxPid; i++) {
            updatePool(i);
        }

        uint256 allTokenRealStaked = 0;
        uint256 allTokenRewarded = 0;
        uint256 allTokenReceived = 0;

        for (uint256 i=0; i<maxPid; i++) {
            allTokenRealStaked = allTokenRealStaked.add(poolInfo[i].tokenRealStaked);
            allTokenRewarded = allTokenRewarded.add(poolInfo[i].tokenRewarded);
            allTokenReceived = allTokenReceived.add(poolInfo[i].tokenReceived);
        }

        uint256 reservedAmount = allTokenRealStaked.add(allTokenRewarded).sub(allTokenReceived);
        uint256 possibleAmount = token.balanceOf(address(this));
        uint256 unlockedAmount = 0;

        if (possibleAmount > reservedAmount) {
            unlockedAmount = possibleAmount.sub(reservedAmount);
        }
        if (unlockedAmount > 0) {
            token.safeTransfer(owner(), unlockedAmount);
            emit WithdrawnRemain(owner(), 0, address(token), unlockedAmount);
        }
    }

    function pendingRewards(uint256 /**pid**/, address /**addr**/) external view returns (uint256) {
        return 0;
    }

    function deposit(uint256 pid, uint256 amount) external payable collectFee('deposit')  {
        // amount eq to zero is allowed
        require(pid < maxPid, 'Staking: invalid pool ID provided');
        require(startBlock > 0 && block.number >= startBlock, 'Staking: not started yet');
        require(closeBlock == 0 || block.number <= closeBlock, 'Staking: farming has ended, please withdraw remaining tokens');

        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        require(pool.tokenTotalLimit == 0 || pool.tokenTotalLimit >= pool.tokenRealStaked.add(amount),
            'Staking: you cannot deposit over the limit!');

        updatePool(pid);

        if (amount > 0) {
            user.amount = user.amount.add(amount);
            pool.tokenRealStaked = pool.tokenRealStaked.add(amount);
            token.safeTransferFrom(address(msg.sender), address(this), amount);
            emit Deposited(msg.sender, pid, address(token), amount);
        }
        
        if (block.timestamp >= user.lockedTimestamp || user.lockedTimestamp == 0) {
            user.lockedTimestamp = block.timestamp.add(pool.lockupTimerange);
        }

        if (address(delegate) != address(0)) {
            delegate.balanceChanged(msg.sender, pid, address(token), user.amount);
        }
    }

    function withdraw(uint256 pid, uint256 amount) external payable collectFee('withdraw') {
        // amount eq to zero is allowed
        require(pid < maxPid, 'Staking: invalid pool ID provided');
        require(startBlock > 0 && block.number >= startBlock, 'Staking: not started yet');

        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        require((block.timestamp >= user.lockedTimestamp)
            || (closeBlock > 0 && closeBlock <= block.number),
            'Staking: you cannot withdraw yet!');
        require(user.amount >= amount, 'Staking: you cannot withdraw more than you have!');

        updatePool(pid);

        if (amount > 0) {
            user.amount = user.amount.sub(amount);
            pool.tokenRealStaked = pool.tokenRealStaked.sub(amount);
            token.safeTransfer(address(msg.sender), amount);
            emit Withdrawn(msg.sender, pid, address(token), amount);
        }

        if (address(delegate) != address(0)) {
            delegate.balanceChanged(msg.sender, pid, address(token), user.amount);
        }
    }

    function addPool(uint256 _lockupTimerange, uint256 _tokenTotalLimit) internal {
        require(maxPid < 10, 'Staking: Cannot add more than 10 pools!');

        poolInfo.push(PoolInfo({
            lastBlock: 0,
            tokenPerShare: 0,
            tokenRealStaked: 0,
            tokenReceived: 0,
            tokenRewarded: 0,
            tokenTotalLimit: _tokenTotalLimit,
            lockupTimerange: _lockupTimerange
        }));
        maxPid = maxPid.add(1);
    }

    function updatePool(uint256 pid) internal {
        if (pid >= maxPid) {
            return;
        }
        if (startBlock == 0 || block.number < startBlock) {
            return;
        }
        PoolInfo storage pool = poolInfo[pid];
        if (pool.lastBlock == 0) {
            pool.lastBlock = startBlock;
        }
        uint256 lastBlock = getLastBlock();
        if (lastBlock <= pool.lastBlock) {
            return;
        }
        uint256 pooltokenRealStaked = pool.tokenRealStaked;
        if (pooltokenRealStaked == 0) {
            return;
        }
        pool.lastBlock = lastBlock;
    }

    function getLastBlock() internal view returns (uint256) {
        if (startBlock == 0) return 0;
        if (closeBlock == 0) return block.number;
        return (closeBlock < block.number) ? closeBlock : block.number;
    }
}
