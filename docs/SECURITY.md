# Security review notes

This is an implementation self-review and a handoff for the required independent
review. It is not an audit certification. Only `LowestMintGame` is an application
contract; contracts in `test/` and the local v4 core are fixtures.

## Accounting model

For `n` successful entries:

```text
native input settled with v4 = n * 0.08 ETH
rewardPool + pendingReward + totalRewardsPaid = n * 0.02 ETH
contract ETH balance >= rewardPool + pendingReward
```

Equality holds in the last relation absent forced ETH. The unit and stateful tests
also check conservation across payer balances, the manager balance and the game.
Every stored receipt equals both the actual transfer increase at purchase and the
v4 swap output. Receipt history is immutable; current token holdings are irrelevant.

No operation loops over entries in production. Leader selection and settlement
take constant work. At most 100 receipts and one eventual winner claim exist.

## Trust boundaries and adversarial cases

| Boundary | Protection and remaining assumption |
| --- | --- |
| Factory / deployment | Explicit owner argument, nonpayable constructor, no external constructor calls, immutable public manager dependency. Tests reproduce empty-chain deployment and scan reachable runtime opcodes. |
| Owner / configuration | Owner-only setter, live code and initialized-pool checks, event with complete settings, frozen after first success. Before then, the owner can select any eligible pool and floor; users must verify identity, not just the token symbol. |
| Payer / callback | Reentrancy guard spans swap, accounting and payout. Callback requires the exact manager, active mint guard and one-use payer context. No arbitrary payer or recipient can be injected in callback bytes. |
| Swap / reward custody | Fixed negative exact-input amount; returned native debit must be exactly 0.08 ETH. Partial fills and unexpected hook input deltas revert before settlement. A hook's ERC20 sync is reset to native. Existing rewards cannot finance a swap. |
| Token / score | Snapshot immediately around manager-to-payer transfer, require receipt equals positive delta, then record measured increase. Fee-on-transfer, bonus/rebasing delivery and false/reverting transfers fail atomically. Honest ERC20 balance reporting is required. |
| Hook / score | Hook effects are already included in returned v4 deltas. Output fees can lower receipt and influence score. A reviewed hook must accept empty data and the game as caller. Permission bits do not establish that a hook is safe. |
| Prize / recipient | Finalized state and zeroed claim precede ETH calls. Automatic gas is bounded and failures preserve a pull claim. A failed manual claim restores accounting by revert. No loser or owner may claim another payer's prize. |
| Time / liveness | Fixed 30-day cutoff from first entry. No entry at the cutoff. Anyone can settle then, without touching the token or manager. No keeper is built in. Timestamp ordering near the boundary is not a randomness source. |
| Administrative lifecycle | Two-step transfer. No pause, upgrade, emergency withdrawal, reset or winner rewrite. Renouncing before configuration prevents opening; renouncing after configuration does not block players. |
| Unsolicited funds | Direct ETH rejected; forced ETH never changes entry count or rewards. Forced ETH and accidentally sent tokens cannot be rescued. |

The callback deliberately is not itself marked `nonReentrant`: it must execute
inside the guarded mint. It checks that guard is active and consumes its context
before swap, settlement, hook and token interactions. Ordinary mint, configuration,
finalization and prize claims are guarded.

## Economic limitation requiring explicit review

The prize is tied to an executable market price, not to randomness. A participant
can trade in the pool before entering; an LP can alter liquidity; a hook operator
can change fees; validators/searchers can order transactions. None of these need
to violate contract access controls to change the winning score. The frozen output
floor bounds the worst accepted receipt but can still be targeted by an adversary.

The real-pool integration test provides a concrete baseline: with fixed liquidity
and no external sells, each of 100 consecutive 0.08 ETH buys yields less IMD, so the
100th entry wins the entire 2 ETH prize. An external manipulator may create that
advantage sooner. Removing this incentive would require changing the requested
selection rule; it is not silently treated as solved by slippage checks.

## Evidence and open operational work

Unit tests cover exact payment, unconfigured operation, setter authorization and
locking, transfer semantics, payment conservation, ties, repeats, final-entry
accounting, late entry, partial fills, minimum output, deadlines, callback forgery,
missing/duplicate callbacks, reentrancy, rejected prizes, gas exhaustion and retry.
Integration tests deploy unmodified v4 core locally and fund actual liquidity,
exercise price movement, compare receipts to balances, and verify rollback of pool
state. Hook integration tests cover dynamic fees, output fees, reentry and native
settlement after an ERC20 sync. Stateful tests use an independent model of entries,
scores, closure, balances and one-time payout.

The supplied protected deployment floor is represented by a local test without
its environment-variable handoff. The actual protected harness remains the
verifier's responsibility. Its owner-check base was not included among the inputs;
local tests directly check explicit ownership under factory-style deployment.

Before production opening, the owner and independent reviewer must identify the
authentic IMD pool, inspect its token/hook behavior and administrative controls,
simulate a complete purchase on that pool, select the output floor, and accept the
market manipulation risk. The exact live IMD integration could not be exercised
because its token address and pool key were not supplied. These are configurable
values, not guessed constructor addresses. Explorer verification and actual
deployment belong to the authorized launch process.

No Slither, Mythril, external audit, live transaction, or production-fund test is
claimed by this work.
