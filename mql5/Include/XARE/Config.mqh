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

   // SL/TP construction (§20/§21). Modes are hypotheses.
   ENUM_XARE_SL_MODE sl_mode;           // hybrid default: max(structure, ATR)
   double           sl_atr_mult;        // ATR multiplier for ATR/hybrid SL
   ENUM_XARE_TP_MODE tp_mode;           // fixed-R default
   double           tp_r_multiple;      // TP = SL distance × this
   double           tp_atr_mult;        // TP when tp_mode=ATR_MULT

   // Risk (§18/§19/§24/§25/§26/§27/§50). All defaults preserve capital.
   double           risk_per_trade_pct;     // % equity risked per trade
   double           risk_floor_pct;         // never risk below this (skip instead)
   double           daily_loss_limit_pct;   // % equity: stop opening trades
   double           weekly_loss_limit_pct;
   double           dd_caution_pct;         // peak-DD states (§25)
   double           dd_reduced_pct;
   double           dd_halt_pct;
   int              max_consecutive_losses; // streak cooldown trigger
   int              cooldown_bars;          // pause length in bars
   int              max_trades_per_day;
   int              max_concurrent_positions;
   bool             close_on_daily_limit;   // §24: default NO (stop opening only)
   double           risk_mult_caution;      // risk scale in CAUTION state (<=1)
   double           risk_mult_reduced;      // risk scale in REDUCED state (<=1)
   double           risk_mult_defensive;    // risk scale in DEFENSIVE state (<=1)
   ENUM_TIMEFRAMES  working_tf;             // bar-time anchor for cooldowns

   // Execution (§29) + small-account guard (§49)
   long             emergency_max_lot_x1000; // hard volume ceiling ×1000 (lots)
   double           max_margin_pct;          // refuse if margin > this % of free
   bool             allow_min_lot_override;  // §49 high-risk override; default OFF

   // Position management (§22/§23). Triggers in R of the actual SL distance.
   double           be_trigger_r;       // move SL to BE at this R
   double           be_lock_points;     // BE lock beyond entry (points)
   double           trail_trigger_r;    // start trailing at this R
   double           trail_atr_mult;     // trail distance = ATR × this
   double           partial_trigger_r;  // take partial at this R
   double           partial_close_pct;  // % of volume closed at partial
   int              max_bars_in_trade;  // §23: hard bar-based exit
   int              max_hold_minutes;   // §23: minute-based exit (0 = off)

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
   int              expectancy_min_trades;// §17: gate disabled below this sample
   double           expectancy_block_r;   // §17: block when expR <= -this AND pf<1

   // === v0.17.0 hardening (§2-§22) — all defaults OFF or risk-REDUCING ===

   // Adaptive risk (§6): product of bounded factors, each clamped
   // [factor_min, 1.0] — risk can only shrink or stay. No factor can raise it.
   double           factor_min;           // hard lower bound per factor

   // Account survival (§10): DEFENSIVE state inputs
   int              max_consec_losing_days;  // losing days -> DEFENSIVE (0=off)
   double           min_margin_level_pct;    // margin level floor (0=off)

   // Profit lock / capital floor (§9): optional, OFF by default, UNVALIDATED
   bool             profit_lock_enabled;
   double           lock_milestone_pct;      // equity gain% that arms a floor
   double           lock_floor_pct;          // % of the gain protected

   // Capital stages (§8): research labels; stage factor only reduces risk
   bool             stages_enabled;
   double           stage_micro_max_equity;      // < 500
   double           stage_growth_max_equity;     // < 5000
   double           stage_standard_max_equity;   // < 50000

   // Weekend/Friday (§15): broker server time
   int              friday_cutoff_min;    // minutes from midnight; final entry
                                         // must START before this (default 1200 = 20:00)
   bool             friday_close_all;     // §15 optional close-all at cutoff

   // Cooldown suite (§12): additive to the existing streak cooldown
   int              post_sl_cooldown_bars;    // after any closed SL loser
   double           slip_cooldown_points;     // abnormal slippage trigger
   int              slip_cooldown_bars;       // pause length after it
   int              max_trades_per_session;

   // News (§14): native MT5 calendar when available, CSV fallback
   ENUM_XARE_NEWS_SOURCE news_source;

   // Breakout hardening (§2): ATR-normalized strength bands (hypotheses)
   double           breakout_body_min_pct;   // body >= % of bar range
   double           breakout_strong_atr;     // beyond >= this (ATR) => strong band

   // Startup health (§21)
   bool             health_check_enabled;    // BLOCKED blocks sends (not signals)
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

   // SL/TP: hybrid SL, fixed-R TP — all hypotheses (docs/parameters.md)
   c.sl_mode                 = XARE_SL_HYBRID;
   c.sl_atr_mult             = 1.5;
   c.tp_mode                 = XARE_TP_FIXED_R;
   c.tp_r_multiple           = 2.0;
   c.tp_atr_mult             = 3.0;

   // Risk: capital-preservation defaults (docs/parameters.md)
   c.risk_per_trade_pct      = 0.5;
   c.risk_floor_pct          = 0.10;   // below 0.10% ⇒ skip, never oversized
   c.daily_loss_limit_pct    = 2.0;
   c.weekly_loss_limit_pct   = 5.0;
   c.dd_caution_pct          = 5.0;
   c.dd_reduced_pct          = 10.0;
   c.dd_halt_pct             = 15.0;
   c.max_consecutive_losses  = 3;
   c.cooldown_bars           = 4;
   c.max_trades_per_day      = 3;
   c.max_concurrent_positions= 1;      // §32: one position per symbol (v1)
   c.close_on_daily_limit    = false;  // §24 default: stop opening, keep managing
   c.risk_mult_caution       = 0.5;    // only downward, never up (§31)
   c.risk_mult_reduced       = 0.25;
   c.risk_mult_defensive     = 0.5;    // §10 DEFENSIVE state scale
   c.working_tf              = PERIOD_M15;  // EA overrides with chart period

   // Execution: hard ceilings (docs/parameters.md)
   c.emergency_max_lot_x1000 = 500;    // 0.50 lots hard cap
   c.max_margin_pct          = 50.0;   // refuse if required margin > 50% of free
   c.allow_min_lot_override  = false;  // §49: default SAFE

   // Position management: conservative hypotheses (docs/parameters.md)
   c.be_trigger_r            = 1.0;    // BE after 1R of favorable movement
   c.be_lock_points          = 50;     // lock $0.50/oz-equivalent beyond entry
   c.trail_trigger_r         = 1.0;
   c.trail_atr_mult          = 2.0;
   c.partial_trigger_r       = 1.5;
   c.partial_close_pct       = 50.0;
   c.max_bars_in_trade       = 48;     // 12h on M15 — no indefinite holds (§23)
   c.max_hold_minutes        = 0;      // minutes-based exit disabled by default

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
   c.expectancy_min_trades  = 30;     // §17: abstain (never block) below this
   c.expectancy_block_r     = 0.10;   // clearly-negative threshold

   // --- v0.17.0 hardening defaults: every addition is OFF or risk-reducing
   c.factor_min             = 0.5;    // per-factor hard floor (§6)

   c.max_consec_losing_days = 2;      // §10: 2 losing days -> DEFENSIVE
   c.min_margin_level_pct   = 200.0;  // §10: margin level floor (%); 0=off

   c.profit_lock_enabled    = false;  // §9: OFF until walk-forward validates
   c.lock_milestone_pct     = 10.0;   // +10% equity arms a floor
   c.lock_floor_pct         = 50.0;   // protect 50% of the gain

   c.stages_enabled         = true;   // §8: labels + reduce-only risk factor
   c.stage_micro_max_equity = 500.0;
   c.stage_growth_max_equity= 5000.0;
   c.stage_standard_max_equity = 50000.0;

   c.friday_cutoff_min      = 1200;   // §15: 20:00 server = final entry start
   c.friday_close_all       = false;  // §15: optional close-all (OFF)

   c.post_sl_cooldown_bars  = 4;      // §12: pause after any SL loser
   c.slip_cooldown_points   = 150.0;  // §12: abnormal slippage trigger (pt)
   c.slip_cooldown_bars     = 4;
   c.max_trades_per_session = 2;

   c.news_source            = XARE_NEWS_CALENDAR_IF_AVAILABLE; // §14

   c.breakout_body_min_pct  = 50.0;   // §2: body must be >= 50% of range
   c.breakout_strong_atr    = 0.5;    // §2: beyond >= 0.5 ATR => strong band

   c.health_check_enabled   = true;   // §21: BLOCKED blocks sends (not signals)
  }

#endif // __XARE_CONFIG_MQH__
