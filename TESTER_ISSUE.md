# MT5 Strategy Tester — 10044 "Only position closing is allowed" on Wine/Docker

## Problem

Every `OrderSend()` in the MT5 Strategy Tester returns `TRADE_RETCODE_CLOSE_ONLY` (10044) — "Only position closing is allowed". Zero trades execute across the entire backtest. The same EA, same account, same broker works perfectly on a Windows desktop.

## Environment

### VPS (FAILS)
- **OS:** RHEL 9 (Azure VM, Intel Xeon Platinum 8370C, 2 cores)
- **Container:** Podman, linuxserver.io base (Debian Bookworm), KasmVNC
- **Wine:** 11.0
- **MT5:** PXBT Trading MT5 Terminal x64 build 5836, portable mode (`/portable`)
- **User:** runs as `abc` (UID 1000)

### Desktop (WORKS)
- **OS:** Windows 11 build 26200
- **MT5:** Same broker, same build 5836
- **Account:** Same account 1262395

### Broker
- **Broker:** PXBT Trading Ltd
- **Server:** PXBTTrading-1
- **Account:** 1262395 (live, hedging mode)
- **Symbol:** XAUUSD (Gold)

## EA Details
- **Name:** MasterTrader v2.1
- **File:** `MasterTrader.mq5` (~1270 lines)
- **Uses:** `CTrade::OrderSend()` for market orders (BUY/SELL)
- **Does NOT use:** `TRADE_ACTION_CLOSE_BY`, `AccountInfoInteger(ACCOUNT_LOGIN)`

## Configuration

### Config file used on VPS (tester.ini)

```ini
[Common]
Login=1262395
Password=****
Server=PXBTTrading-1
KeepPrivate=1

[Tester]
Expert=MasterTrader.ex5
Symbol=XAUUSD
Period=M1
Optimization=0
Model=1
FromDate=2026.06.08
ToDate=2026.06.12
ForwardMode=0
Deposit=10000
Currency=USD
ProfitInPips=0
Leverage=100
ExecutionMode=0
OptimizationCriterion=0
Visual=0
ShutdownTerminal=1
UseLocal=1
UseRemote=0
UseCloud=0
ReplaceReport=1
Report=Z:\data\reports\backtest_report

[TesterInputs]
INP_RiskPct=7.5||3.0||0.300000||30.000000||N
INP_GlobalSL=4.5||7.5||0.750000||75.000000||N
INP_GlobalRR=1.2||1.0||0.100000||10.000000||N
INP_Magic=300||300||1||3000||N
; ... (more EA parameters)
```

### Desktop config (working.ini — NO [Common] section)

```ini
[Tester]
Expert=MasterTrader.ex5
Symbol=XAUUSD
Period=M1
Optimization=0
Model=1
FromDate=2026.06.06
ToDate=2026.06.13
; ... same parameters ...

[TesterInputs]
; ... same parameters ...
```

Desktop has **no `[Common]` section** — it relies on the already-running terminal's authenticated session.

### Launch command (VPS)

```bash
wine terminal64.exe /portable /config:C:\Program Files\PXBT Trading MT5 Terminal\Config\tester.ini
```

## Error Log (VPS Agent)

```
Core 1  2026.06.09 04:00:00  failed market buy 1 XAUUSD sl: 4251.95 tp: 4266.95 [Only position closing is allowed]
Core 1  2026.06.09 04:00:00  CTrade::OrderSend: market buy 1.00 XAUUSD sl: 4251.95 tp: 4266.95 [unknown retcode 10044]
...
(ALL orders fail with same error, at ALL times of day, ALL days of week in test range)
...
Core 1  final balance 10000.00 USD
Core 1  TOTAL: 0 trades  W:0 L:0  WR:0%  PnL:$0.00
Core 1  XAUUSD,M1: 22048 ticks, 5512 bars generated. Environment synchronized in 0:00:00.036. Test passed in 0:00:04.163.
```

## Working Log (Desktop Agent)

```
Network  27568 bytes of account info loaded
Network  1478 bytes of tester parameters loaded
Network  74948 bytes of input parameters loaded
Network  1281 bytes of symbols list loaded (209 symbols)
Tester   expert file added: Experts\MasterTrader.ex5. 109042 bytes loaded
Tester   initial deposit 10000.00 USD, leverage 1:100
Tester   successfully initialized
Symbols  XAUUSD: symbol synchronized, 4120 bytes of symbol info received
History  XAUUSD: history synchronized from 2025.01.01 to 2026.06.12
Tester   XAUUSD,M1: testing of Experts\MasterTrader.ex5 from 2026.06.06 00:00 to 2026.06.13 00:00 started
...
Trades   2026.06.06 03:13:20  market buy 1 XAUUSD ... [done at 4274.42]
(trades execute successfully)
```

## Root Cause (Suspected)

The broker (PXBT Trading) sets `SYMBOL_TRADE_MODE` to `SYMBOL_TRADE_MODE_CLOSEONLY` for XAUUSD during weekends/market-closed hours. When the VPS terminal starts:

1. Terminal connects to broker via `[Common]` credentials
2. Broker sends current symbol specification with `SYMBOL_TRADE_MODE_CLOSEONLY`
3. Terminal passes this spec to the tester agent
4. Agent applies this restriction to the ENTIRE historical backtest
5. Every order is rejected with 10044

**Desktop works because:**
- Terminal was started during market hours (spec = `SYMBOL_TRADE_MODE_FULL`)
- The spec is cached in memory while the terminal runs
- Tester uses the cached in-memory spec, not a fresh broker download
- Desktop's `working.ini` has no `[Common]` — it reuses the running terminal's session

**VPS fails because:**
- Container starts fresh each time → fresh broker connection → fresh spec download
- During weekends, broker returns CLOSEONLY → tester gets CLOSEONLY
- Even seeding `symbols.dat` from desktop doesn't help — live broker connection overrides cached file in memory

## What We Tried

| # | Approach | Result |
|---|----------|--------|
| 1 | No `[Common]` section (like desktop) | "account is not specified" — can't start tester |
| 2 | `[Common]` with Login+Password+Server | Tester runs but all trades fail with 10044 |
| 3 | `[Common]` with Login+Server only (no Password) | "not synchronized with trade server" |
| 4 | Pre-sync: launch terminal with full auth, kill after 30s, then launch tester with Login+Server only | Tester starts but "not synchronized" — agent gets no account/symbol data |
| 5 | Single session: one config with `[Common]` + `[Tester]` (no kill/restart) | Terminal authenticates, syncs, starts tester — but still 10044 |
| 6 | Add `Login=123456` (dummy) to `[Tester]` section | Removed — per docs `[Tester] Login` is just emulated account for `AccountInfoInteger()`, not auth |
| 7 | Change test dates to Mon-Thu only (avoid Friday) | Same 10044 — not date-related |
| 8 | Seed desktop `symbols.dat` into container before launch | File is correct on disk (176KB) but terminal overrides in memory when connecting to broker |
| 9 | Clean agent bases cache before each run | Still 10044 |
| 10 | Add `KeepPrivate=1` to preserve password | No effect on 10044 |

## Key Observations

- The error occurs at ALL simulated hours (00:00 through 23:59) across ALL test days
- Agent log shows `Environment synchronized in 0:00:00.037` — tester IS running a local simulation
- Desktop agent shows `27568 bytes of account info loaded` + `4120 bytes of symbol info received` — VPS agent gets these from the terminal process
- The symbol spec includes `SYMBOL_TRADE_MODE` which controls what operations are allowed
- `SYMBOL_TRADE_MODE_CLOSEONLY` → 10044 on any new position
- `SYMBOL_TRADE_MODE_FULL` → no restrictions (what desktop has cached)

## Questions

1. **Is there a way to force `SYMBOL_TRADE_MODE_FULL` in the tester config or via MQL5 code?**
2. **Can the tester agent be told to ignore the symbol trade mode restriction for backtesting?**
3. **Is there a way to prevent MT5 terminal from overwriting cached symbol specs when connecting during weekends?**
4. **Can Wine/headless MT5 be configured to use offline/cached specs instead of fetching from broker?**
5. **Are there known workarounds for brokers that set CLOSEONLY during market-closed hours in the context of backtesting?**

## Files

- `working.ini` — Desktop tester config (works)
- `working.log` — Desktop agent log (shows successful trades)
- `symbols-1262395.dat` — Desktop symbol spec cache (176KB, has FULL mode)
- `selected-1262395.dat` — Desktop selected symbols list
- `MQL5/Experts/MasterTrader.mq5` — EA source code
