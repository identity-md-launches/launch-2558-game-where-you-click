# Lowest Mint Game

`LowestMintGame` is a single, finite Ethereum game. Each successful `mint()` costs
exactly **0.1 ETH**, spends **0.08 ETH** buying IMD in one configured Uniswap v4
native ETH/IMD pool, and transfers the purchased IMD directly to the payer. It
retains **0.02 ETH** for the prize. The payer of the entry that received the fewest
tokens wins the accumulated prize when the game sells out.

This repository delivers one application contract: [`src/LowestMintGame.sol`](src/LowestMintGame.sol).
It does not deploy an IMD token, a liquidity pool, a hook, or an NFT. “Mint” means
buying a numbered game entry. The local test tokens, PoolManager and hooks are
fixtures and are not launch contracts.

## Rules and selected assumptions

| Setting | Value / behavior |
| --- | --- |
| `MINT_PRICE` | 0.1 ETH, exact payment only |
| `SWAP_AMOUNT` | 0.08 ETH total native input, including any v4 swap fees |
| `REWARD_PER_MINT` | 0.02 ETH; no owner fee or treasury share |
| `MAX_MINTS` | 100 successful entries; 2 ETH total prize at sellout |
| `GAME_DURATION` | 30 days from the first successful entry |
| Winner | Smallest **individual entry receipt**, in raw IMD units |
| Ties | Earliest successful entry wins |
| Repeat purchases | Allowed; each purchase has its own score |
| Beneficiary | `msg.sender` receives the IMD and owns that entry's prize eligibility |
| Rounds | One game per deployment; no restart |
| Unfilled game | Anyone can finalize at the deadline and pay the current leader |
| Failed entry | The whole transaction reverts, including the swap and ETH payment; gas is still spent |
| Successful entry | Final purchase, with no refund; the buyer already owns the IMD |

The cap, tie rule, repeat-entry treatment and timeout resolve details left open by
the brief. “Fewest tokens” is compared per purchase, not by the payer's lifetime
total or current wallet balance. Moving tokens after purchase never changes a
score. If several entries share the lowest receipt, the first wins without a split.
There is no randomness.

The deadline is fixed by the first successful entry and never extended. Minting is
allowed strictly before `closesAt`. At or after it, minting reverts and anyone may
call `finalize()`. Before any successful entry there is no timer or prize to settle.
An unsold game pays `minted * 0.02 ETH` to its leader at timeout. This avoids an
indefinite prize lock if liquidity disappears or the minimum output becomes
unattainable. Timeout settlement still requires someone to submit a transaction;
there is no autonomous on-chain scheduler.

## Deployment

Deploy **only `LowestMintGame`**, on Ethereum (chain ID 1), with zero ETH and these
two constructor arguments in declaration order:

| Argument | Launch value |
| --- | --- |
| `address initialOwner` | `$owner`, resolving to `0x047f606fd5b2baa5f5c6c4ab8958e45cb6b054b7` |
| `IPoolManager manager` | `0x000000000004444c5dc75cB358380D2e3dE08A90` |

The PoolManager is the Ethereum address published in
[Uniswap's v4 deployment table](https://developers.uniswap.org/docs/protocols/v4/deployments).
Its Ethereum code presence was checked during implementation (24,009 runtime
bytes). This check does not identify the intended IMD pool. The manager address is
immutable; deploy with the canonical address above, not a router or a pool ID.

Ownership comes exclusively from `initialOwner`, including when a factory calls
the constructor. The constructor makes no external calls and does not require
dependency code to exist. It rejects a zero owner or manager. There are no proxies,
initializers, linked external libraries or constructor deployment dependencies.
The launch manifest is supplied by the separate manifest step; none is included here.

### After launch

The IMD token address, v4 fee, tick spacing, hook address and suitable minimum
output were not supplied. They are owner settings, with **no guessed defaults**.
Until configured, both mint entry points revert with `NotConfigured`.

The owner calls:

```solidity
configurePool(PoolKey key, uint256 minimumOutput)
// ABI: configurePool((address,address,uint24,int24,address),uint256)
```

| Setting | What to supply / where to obtain it |
| --- | --- |
| `key.currency0` | Native ETH, encoded as `address(0)`. This is v4's native currency representation, not an unknown address. WETH pairs are not supported. |
| `key.currency1` | The authentic IMD ERC20 address on Ethereum, confirmed against the project's authoritative deployment records and the pool's `Initialize` event. A token symbol alone is not sufficient identification. |
| `key.fee` | The exact fee word from that existing pool's `Initialize` event; static fees or the v4 dynamic fee flag are supported. |
| `key.tickSpacing` | The exact tick spacing from the same event. |
| `key.hooks` | The exact hook address from the same event. Zero is valid only if that pool has no hook. Review any hook and its upgrade/admin powers. |
| `minimumOutput` | A positive absolute IMD output floor in **raw token units**, at most `type(int128).max`. Obtain a fresh quote for a 0.08 ETH exact-input purchase in this specific pool and choose an acceptable minimum. This contract supplies no guessed token price or decimals. |

The setter checks owner authorization, native currency order, tick/fee/hook
validity, dependency code presence and nonzero initialized pool price. It emits
`PoolConfigured`, including the pool ID and all settings. Initialization and code
presence do not prove liquidity depth, authentic IMD identity, safe hook behavior,
or a sensible floor: the owner must verify those before opening the game.

Configuration can be corrected **only before the first successful mint**. That
mint permanently freezes the entire pool key and minimum output. No separate start
transaction is needed. Publish and inspect configuration before accepting entries;
the owner can change it while the entry count is zero. Renouncing ownership before
configuration would leave the game unusable.

Because a correction can land in the same block as the first entries, wallets
should quote against `poolId()` and submit the pool-bound entry point described
below. An entry bound to a pool ID that is no longer configured reverts with
`PoolMismatch` instead of buying a different token, and the owner should not
reconfigure once entries are being solicited.

The selected pool must permit this game contract as the swap caller, empty hook
data, native ETH settlement, and a full 0.08 ETH input. Hooks see the game as their
sender, not the payer. The game does not provide arbitrary hook data, signatures,
allowlist proofs, a WETH adapter or alternate routes. Review compatibility against
the actual IMD token and hook before admitting funds. If a hook requires a different
interface, the application must be adapted before launch; do not configure another
token as a substitute.

## Playing and reading results

Send exactly 0.1 ETH to one of three entry points:

```solidity
game.mint{value: 0.1 ether}();
game.mint{value: 0.1 ether}(minTokensReceived, deadline);
game.mint{value: 0.1 ether}(expectedPoolId, minTokensReceived, deadline);
```

All return `(mintId, tokensReceived)`. Use the three-argument overload for
wallet/UI integration: read `poolId()`, take a fresh off-chain quote for that pool,
supply the user's acceptable minimum, and use a short absolute Unix timestamp
deadline. If the configured pool is not the one quoted (possible only while the
game still has no entries), the entry reverts with `PoolMismatch` and nothing is
bought. The effective minimum is the larger of the user minimum and the frozen pool
floor. Zero user minimum is rejected. The transaction may execute at `deadline`
itself, but never at or after `closesAt`. The two-argument overload offers the same
minimum and deadline without binding the pool. The no-argument overload has no
per-transaction expiry and relies solely on the configured absolute floor; it is
not a fresh percentage-slippage quote.

Useful read methods and events:

- `mints(id)` returns the payer and exact receipt for IDs 1 through `minted()`.
  Unused IDs return the mapping default; they are not entries.
- `mintCountOf(payer)` and `totalTokensReceived(payer)` provide aggregate history.
- `leader()`, `lowestTokens()` and `winningMintId()` identify the current minimum.
- `poolKey()`, `poolId()`, `minimumOutput()`, `closesAt()`, `minted()` and
  `finalized()` expose configuration and lifecycle state.
- `rewardPool()` is the open-game liability, `pendingReward()` the deferred
  winner claim, and `totalRewardsPaid()` the amount already paid.
- `Minted`, `LeaderChanged`, `GameStarted`, `GameFinalized`, `RewardPaid` and
  `RewardDeferred` support indexing and wallet notifications.

A contract wallet or forwarding service is the recorded payer when it calls
`mint`; `tx.origin` is never used. Such a caller must be able to manage its IMD and
invoke `claimRewards` if automatic payment fails. There is no separate recipient
parameter and no one-entry-per-person restriction.

## Prize payment and responsibilities

The last successful mint automatically finalizes the game, includes its own 0.02
ETH contribution, and attempts payment to the winning payer. `finalize()` uses the
same flow after timeout. Both freeze the winner before making any ETH call.

Automatic payment forwards `AUTO_PAYOUT_GAS = 30,000` gas and discards the
winner's return data without copying it, so a winner cannot make settlement cost
more than that allowance. The settling transaction must have at least 100,000 gas
left when payment is attempted; otherwise the whole call reverts with
`InsufficientGasForPayout` and the final entry or `finalize()` must be resubmitted
with more gas. The caller who settles therefore cannot choose a gas limit that
pushes a cooperative winner into the pull path. Only when the winner itself rejects
payment or runs out of its 30,000 gas allowance does the game stay finalized and
emit `RewardDeferred`. The entire prize then remains reserved in `pendingReward`;
the final entry is not cancelled. Only the winning payer may call:

```solidity
game.claimRewards(payable(recipient));
```

The recipient must be nonzero and different from the game. This allows a smart
wallet to redirect payment to an ETH-capable address. A failed claim reverts and
preserves the claim. A paid prize cannot be claimed again. A winning wallet that
cannot receive ETH **or** initiate a claim can strand its own prize; it cannot
prevent other entries or settlement. An operator should monitor deferred prizes
and notify the winning wallet, and submit timeout settlement when needed.

The owner has no withdrawal, pause, reset, upgrade, supply change, winner override,
or post-entry configuration power. Ownership uses OpenZeppelin's two-step transfer
and may be renounced. Transferring or renouncing ownership does not affect claims
or timeout settlement.

Plain ETH transfers are rejected. Forced ETH is not an entry or a reward and is
excluded from the prize accounting; it remains unrecoverable surplus. There is no
rescue function for accidentally sent ERC20s. Send assets only through `mint`.

## Security and economic limits

Swaps follow Uniswap's documented
[unlock and delta-settlement flow](https://developers.uniswap.org/docs/protocols/v4/guides/unlock-callback-and-deltas).
The callback is accepted only from the immutable manager during an active mint,
and only once. The game requires an exact 0.08 ETH debit and a positive output,
explicitly selects native settlement, and checks the payer's balance increase
against the v4 output delta. Partial fills, unexpected input charges, output below
the minimum, taxed delivery and balance-changing/rebasing delivery revert the
whole transaction. Tokens with no transfer return value can work because v4 handles
that transfer; tokens with dishonest balances or unsupported hooks are not safe
dependencies. No approval or token custody by the game is required.

**The game deliberately rewards the worst received price. External trades, MEV,
liquidity changes and dynamic hook fees can influence the winner.** Consecutive buys
in an otherwise unchanged pool tend to give later entrants fewer tokens; the local
real-pool test demonstrates that the last such buyer wins. A trader may manipulate
price to secure a smaller qualifying receipt, potentially for less than the prize.
The output floor and per-call deadline limit an individual trade's execution;
they do not prove a fair market price or prevent reward manipulation. Private
transaction routing does not remove this economic incentive. This is not a fair
lottery or a manipulation-resistant randomness system.

### Open decision for the requester: price manipulation captures the prize

Independent review reproduced the consequence of the rule above with the real v4
core: a trader who, in one block, buys enough IMD to move the pool price, mints
the final entry at the moved price, and sells the IMD back, receives a receipt below
every honest entry and is paid the whole pot inside the same sequence. In the
review's fixture (1000e18 liquidity, 3000 fee) a 20 ETH push cost about 0.14 ETH
in fees and won 2 ETH. The same works at the deadline with `finalize()`.

This is a property of the requested rule, not of a missing check. Any winner
ranking read from the spot swap can be hit by whoever moves the spot price:

- A **bound on price drift** between entries, or a relative slippage band, is bypassed
  by a smaller push that stays inside the band; a band tight enough to block that
  also blocks ordinary price movement over the 30-day game.
- **Scoring against the pre-swap spot price** makes a push in the attacker's favour
  useless but rewards a push in the opposite direction or a liquidity withdrawal,
  and makes all entries in a deep pool tie so that the first entry always wins.
- **Reference prices from earlier blocks** make the attack easier, because the
  attacker's execution still happens at the moved price while the reference does not.

The contract therefore keeps the rule as requested and leaves the decision to the
requester. Options, each a rule change that needs a new build and tests:

1. **Accept it as the game.** Whoever buys at the worst price wins, including someone
   who makes the price bad for themselves. Publish this plainly to players.
2. **Verifiable randomness.** Select the winner among entries with Chainlink VRF,
   optionally weighted toward smaller receipts. The "fewest tokens" receipt becomes a
   weight or a tiebreak instead of the sole rule.
3. **Delayed, bounded execution.** Pay 0.1 ETH now, execute the swap in a later block
   within a tolerance of the price at commitment. This raises the attacker's cost
   and exposure but does not remove the attack, and the IMD no longer arrives in the
   same transaction as the click.

Until the requester chooses, the pot should be regarded as winnable by the best
capitalised trader, and the game should not be marketed as fair to passive players.

These tradeoffs preserve the requested lowest-output rule. Before production use,
an independent contributor must review the contract and the actual IMD token,
pool and hook, and assess whether these economics are acceptable. Local tests are
not an independent security audit. See [`docs/SECURITY.md`](docs/SECURITY.md).

## Build and test offline

Foundry and solc **0.8.26** must be installed. All Solidity dependencies are ordinary
vendored files in `lib/`; no network, environment configuration, submodules or
package installation is needed to build or test. The compiler targets Cancun,
enables optimization at 200 runs and uses `bytecode_hash = "none"`.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x5a44408007253f7dff06338b52e2453d3955ea8f86d15e9524ea32cad7bb49b1 forge test
forge fmt --check
```

The suites include unit failures and success cases, real local Uniswap v4 core
integration (including hooks), stateful accounting invariants, and empty-chain
deployment/bytecode checks. They do not fork the network, read environment variables,
use FFI, or rely on files in `test/scratch`. Dependency versions and licenses are
recorded in [`DEPENDENCIES.md`](DEPENDENCIES.md).
