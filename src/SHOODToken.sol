// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Swarm Hood (SHOOD)
/// @notice A fixed-supply, plain ERC-20 token for the Swarm Hood launch on Robinhood Chain.
/// @dev Design, all of it fixed at compile time:
///      - 1,000,000,000 SHOOD with 18 decimals (1e27 minor units), minted once to the deployer in the
///        constructor. The deployer is the launch factory, which distributes the whole supply.
///      - No mint path after construction: the supply can never grow.
///      - No owner, no admin, no pause, no blacklist, no fee, no tax, no limit. Transfers move exactly
///        the requested amount, so the factory's seed, the Merkle distributor's claims and the Uniswap v4
///        PoolManager's swaps always arrive whole.
///      - No proxies, no upgradeability, no delegatecall, no selfdestruct.
///      The contract is self-contained so every byte of the deployed code is in this file.
contract SHOODToken {
    /// @notice Human-readable token name.
    string public constant name = "Swarm Hood";
    /// @notice Ticker symbol.
    string public constant symbol = "SHOOD";
    /// @notice Minor units per whole token, as a power of ten.
    uint8 public constant decimals = 18;
    /// @notice The fixed, final supply in minor units: 1,000,000,000 * 10**18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    mapping(address account => uint256) private _balances;
    mapping(address owner => mapping(address spender => uint256)) private _allowances;

    /// @notice Emitted when `value` tokens move from `from` to `to`. `from` is the zero address on mint.
    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice Emitted when `owner` sets `spender`'s allowance to `value`.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @dev `sender` tried to move `needed` but holds only `balance`.
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    /// @dev `spender` tried to move `needed` on someone's behalf but is allowed only `allowance`.
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    /// @dev The zero address was used as a sender, receiver, approver or spender.
    error ERC20InvalidAddress(address account);

    /// @notice Mints the entire fixed supply to the deployer (the launch factory). Takes no arguments.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Total minor units in existence. Constant for the life of the contract.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @notice Minor units held by `account`.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Minor units `spender` may move on behalf of `owner`.
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @notice Moves `value` minor units from the caller to `to`. No fee, no tax, no limit.
    /// @return Always true; failures revert.
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to exactly `value`.
    /// @return Always true; failures revert.
    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    /// @notice Moves `value` minor units from `from` to `to` using the caller's allowance.
    /// @dev An allowance of `type(uint256).max` is treated as unlimited and is not decremented.
    /// @return Always true; failures revert.
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 current = _allowances[from][msg.sender];
        if (current != type(uint256).max) {
            if (current < value) revert ERC20InsufficientAllowance(msg.sender, current, value);
            unchecked {
                _approve(from, msg.sender, current - value);
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (from == address(0)) revert ERC20InvalidAddress(from);
        if (to == address(0)) revert ERC20InvalidAddress(to);
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            // fromBalance >= value, and the sum of all balances is TOTAL_SUPPLY < 2**256, so neither
            // side can wrap.
            _balances[from] = fromBalance - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value) private {
        if (owner == address(0)) revert ERC20InvalidAddress(owner);
        if (spender == address(0)) revert ERC20InvalidAddress(spender);
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }
}
