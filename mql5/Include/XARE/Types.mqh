//+------------------------------------------------------------------+
//| Types.mqh — shared vocabulary for XARE (MQL5)                    |
//| v0.2.0 — M2 adds: SXareBar, SXareSymbolProps, SXareFeatures      |
//+------------------------------------------------------------------+
#ifndef __XARE_TYPES_MQH__
#define __XARE_TYPES_MQH__

//--- one CLOSED bar of market data (spec §5). Never contains forming-bar data.
struct SXareBar
  {
   datetime         time;
   double           open;
   double           high;
   double           low;
   double           close;
   long             tick_volume;
   long             spread;         // bar spread in points (broker-reported)
  };

//--- broker symbol properties captured ONCE at init (spec §6). No assumptions.
struct SXareSymbolProps
  {
   string           symbol;
   int              digits;
   double           point;
   double           tick_size;
   double           tick_value;
   double           contract_size;
   double           volume_min;
   double           volume_max;
   double           volume_step;
   long             stops_level;
   long             freeze_level;
   long             trade_mode;
   bool             valid;          // false ⇒ sizing must refuse to trade
  };

//--- per-timeframe trend label (M3): simple, objective EMA-structure rule
enum ENUM_XARE_TF_LABEL
  {
   XARE_TF_NEUTRAL = 0,
   XARE_TF_BULL,
   XARE_TF_BEAR
  };

//--- feature snapshot for one closed bar (spec §7). Indicators are FEATURES.
struct SXareFeatures
  {
   bool             valid;          // all required features readable
   datetime         bar_time;       // closed bar these features describe
   double           ema_fast;       // EMA 20
   double           ema_mid;        // EMA 50
   double           ema_slow;       // EMA 200
   double           rsi;            // RSI 14
   double           roc;            // Rate of Change 10 (computed, no builtin)
   double           adx;            // ADX 14 main line
   double           di_plus;        // ADX +DI
   double           di_minus;       // ADX -DI
   double           atr;            // ATR 14
  };

//--- operating modes (spec §1). SELF_TEST added for MQL5 self-tests.
enum ENUM_XARE_MODE
  {
   XARE_MODE_RESEARCH    = 0,   // log features only, never trade
   XARE_MODE_SIGNAL_ONLY = 1,   // report entries/SL/TP, never place orders
   XARE_MODE_BACKTEST    = 2,   // full pipeline in Strategy Tester
   XARE_MODE_DEMO        = 3,   // full pipeline on demo account
   XARE_MODE_PRODUCTION  = 4,   // full pipeline on live account (explicit)
   XARE_MODE_SELF_TEST   = 5    // run SelfTest() then halt (Strategy Tester)
  };

//--- market regime (spec §9). Volatility classes are regimes, not flags.
enum ENUM_XARE_REGIME
  {
   XARE_REGIME_UNKNOWN = 0,
   XARE_REGIME_TREND_UP,
   XARE_REGIME_TREND_DOWN,
   XARE_REGIME_RANGE,
   XARE_REGIME_BREAKOUT,
   XARE_REGIME_HIGH_VOLATILITY,
   XARE_REGIME_LOW_VOLATILITY,
   XARE_REGIME_UNSAFE
  };

//--- multi-timeframe alignment (spec §8)
enum ENUM_XARE_ALIGNMENT
  {
   XARE_ALIGN_NEUTRAL = 0,
   XARE_ALIGN_BULLISH,
   XARE_ALIGN_BEARISH,
   XARE_ALIGN_MIXED          // conflicting TFs — never forced into a trade
  };

//--- multi-timeframe context verdict (spec §8)
struct SXareMTF
  {
   bool             valid;          // all TF reads succeeded
   ENUM_XARE_ALIGNMENT alignment;
   ENUM_XARE_TF_LABEL h4;           // macro
   ENUM_XARE_TF_LABEL h1;           // intermediate
   ENUM_XARE_TF_LABEL exec;         // execution TF (= chart TF, e.g. M15)
   string           evidence;
   datetime         evaluated_at;
  };

//--- market-structure trend from swing sequence (spec §10)
enum ENUM_XARE_STRUCT_TREND
  {
   XARE_STRUCT_NEUTRAL = 0,
   XARE_STRUCT_BULLISH,      // higher highs + higher lows
   XARE_STRUCT_BEARISH,      // lower highs + lower lows
   XARE_STRUCT_MIXED         // conflicting swings — no clean structure
  };

//--- structure verdict (spec §10)
struct SXareStructure
  {
   bool             valid;
   ENUM_XARE_STRUCT_TREND trend;
   double           last_swing_high;
   double           prev_swing_high;
   double           last_swing_low;
   double           prev_swing_low;
   bool             bos_bull;       // close above last swing high (this bar)
   bool             bos_bear;       // close below last swing low (this bar)
   bool             choch;          // BOS against prevailing trend
   double           resistance[4];  // top-zone refs (per side, capped)
   double           support[4];
   int              zone_count_res;
   int              zone_count_sup;
   string           evidence;
   datetime         evaluated_at;
  };

//--- broker-time sessions (spec §13); overlap = London ∩ New York (derived)
enum ENUM_XARE_SESSION
  {
   XARE_SESS_OFF = 0,
   XARE_SESS_ASIAN,
   XARE_SESS_LONDON,
   XARE_SESS_NEWYORK,
   XARE_SESS_OVERLAP
  };

//--- session verdict (spec §13)
struct SXareSession
  {
   bool             valid;
   ENUM_XARE_SESSION session;
   int              minute_of_day;  // broker server time (bar time based)
   double           high;           // current session-episode high
   double           low;            // current session-episode low
   double           range;
   int              episode_bars;   // bars in the current episode
   string           evidence;
   datetime         evaluated_at;
  };

//--- liquidity verdict (spec §11): objective price-based events only.
//--- No "smart money" claims — just measurable sweep/false-break mechanics.
struct SXareLiquidity
  {
   bool             valid;
   bool             sweep_up;       // buyside level swept, close reclaimed below
   bool             sweep_down;     // sellside level swept, close reclaimed above
   double           swept_level;
   string           level_name;     // PDH / PDL / SESS_HIGH / SESS_LOW / SWING_*
   double           penetration_atr;// swept depth in ATR units
   string           evidence;
   datetime         evaluated_at;
  };

//--- NO_TRADE reason codes (spec §15: engine must be capable of returning
//--- NO_TRADE; every no-trade must say why)
enum ENUM_XARE_NOTRADE_REASON
  {
   XARE_NT_NONE = 0,
   XARE_NT_INSUFFICIENT_DATA,   // features/verdicts missing or not valid
   XARE_NT_REGIME_INCOMPATIBLE, // regime offers no setup precondition
   XARE_NT_ALIGNMENT_CONFLICT,  // MTF mixed/neutral blocks directional setups
   XARE_NT_REGIME_CONFIDENCE,   // regime confidence below floor
   XARE_NT_NO_SETUP_TRIGGER,    // context valid but no setup fired this bar
   XARE_NT_SETUP_DISABLED       // setup matched but disabled in config
  };

//--- setup types (spec §15)
enum ENUM_XARE_SETUP
  {
   XARE_SETUP_NONE = 0,
   XARE_SETUP_TREND_CONTINUATION,
   XARE_SETUP_TREND_PULLBACK,
   XARE_SETUP_BREAKOUT,
   XARE_SETUP_BREAKOUT_RETEST,
   XARE_SETUP_RANGE_REVERSAL,
   XARE_SETUP_LIQUIDITY_SWEEP_REVERSAL
  };

//--- risk states (spec §25)
enum ENUM_XARE_RISK_STATE
  {
   XARE_RISK_NORMAL = 0,
   XARE_RISK_CAUTION,
   XARE_RISK_REDUCED,
   XARE_RISK_HALTED          // latch: requires EA re-init to clear
  };

//--- exit reasons (spec §22/§30); every exit must map to one of these
enum ENUM_XARE_EXIT_REASON
  {
   XARE_EXIT_NONE = 0,
   XARE_EXIT_HARD_SL,
   XARE_EXIT_TP,
   XARE_EXIT_BREAK_EVEN,
   XARE_EXIT_PARTIAL,
   XARE_EXIT_TRAILING,
   XARE_EXIT_TIME,
   XARE_EXIT_REGIME_FLIP,
   XARE_EXIT_SIGNAL_REVERSAL,
   XARE_EXIT_EMERGENCY
  };

//--- position state machine (spec §30)
enum ENUM_XARE_POS_STATE
  {
   XARE_POS_NONE = 0,
   XARE_POS_ENTRY_PENDING,
   XARE_POS_OPEN,
   XARE_POS_PROTECTED,       // break-even moved
   XARE_POS_PARTIAL_PROFIT,  // partial taken
   XARE_POS_TRAILING,
   XARE_POS_EXIT_PENDING,
   XARE_POS_CLOSED
  };

//--- safety verdict (spec §33)
enum ENUM_XARE_SAFETY_VERDICT
  {
   XARE_SAFETY_GO = 0,
   XARE_SAFETY_BLOCK         // reason string mandatory when blocked
  };

//--- block reasons (spec §33): every refused trade maps to exactly one code.
//--- Order matters only for readability; always pair with a detail string.
enum ENUM_XARE_BLOCK_REASON
  {
   XARE_BR_NONE = 0,
   XARE_BR_TRADING_OFF,          // global switch / mode never trades
   XARE_BR_RISK_HALTED,          // drawdown/streak halt latch
   XARE_BR_EMERGENCY,            // emergency shutdown latch
   XARE_BR_DAILY_LOSS,           // daily loss limit reached
   XARE_BR_WEEKLY_LOSS,          // weekly loss limit reached
   XARE_BR_DRAWDOWN_STATE,       // risk state REDUCED/HALTED via DD
   XARE_BR_COOLDOWN_LOSSES,      // consecutive-loss cooldown active
   XARE_BR_MAX_TRADES_DAY,       // daily trade-count cap
   XARE_BR_MAX_POSITIONS,        // concurrent-position cap
   XARE_BR_SPREAD,               // spread above entry limit
   XARE_BR_SPREAD_ABNORMAL,      // abnormal spread condition
   XARE_BR_NEWS,                 // news blackout (only with real data)
   XARE_BR_NO_QUOTES,            // bid/ask unavailable or invalid
   XARE_BR_SYMBOL_STATE,         // symbol trade mode disabled/restricted
   XARE_BR_MARGIN,               // margin required exceeds safe budget
   XARE_BR_STOPS_LEVEL,          // SL/TP inside broker stops/freeze zone
   XARE_BR_VOLUME,               // volume invalid / below min / above cap
   XARE_BR_NO_TRADE_BAND,        // score below trade band
   XARE_BR_EXEC_FAILURE,         // execution failure streak latch
   XARE_BR_DATA_STALE,           // market data staleness beyond tolerance
   XARE_BR_SL_INVALID,           // no acceptable hard SL could be built
   XARE_BR_TP_INVALID            // no acceptable TP could be built
  };

//--- stop-loss / take-profit construction policies (spec §20/§21)
enum ENUM_XARE_SL_MODE
  {
   XARE_SL_ATR = 0,        // ATR × multiplier
   XARE_SL_STRUCTURE,      // structural swing level
   XARE_SL_HYBRID          // max(structural, ATR) — conservative default
  };

enum ENUM_XARE_TP_MODE
  {
   XARE_TP_FIXED_R = 0,    // SL distance × R multiple
   XARE_TP_ATR_MULT        // ATR × multiple
  };

//--- score bands (spec §16); thresholds are configurable hypotheses
enum ENUM_XARE_SCORE_BAND
  {
   XARE_BAND_NONE = 0,       // below minimum — no trade
   XARE_BAND_CANDIDATE,      // acceptable
   XARE_BAND_TRADE,          // trade candidate
   XARE_BAND_STRONG          // high-quality candidate
  };

//--- per-component score contribution (spec §16); weights are hypotheses
struct SXareScoreComponent
  {
   double           earned;
   double           max;
   string           note;
  };

//--- full score breakdown; always log every component
struct SXareScore
  {
   double           total;          // 0..100 (clamped)
   SXareScoreComponent trend;       // max = cfg weight
   SXareScoreComponent mtf;
   SXareScoreComponent structure;
   SXareScoreComponent momentum;
   SXareScoreComponent liquidity;
   SXareScoreComponent volatility;
   SXareScoreComponent session;
   SXareScoreComponent setup;
  };

//--- regime verdict: label + confidence + evidence (never a probability)
struct SXareRegime
  {
   bool             valid;          // evaluation succeeded
   ENUM_XARE_REGIME regime;
   int              confidence;     // 0..100 score, not probability
   string           evidence;
   datetime         evaluated_at;
  };

//--- final decision object (spec §15/§16): everything needed to explain
//--- a bar's verdict — trade candidate or NO_TRADE with reason + breakdown
struct SXareDecision
  {
   bool             has_signal;         // false = NO_TRADE
   ENUM_XARE_NOTRADE_REASON nt_reason;  // why not (when has_signal=false)
   int              direction;          // +1 buy, -1 sell, 0 flat
   ENUM_XARE_SETUP  setup;
   double           setup_confidence;
   double           entry_lo;           // entry zone (price)
   double           entry_hi;
   string           invalidation;       // what cancels the idea
   string           evidence;           // combined supporting evidence
   datetime         bar_time;
  };

//--- a candidate setup produced by the SignalEngine (spec §15)
struct SXareSignal
  {
   bool             valid;          // false = NO_TRADE
   ENUM_XARE_SETUP  setup;
   int              direction;      // +1 buy, -1 sell
   double           confidence;     // 0..100
   double           entry_zone_lo;
   double           entry_zone_hi;
   string           invalidation;   // what cancels this idea
   string           evidence;
   datetime         bar_time;       // signal bar (closed bar time)
  };

//--- a fully-priced trade decision handed to execution (spec §18-21).
//--- actionable=false is a valid outcome: block_reason says why (§33).
struct SXareTradeDecision
  {
   bool             actionable;
   ENUM_XARE_BLOCK_REASON block_reason;   // when not actionable
   string           block_detail;
   int              direction;      // +1 buy, -1 sell
   double           entry_price;    // expected entry (bid/ask at decision)
   double           sl_price;
   double           tp_price;
   double           volume;         // broker-normalized lots
   double           risk_pct;       // effective risk % (may be reduced state)
   double           risk_money;     // equity × effective risk %
   double           sl_points;      // SL distance in points
   double           tp_points;      // TP distance in points
   double           planned_r;      // tp_points / sl_points
   double           score;
   ENUM_XARE_SETUP  setup;
   string           session;
   string           reason;         // human-readable trade reason (spec §69)
  };

//--- execution result record (spec §29)
struct SXareExecutionResult
  {
   bool             success;
   ulong            ticket;
   double           fill_price;
   double           requested_price;
   double           slippage_points;
   uint             retcode;
   string           comment;
  };

//--- risk-engine snapshot for logs + dashboard (spec §24/§25)
struct SXareRiskSnapshot
  {
   bool             ready;
   ENUM_XARE_RISK_STATE state;
   double           equity;
   double           peak_equity;
   double           day_start_equity;
   double           daily_pl;        // equity − day_start (incl. floating)
   double           daily_dd_pct;    // loss below day start, %
   double           weekly_dd_pct;
   double           current_dd_pct;  // from peak, %
   int              trades_today;
   int              consecutive_losses;
   bool             cooldown_active;
   datetime         cooldown_until;
  };

//--- open position context kept by the PositionManager
struct SXarePosition
  {
   ENUM_XARE_POS_STATE state;
   ulong            ticket;
   int              direction;
   double           volume_initial;
   double           volume_current;
   double           entry_price;
   double           sl_price;
   double           tp_price;
   double           risk_pct_at_entry;
   double           score_at_entry;
   ENUM_XARE_SETUP  setup;
   string           session;
   string           regime;         // regime label at entry (journal context)
   string           open_reason;
   datetime         open_time;
   datetime         open_bar_time;
   int              bars_in_trade;
   bool             be_done;
   bool             partial_done;
  };

//--- convenience: regime/score/state to short strings for logs + panel
string XareRegimeToString(const ENUM_XARE_REGIME r)
  {
   switch(r)
     {
      case XARE_REGIME_TREND_UP:       return "TREND_UP";
      case XARE_REGIME_TREND_DOWN:     return "TREND_DOWN";
      case XARE_REGIME_RANGE:          return "RANGE";
      case XARE_REGIME_BREAKOUT:       return "BREAKOUT";
      case XARE_REGIME_HIGH_VOLATILITY:return "HIGH_VOLATILITY";
      case XARE_REGIME_LOW_VOLATILITY: return "LOW_VOLATILITY";
      case XARE_REGIME_UNSAFE:         return "UNSAFE";
      default:                         return "UNKNOWN";
     }
  }

string XareSetupToString(const ENUM_XARE_SETUP s)
  {
   switch(s)
     {
      case XARE_SETUP_TREND_CONTINUATION:       return "TREND_CONTINUATION";
      case XARE_SETUP_TREND_PULLBACK:           return "TREND_PULLBACK";
      case XARE_SETUP_BREAKOUT:                 return "BREAKOUT";
      case XARE_SETUP_BREAKOUT_RETEST:          return "BREAKOUT_RETEST";
      case XARE_SETUP_RANGE_REVERSAL:           return "RANGE_REVERSAL";
      case XARE_SETUP_LIQUIDITY_SWEEP_REVERSAL: return "LIQ_SWEEP_REVERSAL";
      default:                                  return "NONE";
     }
  }

string XareRiskStateToString(const ENUM_XARE_RISK_STATE s)
  {
   switch(s)
     {
      case XARE_RISK_NORMAL:  return "NORMAL";
      case XARE_RISK_CAUTION: return "CAUTION";
      case XARE_RISK_REDUCED: return "REDUCED_RISK";
      case XARE_RISK_HALTED:  return "HALTED";
      default:                return "NORMAL";
     }
  }

string XareModeToString(const ENUM_XARE_MODE m)
  {
   switch(m)
     {
      case XARE_MODE_RESEARCH:    return "RESEARCH";
      case XARE_MODE_SIGNAL_ONLY: return "SIGNAL_ONLY";
      case XARE_MODE_BACKTEST:    return "BACKTEST";
      case XARE_MODE_DEMO:        return "DEMO";
      case XARE_MODE_PRODUCTION:  return "PRODUCTION";
      case XARE_MODE_SELF_TEST:   return "SELF_TEST";
      default:                    return "UNKNOWN";
     }
  }

string XareExitToString(const ENUM_XARE_EXIT_REASON r)
  {
   switch(r)
     {
      case XARE_EXIT_HARD_SL:         return "HARD_SL";
      case XARE_EXIT_TP:              return "TP";
      case XARE_EXIT_BREAK_EVEN:      return "BREAK_EVEN";
      case XARE_EXIT_PARTIAL:         return "PARTIAL";
      case XARE_EXIT_TRAILING:        return "TRAILING_STOP";
      case XARE_EXIT_TIME:            return "TIME";
      case XARE_EXIT_REGIME_FLIP:     return "REGIME_FLIP";
      case XARE_EXIT_SIGNAL_REVERSAL: return "SIGNAL_REVERSAL";
      case XARE_EXIT_EMERGENCY:       return "EMERGENCY";
      default:                        return "NONE";
     }
  }

string XareBlockReasonToString(const ENUM_XARE_BLOCK_REASON r)
  {
   switch(r)
     {
      case XARE_BR_TRADING_OFF:       return "TRADING_OFF";
      case XARE_BR_RISK_HALTED:       return "RISK_HALTED";
      case XARE_BR_EMERGENCY:         return "EMERGENCY";
      case XARE_BR_DAILY_LOSS:        return "DAILY_LOSS";
      case XARE_BR_WEEKLY_LOSS:       return "WEEKLY_LOSS";
      case XARE_BR_DRAWDOWN_STATE:    return "DRAWDOWN_STATE";
      case XARE_BR_COOLDOWN_LOSSES:   return "COOLDOWN_LOSSES";
      case XARE_BR_MAX_TRADES_DAY:    return "MAX_TRADES_DAY";
      case XARE_BR_MAX_POSITIONS:     return "MAX_POSITIONS";
      case XARE_BR_SPREAD:            return "SPREAD";
      case XARE_BR_SPREAD_ABNORMAL:   return "SPREAD_ABNORMAL";
      case XARE_BR_NEWS:              return "NEWS";
      case XARE_BR_NO_QUOTES:         return "NO_QUOTES";
      case XARE_BR_SYMBOL_STATE:      return "SYMBOL_STATE";
      case XARE_BR_MARGIN:            return "MARGIN";
      case XARE_BR_STOPS_LEVEL:       return "STOPS_LEVEL";
      case XARE_BR_VOLUME:            return "VOLUME";
      case XARE_BR_NO_TRADE_BAND:     return "NO_TRADE_BAND";
      case XARE_BR_EXEC_FAILURE:      return "EXEC_FAILURE";
      case XARE_BR_DATA_STALE:        return "DATA_STALE";
      case XARE_BR_SL_INVALID:        return "SL_INVALID";
      case XARE_BR_TP_INVALID:        return "TP_INVALID";
      default:                        return "NONE";
     }
  }

string XareNoTradeToString(const ENUM_XARE_NOTRADE_REASON r)
  {
   switch(r)
     {
      case XARE_NT_INSUFFICIENT_DATA:   return "INSUFFICIENT_DATA";
      case XARE_NT_REGIME_INCOMPATIBLE: return "REGIME_INCOMPATIBLE";
      case XARE_NT_ALIGNMENT_CONFLICT:  return "ALIGNMENT_CONFLICT";
      case XARE_NT_REGIME_CONFIDENCE:   return "REGIME_CONFIDENCE";
      case XARE_NT_NO_SETUP_TRIGGER:    return "NO_SETUP_TRIGGER";
      case XARE_NT_SETUP_DISABLED:      return "SETUP_DISABLED";
      default:                          return "NONE";
     }
  }

string XareAlignmentToString(const ENUM_XARE_ALIGNMENT a)
  {
   switch(a)
     {
      case XARE_ALIGN_BULLISH: return "BULLISH";
      case XARE_ALIGN_BEARISH: return "BEARISH";
      case XARE_ALIGN_MIXED:   return "MIXED";
      default:                 return "NEUTRAL";
     }
  }

string XareStructTrendToString(const ENUM_XARE_STRUCT_TREND t)
  {
   switch(t)
     {
      case XARE_STRUCT_BULLISH: return "BULLISH";
      case XARE_STRUCT_BEARISH: return "BEARISH";
      case XARE_STRUCT_MIXED:   return "MIXED";
      default:                  return "NEUTRAL";
     }
  }

string XareSessionToString(const ENUM_XARE_SESSION s)
  {
   switch(s)
     {
      case XARE_SESS_ASIAN:   return "ASIAN";
      case XARE_SESS_LONDON:  return "LONDON";
      case XARE_SESS_NEWYORK: return "NEWYORK";
      case XARE_SESS_OVERLAP: return "OVERLAP";
      default:                return "OFF";
     }
  }

string XareScoreBandToString(const ENUM_XARE_SCORE_BAND b)
  {
   switch(b)
     {
      case XARE_BAND_CANDIDATE: return "CANDIDATE";
      case XARE_BAND_TRADE:     return "TRADE";
      case XARE_BAND_STRONG:    return "STRONG";
      default:                  return "NONE";
     }
  }

#endif // __XARE_TYPES_MQH__
