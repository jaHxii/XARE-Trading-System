//+------------------------------------------------------------------+
//| ExitEngine.mqh — management decisions (spec §22, §23)            |
//| v0.11.0 — M11.                                                   |
//|                                                                  |
//| Pure decision layer for an OPEN position. Produces management    |
//| ORDERS (as data) that an executor applies; it never touches the  |
//| terminal itself. Every decision is explainable and every action  |
//| keeps risk <= entry risk: stops may only tighten (§22).          |
//| Orders: XARE_MGMT_NONE / MODIFY_SL / MODIFY_TP / PARTIAL_CLOSE / |
//| CLOSE_FULL.                                                      |
//+------------------------------------------------------------------+
#ifndef __XARE_EXITENGINE_MQH__
#define __XARE_EXITENGINE_MQH__

#include "Types.mqh"
#include "Config.mqh"

//--- management action type
enum ENUM_XARE_MGMT_ACTION
  {
   XARE_MGMT_NONE = 0,
   XARE_MGMT_MODIFY_SL,
   XARE_MGMT_MODIFY_TP,
   XARE_MGMT_PARTIAL_CLOSE,
   XARE_MGMT_CLOSE_FULL
  };

//--- one management decision (data, not a terminal call)
struct SXareMgmtOrder
  {
   ENUM_XARE_MGMT_ACTION action;
   double           new_sl;        // for MODIFY_SL (tick-grid normalized)
   double           new_tp;        // for MODIFY_TP
   double           close_volume;  // for PARTIAL_CLOSE
   string           reason;        // human-readable, journal-ready
  };

string XareMgmtActionToString(const ENUM_XARE_MGMT_ACTION a)
  {
   switch(a)
     {
      case XARE_MGMT_MODIFY_SL:     return "MODIFY_SL";
      case XARE_MGMT_MODIFY_TP:     return "MODIFY_TP";
      case XARE_MGMT_PARTIAL_CLOSE: return "PARTIAL_CLOSE";
      case XARE_MGMT_CLOSE_FULL:    return "CLOSE_FULL";
      default:                      return "NONE";
     }
  }

class CXareExitEngine
  {
private:
   SXareConfig      m_cfg;

public:
                     CXareExitEngine(void) { XareConfigDefaults(m_cfg); }
   void              Init(const SXareConfig &cfg) { m_cfg = cfg; }

   //--- pure: break-even decision (§22). BE adds a lock buffer so costs
   //--- (spread/commission approximated by be_lock_points) are covered.
   //--- Never moves SL backward past entry on the loss side (risk rule).
   bool              ShouldBreakEven(const SXarePosition &pos,
                                     const double current_price,
                                     const double point,
                                     double &new_sl_out, string &reason_out) const
     {
      new_sl_out  = 0.0;
      reason_out  = "";
      if(pos.be_done || pos.direction == 0 || point <= 0.0)
         return false;
      double profit_dist = (pos.direction > 0)
                           ? (current_price - pos.entry_price)
                           : (pos.entry_price - current_price);
      double trigger = m_cfg.be_trigger_r * MathAbs(pos.entry_price - pos.sl_price);
      if(trigger <= 0.0 || profit_dist < trigger)
         return false;
      double lock = m_cfg.be_lock_points * point;
      new_sl_out = (pos.direction > 0)
                   ? pos.entry_price + lock
                   : pos.entry_price - lock;
      //--- tighten-only: current SL must be worse than the new one
      bool tightens = (pos.direction > 0)
                      ? (pos.sl_price < new_sl_out)
                      : (pos.sl_price > new_sl_out || pos.sl_price == 0.0);
      if(!tightens)
         return false;
      reason_out = StringFormat("break-even at %.2fR (lock %.0fpt)",
                                m_cfg.be_trigger_r, m_cfg.be_lock_points);
      return true;
     }

   //--- pure: trailing-stop decision (§22). Trail distance = ATR x mult,
   //--- SL follows price at that distance, tighten-only, after trigger R.
   bool              ShouldTrail(const SXarePosition &pos,
                                 const double current_price,
                                 const double atr,
                                 double &new_sl_out, string &reason_out) const
     {
      new_sl_out  = 0.0;
      reason_out  = "";
      if(pos.direction == 0 || atr <= 0.0)
         return false;
      double profit_dist = (pos.direction > 0)
                           ? (current_price - pos.entry_price)
                           : (pos.entry_price - current_price);
      double trigger = m_cfg.trail_trigger_r * MathAbs(pos.entry_price - pos.sl_price);
      if(profit_dist < trigger)
         return false;
      double dist = atr * m_cfg.trail_atr_mult;
      if(dist <= 0.0)
         return false;
      new_sl_out = (pos.direction > 0)
                   ? current_price - dist
                   : current_price + dist;
      bool tightens = (pos.direction > 0)
                      ? (new_sl_out > pos.sl_price)
                      : (new_sl_out < pos.sl_price || pos.sl_price == 0.0);
      if(!tightens)
         return false;
      reason_out = StringFormat("trailing at %.1fxATR after %.1fR",
                                m_cfg.trail_atr_mult, m_cfg.trail_trigger_r);
      return true;
     }

   //--- pure: partial-profit decision (§22). One shot per position.
   bool              ShouldTakePartial(const SXarePosition &pos,
                                       const double current_price,
                                       double &close_vol_out,
                                       string &reason_out) const
     {
      close_vol_out = 0.0;
      reason_out    = "";
      if(pos.partial_done || pos.direction == 0)
         return false;
      double profit_dist = (pos.direction > 0)
                           ? (current_price - pos.entry_price)
                           : (pos.entry_price - current_price);
      double trigger = m_cfg.partial_trigger_r * MathAbs(pos.entry_price - pos.sl_price);
      if(trigger <= 0.0 || profit_dist < trigger)
         return false;
      close_vol_out = pos.volume_initial * m_cfg.partial_close_pct / 100.0;
      if(close_vol_out <= 0.0)
         return false;
      reason_out = StringFormat("partial %.0f%% at %.1fR",
                                m_cfg.partial_close_pct, m_cfg.partial_trigger_r);
      return true;
     }

   //--- pure: time-based exit (§23). Positions must never linger unmanaged.
   bool              ShouldTimeExit(const SXarePosition &pos,
                                    const int max_bars, const int max_minutes,
                                    string &reason_out) const
     {
      reason_out = "";
      if(pos.direction == 0)
         return false;
      if(max_bars > 0 && pos.bars_in_trade >= max_bars)
        {
         reason_out = StringFormat("max bars in trade (%d >= %d)",
                                   pos.bars_in_trade, max_bars);
         return true;
        }
      if(max_minutes > 0 && pos.open_time > 0)
        {
         long mins = (long)(TimeCurrent() - pos.open_time) / 60;
         if(mins >= max_minutes)
           {
            reason_out = StringFormat("max holding minutes (%d >= %d)",
                                      (int)mins, max_minutes);
            return true;
           }
        }
      return false;
     }

   //--- pure: regime-change exit (§22). A trend trade in an opposing regime
   //--- has lost its thesis; exit rather than hope.
   bool              ShouldRegimeExit(const SXarePosition &pos,
                                      const ENUM_XARE_REGIME current_regime,
                                      string &reason_out) const
     {
      reason_out = "";
      if(pos.direction == 0 || current_regime == XARE_REGIME_UNKNOWN)
         return false;
      bool opposite = (pos.direction > 0 &&
                       current_regime == XARE_REGIME_TREND_DOWN) ||
                      (pos.direction < 0 &&
                       current_regime == XARE_REGIME_TREND_UP);
      if(!opposite)
         return false;
      reason_out = StringFormat("regime flipped to %s against %s position",
                                XareRegimeToString(current_regime),
                                pos.direction > 0 ? "LONG" : "SHORT");
      return true;
     }

   //--- pure: signal-reversal exit (§22). A fresh OPPOSITE actionable signal
   //--- (any setup type) voids the current trade's thesis.
   bool              ShouldReversalExit(const SXarePosition &pos,
                                        const int new_signal_direction,
                                        string &reason_out) const
     {
      reason_out = "";
      if(pos.direction == 0 || new_signal_direction == 0)
         return false;
      if(new_signal_direction == pos.direction)
         return false;
      reason_out = StringFormat("fresh %s signal reverses %s position",
                                new_signal_direction > 0 ? "LONG" : "SHORT",
                                pos.direction > 0 ? "LONG" : "SHORT");
      return true;
     }

   //--- pure: assemble the management decision for a bar, in priority order.
   //--- current_regime/signals come from the M4/M7 verdicts of the same bar.
   SXareMgmtOrder    Evaluate(const SXarePosition &pos,
                              const double bid, const double ask,
                              const double atr, const double point,
                              const int max_bars, const int max_minutes,
                              const ENUM_XARE_REGIME current_regime,
                              const int new_signal_direction,
                              const SXareSymbolProps &props) const
     {
      SXareMgmtOrder o;
      o.action = XARE_MGMT_NONE;
      o.new_sl = 0.0; o.new_tp = 0.0; o.close_volume = 0.0; o.reason = "";
      if(pos.direction == 0 || point <= 0.0)
         return o;

      double px = (pos.direction > 0) ? bid : ask;   // close-side price

      //--- 1) hard exits first: time, regime flip, reversal
      string why = "";
      if(ShouldTimeExit(pos, max_bars, max_minutes, why))
        {
         o.action = XARE_MGMT_CLOSE_FULL;
         o.reason = "TIME EXIT: " + why;
         return o;
        }
      if(ShouldRegimeExit(pos, current_regime, why))
        {
         o.action = XARE_MGMT_CLOSE_FULL;
         o.reason = "REGIME EXIT: " + why;
         return o;
        }
      if(ShouldReversalExit(pos, new_signal_direction, why))
        {
         o.action = XARE_MGMT_CLOSE_FULL;
         o.reason = "REVERSAL EXIT: " + why;
         return o;
        }

      //--- 2) protective ladder: partial, then BE, then trail (tighten-only)
      double vol = 0.0, sl_new = 0.0;
      if(ShouldTakePartial(pos, px, vol, why))
        {
         o.action       = XARE_MGMT_PARTIAL_CLOSE;
         o.close_volume = vol;
         o.reason       = "PARTIAL: " + why;
         return o;
        }
      if(ShouldBreakEven(pos, px, point, sl_new, why))
        {
         o.action = XARE_MGMT_MODIFY_SL;
         o.new_sl = NormalizeDouble(MathFloor(sl_new / props.tick_size) *
                                    props.tick_size, props.digits);
         o.reason = "SL MOVE: " + why;
         return o;
        }
      if(ShouldTrail(pos, px, atr, sl_new, why))
        {
         //--- trail keeps a safety margin: never inside stops level
         double min_dist = props.stops_level * point;
         bool tightens = (pos.direction > 0)
                         ? (sl_new > pos.sl_price)
                         : (sl_new < pos.sl_price || pos.sl_price == 0.0);
         bool respects = (pos.direction > 0)
                         ? (px - sl_new >= min_dist)
                         : (sl_new - px >= min_dist);
         if(tightens && respects)
           {
            o.action = XARE_MGMT_MODIFY_SL;
            o.new_sl = NormalizeDouble((pos.direction > 0)
                                       ? MathFloor(sl_new / props.tick_size) * props.tick_size
                                       : MathCeil (sl_new / props.tick_size) * props.tick_size,
                                       props.digits);
            o.reason = "SL MOVE: " + why;
           }
        }
      return o;
     }
  };
#endif // __XARE_EXITENGINE_MQH__
