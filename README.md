# GoalJar — the savings jar that locks itself

**Reactive Omni Buildathon — Track: "Set It and Forget It"**

GoalJar is a two-contract savings jar. You set a goal on an origin chain and
keep depositing. A reactive contract watches every deposit from the Reactive
Network and, the moment your savings cross the goal, it calls back and locks
the money for 30 days. No keeper, no cron job, no "I'll lock it later" —
the lock is triggered by the deposit itself.

## Why

People don't fail to save because they lack a vault; they fail because moving
money into the "do not touch" bucket is a manual step that never happens.
GoalJar removes the step: reaching the goal *is* the lock event.

## How it works

```
Base Sepolia (origin + destination)            Reactive Lasna
┌────────────────────────────┐                 ┌────────────────────────────┐
│ GoalJarVault               │   Deposited     │ GoalJarReactive            │
│ - deposit()  (owner only)  │ ─── event ───▶  │ - subscribes to Deposited  │
│ - flexible / locked funds  │                 │ - accumulates the total    │
│ - onProgress(pct)          │ ◀── callback ── │ - 50% / 90% → onProgress   │
│ - onGoalReached() → lock   │ ◀── callback ── │ - 100% → onGoalReached     │
│   30 days, SavingsLocked   │                 │                            │
└────────────────────────────┘                 └────────────────────────────┘
```

- **GoalJarVault** (`src/GoalJarVault.sol`) lives on Base Sepolia. Only the
  owner can deposit or withdraw flexible funds. Callbacks are accepted only
  from the Reactive callback proxy and only from the registered reactive
  contract (`verifySender` pattern). `onGoalReached` moves the whole flexible
  balance into a 30-day lock and emits `SavingsLocked`.
- **GoalJarReactive** (`src/GoalJarReactive.sol`) lives on Reactive Lasna. It
  subscribes to the vault's `Deposited` events through the Reactive system
  contract (Omni `subscribeV_1_0`), keeps a running total per vault, and
  requests callbacks (`requestCallbackV_1_0`) at the 50% and 90% milestones
  and at 100% of the goal. It pays its own fees via `AbstractPayer`.

Built against the current Omni reactive library
(`Reactive-Network/reactive-lib-omni` v0.1.0).

## Deployed contracts

| Contract | Chain | Address |
|---|---|---|
| GoalJarVault | Base Sepolia (84532) | `0xd3b2Ed28a817bf4160b7217824475808C0ee822d` |
| GoalJarReactive | Reactive Lasna (5318007) | `0x843F7f7019D27D87c9458a9979298B090A2dC0A7` |

Goal: 0.006 ETH. Lock period: 30 days.

## Full-loop proof (origin → react → callback)

Setup transactions:

| Step | Chain | Tx |
|---|---|---|
| Faucet: Sepolia ETH → lREACT | Sepolia → Lasna | `0x6a25fa8554f6211822766cfb0c4a9edd6358cd15f5179eb9ef32c65242661831` |
| Bridge gas to Base Sepolia | Sepolia → Base Sepolia | `0xf88c26f67c52be0ae7f2f89106fc0cfc68fb38d14aa89dd23ec8e4aa891dad3c` |
| Deploy GoalJarReactive | Lasna | `0x58924d07481f4abd9a4581c9c46206db8402cf87ce9f81aedba9968f295513ae` |
| Fund reactive reserves (`depositTo`) | Lasna | `0x5c09452647933024afd5e90ddf4f1fc33dd0c7c45f5f87781465b09ded6af8ce` |
| Deploy GoalJarVault | Base Sepolia | `0x526d33aeef861d5195f0d3190ee9913e0c9ac4030fc40ad00c821121b867d4c1` |
| Fund callback reserves (`depositTo`) | Base Sepolia | `0xf1366aa30b1acb14cf93b72b885830690c426bcd466e7ff057dc7ff2b4c3130d` |
| Start subscription (`start`) | Lasna | `0x6d4e92fd59efcb814bb26461f9e279c86c0b8644095c2d65cf54a7950c327fdd` |

The loop itself — three deposits, three reactive reactions, three callbacks:

| # | Deposit (Base Sepolia) | Reactive tx (Lasna) | Callback (Base Sepolia) | Effect |
|---|---|---|---|---|
| 1 | `0x52b90699d2f4bf95f3734833545394da542674d54c90d7a21f81903dbcd95d89` (0.003 ETH, 50%) | `0x67ae1bf7aaa7d922216ffbe223dab091e839cfd43db25f9375f0cc2a2c7038a7` | `0x26938c86293f886e085a24a4fab99a2203dd09f6f650e29f199ac419e780119b` | `ProgressMarked(0.003 / 0.006 ETH)` |
| 2 | `0x7e92e0dced9fd06eb114e8bda77d9b8209a50c909261d658f35a46aa0373d172` (0.0024 ETH, 90%) | `0xf21e66e0263c5c61bd6df189844ad4292ac19375ae7da03a6f260e97c9ff7364` | `0xb587f35c420b79e55239c85c78fd3211faed46b506202ddc0188d7d93b1c4a3a` | `ProgressMarked(0.0054 / 0.006 ETH)` |
| 3 | `0xd168cd8a1f18fee4e036e4261bf773a91ccffb0b1fe352bc325237f6b93939cd` (0.0012 ETH, 110%) | `0x3a1a6f8fe04bef48db0678a5b09e2660aba87fcada767482ef3ef921d5bc5d4d` | `0xe59a6ab1217d4270c2667802461377c027a01fcbb8584ff462ec8785b2012f2f` | `SavingsLocked(0.0066 ETH, 30 days)` |

Final vault state: `goalFired = true`, flexible 0, locked 0.0066 ETH.

## Build

Requires [Foundry](https://getfoundry.sh). The Reactive Omni library is not
vendored in this repo — fetch it first:

```bash
forge install Reactive-Network/reactive-lib-omni@v0.1.0
forge build
```

`foundry.toml` already maps `@reactive/` to `lib/reactive-lib-omni/`, so the
contracts in `src/` compile as-is once the library is installed.

RPC endpoints for both chains are preconfigured in `foundry.toml`
(`lasna`, `base_sepolia`). Deployment and day-to-day operations (funding the
fee reserves via `depositTo`, calling `start`, deposits, state reads) are
plain contract calls against those endpoints — use your own deployer key
from a local, git-ignored `.env` (see `.gitignore`); never commit keys.

## Notes / limitations

- Testnet demo: the vault holds ETH on Base Sepolia; the same design works
  for ERC-20 savings goals.
- Withdrawals of locked funds open after the 30-day lock; flexible funds can
  be withdrawn by the owner at any time.

## License

MIT — see [LICENSE](LICENSE).
