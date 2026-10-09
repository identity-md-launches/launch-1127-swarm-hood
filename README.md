# Swarm Hood (SHOOD)

A fixed-supply, plain ERC-20 token for launch on Robinhood Chain (chain id 4663) through the
IdentityMD launch factory, with liquidity in Uniswap v4 paired against IMD.

| | |
|---|---|
| Solidity contract | `SHOODToken` (`src/SHOODToken.sol`) |
| Name / symbol | Swarm Hood / SHOOD |
| Decimals | 18 |
| Total supply | 1,000,000,000 SHOOD = `1000000000000000000000000000` minor units (1e27) |
| Constructor args | none |
| Mint after launch | impossible; there is no mint function |
| Owner / admin | none; every parameter is a compile-time constant |
| Transfer rules | plain ERC-20, no fee, tax, limit, pause or blacklist |
| Proxies / upgradeability | none |
| `delegatecall` / `selfdestruct` | none (checked by test) |

## Build and test

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, the optimizer on, and
`bytecode_hash = "none"` so the deployed bytes are reproducible without a metadata hash. The only
dependency is `forge-std`, vendored as ordinary files under `lib/forge-std` (no git submodule).

## How the launch distributes the supply

The token itself does none of the distribution. Its constructor mints the whole 1e27 units once to
`msg.sender`, which at launch is the factory (`ProjectFactory.launchCustom`). The factory then:

1. sends the swarm's 10% of the supply to the launch's Merkle distributor;
2. seeds the Uniswap v4 pool through the PoolManager at
   `0x8366a39cc670b4001a1121b8f6a443a643e40951` with `economics.poolBps` (90%) of the supply, paired
   with IMD at `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, at the price it derives from
   `economics.initialMarketCapWei` (2,500 IMD for the whole supply) and the deployed currency order;
3. sends any remainder to `economics.remainderTo`.

Because transfers move exactly the requested amount for every caller, the factory, distributor and
PoolManager need no exemptions and the token takes no launch addresses as constructor arguments.

## launch.json

`launch.json` at the repository root is the manifest the brief asked for. `pool.initialPrice` is
provenance only; the deployer derives the actual opening sqrt price from the economics block.

## Assumptions and operational notes

- The deployer is trusted only to be the factory. The token gives the deployer no power beyond the
  balance it holds; after distribution it is an ordinary holder.
- Supply can never increase. It is also never decreased: there is no `burn`. Tokens sent to an
  unreachable address are simply stranded, as with any ERC-20.
- An allowance of `type(uint256).max` is treated as unlimited and is not decremented on
  `transferFrom`, matching OpenZeppelin behaviour that routers and the PoolManager rely on.
- Nothing after launch needs configuring: there is no "After launch" checklist and no setter.
- This repository does not deploy, broadcast or hold keys. Explorer verification of the deployed
  bytecode is the network deployer's step.
- Tests here are smoke tests (deploy, supply, metadata, transfer success and failure, allowance,
  absence of admin selectors and forbidden opcodes). A separate assignment adds fuzz and invariant
  coverage. Tests pass with an empty environment and read no environment variables.
