// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManagerStub, PoolKey, IUnlockCallback, IERC20Minimal} from "./PoolManagerStub.sol";

interface IToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Stands in for ProjectFactory: deploys the token through CREATE2 so the token's constructor sees
/// the factory as msg.sender, holds the supply, answers `distributorOf`, and seeds the pool through the
/// manager's unlock the way the factory will. Only its controller (the test) may drive it.
contract LaunchFactoryProbe is IUnlockCallback {
    address private immutable controller = msg.sender;
    PoolManagerStub private manager;
    mapping(uint64 => address) public distributorOf;

    struct Seed {
        PoolKey key;
        uint256 amount0;
        uint256 amount1;
    }

    modifier onlyController() {
        require(msg.sender == controller, "not the harness");
        _;
    }

    function deploy(bytes memory code, bytes32 salt) external onlyController returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function predict(bytes memory code, bytes32 salt) external view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(code))))));
    }

    function setDistributor(uint64 launchNumber, address distributor) external onlyController {
        distributorOf[launchNumber] = distributor;
    }

    function move(IToken token, address to, uint256 amount) external onlyController returns (bool) {
        return token.transfer(to, amount);
    }

    function initialize(PoolManagerStub manager_, PoolKey calldata key, uint160 price) external onlyController {
        manager_.initialize(key, price);
    }

    function seed(PoolManagerStub manager_, Seed calldata seed_) external onlyController {
        manager = manager_;
        manager_.unlock(abi.encode(seed_));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        Seed memory s = abi.decode(data, (Seed));
        (int256 d0, int256 d1) = manager.addLiquidity(s.key, s.amount0, s.amount1);
        _settle(s.key.currency0, d0);
        _settle(s.key.currency1, d1);
        return "";
    }

    function _settle(address currency, int256 delta) private {
        if (delta >= 0) return;
        manager.sync(currency);
        IERC20Minimal(currency).transfer(address(manager), uint256(-delta));
        manager.settle();
    }
}

/// @notice An ordinary trader: not the factory, not the distributor, nothing the token has any reason to
/// treat specially. Buys and sells through the manager's unlock, paying with a plain `transfer` and
/// receiving through the manager's `take`. `shortfall` lets a test pay less than owed to show the manager
/// refuses a short settlement and the whole swap unwinds.
contract TraderProbe is IUnlockCallback {
    PoolManagerStub private immutable manager;
    PoolKey private key;
    uint256 public shortfall;

    constructor(PoolManagerStub manager_) {
        manager = manager_;
    }

    function setShortfall(uint256 amount) external {
        shortfall = amount;
    }

    function swap(PoolKey calldata key_, bool zeroForOne, int256 amountSpecified)
        external
        returns (int256 amount0, int256 amount1)
    {
        key = key_;
        return abi.decode(manager.unlock(abi.encode(zeroForOne, amountSpecified)), (int256, int256));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (bool zeroForOne, int256 amountSpecified) = abi.decode(data, (bool, int256));
        (int256 amount0, int256 amount1) = manager.swap(key, zeroForOne, amountSpecified, 0);
        _close(key.currency0, amount0);
        _close(key.currency1, amount1);
        return abi.encode(amount0, amount1);
    }

    function _close(address currency, int256 delta) private {
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            manager.sync(currency);
            IERC20Minimal(currency).transfer(address(manager), owed - shortfall);
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        }
    }
}

/// @notice A router that pays the manager by pulling from the trader with `transferFrom` under an
/// allowance, the way a Permit2-style router does, rather than from its own balance.
contract RouterProbe is IUnlockCallback {
    PoolManagerStub private immutable manager;
    PoolKey private key;
    address private payer;

    constructor(PoolManagerStub manager_) {
        manager = manager_;
    }

    function swapFor(address payer_, PoolKey calldata key_, bool zeroForOne, int256 amountSpecified)
        external
        returns (int256 amount0, int256 amount1)
    {
        key = key_;
        payer = payer_;
        return abi.decode(manager.unlock(abi.encode(zeroForOne, amountSpecified)), (int256, int256));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (bool zeroForOne, int256 amountSpecified) = abi.decode(data, (bool, int256));
        (int256 amount0, int256 amount1) = manager.swap(key, zeroForOne, amountSpecified, 0);
        _close(key.currency0, amount0);
        _close(key.currency1, amount1);
        return abi.encode(amount0, amount1);
    }

    function _close(address currency, int256 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            IToken(currency).transferFrom(payer, address(manager), uint256(-delta));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(delta));
        }
    }
}
