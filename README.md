# IMD Vault

Vaults nobody owns, for the identity.md ecosystem. A project locks its team tokens and its treasury under rules
written in code, and IMD RADAR shows those rules, and every move, on the project's file.

Built for the Identity MD Hackathon (October 2026). See [SWARM_BRIEF.md](SWARM_BRIEF.md) for the audit and deployment through the IMD swarm.

## Contracts (`src`)

| Contract | What it does |
|---|---|
| `VaultFactory` | Creates vaults and charges 5 IMD once per project (the first vault for a token; later ones are free), paid to IMD RADAR's public wallet to fund its servers and swarm jobs. On chains without IMD (Robinhood) vaults are free to create and the project pays on Ethereum with `payFor(chainId, token)`. It keeps a public registry (`allVaults`, `isVault`, `vaultsByToken`, `creatorOf`). No owner, holds no funds. |
| `VestingVault` | Team tokens: nothing during the cliff, then linear over the duration, which must be at least 4 weeks, so no schedule unlocks more than 25% in any week. Each project picks its own cliff and duration above that floor; `start` can not be in the past, and the whole schedule must fit in a `uint64`. `release()` is callable by anyone and only pays the beneficiary. The duration can only grow. A new beneficiary takes over after 7 days. |
| `TreasuryVault` | Treasuries: anyone deposits tokens or ETH. The manager can only queue a withdrawal; it executes after the delay (at least 24h, at most 30 days, checked by the vault itself), within 14 days of the time it was announced for, only to an allowed destination, and no more than `rateBps` (at most 25%) of the balance can leave per asset per 7-day epoch. Delay can only grow, rate only shrink, destinations only be removed. A new manager takes over after the current delay. |

Nothing has an admin, a pause, an upgrade path or an emergency withdrawal.

### Accounting notes
- Vesting counts `balance + released`, so fee-on-transfer tokens and later top-ups vest on the same schedule.
- The weekly cap is fixed by the first withdrawal executed in an epoch (`rateBps` of the balance at that moment);
  deposits later in the same epoch do not raise it.
- Epochs are fixed calendar weeks (`block.timestamp / 7 days`), not a rolling window. A span of 7 days can straddle
  two epochs, so the most that can leave in any 7 days is `rate + rate × (1 − rate)` of the balance at its start:
  43.75% at the 25% ceiling, in two withdrawals a week apart at most. A rate decrease applies from the next epoch when
  a withdrawal has already executed in the current one.
- Tightening a rule (longer delay, removed destination) also holds back withdrawals already queued, and a pending
  change of manager waits the current delay from its proposal (`pendingManagerEta()`). A withdrawal's expiry is fixed
  when it is queued (`expiresAt = queuedAt + delay + 14 days`), so a longer delay can shorten or close its execution
  window (it is then requeued) but never reopens one that has passed.
- The weekly cap is a rule on the balance, not on the address. The treasury tracks every ERC-20 asset the manager has
  ever queued (`trackedAssets()`), and every ERC-20 withdrawal reads the other tracked balances before and after the
  transfer: a balance that fell is charged against that asset's window too, so a token with two addresses to one
  balance (a legacy contract forwarding to the main token, a proxy and its target) shares one 25% window once both
  addresses have been queued. An address nobody queued keeps a window of its own. A tracked asset that can not be
  read (no code, or a reverting `balanceOf`) is skipped, never a block. The manager alone grows that set and pays for
  the loop it adds, and nothing removes an asset from it. The set trusts what a tracked token answers, so the
  manager must only ever queue tokens whose contract it trusts (never an unsolicited airdrop: leave it where it is).
  A tracked token that later turns hostile can block every ERC-20 withdrawal, though never ETH and never take
  anything: one that lies about its balance (reports it falling when another asset leaves) makes `execute` revert
  `OverWeeklyCap` against its own window; one whose `balanceOf` burns all the gas it is given or returns a huge
  payload makes `execute` run out of gas. The cap is checked only for the asset being withdrawn by its nominal
  amount, so a token that debits the sender more than the amount (a burn on top of the transfer) can let more than
  `rateBps` leave, and `availableThisWeek` answers from the asset's own window only, so for a second address to a
  balance whose main address is spent it can report more than `execute` will allow until that address is tracked.
- The cap (`balance × rateBps`) and the vesting amount (`total × elapsed`) are computed in checked arithmetic, so a
  balance above `2^256 / rateBps` or an allocation above `2^256 / duration` (about `4.6e73` and `4.8e70` base units
  at the 25% ceiling and 28-day floor) makes the cap revert and the vesting revert until the schedule ends. No real
  token's supply comes near those; a `uint256`-max supply token is the only case, and such a token must not be put
  in these vaults.
- A vesting vault releases the whole releasable amount at once, so a token that debits the sender more than the
  amount can not complete the final release of a bound vault; such a token must not be vested here.
- Anyone can execute a due withdrawal, so anyone can choose the moment an epoch's cap is fixed. Executing a small
  withdrawal just before a large deposit lands pins the cap to the pre-deposit balance for that epoch, and a large
  withdrawal queued earlier waits for the next epoch, which opens on the full balance. That is the rule above as
  written; the 14-day grace period covers the wait, so nothing is lost and nothing can be taken.
- The cap is `rateBps` of the balance rounded down, so a balance below `10_000 / rateBps` base units (3 units at
  25%, 9 999 at 1 bps) has a cap of zero until something is deposited, and since each epoch moves at most `rateBps`
  of what is left, an asset decays geometrically and the last dust of it never leaves. That is the rule as written.
- A restricted treasury always keeps at least one destination, so it can never freeze itself.
- `recover()` in a bound vault reads the vested token's balance before and after, so a token with a second entry
  point to the same balance (a legacy or proxy contract) can not move it out early.
- Vesting is calendar-based per token, not per tranche: a top-up of a token the vault already holds (or already
  recorded, in an open vault) is unlocked by the fraction of the schedule that has elapsed, and anything that
  arrives after the schedule has run is releasable at once. The radar counts locked supply as `balance −
  releasable(token)`, never as the balance, and a top-up after the schedule has advanced is not a lock. In an open
  vault a token's arrival is recorded once, the first time `sync` or `release` sees a nonzero balance, and anyone
  holding a wei of a token that already exists can send it and record that arrival early: the real tranche then lands
  as a calendar top-up on that clock. So an open vault's arrival clock is only trustworthy for a token minted in the
  funding transaction itself (an IMD launch), and the radar refuses its seal to an open vault holding a token that
  existed before the vault did; for such a token use a bound vault (`createVesting`).
- An open vesting vault accounts per token address. A token with two addresses to one balance would get a schedule
  per address (up to 43.75% in the first week through both). The contracts can not guard this without a set of
  other assets to watch, which anyone could pad through `sync()`, so the radar refuses its seal to an open vault
  holding such a token (it already reviews the token as legit). An IMD-launched token has one address.

## Locking a launch's supply before the token exists

When the IMD swarm launches a token, 10% of the supply goes to the swarm, part of the requester's 90% seeds the pool,
and the rest is sent to `remainderTo` in the launch transaction (the paying wallet by default). A project can name a
vault there instead, so its share never passes through the team's wallet:

1. Before launching, create the vault: `createLaunchVesting(beneficiary, start, cliff, duration)`, or
   `createTreasury(address(0), manager, delay, rateBps, destinations)`. It pays the 5 IMD fee, keyed to the vault.
2. Put the vault's address as `remainderTo` in the launch body (`economics.remainderTo`).
3. The remainder arrives in the vault when the token launches, and vests or waits behind the treasury rules from then on.
4. For a vesting vault, call `sync(token)` right after the launch (anyone can; the first `release(token)` does it
   too). The launch does not tell the vault, and the token's clock only runs from the recorded arrival.

An open vesting vault (`token` zero) vests every token it receives on the same schedule, so nothing can be pulled out
early by sending it a different token first. Each token's linear unlock starts at the later of `start + cliff` and
its recorded arrival (`arrivedAt`, see `unlockStart(token)`): a launch that slips past the schedule still vests from
the day it pays the vault, never on it. Pick `start` after the launch you expect and the schedule runs exactly as
chosen. On Robinhood, the free factory creates the vault and the fee is paid on Ethereum with `payFor(4663, vault)`.

The fee is keyed to the open vault's address, so a vault made before the launch and a vault made afterwards for the
launched token (`createVesting` or `createTreasury` with the token) are two projects to the factory: each pays 5 IMD.
The contracts can not know the token before it exists; the radar links the open vault to the token off-chain.

## Build and test

Requires [Foundry](https://getfoundry.sh). Dependencies: OpenZeppelin Contracts 5.1.0 and forge-std in `lib`.

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 foundry-rs/forge-std --no-git
forge test
```

The fork test runs against the real IMD token on Ethereum when an RPC is given:

```bash
FORK_RPC=https://rpc.mevblocker.io forge test --match-contract Fork
```

Tests cover the vesting math and cliff, vaults made before a launch that receive its remainder, top-ups, fee-on-transfer tokens, beneficiary and manager timelocks, the
treasury delay, expiry, allowlist, weekly cap and ETH, stricter-only rule changes, the one-time fee (and paying for a Robinhood project), and fuzzing of
the vesting payout, the 25%-a-week vesting ceiling and the treasury weekly cap. `test/Audit.t.sol` holds one test per
audit finding fixed before the launch (see [ADAPTATION.md](ADAPTATION.md)): the start floor, the arrival clock of open
vaults, the schedule overflow, `recover()` against double-entry tokens, the treasury's own 24h floor, the real
bound of the epoch cap, the shared cap of a double-entry token in a treasury, the fixed expiry of a queued
withdrawal, the pending manager's delay, the creator in the registry and the received amount in `VestingCreated`;
and, from the Robinhood launch, that the tree still compiles to the mainnet factory's exact runtime, the zero-argument
factory on chain 4663 and the documented cap-pinning bound.

## Addresses

- IMD (Ethereum): `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`
- VaultFactory (Ethereum, launch 2244): `0xdbaff609cd0500527a2a102f5cbbbbc70fd2ff5b`, `new VaultFactory(IMD, radarWallet)`.
- VaultFactory (Robinhood Chain, 4663): deployed by the IMD launch as `VaultFactoryNoFee`, whose code and immutables
  are exactly `new VaultFactory(address(0), address(0))` of the same audited source; no fee on this chain,
  `payFor(4663, token)` on the Ethereum factory instead.

## The IMD RADAR seal

The radar shows "Locked with IMD Vault" on a token when all of these hold (checked by the radar, not the contracts):
- the project paid the fee (`feePaid[chainId][token]` on the Ethereum factory);
- at least 3% of the supply is locked in its vaults, counted as `balance − releasable(token)`;
- the radar has reviewed the token as legit (and, for an open vesting vault, that it has one address).

Once a token's fee is paid, anyone can register further vaults under it for free, so the radar files a vault under a
project only when `creatorOf(vault)` is the project's wallet (the payer in `FeePaid`, or a wallet the project names),
and reads vaults from the `VestingCreated` and `TreasuryCreated` events (which carry the creator) rather than the
unbounded `vaultsByToken` list. `VestingCreated` logs what the vault received, after any transfer fee of the token.

Locked or burned liquidity is shown as a plus next to the seal.
