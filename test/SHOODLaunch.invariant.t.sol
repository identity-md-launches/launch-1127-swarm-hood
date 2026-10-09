// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SHOODToken} from "../src/SHOODToken.sol";
import {PairToken} from "./mocks/PairToken.sol";
import {PoolManagerStub, PoolKey} from "./mocks/PoolManagerStub.sol";
import {LaunchFactoryProbe, TraderProbe, IToken} from "./mocks/LaunchProbes.sol";

/// @notice After the launch, random traders buy and sell through the manager, claimants draw from the
/// distributor and holders transfer among themselves. Failed swaps (a pool that cannot pay, a trader that
/// holds too little) are caught and counted, so the sequences exercise failure paths without aborting.
contract SHOODLaunchHandler is Test {
    SHOODToken public immutable token;
    PairToken public immutable imd;
    PoolManagerStub public immutable manager;
    PoolKey public key;
    bool public immutable tokenIsCurrency0;
    address public immutable distributor;

    TraderProbe[] public traders;
    address[] public holders;

    uint256 public buys;
    uint256 public sells;
    uint256 public failedSwaps;
    uint256 public claims;

    constructor(
        SHOODToken token_,
        PairToken imd_,
        PoolManagerStub manager_,
        PoolKey memory key_,
        bool tokenIsCurrency0_,
        address distributor_
    ) {
        token = token_;
        imd = imd_;
        manager = manager_;
        key = key_;
        tokenIsCurrency0 = tokenIsCurrency0_;
        distributor = distributor_;
        for (uint256 i; i < 4; ++i) {
            TraderProbe trader = new TraderProbe(manager_);
            imd_.mint(address(trader), 1_000 ether);
            traders.push(trader);
            holders.push(address(trader));
        }
        holders.push(distributor_);
        holders.push(makeAddr("claimant-a"));
        holders.push(makeAddr("claimant-b"));
    }

    function traderCount() external view returns (uint256) {
        return traders.length;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function buy(uint256 traderSeed, uint256 imdIn) external {
        TraderProbe trader = traders[traderSeed % traders.length];
        uint256 budget = imd.balanceOf(address(trader));
        if (budget == 0) return;
        imdIn = bound(imdIn, 1, budget);
        uint256 before = token.balanceOf(address(trader));
        try trader.swap(key, !tokenIsCurrency0, -int256(imdIn)) returns (int256 d0, int256 d1) {
            int256 dToken = tokenIsCurrency0 ? d0 : d1;
            assertEq(token.balanceOf(address(trader)), before + uint256(dToken), "buy delivered short");
            buys++;
        } catch {
            failedSwaps++;
        }
    }

    function sell(uint256 traderSeed, uint256 tokenIn) external {
        TraderProbe trader = traders[traderSeed % traders.length];
        uint256 held = token.balanceOf(address(trader));
        if (held == 0) return;
        tokenIn = bound(tokenIn, 1, held);
        try trader.swap(key, tokenIsCurrency0, -int256(tokenIn)) {
            assertEq(token.balanceOf(address(trader)), held - tokenIn, "sell charged a different amount");
            sells++;
        } catch {
            // The pool may hold too little IMD to pay for a large sell. Nothing may have moved.
            assertEq(token.balanceOf(address(trader)), held, "a failed sell moved tokens");
            failedSwaps++;
        }
    }

    function claim(uint256 claimantSeed, uint256 amount) external {
        address claimant = holders[claimantSeed % holders.length];
        amount = bound(amount, 0, token.balanceOf(distributor));
        vm.prank(distributor);
        assertTrue(token.transfer(claimant, amount));
        claims++;
    }

    function transferBetweenHolders(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = holders[fromSeed % holders.length];
        address to = holders[toSeed % holders.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
    }
}

/// @notice Invariants over the launched system: the manager's holdings always equal its pool accounting
/// (the property a taxed or short transfer would break), and the supply is conserved across every holder.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract SHOODLaunchInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant DISTRIBUTOR = address(0xD157);
    /// @dev launch.json pool.initialPrice with SHOOD as currency0; the suite below forces that ordering.
    uint160 internal constant SQRT_PRICE = 125_270_724_187_523_965_593_206_900;

    SHOODToken internal token;
    PairToken internal imd;
    PoolManagerStub internal manager;
    LaunchFactoryProbe internal factory;
    SHOODLaunchHandler internal handler;
    PoolKey internal key;
    uint256 internal poolShare;

    function setUp() public {
        vm.etch(POOL_MANAGER, address(new PoolManagerStub()).code);
        manager = PoolManagerStub(POOL_MANAGER);
        vm.etch(IMD, address(new PairToken()).code);
        imd = PairToken(IMD);
        factory = new LaunchFactoryProbe();

        bytes memory code = type(SHOODToken).creationCode;
        bytes32 salt;
        for (uint256 i; i < 10_000; ++i) {
            if (factory.predict(code, bytes32(i)) < IMD) {
                salt = bytes32(i);
                break;
            }
        }
        token = SHOODToken(factory.deploy(code, salt));
        require(address(token) < IMD, "token must be currency0 for this fixture");
        key = PoolKey(address(token), IMD, 3_000, 60, address(0));

        uint256 swarmShare = SUPPLY / 10;
        poolShare = (SUPPLY * 9_000) / 10_000;
        factory.move(IToken(address(token)), DISTRIBUTOR, swarmShare);
        factory.initialize(manager, key, SQRT_PRICE);
        factory.seed(manager, LaunchFactoryProbe.Seed(key, poolShare, 0));
        require(token.balanceOf(address(factory)) == 0, "the launch left a remainder");

        handler = new SHOODLaunchHandler(token, imd, manager, key, true, DISTRIBUTOR);
        targetContract(address(handler));
    }

    function invariant_managerHoldsExactlyWhatItsBooksSay() public view {
        (uint256 r0, uint256 r1) = manager.reserves(key);
        assertEq(token.balanceOf(POOL_MANAGER), r0, "manager SHOOD balance != pool reserve");
        assertEq(imd.balanceOf(POOL_MANAGER), r1, "manager IMD balance != pool reserve");
    }

    function invariant_supplyConservedAcrossEveryHolder() public view {
        uint256 sum = token.balanceOf(POOL_MANAGER);
        for (uint256 i; i < handler.holderCount(); ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, SUPPLY, "tokens were created or destroyed by the launch flows");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_factoryAndRemainderStayEmpty() public view {
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(0x000000000000000000000000000000000000dEaD), 0);
    }

    /// @dev The manager never holds an unsettled delta between calls.
    function invariant_noOpenDeltaBetweenCalls() public view {
        assertEq(manager.currencyDelta(address(token)), 0);
        assertEq(manager.currencyDelta(IMD), 0);
    }
}
