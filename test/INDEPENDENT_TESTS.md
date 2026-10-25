# Independent game tests

These additions extend the existing unit, hook integration, deployment and mock
accounting tests. They use the vendored dependencies and need no network, RPC,
environment secrets, generated Solidity, or files from `test/scratch/`.

## Adversarial purchases

`AdversarialMint.t.sol` tests dependency failures after earlier players have already
paid into the reward pot. A digest of receipts, payer totals, native/token balances,
the timer and settlement accounting must remain unchanged. Each rejected attempt
is followed by a valid purchase to verify recovery and contiguous IDs.

The fault cases include missing/duplicate callbacks, reverted swaps, incorrect
settlement, partial/excess/native-credit input deltas, zero/negative output, taxed
or bonus delivery, false/reverting token transfers, and slippage. Other cases cover
both payment overloads, the positive int128 output domain (512 fuzz cases), one raw
token, signed extrema, aggregates exceeding uint128, transaction-origin versus
forwarding-wallet identity, token transfers after purchase, configuration rollback,
cross-function reentrancy, ownership changes and payout event data.

## Real Uniswap v4 sequences

`RealPoolInvariant.t.sol` deploys the unmodified vendored PoolManager and funds a
local ETH/test-token liquidity position. `RealPoolGameHandler` drives eight actions
in random order: purchases through both overloads, outside buys/sells, token
transfers between players, invalid purchases, time advances, finalization, claims,
and forced surplus. Four payers include a wallet that rejects ETH. Inputs are
bounded; expected failures assert their error selectors. Unexpected reverts fail
the campaign. Inline configuration requests 256 runs of 96 calls.

The three invariant functions check:

- Exact native conservation across players, the game, the pool, the external
  trader and liquidity provider; rewards equal 0.02 ETH per successful entry and
  pool purchases consume exactly 0.08 ETH. Forced surplus stays separate.
- Every receipt and payer aggregate matches independently measured delivery.
  Transfers change current holdings without rewriting history. Token supply and
  custody balance, including unrelated market flows.
- The recorded winner has a receipt no greater than any other entry, wins ties
  by earliest ID, and remains fixed after closure. Configuration and the first
  entry's deadline stay fixed.

The handler also checks pool price, liquidity and fee-growth rollback on rejected
swaps. It inspects v4 locks and currency debts inside the same transaction as the
swap, before Forge 1.8 clears transient storage. `afterInvariant` closes any started
game and collects any deferred reward to check withdrawal liveness after every
campaign. Deterministic scenarios exercise sellout with a rejecting winner,
invalid/repeated claims, both market directions, transfers and deferred payment.

The token and pool key are local fixtures, not claims about a particular live IMD
deployment. Market manipulation resistance is not asserted: outside trades are
allowed to change scores under the requested lowest-receipt rule. Hook-specific
integration remains covered by the pre-existing hook tests.

## Reproduction

```sh
forge build --offline
FOUNDRY_FUZZ_SEED=0x5a44408007253f7dff06338b52e2453d3955ea8f86d15e9524ea32cad7bb49b1 forge test --offline
```

To place local compiler artifacts entirely within the disposable test directory,
prefix these commands with
`FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache`.
