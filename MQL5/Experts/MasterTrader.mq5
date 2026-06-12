//+------------------------------------------------------------------+
//| MasterTrader.mq5 — Self-contained trading EA with built-in       |
//| indicator logic and external control via CSV files.               |
//| Strategies ported from live mt5-trader session (Jun 9-11 2026).  |
//|                                                                  |
//| Strategies:                                                      |
//|   1. shstar_m5_m15  — M5 shooting star + M15 UT Bot bearish     |
//|   2. dc_wick_rej    — DC M15 wick rejection + M3 UT Bot bias    |
//|                                                                  |
//| External control: reads ea_control.csv from MQL5/Files           |
//| Status output:    writes ea_status.csv to MQL5/Files             |
//+------------------------------------------------------------------+
#property copyright "mt5-ea"
#property version   "1.00"
#property strict
#property description "Master EA — all intelligence inside, external control via CSV"

#include <Trade/Trade.mqh>

//=== Input Parameters ================================================
input group "=== Risk Management ==="
input double INP_RiskPct       = 5.0;      // Risk % of equity per trade
input double INP_SL_ShStar     = 7.5;      // SL dollars: shstar_m5_m15
input double INP_SL_WickRej    = 5.0;      // SL dollars: dc_wick_rejection
input double INP_RR_ShStar     = 1.0;      // Reward ratio: shstar_m5_m15
input double INP_RR_WickRej    = 1.0;      // Reward ratio: dc_wick_rejection

input group "=== UT Bot Settings ==="
input int    INP_UTBot_Period  = 10;       // ATR period for UT Bot
input double INP_UTBot_Mult    = 2.0;      // ATR multiplier for UT Bot

input group "=== Donchian Channel ==="
input int    INP_DC_Length     = 20;       // Donchian Channel length

input group "=== Strategy Enables ==="
input bool   INP_Enable_ShStar   = true;   // Enable shstar_m5_m15
input bool   INP_Enable_WickRej  = true;   // Enable dc_wick_rejection

input group "=== Trade Management ==="
input int    INP_Magic          = 300;     // Magic number
input int    INP_MaxDailyTrades = 30;      // Max trades per day
input int    INP_CooldownSec   = 120;      // Cooldown between trades (sec)
input int    INP_Slippage      = 20;       // Max slippage (points)

input group "=== External Control ==="
input bool   INP_UseControlFile = true;    // Read ea_control.csv for switches
input int    INP_ControlPollSec = 5;       // Control file poll interval (sec)

//=== Global State ====================================================
CTrade         g_trade;
datetime       g_lastTradeTime    = 0;
int            g_dailyTradeCount  = 0;
datetime       g_lastDay          = 0;
int            g_totalTrades      = 0;
int            g_totalWins        = 0;
int            g_totalLosses      = 0;
double         g_totalPnL         = 0;

// Indicator handles
int            g_atr_m3_handle    = INVALID_HANDLE;
int            g_atr_m5_handle    = INVALID_HANDLE;
int            g_atr_m15_handle   = INVALID_HANDLE;

// External control state (overridable via file)
bool           g_tradingEnabled   = true;
bool           g_buyEnabled       = true;
bool           g_sellEnabled      = true;
int            g_maxDailyTrades   = 0;  // 0 = use input
int            g_cooldownSec      = 0;  // 0 = use input
double         g_riskPct          = 0;  // 0 = use input

// Control file polling
datetime       g_lastControlRead  = 0;

//+------------------------------------------------------------------+
//| Initialization                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(INP_Magic);
   g_trade.SetDeviationInPoints(INP_Slippage);
   g_trade.SetTypeFilling(ORDER_FILLING_FOK);

   // Create ATR handles for UT Bot on M3, M5, M15
   g_atr_m3_handle  = iATR(_Symbol, PERIOD_M3,  INP_UTBot_Period);
   g_atr_m5_handle  = iATR(_Symbol, PERIOD_M5,  INP_UTBot_Period);
   g_atr_m15_handle = iATR(_Symbol, PERIOD_M15, INP_UTBot_Period);

   if(g_atr_m3_handle == INVALID_HANDLE ||
      g_atr_m5_handle == INVALID_HANDLE ||
      g_atr_m15_handle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR handles");
      return INIT_FAILED;
   }

   // Initialize external control from inputs
   g_maxDailyTrades = INP_MaxDailyTrades;
   g_cooldownSec    = INP_CooldownSec;
   g_riskPct        = INP_RiskPct;

   EventSetTimer(1);

   Print("MasterTrader started on ", _Symbol,
         " | ShStar=", INP_Enable_ShStar,
         " | WickRej=", INP_Enable_WickRej,
         " | Risk=", INP_RiskPct, "%",
         " | Magic=", INP_Magic);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_atr_m3_handle  != INVALID_HANDLE) IndicatorRelease(g_atr_m3_handle);
   if(g_atr_m5_handle  != INVALID_HANDLE) IndicatorRelease(g_atr_m5_handle);
   if(g_atr_m15_handle != INVALID_HANDLE) IndicatorRelease(g_atr_m15_handle);

   WriteStatusFile();
   Print("MasterTrader stopped. Trades: ", g_totalTrades,
         " W:", g_totalWins, " L:", g_totalLosses,
         " PnL:", DoubleToString(g_totalPnL, 2));
}

//+------------------------------------------------------------------+
//| Timer — check strategies every second                             |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Poll external control file
   if(INP_UseControlFile)
   {
      datetime now = TimeCurrent();
      if(now - g_lastControlRead >= INP_ControlPollSec)
      {
         ReadControlFile();
         g_lastControlRead = now;
      }
   }

   // Write status periodically
   static int statusCounter = 0;
   if(++statusCounter >= 10) { WriteStatusFile(); statusCounter = 0; }
}

//+------------------------------------------------------------------+
//| Tick — main trading logic                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   // Reset daily counter on new day
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today = StringToTime(IntegerToString(dt.year) + "." +
                                 IntegerToString(dt.mon) + "." +
                                 IntegerToString(dt.day));
   if(today != g_lastDay)
   {
      g_dailyTradeCount = 0;
      g_lastDay = today;
   }

   // Check if we should trade at all
   if(!g_tradingEnabled) return;

   // Already have a position with our magic?
   if(HasOpenPosition()) return;

   // Daily trade limit
   int maxDaily = (g_maxDailyTrades > 0) ? g_maxDailyTrades : INP_MaxDailyTrades;
   if(g_dailyTradeCount >= maxDaily) return;

   // Cooldown check
   int cooldown = (g_cooldownSec > 0) ? g_cooldownSec : INP_CooldownSec;
   if(TimeCurrent() - g_lastTradeTime < cooldown) return;

   // Only evaluate on new closed bar (M5 timeframe drives the main loop)
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // === Strategy 1: shstar_m5_m15 (SELL only) ===
   if(INP_Enable_ShStar && g_sellEnabled)
   {
      if(CheckShStarM5M15())
      {
         double riskPct = (g_riskPct > 0) ? g_riskPct : INP_RiskPct;
         ExecuteSell("shstar_m5_m15", INP_SL_ShStar, INP_RR_ShStar, riskPct);
         return;
      }
   }

   // === Strategy 2: dc_wick_rejection (BUY and SELL) ===
   if(INP_Enable_WickRej)
   {
      int wickSignal = CheckDCWickRejection();
      if(wickSignal == 1 && g_buyEnabled)
      {
         double riskPct = (g_riskPct > 0) ? g_riskPct : INP_RiskPct;
         ExecuteBuy("dc_wick_rej", INP_SL_WickRej, INP_RR_WickRej, riskPct);
         return;
      }
      if(wickSignal == -1 && g_sellEnabled)
      {
         double riskPct = (g_riskPct > 0) ? g_riskPct : INP_RiskPct;
         ExecuteSell("dc_wick_rej", INP_SL_WickRej, INP_RR_WickRej, riskPct);
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Trade event — track wins/losses                                   |
//+------------------------------------------------------------------+
void OnTrade()
{
   static int lastDeals = 0;
   if(!HistorySelect(0, TimeCurrent())) return;

   int totalDeals = HistoryDealsTotal();
   for(int i = lastDeals; i < totalDeals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != INP_Magic) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      g_totalTrades++;
      g_totalPnL += profit;
      if(profit >= 0) g_totalWins++;
      else g_totalLosses++;

      string resultStr = (profit >= 0) ? "WIN" : "LOSS";
      Print("Trade CLOSED: ", resultStr, " $", DoubleToString(profit, 2),
            " | Total: W", g_totalWins, " L", g_totalLosses,
            " PnL:", DoubleToString(g_totalPnL, 2));
   }
   lastDeals = totalDeals;
}

//=====================================================================
//  STRATEGY 1: shstar_m5_m15
//  SELL when M5 candle is SHOOTING_STAR + M15 UT Bot bias BEARISH
//=====================================================================
bool CheckShStarM5M15()
{
   //--- Check M5 closed candle for SHOOTING_STAR pattern
   double m5_open  = iOpen(_Symbol, PERIOD_M5, 1);
   double m5_high  = iHigh(_Symbol, PERIOD_M5, 1);
   double m5_low   = iLow(_Symbol, PERIOD_M5, 1);
   double m5_close = iClose(_Symbol, PERIOD_M5, 1);

   if(!IsShootingStar(m5_open, m5_high, m5_low, m5_close))
      return false;

   //--- Check M15 UT Bot bias
   int m15_bias = GetUTBotBias(PERIOD_M15, g_atr_m15_handle);
   if(m15_bias != -1) // Not bearish
      return false;

   Print("SIGNAL: shstar_m5_m15 SELL — M5 SHOOTING_STAR + M15 BEARISH");
   return true;
}

//=====================================================================
//  STRATEGY 2: dc_wick_rejection
//  BUY:  DC M15 lower wick rejection + UT Bot M3 BULLISH
//  SELL: DC M15 upper wick rejection + UT Bot M3 BEARISH
//  Returns: 1=BUY, -1=SELL, 0=no signal
//=====================================================================
int CheckDCWickRejection()
{
   //--- DC M15: compute upper/lower bands
   double dc_upper = 0, dc_lower = 0;
   if(!GetDonchianBands(PERIOD_M15, INP_DC_Length, dc_upper, dc_lower))
      return 0;

   //--- Get M15 closed bar
   double cls_open  = iOpen(_Symbol, PERIOD_M15, 1);
   double cls_high  = iHigh(_Symbol, PERIOD_M15, 1);
   double cls_low   = iLow(_Symbol, PERIOD_M15, 1);
   double cls_close = iClose(_Symbol, PERIOD_M15, 1);

   //--- Wick rejection detection
   double body_top    = MathMax(cls_open, cls_close);
   double body_bottom = MathMin(cls_open, cls_close);
   double upper_wick  = cls_high - body_top;
   double lower_wick  = body_bottom - cls_low;
   double body_size   = body_top - body_bottom;

   bool upper_wick_rej = (cls_high >= dc_upper) &&
                         (upper_wick > body_size) &&
                         (cls_close < dc_upper);

   bool lower_wick_rej = (cls_low <= dc_lower) &&
                         (lower_wick > body_size) &&
                         (cls_close > dc_lower);

   //--- Get UT Bot M3 bias
   int m3_bias = GetUTBotBias(PERIOD_M3, g_atr_m3_handle);

   //--- BUY signal
   if(lower_wick_rej && m3_bias == 1)
   {
      Print("SIGNAL: dc_wick_rej BUY — M15 lower_wick_rej + M3 BULLISH");
      return 1;
   }

   //--- SELL signal
   if(upper_wick_rej && m3_bias == -1)
   {
      Print("SIGNAL: dc_wick_rej SELL — M15 upper_wick_rej + M3 BEARISH");
      return -1;
   }

   return 0;
}

//=====================================================================
//  UT BOT — compute bias from ATR trailing stop
//  Returns: 1=BULLISH, -1=BEARISH
//=====================================================================
int GetUTBotBias(ENUM_TIMEFRAMES tf, int atr_handle)
{
   int lookback = INP_UTBot_Period + 100; // enough bars for computation
   int bars = Bars(_Symbol, tf);
   if(bars < lookback) lookback = bars;
   if(lookback < INP_UTBot_Period + 3) return 0;

   double close_arr[], atr_arr[];
   ArraySetAsSeries(close_arr, false);
   ArraySetAsSeries(atr_arr, false);

   if(CopyClose(_Symbol, tf, 0, lookback, close_arr) < lookback) return 0;
   if(CopyBuffer(atr_handle, 0, 0, lookback, atr_arr) < lookback) return 0;

   // Compute trailing stop + direction
   double trail = close_arr[0];
   double dir   = 1;

   for(int i = INP_UTBot_Period; i < lookback; i++)
   {
      double nLoss     = INP_UTBot_Mult * atr_arr[i];
      double prev_stop = trail;
      double prev_dir  = dir;

      if(close_arr[i] > prev_stop)
      {
         trail = close_arr[i] - nLoss;
         if(prev_dir > 0) trail = MathMax(trail, prev_stop);
         dir = 1;
      }
      else
      {
         trail = close_arr[i] + nLoss;
         if(prev_dir < 0) trail = MathMin(trail, prev_stop);
         dir = -1;
      }
   }

   // Return bias of the last closed bar (index lookback-2)
   // But since we computed sequentially, `dir` is the bias of last bar (lookback-1)
   // We need the closed bar bias, which is the second-to-last
   // Re-compute to get closed bar specifically
   double trail_arr[];
   double dir_arr[];
   ArrayResize(trail_arr, lookback);
   ArrayResize(dir_arr, lookback);

   for(int i = 0; i < INP_UTBot_Period && i < lookback; i++)
   {
      trail_arr[i] = close_arr[i];
      dir_arr[i] = 1;
   }

   for(int i = INP_UTBot_Period; i < lookback; i++)
   {
      double nLoss = INP_UTBot_Mult * atr_arr[i];
      double ps    = trail_arr[i - 1];
      double pd    = dir_arr[i - 1];

      if(close_arr[i] > ps)
      {
         trail_arr[i] = close_arr[i] - nLoss;
         if(pd > 0) trail_arr[i] = MathMax(trail_arr[i], ps);
         dir_arr[i] = 1;
      }
      else
      {
         trail_arr[i] = close_arr[i] + nLoss;
         if(pd < 0) trail_arr[i] = MathMin(trail_arr[i], ps);
         dir_arr[i] = -1;
      }
   }

   // Closed bar = lookback-2 (the last fully completed bar)
   int cls = lookback - 2;
   return (int)dir_arr[cls];
}

//=====================================================================
//  Candle Pattern — Shooting Star detection
//  upper_wick >= 2x body AND lower_wick < body
//=====================================================================
bool IsShootingStar(double open, double high, double low, double close)
{
   double body_top    = MathMax(open, close);
   double body_bottom = MathMin(open, close);
   double body_size   = body_top - body_bottom;
   double upper_wick  = high - body_top;
   double lower_wick  = body_bottom - low;
   double total_range = high - low;

   if(total_range <= _Point) return false;      // doji / no range
   double body_pct = (body_size / total_range) * 100.0;
   if(body_pct < 10.0) return false;            // too small body = doji

   double body_safe = (body_size > _Point) ? body_size : _Point;

   return (upper_wick >= 2.0 * body_safe) && (lower_wick < body_safe);
}

//=====================================================================
//  Donchian Channel — highest high / lowest low of N bars
//=====================================================================
bool GetDonchianBands(ENUM_TIMEFRAMES tf, int length,
                      double &upper, double &lower)
{
   // Use bars 2..length+1 to get the channel at the closed bar
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   if(CopyHigh(_Symbol, tf, 2, length, highs) < length) return false;
   if(CopyLow(_Symbol, tf, 2, length, lows) < length) return false;

   upper = highs[ArrayMaximum(highs)];
   lower = lows[ArrayMinimum(lows)];

   return true;
}

//=====================================================================
//  Trade Execution
//=====================================================================
void ExecuteBuy(string strategy, double sl_dollars, double rr, double riskPct)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double lot = CalcLotSize(riskPct, sl_dollars);
   if(lot <= 0) return;

   double price = tick.ask;
   double sl    = NormalizeDouble(price - sl_dollars, _Digits);
   double tp    = NormalizeDouble(price + sl_dollars * rr, _Digits);

   string comment = "MT|" + strategy;
   if(g_trade.Buy(lot, _Symbol, price, sl, tp, comment))
   {
      g_lastTradeTime = TimeCurrent();
      g_dailyTradeCount++;
      Print("TRADE OPENED: BUY ", DoubleToString(lot, 2), " @ ",
            DoubleToString(price, _Digits),
            " SL=", DoubleToString(sl, _Digits),
            " TP=", DoubleToString(tp, _Digits),
            " [", strategy, "]");
   }
   else
   {
      Print("TRADE FAILED: BUY ", strategy,
            " error=", GetLastError());
   }
}

void ExecuteSell(string strategy, double sl_dollars, double rr, double riskPct)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double lot = CalcLotSize(riskPct, sl_dollars);
   if(lot <= 0) return;

   double price = tick.bid;
   double sl    = NormalizeDouble(price + sl_dollars, _Digits);
   double tp    = NormalizeDouble(price - sl_dollars * rr, _Digits);

   string comment = "MT|" + strategy;
   if(g_trade.Sell(lot, _Symbol, price, sl, tp, comment))
   {
      g_lastTradeTime = TimeCurrent();
      g_dailyTradeCount++;
      Print("TRADE OPENED: SELL ", DoubleToString(lot, 2), " @ ",
            DoubleToString(price, _Digits),
            " SL=", DoubleToString(sl, _Digits),
            " TP=", DoubleToString(tp, _Digits),
            " [", strategy, "]");
   }
   else
   {
      Print("TRADE FAILED: SELL ", strategy,
            " error=", GetLastError());
   }
}

//=====================================================================
//  Position Sizing — percentage of equity
//=====================================================================
double CalcLotSize(double riskPct, double sl_dollars)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * riskPct / 100.0;

   // For XAUUSD: 1 lot = 100 oz, $1 move = $100
   // sl_dollars point move → cash risk per lot = sl_dollars * 100
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0 || tickValue <= 0) return 0;

   double cashPerLot = (sl_dollars / tickSize) * tickValue;
   if(cashPerLot <= 0) return 0;

   double lot = riskAmount / cashPerLot;

   // Normalize to lot step
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep > 0)
      lot = MathFloor(lot / lotStep) * lotStep;

   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);

   return NormalizeDouble(lot, 2);
}

//=====================================================================
//  Check for open position with our magic number
//=====================================================================
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) == INP_Magic)
         return true;
   }
   return false;
}

//=====================================================================
//  External Control File — read switches from ea_control.csv
//  Format: key,value (one per line)
//  Keys: trading_enabled, buy_enabled, sell_enabled,
//        max_daily_trades, cooldown_seconds, risk_pct
//=====================================================================
void ReadControlFile()
{
   string filename = "ea_control.csv";
   if(!FileIsExist(filename)) return;

   int handle = FileOpen(filename, FILE_READ | FILE_CSV | FILE_ANSI, ',');
   if(handle == INVALID_HANDLE) return;

   while(!FileIsEnding(handle))
   {
      string key = FileReadString(handle);
      if(StringLen(key) == 0) break;
      string value = FileReadString(handle);

      StringTrimLeft(key);   StringTrimRight(key);
      StringTrimLeft(value); StringTrimRight(value);
      StringToLower(key);
      StringToLower(value);

      if(key == "trading_enabled")
         g_tradingEnabled = (value == "true" || value == "1");
      else if(key == "buy_enabled")
         g_buyEnabled = (value == "true" || value == "1");
      else if(key == "sell_enabled")
         g_sellEnabled = (value == "true" || value == "1");
      else if(key == "max_daily_trades")
         g_maxDailyTrades = (int)StringToInteger(value);
      else if(key == "cooldown_seconds")
         g_cooldownSec = (int)StringToInteger(value);
      else if(key == "risk_pct")
         g_riskPct = StringToDouble(value);
   }
   FileClose(handle);
}

//=====================================================================
//  Status File — write EA state for external monitoring
//=====================================================================
void WriteStatusFile()
{
   string filename = "ea_status.csv";
   int handle = FileOpen(filename, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(handle == INVALID_HANDLE) return;

   FileWrite(handle, "key", "value");
   FileWrite(handle, "symbol",            _Symbol);
   FileWrite(handle, "ea_version",        "1.00");
   FileWrite(handle, "server_time",       TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   FileWrite(handle, "trading_enabled",   g_tradingEnabled ? "true" : "false");
   FileWrite(handle, "buy_enabled",       g_buyEnabled ? "true" : "false");
   FileWrite(handle, "sell_enabled",      g_sellEnabled ? "true" : "false");
   FileWrite(handle, "has_position",      HasOpenPosition() ? "true" : "false");
   FileWrite(handle, "daily_trades",      IntegerToString(g_dailyTradeCount));
   FileWrite(handle, "total_trades",      IntegerToString(g_totalTrades));
   FileWrite(handle, "total_wins",        IntegerToString(g_totalWins));
   FileWrite(handle, "total_losses",      IntegerToString(g_totalLosses));
   FileWrite(handle, "total_pnl",         DoubleToString(g_totalPnL, 2));
   FileWrite(handle, "equity",            DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   FileWrite(handle, "risk_pct",          DoubleToString((g_riskPct > 0) ? g_riskPct : INP_RiskPct, 1));
   FileWrite(handle, "cooldown_sec",      IntegerToString((g_cooldownSec > 0) ? g_cooldownSec : INP_CooldownSec));
   FileWrite(handle, "max_daily_trades",  IntegerToString((g_maxDailyTrades > 0) ? g_maxDailyTrades : INP_MaxDailyTrades));

   // UT Bot bias snapshots
   int m3_bias  = GetUTBotBias(PERIOD_M3, g_atr_m3_handle);
   int m5_bias  = GetUTBotBias(PERIOD_M5, g_atr_m5_handle);
   int m15_bias = GetUTBotBias(PERIOD_M15, g_atr_m15_handle);
   FileWrite(handle, "utbot_m3_bias",     (m3_bias > 0) ? "BULLISH" : (m3_bias < 0) ? "BEARISH" : "NONE");
   FileWrite(handle, "utbot_m5_bias",     (m5_bias > 0) ? "BULLISH" : (m5_bias < 0) ? "BEARISH" : "NONE");
   FileWrite(handle, "utbot_m15_bias",    (m15_bias > 0) ? "BULLISH" : (m15_bias < 0) ? "BEARISH" : "NONE");

   FileClose(handle);
}
//+------------------------------------------------------------------+
