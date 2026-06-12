# mt5-ea — Master Trading EA

Self-contained MQL5 Expert Advisor with all trading intelligence built-in. Replaces the old Python-based mt5-trader system to enable native MT5 Strategy Tester backtesting.

## Architecture

```
mt5-ea/
├── MQL5/Experts/
│   └── MasterTrader.mq5    ← Master EA (all logic inside)
└── README.md
```

## Strategies (from live session Jun 9-11 2026)

### 1. `shstar_m5_m15` — Shooting Star Reversal (SELL only)
- **M5 closed candle** is a SHOOTING_STAR pattern (upper wick >= 2x body, lower wick < body)
- **M15 UT Bot bias** is BEARISH
- SL: $7.50 | TP: $7.50 (1:1 RR)

### 2. `dc_wick_rejection` — Donchian Wick Rejection (BUY + SELL)
- **BUY**: M15 DC lower wick rejection + M3 UT Bot BULLISH
- **SELL**: M15 DC upper wick rejection + M3 UT Bot BEARISH
- SL: $5.00 | TP: $5.00 (1:1 RR)

## Indicators (computed internally)

| Indicator | Timeframes | Parameters |
|-----------|-----------|------------|
| UT Bot (ATR trailing stop) | M3, M5, M15 | Period=10, Mult=2.0 |
| Donchian Channel | M15 | Length=20 |
| Candle Pattern | M5 | Shooting star detection |

## External Control (CSV-based)

The EA reads `MQL5/Files/ea_control.csv` for runtime switches:

```csv
trading_enabled,true
buy_enabled,true
sell_enabled,true
max_daily_trades,30
cooldown_seconds,120
risk_pct,5.0
```

The EA writes `MQL5/Files/ea_status.csv` with current state (equity, positions, UT Bot bias, trade stats).

This works in **both live trading and backtesting**.

## Setup

1. Copy `MQL5/Experts/MasterTrader.mq5` into your MT5 terminal's `MQL5/Experts/` folder
2. Compile in MetaEditor
3. Attach to XAUUSD chart
4. Optionally place `ea_control.csv` in `MQL5/Files/` for external control

## Backtesting

Open Strategy Tester → select MasterTrader → XAUUSD → set timeframe to M5 → run.

The EA handles multi-timeframe internally (M3, M5, M15), so the chart timeframe just needs to be M5 or lower.
