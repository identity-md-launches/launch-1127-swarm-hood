// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SHOODToken} from "../src/SHOODToken.sol";

/// @notice Smoke tests for the Swarm Hood token: deployment, fixed supply, plain transfers and the
/// absence of any admin surface. A fuller suite (fuzz, invariants) is written separately.
contract SHOODTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @dev Stands in for the launch factory: the token mints its whole supply to whoever deploys it.
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

    // ---------------------------------------------------------------- deployment and metadata

    function test_metadata() public view {
        assertEq(token.name(), "Swarm Hood");
        assertEq(token.symbol(), "SHOOD");
        assertEq(token.decimals(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit();
        emit Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        new SHOODToken();
    }

    // ---------------------------------------------------------------- transfer

    function test_transferMovesExactAmount() public {
        uint256 amount = 123_456 ether;
        vm.prank(deployer);
        vm.expectEmit();
        emit Transfer(deployer, alice, amount);
        assertTrue(token.transfer(alice, amount));

        assertEq(token.balanceOf(alice), amount, "recipient received less than sent");
        assertEq(token.balanceOf(deployer), SUPPLY - amount, "sender charged more than sent");
        assertEq(token.totalSupply(), SUPPLY, "supply changed on transfer");
    }

    function test_transferFullBalanceLeavesZero() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.transfer(alice, 10 ether);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InsufficientBalance.selector, alice, 5 ether, 6 ether));
        token.transfer(bob, 6 ether);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InvalidAddress.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------- approve / transferFrom

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(alice);
        vm.expectEmit();
        emit Approval(alice, bob, 42);
        assertTrue(token.approve(bob, 42));
        assertEq(token.allowance(alice, bob), 42);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InvalidAddress.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 60 ether);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 40 ether));

        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.balanceOf(bob), 40 ether);
        assertEq(token.allowance(alice, bob), 20 ether);
    }

    function test_transferFromInfiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, bob, 100 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InsufficientAllowance.selector, bob, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_transferFromRevertsBeyondBalanceEvenWithAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InsufficientBalance.selector, alice, 1 ether, 2 ether));
        token.transferFrom(alice, bob, 2 ether);
    }

    /// @dev The deployer (the factory) has no special power: without an allowance it cannot pull a
    /// holder's tokens any more than a stranger can.
    function test_deployerCannotPullWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SHOODToken.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    // ---------------------------------------------------------------- no admin surface

    function test_noMintOrAdminSelectorExists() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "blacklist(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], deployer, type(uint128).max);
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }
}
