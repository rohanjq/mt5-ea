//+------------------------------------------------------------------+
//| MasterTrader.mq5 — Expression-based multi-strategy EA            |
//| v2.1 — Clean signal naming, running candle, all indicators       |
//+------------------------------------------------------------------+
#property copyright "mt5-ea"
#property version   "2.10"
#property strict
#property description "Expression engine, 15+5 strategies, per-strategy stats"

#include <Trade/Trade.mqh>

//=====================================================================
//  SECTION 1: INPUT PARAMETERS
//=====================================================================

input group "=== Global Risk ==="
input double INP_RiskPct        = 3.0;     // Risk % of equity per trade
input double INP_GlobalSL       = 7.5;     // Default SL (dollars) if strategy SL=0
input double INP_GlobalRR       = 1.0;     // Default reward:risk if strategy RR=0

input group "=== Trade Management ==="
input int    INP_Magic          = 300;     // Magic number
input bool   INP_MultiPosition  = false;   // Allow multiple positions
input int    INP_MaxPositions   = 1;       // Max simultaneous positions
input int    INP_MaxDailyTrades = 15;      // Max trades per day
input int    INP_CooldownSec   = 300;      // Cooldown between trades (sec)
input int    INP_ReversalCooldown = 300;   // Reversal cooldown (sec)
input int    INP_MaxConsecLoss  = 3;       // Pause after N consec losses (0=off)
input int    INP_ConsecLossPause = 1800;   // Pause per consec loss (sec)
input int    INP_Slippage      = 20;       // Max slippage (points)

input group "=== Trailing Stop ==="
input double INP_BreakevenStart = 0.0;     // Move SL to entry after $X profit (0=off)
input double INP_TrailStart     = 0.0;     // Start trailing after $X profit (0=off)
input double INP_TrailStep      = 2.0;     // Trail distance (dollars)

input group "=== Indicator Parameters ==="
input int    INP_UTBot_Period   = 10;      // UT Bot ATR period
input double INP_UTBot_Mult     = 2.0;     // UT Bot ATR multiplier
input int    INP_DC_Length      = 20;      // Donchian Channel length

input group "=== External Control ==="
input bool   INP_UseControlFile  = false;  // Read ea_control.csv
input bool   INP_WriteStatusFile = false;  // Write ea_status.csv
input int    INP_ControlPollSec  = 5;      // Poll interval (sec)

// ─── Signal key reference ───────────────────────────────────────────
// utbot_TF   : .bias .signal .bullish_since .bearish_since
// dc_TF      : .zone .upper_wick_rej .lower_wick_rej .width
// emaX_TF    : .price_vs .slope .value       (X = 9/21/50/200)
// rsiX_TF    : .value .zone                  (X = 2/14)
// adx_TF     : .value .strength .di_bias
// macd_TF    : .cross .hist_dir .vs_zero
// stoch_TF   : .k .zone
// bb_TF      : .squeeze .reenter_below
// atr_TF     : .value
// vwap_TF    : .price_vs .value
// candle_TF  : .type .dir .is_bullish .is_bearish
//              .upper_wick_ratio .lower_wick_ratio .body_pct
//              .live_*  (same fields on running bar)
// ────────────────────────────────────────────────────────────────────

input group "=== S01: dc_wick_rejection ==="
input bool   S01_On   = true;
input double S01_SL   = 5.0;
input double S01_RR   = 1.0;
input string S01_Buy  = "dc_M15.lower_wick_rej==TRUE|utbot_M3.bias==BULLISH";
input string S01_Sell = "dc_M15.upper_wick_rej==TRUE|utbot_M3.bias==BEARISH";

input group "=== S02: trend_2w_m2_ema50_bounce2_vwap ==="
input bool   S02_On   = true;
input double S02_SL   = 7.5;
input double S02_RR   = 1.0;
input string S02_Buy  = "";
input string S02_Sell = "utbot_M2.signal==SELL|ema50_M5.price_vs==BELOW|utbot_M5.bullish_since>=2|vwap_M1.price_vs==BELOW";

input group "=== S03: trend_2w_m2_m15bear_bounce2_vwap ==="
input bool   S03_On   = true;
input double S03_SL   = 7.5;
input double S03_RR   = 1.0;
input string S03_Buy  = "";
input string S03_Sell = "utbot_M2.signal==SELL|utbot_M15.bias==BEARISH|utbot_M5.bullish_since>=2|vwap_M1.price_vs==BELOW";

input group "=== S04: dc2w_m3_h1bear_dcupper_vwap ==="
input bool   S04_On   = true;
input double S04_SL   = 7.5;
input double S04_RR   = 1.0;
input string S04_Buy  = "";
input string S04_Sell = "utbot_M3.signal==SELL|utbot_H1.bias==BEARISH|dc_M15.zone in UPPER,UPPER_MID|vwap_M1.price_vs==BELOW";

input group "=== S05: hammer_2w_m15_dc ==="
input bool   S05_On   = true;
input double S05_SL   = 7.5;
input double S05_RR   = 1.0;
input string S05_Buy  = "candle_M3.type==HAMMER|utbot_M5.bearish_since>=2|utbot_M15.bias==BULLISH|dc_M15.zone in LOWER,LOWER_MID";
input string S05_Sell = "";

input group "=== S06: doji_dc_upper_m15 ==="
input bool   S06_On   = true;
input double S06_SL   = 7.5;
input double S06_RR   = 1.0;
input string S06_Buy  = "";
input string S06_Sell = "candle_M3.type==DOJI|dc_M15.zone in UPPER,UPPER_MID|utbot_M15.bias==BEARISH";

input group "=== S07: shstar_m5_m15 ==="
input bool   S07_On   = true;
input double S07_SL   = 7.5;
input double S07_RR   = 1.0;
input string S07_Buy  = "";
input string S07_Sell = "candle_M5.type==SHOOTING_STAR|utbot_M15.bias==BEARISH";

input group "=== S08: wick2x_dc_h1_vwap_sell ==="
input bool   S08_On   = true;
input double S08_SL   = 7.5;
input double S08_RR   = 1.0;
input string S08_Buy  = "";
input string S08_Sell = "candle_M3.upper_wick_ratio>=2|candle_M3.is_bearish==TRUE|dc_M15.zone in UPPER,UPPER_MID|utbot_H1.bias==BEARISH|vwap_M1.price_vs==BELOW";

input group "=== S09: dc_mid_hammer_2w_m15 ==="
input bool   S09_On   = true;
input double S09_SL   = 7.5;
input double S09_RR   = 1.0;
input string S09_Buy  = "dc_M5.zone==MIDDLE|utbot_M5.bearish_since>=2|candle_M3.type==HAMMER|utbot_M15.bias==BULLISH";
input string S09_Sell = "";

input group "=== S10: dc_mid_shstar_2w_m15 ==="
input bool   S10_On   = true;
input double S10_SL   = 7.5;
input double S10_RR   = 1.0;
input string S10_Buy  = "";
input string S10_Sell = "dc_M5.zone==MIDDLE|utbot_M5.bullish_since>=2|candle_M3.type==SHOOTING_STAR|utbot_M15.bias==BEARISH";

input group "=== S11: dc_lowmid_hammer_2w_m15 ==="
input bool   S11_On   = true;
input double S11_SL   = 7.5;
input double S11_RR   = 1.0;
input string S11_Buy  = "dc_M5.zone in LOWER_MID,MIDDLE|utbot_M5.bearish_since>=2|candle_M3.type==HAMMER|utbot_M15.bias==BULLISH";
input string S11_Sell = "";

input group "=== S12: dc_upmid_shstar_2w_m15 ==="
input bool   S12_On   = true;
input double S12_SL   = 7.5;
input double S12_RR   = 1.0;
input string S12_Buy  = "";
input string S12_Sell = "dc_M5.zone in UPPER_MID,MIDDLE|utbot_M5.bullish_since>=2|candle_M3.type==SHOOTING_STAR|utbot_M15.bias==BEARISH";

input group "=== S13: rsi2_mean_rev_full ==="
input bool   S13_On   = true;
input double S13_SL   = 3.0;
input double S13_RR   = 1.5;
input string S13_Buy  = "rsi2_M5.zone==EXTREME_OS|ema200_M15.price_vs==ABOVE|adx_M15.strength in STRONG_TREND,TRENDING|utbot_H1.bias==BULLISH";
input string S13_Sell = "";

input group "=== S14: ema50_dc_wick_h1 ==="
input bool   S14_On   = true;
input double S14_SL   = 3.0;
input double S14_RR   = 2.0;
input string S14_Buy  = "ema50_M15.slope==RISING|dc_M15.lower_wick_rej==TRUE|utbot_H1.bias==BULLISH";
input string S14_Sell = "";

input group "=== S15: rsi2_dc_wick ==="
input bool   S15_On   = true;
input double S15_SL   = 3.0;
input double S15_RR   = 1.0;
input string S15_Buy  = "rsi2_M5.zone==EXTREME_OS|ema200_M15.price_vs==ABOVE|dc_M15.lower_wick_rej==TRUE";
input string S15_Sell = "";

input group "=== S16: (custom) ==="
input bool   S16_On   = false;
input double S16_SL   = 0;
input double S16_RR   = 0;
input string S16_Buy  = "";
input string S16_Sell = "";

input group "=== S17: (custom) ==="
input bool   S17_On   = false;
input double S17_SL   = 0;
input double S17_RR   = 0;
input string S17_Buy  = "";
input string S17_Sell = "";

input group "=== S18: (custom) ==="
input bool   S18_On   = false;
input double S18_SL   = 0;
input double S18_RR   = 0;
input string S18_Buy  = "";
input string S18_Sell = "";

input group "=== S19: (custom) ==="
input bool   S19_On   = false;
input double S19_SL   = 0;
input double S19_RR   = 0;
input string S19_Buy  = "";
input string S19_Sell = "";

input group "=== S20: (custom) ==="
input bool   S20_On   = false;
input double S20_SL   = 0;
input double S20_RR   = 0;
input string S20_Buy  = "";
input string S20_Sell = "";

//=====================================================================
//  SECTION 2: CONSTANTS & STRUCTURES
//=====================================================================
#define NUM_TF       11
#define MAX_SIGNALS  700
#define MAX_STRAT    20
#define LOOKBACK     200

ENUM_TIMEFRAMES g_tfs[NUM_TF] = {
   PERIOD_M1, PERIOD_M2, PERIOD_M3, PERIOD_M5, PERIOD_M10,
   PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4, PERIOD_D1, PERIOD_W1
};
string g_tfNames[NUM_TF] = {
   "M1","M2","M3","M5","M10","M15","M30","H1","H4","D1","W1"
};

struct Strategy
{
   string name;
   bool   enabled;
   double sl;
   double rr;
   string buyCond;
   string sellCond;
   int    wins;
   int    losses;
   int    totalTrades;
   double pnl;
};

//=====================================================================
//  SECTION 3: GLOBAL STATE
//=====================================================================
CTrade         g_trade;
datetime       g_lastTradeTime   = 0;
int            g_lastTradeDir    = 0;       // 1=BUY, -1=SELL
int            g_dailyTradeCount = 0;
datetime       g_lastDay         = 0;
int            g_consecLosses    = 0;

int            g_totalTrades     = 0;
int            g_totalWins       = 0;
int            g_totalLosses     = 0;
double         g_totalPnL        = 0;
int            g_lastDealCount   = 0;

bool           g_tradingEnabled  = true;
bool           g_buyEnabled      = true;
bool           g_sellEnabled     = true;
datetime       g_lastControlRead = 0;

string         g_sigKeys[MAX_SIGNALS];
string         g_sigVals[MAX_SIGNALS];
int            g_sigCount = 0;

datetime       g_lastBarTime[NUM_TF];

Strategy       g_strats[MAX_STRAT];
int            g_stratCount = 0;

// Indicator handles per timeframe
int g_h_utbot_atr[NUM_TF];
int g_h_ema9[NUM_TF];
int g_h_ema21[NUM_TF];
int g_h_ema50[NUM_TF];
int g_h_ema200[NUM_TF];
int g_h_rsi14[NUM_TF];
int g_h_rsi2[NUM_TF];
int g_h_adx[NUM_TF];
int g_h_macd[NUM_TF];
int g_h_stoch[NUM_TF];
int g_h_bb[NUM_TF];
int g_h_atr[NUM_TF];

//=====================================================================
//  SECTION 4: INITIALIZATION
//=====================================================================
int OnInit()
{
   g_trade.SetExpertMagicNumber(INP_Magic);
   g_trade.SetDeviationInPoints(INP_Slippage);

   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   for(int i = 0; i < NUM_TF; i++)
   {
      ENUM_TIMEFRAMES tf = g_tfs[i];
      g_h_utbot_atr[i] = iATR(_Symbol, tf, INP_UTBot_Period);
      g_h_ema9[i]      = iMA(_Symbol, tf, 9,   0, MODE_EMA, PRICE_CLOSE);
      g_h_ema21[i]     = iMA(_Symbol, tf, 21,  0, MODE_EMA, PRICE_CLOSE);
      g_h_ema50[i]     = iMA(_Symbol, tf, 50,  0, MODE_EMA, PRICE_CLOSE);
      g_h_ema200[i]    = iMA(_Symbol, tf, 200, 0, MODE_EMA, PRICE_CLOSE);
      g_h_rsi14[i]     = iRSI(_Symbol, tf, 14, PRICE_CLOSE);
      g_h_rsi2[i]      = iRSI(_Symbol, tf, 2,  PRICE_CLOSE);
      g_h_adx[i]       = iADX(_Symbol, tf, 14);
      g_h_macd[i]      = iMACD(_Symbol, tf, 12, 26, 9, PRICE_CLOSE);
      g_h_stoch[i]     = iStochastic(_Symbol, tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      g_h_bb[i]        = iBands(_Symbol, tf, 20, 0, 2.0, PRICE_CLOSE);
      g_h_atr[i]       = iATR(_Symbol, tf, 14);
      g_lastBarTime[i] = 0;
   }

   LoadStrategies();
   EventSetTimer(1);

   int enabled = 0;
   for(int i = 0; i < g_stratCount; i++)
      if(g_strats[i].enabled) enabled++;

   Print("MasterTrader v2.1 | ", _Symbol,
         " | Strats: ", enabled, "/", g_stratCount,
         " | Risk: ", INP_RiskPct, "%",
         " | Magic: ", INP_Magic);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();

   for(int i = 0; i < NUM_TF; i++)
   {
      if(g_h_utbot_atr[i] != INVALID_HANDLE) IndicatorRelease(g_h_utbot_atr[i]);
      if(g_h_ema9[i]      != INVALID_HANDLE) IndicatorRelease(g_h_ema9[i]);
      if(g_h_ema21[i]     != INVALID_HANDLE) IndicatorRelease(g_h_ema21[i]);
      if(g_h_ema50[i]     != INVALID_HANDLE) IndicatorRelease(g_h_ema50[i]);
      if(g_h_ema200[i]    != INVALID_HANDLE) IndicatorRelease(g_h_ema200[i]);
      if(g_h_rsi14[i]     != INVALID_HANDLE) IndicatorRelease(g_h_rsi14[i]);
      if(g_h_rsi2[i]      != INVALID_HANDLE) IndicatorRelease(g_h_rsi2[i]);
      if(g_h_adx[i]       != INVALID_HANDLE) IndicatorRelease(g_h_adx[i]);
      if(g_h_macd[i]      != INVALID_HANDLE) IndicatorRelease(g_h_macd[i]);
      if(g_h_stoch[i]     != INVALID_HANDLE) IndicatorRelease(g_h_stoch[i]);
      if(g_h_bb[i]        != INVALID_HANDLE) IndicatorRelease(g_h_bb[i]);
      if(g_h_atr[i]       != INVALID_HANDLE) IndicatorRelease(g_h_atr[i]);
   }

   Print("=========== STRATEGY RESULTS ===========");
   for(int i = 0; i < g_stratCount; i++)
   {
      if(!g_strats[i].enabled || g_strats[i].totalTrades == 0) continue;
      double wr = (double)g_strats[i].wins / g_strats[i].totalTrades * 100.0;
      Print(StringFormat("  %-35s  W:%-3d L:%-3d  WR:%.0f%%  PnL:$%.2f",
            g_strats[i].name, g_strats[i].wins, g_strats[i].losses, wr, g_strats[i].pnl));
   }
   double totalWR = (g_totalTrades > 0)
      ? (double)g_totalWins / g_totalTrades * 100.0 : 0;
   Print(StringFormat("  TOTAL: %d trades  W:%d L:%d  WR:%.0f%%  PnL:$%.2f",
         g_totalTrades, g_totalWins, g_totalLosses, totalWR, g_totalPnL));
   Print("========================================");
}

void LoadStrategies()
{
   g_stratCount = 0;
   AddStrat("dc_wick_rejection",               S01_On, S01_SL, S01_RR, S01_Buy, S01_Sell);
   AddStrat("trend_2w_m2_ema50_bounce2_vwap",   S02_On, S02_SL, S02_RR, S02_Buy, S02_Sell);
   AddStrat("trend_2w_m2_m15bear_bounce2_vwap", S03_On, S03_SL, S03_RR, S03_Buy, S03_Sell);
   AddStrat("dc2w_m3_h1bear_dcupper_vwap",      S04_On, S04_SL, S04_RR, S04_Buy, S04_Sell);
   AddStrat("hammer_2w_m15_dc",                 S05_On, S05_SL, S05_RR, S05_Buy, S05_Sell);
   AddStrat("doji_dc_upper_m15",                S06_On, S06_SL, S06_RR, S06_Buy, S06_Sell);
   AddStrat("shstar_m5_m15",                    S07_On, S07_SL, S07_RR, S07_Buy, S07_Sell);
   AddStrat("wick2x_dc_h1_vwap_sell",           S08_On, S08_SL, S08_RR, S08_Buy, S08_Sell);
   AddStrat("dc_mid_hammer_2w_m15",             S09_On, S09_SL, S09_RR, S09_Buy, S09_Sell);
   AddStrat("dc_mid_shstar_2w_m15",             S10_On, S10_SL, S10_RR, S10_Buy, S10_Sell);
   AddStrat("dc_lowmid_hammer_2w_m15",          S11_On, S11_SL, S11_RR, S11_Buy, S11_Sell);
   AddStrat("dc_upmid_shstar_2w_m15",           S12_On, S12_SL, S12_RR, S12_Buy, S12_Sell);
   AddStrat("rsi2_mean_rev_full",               S13_On, S13_SL, S13_RR, S13_Buy, S13_Sell);
   AddStrat("ema50_dc_wick_h1",                 S14_On, S14_SL, S14_RR, S14_Buy, S14_Sell);
   AddStrat("rsi2_dc_wick",                     S15_On, S15_SL, S15_RR, S15_Buy, S15_Sell);
   AddStrat("custom_16",                        S16_On, S16_SL, S16_RR, S16_Buy, S16_Sell);
   AddStrat("custom_17",                        S17_On, S17_SL, S17_RR, S17_Buy, S17_Sell);
   AddStrat("custom_18",                        S18_On, S18_SL, S18_RR, S18_Buy, S18_Sell);
   AddStrat("custom_19",                        S19_On, S19_SL, S19_RR, S19_Buy, S19_Sell);
   AddStrat("custom_20",                        S20_On, S20_SL, S20_RR, S20_Buy, S20_Sell);
}

void AddStrat(string name, bool on, double sl, double rr,
              string buyCond, string sellCond)
{
   if(g_stratCount >= MAX_STRAT) return;
   int i = g_stratCount++;
   g_strats[i].name       = name;
   g_strats[i].enabled    = on;
   g_strats[i].sl         = sl;
   g_strats[i].rr         = rr;
   g_strats[i].buyCond    = buyCond;
   g_strats[i].sellCond   = sellCond;
   g_strats[i].wins       = 0;
   g_strats[i].losses     = 0;
   g_strats[i].totalTrades = 0;
   g_strats[i].pnl        = 0;
}

//=====================================================================
//  SECTION 5: EVENT HANDLERS
//=====================================================================
void OnTimer()
{
   if(INP_UseControlFile)
   {
      datetime now = TimeCurrent();
      if(now - g_lastControlRead >= INP_ControlPollSec)
      { ReadControlFile(); g_lastControlRead = now; }
   }
   if(INP_WriteStatusFile)
   {
      static int sc = 0;
      if(++sc >= 10) { WriteStatusFile(); sc = 0; }
   }
}

void OnTick()
{
   // 1. Trailing stop — every tick
   if(INP_TrailStart > 0 || INP_BreakevenStart > 0)
      ManageTrailingStop();

   // 2. Recompute indicator signals on new bars
   for(int i = 0; i < NUM_TF; i++)
   {
      datetime barTime = iTime(_Symbol, g_tfs[i], 0);
      if(barTime != 0 && barTime != g_lastBarTime[i])
      {
         g_lastBarTime[i] = barTime;
         ComputeAllSignals(i);
      }
   }

   // 3. Running candle — every tick, all sub-daily TFs
   for(int i = 0; i < NUM_TF; i++)
   {
      if(g_tfs[i] >= PERIOD_D1) continue;
      ComputeCandleForBar(i, 0, "live_");
   }

   // 4. Daily counter reset
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today = StringToTime(StringFormat("%d.%02d.%02d", dt.year, dt.mon, dt.day));
   if(today != g_lastDay) { g_dailyTradeCount = 0; g_lastDay = today; }

   // 5. Trading filters
   if(!g_tradingEnabled) return;

   int openPos = CountOpenPositions();
   if(!INP_MultiPosition && openPos > 0) return;
   if(INP_MultiPosition && openPos >= INP_MaxPositions) return;
   if(g_dailyTradeCount >= INP_MaxDailyTrades) return;

   datetime now = TimeCurrent();
   if(now - g_lastTradeTime < INP_CooldownSec) return;

   if(INP_MaxConsecLoss > 0 && g_consecLosses >= INP_MaxConsecLoss)
   {
      if(now - g_lastTradeTime < g_consecLosses * INP_ConsecLossPause) return;
      g_consecLosses = 0;
   }

   // 6. Evaluate strategies
   for(int s = 0; s < g_stratCount; s++)
   {
      if(!g_strats[s].enabled) continue;

      if(g_buyEnabled && StringLen(g_strats[s].buyCond) > 0
         && EvalAllConditions(g_strats[s].buyCond))
      {
         if(g_lastTradeDir == -1 && now - g_lastTradeTime < INP_ReversalCooldown)
            continue;
         ExecuteTrade(s, ORDER_TYPE_BUY);
         return;
      }

      if(g_sellEnabled && StringLen(g_strats[s].sellCond) > 0
         && EvalAllConditions(g_strats[s].sellCond))
      {
         if(g_lastTradeDir == 1 && now - g_lastTradeTime < INP_ReversalCooldown)
            continue;
         ExecuteTrade(s, ORDER_TYPE_SELL);
         return;
      }
   }
}

void OnTrade()
{
   if(!HistorySelect(0, TimeCurrent())) return;
   int totalDeals = HistoryDealsTotal();

   for(int i = g_lastDealCount; i < totalDeals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != INP_Magic) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      string comment = HistoryDealGetString(ticket, DEAL_COMMENT);

      for(int s = 0; s < g_stratCount; s++)
      {
         if(StringFind(comment, g_strats[s].name) >= 0)
         {
            g_strats[s].totalTrades++;
            g_strats[s].pnl += profit;
            if(profit >= 0) g_strats[s].wins++;
            else            g_strats[s].losses++;
            break;
         }
      }

      g_totalTrades++;
      g_totalPnL += profit;
      if(profit >= 0) { g_totalWins++; g_consecLosses = 0; }
      else            { g_totalLosses++; g_consecLosses++; }

      Print((profit >= 0) ? "WIN" : "LOSS",
            " $", DoubleToString(profit, 2),
            " [", comment, "]",
            " | W:", g_totalWins, " L:", g_totalLosses);
   }
   g_lastDealCount = totalDeals;
}

//=====================================================================
//  SECTION 6: SIGNAL COMPUTATION
//=====================================================================
void ComputeAllSignals(int tf_idx)
{
   ComputeUTBot(tf_idx);
   ComputeDC(tf_idx);
   ComputeEMA(tf_idx, g_h_ema9[tf_idx],   "ema9");
   ComputeEMA(tf_idx, g_h_ema21[tf_idx],  "ema21");
   ComputeEMA(tf_idx, g_h_ema50[tf_idx],  "ema50");
   ComputeEMA(tf_idx, g_h_ema200[tf_idx], "ema200");
   ComputeRSI(tf_idx, 14, g_h_rsi14[tf_idx], "rsi14");
   ComputeRSI(tf_idx, 2,  g_h_rsi2[tf_idx],  "rsi2");
   ComputeADX(tf_idx);
   ComputeMACD(tf_idx);
   ComputeStoch(tf_idx);
   ComputeBB(tf_idx);
   ComputeATR(tf_idx);
   ComputeVWAP(tf_idx);
   ComputeCandleForBar(tf_idx, 1, "");   // closed bar
}

//--- UT Bot: ATR trailing stop crossover
void ComputeUTBot(int tf_idx)
{
   ENUM_TIMEFRAMES tf = g_tfs[tf_idx];
   string tn = g_tfNames[tf_idx];
   int handle = g_h_utbot_atr[tf_idx];
   if(handle == INVALID_HANDLE) return;

   int total = MathMin(Bars(_Symbol, tf), LOOKBACK);
   if(total < INP_UTBot_Period + 3) return;

   double cl[], atr[];
   if(CopyClose(_Symbol, tf, 0, total, cl) < total) return;
   if(CopyBuffer(handle, 0, 0, total, atr) < total) return;

   // Build trailing stop + direction arrays
   double trail[], dir[];
   ArrayResize(trail, total);
   ArrayResize(dir, total);

   for(int i = 0; i < INP_UTBot_Period && i < total; i++)
   { trail[i] = cl[i]; dir[i] = 1; }

   for(int i = INP_UTBot_Period; i < total; i++)
   {
      double nLoss = INP_UTBot_Mult * atr[i];
      double ps = trail[i-1], pd = dir[i-1];
      if(cl[i] > ps)
      {
         trail[i] = cl[i] - nLoss;
         if(pd > 0) trail[i] = MathMax(trail[i], ps);
         dir[i] = 1;
      }
      else
      {
         trail[i] = cl[i] + nLoss;
         if(pd < 0) trail[i] = MathMin(trail[i], ps);
         dir[i] = -1;
      }
   }

   int cls  = total - 2;   // closed bar
   int prev = total - 3;
   string pfx = "utbot_" + tn;

   // Bias
   SigSet(pfx + ".bias", (dir[cls] > 0) ? "BULLISH" : "BEARISH");

   // Signal (one-bar flash on direction change)
   string signal = "NONE";
   if(prev >= 0)
   {
      if(dir[cls] > 0 && dir[prev] < 0) signal = "BUY";
      if(dir[cls] < 0 && dir[prev] > 0) signal = "SELL";
   }
   SigSet(pfx + ".signal", signal);

   // Bars since bias turned (count from closed bar backwards)
   int bullSince = 0, bearSince = 0;
   for(int i = cls; i >= 0; i--)
   {
      if(dir[i] > 0) { if(bearSince > 0) break; bullSince++; }
      else           { if(bullSince > 0) break; bearSince++; }
   }
   SigSet(pfx + ".bullish_since", IntegerToString(bullSince));
   SigSet(pfx + ".bearish_since", IntegerToString(bearSince));
}

//--- Donchian Channel
void ComputeDC(int tf_idx)
{
   ENUM_TIMEFRAMES tf = g_tfs[tf_idx];
   string tn = g_tfNames[tf_idx];

   if(Bars(_Symbol, tf) < INP_DC_Length + 2) return;

   double highs[], lows[];
   if(CopyHigh(_Symbol, tf, 1, INP_DC_Length, highs) < INP_DC_Length) return;
   if(CopyLow(_Symbol, tf, 1, INP_DC_Length, lows) < INP_DC_Length) return;

   double upper = highs[ArrayMaximum(highs)];
   double lower = lows[ArrayMinimum(lows)];
   double width = upper - lower;

   double o = iOpen(_Symbol, tf, 1);
   double h = iHigh(_Symbol, tf, 1);
   double l = iLow(_Symbol, tf, 1);
   double c = iClose(_Symbol, tf, 1);

   // Zone classification
   double pct = (width > 0) ? (c - lower) / width * 100.0 : 50.0;
   string zone;
   if(pct >= 80)      zone = "UPPER";
   else if(pct >= 60) zone = "UPPER_MID";
   else if(pct >= 40) zone = "MIDDLE";
   else if(pct >= 20) zone = "LOWER_MID";
   else               zone = "LOWER";

   // Wick rejection
   double body_top    = MathMax(o, c);
   double body_bottom = MathMin(o, c);
   double body_size   = body_top - body_bottom;
   double upper_wick  = h - body_top;
   double lower_wick  = body_bottom - l;

   bool uwr = (h >= upper) && (upper_wick > body_size) && (c < upper);
   bool lwr = (l <= lower)  && (lower_wick > body_size) && (c > lower);

   string pfx = "dc_" + tn;
   SigSet(pfx + ".zone",           zone);
   SigSet(pfx + ".upper_wick_rej", uwr ? "TRUE" : "FALSE");
   SigSet(pfx + ".lower_wick_rej", lwr ? "TRUE" : "FALSE");
   SigSet(pfx + ".width",          DoubleToString(width, _Digits));
}

//--- EMA: price_vs + slope
void ComputeEMA(int tf_idx, int handle, string indName)
{
   if(handle == INVALID_HANDLE) return;
   string tn = g_tfNames[tf_idx];

   double ema[];
   if(CopyBuffer(handle, 0, 1, 5, ema) < 5) return;
   // ema[0]=oldest, ema[4]=closed bar

   double price = iClose(_Symbol, g_tfs[tf_idx], 1);
   double val   = ema[4];
   double old   = ema[1];

   string pfx = indName + "_" + tn;
   SigSet(pfx + ".price_vs", (price >= val) ? "ABOVE" : "BELOW");

   string slope = "FLAT";
   if(val > old + _Point) slope = "RISING";
   else if(val < old - _Point) slope = "FALLING";
   SigSet(pfx + ".slope", slope);
   SigSet(pfx + ".value", DoubleToString(val, _Digits));
}

//--- RSI: value + zone
void ComputeRSI(int tf_idx, int period, int handle, string indName)
{
   if(handle == INVALID_HANDLE) return;
   string tn = g_tfNames[tf_idx];

   double rsi[];
   if(CopyBuffer(handle, 0, 1, 1, rsi) < 1) return;
   double val = rsi[0];

   string zone;
   if(period == 2)
   {
      if(val > 95)      zone = "EXTREME_OB";
      else if(val > 80) zone = "OB";
      else if(val < 5)  zone = "EXTREME_OS";
      else if(val < 20) zone = "OS";
      else              zone = "NEUTRAL";
   }
   else
   {
      if(val > 70)      zone = "OB";
      else if(val < 30) zone = "OS";
      else              zone = "NEUTRAL";
   }

   string pfx = indName + "_" + tn;
   SigSet(pfx + ".value", DoubleToString(val, 2));
   SigSet(pfx + ".zone",  zone);
}

//--- ADX: strength + DI bias
void ComputeADX(int tf_idx)
{
   int handle = g_h_adx[tf_idx];
   if(handle == INVALID_HANDLE) return;
   string tn = g_tfNames[tf_idx];

   double adx[], diP[], diM[];
   if(CopyBuffer(handle, 0, 1, 1, adx) < 1) return;
   if(CopyBuffer(handle, 1, 1, 1, diP) < 1) return;
   if(CopyBuffer(handle, 2, 1, 1, diM) < 1) return;

   string strength;
   if(adx[0] >= 40)      strength = "STRONG_TREND";
   else if(adx[0] >= 25) strength = "TRENDING";
   else if(adx[0] >= 20) strength = "WEAK_TREND";
   else                   strength = "RANGING";

   string bias = "NEUTRAL";
   if(diP[0] > diM[0] + 1) bias = "BULLISH";
   else if(diM[0] > diP[0] + 1) bias = "BEARISH";

   string pfx = "adx_" + tn;
   SigSet(pfx + ".value",    DoubleToString(adx[0], 2));
   SigSet(pfx + ".strength", strength);
   SigSet(pfx + ".di_bias",  bias);
}

//--- MACD: cross + histogram direction + vs zero
void ComputeMACD(int tf_idx)
{
   int handle = g_h_macd[tf_idx];
   if(handle == INVALID_HANDLE) return;
   string tn = g_tfNames[tf_idx];

   double main[], sig[];
   if(CopyBuffer(handle, 0, 1, 2, main) < 2) return;
   if(CopyBuffer(handle, 1, 1, 2, sig) < 2) return;
   // [0]=prev, [1]=closed

   string cross = "NONE";
   if(main[1] > sig[1] && main[0] <= sig[0]) cross = "CROSS_UP";
   if(main[1] < sig[1] && main[0] >= sig[0]) cross = "CROSS_DOWN";

   double hist_now  = main[1] - sig[1];
   double hist_prev = main[0] - sig[0];

   string pfx = "macd_" + tn;
   SigSet(pfx + ".cross",    cross);
   SigSet(pfx + ".hist_dir", (hist_now > hist_prev) ? "RISING" : "FALLING");
   SigSet(pfx + ".vs_zero",  (main[1] >= 0) ? "ABOVE" : "BELOW");
}

//--- Stochastic: %K + zone
void ComputeStoch(int tf_idx)
{
   int handle = g_h_stoch[tf_idx];
   if(handle == INVALID_HANDLE) return;
   string tn = g_tfNames[tf_idx];

   double k[];
   if(CopyBuffer(handle, 0, 1, 1, k) < 1) return;

   string zone = "NEUTRAL";
   if(k[0] > 80) zone = "OB";
   else if(k[0] < 20) zone = "OS";

   string pfx = "stoch_" + tn;
   SigSet(pfx + ".k",    DoubleToString(k[0], 2));
   SigSet(pfx + ".zone", zone);
}

//--- Bollinger Bands: squeeze + reenter
void ComputeBB(int tf_idx)
{
   int handle = g_h_bb[tf_idx];
   if(handle == INVALID_HANDLE) return;
   string tn = g_tfNames[tf_idx];

   double base[], upper[], lower[];
   if(CopyBuffer(handle, 0, 1, 2, base) < 2) return;
   if(CopyBuffer(handle, 1, 1, 2, upper) < 2) return;
   if(CopyBuffer(handle, 2, 1, 2, lower) < 2) return;

   double bw     = (base[1] > 0) ? (upper[1] - lower[1]) / base[1] : 0;
   double bwPrev = (base[0] > 0) ? (upper[0] - lower[0]) / base[0] : 0;
   bool squeeze = (bwPrev > 0) && (bw < bwPrev * 0.75);

   double cls  = iClose(_Symbol, g_tfs[tf_idx], 1);
   double prev = iClose(_Symbol, g_tfs[tf_idx], 2);
   bool reenter = (prev < lower[0]) && (cls >= lower[1]);

   string pfx = "bb_" + tn;
   SigSet(pfx + ".squeeze",       squeeze ? "TRUE" : "FALSE");
   SigSet(pfx + ".reenter_below", reenter ? "TRUE" : "FALSE");
}

//--- ATR: raw value
void ComputeATR(int tf_idx)
{
   int handle = g_h_atr[tf_idx];
   if(handle == INVALID_HANDLE) return;

   double atr[];
   if(CopyBuffer(handle, 0, 1, 1, atr) < 1) return;

   SigSet("atr_" + g_tfNames[tf_idx] + ".value", DoubleToString(atr[0], _Digits));
}

//--- VWAP: session-based (from midnight)
void ComputeVWAP(int tf_idx)
{
   ENUM_TIMEFRAMES tf = g_tfs[tf_idx];
   string tn = g_tfNames[tf_idx];
   if(tf >= PERIOD_D1) return;

   MqlDateTime dt;
   TimeCurrent(dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime sessionStart = StructToTime(dt);

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, tf, sessionStart, TimeCurrent(), rates);
   if(copied < 2) return;

   double cumTPV = 0, cumVol = 0;
   for(int i = 0; i <= copied - 2; i++)
   {
      double tp = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      double vol = (double)rates[i].tick_volume;
      if(vol <= 0) vol = 1;
      cumTPV += tp * vol;
      cumVol += vol;
   }
   if(cumVol <= 0) return;

   double vwap = cumTPV / cumVol;
   double price = rates[copied - 2].close;

   string pfx = "vwap_" + tn;
   SigSet(pfx + ".price_vs", (price >= vwap) ? "ABOVE" : "BELOW");
   SigSet(pfx + ".value",    DoubleToString(vwap, _Digits));
}

//--- Candle patterns — reusable for any bar index
//    prefix="" → closed bar keys (candle_M3.type)
//    prefix="live_" → running bar keys (candle_M3.live_type)
void ComputeCandleForBar(int tf_idx, int barIdx, string prefix)
{
   ENUM_TIMEFRAMES tf = g_tfs[tf_idx];
   string tn = g_tfNames[tf_idx];
   if(tf >= PERIOD_D1) return;

   double o = iOpen(_Symbol, tf, barIdx);
   double h = iHigh(_Symbol, tf, barIdx);
   double l = iLow(_Symbol, tf, barIdx);
   double c = iClose(_Symbol, tf, barIdx);

   if(o == 0 && h == 0 && l == 0 && c == 0) return;

   double body_top    = MathMax(o, c);
   double body_bottom = MathMin(o, c);
   double body_size   = body_top - body_bottom;
   double upper_wick  = h - body_top;
   double lower_wick  = body_bottom - l;
   double total_range = h - l;

   double range_safe = (total_range > _Point) ? total_range : _Point;
   double body_safe  = (body_size > _Point) ? body_size : _Point;
   double body_pct   = (body_size / range_safe) * 100.0;

   double uwr = (body_size > _Point) ? (upper_wick / body_safe) : 0;
   double lwr = (body_size > _Point) ? (lower_wick / body_safe) : 0;

   // Type classification
   string type = "NORMAL";
   if(total_range <= _Point)
      type = "DOJI";
   else if(body_pct >= 80.0)
      type = "MARUBOZU";
   else if(body_pct < 10.0)
      type = "DOJI";
   else if(lower_wick >= 2.0 * body_safe && upper_wick < body_safe)
      type = "HAMMER";
   else if(upper_wick >= 2.0 * body_safe && lower_wick < body_safe)
      type = "SHOOTING_STAR";
   else if(body_pct < 40.0 && upper_wick > 0.5 * body_safe && lower_wick > 0.5 * body_safe)
      type = "SPINNING_TOP";

   string pfx = "candle_" + tn + "." + prefix;
   SigSet(pfx + "type",             type);
   SigSet(pfx + "dir",              (c > o) ? "UP" : (c < o) ? "DOWN" : "DOJI");
   SigSet(pfx + "is_bullish",       (c > o) ? "TRUE" : "FALSE");
   SigSet(pfx + "is_bearish",       (c < o) ? "TRUE" : "FALSE");
   SigSet(pfx + "upper_wick_ratio", DoubleToString(uwr, 2));
   SigSet(pfx + "lower_wick_ratio", DoubleToString(lwr, 2));
   SigSet(pfx + "body_pct",         DoubleToString(body_pct, 1));
}

//=====================================================================
//  SECTION 7: SIGNAL REGISTRY + EXPRESSION ENGINE
//=====================================================================
void SigSet(string key, string value)
{
   for(int i = 0; i < g_sigCount; i++)
   {
      if(g_sigKeys[i] == key)
      { g_sigVals[i] = value; return; }
   }
   if(g_sigCount < MAX_SIGNALS)
   {
      g_sigKeys[g_sigCount] = key;
      g_sigVals[g_sigCount] = value;
      g_sigCount++;
   }
}

string SigGet(string key)
{
   for(int i = 0; i < g_sigCount; i++)
      if(g_sigKeys[i] == key) return g_sigVals[i];
   return "";
}

bool ParseCondition(string expr, string &key, string &op, string &val)
{
   // Word operators (require surrounding spaces)
   string wordOps[]   = {" not_in ", " in "};
   string wordClean[] = {"not_in",   "in"};
   for(int i = 0; i < 2; i++)
   {
      int pos = StringFind(expr, wordOps[i]);
      if(pos > 0)
      {
         key = StringSubstr(expr, 0, pos);
         op  = wordClean[i];
         val = StringSubstr(expr, pos + StringLen(wordOps[i]));
         StringTrimLeft(key); StringTrimRight(key);
         StringTrimLeft(val); StringTrimRight(val);
         return true;
      }
   }

   // Symbol operators (longest first)
   string symOps[] = {">=", "<=", "!=", "==", ">", "<"};
   for(int i = 0; i < 6; i++)
   {
      int pos = StringFind(expr, symOps[i]);
      if(pos > 0)
      {
         key = StringSubstr(expr, 0, pos);
         op  = symOps[i];
         val = StringSubstr(expr, pos + StringLen(symOps[i]));
         StringTrimLeft(key); StringTrimRight(key);
         StringTrimLeft(val); StringTrimRight(val);
         return true;
      }
   }
   return false;
}

bool EvalCondition(string expr)
{
   string key, op, val;
   if(!ParseCondition(expr, key, op, val)) return false;

   string actual = SigGet(key);
   if(actual == "") return false;

   if(op == "==") return StringCompare(actual, val, false) == 0;
   if(op == "!=") return StringCompare(actual, val, false) != 0;

   if(op == "in")
   {
      string parts[];
      StringSplit(val, ',', parts);
      for(int i = 0; i < ArraySize(parts); i++)
      {
         string p = parts[i];
         StringTrimLeft(p); StringTrimRight(p);
         if(StringCompare(actual, p, false) == 0) return true;
      }
      return false;
   }

   if(op == "not_in")
   {
      string parts[];
      StringSplit(val, ',', parts);
      for(int i = 0; i < ArraySize(parts); i++)
      {
         string p = parts[i];
         StringTrimLeft(p); StringTrimRight(p);
         if(StringCompare(actual, p, false) == 0) return false;
      }
      return true;
   }

   double a = StringToDouble(actual);
   double b = StringToDouble(val);
   if(op == ">=") return a >= b;
   if(op == "<=") return a <= b;
   if(op == ">")  return a > b;
   if(op == "<")  return a < b;

   return false;
}

bool EvalAllConditions(string conditions)
{
   if(StringLen(conditions) == 0) return false;

   string parts[];
   StringSplit(conditions, '|', parts);

   for(int i = 0; i < ArraySize(parts); i++)
   {
      string cond = parts[i];
      StringTrimLeft(cond); StringTrimRight(cond);
      if(StringLen(cond) == 0) continue;
      if(!EvalCondition(cond)) return false;
   }
   return true;
}

//=====================================================================
//  SECTION 8: TRADE EXECUTION
//=====================================================================
void ExecuteTrade(int stratIdx, ENUM_ORDER_TYPE type)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double sl_dollars = g_strats[stratIdx].sl;
   if(sl_dollars <= 0) sl_dollars = INP_GlobalSL;

   double rr = g_strats[stratIdx].rr;
   if(rr <= 0) rr = INP_GlobalRR;

   double lot = CalcLotSize(INP_RiskPct, sl_dollars);
   if(lot <= 0) return;

   double price, sl, tp;
   string comment = "MT|" + g_strats[stratIdx].name;

   if(type == ORDER_TYPE_BUY)
   {
      price = tick.ask;
      sl = NormalizeDouble(price - sl_dollars, _Digits);
      tp = NormalizeDouble(price + sl_dollars * rr, _Digits);

      if(g_trade.Buy(lot, _Symbol, price, sl, tp, comment))
      {
         g_lastTradeTime = TimeCurrent();
         g_lastTradeDir  = 1;
         g_dailyTradeCount++;
         Print("BUY ", DoubleToString(lot, 2), " @ ", DoubleToString(price, _Digits),
               " SL=", DoubleToString(sl, _Digits),
               " TP=", DoubleToString(tp, _Digits),
               " [", g_strats[stratIdx].name, "]");
      }
      else
      {
         g_lastTradeTime = TimeCurrent();  // prevent retry spam on failure
      }
   }
   else
   {
      price = tick.bid;
      sl = NormalizeDouble(price + sl_dollars, _Digits);
      tp = NormalizeDouble(price - sl_dollars * rr, _Digits);

      if(g_trade.Sell(lot, _Symbol, price, sl, tp, comment))
      {
         g_lastTradeTime = TimeCurrent();
         g_lastTradeDir  = -1;
         g_dailyTradeCount++;
         Print("SELL ", DoubleToString(lot, 2), " @ ", DoubleToString(price, _Digits),
               " SL=", DoubleToString(sl, _Digits),
               " TP=", DoubleToString(tp, _Digits),
               " [", g_strats[stratIdx].name, "]");
      }
      else
      {
         g_lastTradeTime = TimeCurrent();  // prevent retry spam on failure
      }
   }
}

double CalcLotSize(double riskPct, double sl_dollars)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * riskPct / 100.0;

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0;

   double cashPerLot = (sl_dollars / tickSize) * tickValue;
   if(cashPerLot <= 0) return 0;

   double lot = riskAmount / cashPerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep > 0) lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);

   return NormalizeDouble(lot, 2);
}

//=====================================================================
//  SECTION 9: TRAILING STOP
//=====================================================================
void ManageTrailingStop()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != INP_Magic) continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      long   posType = PositionGetInteger(POSITION_TYPE);

      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) return;

      if(posType == POSITION_TYPE_BUY)
      {
         double profit = tick.bid - entry;

         if(INP_BreakevenStart > 0 && profit >= INP_BreakevenStart && sl < entry)
         {
            double newSL = NormalizeDouble(entry + _Point, _Digits);
            if(newSL > sl) g_trade.PositionModify(ticket, newSL, tp);
            continue;
         }
         if(INP_TrailStart > 0 && profit >= INP_TrailStart)
         {
            double newSL = NormalizeDouble(tick.bid - INP_TrailStep, _Digits);
            if(newSL > sl) g_trade.PositionModify(ticket, newSL, tp);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double profit = entry - tick.ask;

         if(INP_BreakevenStart > 0 && profit >= INP_BreakevenStart && (sl > entry || sl == 0))
         {
            double newSL = NormalizeDouble(entry - _Point, _Digits);
            if(newSL < sl || sl == 0) g_trade.PositionModify(ticket, newSL, tp);
            continue;
         }
         if(INP_TrailStart > 0 && profit >= INP_TrailStart)
         {
            double newSL = NormalizeDouble(tick.ask + INP_TrailStep, _Digits);
            if(newSL < sl || sl == 0) g_trade.PositionModify(ticket, newSL, tp);
         }
      }
   }
}

//=====================================================================
//  SECTION 10: POSITION HELPERS
//=====================================================================
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) == INP_Magic) count++;
   }
   return count;
}

//=====================================================================
//  SECTION 11: EXTERNAL CONTROL
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
      StringToLower(key);    StringToLower(value);

      if(key == "trading_enabled")
         g_tradingEnabled = (value == "true" || value == "1");
      else if(key == "buy_enabled")
         g_buyEnabled = (value == "true" || value == "1");
      else if(key == "sell_enabled")
         g_sellEnabled = (value == "true" || value == "1");
   }
   FileClose(handle);
}

void WriteStatusFile()
{
   int handle = FileOpen("ea_status.csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(handle == INVALID_HANDLE) return;

   FileWrite(handle, "key", "value");
   FileWrite(handle, "symbol",          _Symbol);
   FileWrite(handle, "server_time",     TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   FileWrite(handle, "trading_enabled", g_tradingEnabled ? "true" : "false");
   FileWrite(handle, "positions",       IntegerToString(CountOpenPositions()));
   FileWrite(handle, "daily_trades",    IntegerToString(g_dailyTradeCount));
   FileWrite(handle, "total_trades",    IntegerToString(g_totalTrades));
   FileWrite(handle, "total_wins",      IntegerToString(g_totalWins));
   FileWrite(handle, "total_losses",    IntegerToString(g_totalLosses));
   FileWrite(handle, "total_pnl",       DoubleToString(g_totalPnL, 2));
   FileWrite(handle, "equity",          DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   FileWrite(handle, "consec_losses",   IntegerToString(g_consecLosses));

   FileClose(handle);
}
//+------------------------------------------------------------------+
