// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SHOODToken} from "../src/SHOODToken.sol";

/// @notice Property tests and edge cases for every rule in the brief: fixed 1e27 supply minted once to the
/// deployer, no mint path, plain transfers with no fee, tax or limit for any caller, allowance arithmetic
/// at its edges, and the absence of any owner, admin, fallback or ETH path. Builds on the smoke suite in
/// SHOODToken.t.sol; nothing here is repeated from it.
contract SHOODTokenFuzzTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    address internal deployer = makeAddr("factory");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    SHOODToken internal token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new SHOODToken();
    }

    // ------------------------------------------------------------------ supply

    function test_supplyIsExactlyTheManifestFigure() public view {
        // launch.json token.totalSupply = "1000000000000000000000000000", decimals 18.
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** uint256(token.decimals()));
    }

    function test_eachDeploymentMintsItsOwnSupplyToItsOwnDeployer() public {
        vm.prank(alice);
        SHOODToken second = new SHOODToken();
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0, "a second deployment touched the first");
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testFuzz_supplyNeverChangesWhateverIsTransferred(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer) + (to == deployer ? 0 : token.balanceOf(to)), SUPPLY);
    }

    // ------------------------------------------------------------------ transfer: no fee, tax or limit

    function testFuzz_transferMovesExactlyTheAmountForAnyCaller(
        address caller,
        address to,
        uint256 held,
        uint256 amount
    ) public {
        vm.assume(caller != address(0) && to != address(0) && caller != to && caller != deployer && to != deployer);
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        vm.prank(deployer);
        token.transfer(caller, held);

        vm.prank(caller);
        vm.expectEmit(address(token));
        emit Transfer(caller, to, amount);
        assertTrue(token.transfer(to, amount));

        assertEq(token.balanceOf(to), amount, "recipient got a different amount: a fee or tax");
        assertEq(token.balanceOf(caller), held - amount, "sender charged a different amount");
        assertEq(token.balanceOf(deployer), SUPPLY - held);
    }

    /// @dev No max-transaction or max-wallet limit: one wallet can receive and send the entire supply.
    function test_wholeSupplyMovesInOneTransfer() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY);
        vm.prank(alice);
        token.transfer(bob, SUPPLY);
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(deployer), 0);
    }

    function testFuzz_transferAboveBalanceRevertsForAnyShortfall(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(alice, held);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InsufficientBalance.selector, alice, held, amount));
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferOfOneWeiMoreThanSupplyRevertsEvenForTheDeployer() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(SHOODToken.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_transferMaxUint256Reverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(SHOODToken.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    function testFuzz_transferToSelfIsANoOp(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), held, "self-transfer changed the balance");
    }

    function test_transferToSelfAboveBalanceStillReverts() public {
        vm.prank(deployer);
        token.transfer(alice, 5);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InsufficientBalance.selector, alice, 5, 6));
        token.transfer(alice, 6);
    }

    function test_sameTransferTwiceIsChargedTwice() public {
        vm.prank(deployer);
        token.transfer(alice, 10);
        vm.startPrank(alice);
        token.transfer(bob, 5);
        token.transfer(bob, 5);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InsufficientBalance.selector, alice, 0, 5));
        token.transfer(bob, 5);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 10);
    }

    function test_zeroTransferToZeroAddressStillReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InvalidAddress.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_transferToContractWithoutReceiverHookSucceeds() public {
        // Plain ERC-20: no ERC-777 or ERC-1363 callback, so a contract recipient needs no hook.
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
    }

    // ------------------------------------------------------------------ approve

    function testFuzz_approveOverwritesRatherThanAccumulates(uint256 first, uint256 second) public {
        vm.startPrank(alice);
        token.approve(bob, first);
        assertEq(token.allowance(alice, bob), first);
        token.approve(bob, second);
        assertEq(token.allowance(alice, bob), second, "approve accumulated instead of overwriting");
        vm.stopPrank();
    }

    function test_approveNeedsNoBalance() public {
        assertEq(token.balanceOf(alice), 0);
        vm.prank(alice);
        assertTrue(token.approve(bob, SUPPLY * 2));
        assertEq(token.allowance(alice, bob), SUPPLY * 2);
    }

    function test_approveSelfIsAllowedAndSpendable() public {
        vm.prank(deployer);
        token.transfer(alice, 10);
        vm.startPrank(alice);
        token.approve(alice, 4);
        token.transferFrom(alice, bob, 4);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 4);
        assertEq(token.allowance(alice, alice), 0);
    }

    function test_approveZeroRevokesAndEmits() public {
        vm.startPrank(alice);
        token.approve(bob, 7);
        vm.expectEmit(address(token));
        emit Approval(alice, bob, 0);
        token.approve(bob, 0);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_allowanceIsDirectional() public {
        vm.prank(alice);
        token.approve(bob, 9);
        assertEq(token.allowance(alice, bob), 9);
        assertEq(token.allowance(bob, alice), 0, "allowance leaked in the other direction");
    }

    // ------------------------------------------------------------------ transferFrom

    function testFuzz_transferFromSpendsExactlyTheAmount(uint256 held, uint256 allowed, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        allowed = bound(allowed, 0, type(uint256).max - 1); // exclude the unlimited sentinel
        amount = bound(amount, 0, held < allowed ? held : allowed);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertEq(token.balanceOf(bob), amount, "transferFrom delivered a different amount");
        assertEq(token.balanceOf(alice), held - amount);
        assertEq(token.allowance(alice, bob), allowed - amount, "allowance moved by a different amount");
    }

    function testFuzz_transferFromAboveAllowanceReverts(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        amount = bound(amount, allowed + 1, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, SUPPLY); // balance is never the limiting factor here
        vm.prank(alice);
        token.approve(bob, allowed);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InsufficientAllowance.selector, bob, allowed, amount));
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.allowance(alice, bob), allowed, "a failed transferFrom spent allowance");
    }

    function test_transferFromAllowanceExactlyEqualToAmountSucceedsAndEmptiesIt() public {
        vm.prank(deployer);
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, 10);
        vm.prank(bob);
        token.transferFrom(alice, bob, 10);
        assertEq(token.allowance(alice, bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_transferFromMaxMinusOneIsNotUnlimited() public {
        vm.prank(deployer);
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, type(uint256).max - 1);
        vm.prank(bob);
        token.transferFrom(alice, bob, 10);
        assertEq(token.allowance(alice, bob), type(uint256).max - 11, "an allowance below max was not decremented");
    }

    function test_transferFromDecrementEmitsApproval() public {
        // Documented behaviour of this implementation: spending allowance emits Approval with the new value.
        vm.prank(deployer);
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, 10);
        vm.prank(bob);
        vm.expectEmit(address(token));
        emit Approval(alice, bob, 4);
        vm.expectEmit(address(token));
        emit Transfer(alice, bob, 6);
        token.transferFrom(alice, bob, 6);
    }

    function test_transferFromZeroAmountWithoutAllowanceSucceeds() public {
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromTheZeroAddressRevertsEvenForZero() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InvalidAddress.selector, address(0)));
        token.transferFrom(address(0), bob, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(address(0), bob, 1);
    }

    function test_transferFromToZeroAddressReverts() public {
        vm.prank(deployer);
        token.approve(bob, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InvalidAddress.selector, address(0)));
        token.transferFrom(deployer, address(0), 1);
        assertEq(token.allowance(deployer, bob), 1, "a reverted transferFrom spent allowance");
    }

    function test_transferFromToAThirdPartyWorks() public {
        vm.prank(deployer);
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, 10);
        address carol = makeAddr("carol");
        vm.prank(bob);
        token.transferFrom(alice, carol, 10);
        assertEq(token.balanceOf(carol), 10);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_approvalRaceIsOverwriteNotSum() public {
        // Classic ERC-20 race: alice set 10, bob spends 10, alice sets 5. bob can spend at most 5 more.
        vm.prank(deployer);
        token.transfer(alice, 100);
        vm.prank(alice);
        token.approve(bob, 10);
        vm.prank(bob);
        token.transferFrom(alice, bob, 10);
        vm.prank(alice);
        token.approve(bob, 5);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InsufficientAllowance.selector, bob, 5, 6));
        token.transferFrom(alice, bob, 6);
        vm.prank(bob);
        token.transferFrom(alice, bob, 5);
        assertEq(token.balanceOf(bob), 15);
    }

    // ------------------------------------------------------------------ no owner, no admin, no ETH

    function test_noOwnerOrAdminGetters() public {
        string[6] memory getters = ["owner()", "admin()", "paused()", "isBlacklisted(address)", "minter()", "feeBps()"];
        for (uint256 i; i < getters.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(getters[i], alice));
            assertFalse(ok, getters[i]);
        }
    }

    /// @dev Every privileged call a token might expose is tried from the deployer, the address a token would
    /// most plausibly trust; a holder must still hold what it held and still be able to transfer.
    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000 ether);
        string[14] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "setMaxTx(uint256)",
            "setFee(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(alice), 1_000 ether, "a privileged call moved the holder's balance");
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1_000 ether), "the holder can no longer transfer");
        assertEq(token.balanceOf(bob), 1_000 ether);
    }

    function testFuzz_nobodyCanMintFromAnySelector(bytes4 selector, address caller) public {
        vm.assume(caller != address(0));
        vm.assume(
            selector != SHOODToken.transfer.selector && selector != SHOODToken.transferFrom.selector
                && selector != SHOODToken.approve.selector
        );
        bytes memory data = abi.encodePacked(selector, abi.encode(caller, type(uint256).max));
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        // Any selector other than the view getters must revert; whatever happens, nothing was minted.
        if (ok) {
            assertTrue(
                selector == bytes4(keccak256("name()")) || selector == bytes4(keccak256("symbol()"))
                    || selector == bytes4(keccak256("decimals()")) || selector == SHOODToken.totalSupply.selector
                    || selector == SHOODToken.balanceOf.selector || selector == SHOODToken.allowance.selector
                    || selector == bytes4(keccak256("TOTAL_SUPPLY()")),
                "an unknown selector succeeded"
            );
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(caller), caller == deployer ? SUPPLY : 0);
    }

    function test_noFallbackAndNoReceive() public {
        (bool ok,) = address(token).call("");
        assertFalse(ok, "empty calldata was accepted");
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "unknown selector was accepted");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "the token accepted ETH");
        assertEq(address(token).balance, 0);
    }

    function test_creationCodeHasNoDelegatecallCallcodeOrSelfdestruct() public pure {
        // The brief forbids them "anywhere": the constructor too, not only the runtime (which the smoke
        // suite scans). Creation code is init code followed by the runtime; both are straight-line EVM
        // code with no trailing metadata because foundry.toml sets bytecode_hash = "none".
        bytes memory code = type(SHOODToken).creationCode;
        assertGt(code.length, 0);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL in creation code");
            assertTrue(op != 0xF2, "CALLCODE in creation code");
            assertTrue(op != 0xFF, "SELFDESTRUCT in creation code");
        }
    }

    function test_runtimeFitsEIP170() public view {
        assertLe(address(token).code.length, 24_576);
    }
}
