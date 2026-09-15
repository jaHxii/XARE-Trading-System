//+------------------------------------------------------------------+
//| LiquidityEngine.mqh — liquidity levels + sweep detection (§11)    |
//| v0.6.0 — M6.                                                     |
//| Objective definitions only:                                      |
//|   Levels: previous-day high/low (PDH/PDL), current session       |
//|   episode high/low, most recent confirmed swing high/low.        |
//|   Sweep: price WICKS through a level by >= SweepATRMultiple·ATR  |
//|   but the bar CLOSES back on the origin side (or within          |
//|   SweepReclaimBars). A close beyond the level is a BREAK, not a  |
//|   sweep. No smart-money claims — measurable mechanics only.      |
//+------------------------------------------------------------------+
#ifndef __XARE_LIQUIDITYENGINE_MQH__
#define __XARE_LIQUIDITYENGINE_MQH__

#include "Types.mqh"
#include "Config.mqh"
#include "Logger.mqh"
#include "SessionEngine.mqh"

class CXareLiquidityEngine
  {
private:
   SXareConfig      m_cfg;
   string           m_symbol;
   ENUM_TIMEFRAMES  m_tf;
   SXareLiquidity   m_last;
   CXareLogger     *m_log;

   //--- previous day high/low from D1 data (closed D1 bar = shift 1)
   bool              PrevDayHL(double &pdh, double &pdl) const
     {
      pdh = iHigh(m_symbol, PERIOD_D1, 1);
      pdl = iLow (m_symbol, PERIOD_D1, 1);
      return (pdh > 0 && pdl > 0 && pdh >= pdl);
     }

   //--- most recent confirmed swing extremes (structure engine's rule)
   bool              RecentSwingHL(const int lookback, double &sh, double &sl) const
     {
      // lightweight scan consistent with StructureEngine confirmation:
      // a pivot needs pivot_lb each side + pivot_confirm closed after it.
      int lb = m_cfg.pivot_lookback;
      int start = lb + m_cfg.pivot_confirm;
      if(Bars(m_symbol, m_tf) < start + lookback)
         return false;
      sh = 0; sl = 0;
      for(int i = start; i < start + lookback && (sh <= 0 || sl <= 0); i++)
        {
         if(sh <= 0)
           {
            double h = iHigh(m_symbol, m_tf, i);
            bool is_p = true;
            for(int k = 1; k <= lb && is_p; k++)
               if(iHigh(m_symbol, m_tf, i - k) >= h ||
                  iHigh(m_symbol, m_tf, i + k) >  h)
                  is_p = false;
            if(is_p) sh = h;
           }
         if(sl <= 0)
           {
            double l = iLow(m_symbol, m_tf, i);
            bool is_p = true;
            for(int k = 1; k <= lb && is_p; k++)
               if(iLow(m_symbol, m_tf, i - k) <= l ||
                  iLow(m_symbol, m_tf, i + k) <  l)
                  is_p = false;
            if(is_p) sl = l;
           }
        }
      return (sh > 0 && sl > 0);
     }

   //--- sweep test for one level; direction semantics:
   //--- sweep_up: price traded ABOVE the level then closed back BELOW it
   //--- sweep_down: price traded BELOW the level then closed back ABOVE it
   bool              TestSweep(const double level, const double bar_high,
                               const double bar_low, const double bar_close,
                               const double atr,
                               bool &sweep_up, bool &sweep_down,
                               double &penetration) const
     {
      sweep_up = false; sweep_down = false; penetration = 0.0;
      if(level <= 0 || atr <= 0)
         return false;
      double depth_req = m_cfg.sweep_atr_multiple * atr;

      // wick above the level, close back below
      if(bar_high > level && bar_close < level)
        {
         double depth = bar_high - level;
         if(depth >= depth_req)
           {
            sweep_up = true;
            penetration = depth / atr;
            return true;
           }
        }
      // wick below the level, close back above
      if(bar_low < level && bar_close > level)
        {
         double depth = level - bar_low;
         if(depth >= depth_req)
           {
            sweep_down = true;
            penetration = depth / atr;
            return true;
           }
        }
      return false;
     }

public:
                     CXareLiquidityEngine(void) : m_symbol(""), m_tf(PERIOD_CURRENT),
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

   //--- evaluate liquidity events for the closed bar at 'shift'
   bool              Evaluate(const int shift, const SXareSession &session,
                              const double atr, SXareLiquidity &out)
     {
      ZeroMemory(out);
      out.valid = false;

      SXareBar bar;
      datetime bt = iTime(m_symbol, m_tf, shift);
      if(bt <= 0)
         return false;
      bar.high  = iHigh(m_symbol, m_tf, shift);
      bar.low   = iLow (m_symbol, m_tf, shift);
      bar.close = iClose(m_symbol, m_tf, shift);
      if(bar.high <= 0 || bar.low <= 0 || bar.close <= 0)
         return false;

      // --- candidate levels (objective) --------------------------------
      double pdh = 0, pdl = 0;
      bool have_pd = PrevDayHL(pdh, pdl);
      double sh = 0, sl = 0;
      bool have_sw = RecentSwingHL(m_cfg.swing_liquidity_lookback, sh, sl);
      double sess_h = session.valid ? session.high : 0.0;
      double sess_l = session.valid ? session.low  : 0.0;

      // --- test each level; first hit wins (documented priority: PD >
      // --- session > swing, because prior-day extremes carry more weight)
      bool hit = false;
      double lvl = 0; string lname = "";
      bool up = false, down = false; double pen = 0;

      if(have_pd && !hit)
        {
         if(TestSweep(pdh, bar.high, bar.low, bar.close, atr, up, down, pen))
           { hit = true; lvl = pdh; lname = "PDH"; }
         else if(TestSweep(pdl, bar.high, bar.low, bar.close, atr, up, down, pen))
           { hit = true; lvl = pdl; lname = "PDL"; }
        }
      if(session.valid && sess_h > 0 && !hit)
        {
         if(TestSweep(sess_h, bar.high, bar.low, bar.close, atr, up, down, pen))
           { hit = true; lvl = sess_h; lname = "SESS_HIGH"; }
         else if(sess_l > 0 &&
                 TestSweep(sess_l, bar.high, bar.low, bar.close, atr, up, down, pen))
           { hit = true; lvl = sess_l; lname = "SESS_LOW"; }
        }
      if(have_sw && !hit)
        {
         if(TestSweep(sh, bar.high, bar.low, bar.close, atr, up, down, pen))
           { hit = true; lvl = sh; lname = "SWING_HIGH"; }
         else if(TestSweep(sl, bar.high, bar.low, bar.close, atr, up, down, pen))
           { hit = true; lvl = sl; lname = "SWING_LOW"; }
        }

      out.sweep_up        = (hit && up);
      out.sweep_down      = (hit && down);
      out.swept_level     = hit ? lvl : 0.0;
      out.level_name      = hit ? lname : "";
      out.penetration_atr = hit ? pen : 0.0;
      out.evidence        = hit
         ? StringFormat("sweep_%s of %s (%s) depth=%.2f ATR",
                        up ? "up" : "down", lname,
                        DoubleToString(lvl, 2), pen)
         : StringFormat("no sweep | PDH=%s PDL=%s sessH=%s sessL=%s swH=%s swL=%s",
                        DoubleToString(pdh, 2), DoubleToString(pdl, 2),
                        DoubleToString(sess_h, 2), DoubleToString(sess_l, 2),
                        DoubleToString(sh, 2),  DoubleToString(sl, 2));
      out.evaluated_at    = TimeCurrent();
      out.valid           = true;
      m_last              = out;

      if(m_log != NULL)
         m_log.Debug("LIQ", out.evidence);
      return true;
     }

   bool              Last(SXareLiquidity &out) const
     {
      if(!m_last.valid)
         return false;
      out = m_last;
      return true;
     }

   //--- pure sweep math exposed for SELF_TEST
   static bool       SweepStatic(const double level, const double bar_high,
                                 const double bar_low, const double bar_close,
                                 const double atr, const double mult,
                                 bool &up, bool &down, double &penetration)
     {
      up = false; down = false; penetration = 0.0;
      if(level <= 0 || atr <= 0)
         return false;
      double depth_req = mult * atr;
      if(bar_high > level && bar_close < level && (bar_high - level) >= depth_req)
        {
         up = true; penetration = (bar_high - level) / atr;
         return true;
        }
      if(bar_low < level && bar_close > level && (level - bar_low) >= depth_req)
        {
         down = true; penetration = (level - bar_low) / atr;
         return true;
        }
      return false;
     }
  };

#endif // __XARE_LIQUIDITYENGINE_MQH__
