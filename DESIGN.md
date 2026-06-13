# MasterTrader EA — Complete Technical Documentation

## 1. Overview

**MasterTrader.mq5** is a single-file MQL5 Expert Advisor (~1255 lines) that implements an expression-based multi-strategy trading system for MetaTrader 5. It was designed to replace a previous Python-based system (`mt5-trader`) that used CSV signal passing, by computing all indicators natively inside the EA.

**Target instrument:** XAUUSD (gold), though it works on any symbol.  
**Broker:** PXBT Trading MT5 Terminal (demo).  
**Version:** 2.1

### Design Goals
1. **Self-contained** — no external dependencies, no Python bridge, no CSV signal pipeline. Everything runs inside MT5 natively.
2. **Expression-driven** — strategies are defined as human-readable condition strings in input parameters. No recompilation needed to change strategy logic.
3. **Extensible** — 15 pre-configured strategies + 5 empty custom slots. New strategies can be added by editing input strings in the MT5 UI.
4. **Backtestable** — all file I/O disabled by default so Strategy Tester runs at full speed.

---

## 2. Architecture

The EA is organized into 11 sections:

```
SECTION 1:  Input Parameters (risk, trade mgmt, trailing, indicators, 20 strategy slots)
SECTION 2:  Constants & Structures (timeframes, limits, Strategy struct)
SECTION 3:  Global State (trade tracking, signal registry, indicator handles)
SECTION 4:  Initialization (OnInit / OnDeinit / LoadStrategies)
SECTION 5:  Event Handlers (OnTimer / OnTick / OnTrade)
SECTION 6:  Signal Computation (all indicator functions)
SECTION 7:  Signal Registry + Expression Engine (SigSet/SigGet/Parse/Eval)
SECTION 8:  Trade Execution (ExecuteTrade / CalcLotSize)
SECTION 9:  Trailing Stop (ManageTrailingStop)
SECTION 10: Position Helpers (CountOpenPositions)
SECTION 11: External Control (ReadControlFile / WriteStatusFile)
```

### Data Flow

```
OnTick()
  │
  ├─ ManageTrailingStop()       ← every tick (if enabled)
  │
  ├─ for each timeframe:
  │     if new bar detected:
  │       ComputeAllSignals(tf)  ← writes to signal registry
  │
  ├─ for each sub-daily TF:
  │     ComputeCandleForBar(tf, 0, "live_")  ← running candle, every tick
  │
  ├─ Trading filters (enabled? position limit? cooldown? consec loss?)
  │
  └─ for each strategy:
        EvalAllConditions(buyCond)  ← reads from signal registry
        EvalAllConditions(sellCond)
          → if match: ExecuteTrade()
```

---

## 3. Signal Registry

The core abstraction is a flat key-value store:

```cpp
string g_sigKeys[700];   // e.g. "utbot_M15.bias"
string g_sigVals[700];   // e.g. "BULLISH"
int    g_sigCount = 0;
```

**Why flat arrays instead of a hash map?**  
MQL5 does not have a native hash map. Using flat arrays with linear scan is simple and reliable. With ~300-400 active signals, the O(n) scan is negligible compared to indicator computation cost. A binary search or hash could optimize lookups but would add complexity for minimal gain at this scale.

### Signal Key Convention

Format: `indicator_TIMEFRAME.field`

| Indicator | Prefix | Fields |
|-----------|--------|--------|
| UT Bot | `utbot_TF` | `.bias` `.signal` `.bullish_since` `.bearish_since` |
| Donchian | `dc_TF` | `.zone` `.upper_wick_rej` `.lower_wick_rej` `.width` |
| EMA | `ema{N}_TF` | `.price_vs` `.slope` `.value` |
| RSI | `rsi{N}_TF` | `.value` `.zone` |
| ADX | `adx_TF` | `.value` `.strength` `.di_bias` |
| MACD | `macd_TF` | `.cross` `.hist_dir` `.vs_zero` |
| Stochastic | `stoch_TF` | `.k` `.zone` |
| Bollinger | `bb_TF` | `.squeeze` `.reenter_below` |
| ATR | `atr_TF` | `.value` |
| VWAP | `vwap_TF` | `.price_vs` `.value` |
| Candle | `candle_TF` | `.type` `.dir` `.is_bullish` `.is_bearish` `.upper_wick_ratio` `.lower_wick_ratio` `.body_pct` |
| Candle (live) | `candle_TF` | `.live_type` `.live_dir` etc. (same fields, prefixed with `live_`) |

### Naming Decisions

- **No `closed_` prefix** — the default is always the closed bar. We don't prefix the common case.
- **`bullish_since` / `bearish_since`** — counts how many bars the UT Bot bias has been in the current direction. Named to describe what it measures ("how long since the bias turned") rather than the old system's "consecutive_bull_bars" which was confusing.
- **No parameter numbers on single-variant indicators** — `adx` not `adx14`, `macd` not `macd12_26_9`, `stoch` not `stoch5_3_3`, `bb` not `bb20d2`. The parameters are fixed in input settings; cluttering the key name with them adds no information. EMA and RSI keep the number (`ema50`, `rsi2`) because multiple variants coexist.

---

## 4. Expression Engine

### Syntax

Strategies are defined as pipe-separated conditions. All conditions must be true (AND logic).

```
condition1|condition2|condition3
```

Each condition is: `signal_key operator value`

### Operators

| Operator | Example | Meaning |
|----------|---------|---------|
| `==` | `utbot_M15.bias==BULLISH` | Equality (case-insensitive) |
| `!=` | `utbot_M15.bias!=BEARISH` | Not equal |
| `>=` | `utbot_M5.bullish_since>=2` | Numeric greater-or-equal |
| `<=` | `rsi2_M5.value<=5` | Numeric less-or-equal |
| `>` | `candle_M3.upper_wick_ratio>2` | Numeric greater |
| `<` | `rsi2_M5.value<20` | Numeric less |
| `in` | `dc_M15.zone in UPPER,UPPER_MID` | Set membership |
| `not_in` | `dc_M5.zone not_in LOWER,UPPER` | Set exclusion |

### Parsing Logic (`ParseCondition`)

1. First scans for word operators (` in `, ` not_in `) — these require surrounding spaces to avoid false matches in key names.
2. Then scans for symbol operators in length order (`>=` before `>`) to avoid ambiguity.
3. Splits into: key, operator, value. All trimmed.

### Evaluation (`EvalCondition`)

- Looks up the key in the signal registry via `SigGet()`.
- If the key is not found (returns ""), the condition fails. This is a safety measure — if an indicator didn't compute (not enough bars), the strategy won't fire.
- String comparisons are case-insensitive (`StringCompare` with `false`).
- For `in` / `not_in`, the value is split on commas and each element is trimmed.
- For `>=`, `<=`, `>`, `<`, both sides are converted to double for numeric comparison.

### Why No OR Logic?

OR would require parentheses and a recursive parser. The old Python system never needed OR — all strategies are AND-only combinations. If OR is needed in the future, it could be added with a `||` separator or by splitting into multiple strategy entries.

---

## 5. Indicator Implementations

### 5.1 UT Bot (`ComputeUTBot`)

The UT Bot is an ATR-based trailing stop crossover system. It's not a standard MT5 indicator — it's computed from scratch.

**Algorithm:**
1. Compute ATR(period) for each bar using the native `iATR` handle.
2. Build a trailing stop array:
   - If price > previous trailing stop: trailing = max(price - mult*ATR, previous trailing). Direction = bullish.
   - If price <= previous trailing stop: trailing = min(price + mult*ATR, previous trailing). Direction = bearish.
3. **Bias**: direction of closed bar (bullish/bearish).
4. **Signal**: "BUY" when direction flips from bearish to bullish on the closed bar, "SELL" for the reverse. Only flashes for one bar.
5. **bullish_since / bearish_since**: counts consecutive bars in the same direction, walking backward from the closed bar.

**Why computed from bar 0 to bar N (chronological order)?**  
The trailing stop is path-dependent — each bar's value depends on the previous bar. MQL5's `CopyClose` with `ArraySetAsSeries(false)` (the default) returns data in chronological order, which is what we need.

**Parameters:** `INP_UTBot_Period=10`, `INP_UTBot_Mult=2.0` (configurable via inputs).

### 5.2 Donchian Channel (`ComputeDC`)

**Algorithm:**
1. Copy the last `INP_DC_Length` bars of highs and lows (starting from bar 1 = closed bar).
2. Upper band = highest high, lower band = lowest low.
3. **Zone**: where the closed bar's close falls within the channel (5 zones: LOWER, LOWER_MID, MIDDLE, UPPER_MID, UPPER based on 20/40/60/80 percentile thresholds).
4. **Wick rejection**: checks if the bar's wick pierced the band but the close retreated inside. Requires: (a) the wick reached the band, (b) wick length > body size, (c) close is inside the band.

**Why wick > body instead of a fixed ratio?**  
A wick rejection means the market tried to break the band but was rejected. If the wick is longer than the body, it shows strong rejection regardless of absolute size.

### 5.3 EMA (`ComputeEMA`)

Uses native `iMA` handles for EMA 9, 21, 50, 200.

**Fields:**
- `price_vs`: whether closed bar's close is ABOVE or BELOW the EMA.
- `slope`: compares EMA value on closed bar vs 3 bars earlier. RISING/FALLING/FLAT (with _Point tolerance to avoid noise).
- `value`: raw EMA value.

**Why 4 separate handles per TF instead of one parameterized function?**  
MQL5 indicator handles are created once in `OnInit` and reused. Each unique (symbol, tf, period) combination needs its own handle. Creating them upfront is the MQL5-native pattern for efficiency.

### 5.4 RSI (`ComputeRSI`)

Two variants: RSI(14) and RSI(2).

**Zone thresholds differ by period:**
- RSI(2): EXTREME_OB (>95), OB (>80), EXTREME_OS (<5), OS (<20), NEUTRAL
- RSI(14): OB (>70), OS (<30), NEUTRAL

**Why different thresholds?**  
RSI(2) is a mean-reversion indicator with wider swings. Standard 70/30 thresholds would rarely trigger. The extreme zones (5/95) are specifically for strategies like `rsi2_mean_rev_full` that catch extreme oversold bounces.

### 5.5 ADX (`ComputeADX`)

Uses native `iADX` handle (period 14).

**Fields:**
- `strength`: STRONG_TREND (>=40), TRENDING (>=25), WEAK_TREND (>=20), RANGING (<20)
- `di_bias`: BULLISH (+DI > -DI by >1), BEARISH (reverse), NEUTRAL

### 5.6 MACD (`ComputeMACD`)

Uses native `iMACD` handle (12, 26, 9).

**Fields:**
- `cross`: CROSS_UP (MACD crosses above signal), CROSS_DOWN (reverse), NONE
- `hist_dir`: RISING or FALLING (comparing current vs previous histogram)
- `vs_zero`: ABOVE or BELOW

### 5.7 Stochastic (`ComputeStoch`)

Uses native `iStochastic` handle (5, 3, 3, SMA, LowHigh).

**Fields:**
- `k`: raw %K value
- `zone`: OB (>80), OS (<20), NEUTRAL

### 5.8 Bollinger Bands (`ComputeBB`)

Uses native `iBands` handle (20, 0, 2.0).

**Fields:**
- `squeeze`: TRUE if current bandwidth < 75% of previous bar's bandwidth
- `reenter_below`: TRUE if previous bar closed below lower band and current bar closed above it

### 5.9 ATR (`ComputeATR`)

Uses native `iATR` handle (period 14). Outputs raw value only.

### 5.10 VWAP (`ComputeVWAP`)

Session-based VWAP computed from midnight (server time).

**Algorithm:**
1. Find session start (midnight of current day).
2. Copy all bars from session start to now.
3. Accumulate: typical price (H+L+C/3) * tick volume.
4. VWAP = cumulative(TP*V) / cumulative(V).
5. Compare closed bar's close to VWAP.

**Why tick volume instead of real volume?**  
Most forex/CFD brokers don't provide real volume. Tick volume is the standard proxy in MT5.

**Why skip daily+ timeframes?**  
VWAP is an intraday indicator. On daily bars, there's only one bar per session — the concept doesn't apply.

### 5.11 Candle Patterns (`ComputeCandleForBar`)

Reusable function that works on any bar index with a prefix parameter:
- `ComputeCandleForBar(tf_idx, 1, "")` → closed bar → keys like `candle_M3.type`
- `ComputeCandleForBar(tf_idx, 0, "live_")` → running bar → keys like `candle_M3.live_type`

**Pattern classification (in priority order):**
1. **DOJI**: total range <= 1 point, or body < 10% of range
2. **MARUBOZU**: body >= 80% of range (strong directional candle)
3. **HAMMER**: lower wick >= 2x body, upper wick < body
4. **SHOOTING_STAR**: upper wick >= 2x body, lower wick < body
5. **SPINNING_TOP**: body < 40% of range, both wicks > 0.5x body
6. **NORMAL**: everything else

**Additional fields:**
- `dir`: UP / DOWN / DOJI
- `is_bullish` / `is_bearish`: TRUE/FALSE
- `upper_wick_ratio` / `lower_wick_ratio`: wick size divided by body size (numeric, for threshold conditions like `>=2`)
- `body_pct`: body as percentage of total range

**Why body_safe uses _Point as minimum?**  
To avoid division by zero on doji candles where body = 0.

---

## 6. Strategy Definitions

Each strategy has 6 fields as input parameters:
- `On` (bool): enable/disable
- `SL` (double): stop loss in dollars (price distance from entry)
- `RR` (double): reward:risk ratio (TP = SL * RR)
- `Buy` (string): pipe-separated buy conditions
- `Sell` (string): pipe-separated sell conditions

### The 15 Strategies

These were ported from the original `config-gold.yaml` file used in the Python system. The conditions are identical in logic, only the signal key naming changed.

#### S01: dc_wick_rejection (SL=5.0, RR=1.0)
- **BUY**: DC lower wick rejection on M15 + UT Bot M3 bullish
- **SELL**: DC upper wick rejection on M15 + UT Bot M3 bearish
- **Logic**: Price tests the Donchian band edge, gets rejected (long wick), and the short-term UT Bot confirms direction.

#### S02: trend_2w_m2_ema50_bounce2_vwap (SL=7.5, RR=1.0)
- **SELL only**: UT Bot M2 sell signal + price below EMA50 on M5 + UT Bot M5 bullish for >=2 bars (bounce) + below VWAP on M1
- **Logic**: Short-term sell signal after a 2+ bar bounce in a bearish trend, confirmed by EMA and VWAP.

#### S03: trend_2w_m2_m15bear_bounce2_vwap (SL=7.5, RR=1.0)
- **SELL only**: Like S02 but uses M15 bearish bias instead of EMA50.
- **Logic**: Variation of the bounce-sell with higher timeframe trend confirmation.

#### S04: dc2w_m3_h1bear_dcupper_vwap (SL=7.5, RR=1.0)
- **SELL only**: UT Bot M3 sell + H1 bearish + DC M15 in upper zone + below VWAP
- **Logic**: Selling at the top of the Donchian channel when the hourly trend is bearish.

#### S05: hammer_2w_m15_dc (SL=7.5, RR=1.0)
- **BUY only**: Hammer candle on M3 + 2+ bearish bars on M5 (pullback) + M15 bullish + DC lower zone
- **Logic**: Hammer reversal at channel bottom after a pullback in an uptrend.

#### S06: doji_dc_upper_m15 (SL=7.5, RR=1.0)
- **SELL only**: Doji on M3 + DC upper zone on M15 + M15 bearish
- **Logic**: Indecision at the top of the channel in a bearish trend.

#### S07: shstar_m5_m15 (SL=7.5, RR=1.0)
- **SELL only**: Shooting star on M5 + M15 bearish
- **Logic**: Bearish reversal candle confirmed by higher TF trend.

#### S08: wick2x_dc_h1_vwap_sell (SL=7.5, RR=1.0)
- **SELL only**: Upper wick ratio >=2 + bearish candle on M3 + DC upper zone + H1 bearish + below VWAP
- **Logic**: Strong upper wick (rejection) with multiple bearish confirmations. The strictest sell strategy.

#### S09: dc_mid_hammer_2w_m15 (SL=7.5, RR=1.0)
- **BUY only**: DC middle zone on M5 + 2+ bearish bars + hammer on M3 + M15 bullish
- **Logic**: Hammer at the channel midpoint after a pullback.

#### S10: dc_mid_shstar_2w_m15 (SL=7.5, RR=1.0)
- **SELL only**: Mirror of S09 — shooting star at midpoint after a bullish bounce.

#### S11: dc_lowmid_hammer_2w_m15 (SL=7.5, RR=1.0)
- **BUY only**: Like S09 but allows LOWER_MID or MIDDLE zone. Wider entry zone.

#### S12: dc_upmid_shstar_2w_m15 (SL=7.5, RR=1.0)
- **SELL only**: Mirror of S11 — UPPER_MID or MIDDLE zone.

#### S13: rsi2_mean_rev_full (SL=3.0, RR=1.5)
- **BUY only**: RSI(2) extreme oversold on M5 + price above EMA200 on M15 + ADX trending/strong + H1 bullish
- **Logic**: Mean reversion buy. Tight SL ($3) with higher RR (1.5). Only buys in strong uptrends (EMA200 + ADX + H1 bias) when RSI(2) is extremely oversold (<5).

#### S14: ema50_dc_wick_h1 (SL=3.0, RR=2.0)
- **BUY only**: EMA50 slope rising on M15 + DC lower wick rejection on M15 + H1 bullish
- **Logic**: Trend-following buy on a pullback to the channel bottom with rising EMA. Tightest SL ($3) with best RR (2.0).

#### S15: rsi2_dc_wick (SL=3.0, RR=1.0)
- **BUY only**: RSI(2) extreme oversold on M5 + above EMA200 on M15 + DC lower wick rejection on M15
- **Logic**: Combining mean reversion (RSI2) with channel support (DC wick rejection).

---

## 7. Trade Execution

### Lot Sizing (`CalcLotSize`)

```
risk_amount = equity * risk_pct / 100
cash_per_lot = (sl_dollars / tick_size) * tick_value
lot = risk_amount / cash_per_lot
```

Then clamped to min/max lot and rounded down to lot step.

**Why `sl_dollars` (price distance) instead of pips?**  
Gold (XAUUSD) is quoted in dollars per ounce. A $7.50 SL on gold means the price can move $7.50 against us. This is more intuitive and broker-independent than pips, which vary in meaning across instruments.

### Order Placement

- Uses MQL5's `CTrade` class from `<Trade/Trade.mqh>`.
- Fill mode auto-detected from broker's `SYMBOL_FILLING_MODE` flags (FOK, IOC, or RETURN).
- Comment format: `MT|strategy_name` — used later by `OnTrade()` to attribute wins/losses to strategies.
- SL and TP are set as absolute price levels (entry ± dollars).

### Trade Management Filters

Applied in order in `OnTick()`:

1. **g_tradingEnabled** — master kill switch (from ea_control.csv)
2. **Position limit** — if `MultiPosition=false`, only 1 position at a time. If true, up to `MaxPositions`.
3. **Daily trade limit** — `MaxDailyTrades` per calendar day (reset at midnight server time).
4. **Cooldown** — `CooldownSec` seconds must pass between any two trades.
5. **Consecutive loss pause** — after `MaxConsecLoss` losses in a row, pause for `consecLosses * ConsecLossPause` seconds. The multiplier means longer pauses after longer losing streaks.
6. **Reversal cooldown** — if the last trade was a BUY, a SELL must wait `ReversalCooldown` seconds (and vice versa). Prevents whipsawing.

### Strategy Priority

Strategies are evaluated in order (S01 first, S20 last). The **first** strategy whose conditions match fires the trade. This means S01 has highest priority. After a trade is executed, `OnTick()` returns immediately — no further strategies are evaluated until the next tick.

---

## 8. Trailing Stop (`ManageTrailingStop`)

Runs every tick (before signal computation). Two stages:

### Breakeven
If `BreakevenStart > 0` and unrealized profit >= BreakevenStart dollars:
- Move SL to entry + 1 point (just above/below entry to lock in breakeven).
- Only fires once (checked by `sl < entry` for buys, `sl > entry` for sells).
- After breakeven is applied, skip trailing for this tick (`continue`).

### Trailing
If `TrailStart > 0` and unrealized profit >= TrailStart dollars:
- For BUY: newSL = current bid - TrailStep. Only move SL up, never down.
- For SELL: newSL = current ask + TrailStep. Only move SL down, never up.

**Why breakeven before trailing?**  
Breakeven is a one-time event. Once SL is at entry, the trailing logic takes over on subsequent ticks as profit grows further.

**Both are disabled by default** (set to 0.0) since the strategies use fixed SL/TP risk-reward.

---

## 9. Per-Strategy Stats (`OnTrade`)

`OnTrade()` is called by MT5 whenever a deal occurs. The EA:

1. Selects full deal history via `HistorySelect(0, TimeCurrent())`.
2. Iterates only new deals since last check (`g_lastDealCount`).
3. Filters for our magic number and exit deals only (`DEAL_ENTRY_OUT`).
4. Computes net profit (profit + swap + commission).
5. Matches the deal's comment to a strategy name via `StringFind`.
6. Updates per-strategy W/L/PnL and global counters.
7. Resets `g_consecLosses` on a win, increments on a loss.

**On `OnDeinit`** (EA removed or backtest ends), prints a summary table:

```
=========== STRATEGY RESULTS ===========
  dc_wick_rejection                   W:12  L:8   WR:60%  PnL:$142.50
  shstar_m5_m15                       W:5   L:3   WR:63%  PnL:$67.20
  TOTAL: 28 trades  W:17 L:11  WR:61%  PnL:$209.70
========================================
```

---

## 10. Running Candle

`ComputeCandleForBar` is a reusable function:

```cpp
ComputeCandleForBar(tf_idx, 1, "");      // closed bar → candle_M3.type
ComputeCandleForBar(tf_idx, 0, "live_"); // running bar → candle_M3.live_type
```

The running candle is computed **every tick** for all sub-daily timeframes. This allows strategies to react to patterns forming on the current bar before it closes.

**Known performance impact:** This is the main bottleneck during backtesting. None of the current 15 strategies use `live_` fields, so it's computing signals that are never evaluated. A future optimization would auto-detect whether any strategy references `live_` and skip the computation if not.

**How to use in a strategy:**
```
candle_M3.live_type==SHOOTING_STAR|utbot_M15.bias==BEARISH
```
This would trigger as soon as the M3 running candle forms a shooting star shape, rather than waiting for bar close.

---

## 11. Timeframes

11 timeframes supported, covering M1 to W1:

```
M1, M2, M3, M5, M10, M15, M30, H1, H4, D1, W1
```

**Why no M45?**  
M45 is not a native MT5 timeframe. The original Python system used M45 in strategies S04 and S08, but it was computed synthetically by aggregating M15 bars. In native MQL5, we substituted H1 as the closest standard timeframe.

**Why all 11 TFs always computed?**  
The EA creates indicator handles for all 11 TFs in `OnInit`. Signals are recomputed per-TF only when a new bar is detected on that TF. Higher TFs (H4, D1, W1) get new bars very rarely, so the cost is minimal. This ensures any strategy can reference any TF without code changes.

---

## 12. External Control

Both disabled by default (`INP_UseControlFile=false`, `INP_WriteStatusFile=false`).

### ea_control.csv (read)
Polled every `ControlPollSec` seconds via `OnTimer`. Contains key-value pairs:
```
trading_enabled,true
buy_enabled,true
sell_enabled,false
```
Allows external scripts to pause/resume trading without touching the EA.

### ea_status.csv (write)
Written every 10 seconds of simulated time. Contains current state: symbol, time, positions, trades, PnL, equity.

**Why disabled by default?**  
File I/O in the Strategy Tester is extremely slow. Writing ea_status.csv every 10 simulated seconds caused the V1 backtest to be 100x slower. These are live-trading features only.

---

## 13. Known Issues & Future Work

### Performance
- **Running candle every tick** — major bottleneck in backtesting. Should auto-detect `live_` usage and skip if unused.
- **Signal registry linear scan** — O(n) lookup for ~400 keys. Could use a sorted array with binary search or a hash, but current performance is acceptable.
- **All indicators on all TFs** — computes indicators on TFs that no strategy references. Could be optimized by scanning strategy strings at init to determine which TF/indicator combos are needed.

### Functionality
- **No OR logic** — only AND (pipe-separated). Could add `||` as OR separator if needed.
- **No cross-bar conditions** — can't express "RSI was oversold 2 bars ago". Would need a history buffer.
- **No partial close** — always full position close via SL/TP. No scaling out.
- **Single magic number** — all strategies share one magic. Can't distinguish active positions by strategy.
- **VWAP session start** — hardcoded to midnight server time. Some brokers have different session boundaries.

### SL/TP Model
- SL and TP are in **dollar price distance** (e.g., $7.50 means XAUUSD entry at 2650 → SL at 2642.50 or 2657.50).
- This is correct for gold but may need adjustment for other instruments where dollar distance doesn't map intuitively.

---

## 14. Input Parameter Reference

### Global Risk
| Parameter | Default | Description |
|-----------|---------|-------------|
| `INP_RiskPct` | 3.0 | % of account equity risked per trade |
| `INP_GlobalSL` | 7.5 | Fallback SL if strategy SL=0 |
| `INP_GlobalRR` | 1.0 | Fallback reward:risk if strategy RR=0 |

### Trade Management
| Parameter | Default | Description |
|-----------|---------|-------------|
| `INP_Magic` | 300 | Magic number to identify this EA's orders |
| `INP_MultiPosition` | false | Allow multiple open positions |
| `INP_MaxPositions` | 1 | Max positions (if multi enabled) |
| `INP_MaxDailyTrades` | 15 | Trades per day limit |
| `INP_CooldownSec` | 300 | Min seconds between trades |
| `INP_ReversalCooldown` | 300 | Min seconds before trading opposite direction |
| `INP_MaxConsecLoss` | 3 | Pause after N consecutive losses (0=off) |
| `INP_ConsecLossPause` | 1800 | Seconds to pause per consecutive loss |
| `INP_Slippage` | 20 | Max slippage in points |

### Trailing Stop
| Parameter | Default | Description |
|-----------|---------|-------------|
| `INP_BreakevenStart` | 0.0 | Move SL to entry after $X unrealized profit (0=off) |
| `INP_TrailStart` | 0.0 | Start trailing after $X unrealized profit (0=off) |
| `INP_TrailStep` | 2.0 | Trailing distance in dollars |

### Indicator Parameters
| Parameter | Default | Description |
|-----------|---------|-------------|
| `INP_UTBot_Period` | 10 | ATR period for UT Bot |
| `INP_UTBot_Mult` | 2.0 | ATR multiplier for UT Bot |
| `INP_DC_Length` | 20 | Donchian Channel lookback length |

### Strategy Slots (S01-S20)
Each slot has:
| Field | Type | Description |
|-------|------|-------------|
| `On` | bool | Enable/disable this strategy |
| `SL` | double | Stop loss in dollars (0 = use global) |
| `RR` | double | Reward:risk ratio (0 = use global) |
| `Buy` | string | Pipe-separated buy conditions |
| `Sell` | string | Pipe-separated sell conditions |
