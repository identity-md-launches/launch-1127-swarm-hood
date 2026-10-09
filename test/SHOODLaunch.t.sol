// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SHOODToken} from "../src/SHOODToken.sol";
import {PairToken} from "./mocks/PairToken.sol";
import {PoolManagerStub, PoolKey} from "./mocks/PoolManagerStub.sol";
import {LaunchFactoryProbe, TraderProbe, RouterProbe, IToken} from "./mocks/LaunchProbes.sol";

/// @notice The launch as the factory performs it, offline: the token is deployed by the factory through
/// CREATE2, the swarm's 10% goes to the distributor, 90% seeds a single-sided pool through a v4-style
/// PoolManager at the real address, the remainder goes to remainderTo, and an ordinary trader buys and
/// sells through the manager with the pool's 0.30% fee. Every flow is asserted to move exactly what it says.
/// @dev Abstract so the same suite runs with the token sorted as currency0 and as currency1: which one it
/// is on Robinhood Chain depends on the deployed address, and the token must not care.
abstract contract SHOODLaunchBase is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 9_000;
    uint256 internal constant INITIAL_MARKET_CAP_WEI = 2_500 ether; // 2500 IMD for the whole supply
    uint24 internal constant POOL_FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;
    uint64 internal constant LAUNCH_NUMBER = 7;
    /// @dev launch.json pool.initialPrice, provenance only, with SHOOD as currency0.
    uint160 internal constant MANIFEST_SQRT_PRICE = 125_270_724_187_523_965_593_206_900;

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant REMAINDER_TO = 0x000000000000000000000000000000000000dEaD;
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT_A = address(0xC1A1);
    address internal constant CLAIMANT_B = address(0xC1A2);

    LaunchFactoryProbe internal factory;
    PoolManagerStub internal manager;
    PairToken internal imd;
    SHOODToken internal token;
    PoolKey internal key;
    uint160 internal sqrtPrice;
    uint256 internal swarmShare;
    uint256 internal poolShare;

    /// @dev Which currency slot the token should land in for this run of the suite.
    function tokenIsCurrency0() internal pure virtual returns (bool);

    function setUp() public virtual {
        vm.etch(POOL_MANAGER, address(new PoolManagerStub()).code);
        manager = PoolManagerStub(POOL_MANAGER);
        vm.etch(IMD, address(new PairToken()).code);
        imd = PairToken(IMD);
        vm.label(POOL_MANAGER, "PoolManager");
        vm.label(IMD, "IMD");

        factory = new LaunchFactoryProbe();
        vm.label(address(factory), "factory");
        factory.setDistributor(LAUNCH_NUMBER, DISTRIBUTOR);

        bytes memory code = type(SHOODToken).creationCode;
        bytes32 salt = _findSalt(code, tokenIsCurrency0());
        token = SHOODToken(factory.deploy(code, salt));
        vm.label(address(token), "SHOOD");
        assertEq(address(token) < IMD, tokenIsCurrency0(), "fixture sorted the token wrongly");

        (address c0, address c1) = tokenIsCurrency0() ? (address(token), IMD) : (IMD, address(token));
        key = PoolKey(c0, c1, POOL_FEE, TICK_SPACING, address(0));
        // currency1 per currency0, derived from the opening market cap the way the deployer does.
        sqrtPrice = tokenIsCurrency0()
            ? _sqrtPriceX96(INITIAL_MARKET_CAP_WEI, SUPPLY)
            : _sqrtPriceX96(SUPPLY, INITIAL_MARKET_CAP_WEI);

        swarmShare = (SUPPLY * SWARM_BPS) / 10_000;
        poolShare = (SUPPLY * POOL_BPS) / 10_000;
    }

    // ------------------------------------------------------------------ helpers

    function _findSalt(bytes memory code, bool below) internal view returns (bytes32) {
        for (uint256 i; i < 10_000; ++i) {
            bytes32 salt = bytes32(i);
            if ((factory.predict(code, salt) < IMD) == below) return salt;
        }
        revert("no salt gives the wanted currency order");
    }

    /// @dev sqrt(numerator / denominator) * 2^96, computed as sqrt(numerator * 2^96 / denominator) * 2^48 so
    /// 1e27-scale inputs never overflow.
    function _sqrtPriceX96(uint256 numerator, uint256 denominator) internal pure returns (uint160) {
        return uint160(_sqrt((numerator << 96) / denominator) << 48);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @dev The factory's launch, in the order ProjectFactory performs it.
    function _launch() internal {
        factory.move(IToken(address(token)), DISTRIBUTOR, swarmShare);
        factory.initialize(manager, key, sqrtPrice);
        (uint256 a0, uint256 a1) = tokenIsCurrency0() ? (poolShare, uint256(0)) : (uint256(0), poolShare);
        factory.seed(manager, LaunchFactoryProbe.Seed(key, a0, a1));
        uint256 remainder = token.balanceOf(address(factory));
        if (remainder != 0) factory.move(IToken(address(token)), REMAINDER_TO, remainder);
    }

    function _newTrader(uint256 imdBudget) internal returns (TraderProbe trader) {
        trader = new TraderProbe(manager);
        imd.mint(address(trader), imdBudget);
    }

    function _buy(TraderProbe trader, int256 amountSpecified) internal returns (uint256 tokenOut, uint256 imdIn) {
        (int256 d0, int256 d1) = trader.swap(key, !tokenIsCurrency0(), amountSpecified);
        (int256 dToken, int256 dImd) = tokenIsCurrency0() ? (d0, d1) : (d1, d0);
        assertGt(dToken, 0, "buy did not credit the token");
        assertLt(dImd, 0, "buy did not charge IMD");
        return (uint256(dToken), uint256(-dImd));
    }

    function _sell(TraderProbe trader, int256 amountSpecified) internal returns (uint256 tokenIn, uint256 imdOut) {
        (int256 d0, int256 d1) = trader.swap(key, tokenIsCurrency0(), amountSpecified);
        (int256 dToken, int256 dImd) = tokenIsCurrency0() ? (d0, d1) : (d1, d0);
        assertLt(dToken, 0, "sell did not charge the token");
        // A dust-sized sell can round to zero IMD out; it must never be negative.
        assertGe(dImd, 0, "sell charged IMD");
        return (uint256(-dToken), uint256(dImd));
    }

    function _poolTokenReserve() internal view returns (uint256) {
        (uint256 r0, uint256 r1) = manager.reserves(key);
        return tokenIsCurrency0() ? r0 : r1;
    }

    function _poolImdReserve() internal view returns (uint256) {
        (uint256 r0, uint256 r1) = manager.reserves(key);
        return tokenIsCurrency0() ? r1 : r0;
    }

    /// @dev The check the real manager relies on: what it holds is exactly what its pool accounting says.
    function _assertManagerBooksBalance() internal view {
        assertEq(token.balanceOf(POOL_MANAGER), _poolTokenReserve(), "manager SHOOD balance != pool reserve");
        assertEq(imd.balanceOf(POOL_MANAGER), _poolImdReserve(), "manager IMD balance != pool reserve");
    }

    // ------------------------------------------------------------------ deployment through the factory

    function test_factoryDeploymentMintsWholeSupplyToFactory() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY, "the factory does not hold the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the harness, which sent the deploy tx, got tokens");
        assertEq(token.balanceOf(tx.origin), 0, "tx.origin got tokens");
        assertEq(token.decimals(), 18);
    }

    function test_manifestPriceMatchesEconomicsWhenTokenIsCurrency0() public pure {
        // 2500 IMD / 1e9 SHOOD as a sqrtPriceX96 with SHOOD as currency0 is what launch.json records.
        assertApproxEqRel(uint256(_sqrtPriceX96(INITIAL_MARKET_CAP_WEI, SUPPLY)), MANIFEST_SQRT_PRICE, 1e12);
    }

    // ------------------------------------------------------------------ the launch flows

    function test_launchFlowsArriveWholeAndLeaveNothingBehind() public {
        _launch();
        assertEq(token.balanceOf(DISTRIBUTOR), swarmShare, "the swarm's share arrived short");
        assertEq(token.balanceOf(POOL_MANAGER), poolShare, "the seed arrived short");
        assertEq(_poolTokenReserve(), poolShare, "the manager credited less than it received");
        assertEq(token.balanceOf(address(factory)), 0, "the factory kept something back");
        // 10% + 90% is the whole supply: nothing is left for remainderTo.
        assertEq(token.balanceOf(REMAINDER_TO), 0);
        assertEq(swarmShare + poolShare, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY, "the launch changed the supply");
        _assertManagerBooksBalance();
    }

    function test_remainderGoesToRemainderToWhenPoolShareIsSmaller() public {
        // Same flow with a smaller pool share, to show the remainder path moves exactly what is left.
        factory.move(IToken(address(token)), DISTRIBUTOR, swarmShare);
        factory.initialize(manager, key, sqrtPrice);
        uint256 smaller = poolShare / 2;
        (uint256 a0, uint256 a1) = tokenIsCurrency0() ? (smaller, uint256(0)) : (uint256(0), smaller);
        factory.seed(manager, LaunchFactoryProbe.Seed(key, a0, a1));
        uint256 remainder = token.balanceOf(address(factory));
        assertEq(remainder, SUPPLY - swarmShare - smaller);
        assertTrue(factory.move(IToken(address(token)), REMAINDER_TO, remainder));
        assertEq(token.balanceOf(REMAINDER_TO), remainder, "the remainder arrived short");
        assertEq(token.balanceOf(address(factory)), 0);
    }

    function test_distributorClaimsArriveWholeDownToTheLastWei() public {
        _launch();
        uint256 half = swarmShare / 2;
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT_A, half));
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT_B, swarmShare - half));
        assertEq(token.balanceOf(CLAIMANT_A), half, "a claim arrived short");
        assertEq(token.balanceOf(CLAIMANT_B), swarmShare - half, "the last claim arrived short");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "the distributor kept something back");
    }

    function test_distributorCannotOverclaim() public {
        _launch();
        vm.prank(DISTRIBUTOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                SHOODToken.ERC20InsufficientBalance.selector, DISTRIBUTOR, swarmShare, swarmShare + 1
            )
        );
        token.transfer(CLAIMANT_A, swarmShare + 1);
    }

    function test_seedBeyondFactoryBalanceRevertsInsideTheUnlock() public {
        factory.move(IToken(address(token)), DISTRIBUTOR, swarmShare);
        factory.initialize(manager, key, sqrtPrice);
        // The factory holds 90% but tries to seed 100%: the token's own check stops the settle transfer, and
        // because it happens inside the unlock the whole seed unwinds.
        (uint256 a0, uint256 a1) = tokenIsCurrency0() ? (SUPPLY, uint256(0)) : (uint256(0), SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(SHOODToken.ERC20InsufficientBalance.selector, address(factory), poolShare, SUPPLY)
        );
        factory.seed(manager, LaunchFactoryProbe.Seed(key, a0, a1));
        assertEq(token.balanceOf(POOL_MANAGER), 0);
        assertEq(token.balanceOf(address(factory)), poolShare);
    }

    // ------------------------------------------------------------------ swaps with the 0.30% fee

    function test_buyThenSellThroughTheManagerWithFee() public {
        _launch();
        TraderProbe trader = _newTrader(10 ether);

        uint256 managerBefore = token.balanceOf(POOL_MANAGER);
        (uint256 bought, uint256 paid) = _buy(trader, -1 ether);
        assertEq(paid, 1 ether, "exact input charged a different amount");
        assertGt(bought, 0, "a trader could not buy the token");
        assertEq(token.balanceOf(address(trader)), bought, "the trader received less than the manager paid");
        assertEq(token.balanceOf(POOL_MANAGER), managerBefore - bought, "the manager paid out a different amount");
        assertEq(imd.balanceOf(POOL_MANAGER), 1 ether, "the manager received a different amount of IMD");
        _assertManagerBooksBalance();

        // The fee was really charged: without it the same IMD would have bought more.
        uint256 virtualImd = _poolImdVirtualAtOpen();
        uint256 net = 1 ether - (uint256(1 ether) * POOL_FEE) / 1_000_000;
        uint256 expectedWithFee = (poolShare * net) / (virtualImd + net);
        uint256 expectedNoFee = (poolShare * 1 ether) / (virtualImd + 1 ether);
        assertEq(bought, expectedWithFee, "buy did not apply the 0.30% fee as expected");
        assertLt(bought, expectedNoFee, "the fee charged nothing");

        (uint256 sold, uint256 received) = _sell(trader, -int256(bought));
        assertEq(sold, bought, "the sell charged a different amount than specified");
        assertEq(token.balanceOf(address(trader)), 0, "a trader could not sell everything back");
        assertEq(token.balanceOf(POOL_MANAGER), managerBefore, "the manager did not get the tokens back whole");
        assertLt(received, paid, "a round trip through a 0.30% pool returned the full amount");
        assertEq(imd.balanceOf(address(trader)), 10 ether - paid + received);
        assertEq(imd.balanceOf(POOL_MANAGER), paid - received, "the pool did not keep the fee");
        _assertManagerBooksBalance();
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_exactOutputBuyDeliversExactlyWhatWasAsked() public {
        _launch();
        TraderProbe trader = _newTrader(10 ether);
        uint256 want = 123_456 ether;
        (uint256 bought, uint256 paid) = _buy(trader, int256(want));
        assertEq(bought, want);
        assertEq(token.balanceOf(address(trader)), want, "exact output arrived short");
        assertGt(paid, 0);
        assertEq(imd.balanceOf(address(trader)), 10 ether - paid);
        _assertManagerBooksBalance();
    }

    function test_routerPullsWithAllowanceAndSettlesWhole() public {
        _launch();
        address user = makeAddr("user");
        imd.mint(user, 5 ether);
        RouterProbe router = new RouterProbe(manager);
        vm.prank(user);
        imd.approve(address(router), type(uint256).max);

        (int256 d0, int256 d1) = router.swapFor(user, key, !tokenIsCurrency0(), -2 ether);
        uint256 bought = uint256(tokenIsCurrency0() ? d0 : d1);
        assertGt(bought, 0);
        assertEq(token.balanceOf(user), bought, "the router's take delivered short");
        assertEq(imd.balanceOf(user), 3 ether);

        // Now the user sells back through the router under an unlimited SHOOD allowance, the way v4
        // routers pull through Permit2: transferFrom into the manager, then settle.
        vm.prank(user);
        token.approve(address(router), type(uint256).max);
        router.swapFor(user, key, tokenIsCurrency0(), -int256(bought));
        assertEq(token.balanceOf(user), 0, "the user could not sell through a router");
        assertEq(token.allowance(user, address(router)), type(uint256).max, "unlimited allowance was spent");
        _assertManagerBooksBalance();
    }

    function test_routerWithoutAllowanceCannotSell() public {
        _launch();
        address user = makeAddr("user");
        imd.mint(user, 5 ether);
        RouterProbe router = new RouterProbe(manager);
        vm.prank(user);
        imd.approve(address(router), type(uint256).max);
        (int256 d0, int256 d1) = router.swapFor(user, key, !tokenIsCurrency0(), -2 ether);
        uint256 bought = uint256(tokenIsCurrency0() ? d0 : d1);

        vm.expectRevert(
            abi.encodeWithSelector(SHOODToken.ERC20InsufficientAllowance.selector, address(router), 0, bought)
        );
        router.swapFor(user, key, tokenIsCurrency0(), -int256(bought));
        assertEq(token.balanceOf(user), bought, "a failed router sell moved the user's tokens");
    }

    function test_shortSettlementUnwindsTheWholeSwap() public {
        _launch();
        TraderProbe trader = _newTrader(10 ether);
        (uint256 bought,) = _buy(trader, -1 ether);
        uint256 managerBefore = token.balanceOf(POOL_MANAGER);
        uint256 imdBefore = imd.balanceOf(address(trader));

        // Sell, but deliver one wei less than owed: the manager credits only what arrived and refuses to
        // close. The transfer that did happen is unwound with the rest of the swap.
        trader.setShortfall(1);
        vm.expectRevert(PoolManagerStub.CurrencyNotSettled.selector);
        trader.swap(key, tokenIsCurrency0(), -int256(bought));
        assertEq(token.balanceOf(address(trader)), bought, "a failed swap moved the trader's tokens");
        assertEq(token.balanceOf(POOL_MANAGER), managerBefore, "a failed swap changed the manager's balance");
        assertEq(imd.balanceOf(address(trader)), imdBefore);
        _assertManagerBooksBalance();
    }

    function test_sellingMoreThanHeldRevertsWithTheTokensError() public {
        _launch();
        TraderProbe trader = _newTrader(10 ether);
        (uint256 bought,) = _buy(trader, -1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(SHOODToken.ERC20InsufficientBalance.selector, address(trader), bought, bought + 1)
        );
        trader.swap(key, tokenIsCurrency0(), -int256(bought + 1));
        assertEq(token.balanceOf(address(trader)), bought);
    }

    function test_sellCannotDrainMoreIMDThanThePoolHolds() public {
        _launch();
        // A holder who got tokens from a claim, not a purchase, tries to sell a large amount into a pool
        // that holds no IMD yet: the manager refuses, and nothing moves.
        vm.prank(DISTRIBUTOR);
        token.transfer(CLAIMANT_A, swarmShare);
        TraderProbe trader = new TraderProbe(manager);
        vm.prank(CLAIMANT_A);
        token.transfer(address(trader), swarmShare);

        vm.expectRevert(PoolManagerStub.InsufficientLiquidity.selector);
        trader.swap(key, tokenIsCurrency0(), -int256(swarmShare));
        assertEq(token.balanceOf(address(trader)), swarmShare);
        assertEq(token.balanceOf(POOL_MANAGER), poolShare);
    }

    function test_swapBeforeTheSeedReverts() public {
        factory.initialize(manager, key, sqrtPrice);
        TraderProbe trader = _newTrader(1 ether);
        vm.expectRevert(PoolManagerStub.InsufficientLiquidity.selector);
        trader.swap(key, !tokenIsCurrency0(), -1 ether);
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(imd.balanceOf(address(trader)), 1 ether, "a refused swap took the trader's IMD");
    }

    /// @dev Many traders in a row: the supply is never created or destroyed by the manager's flows.
    function test_manyTradersConserveSupply() public {
        _launch();
        TraderProbe[5] memory traders;
        uint256 sumTraders;
        for (uint256 i; i < traders.length; ++i) {
            traders[i] = _newTrader(10 ether);
            (uint256 bought,) = _buy(traders[i], -int256((i + 1) * 0.5 ether));
            sumTraders += bought;
            _assertManagerBooksBalance();
        }
        for (uint256 i; i < traders.length; i += 2) {
            uint256 held = token.balanceOf(address(traders[i]));
            _sell(traders[i], -int256(held / 2));
            sumTraders -= held / 2;
            _assertManagerBooksBalance();
        }
        assertEq(
            token.balanceOf(POOL_MANAGER) + token.balanceOf(DISTRIBUTOR) + sumTraders,
            SUPPLY,
            "tokens were created or destroyed by trading"
        );
    }

    // ------------------------------------------------------------------ fuzz over the flows

    function testFuzz_anyBuyArrivesWholeAndBooksBalance(uint96 rawIn) public {
        uint256 imdIn = bound(uint256(rawIn), 1, 1_000 ether);
        _launch();
        TraderProbe trader = _newTrader(imdIn);
        uint256 managerBefore = token.balanceOf(POOL_MANAGER);
        (uint256 bought, uint256 paid) = _buy(trader, -int256(imdIn));
        assertEq(paid, imdIn);
        assertEq(token.balanceOf(address(trader)), bought);
        assertEq(token.balanceOf(POOL_MANAGER), managerBefore - bought);
        assertEq(imd.balanceOf(address(trader)), 0);
        _assertManagerBooksBalance();
        assertEq(token.balanceOf(POOL_MANAGER) + token.balanceOf(DISTRIBUTOR) + bought, SUPPLY);
    }

    function testFuzz_roundTripReturnsEveryTokenAndNeverMoreIMDThanPaid(uint96 rawIn, uint8 fraction) public {
        uint256 imdIn = bound(uint256(rawIn), 1e9, 1_000 ether);
        _launch();
        TraderProbe trader = _newTrader(imdIn);
        (uint256 bought, uint256 paid) = _buy(trader, -int256(imdIn));
        vm.assume(bought > 1);
        // Sell a fraction first, then the rest: the token's balance accounting must close exactly.
        uint256 first = bound((bought * uint256(fraction)) / 255, 1, bought - 1);
        (, uint256 out1) = _sell(trader, -int256(first));
        (, uint256 out2) = _sell(trader, -int256(bought - first));
        assertEq(token.balanceOf(address(trader)), 0, "the trader could not sell everything back");
        assertEq(token.balanceOf(POOL_MANAGER), poolShare, "the manager did not end up holding the seed again");
        assertLe(out1 + out2, paid, "a round trip through a fee pool returned more than it cost");
        _assertManagerBooksBalance();
    }

    // ------------------------------------------------------------------ internals

    /// @dev The virtual IMD reserve the stub prices the single-sided seed against, recomputed the same way,
    /// so the fee assertion in the buy test is an independent formula rather than the stub's own output.
    function _poolImdVirtualAtOpen() internal view returns (uint256) {
        uint256 q96 = 2 ** 96;
        if (tokenIsCurrency0()) {
            return (((poolShare * sqrtPrice) / q96) * sqrtPrice) / q96;
        }
        return (((poolShare * q96) / sqrtPrice) * q96) / sqrtPrice;
    }
}

/// @notice The token's address sorts below IMD: SHOOD is currency0, as launch.json's initialPrice assumes.
contract SHOODLaunchTokenAsCurrency0Test is SHOODLaunchBase {
    function tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

/// @notice The token's address sorts above IMD: SHOOD is currency1 and the deployer inverts the price.
contract SHOODLaunchTokenAsCurrency1Test is SHOODLaunchBase {
    function tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
