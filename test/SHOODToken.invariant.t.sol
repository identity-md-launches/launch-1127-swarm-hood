// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SHOODToken} from "../src/SHOODToken.sol";

/// @notice Drives the token with random sequences of transfer, approve and transferFrom among a fixed set
/// of actors, including calls meant to fail (over-balance, over-allowance, zero address), and mirrors every
/// movement in ghost ledgers so the invariants can compare the token's books to an independent account.
contract SHOODTokenHandler is Test {
    SHOODToken public immutable token;
    address[] public actors;

    mapping(address => uint256) public ghostReceived;
    mapping(address => uint256) public ghostSent;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public transfers;
    uint256 public transferFroms;
    uint256 public expectedReverts;

    constructor(SHOODToken token_, address deployer) {
        token = token_;
        actors.push(deployer);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("pool"));
        actors.push(makeAddr("distributor"));
        ghostReceived[deployer] = token_.totalSupply();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok);
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        transfers++;
    }

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - balance);
        vm.prank(from);
        try token.transfer(to, balance + excess) {
            fail("transfer above balance succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(SHOODToken.ERC20InsufficientBalance.selector, from, balance, balance + excess)
            );
            expectedReverts++;
        }
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        try token.transfer(address(0), amount) {
            fail("transfer to the zero address succeeded");
        } catch {
            expectedReverts++;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, spender);
        uint256 cap = token.balanceOf(from);
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
        transferFroms++;
    }

    function transferFromTooMuch(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, spender);
        uint256 balance = token.balanceOf(from);
        if (allowed == type(uint256).max) {
            // Unlimited allowance: only the balance can stop it.
            excess = bound(excess, 1, type(uint256).max - balance);
            vm.prank(spender);
            try token.transferFrom(from, to, balance + excess) {
                fail("transferFrom above balance succeeded");
            } catch {
                expectedReverts++;
            }
            return;
        }
        excess = bound(excess, 1, type(uint256).max - allowed);
        vm.prank(spender);
        try token.transferFrom(from, to, allowed + excess) {
            fail("transferFrom above allowance succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(
                    SHOODToken.ERC20InsufficientAllowance.selector, spender, allowed, allowed + excess
                )
            );
            expectedReverts++;
        }
    }
}

/// @notice Invariants for the token's books over random call sequences.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SHOODTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    address internal deployer = makeAddr("factory");
    SHOODToken internal token;
    SHOODTokenHandler internal handler;

    function setUp() public {
        vm.prank(deployer);
        token = new SHOODToken();
        handler = new SHOODTokenHandler(token, deployer);
        targetContract(address(handler));
    }

    /// @dev The supply is fixed forever: no sequence of calls changes `totalSupply`.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Only the actors ever receive tokens, so their balances must sum to the whole supply: nothing is
    /// minted, burned, taxed or stranded by any call.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY, "sum of balances drifted from the supply");
    }

    /// @dev Every balance equals exactly what the holder received minus what it sent: no fee on either side.
    function invariant_balanceEqualsReceivedMinusSent() public view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            assertEq(
                token.balanceOf(actor),
                handler.ghostReceived(actor) - handler.ghostSent(actor),
                "balance disagrees with the ghost ledger"
            );
            assertLe(token.balanceOf(actor), SUPPLY);
        }
    }

    /// @dev Allowances move only by `approve` and by exactly the amount spent through `transferFrom`, and an
    /// unlimited allowance never moves.
    function invariant_allowancesMatchGhost() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drifted");
            }
        }
    }

    /// @dev The zero address never holds anything: no path mints to it, burns through it or sends to it.
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }
}
