// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev Same shape as Uniswap v4's PoolKey, with currencies as plain addresses. currency0 must sort below
/// currency1, exactly as the real manager requires.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice Offline stand-in for the Uniswap v4 PoolManager (0x8366a39cc670b4001a1121b8f6a443a643e40951).
/// @dev The verifier has no network, so the real manager cannot be forked and v4-core cannot be vendored
/// without a remapping this task may not add. This reproduces the parts of the documented v4 behaviour the
/// token is judged against:
///   - the unlock/callback pattern: every swap or liquidity change runs inside `unlock`, and the callback
///     must leave every currency delta at zero or the whole call reverts (`CurrencyNotSettled`);
///   - `sync` / `settle`: the payer transfers tokens to the manager and the manager credits only what its
///     `balanceOf` actually grew by, so a token that taxes the manager settles short and the swap reverts;
///   - `take`: the manager pays out with `transfer`, so a token that taxes transfers from the manager
///     delivers short and the trader's delta is wrong;
///   - the LP fee in pips (3000 = 0.30%), charged on the input currency and kept in the pool;
///   - a single-sided seed at the pool's opening price: the seeded side is real, the other side is a
///     virtual reserve priced from `sqrtPriceX96`, and a trader can never take more of a currency than the
///     pool really holds. Pricing is constant-product over (real + virtual) reserves, a deliberate
///     simplification of concentrated liquidity. Everything about how the token moves is exact.
/// No constructor state, so it works after `vm.etch` at the real address.
contract PoolManagerStub {
    uint256 public constant MAX_FEE = 1_000_000; // 100% in pips
    uint256 private constant Q96 = 2 ** 96;

    struct Pool {
        bool initialized;
        uint160 sqrtPriceX96;
        uint24 fee;
        uint256 reserve0; // tokens of currency0 the pool really holds
        uint256 reserve1; // tokens of currency1 the pool really holds
        uint256 virtual0; // phantom currency0 backing a single-sided currency1 seed
        uint256 virtual1; // phantom currency1 backing a single-sided currency0 seed
    }

    error ManagerLocked();
    error AlreadyUnlocked();
    error CurrencyNotSettled();
    error CurrenciesOutOfOrder();
    error LPFeeTooLarge();
    error TickSpacingTooSmall();
    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error SwapAmountCannotBeZero();
    error InsufficientLiquidity();
    error NotSynced();
    error TransferFailed();

    mapping(bytes32 => Pool) public pools;

    bool private _unlocked;
    address private _syncedCurrency;
    uint256 private _syncedReserves;
    bool private _synced;
    mapping(address currency => int256) private _delta;
    uint256 private _nonzeroDeltas;

    modifier onlyWhenUnlocked() {
        if (!_unlocked) revert ManagerLocked();
        _;
    }

    function toId(PoolKey memory key) public pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function currencyDelta(address currency) external view returns (int256) {
        return _delta[currency];
    }

    function reserves(PoolKey memory key) external view returns (uint256 real0, uint256 real1) {
        Pool storage pool = pools[toId(key)];
        return (pool.reserve0, pool.reserve1);
    }

    // ------------------------------------------------------------------ lifecycle

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external {
        if (key.currency0 >= key.currency1) revert CurrenciesOutOfOrder();
        if (key.fee > MAX_FEE) revert LPFeeTooLarge();
        if (key.tickSpacing <= 0) revert TickSpacingTooSmall();
        Pool storage pool = pools[toId(key)];
        if (pool.initialized) revert PoolAlreadyInitialized();
        pool.initialized = true;
        pool.sqrtPriceX96 = sqrtPriceX96;
        pool.fee = key.fee;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (_unlocked) revert AlreadyUnlocked();
        _unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        if (_nonzeroDeltas != 0) revert CurrencyNotSettled();
        _unlocked = false;
    }

    // ------------------------------------------------------------------ liquidity

    /// @notice Adds `amount0` of currency0 and `amount1` of currency1 to the pool. One side may be zero: the
    /// other is then backed by a virtual reserve priced at the pool's opening price, which is how a
    /// single-sided v4 seed above the current price behaves to a buyer.
    function addLiquidity(PoolKey memory key, uint256 amount0, uint256 amount1)
        external
        onlyWhenUnlocked
        returns (int256 delta0, int256 delta1)
    {
        Pool storage pool = pools[toId(key)];
        if (!pool.initialized) revert PoolNotInitialized();
        if (amount0 == 0 && amount1 == 0) revert SwapAmountCannotBeZero();
        if (amount1 == 0) pool.virtual1 += _quote0To1(amount0, pool.sqrtPriceX96);
        else if (amount0 == 0) pool.virtual0 += _quote1To0(amount1, pool.sqrtPriceX96);
        pool.reserve0 += amount0;
        pool.reserve1 += amount1;
        delta0 = -int256(amount0);
        delta1 = -int256(amount1);
        _accountDelta(key.currency0, delta0);
        _accountDelta(key.currency1, delta1);
    }

    // ------------------------------------------------------------------ swaps

    /// @notice Swaps `amountSpecified` (negative: exact input, positive: exact output) in the given direction.
    /// @return amount0 The caller's resulting delta in currency0: negative is owed to the manager, positive
    /// is owed to the caller. Same for `amount1`.
    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160)
        external
        onlyWhenUnlocked
        returns (int256 amount0, int256 amount1)
    {
        Pool storage pool = pools[toId(key)];
        if (!pool.initialized) revert PoolNotInitialized();
        if (amountSpecified == 0) revert SwapAmountCannotBeZero();

        (uint256 realIn, uint256 realOut, uint256 virtIn, uint256 virtOut) = zeroForOne
            ? (pool.reserve0, pool.reserve1, pool.virtual0, pool.virtual1)
            : (pool.reserve1, pool.reserve0, pool.virtual1, pool.virtual0);
        uint256 totalIn = realIn + virtIn;
        uint256 totalOut = realOut + virtOut;
        // An unseeded pool has nothing to price against.
        if (totalIn == 0 || totalOut == 0) revert InsufficientLiquidity();

        uint256 amountIn;
        uint256 amountOut;
        if (amountSpecified < 0) {
            amountIn = uint256(-amountSpecified);
            uint256 net = amountIn - (amountIn * pool.fee) / MAX_FEE;
            amountOut = (totalOut * net) / (totalIn + net);
        } else {
            amountOut = uint256(amountSpecified);
            if (amountOut >= totalOut) revert InsufficientLiquidity();
            uint256 net = _ceilDiv(totalIn * amountOut, totalOut - amountOut);
            amountIn = _ceilDiv(net * MAX_FEE, MAX_FEE - pool.fee);
        }
        // The pool can only pay out what it really holds: the virtual side is price, not tokens.
        if (amountOut > realOut) revert InsufficientLiquidity();

        if (zeroForOne) {
            pool.reserve0 += amountIn;
            pool.reserve1 -= amountOut;
            amount0 = -int256(amountIn);
            amount1 = int256(amountOut);
        } else {
            pool.reserve1 += amountIn;
            pool.reserve0 -= amountOut;
            amount1 = -int256(amountIn);
            amount0 = int256(amountOut);
        }
        _accountDelta(key.currency0, amount0);
        _accountDelta(key.currency1, amount1);
    }

    // ------------------------------------------------------------------ settlement

    function sync(address currency) external {
        _syncedCurrency = currency;
        _syncedReserves = IERC20Minimal(currency).balanceOf(address(this));
        _synced = true;
    }

    /// @notice Credits the caller with exactly what the synced currency's balance grew by since `sync`.
    function settle() external onlyWhenUnlocked returns (uint256 paid) {
        if (!_synced) revert NotSynced();
        address currency = _syncedCurrency;
        paid = IERC20Minimal(currency).balanceOf(address(this)) - _syncedReserves;
        _synced = false;
        _syncedCurrency = address(0);
        _syncedReserves = 0;
        _accountDelta(currency, int256(paid));
    }

    function take(address currency, address to, uint256 amount) external onlyWhenUnlocked {
        _accountDelta(currency, -int256(amount));
        if (!IERC20Minimal(currency).transfer(to, amount)) revert TransferFailed();
    }

    // ------------------------------------------------------------------ internals

    function _accountDelta(address currency, int256 amount) private {
        if (amount == 0) return;
        int256 previous = _delta[currency];
        int256 next = previous + amount;
        if (previous == 0) _nonzeroDeltas += 1;
        if (next == 0) _nonzeroDeltas -= 1;
        _delta[currency] = next;
    }

    /// @dev currency1 per `amount0` at sqrtPriceX96: amount0 * (sqrtP / 2^96)^2, in two steps so 1e27-scale
    /// amounts and 2^105-scale square roots never overflow.
    function _quote0To1(uint256 amount0, uint160 sqrtPriceX96) private pure returns (uint256) {
        return (((amount0 * sqrtPriceX96) / Q96) * sqrtPriceX96) / Q96;
    }

    function _quote1To0(uint256 amount1, uint160 sqrtPriceX96) private pure returns (uint256) {
        return (((amount1 * Q96) / sqrtPriceX96) * Q96) / sqrtPriceX96;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
