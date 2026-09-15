//+------------------------------------------------------------------+
//| Types.mqh — shared vocabulary for XARE (MQL5)                    |
//| v0.1.0 — M1: types needed by skeleton; extended in later builds  |
//+------------------------------------------------------------------+
#ifndef __XARE_TYPES_MQH__
#define __XARE_TYPES_MQH__

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
   ENUM_XARE_REGIME regime;
   int              confidence;     // 0..100 score, not probability
   string           evidence;
   datetime         evaluated_at;
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

//--- a fully-priced trade decision handed to execution (spec §18-21)
struct SXareTradeDecision
  {
   bool             actionable;
   int              direction;      // +1 buy, -1 sell
   double           entry_price;    // expected entry (bid/ask at decision)
   double           sl_price;
   double           tp_price;
   double           volume;         // broker-normalized lots
   double           risk_pct;       // effective risk % (may be reduced state)
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

#endif // __XARE_TYPES_MQH__
