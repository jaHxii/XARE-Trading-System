//+------------------------------------------------------------------+
//| Config.mqh — all XARE parameters in one place (spec §62)          |
//| v0.2.0 — M2 adds: indicator periods + feature/MTF bar counts.     |
//| NOTE: MQL5 has no `input struct`; inputs are declared in XARE.mq5 |
//| and copied into this struct once at init (single source of truth).|
//+------------------------------------------------------------------+
#ifndef __XARE_CONFIG_MQH__
#define __XARE_CONFIG_MQH__

#include "Types.mqh"

//--- resolved, immutable-after-init configuration
struct SXareConfig
  {
   // General (spec §62: General)
   ENUM_XARE_MODE   mode;
   bool             trading_enabled;      // global risk switch (§18)
   long             magic;
   string           order_comment;
   bool             dashboard_enabled;

   // Market Data (§5, §28)
   bool             use_closed_bars_only;
   int              max_spread_points;        // block entries above
   int              abnormal_spread_points;   // abnormal condition gate
   int              max_bars_without_data;    // staleness tolerance

   // Indicators (§7). Periods are hypotheses; documented in parameters.md.
   int              ema_fast_period;     // 20
   int              ema_mid_period;      // 50
   int              ema_slow_period;     // 200
   int              rsi_period;          // 14
   int              roc_period;          // 10 (computed manually)
   int              adx_period;          // 14
   int              atr_period;          // 14
   int              history_bars_min;    // required closed bars before engine runs

   // Regime (§9). Thresholds are hypotheses; see docs/parameters.md.
   int              trend_adx_min;       // ADX above ⇒ trend-capable
   int              high_vol_atr_pct;    // ATR percentile above ⇒ HIGH_VOLATILITY
   int              low_vol_atr_pct;     // ATR percentile below ⇒ LOW_VOLATILITY
   int              breakout_range_lookback; // bars defining pre-breakout range
   int              regime_conf_min;     // below ⇒ UNKNOWN (no-trend evidence)

   // Structure (§10). A pivot is KNOWN only after pivot_confirm closed bars
   // past it — see StructureEngine.mqh header for the exact rule.
   int              pivot_lookback;      // bars each side of a pivot
   int              pivot_confirm;       // closed bars after pivot before it counts
   int              structure_max_zones; // S/R levels kept per side

   // Sessions (§13): broker SERVER time minutes-from-midnight. Verify the
   // broker offset before trusting these (scripts/check_broker_time.py idea).
   int              sess_asian_start;    // 0:00
   int              sess_asian_end;      // 8:00
   int              sess_london_start;   // 7:00
   int              sess_london_end;     // 16:00
   int              sess_ny_start;       // 12:30
   int              sess_ny_end;         // 21:00

   // Liquidity (§11)
   double           sweep_atr_multiple;  // penetration depth >= this ⇒ sweep
   int              sweep_reclaim_bars;  // close back within N bars ⇒ confirmed
   int              swing_liquidity_lookback; // bars scanned for swing extremes

   // Signals (§15). All thresholds are hypotheses (docs/parameters.md).
   bool             setup_trend_continuation;   // enable flags (§15)
   bool             setup_trend_pullback;
   bool             setup_breakout;
   bool             setup_breakout_retest;
   bool             setup_range_reversal;
   bool             setup_liquidity_sweep_reversal;
   double           pullback_ema_zone_atr; // pullback zone half-width in ATR
   double           min_setup_confidence;  // setup-level floor (0..100)
   int              retest_valid_bars;     // break must be recent to retest

   // Scoring (§16). Weights are INITIAL HYPOTHESES (sum 100), docs/parameters.md.
   double           w_trend;             // 20
   double           w_mtf;               // 15
   double           w_structure;         // 15
   double           w_momentum;          // 10
   double           w_liquidity;         // 15
   double           w_volatility;        // 10
   double           w_session;           // 5
   double           w_setup;             // 10
   double           score_min;           // below ⇒ no trade
   double           score_candidate;     // candidate band from
   double           score_trade;         // trade band from
   double           score_strong;        // strong band from

   // Logging / Research (§34, §37)
   int              log_level;            // 0=DEBUG 1=INFO 2=WARN 3=ERROR
   bool             research_csv_enabled; // RESEARCH mode feature rows
   bool             journal_csv_enabled;  // trade journal (§69)
   string           journal_dir;          // under MQL5\Files
  };

//--- defaults: safety-first (spec §63). Values are hypotheses (docs/parameters.md)
void XareConfigDefaults(SXareConfig &c)
  {
   c.mode                   = XARE_MODE_SIGNAL_ONLY;   // never default to trading
   c.trading_enabled        = false;
   c.magic                  = 860001;
   c.order_comment          = "XARE";
   c.dashboard_enabled      = true;

   c.use_closed_bars_only   = true;
   c.max_spread_points      = 350;    // XAUUSDm typical ≈100–200pt — MEASURE, don't trust
   c.abnormal_spread_points = 600;
   c.max_bars_without_data  = 3;

   // Indicator periods: initial hypotheses (docs/parameters.md)
   c.ema_fast_period        = 20;
   c.ema_mid_period         = 50;
   c.ema_slow_period        = 200;
   c.rsi_period             = 14;
   c.roc_period             = 10;
   c.adx_period             = 14;
   c.atr_period             = 14;
   c.history_bars_min       = 260;    // EMA200 + margin

   // Regime thresholds: initial hypotheses (docs/parameters.md)
   c.trend_adx_min          = 22;
   c.high_vol_atr_pct       = 80;
   c.low_vol_atr_pct        = 20;
   c.breakout_range_lookback= 20;
   c.regime_conf_min        = 55;

   // Structure: initial hypotheses (docs/parameters.md)
   c.pivot_lookback         = 3;
   c.pivot_confirm          = 2;
   c.structure_max_zones    = 4;

   // Sessions in broker server time (minutes); hypotheses pending offset check
   c.sess_asian_start       = 0;     // 00:00
   c.sess_asian_end         = 480;   // 08:00
   c.sess_london_start      = 420;   // 07:00
   c.sess_london_end        = 960;   // 16:00
   c.sess_ny_start          = 750;   // 12:30
   c.sess_ny_end            = 1260;  // 21:00

   // Liquidity: initial hypotheses (docs/parameters.md)
   c.sweep_atr_multiple     = 0.25;
   c.sweep_reclaim_bars     = 3;
   c.swing_liquidity_lookback = 40;

   // Signals: all six enabled; thresholds are hypotheses
   c.setup_trend_continuation = true;
   c.setup_trend_pullback     = true;
   c.setup_breakout           = true;
   c.setup_breakout_retest    = true;
   c.setup_range_reversal     = true;
   c.setup_liquidity_sweep_reversal = true;
   c.pullback_ema_zone_atr    = 1.2;
   c.min_setup_confidence     = 55.0;
   c.retest_valid_bars        = 8;

   // Scoring weights + bands: hypotheses (docs/parameters.md)
   c.w_trend                 = 20.0;
   c.w_mtf                   = 15.0;
   c.w_structure             = 15.0;
   c.w_momentum              = 10.0;
   c.w_liquidity             = 15.0;
   c.w_volatility            = 10.0;
   c.w_session               = 5.0;
   c.w_setup                 = 10.0;
   c.score_min               = 60.0;
   c.score_candidate         = 70.0;
   c.score_trade             = 80.0;
   c.score_strong            = 85.0;

   c.log_level              = 1;      // INFO
   c.research_csv_enabled   = false;  // enabled by RESEARCH mode itself
   c.journal_csv_enabled    = true;
   c.journal_dir            = "XARE";
  }

#endif // __XARE_CONFIG_MQH__
