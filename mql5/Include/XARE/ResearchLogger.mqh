//+------------------------------------------------------------------+
//| ResearchLogger.mqh — feature/decision CSV export (spec §37)      |
//| v0.13.0 — M13.                                                   |
//|                                                                  |
//| RESEARCH-mode rows: one per closed bar with the FULL feature     |
//| context used for decisions (features only — no future outcomes). |
//| File: MQL5\Files\XARE\research_log.csv (FILE_COMMON).            |
//+------------------------------------------------------------------+
#ifndef __XARE_RESEARCHLOGGER_MQH__
#define __XARE_RESEARCHLOGGER_MQH__

#include "Types.mqh"

class CXareResearchLogger
  {
private:
   bool             m_enabled;
   bool             m_failed;       // latch: stop retrying a broken file
   string           m_path;
   int              m_handle;

public:
                     CXareResearchLogger(void) : m_enabled(false), m_failed(false),
                                                 m_handle(INVALID_HANDLE) {}

   bool              Init(const bool enabled, const string dir)
     {
      m_enabled = enabled;
      if(!m_enabled)
         return true;
      FolderCreate(dir, FILE_COMMON);
      m_path = dir + "\\research_log.csv";
      ResetLastError();
      m_handle = FileOpen(m_path, FILE_READ|FILE_WRITE|FILE_CSV|FILE_SHARE_READ|FILE_COMMON, ',');
      if(m_handle == INVALID_HANDLE)
        {
         m_failed = true;
         PrintFormat("XARE[RES][ERROR] cannot open research CSV '%s' err=%d",
                     m_path, GetLastError());
         return false;
        }
      FileSeek(m_handle, 0, SEEK_END);
      if(FileTell(m_handle) == 0)
         WriteHeader();
      return true;
     }

   void              Deinit(void)
     {
      if(m_handle != INVALID_HANDLE)
        {
         FileClose(m_handle);
         m_handle = INVALID_HANDLE;
        }
     }

   bool              Ready(void) const { return (m_enabled && !m_failed && m_handle != INVALID_HANDLE); }

   void              WriteHeader(void)
     {
      if(!Ready())
         return;
      FileWrite(m_handle,
                "bar_time","symbol","tf_minutes",
                "open","high","low","close","spread_pts","tick_volume",
                "ema_fast","ema_mid","ema_slow","rsi","roc","adx","di_plus","di_minus","atr","atr_pct",
                "regime","regime_conf","mtf_alignment","struct_trend",
                "session","sweep_up","sweep_down","swept_level",
                "bos_bull","bos_bear","choch",
                "signal","setup","direction","setup_conf","score","score_band",
                "risk_state","daily_pl","dd_pct","spread_now",
                "nt_reason","evidence");
     }

   //--- one row per closed bar; inputs are the same verdicts the EA used
   void              Row(const SXareBar &bar, const SXareFeatures &f,
                         const double atr_pct,
                         const SXareRegime &regime, const SXareMTF &mtf,
                         const SXareStructure &st, const SXareSession &sess,
                         const SXareLiquidity &liq,
                         const SXareDecision &dec, const SXareScore &score,
                         const ENUM_XARE_SCORE_BAND band,
                         const SXareRiskSnapshot &risk,
                         const int spread_now, const int tf_minutes)
     {
      if(!Ready())
         return;
      FileWrite(m_handle,
                TimeToString(bar.time, TIME_DATE|TIME_MINUTES),
                _Symbol, IntegerToString(tf_minutes),
                DoubleToString(bar.open, 8), DoubleToString(bar.high, 8),
                DoubleToString(bar.low, 8),  DoubleToString(bar.close, 8),
                IntegerToString((int)bar.spread), IntegerToString((int)bar.tick_volume),
                DoubleToString(f.ema_fast, 8), DoubleToString(f.ema_mid, 8),
                DoubleToString(f.ema_slow, 8), DoubleToString(f.rsi, 3),
                DoubleToString(f.roc, 5), DoubleToString(f.adx, 3),
                DoubleToString(f.di_plus, 3), DoubleToString(f.di_minus, 3),
                DoubleToString(f.atr, 8), DoubleToString(atr_pct, 2),
                XareRegimeToString(regime.regime), IntegerToString(regime.confidence),
                XareAlignmentToString(mtf.alignment),
                XareStructTrendToString(st.trend),
                XareSessionToString(sess.session),
                (liq.sweep_up ? "1" : "0"), (liq.sweep_down ? "1" : "0"),
                DoubleToString(liq.swept_level, 8),
                (st.bos_bull ? "1" : "0"), (st.bos_bear ? "1" : "0"),
                (st.choch ? "1" : "0"),
                (dec.has_signal ? "1" : "0"),
                XareSetupToString(dec.setup),
                IntegerToString(dec.direction),
                DoubleToString(dec.setup_confidence, 1),
                DoubleToString(score.total, 1),
                XareScoreBandToString(band),
                XareRiskStateToString(risk.state),
                DoubleToString(risk.daily_pl, 2),
                DoubleToString(risk.current_dd_pct, 2),
                IntegerToString(spread_now),
                (dec.has_signal ? "" : XareNoTradeToString(dec.nt_reason)),
                dec.evidence);
      FileFlush(m_handle);
     }
  };
#endif // __XARE_RESEARCHLOGGER_MQH__
