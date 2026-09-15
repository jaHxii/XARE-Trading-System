//+------------------------------------------------------------------+
//| SessionEngine.mqh — broker-time sessions (spec §13)               |
//| v0.6.0 — M6.                                                     |
//| All windows are CONFIGURED in broker SERVER time minutes-from-   |
//| midnight. Local time is never used. Overlap = London ∩ New York. |
//| Session H/L accumulate from bar data (closed bars only).         |
//+------------------------------------------------------------------+
#ifndef __XARE_SESSIONENGINE_MQH__
#define __XARE_SESSIONENGINE_MQH__

#include "Types.mqh"
#include "Config.mqh"
#include "Logger.mqh"

class CXareSessionEngine
  {
private:
   SXareConfig      m_cfg;
   string           m_symbol;
   ENUM_TIMEFRAMES  m_tf;
   SXareSession     m_last;
   CXareLogger     *m_log;

   //--- static mapping is testable; episode H/L is stateful below
   ENUM_XARE_SESSION SessionForMinute(const int minute) const
     {
      // windows may overlap by design; priority: overlap > NY > London > Asian
      bool in_london = (minute >= m_cfg.sess_london_start && minute < m_cfg.sess_london_end);
      bool in_ny     = (minute >= m_cfg.sess_ny_start     && minute < m_cfg.sess_ny_end);
      bool in_asian  = (minute >= m_cfg.sess_asian_start  && minute < m_cfg.sess_asian_end);
      if(in_london && in_ny)   return XARE_SESS_OVERLAP;
      if(in_ny)                return XARE_SESS_NEWYORK;
      if(in_london)            return XARE_SESS_LONDON;
      if(in_asian)             return XARE_SESS_ASIAN;
      return XARE_SESS_OFF;
     }

   static string     NameOf(const ENUM_XARE_SESSION s)
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

public:
                     CXareSessionEngine(void) : m_symbol(""), m_tf(PERIOD_CURRENT),
                                                m_log(NULL)
     {
      ZeroMemory(m_last);
     }

   bool              Init(const string symbol, const ENUM_TIMEFRAMES tf,
                          const SXareConfig &cfg, CXareLogger *log)
     {
      m_symbol = symbol;
      m_tf     = tf;
      m_cfg    = cfg;
      m_log    = log;
      return true;
     }

   //--- evaluate session for the closed bar at 'shift'
   bool              Evaluate(const int shift, SXareSession &out)
     {
      ZeroMemory(out);
      out.valid = false;

      datetime bt = iTime(m_symbol, m_tf, shift);
      if(bt <= 0)
         return false;
      MqlDateTime dt;
      TimeToStruct(bt, dt);
      int minute = dt.hour * 60 + dt.min;

      ENUM_XARE_SESSION prev = m_last.valid ? m_last.session : XARE_SESS_OFF;
      ENUM_XARE_SESSION now  = SessionForMinute(minute);
      bool episode_continues = (now == prev && prev != XARE_SESS_OFF &&
                                m_last.evaluated_at > 0 &&
                                // same broker day keeps the episode alive
                                (bt - m_last.evaluated_at) <= 24*3600);

      // accumulate H/L over the episode (closed-bar highs/lows only)
      double h = iHigh(m_symbol, m_tf, shift);
      double l = iLow (m_symbol, m_tf, shift);
      if(h <= 0 || l <= 0)
         return false;
      if(episode_continues)
        {
         out.high = MathMax(m_last.high, h);
         out.low  = MathMin(m_last.low,  l);
         out.episode_bars = m_last.episode_bars + 1;
        }
      else
        {
         out.high = h;                    // new episode starts from this bar
         out.low  = l;
         out.episode_bars = 1;
        }

      out.session       = now;
      out.minute_of_day = minute;
      out.range         = out.high - out.low;
      out.evidence      = StringFormat("session=%s minute=%d H=%s L=%s range=%s bars=%d",
                          NameOf(now), minute,
                          DoubleToString(out.high, 2), DoubleToString(out.low, 2),
                          DoubleToString(out.range, 2), out.episode_bars);
      out.evaluated_at  = bt;
      out.valid         = true;
      m_last            = out;

      if(m_log != NULL)
         m_log.Debug("SESSION", out.evidence);
      return true;
     }

   bool              Last(SXareSession &out) const
     {
      if(!m_last.valid)
         return false;
      out = m_last;
      return true;
     }

   //--- pure classifier exposed for SELF_TEST (uses provided config values)
   static ENUM_XARE_SESSION ClassifyStatic(const int minute,
                                           const int lon_s, const int lon_e,
                                           const int ny_s,  const int ny_e,
                                           const int asi_s, const int asi_e)
     {
      bool in_london = (minute >= lon_s && minute < lon_e);
      bool in_ny     = (minute >= ny_s  && minute < ny_e);
      bool in_asian  = (minute >= asi_s && minute < asi_e);
      if(in_london && in_ny) return XARE_SESS_OVERLAP;
      if(in_ny)              return XARE_SESS_NEWYORK;
      if(in_london)          return XARE_SESS_LONDON;
      if(in_asian)           return XARE_SESS_ASIAN;
      return XARE_SESS_OFF;
     }
  };

#endif // __XARE_SESSIONENGINE_MQH__
