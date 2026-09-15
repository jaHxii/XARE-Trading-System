//+------------------------------------------------------------------+
//| StructureEngine.mqh — swings, BOS/CHoCH, S/R zones (spec §10)     |
//| v0.5.0 — M5.                                                     |
//| Pivot confirmation rule (documented, anti-look-ahead): a bar i   |
//| is a swing high if its high is >= the highs of the L bars before |
//| AND AFTER it, where "after" counts only CLOSED bars. A pivot is  |
//| therefore only KNOWN once PivotConfirmBars bars have closed past |
//| it. This engine never inspects bars newer than shift 1.          |
//+------------------------------------------------------------------+
#ifndef __XARE_STRUCTUREENGINE_MQH__
#define __XARE_STRUCTUREENGINE_MQH__

#include "Types.mqh"
#include "Config.mqh"
#include "Logger.mqh"

#define XARE_MAX_ZONES 4

//--- one confirmed pivot
struct SXarePivot
  {
   datetime         time;
   double           price;
   int              bar_index;      // shift at confirmation time (informational)
  };

class CXareStructureEngine
  {
private:
   string           m_symbol;
   ENUM_TIMEFRAMES  m_tf;
   int              m_pivot_lb;     // bars on each side of a pivot
   int              m_pivot_confirm;// closed bars required after pivot
   int              m_max_zones;
   SXareStructure   m_last;
   CXareLogger     *m_log;

   //--- scan for the most recent confirmed swing high/low ending before
   //--- 'from_shift' (a pivot needs pivot_lb bars on each side and
   //--- pivot_confirm bars closed after it before we may know it).
   bool              FindSwingHigh(const int from_shift, SXarePivot &p) const
     {
      for(int i = from_shift; i <= 500; i++)
        {
         double h = iHigh(m_symbol, m_tf, i + m_pivot_lb);
         if(h <= 0)
            return false;
         bool is_pivot = true;
         // left side: bars AFTER the pivot in time (higher shift = older)
         for(int k = 1; k <= m_pivot_lb && is_pivot; k++)
            if(iHigh(m_symbol, m_tf, i + m_pivot_lb + k) > h)
               is_pivot = false;
         // right side: bars BEFORE the pivot in time (must be closed)
         for(int k = 1; k <= m_pivot_lb && is_pivot; k++)
            if(iHigh(m_symbol, m_tf, i + m_pivot_lb - k) >= h)
               is_pivot = false;
         if(is_pivot)
           {
            p.time      = iTime(m_symbol, m_tf, i + m_pivot_lb);
            p.price     = h;
            p.bar_index = i + m_pivot_lb;
            return true;
           }
        }
      return false;
     }

   bool              FindSwingLow(const int from_shift, SXarePivot &p) const
     {
      for(int i = from_shift; i <= 500; i++)
        {
         double l = iLow(m_symbol, m_tf, i + m_pivot_lb);
         if(l <= 0)
            return false;
         bool is_pivot = true;
         for(int k = 1; k <= m_pivot_lb && is_pivot; k++)
            if(iLow(m_symbol, m_tf, i + m_pivot_lb + k) < l)
               is_pivot = false;
         for(int k = 1; k <= m_pivot_lb && is_pivot; k++)
            if(iLow(m_symbol, m_tf, i + m_pivot_lb - k) <= l)
               is_pivot = false;
         if(is_pivot)
           {
            p.time      = iTime(m_symbol, m_tf, i + m_pivot_lb);
            p.price     = l;
            p.bar_index = i + m_pivot_lb;
            return true;
           }
        }
      return false;
     }

   //--- collect up to 'max_zones' most recent swing levels of one side
   int               CollectLevels(const bool highs, const int max_zones, double &out[]) const
     {
      ArrayResize(out, 0);
      int found = 0;
      int start = 1 + m_pivot_confirm;      // first bar where a pivot may be known
      for(int n = 0; n < 200 && found < max_zones; n++)
        {
         SXarePivot p;
         bool ok = highs ? FindSwingHigh(start, p) : FindSwingLow(start, p);
         if(!ok)
            break;
         int sz = ArraySize(out);
         ArrayResize(out, sz + 1);
         out[sz] = p.price;
         found++;
         start = p.bar_index + 1;            // continue before this pivot
        }
      return found;
     }

public:
                     CXareStructureEngine(void) : m_symbol(""), m_tf(PERIOD_CURRENT),
                                                  m_pivot_lb(3), m_pivot_confirm(2),
                                                  m_max_zones(XARE_MAX_ZONES),
                                                  m_log(NULL)
     {
      ZeroMemory(m_last);
     }

   bool              Init(const string symbol, const ENUM_TIMEFRAMES tf,
                          const int pivot_lookback, const int pivot_confirm,
                          const int max_zones, CXareLogger *log)
     {
      m_symbol        = symbol;
      m_tf            = tf;
      m_pivot_lb      = (pivot_lookback >= 1 ? pivot_lookback : 1);
      m_pivot_confirm = (pivot_confirm  >= 1 ? pivot_confirm  : 1);
      m_max_zones     = MathMax(1, MathMin(max_zones, XARE_MAX_ZONES));
      m_log           = log;
      return true;
     }

   //--- evaluate structure as of the closed bar at 'shift'
   bool              Evaluate(const int shift, SXareStructure &out)
     {
      ZeroMemory(out);
      out.valid = false;

      SXarePivot sh1, sh2, sl1, sl2;
      if(!FindSwingHigh(shift + m_pivot_confirm, sh1)) return false;
      if(!FindSwingHigh(sh1.bar_index + 1,        sh2)) return false;
      if(!FindSwingLow (shift + m_pivot_confirm, sl1)) return false;
      if(!FindSwingLow (sl1.bar_index + 1,        sl2)) return false;

      out.last_swing_high  = sh1.price;
      out.prev_swing_high  = sh2.price;
      out.last_swing_low   = sl1.price;
      out.prev_swing_low   = sl2.price;

      // --- swing-sequence trend --------------------------------------
      bool hh = (sh1.price > sh2.price);
      bool hl = (sl1.price > sl2.price);
      bool lh = (sh1.price < sh2.price);
      bool ll = (sl1.price < sl2.price);
      if(hh && hl)       out.trend = XARE_STRUCT_BULLISH;
      else if(lh && ll)  out.trend = XARE_STRUCT_BEARISH;
      else if(hh || hl || lh || ll) out.trend = XARE_STRUCT_MIXED;
      else               out.trend = XARE_STRUCT_NEUTRAL;

      // --- BOS on the signal bar (closed bar only) --------------------
      double close = iClose(m_symbol, m_tf, shift);
      if(close <= 0)
         return false;
      out.bos_bull = (close > sh1.price);
      out.bos_bear = (close < sl1.price);

      // CHoCH: BOS against the prevailing swing trend
      out.choch = (out.bos_bull && out.trend == XARE_STRUCT_BEARISH) ||
                  (out.bos_bear && out.trend == XARE_STRUCT_BULLISH);

      // --- approximate S/R zones from recent swings -------------------
      double res[], sup[];
      out.zone_count_res = CollectLevels(true,  m_max_zones, res);
      out.zone_count_sup = CollectLevels(false, m_max_zones, sup);
      for(int i = 0; i < out.zone_count_res && i < XARE_MAX_ZONES; i++)
         out.resistance[i] = res[i];
      for(int i = 0; i < out.zone_count_sup && i < XARE_MAX_ZONES; i++)
         out.support[i] = sup[i];

      out.evidence = StringFormat(
         "trend=%s SH=%s->%s SL=%s->%s bos_bull=%d bos_bear=%d choch=%d zones(R/S)=%d/%d",
         out.trend==XARE_STRUCT_BULLISH?"BULL":
         out.trend==XARE_STRUCT_BEARISH?"BEAR":
         out.trend==XARE_STRUCT_MIXED?"MIXED":"FLAT",
         DoubleToString(out.prev_swing_high, 2), DoubleToString(out.last_swing_high, 2),
         DoubleToString(out.prev_swing_low, 2),  DoubleToString(out.last_swing_low, 2),
         out.bos_bull, out.bos_bear, out.choch,
         out.zone_count_res, out.zone_count_sup);
      out.evaluated_at = TimeCurrent();
      out.valid = true;
      m_last = out;

      if(m_log != NULL)
         m_log.Debug("STRUCT", out.evidence);
      return true;
     }

   bool              Last(SXareStructure &out) const
     {
      if(!m_last.valid)
         return false;
      out = m_last;
      return true;
     }

   //--- exposed for SELF_TEST: pure pivot-bar validity math
   static int        MinBarsForPivot(const int pivot_lb, const int pivot_confirm)
     {
      return pivot_lb + pivot_confirm;   // bars needed before a pivot is KNOWN
     }
  };

#endif // __XARE_STRUCTUREENGINE_MQH__
