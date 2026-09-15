//+------------------------------------------------------------------+
//|                                                     XARE.mq5     |
//|        XARE — XAUUSD Adaptive Risk Engine  (v0.9.0, M9)          |
//|                                                                  |
//| Data/feature/context layers live: market data, indicators, MTF,  |
//| regime, structure, session, liquidity — all on closed bars.      |
//| M7 signal engine (6 setups + NO_TRADE reasons) and M8 scoring    |
//| (0–100 weighted breakdown) are wired.                            |
//| M9 risk engine: dynamic sizing from broker properties, daily/    |
//| weekly loss limits, drawdown states, streak cooldown.            |
//| M10 execution: fully priced trade PLAN per signal bar (pure      |
//| builder + §29 validation chain). M11 position state machine +    |
//| management decisions (BE/trail/partial/time/regime/reversal).    |
//| M12 safety gate: ONE GO/BLOCK choke point; emergency latch.      |
//| Orders flow ONLY through: safety gate -> execution engine.       |
//| Trading modes (DEMO/PRODUCTION/BACKTEST) require the explicit    |
//| trading switch; default mode never sends.                        |
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
#property description "XARE — XAUUSD Adaptive Risk Engine (research build, M12)"

#include <XARE\Types.mqh>
#include <XARE\Config.mqh>
#include <XARE\Logger.mqh>
#include <XARE\Diagnostics.mqh>
#include <XARE\MarketData.mqh>
#include <XARE\Indicators.mqh>
#include <XARE\MultiTimeframe.mqh>
#include <XARE\RegimeEngine.mqh>
#include <XARE\StructureEngine.mqh>
#include <XARE\SessionEngine.mqh>
#include <XARE\LiquidityEngine.mqh>
#include <XARE\SignalEngine.mqh>
#include <XARE\ScoreEngine.mqh>
#include <XARE\RiskEngine.mqh>
#include <XARE\ExecutionEngine.mqh>
#include <XARE\PositionManager.mqh>
#include <XARE\ExitEngine.mqh>
#include <XARE\SafetyEngine.mqh>
#include <XARE\NewsFilter.mqh>
#include <XARE\ResearchLogger.mqh>
#include <XARE\PerformanceTracker.mqh>

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

input group  "Signals"
input bool           InpSetupTrendCont  = true;                  // Setup: TREND_CONTINUATION
input bool           InpSetupPullback   = true;                  // Setup: TREND_PULLBACK
input bool           InpSetupBreakout   = true;                  // Setup: BREAKOUT
input bool           InpSetupRetest     = true;                  // Setup: BREAKOUT_RETEST
input bool           InpSetupRangeRev   = true;                  // Setup: RANGE_REVERSAL
input bool           InpSetupSweepRev   = true;                  // Setup: LIQ_SWEEP_REVERSAL
input double         InpPullbackZoneATR = 1.2;                   // Pullback zone half-width (ATR)
input double         InpMinSetupConf    = 55.0;                  // Min setup confidence
input int            InpRetestValidBars = 8;                     // Retest window (bars)

input group  "Scoring (v0.8: hypotheses, see docs/parameters.md)"
input double         InpWTrend          = 20.0;                  // Weight: trend (max 20)
input double         InpWMTF            = 15.0;                  // Weight: MTF alignment (max 15)
input double         InpWStructure      = 15.0;                  // Weight: structure (max 15)
input double         InpWMomentum       = 10.0;                  // Weight: momentum (max 10)
input double         InpWLiquidity      = 15.0;                  // Weight: liquidity (max 15)
input double         InpWVolatility     = 10.0;                  // Weight: volatility (max 10)
input double         InpWSession        = 5.0;                   // Weight: session (max 5)
input double         InpWSetup          = 10.0;                  // Weight: setup quality (max 10)
input double         InpScoreMin        = 60.0;                  // Band floor: below = no trade
input double         InpScoreCandidate  = 70.0;                  // Band: candidate from
input double         InpScoreTrade      = 80.0;                  // Band: trade from
input double         InpScoreStrong     = 85.0;                  // Band: strong from

input group  "Risk (v0.9: conservative defaults, docs/parameters.md)"
input double         InpRiskPerTradePct = 0.5;                   // Risk per trade (% equity)
input double         InpRiskFloorPct    = 0.10;                  // Risk floor (%; below = skip)
input double         InpDailyLossPct    = 2.0;                   // Daily loss limit (% equity)
input double         InpWeeklyLossPct   = 5.0;                   // Weekly loss limit (% equity)
input double         InpDDCautionPct    = 5.0;                   // DD: caution state from (%)
input double         InpDDReducedPct    = 10.0;                  // DD: reduced state from (%)
input double         InpDDHaltPct       = 15.0;                  // DD: halt state from (%)
input double         InpRiskMultCaution = 0.5;                   // Risk x in CAUTION
input double         InpRiskMultReduced = 0.25;                  // Risk x in REDUCED
input int            InpMaxConsecLosses = 3;                     // Loss streak -> cooldown
input int            InpCooldownBars    = 4;                     // Cooldown length (bars)
input int            InpMaxTradesPerDay = 3;                     // Max trades per day
input int            InpMaxPositions    = 1;                     // Max concurrent positions
input bool           InpCloseOnDailyLim = false;                 // Close positions at daily limit
input double         InpSLAtrMult       = 1.5;                   // SL: ATR multiplier
input double         InpTPRMultiple     = 2.0;                   // TP: R multiple of SL
input double         InpEmergMaxLot     = 0.50;                  // Emergency max lot (hard cap)
input double         InpMaxMarginPct    = 50.0;                  // Max margin (% of free)

input group  "Safety (v0.12: fail-safe defaults)"
input int            InpNewsBeforeMin   = 30;                    // News blackout before HIGH event (min)
input int            InpNewsAfterMin    = 30;                    // News blackout after HIGH event (min)
input int            InpExpectMinTrades = 30;                    // Expectancy gate: min closed trades
input double         InpExpectBlockR    = 0.10;                  // Expectancy gate: block below -R

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
CXareSessionEngine  g_sess;
CXareLiquidityEngine g_liq;
CXareSignalEngine   g_sig;
CXareScoreEngine    g_score;
CXareRiskEngine     g_risk;
CXareExecutionEngine g_exec;
CXarePositionManager g_pos;
CXareExitEngine     g_exit;
CXareSafetyEngine   g_safety;
CXareNewsFilter     g_news;
CXareResearchLogger g_res;
CXarePerformanceTracker g_perf;

//--- last bar decision (for dashboard; signal-only — nothing is executed)
SXareDecision     g_last_decision;
SXareScore        g_last_score;
bool              g_have_decision = false;
bool              g_have_score    = false;
SXareRegime       g_last_regime;
bool              g_have_regime   = false;
SXareTradeDecision g_last_plan;     // fully priced plan (M10; not sent here)
bool              g_have_plan     = false;
bool              g_emergency_ref = false;   // mirror of the safety latch
string            g_sess_cache    = "N/A";   // last evaluated session label
string            g_news_ui_why   = "";      // news reason scratch (panel)

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

   // M7: signal setup flags and thresholds
   g_cfg.setup_trend_continuation       = InpSetupTrendCont;
   g_cfg.setup_trend_pullback           = InpSetupPullback;
   g_cfg.setup_breakout                 = InpSetupBreakout;
   g_cfg.setup_breakout_retest          = InpSetupRetest;
   g_cfg.setup_range_reversal           = InpSetupRangeRev;
   g_cfg.setup_liquidity_sweep_reversal = InpSetupSweepRev;
   g_cfg.pullback_ema_zone_atr          = InpPullbackZoneATR;
   g_cfg.min_setup_confidence           = InpMinSetupConf;
   g_cfg.retest_valid_bars              = InpRetestValidBars;

   // M8: scoring weights + bands (hypotheses — docs/parameters.md)
   g_cfg.w_trend                 = InpWTrend;
   g_cfg.w_mtf                   = InpWMTF;
   g_cfg.w_structure             = InpWStructure;
   g_cfg.w_momentum              = InpWMomentum;
   g_cfg.w_liquidity             = InpWLiquidity;
   g_cfg.w_volatility            = InpWVolatility;
   g_cfg.w_session               = InpWSession;
   g_cfg.w_setup                 = InpWSetup;
   g_cfg.score_min               = InpScoreMin;
   g_cfg.score_candidate         = InpScoreCandidate;
   g_cfg.score_trade             = InpScoreTrade;
   g_cfg.score_strong            = InpScoreStrong;

   // M9: risk group
   g_cfg.risk_per_trade_pct      = InpRiskPerTradePct;
   g_cfg.risk_floor_pct          = InpRiskFloorPct;
   g_cfg.daily_loss_limit_pct    = InpDailyLossPct;
   g_cfg.weekly_loss_limit_pct   = InpWeeklyLossPct;
   g_cfg.dd_caution_pct          = InpDDCautionPct;
   g_cfg.dd_reduced_pct          = InpDDReducedPct;
   g_cfg.dd_halt_pct             = InpDDHaltPct;
   g_cfg.risk_mult_caution       = InpRiskMultCaution;
   g_cfg.risk_mult_reduced       = InpRiskMultReduced;
   g_cfg.max_consecutive_losses  = InpMaxConsecLosses;
   g_cfg.cooldown_bars           = InpCooldownBars;
   g_cfg.max_trades_per_day      = InpMaxTradesPerDay;
   g_cfg.max_concurrent_positions= InpMaxPositions;
   g_cfg.close_on_daily_limit    = InpCloseOnDailyLim;
   g_cfg.sl_atr_mult             = InpSLAtrMult;
   g_cfg.tp_r_multiple           = InpTPRMultiple;
   g_cfg.emergency_max_lot_x1000 = (long)MathRound(InpEmergMaxLot * 1000.0);
   g_cfg.max_margin_pct          = InpMaxMarginPct;
   g_cfg.working_tf              = _Period;

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

   g_log.Info("INIT", StringFormat("XARE v0.12.0 starting | mode=%s trading=%s symbol=%s tf=%s",
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
   if(!g_sess.Init(g_symbol, _Period, g_cfg, &g_log) ||
      !g_liq.Init(g_symbol, _Period, g_cfg, &g_log))
     {
      g_log.Error("INIT", "session/liquidity engine failed to initialize");
      g_mtf.Release();
      g_ind.Release();
      return INIT_FAILED;
     }
   // M8: score-weight sanity — weights must sum to 100 (§16) or init fails
   if(!XareWeightsValid(g_cfg.w_trend, g_cfg.w_mtf, g_cfg.w_structure,
                        g_cfg.w_momentum, g_cfg.w_liquidity, g_cfg.w_volatility,
                        g_cfg.w_session, g_cfg.w_setup))
     {
      g_log.Error("INIT", "scoring weights must sum to 100 — refusing to start");
      g_mtf.Release();
      g_ind.Release();
      return INIT_PARAMETERS_INCORRECT;
     }

   g_sig.Init(g_cfg);   // pure engine; cannot fail
   g_score.Init(g_cfg); // pure engine; cannot fail
   g_exec.Init(g_cfg);  // execution layer (send path armed for M11+)
   g_pos.Init(g_cfg.magic, &g_log);   // position state machine
   g_exit.Init(g_cfg);  // pure management decisions
   g_safety.Init();     // gatekeeper + emergency latch
   g_news.Init(InpNewsBeforeMin, InpNewsAfterMin);  // §14 fail-safe filter
   g_cfg.expectancy_min_trades = InpExpectMinTrades;
   g_cfg.expectancy_block_r    = InpExpectBlockR;
   g_perf.Init(g_cfg);  // §17/§39 rolling stats (abstains until sample ready)
   if(!g_res.Init(g_cfg.mode == XARE_MODE_RESEARCH, g_cfg.journal_dir))
      g_log.Warn("INIT", "research CSV unavailable — continuing without it");
   SXareSymbolProps props;
   g_md.GetProps(props);
   g_risk.Init(g_cfg, props);   // anchors equity/day/week at init
   if(g_risk.Ready())
      g_log.Info("RISK", StringFormat("risk anchors set | equity=%.2f risk/trade=%.2f%% daily_limit=%.2f%%",
                 AccountInfoDouble(ACCOUNT_EQUITY), g_cfg.risk_per_trade_pct,
                 g_cfg.daily_loss_limit_pct));
   else
      g_log.Warn("RISK", "equity unavailable at init — risk engine idle until first Update");
   g_log.Info("INIT", StringFormat("engines ready | props.valid=%s min_history=%d mtf=H4+H1+%s",
              props.valid ? "true" : "false", g_cfg.history_bars_min, g_tf_label));

   // 6) dashboard
   g_ui.Init(g_cfg.dashboard_enabled, "v0.12.0");

   g_init_ok = true;
   g_log.Info("INIT", StringFormat("initialization complete (all engines live; safety gate active; news filter %s; research CSV %s)",
              g_news.Enabled() ? "ENABLED" : "DISABLED (no calendar — fail-safe clear)",
              g_res.Ready() ? "ON" : "OFF"));
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

   // T8 (M6): session classification priority (overlap > NY > London > Asian)
   // windows: London 420..960, NY 750..1260, Asian 0..480 (broker minutes)
   if(CXareSessionEngine::ClassifyStatic(900, 420,960,750,1260,0,480)
      != XARE_SESS_OVERLAP)  { failed++; Print("SELFTEST FAIL T8 overlap"); }
   if(CXareSessionEngine::ClassifyStatic(1100, 420,960,750,1260,0,480)
      != XARE_SESS_NEWYORK)  { failed++; Print("SELFTEST FAIL T8 ny"); }
   if(CXareSessionEngine::ClassifyStatic(600, 420,960,750,1260,0,480)
      != XARE_SESS_LONDON)   { failed++; Print("SELFTEST FAIL T8 london"); }
   if(CXareSessionEngine::ClassifyStatic(200, 420,960,750,1260,0,480)
      != XARE_SESS_ASIAN)    { failed++; Print("SELFTEST FAIL T8 asian"); }
   if(CXareSessionEngine::ClassifyStatic(1400, 420,960,750,1260,0,480)
      != XARE_SESS_OFF)      { failed++; Print("SELFTEST FAIL T8 off"); }

   // T8b (M6): sweep math — wick-through-close-back, depth >= mult*ATR
   bool up, down; double pen;
   if(!CXareLiquidityEngine::SweepStatic(2000.0, 2001.0, 1995.0, 1998.0,
                                         2.0, 0.25, up, down, pen) || !up)
      { failed++; Print("SELFTEST FAIL T8b sweep up"); }
   if(CXareLiquidityEngine::SweepStatic(2000.0, 2003.0, 1999.0, 2002.0,
                                        2.0, 0.25, up, down, pen))
      { failed++; Print("SELFTEST FAIL T8b close-above is not a sweep"); }
   if(CXareLiquidityEngine::SweepStatic(2000.0, 2000.3, 1999.0, 1999.5,
                                        2.0, 0.25, up, down, pen))
      { failed++; Print("SELFTEST FAIL T8b shallow wick is not a sweep"); }

   // T9 (M7): signal-engine gates on synthetic contexts ---------------
   SXareConfig sc; XareConfigDefaults(sc);
   SXareRegime   rg;  rg.valid=true; rg.regime=XARE_REGIME_TREND_UP; rg.confidence=80; rg.evidence="t"; rg.evaluated_at=0;
   SXareMTF      mt;  mt.valid=true; mt.alignment=XARE_ALIGN_BULLISH; mt.h4=XARE_TF_BULL; mt.h1=XARE_TF_BULL; mt.exec=XARE_TF_BULL; mt.evidence="t"; mt.evaluated_at=0;
   SXareStructure stp; stp.valid=true; stp.trend=XARE_STRUCT_BULLISH;
                     stp.last_swing_high=2050.0; stp.prev_swing_high=2040.0;
                     stp.last_swing_low=2000.0;  stp.prev_swing_low=1990.0;
                     stp.bos_bull=false; stp.bos_bear=false; stp.choch=false;
                     stp.zone_count_res=0; stp.zone_count_sup=0; stp.evidence=""; stp.evaluated_at=0;
   for(int i=0;i<4;i++){ stp.resistance[i]=0; stp.support[i]=0; }
   SXareSession  ss;  ss.valid=true; ss.session=XARE_SESS_LONDON; ss.minute_of_day=600; ss.high=2055; ss.low=2005; ss.range=50; ss.episode_bars=5; ss.evidence=""; ss.evaluated_at=0;
   SXareLiquidity lq; lq.valid=true; lq.sweep_up=false; lq.sweep_down=false; lq.swept_level=0; lq.level_name=""; lq.penetration_atr=0; lq.evidence=""; lq.evaluated_at=0;
   SXareFeatures ft;  ft.valid=true; ft.bar_time=D'2026.01.05 10:00';
                     ft.ema_fast=2045; ft.ema_mid=2035; ft.ema_slow=2010;
                     ft.rsi=55; ft.roc=0.5; ft.adx=30; ft.di_plus=25; ft.di_minus=15; ft.atr=4.0;
   SXareBar      br;  br.time=D'2026.01.05 10:15'; br.open=2040; br.high=2052; br.low=2036; br.close=2048; br.tick_volume=1000; br.spread=150;

   CXareSignalEngine sigT;
   sigT.Init(sc);

   // T9a: everything valid but no trigger ⇒ NO_TRADE with reason.
   // Bearish close (no rejection candle) and no ROC re-acceleration ensure
   // neither pullback nor continuation can fire on this bar.
   SXareBar br_nt; br_nt.time=D'2026.01.05 10:15'; br_nt.open=2046; br_nt.high=2052;
             br_nt.low=2042; br_nt.close=2044; br_nt.tick_volume=1000; br_nt.spread=150;
   SXareDecision d9;
   sigT.Evaluate(rg, mt, stp, ss, lq, br_nt, ft, 0.7, d9);
   if(d9.has_signal || d9.nt_reason == XARE_NT_NONE)
      { failed++; Print("SELFTEST FAIL T9a no-trade-reason"); }

   // T9b: invalid features ⇒ INSUFFICIENT_DATA
   SXareFeatures ft_bad = ft; ft_bad.valid = false;
   SXareDecision d9b;
   sigT.Evaluate(rg, mt, stp, ss, lq, br, ft_bad, 0.1, d9b);
   if(d9b.has_signal || d9b.nt_reason != XARE_NT_INSUFFICIENT_DATA)
      { failed++; Print("SELFTEST FAIL T9b insufficient-data"); }

   // T9c: UNSAFE regime ⇒ REGIME_INCOMPATIBLE
   SXareRegime rg_bad = rg; rg_bad.regime = XARE_REGIME_UNSAFE;
   SXareDecision d9c;
   sigT.Evaluate(rg_bad, mt, stp, ss, lq, br, ft, 0.1, d9c);
   if(d9c.has_signal || d9c.nt_reason != XARE_NT_REGIME_INCOMPATIBLE)
      { failed++; Print("SELFTEST FAIL T9c regime-incompatible"); }

   // T9d: low regime confidence ⇒ REGIME_CONFIDENCE
   SXareRegime rg_low = rg; rg_low.confidence = 30;
   SXareDecision d9d;
   sigT.Evaluate(rg_low, mt, stp, ss, lq, br, ft, 0.1, d9d);
   if(d9d.has_signal || d9d.nt_reason != XARE_NT_REGIME_CONFIDENCE)
      { failed++; Print("SELFTEST FAIL T9d regime-confidence"); }

   // T10a: MIXED alignment ⇒ ALIGNMENT_CONFLICT (no forced side)
   SXareMTF mt_mix = mt; mt_mix.alignment = XARE_ALIGN_MIXED;
   SXareDecision d10;
   sigT.Evaluate(rg, mt_mix, stp, ss, lq, br, ft, 0.1, d10);
   if(d10.has_signal || d10.nt_reason != XARE_NT_ALIGNMENT_CONFLICT)
      { failed++; Print("SELFTEST FAIL T10a alignment-conflict"); }

   // T10b: pullback direction matches alignment (bull setup only on bullish)
   SXareBar br_pb = br; br_pb.open=2044; br_pb.high=2050; br_pb.low=2038; br_pb.close=2049;
   // ema zone: 2040.4..2046.6 (zone 1.2*4*0.5=2.4 around 2038..2044+... )
   // touched zone (low 2038 <= zhi), bullish rejection close, rsi 55
   SXareDecision d10b;
   sigT.Evaluate(rg, mt, stp, ss, lq, br_pb, ft, 0.1, d10b);
   if(!d10b.has_signal || d10b.direction <= 0 ||
      d10b.setup != XARE_SETUP_TREND_PULLBACK)
      { failed++; Print("SELFTEST FAIL T10b pullback-direction"); }

   // T10c: disabled setup ⇒ SETUP_DISABLED
   SXareConfig sc_off = sc; sc_off.setup_trend_pullback = false;
   CXareSignalEngine sig_off; sig_off.Init(sc_off);
   SXareDecision d10c;
   sig_off.Evaluate(rg, mt, stp, ss, lq, br_pb, ft, 0.1, d10c);
   if(d10c.has_signal || d10c.nt_reason != XARE_NT_SETUP_DISABLED)
      { failed++; Print("SELFTEST FAIL T10c setup-disabled"); }

   // T10d: sweep reversal fires on sellside sweep with reclaim (bull)
   SXareLiquidity lq_sw = lq; lq_sw.sweep_down = true; lq_sw.swept_level = 2000.0;
   lq_sw.level_name = "PDL"; lq_sw.penetration_atr = 0.6;
   SXareBar br_sw = br; br_sw.low=1998.5; br_sw.close=2003.0;
   // NOTE: alignment is bullish in this synthetic context, so the sweep-reversal
   // long is permitted; regime TREND_UP with conf 80 passes gates.
   CXareSignalEngine sig_sw; sig_sw.Init(sc);
   SXareDecision d10d;
   sig_sw.Evaluate(rg, mt, stp, ss, lq_sw, br_sw, ft, 0.1, d10d);
   if(!d10d.has_signal || d10d.setup != XARE_SETUP_LIQUIDITY_SWEEP_REVERSAL ||
      d10d.direction <= 0)
      { failed++; Print("SELFTEST FAIL T10d sweep-reversal"); }

   // T10e: conflicting signals — sweep long vs MIXED alignment ⇒ conflict wins
   SXareDecision d10e;
   sig_sw.Evaluate(rg, mt_mix, stp, ss, lq_sw, br_sw, ft, 0.1, d10e);
   if(d10e.has_signal || d10e.nt_reason != XARE_NT_ALIGNMENT_CONFLICT)
      { failed++; Print("SELFTEST FAIL T10e conflict-beats-sweep"); }

   // T13 (M9): financial math on synthetic (NOT assumed) broker properties --
   SXareSymbolProps gold_like;   // 100oz-style contract; values are test data only
   gold_like.symbol="TEST"; gold_like.digits=2; gold_like.point=0.01;
   gold_like.tick_size=0.01; gold_like.tick_value=1.0; gold_like.contract_size=100.0;
   gold_like.volume_min=0.01; gold_like.volume_max=100.0; gold_like.volume_step=0.01;
   gold_like.stops_level=0; gold_like.freeze_level=0; gold_like.trade_mode=4; gold_like.valid=true;

   // point value = tick_value x (point/tick_size)
   if(MathAbs(XarePointValuePerLot(gold_like) - 1.0) > 1e-9)
      { failed++; Print("SELFTEST FAIL T13 point-value"); }
   SXareSymbolProps odd = gold_like; odd.tick_size = 0.05; odd.tick_value = 2.5;
   if(MathAbs(XarePointValuePerLot(odd) - 0.5) > 1e-9)   // 2.5 x (0.01/0.05)
      { failed++; Print("SELFTEST FAIL T13 odd-tick"); }

   // sizing: equity 1000 @ 1% = 10; SL 500pts x $1/lot = $500/lot -> 0.02
   double v9, rm9;
   if(!XareVolumeForRisk(1000.0, 1.0, 500.0, gold_like, 50.0, v9, rm9) ||
      MathAbs(v9 - 0.02) > 1e-9 || MathAbs(rm9 - 10.0) > 1e-9)
      { failed++; Print("SELFTEST FAIL T13 sizing-basic"); }
   // below broker minimum -> refused, never padded up (§19/§49)
   if(XareVolumeForRisk(1000.0, 0.01, 500.0, gold_like, 50.0, v9, rm9))
      { failed++; Print("SELFTEST FAIL T13 below-min-refused"); }
   // emergency cap enforced even with huge equity (§50)
   if(!XareVolumeForRisk(100000.0, 5.0, 500.0, gold_like, 0.5, v9, rm9) ||
      MathAbs(v9 - 0.5) > 1e-9)
      { failed++; Print("SELFTEST FAIL T13 emergency-cap"); }
   // volume step snaps DOWN only (raw 0.54 -> 0.5)
   SXareSymbolProps stepy = gold_like; stepy.volume_step = 0.1;
   if(!XareVolumeForRisk(1000.0, 1.08, 20.0, stepy, 50.0, v9, rm9) ||
      MathAbs(v9 - 0.5) > 1e-9)
      { failed++; Print("SELFTEST FAIL T13 snap-down"); }
   // invalid properties are refused outright
   SXareSymbolProps badp = gold_like; badp.valid = false;
   if(XareVolumeForRisk(1000.0, 1.0, 500.0, badp, 50.0, v9, rm9))
      { failed++; Print("SELFTEST FAIL T13 invalid-props"); }

   // drawdown -> state ladder (§25)
   if(XareRiskStateFromDD(1.0, 5.0, 10.0, 15.0)  != XARE_RISK_NORMAL)  { failed++; Print("SELFTEST FAIL T13 state-normal"); }
   if(XareRiskStateFromDD(6.0, 5.0, 10.0, 15.0)  != XARE_RISK_CAUTION) { failed++; Print("SELFTEST FAIL T13 state-caution"); }
   if(XareRiskStateFromDD(11.0, 5.0, 10.0, 15.0) != XARE_RISK_REDUCED) { failed++; Print("SELFTEST FAIL T13 state-reduced"); }
   if(XareRiskStateFromDD(16.0, 5.0, 10.0, 15.0) != XARE_RISK_HALTED)  { failed++; Print("SELFTEST FAIL T13 state-halt"); }

   // effective risk scales DOWN only; HALTED is a hard zero (§31)
   if(MathAbs(XareEffectiveRiskPct(XARE_RISK_REDUCED, 0.5, 0.5, 0.25) - 0.125) > 1e-9)
      { failed++; Print("SELFTEST FAIL T13 eff-risk"); }
   if(XareEffectiveRiskPct(XARE_RISK_HALTED, 0.5, 0.5, 0.25) != 0.0)
      { failed++; Print("SELFTEST FAIL T13 halted-zero"); }

   // stop distances: hybrid = max(ATR x mult, structure); floor respected
   double sd9;
   if(!XareStopDistance(1, 2000.0, 1990.0, 4.0, 1.5, XARE_SL_HYBRID, 1.0, sd9) ||
      MathAbs(sd9 - 10.0) > 1e-9)      // structure 10 > ATR 6
      { failed++; Print("SELFTEST FAIL T13 hybrid-structure"); }
   if(!XareStopDistance(1, 2000.0, 1990.0, 10.0, 1.5, XARE_SL_HYBRID, 1.0, sd9) ||
      MathAbs(sd9 - 15.0) > 1e-9)      // ATR 15 > structure 10
      { failed++; Print("SELFTEST FAIL T13 hybrid-atr"); }
   if(!XareStopDistance(1, 2000.0, 1990.0, 4.0, 1.5, XARE_SL_ATR, 1.0, sd9) ||
      MathAbs(sd9 - 6.0) > 1e-9)       // ATR mode ignores structure
      { failed++; Print("SELFTEST FAIL T13 atr-mode"); }
   // structure on the wrong side is ignored (short: 1990 is above... no —
   // below close; not protective) -> falls back to ATR distance
   if(!XareStopDistance(-1, 2000.0, 1990.0, 4.0, 1.5, XARE_SL_HYBRID, 1.0, sd9) ||
      MathAbs(sd9 - 6.0) > 1e-9)
      { failed++; Print("SELFTEST FAIL T13 struct-side"); }
   // no basis for a stop at all -> refuse, never fabricate a distance
   if(XareStopDistance(1, 2000.0, 0.0, 0.0, 0.0, XARE_SL_ATR, 25.0, sd9))
      { failed++; Print("SELFTEST FAIL T13 no-basis-refused"); }

   // TP distances (§21)
   double td9;
   if(!XareTpDistance(XARE_TP_FIXED_R, 30.0, 4.0, 2.0, 3.0, td9) || MathAbs(td9 - 60.0) > 1e-9)
      { failed++; Print("SELFTEST FAIL T13 tp-fixed-r"); }
   if(!XareTpDistance(XARE_TP_ATR_MULT, 30.0, 4.0, 2.0, 3.0, td9) || MathAbs(td9 - 12.0) > 1e-9)
      { failed++; Print("SELFTEST FAIL T13 tp-atr"); }
   if(XareTpDistance(XARE_TP_FIXED_R, 0.0, 4.0, 2.0, 3.0, td9))
      { failed++; Print("SELFTEST FAIL T13 tp-zero-sl"); }

   // cooldown = bar_time + N bars x period seconds (§26)
   if(XareCooldownUntil(D'2026.01.05 10:00', 4, 900) != (datetime)(D'2026.01.05 10:00' + 4*900))
      { failed++; Print("SELFTEST FAIL T13 cooldown"); }

   // T14 (M10): pure trade-plan builder — band gate, caps, SL/TP, sizing, --
   // margin budget on synthetic props; no terminal state touched.
   // Fixture math (verified): entry=ask=2000.00, spread 1.00px=100pt.
   // swing_low 1999 => structure 1.00px; ATR 4 x 1.5 = 6.00px wins hybrid.
   // SL dist 6.00px = 600pt; loss/lot = 600 x $1 = $600.
   SXareDecision pd; pd.has_signal=true; pd.direction=1;
                     pd.setup=XARE_SETUP_TREND_PULLBACK; pd.setup_confidence=90;
                     pd.entry_lo=2000; pd.entry_hi=2010; pd.bar_time=0;
                     pd.invalidation="x"; pd.evidence="t"; pd.nt_reason=XARE_NT_NONE;
   SXareSymbolProps pp; pp.symbol="TEST"; pp.digits=2; pp.point=0.01;
                      pp.tick_size=0.01; pp.tick_value=1.0; pp.contract_size=100.0;
                      pp.volume_min=0.01; pp.volume_max=100.0; pp.volume_step=0.01;
                      pp.stops_level=0; pp.freeze_level=0; pp.trade_mode=4; pp.valid=true;
   SXareConfig pc; XareConfigDefaults(pc);
   SXareTradeDecision pl;

   // full pass: score 84 (TRADE band), equity 10000 @ 0.5% = $50 risk,
   // raw volume 50/600 = 0.0833 -> snapped DOWN to 0.08
   XareBuildTradePlan(pd, 84.0, 1999.0, 2000.0, pp, pc, XARE_RISK_NORMAL, 0.5,
                      4.0, 1999.0, 2050.0, 0, 0, 10000.0, 10000.0, 0.0, pl);
   if(!pl.actionable || pl.direction != 1 ||
      MathAbs(pl.volume - 0.08) > 1e-9 ||
      MathAbs(pl.sl_price - 1994.0) > 1e-9 ||        // 2000 - 6.00
      MathAbs(pl.tp_price - 2012.0) > 1e-9 ||        // +2R = +12.00
      MathAbs(pl.planned_r - 2.0) > 1e-9 ||
      MathAbs(pl.risk_money - 50.0) > 1e-9)
      { failed++; Print("SELFTEST FAIL T14 plan-basic"); }

   // band gate: score 65 (CANDIDATE) must not produce a plan
   XareBuildTradePlan(pd, 65.0, 1999.0, 2000.0, pp, pc, XARE_RISK_NORMAL, 0.5,
                      4.0, 1999.0, 2050.0, 0, 0, 10000.0, 10000.0, 0.0, pl);
   if(pl.actionable || pl.block_reason != XARE_BR_NO_TRADE_BAND)
      { failed++; Print("SELFTEST FAIL T14 band-gate"); }

   // position cap: 1 open position with cap 1 must block
   XareBuildTradePlan(pd, 84.0, 1999.0, 2000.0, pp, pc, XARE_RISK_NORMAL, 0.5,
                      4.0, 1999.0, 2050.0, 1, 0, 10000.0, 10000.0, 0.0, pl);
   if(pl.actionable || pl.block_reason != XARE_BR_MAX_POSITIONS)
      { failed++; Print("SELFTEST FAIL T14 position-cap"); }

   // HALTED risk state: zero effective risk must block with reason
   XareBuildTradePlan(pd, 84.0, 1999.0, 2000.0, pp, pc, XARE_RISK_HALTED, 0.0,
                      4.0, 1999.0, 2050.0, 0, 0, 10000.0, 10000.0, 0.0, pl);
   if(pl.actionable || pl.block_reason != XARE_BR_DRAWDOWN_STATE)
      { failed++; Print("SELFTEST FAIL T14 halted-block"); }

   // below-min volume: $50 account @ 0.05% = $0.025 risk -> raw 0.00004
   // -> snaps to 0 -> SKIP, never pad up to minimum (§49)
   XareBuildTradePlan(pd, 84.0, 1999.0, 2000.0, pp, pc, XARE_RISK_NORMAL, 0.05,
                      4.0, 1999.0, 2050.0, 0, 0, 50.0, 50.0, 0.0, pl);
   if(pl.actionable || pl.block_reason != XARE_BR_VOLUME)
      { failed++; Print("SELFTEST FAIL T14 small-account-skip"); }

   // margin budget: $7000/lot x 0.08 = $560 > 50% of free 1000 = 500 -> block
   XareBuildTradePlan(pd, 84.0, 1999.0, 2000.0, pp, pc, XARE_RISK_NORMAL, 0.5,
                      4.0, 1999.0, 2050.0, 0, 0, 10000.0, 1000.0, 7000.0, pl);
   if(pl.actionable || pl.block_reason != XARE_BR_MARGIN)
      { failed++; Print("SELFTEST FAIL T14 margin-budget"); }

   // SL floor: stops_level 100 => min_dist = 1.00px + spread 1.00px = 2.00px;
   // ATR 0.1 x 1.5 = 0.15px and structure 1.00px are both below -> dist 2.00px
   SXareSymbolProps pps = pp; pps.stops_level = 100;
   XareBuildTradePlan(pd, 84.0, 1999.0, 2000.0, pps, pc, XARE_RISK_NORMAL, 0.5,
                      0.1, 1999.0, 2050.0, 0, 0, 10000.0, 10000.0, 0.0, pl);
   if(!pl.actionable || pl.sl_points < 200.0)
      { failed++; Print("SELFTEST FAIL T14 stops-floor"); }

   // T15 (M12): emergency latch + safety gate priority + news window ----
   CXareSafetyEngine saf;
   ENUM_XARE_BLOCK_REASON br15; string bd15;
   SXareSafetyContext sc15;
   sc15.trading_enabled=true; sc15.emergency=false; sc15.halted=false;
   sc15.daily_breach=false; sc15.weekly_breach=false; sc15.cooldown_active=false;
   sc15.exec_fail_streak=false; sc15.spread_points=150; sc15.max_spread_points=350;
   sc15.abnormal_spread_points=600; sc15.news_clear=true; sc15.news_reason="";
   sc15.quotes_ok=true; sc15.data_ok=true; sc15.symbol_trade_full=true;
   sc15.equity=1000; sc15.margin_ok=true;

   // all clear => GO
   if(!saf.Go(sc15, br15, bd15) || br15 != XARE_BR_NONE)
      { failed++; Print("SELFTEST FAIL T15 go"); }

   // emergency outranks everything (§51) — even with every other check green
   saf.ArmEmergency("test emergency");
   if(saf.Go(sc15, br15, bd15) || br15 != XARE_BR_EMERGENCY)
      { failed++; Print("SELFTEST FAIL T15 emergency-priority"); }
   if(!saf.Emergency() || saf.EmergencyReason() != "test emergency")
      { failed++; Print("SELFTEST FAIL T15 emergency-latch"); }

   // gate priority: trading-off beats halted beats daily loss
   CXareSafetyEngine saf2;
   sc15.trading_enabled=false; sc15.halted=true; sc15.daily_breach=true;
   if(saf2.Go(sc15, br15, bd15) || br15 != XARE_BR_TRADING_OFF)
      { failed++; Print("SELFTEST FAIL T15 priority-trading-off"); }
   sc15.trading_enabled=true;
   if(saf2.Go(sc15, br15, bd15) || br15 != XARE_BR_RISK_HALTED)
      { failed++; Print("SELFTEST FAIL T15 priority-halted"); }
   sc15.halted=false;
   if(saf2.Go(sc15, br15, bd15) || br15 != XARE_BR_DAILY_LOSS)
      { failed++; Print("SELFTEST FAIL T15 priority-daily"); }

   // spread gates (§28): entry limit and abnormal condition
   sc15.daily_breach=false;
   sc15.spread_points=400;
   if(saf2.Go(sc15, br15, bd15) || br15 != XARE_BR_SPREAD)
      { failed++; Print("SELFTEST FAIL T15 spread-limit"); }
   sc15.spread_points=700;
   if(saf2.Go(sc15, br15, bd15) || br15 != XARE_BR_SPREAD_ABNORMAL)
      { failed++; Print("SELFTEST FAIL T15 spread-abnormal"); }

   // news blackout math (§14): inclusive window edges
   datetime ev = D'2026.01.05 15:30';
   if(!XareInBlackout(ev - 30*60, ev, 30, 30) ||
      !XareInBlackout(ev + 30*60, ev, 30, 30) ||
      XareInBlackout(ev - 31*60, ev, 30, 30) ||
      XareInBlackout(ev + 31*60, ev, 30, 30) ||
      XareInBlackout(ev, 0, 30, 30))
      { failed++; Print("SELFTEST FAIL T15 news-window"); }

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

   // T11 (M8): weight-sum validator + band classifier edges ----------------
   if(!XareWeightsValid(20,15,15,10,15,10,5,10))  { failed++; Print("SELFTEST FAIL T11 weights-valid"); }
   if(XareWeightsValid(25,15,15,10,15,10,5,10))   { failed++; Print("SELFTEST FAIL T11 weights-reject"); }
   if(XareScoreBand(55, 60,70,80,85) != XARE_BAND_NONE)      { failed++; Print("SELFTEST FAIL T11 band none"); }
   if(XareScoreBand(65, 60,70,80,85) != XARE_BAND_CANDIDATE) { failed++; Print("SELFTEST FAIL T11 band candidate"); }
   if(XareScoreBand(75, 60,70,80,85) != XARE_BAND_TRADE)     { failed++; Print("SELFTEST FAIL T11 band trade"); }
   if(XareScoreBand(90, 60,70,80,85) != XARE_BAND_STRONG)    { failed++; Print("SELFTEST FAIL T11 band strong"); }

   // T12 (M8): pure score engine on the T9 synthetic context ---------------
   SXareDecision d12; d12.has_signal=true; d12.direction=1;
                     d12.setup=XARE_SETUP_TREND_PULLBACK; d12.setup_confidence=100.0;
                     d12.entry_lo=2038; d12.entry_hi=2046; d12.bar_time=0;
                     d12.invalidation="x"; d12.evidence="t"; d12.nt_reason=XARE_NT_NONE;
   CXareScoreEngine scT;
   SXareScore s12;
   // aligned everything: trend 20, mtf 15, structure 10.5 (bull trend, no BOS),
   // momentum 10 (roc .5>0>.25, rsi 55), liquidity 0, volatility 10 (pct 50),
   // session 3.5 (LONDON), setup 10 ⇒ 79 = TRADE band
   if(!scT.Score(d12, ft, mt, stp, lq, XARE_SESS_LONDON, 50.0, s12) ||
      MathAbs(s12.total - 79.0) > 0.01 ||
      XareScoreBand(s12.total, 60,70,80,85) != XARE_BAND_TRADE)
      { failed++; Print("SELFTEST FAIL T12 aligned-score"); }
   // counter-trend setup: trend component drops to 25% ⇒ 64 = CANDIDATE
   SXareDecision d12b = d12; d12b.setup = XARE_SETUP_RANGE_REVERSAL;
   SXareScore s12b;
   scT.Score(d12b, ft, mt, stp, lq, XARE_SESS_LONDON, 50.0, s12b);
   if(MathAbs(s12b.total - 64.0) > 0.01 ||
      XareScoreBand(s12b.total, 60,70,80,85) != XARE_BAND_CANDIDATE)
      { failed++; Print("SELFTEST FAIL T12 counter-trend"); }
   // MIXED alignment zeroes the MTF component ⇒ conflict always costs points
   SXareScore s12c;
   scT.Score(d12, ft, mt_mix, stp, lq, XARE_SESS_LONDON, 50.0, s12c);
   if(s12c.mtf.earned != 0.0 || MathAbs(s12c.total - 64.0) > 0.01)
      { failed++; Print("SELFTEST FAIL T12 mixed-zero-mtf"); }
   // no-signal decision is not scoreable
   SXareDecision d12d = d12; d12d.has_signal = false;
   SXareScore s12d;
   if(scT.Score(d12d, ft, mt, stp, lq, XARE_SESS_LONDON, 50.0, s12d))
      { failed++; Print("SELFTEST FAIL T12 no-signal-not-scored"); }

   if(failed==0) Print("XARE SELF-TEST: PASS (15 groups)");
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
//| M12: which modes may send orders. SIGNAL_ONLY/RESEARCH/SELF_TEST |
//| never send regardless of the trading switch (spec §1/§36/§63).   |
//+------------------------------------------------------------------+
bool ModeAllowsTrading()
  {
   if(!g_cfg.trading_enabled)
      return false;
   return (g_cfg.mode == XARE_MODE_DEMO ||
           g_cfg.mode == XARE_MODE_PRODUCTION ||
           g_cfg.mode == XARE_MODE_BACKTEST);
  }

//+------------------------------------------------------------------+
//| M12: assemble the live safety context and gate the send (§33).   |
//| Returns true only when an order actually went out.               |
//+------------------------------------------------------------------+
bool TrySendPlan(const SXareTradeDecision &plan, const datetime bar_time,
                 const SXareSymbolProps &props, const string regime_label)
  {
   if(!plan.actionable)
      return false;
   if(!ModeAllowsTrading())
      return false;              // signal-only: PLAN line already reported it

   SXareSafetyContext sc;
   sc.trading_enabled   = ModeAllowsTrading();
   sc.emergency         = g_safety.Emergency();
   SXareRiskSnapshot rs = g_risk.Snapshot();
   sc.halted            = (rs.state == XARE_RISK_HALTED);
   sc.daily_breach      = g_risk.DailyLossBreached();
   sc.weekly_breach     = g_risk.WeeklyLossBreached();
   sc.cooldown_active   = rs.cooldown_active;
   sc.exec_fail_streak  = (g_exec.ConsecutiveFailures() >= 3);
   sc.spread_points     = g_md.CurrentSpreadPoints();
   sc.max_spread_points = g_cfg.max_spread_points;
   sc.abnormal_spread_points = g_cfg.abnormal_spread_points;
   string news_why = "";
   sc.news_clear        = g_news.Clear(TimeCurrent(), news_why);
   sc.news_reason       = news_why;
   double bid_s, ask_s;
   sc.quotes_ok         = g_md.Quotes(bid_s, ask_s);
   sc.data_ok           = props.valid;
   sc.symbol_trade_full = (SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE)
                           == SYMBOL_TRADE_MODE_FULL);
   sc.equity            = rs.equity;
   sc.margin_ok         = true;   // plan-level margin budget check already passed

   ENUM_XARE_BLOCK_REASON br;
   string bd;
   if(!g_safety.Go(sc, br, bd))
     {
      g_log.Info("SAFETY", StringFormat("BLOCKED (%s) %s",
                 XareBlockReasonToString(br), bd));
      return false;
     }

   SXareExecutionResult res;
   if(g_exec.Send(plan, bar_time, res))
     {
      g_log.Info("EXEC", StringFormat(
         "FILLED #%I64u %s vol=%.2f fill=%s slippage=%.1fpt",
         res.ticket, plan.direction > 0 ? "BUY" : "SELL", plan.volume,
         DoubleToString(res.fill_price, props.digits), res.slippage_points));
      g_pos.OnOpened(plan, res, bar_time, regime_label);
      g_risk.CountTradeOpened();
      return true;
     }
   g_log.Warn("EXEC", StringFormat("send failed: %s", res.comment));
   return false;
  }

//+------------------------------------------------------------------+
//| M11: manage the open position (pure decisions -> executor).      |
//+------------------------------------------------------------------+
void ManagePosition(const ENUM_XARE_REGIME cur_regime,
                    const int new_signal_direction,
                    const SXareSymbolProps &props, const SXareFeatures &f)
  {
   SXarePosition ctx;
   if(!g_pos.GetContext(ctx))
      return;
   double bid_m, ask_m;
   if(!g_md.Quotes(bid_m, ask_m))
      return;

   // §24: optional close at the daily limit (explicit config only; default off)
   if(g_cfg.close_on_daily_limit && g_risk.DailyLossBreached())
     {
      SXareMgmtOrder mo;
      mo.action       = XARE_MGMT_CLOSE_FULL;
      mo.close_volume = 0.0;
      mo.reason       = "DAILY LIMIT: close_on_daily_limit configured";
      SXareExecutionResult res;
      if(g_exec.ApplyManagement(mo, g_pos.Ticket(), res))
        {
         g_pos.OnManagementApplied(mo.action, mo.reason);
         g_log.Info("MGMT", StringFormat("CLOSE_FULL #%I64u: %s",
                    g_pos.Ticket(), mo.reason));
        }
      else
         g_log.Warn("MGMT", StringFormat("daily-limit close failed: %s", res.comment));
      return;
     }

   SXareMgmtOrder mgmt = g_exit.Evaluate(ctx, bid_m, ask_m, f.atr, props.point,
                                         g_cfg.max_bars_in_trade,
                                         g_cfg.max_hold_minutes,
                                         cur_regime, new_signal_direction, props);
   if(mgmt.action == XARE_MGMT_NONE)
      return;
   SXareExecutionResult res;
   if(g_exec.ApplyManagement(mgmt, g_pos.Ticket(), res))
     {
      g_pos.OnManagementApplied(mgmt.action, mgmt.reason);
      g_log.Info("MGMT", StringFormat("%s on #%I64u: %s",
                 XareMgmtActionToString(mgmt.action), g_pos.Ticket(), mgmt.reason));
     }
   else
      g_log.Warn("MGMT", StringFormat("apply failed: %s", res.comment));
  }

//+------------------------------------------------------------------+
//| M11: detect closes, journal them (§69), feed risk stats (§26).   |
//+------------------------------------------------------------------+
void CheckPositionClosed(const SXareSymbolProps &props)
  {
   SXareExitRecord rec;
   if(!g_pos.CheckClosed(props, rec) || !rec.present)
      return;
   g_log.JournalRow(rec.close_time, rec.ticket,
                    rec.direction, XareSetupToString(rec.setup), rec.regime,
                    rec.score, rec.risk_pct, rec.volume,
                    rec.entry_price, rec.sl_price, rec.tp_price,
                    rec.exit_price, XareExitToString(rec.reason),
                    rec.session, rec.pl_money, rec.r_multiple,
                    rec.bars_in_trade, rec.slippage_points, rec.open_reason);
   g_risk.OnTradeClosed(rec.pl_money, rec.close_time);
   g_perf.OnTradeClosed(rec.r_multiple, rec.pl_money);   // §17/§39 stats
   g_perf.LogSnapshot(&g_log);
  }

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
   SXareMTF mtf;                       // explicit init: Evaluate may not write
   mtf.valid=false; mtf.alignment=XARE_ALIGN_NEUTRAL; mtf.h4=XARE_TF_NEUTRAL;
   mtf.h1=XARE_TF_NEUTRAL; mtf.exec=XARE_TF_NEUTRAL; mtf.evidence=""; mtf.evaluated_at=0;
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
   SXareRegime regime;               // explicit init: Evaluate may not write
   regime.valid=false; regime.regime=XARE_REGIME_UNKNOWN; regime.confidence=0;
   regime.evidence=""; regime.evaluated_at=0;
   if(g_regime.Evaluate(1, f, bar, regime) && regime.valid)
      g_log.Info("REGIME", StringFormat("%s conf=%d | %s",
                  XareRegimeToString(regime.regime), regime.confidence, regime.evidence));

   // --- M5: market structure
   SXareStructure structure;
   structure.valid=false; structure.trend=XARE_STRUCT_NEUTRAL;
   structure.last_swing_high=0; structure.prev_swing_high=0;
   structure.last_swing_low=0; structure.prev_swing_low=0;
   structure.bos_bull=false; structure.bos_bear=false; structure.choch=false;
   structure.zone_count_res=0; structure.zone_count_sup=0;
   structure.evidence=""; structure.evaluated_at=0;
   for(int zi=0; zi<4; zi++){ structure.resistance[zi]=0; structure.support[zi]=0; }
   if(g_struct.Evaluate(1, structure) && structure.valid)
      g_log.Info("STRUCT", structure.evidence);

   // --- M6: session then liquidity (liquidity consumes session H/L)
   SXareSession session;
   session.valid=false; session.session=XARE_SESS_OFF; session.minute_of_day=0;
   session.high=0; session.low=0; session.range=0; session.episode_bars=0;
   session.evidence=""; session.evaluated_at=0;
   if(g_sess.Evaluate(1, session) && session.valid)
     {
      g_log.Info("SESSION", session.evidence);
      g_sess_cache = XareSessionToString(session.session);   // panel cache
     }

   SXareLiquidity liq;
   liq.valid=false; liq.sweep_up=false; liq.sweep_down=false; liq.swept_level=0;
   liq.level_name=""; liq.penetration_atr=0; liq.evidence=""; liq.evaluated_at=0;
   if(g_liq.Evaluate(1, session, f.atr, liq) && liq.valid)
      g_log.Info("LIQ", liq.evidence);

   // --- M8: capture regime for scoring + dashboard ------------------------
   double atr_pct = g_regime.LastATRPercentile();

   // --- M10: protective swing for structural stops -----------------------
   double swing_lo = (structure.valid && structure.last_swing_low  > 0.0)
                     ? structure.last_swing_low  : 0.0;
   double swing_hi = (structure.valid && structure.last_swing_high > 0.0)
                     ? structure.last_swing_high : 0.0;
   // --- M7: signal evaluation on the same closed-bar context ----------
   double prev_roc = 0.0;
   double c_now  = iClose(g_symbol, _Period, 1);
   double c_prev = iClose(g_symbol, _Period, 1 + g_cfg.roc_period);
   if(c_prev > 0 && c_now > 0)
      prev_roc = XareRateOfChange(c_now, c_prev);

   // --- M11: manage any open position FIRST (uses this bar's verdicts) --
   int new_signal_dir = 0;
   SXareDecision decision;
   g_sig.Evaluate(regime, mtf, structure, session, liq, bar, f, prev_roc, decision);
   new_signal_dir = decision.has_signal ? decision.direction : 0;
   g_last_decision = decision;
   g_have_decision = true;
   ManagePosition(regime.regime, new_signal_dir, props, f);
   CheckPositionClosed(props);

   // --- M51: emergency triggers — irreversible, latch and stand down ----
   int open_cnt_now = g_pos.CountOpen();
   if(open_cnt_now > g_cfg.max_concurrent_positions)
      g_safety.ArmEmergency(StringFormat("%d open positions exceeds cap %d",
                            open_cnt_now, g_cfg.max_concurrent_positions));
   if(g_exec.ConsecutiveFailures() >= 5)
      g_safety.ArmEmergency("5+ consecutive execution failures");
   if(g_have_plan && g_last_plan.volume > g_cfg.emergency_max_lot_x1000 / 1000.0 + 1e-9)
      g_safety.ArmEmergency("planned volume exceeded the emergency lot ceiling");

   // --- M8: score the decision (0–100, every component logged) -----------
   bool have_score = false;
   SXareScore score;
   if(decision.has_signal &&
      g_score.Score(decision, f, mtf, structure, liq, session.session, atr_pct, score))
     {
      have_score = true;
      g_last_score  = score;
      g_have_score  = true;
      g_last_regime = regime;
      g_have_regime = true;
      ENUM_XARE_SCORE_BAND band = XareScoreBand(score.total, g_cfg.score_min,
                                                g_cfg.score_candidate,
                                                g_cfg.score_trade,
                                                g_cfg.score_strong);
      string band_s = XareScoreBandToString(band);
      g_log.Info("SCORE", StringFormat(
         "total=%.1f [%s] | trend=%.1f/%.0f mtf=%.1f/%.0f structure=%.1f/%.0f momentum=%.1f/%.0f liquidity=%.1f/%.0f volatility=%.1f/%.0f session=%.1f/%.0f setup=%.1f/%.0f",
         score.total, band_s,
         score.trend.earned, score.trend.max,
         score.mtf.earned, score.mtf.max,
         score.structure.earned, score.structure.max,
         score.momentum.earned, score.momentum.max,
         score.liquidity.earned, score.liquidity.max,
         score.volatility.earned, score.volatility.max,
         score.session.earned, score.session.max,
         score.setup.earned, score.setup.max));

      // signal-only output: the DECISION line for every new M15 candle
      g_log.Info("DECISION", StringFormat(
         "%s %s conf=%.0f score=%.1f [%s] entry[%s..%s] | %s | invalidation: %s",
         decision.direction > 0 ? "BUY" : "SELL",
         XareSetupToString(decision.setup), decision.setup_confidence,
         score.total, band_s,
         DoubleToString(decision.entry_lo, props.digits),
         DoubleToString(decision.entry_hi, props.digits),
         decision.evidence, decision.invalidation));

      // --- M10: build the fully priced trade plan ------------------------
      double bid10 = 0.0, ask10 = 0.0;
      g_md.Quotes(bid10, ask10);
      double eff_risk = g_risk.Ready() ? g_risk.EffectiveRiskPct()
                                       : 0.0;   // no risk anchor = no risk
      SXareRiskSnapshot snap = g_risk.Snapshot();
      SXareTradeDecision plan;
      XareBuildTradePlan(decision, score.total, bid10, ask10, props, g_cfg,
                         snap.state, eff_risk, f.atr, swing_lo, swing_hi,
                         /*open_positions=*/g_pos.CountOpen(),
                         /*trades_today=*/
                         (g_risk.Ready() ? snap.trades_today : 0),
                         AccountInfoDouble(ACCOUNT_EQUITY),
                         AccountInfoDouble(ACCOUNT_MARGIN_FREE),
                         /*margin_per_lot=*/0.0,   // 0 = live OrderCalcMargin
                         plan);
      g_last_plan = plan;
      g_have_plan = true;

      if(plan.actionable)
        {
         // --- M12: safety gate, then send (trading modes only) -----------
         // --- M13: expectancy gate (§17) abstains until sample is ready --
         bool sent = false;
         if(!g_perf.ExpectancyAllows(0))
            g_log.Warn("PERF", "measured expectancy clearly negative — send suppressed (§17)");
         else
            sent = TrySendPlan(plan, f.bar_time, props,
                               XareRegimeToString(regime.regime));
         if(!sent)
            g_log.Info("PLAN", StringFormat(
               "%s vol=%.2f entry=%s SL=%s (%.0fpt) TP=%s (%.0fpt) R=%.2f risk=%.2f%% ($%.2f) | not sent (mode/gate)",
               plan.direction > 0 ? "BUY" : "SELL", plan.volume,
               DoubleToString(plan.entry_price, props.digits),
               DoubleToString(plan.sl_price, props.digits), plan.sl_points,
               DoubleToString(plan.tp_price, props.digits), plan.tp_points,
               plan.planned_r, plan.risk_pct, plan.risk_money));
        }
      else if(plan.block_reason != XARE_BR_NONE)
         g_log.Info("PLAN", StringFormat("BLOCKED (%s) %s",
                    XareBlockReasonToString(plan.block_reason),
                    plan.block_detail));
     }
   else
     {
      // NO_TRADE path — score is not applicable; report the reason instead
      g_log.Info("DECISION", StringFormat(
         "NO_TRADE (%s) | %s",
         XareNoTradeToString(decision.nt_reason), decision.evidence));
     }

   // --- M13: research row for this closed bar (features only, §37) ------
   if(g_res.Ready())
     {
      SXareRiskSnapshot rr = g_risk.Snapshot();
      ENUM_XARE_SCORE_BAND rb = have_score
         ? XareScoreBand(score.total, g_cfg.score_min, g_cfg.score_candidate,
                         g_cfg.score_trade, g_cfg.score_strong)
         : XARE_BAND_NONE;
      g_res.Row(bar, f, atr_pct, regime, mtf, structure, session, liq,
                decision, score, rb, rr, spread,
                PeriodSeconds(_Period) / 60);
     }
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

   // --- M9: risk engine refresh (rollovers, peak, states) --------------
   g_risk.Update();

   // --- M2: new-bar gate + duplicate processing guard -----------------
   if(g_md.IsNewBar())
     {
      ProcessBar();
     }

   // --- dashboard snapshot (live values; analytics still placeholders) -
   double price       = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   int    spread_pts  = g_md.CurrentSpreadPoints();
   int    props_dg    = 5;   // symbol digits for panel formatting
   {
      SXareSymbolProps ptmp;
      g_md.GetProps(ptmp);
      props_dg = ptmp.digits;
   }
   SXareFeatures feat;
   g_ind.Last(feat);   // refresh cache; liveness already shown via regime/score
   string decision_txt = "NO_DECISION";
   if(g_have_decision)
      decision_txt = g_last_decision.has_signal
         ? StringFormat("%s %s", g_last_decision.direction > 0 ? "BUY" : "SELL",
                        XareSetupToString(g_last_decision.setup))
         : StringFormat("NO_TRADE(%s)", XareNoTradeToString(g_last_decision.nt_reason));
   // --- dashboard: assemble the full snapshot (M19) --------------------
   int    open_xare   = g_init_ok ? g_pos.CountOpen() : 0;
   double daily_pl    = 0.0, dd_pct = 0.0, daily_dd_pct = 0.0;
   string risk_s      = "N/A";
   if(g_risk.Ready())
     {
      SXareRiskSnapshot rs = g_risk.Snapshot();
      daily_pl     = rs.daily_pl;
      dd_pct       = rs.current_dd_pct;
      daily_dd_pct = rs.daily_dd_pct;
      risk_s       = XareRiskStateToString(rs.state);
     }
   double ui_score    = 0.0;
   string ui_regime   = "UNKNOWN";
   int    ui_conf     = 0;
   if(g_have_regime)
     {
      ui_regime = XareRegimeToString(g_last_regime.regime);
      ui_conf   = g_last_regime.confidence;
     }
   string ui_components = "-";
   if(g_have_score)
      ui_components = StringFormat(
         "trend %.0f/%.0f  mtf %.0f/%.0f  struct %.0f/%.0f  mom %.0f/%.0f  liq %.0f/%.0f  vol %.0f/%.0f  sess %.0f/%.0f  setup %.0f/%.0f",
         g_last_score.trend.earned, g_last_score.trend.max,
         g_last_score.mtf.earned, g_last_score.mtf.max,
         g_last_score.structure.earned, g_last_score.structure.max,
         g_last_score.momentum.earned, g_last_score.momentum.max,
         g_last_score.liquidity.earned, g_last_score.liquidity.max,
         g_last_score.volatility.earned, g_last_score.volatility.max,
         g_last_score.session.earned, g_last_score.session.max,
         g_last_score.setup.earned, g_last_score.setup.max);

   //--- position detail line (lot / entry / SL / TP from the live terminal)
   string pos_detail = "";
   if(open_xare > 0)
     {
      for(int i = PositionsTotal() - 1; i >= 0 && StringLen(pos_detail) == 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || !PositionSelectByTicket(tk))
            continue;
         if(PositionGetString(POSITION_SYMBOL) != g_symbol ||
            PositionGetInteger(POSITION_MAGIC) != g_cfg.magic)
            continue;
         long   ptype = PositionGetInteger(POSITION_TYPE);
         double pvol  = PositionGetDouble(POSITION_VOLUME);
         double popen = PositionGetDouble(POSITION_PRICE_OPEN);
         double psl   = PositionGetDouble(POSITION_SL);
         double ptp   = PositionGetDouble(POSITION_TP);
         pos_detail = StringFormat("%s %.2f @ %s SL %s TP %s",
                      (ptype == POSITION_TYPE_BUY) ? "BUY" : "SELL", pvol,
                      DoubleToString(popen, props_dg), DoubleToString(psl, props_dg),
                      DoubleToString(ptp, props_dg));
         break;
        }
     }

   //--- session + news for the panel
   string sess_s = g_sess_cache;
   string news_s = g_news.Enabled()
                   ? (g_news.Clear(TimeCurrent(), g_news_ui_why) ? "CLEAR" : "BLACKOUT")
                   : "NO DATA";

   //--- NO-TRADE explanation: machine reason + human hint, always shown when flat-and-waiting
   string notrade = "";
   if(g_have_decision && !g_last_decision.has_signal && open_xare == 0)
     {
      notrade = XareNoTradeToString(g_last_decision.nt_reason);
      switch(g_last_decision.nt_reason)
        {
         case XARE_NT_INSUFFICIENT_DATA:
            notrade += " — history warming up or data gap; idling";
            break;
         case XARE_NT_REGIME_INCOMPATIBLE:
            notrade += " — no setup precondition in this regime";
            break;
         case XARE_NT_REGIME_CONFIDENCE:
            notrade += " — regime confidence below floor";
            break;
                    case XARE_NT_ALIGNMENT_CONFLICT:
            notrade += " — higher timeframes disagree; not forcing a side";
            break;
         case XARE_NT_NO_SETUP_TRIGGER:
            notrade += " — context valid, no setup fired on the last closed bar";
            break;
         case XARE_NT_SETUP_DISABLED:
            notrade += " — setup matched but disabled in inputs";
            break;
         default:
            break;
        }
     }

   CXareDiagnostics::PanelData pd;
   pd.version         = "v0.15.0";
   pd.connected       = (TerminalInfoInteger(TERMINAL_CONNECTED) != 0);
   pd.symbol          = g_symbol;
   pd.timeframe       = g_tf_label;
   pd.candle_time     = (datetime)SeriesInfoInteger(g_symbol, _Period, SERIES_LASTBAR_DATE);
   pd.price           = price;
   pd.digits          = props_dg;
   pd.spread_points   = spread_pts;
   pd.regime          = ui_regime;
   pd.regime_conf     = ui_conf;
   pd.signal          = decision_txt;
   pd.score           = ui_score;
   pd.components      = ui_components;
   pd.risk_state      = risk_s;
   pd.daily_pl        = daily_pl;
   pd.daily_dd_pct    = daily_dd_pct;
   pd.cur_dd_pct      = dd_pct;
   pd.open_positions  = open_xare;
   pd.pos_detail      = pos_detail;
   pd.session         = sess_s;
   pd.news            = news_s;
   pd.trading_allowed = ModeAllowsTrading();
   pd.notrade_reason  = notrade;
   pd.action          = (open_xare > 0) ? "MANAGE POSITION"
                        : (StringLen(notrade) > 0 ? "WAIT — see NO TRADE line"
                                                  : "WAIT FOR SETUP");
   g_ui.Update(pd);
  }
//+------------------------------------------------------------------+
