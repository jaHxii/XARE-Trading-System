//+------------------------------------------------------------------+
//| MultiTimeframe.mqh — H4/H1/execution-TF alignment (spec §8)       |
//| v0.3.0 — M3.                                                     |
//| Label rule (objective, documented): BULL if EMA20>EMA50 and      |
//| close>EMA50; BEAR if EMA20<EMA50 and close<EMA50; else NEUTRAL.  |
//| Alignment: all equal → BULLISH/BEARISH; any disagreement → MIXED |
//| (conflict suppresses trend setups; never forced into a trade).   |
//+------------------------------------------------------------------+
#ifndef __XARE_MULTITIMEFRAME_MQH__
#define __XARE_MULTITIMEFRAME_MQH__

#include "Types.mqh"
#include "Config.mqh"
#include "Logger.mqh"

//--- per-TF context: two EMA handles + close, read at shift>=1
class CXareTFContext
  {
private:
   string           m_symbol;
   ENUM_TIMEFRAMES  m_tf;
   int              m_h_ema_fast;
   int              m_h_ema_mid;

public:
                     CXareTFContext(void) : m_symbol(""), m_tf(PERIOD_CURRENT),
                                            m_h_ema_fast(INVALID_HANDLE),
                                            m_h_ema_mid(INVALID_HANDLE) {}

   bool              Init(const string symbol, const ENUM_TIMEFRAMES tf,
                          const int fast_period, const int mid_period)
     {
      m_symbol     = symbol;
      m_tf         = tf;
      m_h_ema_fast = iMA(symbol, tf, fast_period, 0, MODE_EMA, PRICE_CLOSE);
      m_h_ema_mid  = iMA(symbol, tf, mid_period,  0, MODE_EMA, PRICE_CLOSE);
      return (m_h_ema_fast != INVALID_HANDLE && m_h_ema_mid != INVALID_HANDLE);
     }

   void              Release(void)
     {
      if(m_h_ema_fast != INVALID_HANDLE) { IndicatorRelease(m_h_ema_fast); m_h_ema_fast = INVALID_HANDLE; }
      if(m_h_ema_mid  != INVALID_HANDLE) { IndicatorRelease(m_h_ema_mid);  m_h_ema_mid  = INVALID_HANDLE; }
     }

   bool              Label(const int shift, ENUM_XARE_TF_LABEL &out) const
     {
      if(shift < 1)
         return false;
      double ef, em, close;
      double bf[1], bm[1], bc[1];
      if(CopyBuffer(m_h_ema_fast, 0, shift, 1, bf) != 1) return false;
      if(CopyBuffer(m_h_ema_mid,  0, shift, 1, bm) != 1) return false;
      close = iClose(m_symbol, m_tf, shift);
      if(close <= 0) return false;
      ef = bf[0]; em = bm[0];
      if(ef <= 0 || em <= 0 || ef == EMPTY_VALUE || em == EMPTY_VALUE)
         return false;
      if(ef > em && close > em)  out = XARE_TF_BULL;
      else if(ef < em && close < em) out = XARE_TF_BEAR;
      else                       out = XARE_TF_NEUTRAL;
      return true;
     }
  };

class CXareMultiTimeframe
  {
private:
   CXareTFContext   m_h4;             // macro
   CXareTFContext   m_h1;             // intermediate
   string           m_symbol;
   ENUM_TIMEFRAMES  m_exec_tf;
   SXareMTF         m_last;
   CXareLogger     *m_log;

   //--- pure alignment classification from three labels (testable logic)
   ENUM_XARE_ALIGNMENT Classify(const ENUM_XARE_TF_LABEL a,
                                const ENUM_XARE_TF_LABEL b,
                                const ENUM_XARE_TF_LABEL c) const
     {
      if(a == XARE_TF_NEUTRAL || b == XARE_TF_NEUTRAL || c == XARE_TF_NEUTRAL)
         return XARE_ALIGN_NEUTRAL;
      if(a == b && b == c)
         return (a == XARE_TF_BULL) ? XARE_ALIGN_BULLISH : XARE_ALIGN_BEARISH;
      return XARE_ALIGN_MIXED;
     }

   string            LabelStr(const ENUM_XARE_TF_LABEL l) const
     {
      switch(l)
        {
         case XARE_TF_BULL: return "BULL";
         case XARE_TF_BEAR: return "BEAR";
         default:           return "NEUTRAL";
        }
     }

public:
                     CXareMultiTimeframe(void) : m_symbol(""), m_exec_tf(PERIOD_CURRENT),
                                                 m_log(NULL)
     {
      ZeroMemory(m_last);
     }

   bool              Init(const string symbol, const ENUM_TIMEFRAMES exec_tf,
                          const SXareConfig &cfg, CXareLogger *log)
     {
      m_symbol  = symbol;
      m_exec_tf = exec_tf;
      m_log     = log;
      if(!m_h4.Init(symbol, PERIOD_H4, cfg.ema_fast_period, cfg.ema_mid_period))
         return false;
      if(!m_h1.Init(symbol, PERIOD_H1, cfg.ema_fast_period, cfg.ema_mid_period))
        {
         m_h4.Release();
         return false;
        }
      return true;
     }

   void              Release(void)
     {
      m_h4.Release();
      m_h1.Release();
     }

   //--- evaluate alignment for the closed bars at 'shift' on each TF.
   //--- Execution-TF label may be supplied by the caller (single handle set);
   //--- otherwise computed here from the chart TF context.
   bool              Evaluate(const int shift, const ENUM_XARE_TF_LABEL exec_label,
                              SXareMTF &out)
     {
      out.valid = false;
      ENUM_XARE_TF_LABEL h4, h1;
      if(!m_h4.Label(shift, h4))  { m_last = out; return false; }
      if(!m_h1.Label(shift, h1))  { m_last = out; return false; }

      out.h4          = h4;
      out.h1          = h1;
      out.exec        = exec_label;
      out.alignment   = Classify(h4, h1, exec_label);
      out.evaluated_at= TimeCurrent();
      out.evidence    = StringFormat("H4=%s H1=%s %s=%s",
                                     LabelStr(h4), LabelStr(h1),
                                     g_tf_alias(m_exec_tf), LabelStr(exec_label));
      out.valid       = true;
      m_last          = out;
      if(m_log != NULL)
         m_log.Debug("MTF", out.evidence);   // MQL5: dot access works on object pointers
      return true;
     }

   bool              Last(SXareMTF &out) const
     {
      if(!m_last.valid)
         return false;
      out = m_last;
      return true;
     }

   //--- pure classifier exposed for self-tests
   static ENUM_XARE_ALIGNMENT ClassifyStatic(const ENUM_XARE_TF_LABEL a,
                                             const ENUM_XARE_TF_LABEL b,
                                             const ENUM_XARE_TF_LABEL c)
     {
      if(a == XARE_TF_NEUTRAL || b == XARE_TF_NEUTRAL || c == XARE_TF_NEUTRAL)
         return XARE_ALIGN_NEUTRAL;
      if(a == b && b == c)
         return (a == XARE_TF_BULL) ? XARE_ALIGN_BULLISH : XARE_ALIGN_BEARISH;
      return XARE_ALIGN_MIXED;
     }
  };

//--- small helper: TF alias for evidence strings
string g_tf_alias(const ENUM_TIMEFRAMES tf)
  {
   switch(tf)
     {
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      default:         return EnumToString(tf);
     }
  }

#endif // __XARE_MULTITIMEFRAME_MQH__
