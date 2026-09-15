//+------------------------------------------------------------------+
//| SafetyEngine.mqh — centralized trade gatekeeper (spec §33)       |
//| v0.12.0 — M12.                                                   |
//|                                                                  |
//| ONE place that decides GO or BLOCK(reason) for any order. The    |
//| execution layer MUST consult it immediately before every send;   |
//| every blocked trade carries a machine-readable reason + detail.  |
//| Also owns the EMERGENCY latch (§51): when armed, new orders are  |
//| refused until the EA is re-initialized (human decision).         |
//| Pure predicates + passed-in state; the EA feeds live values.     |
//+------------------------------------------------------------------+
#ifndef __XARE_SAFETYENGINE_MQH__
#define __XARE_SAFETYENGINE_MQH__

#include "Types.mqh"
#include "Config.mqh"

struct SXareSafetyContext
  {
   bool             trading_enabled;      // global switch + mode verdict
   bool             emergency;            // §51 latch
   bool             halted;               // risk HALTED latch (§25)
   bool             daily_breach;         // §24
   bool             weekly_breach;        // §24
   bool             cooldown_active;      // §26
   bool             exec_fail_streak;     // repeated execution failures
   int              spread_points;        // current spread (-1 unknown)
   int              max_spread_points;
   int              abnormal_spread_points;
   bool             news_clear;           // NewsFilter verdict
   string           news_reason;
   bool             quotes_ok;
   bool             data_ok;              // features/props valid
   bool             symbol_trade_full;    // SYMBOL_TRADE_MODE == FULL
   double           equity;               // >0 sanity
   long             free_margin;          // sanity flag only (margin check
                                      // happens in the plan builder)
   bool             margin_ok;
  };

class CXareSafetyEngine
  {
private:
   bool             m_emergency;
   string           m_emergency_reason;

public:
                     CXareSafetyEngine(void) : m_emergency(false),
                                               m_emergency_reason("") {}

   void              Init(void)
     {
      m_emergency        = false;
      m_emergency_reason = "";
     }

   //--- §51: arm the emergency latch (EA calls on irreversible triggers)
   void              ArmEmergency(const string reason)
     {
      if(!m_emergency)
        {
         m_emergency        = true;
         m_emergency_reason = reason;
         PrintFormat("XARE[SAFETY][ERROR] EMERGENCY STOP armed: %s", reason);
        }
     }
   bool              Emergency(void) const { return m_emergency; }
   string            EmergencyReason(void) const { return m_emergency_reason; }

   //--- the single gate. Always returns a verdict + reason codes.
   bool              Go(const SXareSafetyContext &c,
                        ENUM_XARE_BLOCK_REASON &reason_out,
                        string &detail_out) const
     {
      reason_out = XARE_BR_NONE;
      detail_out = "";

      //--- 1) emergency latch outranks everything (§51)
      if(m_emergency)
        {
         reason_out = XARE_BR_EMERGENCY;
         detail_out = m_emergency_reason;
         return false;
        }
      //--- 2) explicit global switch
      if(!c.trading_enabled)
        {
         reason_out = XARE_BR_TRADING_OFF;
         detail_out = "global trading switch off / mode never trades";
         return false;
        }
      //--- 3) risk halt latch
      if(c.halted)
        {
         reason_out = XARE_BR_RISK_HALTED;
         detail_out = "drawdown halt state active";
         return false;
        }
      //--- 4) loss limits (§24)
      if(c.daily_breach)
        {
         reason_out = XARE_BR_DAILY_LOSS;
         detail_out = "daily loss limit reached";
         return false;
        }
      if(c.weekly_breach)
        {
         reason_out = XARE_BR_WEEKLY_LOSS;
         detail_out = "weekly loss limit reached";
         return false;
        }
      //--- 5) streak cooldown (§26)
      if(c.cooldown_active)
        {
         reason_out = XARE_BR_COOLDOWN_LOSSES;
         detail_out = "consecutive-loss cooldown active";
         return false;
        }
      //--- 6) repeated execution failures (§51 precursor)
      if(c.exec_fail_streak)
        {
         reason_out = XARE_BR_EXEC_FAILURE;
         detail_out = "repeated execution failures — new sends paused";
         return false;
        }
      //--- 7) data integrity
      if(!c.data_ok)
        {
         reason_out = XARE_BR_DATA_STALE;
         detail_out = "market data or features invalid";
         return false;
        }
      //--- 8) quotes
      if(!c.quotes_ok)
        {
         reason_out = XARE_BR_NO_QUOTES;
         detail_out = "bid/ask unavailable";
         return false;
        }
      //--- 9) symbol state (§6)
      if(!c.symbol_trade_full)
        {
         reason_out = XARE_BR_SYMBOL_STATE;
         detail_out = "symbol trading disabled/restricted by broker";
         return false;
        }
      //--- 10) equity sanity
      if(c.equity <= 0.0)
        {
         reason_out = XARE_BR_DATA_STALE;
         detail_out = "account equity unavailable";
         return false;
        }
      //--- 11) news (§14) — only blocks when real event data exists
      if(!c.news_clear)
        {
         reason_out = XARE_BR_NEWS;
         detail_out = c.news_reason;
         return false;
        }
      //--- 12) spread: abnormal first, then entry limit (§28)
      if(c.spread_points < 0)
        {
         reason_out = XARE_BR_SPREAD;
         detail_out = "spread unavailable";
         return false;
        }
      if(c.abnormal_spread_points > 0 &&
         c.spread_points >= c.abnormal_spread_points)
        {
         reason_out = XARE_BR_SPREAD_ABNORMAL;
         detail_out = StringFormat("spread %dpt >= abnormal %dpt",
                                   c.spread_points, c.abnormal_spread_points);
         return false;
        }
      if(c.max_spread_points > 0 &&
         c.spread_points >= c.max_spread_points)
        {
         reason_out = XARE_BR_SPREAD;
         detail_out = StringFormat("spread %dpt >= limit %dpt",
                                   c.spread_points, c.max_spread_points);
         return false;
        }
      //--- 13) margin headroom (final backstop after plan-level check)
      if(!c.margin_ok)
        {
         reason_out = XARE_BR_MARGIN;
         detail_out = "insufficient free margin";
         return false;
        }
      return true;
     }
  };
#endif // __XARE_SAFETYENGINE_MQH__
