//+------------------------------------------------------------------+
//| MarketData.mqh — closed-bar access, new-bar detection, props (§5,6)|
//| v0.2.0 — M2.                                                     |
//| Look-ahead discipline: features are read at shift>=1 only. The   |
//| forming bar (shift 0) is NEVER used for signal decisions.        |
//+------------------------------------------------------------------+
#ifndef __XARE_MARKETDATA_MQH__
#define __XARE_MARKETDATA_MQH__

#include "Types.mqh"
#include "Config.mqh"

class CXareMarketData
  {
private:
   string           m_symbol;
   ENUM_TIMEFRAMES  m_tf;
   datetime         m_last_bar_time;    // new-bar detection anchor
   bool             m_have_last_bar;
   SXareSymbolProps m_props;

   void              CaptureProps()
     {
      m_props.symbol         = m_symbol;
      m_props.digits         = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      m_props.point          = SymbolInfoDouble (m_symbol, SYMBOL_POINT);
      m_props.tick_size      = SymbolInfoDouble (m_symbol, SYMBOL_TRADE_TICK_SIZE);
      m_props.tick_value     = SymbolInfoDouble (m_symbol, SYMBOL_TRADE_TICK_VALUE);
      m_props.contract_size  = SymbolInfoDouble (m_symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      m_props.volume_min     = SymbolInfoDouble (m_symbol, SYMBOL_VOLUME_MIN);
      m_props.volume_max     = SymbolInfoDouble (m_symbol, SYMBOL_VOLUME_MAX);
      m_props.volume_step    = SymbolInfoDouble (m_symbol, SYMBOL_VOLUME_STEP);
      m_props.stops_level    = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      m_props.freeze_level   = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      m_props.trade_mode     = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_MODE);
      m_props.valid          = (m_props.digits > 0 && m_props.point > 0.0 &&
                                m_props.tick_size > 0.0 && m_props.tick_value > 0.0 &&
                                m_props.volume_min > 0.0 && m_props.volume_step > 0.0);
     }

public:
                     CXareMarketData(void) : m_symbol(""), m_tf(PERIOD_CURRENT),
                                             m_last_bar_time(0), m_have_last_bar(false)
     {
      // zero-init props so a failed capture is loud, not silent garbage
      ZeroMemory(m_props);
     }

   //--- symbol comes from the chart (never hard-coded); tf from config caller
   bool              Init(const string symbol, const ENUM_TIMEFRAMES tf,
                          const int min_history_bars)
     {
      m_symbol = symbol;
      m_tf     = tf;
      if(m_symbol == NULL || StringLen(m_symbol) == 0)
         return false;

      CaptureProps();

      if(!SymbolSelect(m_symbol, true))
        {
         PrintFormat("XARE[MD][ERROR] SymbolSelect failed for '%s'", m_symbol);
         return false;
        }
      if(!m_props.valid)
        {
         PrintFormat("XARE[MD][ERROR] invalid symbol properties for '%s' — refusing", m_symbol);
         return false;
        }

      // history availability: Bars() is our calc; require config minimum
      int avail = Bars(m_symbol, m_tf);
      if(avail < min_history_bars)
        {
         PrintFormat("XARE[MD][WARN] only %d bars of %s history (need %d) — engine idles until enough data",
                     avail, EnumToString(m_tf), min_history_bars);
         // not fatal: tester warms up over time; live needs chart history loaded
        }
      return true;
     }

   //--- copy props out (MQL5 functions cannot return references)
   void              GetProps(SXareSymbolProps &out) const { out = m_props; }

   //--- robust new-bar detection + duplicate processing guard (§5):
   //--- returns true exactly once per bar time. First call after init
   //--- returns false (no bar boundary seen yet) to avoid stale-first-run.
   bool              IsNewBar(void)
     {
      datetime t = (datetime)SeriesInfoInteger(m_symbol, m_tf, SERIES_LASTBAR_DATE);
      if(t <= 0)
         return false;
      if(!m_have_last_bar)
        {
         m_have_last_bar  = true;
         m_last_bar_time  = t;
         return false;             // anchor only; do not process mid-bar
        }
      if(t != m_last_bar_time)
        {
         m_last_bar_time = t;
         return true;
        }
      return false;
     }

   datetime          LastBarTime(void) const { return m_last_bar_time; }

   //--- closed bar copy by shift (1 = last closed). Returns false if unavailable.
   bool              GetClosedBar(const int shift, SXareBar &bar) const
     {
      if(shift < 1)
         return false;             // hard look-ahead guard
      datetime t = iTime (m_symbol, m_tf, shift);
      if(t <= 0)
         return false;
      bar.time       = t;
      bar.open       = iOpen (m_symbol, m_tf, shift);
      bar.high       = iHigh (m_symbol, m_tf, shift);
      bar.low        = iLow  (m_symbol, m_tf, shift);
      bar.close      = iClose(m_symbol, m_tf, shift);
      bar.tick_volume= iVolume(m_symbol, m_tf, shift);
      bar.spread     = (long)iSpread(m_symbol, m_tf, shift);
      return (bar.open > 0 && bar.close > 0 && bar.high >= bar.low);
     }

   //--- staleness: how many whole bars behind the newest closed bar are we?
   int               StaleBars(const datetime last_processed) const
     {
      int bars = Bars(m_symbol, m_tf);
      if(bars < 2)
         return 999999;
      datetime newest_closed = iTime(m_symbol, m_tf, 1);
      if(newest_closed <= 0 || last_processed <= 0)
         return 999999;
      long diff = (long)Bars(m_symbol, m_tf, last_processed, newest_closed);
      return (diff < 0) ? 0 : (int)diff;
     }

   //--- live spread in points from current tick; -1 if unavailable
   int               CurrentSpreadPoints(void) const
     {
      long sp = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
      return (sp >= 0) ? (int)sp : -1;
     }

   //--- current bid/ask; false if unavailable
   bool              Quotes(double &bid, double &ask) const
     {
      bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      return (bid > 0 && ask > 0);
     }

   //--- price normalization per broker digits/tick size (§6)
   double            NormalizePrice(const double price) const
     {
      if(m_props.tick_size <= 0)
         return NormalizeDouble(price, m_props.digits);
      double steps = MathRound(price / m_props.tick_size);
      return NormalizeDouble(steps * m_props.tick_size, m_props.digits);
     }
  };

#endif // __XARE_MARKETDATA_MQH__
