//+------------------------------------------------------------------+
//| Indicators.mqh — feature layer (§7). Indicators are FEATURES.    |
//| v0.2.0 — M2: EMA20/50/200, RSI, ROC, ADX(+DI/-DI), ATR.          |
//| Handles are created once at Init, reused every bar, released at  |
//| Deinit (§64). Reads target shift>=1 (closed bars) by default.    |
//+------------------------------------------------------------------+
#ifndef __XARE_INDICATORS_MQH__
#define __XARE_INDICATORS_MQH__

#include "Types.mqh"
#include "Config.mqh"
#include "MarketData.mqh"

//--- pure helpers: unit-testable math, no terminal state
// Rate of Change in percent
double XareRateOfChange(const double now, const double before)
  {
   if(before <= 0.0)
      return 0.0;
   return (now - before) / before * 100.0;
  }

class CXareIndicators
  {
private:
   string           m_symbol;
   ENUM_TIMEFRAMES  m_tf;
   int              m_h_ema_fast;
   int              m_h_ema_mid;
   int              m_h_ema_slow;
   int              m_h_rsi;
   int              m_h_adx;
   int              m_h_atr;
   int              m_roc_period;
   SXareFeatures    m_cache;
   bool             m_have_features;   // m_cache holds a valid snapshot

   //--- read one buffer value; returns false on any failure (never guesses)
   bool              ReadBuffer(const int handle, const int buffer,
                                const int shift, double &out) const
     {
      if(handle == INVALID_HANDLE)
         return false;
      if(shift < 1)                    // hard look-ahead guard
         return false;
      double buf[1];
      ResetLastError();
      if(CopyBuffer(handle, buffer, shift, 1, buf) != 1)
         return false;
      out = buf[0];
      return true;                     // EMPTY_VALUE check left to caller context
     }

public:
                     CXareIndicators(void) : m_symbol(""), m_tf(PERIOD_CURRENT),
                                             m_h_ema_fast(INVALID_HANDLE),
                                             m_h_ema_mid(INVALID_HANDLE),
                                             m_h_ema_slow(INVALID_HANDLE),
                                             m_h_rsi(INVALID_HANDLE),
                                             m_h_adx(INVALID_HANDLE),
                                             m_h_atr(INVALID_HANDLE),
                                             m_roc_period(10),
                                             m_have_features(false)
     {
      ZeroMemory(m_cache);
     }

   bool              Init(const string symbol, const ENUM_TIMEFRAMES tf,
                          const SXareConfig &cfg)
     {
      m_symbol     = symbol;
      m_tf         = tf;
      m_roc_period = cfg.roc_period;

      m_h_ema_fast = iMA (symbol, tf, cfg.ema_fast_period, 0, MODE_EMA, PRICE_CLOSE);
      m_h_ema_mid  = iMA (symbol, tf, cfg.ema_mid_period,  0, MODE_EMA, PRICE_CLOSE);
      m_h_ema_slow = iMA (symbol, tf, cfg.ema_slow_period, 0, MODE_EMA, PRICE_CLOSE);
      m_h_rsi      = iRSI(symbol, tf, cfg.rsi_period, PRICE_CLOSE);
      m_h_adx      = iADX(symbol, tf, cfg.adx_period);
      m_h_atr      = iATR(symbol, tf, cfg.atr_period);

      if(m_h_ema_fast==INVALID_HANDLE || m_h_ema_mid==INVALID_HANDLE ||
         m_h_ema_slow==INVALID_HANDLE || m_h_rsi==INVALID_HANDLE  ||
         m_h_adx==INVALID_HANDLE        || m_h_atr==INVALID_HANDLE)
        {
         PrintFormat("XARE[IND][ERROR] indicator handle creation failed err=%d", GetLastError());
         Release();
         return false;
        }
      return true;
     }

   void              Release(void)
     {
      if(m_h_ema_fast != INVALID_HANDLE) { IndicatorRelease(m_h_ema_fast); m_h_ema_fast = INVALID_HANDLE; }
      if(m_h_ema_mid  != INVALID_HANDLE) { IndicatorRelease(m_h_ema_mid);  m_h_ema_mid  = INVALID_HANDLE; }
      if(m_h_ema_slow != INVALID_HANDLE) { IndicatorRelease(m_h_ema_slow); m_h_ema_slow = INVALID_HANDLE; }
      if(m_h_rsi      != INVALID_HANDLE) { IndicatorRelease(m_h_rsi);       m_h_rsi      = INVALID_HANDLE; }
      if(m_h_adx      != INVALID_HANDLE) { IndicatorRelease(m_h_adx);       m_h_adx      = INVALID_HANDLE; }
      if(m_h_atr      != INVALID_HANDLE) { IndicatorRelease(m_h_atr);       m_h_atr      = INVALID_HANDLE; }
     }

   //--- refresh features for the closed bar at 'shift' (>=1); copy-out result
   bool              Update(const int shift, SXareFeatures &out)
     {
      m_have_features = false;
      out.valid   = false;
      out.bar_time= iTime(m_symbol, m_tf, (shift >= 1 ? shift : 1));
      m_have_features = false;

      bool ok = true;
      ok = ReadBuffer(m_h_ema_fast, 0, shift, out.ema_fast) && ok;
      ok = ReadBuffer(m_h_ema_mid,  0, shift, out.ema_mid)  && ok;
      ok = ReadBuffer(m_h_ema_slow, 0, shift, out.ema_slow) && ok;
      ok = ReadBuffer(m_h_rsi,      0, shift, out.rsi)      && ok;
      ok = ReadBuffer(m_h_adx,      0, shift, out.adx)       && ok;  // MAIN_LINE
      ok = ReadBuffer(m_h_adx,      1, shift, out.di_plus)   && ok;  // PLUSDI_LINE
      ok = ReadBuffer(m_h_adx,      2, shift, out.di_minus)  && ok;  // MINUSDI_LINE
      ok = ReadBuffer(m_h_atr,      0, shift, out.atr)       && ok;

      // Rate of Change from closed closes: (C[t] - C[t-n]) / C[t-n] * 100
      if(ok)
        {
         double c_now  = iClose(m_symbol, m_tf, shift);
         double c_prev = iClose(m_symbol, m_tf, shift + m_roc_period);
         if(c_prev > 0 && c_now > 0)
            out.roc = XareRateOfChange(c_now, c_prev);
         else
            ok = false;
        }

      if(ok && out.bar_time > 0 && out.ema_slow > 0 && out.ema_slow != EMPTY_VALUE)
        {
         out.valid        = true;
         m_have_features  = true;
        }
      return out.valid;
     }

   //--- last successfully refreshed features (copy-out; MQL5-safe)
   bool              Last(SXareFeatures &out) const
     {
      if(!m_have_features)
         return false;
      out = m_cache;
      return true;
     }
  };

#endif // __XARE_INDICATORS_MQH__
