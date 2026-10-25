# Local validation

Compiler: Solidity **0.8.26**, pinned in `foundry.toml`. Cancun EVM, optimizer 200
runs, metadata bytecode hash disabled. Application runtime: **8,055 bytes**, below
the 24,576-byte EIP-170 limit, with no unresolved library placeholders.

Completed checks:

| Check | Result |
| --- | --- |
| `forge build` | Pass |
| `forge test` with supplied seed | 62 passed; 0 failed; 0 skipped |
| `forge fmt --check` | Pass |
| Clean rebuild using `forge build --offline` | Pass |
| `forge test --offline -j 4` with cleared environment and supplied seed | 62 passed; 0 failed; 0 skipped |
| Vendored Solidity source comparison against pinned archives | All retained files match upstream bytes |

The cleared-environment run supplies only the executable search path and fuzz seed;
it does not preserve project secrets, RPC configuration or account settings. Tests
make no network calls and require no environment lookups. Download archives and
temporary command logs in `test/scratch` are not used by any delivered build or test.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x5a44408007253f7dff06338b52e2453d3955ea8f86d15e9524ea32cad7bb49b1 forge test
forge fmt --check
```

Test distribution:

- 45 unit/fuzz tests of game behavior, configuration, rollback and payouts.
- 13 integration/fuzz tests using real, locally deployed Uniswap v4 core,
  initialized pools, liquidity and representative hooks.
- 1 empty-chain constructor/runtime policy test, reflecting the supplied
  protected deployment floor without environment-based deployment handoff.
- 3 stateful accounting/model invariants. Each reported 128 runs and 8,192 calls,
  with zero handler reverts. Fuzz tests use 256 cases per fuzz function.

The build emits Foundry lint warnings about timestamp comparisons and explicit
integer casts. Timestamps are used for documented deadlines, never randomness.
Application casts operate on the fixed 0.08 ETH input or on checked positive int128
outputs. Test casts use bounded fixtures. These warnings are not suppressed.

The exact live IMD pool is not covered because its identifying parameters were not
provided. The owner must supply and review that configuration before opening the
game. No independent audit or protected-verifier approval is claimed; see
`SECURITY.md` for the review handoff and economic limitations.
