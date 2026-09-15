//+------------------------------------------------------------------+
//|                                                     XARE.mq5     |
//|        XARE — XAUUSD Adaptive Risk Engine  (v0.2.0, M2)          |
//|                                                                  |
//| M2: market data + indicator feature layer on closed bars.        |
//| Still NO trading paths — engines evaluate and log only.          |
//| Modes (default SIGNAL_ONLY — never default to trading):          |
//|   RESEARCH  : future home of feature CSV export                  |
//|   SIGNAL_ONLY: evaluate + report, never place orders             |
//|   BACKTEST  : full pipeline in Strategy Tester                   |
//|   DEMO      : full pipeline, demo account only                   |
//|   PRODUCTION: full pipeline, live account (explicit enable)      |
//|   SELF_TEST : run self-tests, print PASS/FAIL, stop              |
//+------------------------------------------------------------------+
#property copyright "XARE contributors"
#property link        "https://github.com/jaHxii/XARE-Trading-System"
#property version     "1.00"  // display-only: this compiler rejects 0.x majors (warning 68).
                                     // Authoritative version: v0.1.0 — see docs/changelog.md + git tag.  // x.yy format required by MetaEditor; semver v0.1.0 in changelog/tag
#property description "XARE — XAUUSD Adaptive Risk Engine (research build, M1)"

#include <XARE\Types.mqh>
#include <XARE\Config.mqh>
#include <XARE\Logger.mqh>
#include <XARE\Diagnostics.mqh>
#include <XARE\MarketData.mqh>
#include <XARE\Indicators.mqh>
#include <XARE\MultiTimeframe.mqh>
#include <XARE\RegimeEngine.mqh>
#include <XARE\StructureEngine.mqh>

//--- inputs: single source of truth is SXareConfig; inputs feed it once.
input group  "General"
input ENUM_XARE_MODE InpMode            = XARE_MODE_SIGNAL_ONLY; // Operating mode
input bool           InpTradingEnabled  = false;                 // Global trading switch
input long           InpMagic           = 860001;                // Magic number
input string         InpComment         = "XARE";                // Order comment
input bool           InpDashboard       = true;                  // Show dashboard

input group  "Market Data"
input int            InpMaxSpreadPts    = 350;                   // Max spread (points) for entries
input int            InpAbnSpreadPts    = 600;                   // Abnormal spread (points)

input group  "Indicators"
input int            InpEmaFast         = 20;                    // EMA fast period
input int            InpEmaMid          = 50;                    // EMA mid period
input int            InpEmaSlow         = 200;                   // EMA slow period
input int            InpRsiPeriod       = 14;                    // RSI period
input int            InpRocPeriod       = 10;                    // ROC period (bars)
input int            InpAdxPeriod       = 14;                    // ADX period
input int            InpAtrPeriod       = 14;                    // ATR period
input int            InpHistoryBarsMin  = 260;                   // Min closed bars required

input group  "Logging"
input int            InpLogLevel        = 1;                     // 0=DEBUG 1=INFO 2=WARN 3=ERROR
input bool           InpJournalCSV      = true;                  // Enable trade journal CSV

//--- module instances
SXareConfig       g_cfg;
CXareLogger       g_log;
CXareDiagnostics  g_ui;
CXareMarketData   g_md;
CXareIndicators   g_ind;
CXareMultiTimeframe g_mtf;
CXareRegimeEngine  g_regime;
CXareStructureEngine g_struct;

//--- runtime state
string            g_symbol;
string            g_tf_label;
datetime          g_last_heartbeat = 0;
bool              g_init_ok = false;
datetime          g_last_processed_bar = 0;   // duplicate-processing guard
bool              g_features_warned = false;  // log feature-missing once per episode

//+------------------------------------------------------------------+
//| Capability probe: log every symbol property the EA will rely on. |
//| Nothing is assumed; missing capabilities are reported, not       |
//| guessed (spec §6, §58).                                          |
//+------------------------------------------------------------------+
void LogSymbolCapabilities()
  {
   long trade_mode = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE);
   long trade_exec = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_EXEMODE);
   double min_lot  = SymbolInfoDouble (g_symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble (g_symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble (g_symbol, SYMBOL_VOLUME_STEP);
   double tick_sz  = SymbolInfoDouble (g_symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_val = SymbolInfoDouble (g_symbol, SYMBOL_TRADE_TICK_VALUE);
   double contract = SymbolInfoDouble (g_symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   long stops_lvl  = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze_lvl = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int  digits     = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   double point    = SymbolInfoDouble (g_symbol, SYMBOL_POINT);

   double margin_buy = 0.0;
   bool margin_ok = OrderCalcMargin(ORDER_TYPE_BUY, g_symbol, max_lot>0?MathMin(1.0,max_lot):0.01,
                                    SymbolInfoDouble(g_symbol, SYMBOL_ASK), margin_buy);

   g_log.Info("INIT", StringFormat(
      "symbol=%s digits=%d point=%s tick_size=%s tick_value=%s contract=%s",
      g_symbol, digits, DoubleToString(point,digits),
      DoubleToString(tick_sz,digits), DoubleToString(tick_val,2),
      DoubleToString(contract,0)));
   g_log.Info("INIT", StringFormat(
      "volume: min=%s max=%s step=%s | stops_level=%d freeze_level=%d",
      DoubleToString(min_lot,2), DoubleToString(max_lot,2), DoubleToString(lot_step,2),
      (int)stops_lvl, (int)freeze_lvl));
   g_log.Info("INIT", StringFormat(
      "trade_mode=%d execution=%d margin_check(%s1.0 lot)=%s err=%d",
      (int)trade_mode, (int)trade_exec, g_symbol,
      margin_ok ? DoubleToString(margin_buy,2) : "FAILED",
      GetLastError()));

   if(trade_mode == SYMBOL_TRADE_MODE_DISABLED)
      g_log.Warn("INIT", "trading is DISABLED for this symbol — EA will report but never fill");
   if(min_lot <= 0.0 || lot_step <= 0.0)
      g_log.Error("INIT", "invalid volume constraints from broker — do not trade this symbol");
   if(tick_sz <= 0.0 || tick_val <= 0.0)
      g_log.Error("INIT", "invalid tick size/value — risk sizing impossible; EA must not trade");
  }

//+------------------------------------------------------------------+
//| Mode sanity: refuse unsafe mode/permission combinations.         |
//+------------------------------------------------------------------+
bool ValidateModePermissions()
  {
   bool is_tester     = MQLInfoInteger(MQL_TESTER)!=0;
   bool is_demo_acct  = AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO;
   bool autotrading   = TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)!=0;

   switch(g_cfg.mode)
     {
      case XARE_MODE_PRODUCTION:
         if(!g_cfg.trading_enabled)
           { g_log.Error("INIT","PRODUCTION requires InpTradingEnabled=true"); return false; }
         if(is_tester)
            g_log.Warn("INIT","PRODUCTION mode inside tester behaves as BACKTEST");
         if(AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_REAL)
            g_log.Warn("INIT","PRODUCTION selected but account is NOT real — check config");
         if(!autotrading)
            g_log.Warn("INIT","AutoTrading is OFF — orders will be rejected by terminal");
         break;

      case XARE_MODE_DEMO:
         if(!g_cfg.trading_enabled)
           { g_log.Error("INIT","DEMO requires InpTradingEnabled=true"); return false; }
         if(!is_demo_acct && !is_tester)
            g_log.Error("INIT","DEMO mode requires a demo account (or tester)");
         if(!autotrading)
            g_log.Warn("INIT","AutoTrading is OFF — orders will be rejected by terminal");
         break;

      case XARE_MODE_SIGNAL_ONLY:
      case XARE_MODE_RESEARCH:
         if(g_cfg.trading_enabled)
            g_log.Warn("INIT","trading switch is ON but mode never trades — ignored");
         break;

      case XARE_MODE_BACKTEST:
         if(!is_tester)
            g_log.Warn("INIT","BACKTEST mode outside Strategy Tester — treated as SIGNAL_ONLY");
         break;

      case XARE_MODE_SELF_TEST:
         break;
     }
   return true;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol = _Symbol;

   // 1) config: inputs -> struct + defaults for anything not exposed yet
   XareConfigDefaults(g_cfg);
   g_cfg.mode               = InpMode;
   g_cfg.trading_enabled    = InpTradingEnabled;
   g_cfg.magic              = InpMagic;
   g_cfg.order_comment      = InpComment;
   g_cfg.dashboard_enabled  = InpDashboard;
   g_cfg.max_spread_points  = InpMaxSpreadPts;
   g_cfg.abnormal_spread_points = InpAbnSpreadPts;
   g_cfg.log_level          = InpLogLevel;
   g_cfg.journal_csv_enabled= InpJournalCSV;

   // M2: indicator periods
   g_cfg.ema_fast_period    = InpEmaFast;
   g_cfg.ema_mid_period     = InpEmaMid;
   g_cfg.ema_slow_period    = InpEmaSlow;
   g_cfg.rsi_period         = InpRsiPeriod;
   g_cfg.roc_period         = InpRocPeriod;
   g_cfg.adx_period         = InpAdxPeriod;
   g_cfg.atr_period         = InpAtrPeriod;
   g_cfg.history_bars_min   = InpHistoryBarsMin;

   // 2) logger
   if(!g_log.Init(g_symbol, g_cfg.magic, g_cfg.log_level,
                  g_cfg.journal_csv_enabled, g_cfg.journal_dir))
      g_log.Warn("INIT", "journal CSV unavailable — continuing without it");

   // 3) timeframe label
   switch(_Period)
     {
      case PERIOD_M5:  g_tf_label="M5";  break;
      case PERIOD_M15: g_tf_label="M15"; break;
      case PERIOD_H1:  g_tf_label="H1";  break;
      case PERIOD_H4:  g_tf_label="H4";  break;
      default:         g_tf_label=EnumToString(_Period);
     }

   g_log.Info("INIT", StringFormat("XARE v0.1.0 starting | mode=%s trading=%s symbol=%s tf=%s",
              XareModeToString(g_cfg.mode),
              g_cfg.trading_enabled?"ON":"OFF", g_symbol, g_tf_label));

   // 4) hard gates — init fails loudly rather than trading blind
   if(!ValidateModePermissions())
      return INIT_PARAMETERS_INCORRECT;

   LogSymbolCapabilities();

   // 5) engines: market data + indicators (M2)
   if(!g_md.Init(g_symbol, _Period, g_cfg.history_bars_min))
     {
      g_log.Error("INIT", "market data engine failed to initialize");
      return INIT_FAILED;
     }
   if(!g_ind.Init(g_symbol, _Period, g_cfg))
     {
      g_log.Error("INIT", "indicator engine failed to initialize");
      return INIT_FAILED;
     }
   if(!g_mtf.Init(g_symbol, _Period, g_cfg, &g_log))
     {
      g_log.Error("INIT", "multi-timeframe engine failed to initialize");
      g_ind.Release();
      return INIT_FAILED;
     }
   if(!g_regime.Init(g_symbol, _Period, g_cfg, /*atr_handle=*/g_ind.ATRHandle(), &g_log))
     {
      g_log.Error("INIT", "regime engine failed to initialize");
      g_mtf.Release();
      g_ind.Release();
      return INIT_FAILED;
     }
   if(!g_struct.Init(g_symbol, _Period, g_cfg.pivot_lookback,
                     g_cfg.pivot_confirm, g_cfg.structure_max_zones, &g_log))
     {
      g_log.Error("INIT", "structure engine failed to initialize");
      g_mtf.Release();
      g_ind.Release();
      return INIT_FAILED;
     }
   SXareSymbolProps props;
   g_md.GetProps(props);
   g_log.Info("INIT", StringFormat("engines ready | props.valid=%s min_history=%d mtf=H4+H1+%s",
              props.valid ? "true" : "false", g_cfg.history_bars_min, g_tf_label));

   // 6) dashboard
   g_ui.Init(g_cfg.dashboard_enabled, "v0.2.0");

   g_init_ok = true;
   g_log.Info("INIT", "initialization complete (M2: data+features live, no trading)");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_log.Info("INIT", StringFormat("deinit reason=%d", reason));
   g_mtf.Release();          // MTF EMA handles (§64)
   g_ind.Release();          // indicator handles (§64)
   g_ui.Deinit();
   g_log.Deinit();
  }

//+------------------------------------------------------------------+
//| Self-test: arithmetic sanity used in Strategy Tester (§53).      |
//| v0.2.0: M2 adds ROC/price-normalization math on synthetic values.|
//+------------------------------------------------------------------+
void RunSelfTest()
  {
   int failed = 0;

   // T1: defaults must be safe-by-default
   SXareConfig c;
   XareConfigDefaults(c);
   if(c.mode != XARE_MODE_SIGNAL_ONLY)      { failed++; Print("SELFTEST FAIL T1 mode default"); }
   if(c.trading_enabled)                    { failed++; Print("SELFTEST FAIL T1 trading default"); }

   // T2: enum->string helpers are exhaustive
   if(XareRegimeToString(XARE_REGIME_TREND_UP) != "TREND_UP")      { failed++; }
   if(XareSetupToString(XARE_SETUP_BREAKOUT)   != "BREAKOUT")      { failed++; }
   if(XareRiskStateToString(XARE_RISK_HALTED)  != "HALTED")        { failed++; }
   if(XareExitToString(XARE_EXIT_TRAILING)     != "TRAILING_STOP") { failed++; }

   // T3 (M2): ROC math
   if(MathAbs(XareRateOfChange(110.0, 100.0) - 10.0) > 1e-9)  { failed++; Print("SELFTEST FAIL T3 roc up"); }
   if(MathAbs(XareRateOfChange(90.0, 100.0) - (-10.0)) > 1e-9){ failed++; Print("SELFTEST FAIL T3 roc down"); }
   if(XareRateOfChange(100.0, 0.0) != 0.0)                    { failed++; Print("SELFTEST FAIL T3 roc zero-div"); }

   // T7 (M5): pivot confirmation math — a pivot needs lookback + confirm bars
   if(CXareStructureEngine::MinBarsForPivot(3, 2) != 5)
      { failed++; Print("SELFTEST FAIL T7 pivot math"); }

   // T6 (M4): regime classifier priority — volatility overrides, then breakout,
   // then trend, then range; ADX-strong without stack agreement ⇒ UNKNOWN
   if(XareClassifyRegime(false,false,false,false,true,false)
      != XARE_REGIME_HIGH_VOLATILITY) { failed++; Print("SELFTEST FAIL T6 vol-high priority"); }
   if(XareClassifyRegime(false,false,false,false,false,true)
      != XARE_REGIME_LOW_VOLATILITY)  { failed++; Print("SELFTEST FAIL T6 vol-low priority"); }
   if(XareClassifyRegime(true,true,false,true,false,false)
      != XARE_REGIME_BREAKOUT)        { failed++; Print("SELFTEST FAIL T6 breakout priority"); }
   if(XareClassifyRegime(false,true,false,true,false,false)
      != XARE_REGIME_TREND_UP)        { failed++; Print("SELFTEST FAIL T6 trend up"); }
   if(XareClassifyRegime(false,false,true,true,false,false)
      != XARE_REGIME_TREND_DOWN)      { failed++; Print("SELFTEST FAIL T6 trend down"); }
   if(XareClassifyRegime(false,false,true,false,false,false)
      != XARE_REGIME_RANGE)           { failed++; Print("SELFTEST FAIL T6 range"); }
   if(XareClassifyRegime(false,false,false,true,false,false)
      != XARE_REGIME_UNKNOWN)         { failed++; Print("SELFTEST FAIL T6 unknown"); }

   // T5 (M3): MTF alignment classifier — mixed info must never force a side
   if(CXareMultiTimeframe::ClassifyStatic(XARE_TF_BULL,XARE_TF_BULL,XARE_TF_BULL)
      != XARE_ALIGN_BULLISH) { failed++; Print("SELFTEST FAIL T5 bull align"); }
   if(CXareMultiTimeframe::ClassifyStatic(XARE_TF_BEAR,XARE_TF_BEAR,XARE_TF_BEAR)
      != XARE_ALIGN_BEARISH) { failed++; Print("SELFTEST FAIL T5 bear align"); }
   if(CXareMultiTimeframe::ClassifyStatic(XARE_TF_BULL,XARE_TF_BEAR,XARE_TF_BULL)
      != XARE_ALIGN_MIXED)   { failed++; Print("SELFTEST FAIL T5 mixed align"); }
   if(CXareMultiTimeframe::ClassifyStatic(XARE_TF_BULL,XARE_TF_NEUTRAL,XARE_TF_BULL)
      != XARE_ALIGN_NEUTRAL) { failed++; Print("SELFTEST FAIL T5 neutral align"); }

   // T4 (M2): price normalization math vs tick-size grid (same formula as
   // CXareMarketData::NormalizePrice, on synthetic values)
   double n1 = NormalizeDouble(MathRound(123.478/0.05)*0.05, 2);  // expect 123.50
   if(MathAbs(n1 - 123.50) > 1e-9)                            { failed++; Print("SELFTEST FAIL T4 tick-grid"); }

   if(failed==0) Print("XARE SELF-TEST: PASS (7 groups)");
   else          Print("XARE SELF-TEST: FAIL (", failed, " checks)");
  }

//+------------------------------------------------------------------+
//| Heartbeat: proves tick flow + dashboard liveness.                |
//+------------------------------------------------------------------+
void Heartbeat()
  {
   datetime now = TimeCurrent();
   if(now - g_last_heartbeat < 300)   // every 5 minutes max
      return;
   g_last_heartbeat = now;
   g_log.Debug("TICK", StringFormat("alive | mode=%s | %s %s",
               XareModeToString(g_cfg.mode), g_symbol, g_tf_label));
  }

//+------------------------------------------------------------------+
//| M2 per-bar pipeline: new bar -> closed-bar features -> log.      |
//| No trading, no orders — evaluation only.                         |
//+------------------------------------------------------------------+
void ProcessBar()
  {
   SXareBar  bar;
   SXareFeatures f;
   if(!g_md.GetClosedBar(1, bar))
     {
      if(!g_features_warned)
        {
         g_log.Warn("FEAT", "closed bar unavailable — idle");
         g_features_warned = true;
        }
      return;
     }
   if(!g_ind.Update(1, f) || !f.valid)
     {
      if(!g_features_warned)
        {
         g_log.Warn("FEAT", "features unavailable (warming up or history gap) — idle");
         g_features_warned = true;
        }
      return;
     }
   g_features_warned = false;
   g_last_processed_bar = f.bar_time;

   // --- M3: execution-TF label from the same EMA rule, then MTF alignment
   ENUM_XARE_TF_LABEL exec_label = XARE_TF_NEUTRAL;
   if(f.ema_fast > f.ema_mid && bar.close > f.ema_mid)      exec_label = XARE_TF_BULL;
   else if(f.ema_fast < f.ema_mid && bar.close < f.ema_mid) exec_label = XARE_TF_BEAR;
   SXareMTF mtf;
   bool mtf_ok = g_mtf.Evaluate(1, exec_label, mtf);

   int spread = g_md.CurrentSpreadPoints();
   SXareSymbolProps props;
   g_md.GetProps(props);
   int dg = props.digits;
   g_log.Debug("FEAT", StringFormat(
      "bar=%s O=%s H=%s L=%s C=%s | ema20=%s ema50=%s ema200=%s rsi=%.1f roc=%.2f adx=%.1f (+DI %.1f / -DI %.1f) atr=%s spread=%dpt",
      TimeToString(f.bar_time, TIME_DATE|TIME_MINUTES),
      DoubleToString(bar.open,  dg), DoubleToString(bar.high, dg),
      DoubleToString(bar.low,   dg), DoubleToString(bar.close, dg),
      DoubleToString(f.ema_fast, dg), DoubleToString(f.ema_mid, dg),
      DoubleToString(f.ema_slow, dg),
      f.rsi, f.roc, f.adx, f.di_plus, f.di_minus,
      DoubleToString(f.atr, dg), spread));
   if(mtf_ok)
      g_log.Debug("MTF", StringFormat("alignment=%s (%s)",
                  mtf.alignment==XARE_ALIGN_BULLISH ? "BULLISH" :
                  mtf.alignment==XARE_ALIGN_BEARISH ? "BEARISH" :
                  mtf.alignment==XARE_ALIGN_MIXED   ? "MIXED"   : "NEUTRAL",
                  mtf.evidence));

   // --- M4: regime classification
   SXareRegime regime;
   if(g_regime.Evaluate(1, f, bar, regime) && regime.valid)
      g_log.Info("REGIME", StringFormat("%s conf=%d | %s",
                  XareRegimeToString(regime.regime), regime.confidence, regime.evidence));

   // --- M5: market structure
   SXareStructure structure;
   if(g_struct.Evaluate(1, structure) && structure.valid)
      g_log.Info("STRUCT", structure.evidence);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_init_ok)
      return;

   if(g_cfg.mode == XARE_MODE_SELF_TEST)
     {
      RunSelfTest();
      ExpertRemove();   // one-shot
      return;
     }

   Heartbeat();

   // --- M2: new-bar gate + duplicate processing guard -----------------
   if(g_md.IsNewBar())
     {
      ProcessBar();
     }

   // --- dashboard snapshot (live values; analytics still placeholders) -
   double price       = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   int    spread_pts  = g_md.CurrentSpreadPoints();
   SXareFeatures feat;
   bool have_feat = g_ind.Last(feat);
   int    open_xare   = 0;   // PositionManager counts by magic from M11
   double daily_pl    = 0.0;   // RiskEngine from M9
   double dd_pct      = 0.0;   // RiskEngine from M9

   g_ui.Update(g_symbol, g_tf_label, g_cfg.mode, price, spread_pts,
               have_feat ? "FEATURES_OK" : "UNKNOWN", 0, "NO_TRADE", 0.0,
               XareRiskStateToString(XARE_RISK_NORMAL),
               daily_pl, dd_pct, open_xare, "N/A",
               /*trading_allowed=*/false);
  }
//+------------------------------------------------------------------+
