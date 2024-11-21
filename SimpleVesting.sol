// SPDX-License-Identifier: MIT

pragma solidity =0.8.6;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import "./Extension/FeeCollector.sol";

/**
 * @title SimpleVesting
 * @dev Vesting for BEP20 compatible token.
 */
contract SimpleVesting is Ownable, FeeCollector {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    bool private _locked;

    address private _token;
    uint256 private immutable _closeTime;
    uint256 private immutable _startTime;
    uint256 private immutable _startPercent;

    mapping (address => uint256) private _currentBalances;
    mapping (address => uint256) private _initialBalances;

    event TokensReleased(address beneficiary, uint256 amount);

    /**
     * @dev Configures vesting for specified accounts.
     * @param startTimeValue Timestamp after which initial amount of tokens is released.
     * @param closeTimeValue Timestamp after which entire amount of tokens is released.
     * @param startPercentValue Percent of tokens available after initial release.
     */
    constructor(uint256 startTimeValue, uint256 closeTimeValue, uint8 startPercentValue) {
        require(startPercentValue <= 100, 'SimpleVesting: Percent of tokens available after initial time cannot be greater than 100');
        require(closeTimeValue >= startTimeValue, 'SimpleVesting: End time must be greater than start time');

        _closeTime = closeTimeValue;
        _startTime = startTimeValue;
        _startPercent = startPercentValue;
    }

    /**
     * @dev Add beneficiaries
     */
    function addBeneficiaries(address[] memory beneficiaries, uint256[] memory balances) public onlyOwner {
        require(beneficiaries.length == balances.length, 'SimpleVesting: Beneficiaries and amounts must have the same length');
        require(!isLocked(), 'SimpleVesting: Contract has already been locked');

        for (uint256 i = 0; i < beneficiaries.length; ++i) {
            _currentBalances[beneficiaries[i]] = balances[i];
            _initialBalances[beneficiaries[i]] = balances[i];
        }
    }

    /**
     * @dev Lock the contract
     */
    function lock() public onlyOwner {
        _locked = true;
    }

    /**
     * @dev Check if contract is locked
     */
    function isLocked() public view returns (bool) {
        return _locked;
    }

    /**
     * @dev Sends all releases tokens (if any) to the caller.
     */
    function release() public payable collectFee('release') {
        require(_token != address(0), 'SimpleVesting: Not configured yet');
        require(isLocked(), 'SimpleVesting: Not locked yet');
        require(block.timestamp >= _startTime || _startPercent != 0, 'SimpleVesting: Cannot release yet');
        require(_initialBalances[msg.sender] > 0, 'SimpleVesting: Invalid beneficiary');
        require(_currentBalances[msg.sender] > 0, 'SimpleVesting: Balance was already emptied');

        uint256 amount = withdrawalLimit(msg.sender);

        require(amount > 0, 'SimpleVesting: Nothing to withdraw at this time');
        require(_currentBalances[msg.sender] >= amount, 'SimpleVesting: Invalid amount');

        _currentBalances[msg.sender] = _currentBalances[msg.sender].sub(amount);

        IERC20(_token).safeTransfer(msg.sender, amount);

        emit TokensReleased(msg.sender, amount);
    }

    /**
     * @dev Sets token address.
     * @param tokenValue Token address.
     */
    function setTokenAddress(address tokenValue) public onlyOwner {
        require(_token == address(0), 'SimpleVesting: Token address already set');
        _token = tokenValue;
    }

    /**
     * @dev Returns current balance for given address.
     * @param beneficiary Address to check.
     */
    function currentBalance(address beneficiary) public view returns (uint256) {
        return _currentBalances[beneficiary];
    }

    /**
     * @dev Returns initial balance for given address.
     * @param beneficiary Address to check.
     */
    function initialBalance(address beneficiary) public view returns (uint256) {
        return _initialBalances[beneficiary];
    }

    /**
     * @dev Returns total withdrawn for given address.
     * @param beneficiary Address to check.
     */
    function totalWithdrawn(address beneficiary) public view returns (uint256) {
        return (_initialBalances[beneficiary].sub(_currentBalances[beneficiary]));
    }

    /**
     * @dev Returns withdrawal limit for given address.
     * @param beneficiary Address to check.
     */
    function withdrawalLimit(address beneficiary) public view returns (uint256) {
        return (amountAllowedToWithdraw(_initialBalances[beneficiary]).sub(totalWithdrawn(beneficiary)));
    }

    /**
     * @dev Returns amount allowed to withdraw for given initial initialBalanceValue.
     * @param initialBalanceValue Initial initialBalanceValue.
     */
    function amountAllowedToWithdraw(uint256 initialBalanceValue) public view returns (uint256) {
        if (initialBalanceValue == 0 || _token == address(0)) {
            return 0;
        }

        if (block.timestamp >= _closeTime) {
            return initialBalanceValue;
        }

        if (block.timestamp <= _startTime) {
            return _startPercent.mul(10).mul(initialBalanceValue).div(1000);
        }

        uint256 curTimeDiff = block.timestamp.sub(_startTime);
        uint256 maxTimeDiff = _closeTime.sub(_startTime);

        uint256 beginPromile = _startPercent.mul(10);
        uint256 otherPromile = curTimeDiff.mul(uint256(1000).sub(beginPromile)).div(maxTimeDiff);
        uint256 promile = beginPromile.add(otherPromile);

        if (promile >= 1000) {
            return initialBalanceValue;
        }

        return promile.mul(initialBalanceValue).div(1000);
    }

    /**
     * @dev Returns token address.
     */
    function token() public view returns (address) {
        return _token;
    }

    /**
     * @dev Returns current token balance.
     */
    function balance() public view returns (uint256) {
        if (_token == address(0)) {
            return 0;
        }

        return IERC20(_token).balanceOf(address(this));
    }

    /**
     * @dev Returns end time.
     */
    function closeTime() public view returns (uint256) {
        return _closeTime;
    }

    /**
     * @dev Returns start time.
     */
    function startTime() public view returns (uint256) {
        return _startTime;
    }

    /**
     * @dev Returns start percent.
     */
    function startPercent() public view returns (uint256) {
        return _startPercent;
    }
}
