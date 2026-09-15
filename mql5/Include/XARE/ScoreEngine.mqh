//+------------------------------------------------------------------+
//| ScoreEngine.mqh — 0–100 weighted score + breakdown (spec §16)     |
//| v0.8.0 — M8.                                                     |
//| PURE module: consumes verdict structs + the decision from M7;    |
//| produces a score with EVERY component's earned/max and a band.   |
//| Weights and band thresholds are configurable hypotheses — the    |
//| defaults are documented in docs/parameters.md, never claimed     |
//| optimal. The score is NOT a probability.                         |
//| Conflicting-information policy (documented): a MIXED alignment   |
//| scores 0 on the MTF component; a counter-trend setup (range or   |
//| sweep reversal) earns trend points only from structure, not from |
//| the MTF direction — conflict always costs points.                |
//+------------------------------------------------------------------+
#ifndef __XARE_SCOREENGINE_MQH__
#define __XARE_SCOREENGINE_MQH__

#include "Types.mqh"
#include "Config.mqh"

//--- pure band classifier (unit-testable)
ENUM_XARE_SCORE_BAND XareScoreBand(const double score,
                                   const double min_score,
                                   const double candidate,
                                   const double trade,
                                   const double strong)
  {
   if(score < min_score) return XARE_BAND_NONE;
   if(score < candidate) return XARE_BAND_CANDIDATE;
   if(score < trade)     return XARE_BAND_TRADE;
   return XARE_BAND_STRONG;
  }

//--- pure weight-sum validator (SELF_TEST + init sanity)
bool XareWeightsValid(const double wt, const double wm, const double ws,
                      const double wmo, const double wl, const double wv,
                      const double wse, const double wsu,
                      const double tolerance = 0.01)
  {
   double sum = wt + wm + ws + wmo + wl + wv + wse + wsu;
   return (MathAbs(sum - 100.0) <= tolerance);
  }

class CXareScoreEngine
  {
private:
   SXareConfig      m_cfg;
   SXareScore       m_last;

   void              Set(SXareScoreComponent &c, const double earned,
                         const double max, const string note)
     {
      c.earned = MathMax(0.0, MathMin(earned, max));
      c.max    = max;
      c.note   = note;
     }

   //--- trend component: EMA stack + DI agreement with setup direction
   double            TrendEarned(const int dir, const SXareFeatures &f,
                                 const bool counter_trend) const
     {
      if(counter_trend)
         return 0.25 * m_cfg.w_trend;   // fighting the stack: small credit only
      bool stack_ok = (dir > 0)
         ? (f.ema_fast > f.ema_mid && f.ema_mid > f.ema_slow)
         : (f.ema_fast < f.ema_mid && f.ema_mid < f.ema_slow);
      bool di_ok = (dir > 0) ? (f.di_plus > f.di_minus) : (f.di_minus > f.di_plus);
      return (stack_ok ? 0.65 : 0.0) * m_cfg.w_trend + (di_ok ? 0.35 : 0.0) * m_cfg.w_trend;
     }

   //--- MTF component: alignment vs direction; MIXED scores zero
   double            MtfEarned(const int dir, const SXareMTF &mtf) const
     {
      if(mtf.alignment == XARE_ALIGN_MIXED)
         return 0.0;
      bool matches = (dir > 0) ? (mtf.alignment == XARE_ALIGN_BULLISH)
                               : (mtf.alignment == XARE_ALIGN_BEARISH);
      if(matches)
         return m_cfg.w_mtf;
      if(mtf.alignment == XARE_ALIGN_NEUTRAL)
         return 0.35 * m_cfg.w_mtf;     // neutral allows counter setups: partial
      return 0.0;                       // alignment opposes direction
     }

   //--- structure component: swing trend + recency of BOS support
   double            StructureEarned(const int dir, const SXareStructure &st) const
     {
      bool bull = (dir > 0);
      double pts = 0.0;
      if(st.trend == (bull ? XARE_STRUCT_BULLISH : XARE_STRUCT_BEARISH))
         pts += 0.7 * m_cfg.w_structure;
      else if(st.trend == XARE_STRUCT_NEUTRAL)
         pts += 0.3 * m_cfg.w_structure;
      // else MIXED/against: 0
      bool bos_supports = (bull ? st.bos_bull : st.bos_bear);
      if(bos_supports)
         pts += 0.3 * m_cfg.w_structure;
      return pts;
     }

   //--- momentum: ROC sign/strength + RSI positioned for the direction
   double            MomentumEarned(const int dir, const SXareFeatures &f) const
     {
      bool bull = (dir > 0);
      double pts = 0.0;
      double roc = bull ? f.roc : -f.roc;
      if(roc > 0.0)                          pts += 0.4 * m_cfg.w_momentum;
      if(roc > 0.25)                         pts += 0.2 * m_cfg.w_momentum;
      double rsi = bull ? f.rsi : (100.0 - f.rsi);
      if(rsi > 45.0 && rsi < 70.0)           pts += 0.4 * m_cfg.w_momentum;
      return pts;
     }

   //--- liquidity: sweep events supporting the direction
   double            LiquidityEarned(const int dir, const SXareLiquidity &liq) const
     {
      bool bull = (dir > 0);
      bool swept = (bull ? liq.sweep_down : liq.sweep_up);
      if(swept)
         return m_cfg.w_liquidity * (0.6 + 0.4 * MathMin(liq.penetration_atr, 1.0));
      return 0.0;
     }

   //--- volatility: ATR percentile relative to config comfort zone
   double            VolatilityEarned(const double atr_pct) const
     {
      if(atr_pct < 0.0)
         return 0.5 * m_cfg.w_volatility;  // unknown: neutral credit, logged
      if(atr_pct >= 20.0 && atr_pct <= 80.0)
         return m_cfg.w_volatility;        // normal band: full credit
      if(atr_pct < 20.0)
         return 0.4 * m_cfg.w_volatility;  // dead tape
      return 0.2 * m_cfg.w_volatility;     // extreme vol: risk-off discount
     }

   //--- session: overlap > london/ny > asian/off
   double            SessionEarned(const ENUM_XARE_SESSION s) const
     {
      switch(s)
        {
         case XARE_SESS_OVERLAP: return m_cfg.w_session;
         case XARE_SESS_LONDON:
         case XARE_SESS_NEWYORK: return 0.7 * m_cfg.w_session;
         case XARE_SESS_ASIAN:   return 0.3 * m_cfg.w_session;
         default:                return 0.0;
        }
     }

   //--- setup quality: confidence mapped into the setup weight
   double            SetupEarned(const double setup_confidence) const
     {
      return m_cfg.w_setup * MathMax(0.0, MathMin(setup_confidence, 100.0)) / 100.0;
     }

public:
                     CXareScoreEngine(void)
     {
      XareConfigDefaults(m_cfg);
      ZeroMemory(m_last);
     }

   void              Init(const SXareConfig &cfg) { m_cfg = cfg; }

   //--- explicit reset (SXareScore contains strings; never ZeroMemory those)
   void              ResetScore(SXareScore &s)
     {
      s.total = 0.0;
      Set(s.trend, 0, 0, "");
      Set(s.mtf, 0, 0, "");
      Set(s.structure, 0, 0, "");
      Set(s.momentum, 0, 0, "");
      Set(s.liquidity, 0, 0, "");
      Set(s.volatility, 0, 0, "");
      Set(s.session, 0, 0, "");
      Set(s.setup, 0, 0, "");
     }

   //--- PURE scoring. atr_pct: ATR percentile from RegimeEngine context
   //--- (-1 when unavailable). Evidence chain comes from the decision.
   bool              Score(const SXareDecision &dec, const SXareFeatures &f,
                           const SXareMTF &mtf, const SXareStructure &st,
                           const SXareLiquidity &liq, const ENUM_XARE_SESSION session,
                           const double atr_pct, SXareScore &out)
     {
      ResetScore(out);

      if(!dec.has_signal || dec.direction == 0)
        {
         m_last = out;
         return false;                     // nothing to score
        }

      bool counter_trend = (dec.setup == XARE_SETUP_RANGE_REVERSAL ||
                            dec.setup == XARE_SETUP_LIQUIDITY_SWEEP_REVERSAL);
      int dir = dec.direction;

      Set(out.trend,      TrendEarned(dir, f, counter_trend),      m_cfg.w_trend,
          counter_trend ? "counter-trend setup: reduced credit" : "EMA stack + DI vs direction");
      Set(out.mtf,        MtfEarned(dir, mtf),                     m_cfg.w_mtf,
          XareAlignmentToString(mtf.alignment));
      Set(out.structure,  StructureEarned(dir, st),                m_cfg.w_structure,
          XareStructTrendToString(st.trend));
      Set(out.momentum,   MomentumEarned(dir, f),                  m_cfg.w_momentum,
          StringFormat("roc=%.2f rsi=%.1f", f.roc, f.rsi));
      Set(out.liquidity,  LiquidityEarned(dir, liq),               m_cfg.w_liquidity,
          liq.sweep_up || liq.sweep_down ? liq.level_name : "no supporting sweep");
      Set(out.volatility, VolatilityEarned(atr_pct),               m_cfg.w_volatility,
          (atr_pct < 0.0) ? "atr percentile unavailable" :
          StringFormat("atr_pct=%.0f", atr_pct));
      Set(out.session,    SessionEarned(session),                  m_cfg.w_session,
          XareSessionToString(session));
      Set(out.setup,      SetupEarned(dec.setup_confidence),       m_cfg.w_setup,
          XareSetupToString(dec.setup));

      out.total = out.trend.earned + out.mtf.earned + out.structure.earned +
                  out.momentum.earned + out.liquidity.earned +
                  out.volatility.earned + out.session.earned + out.setup.earned;
      out.total = MathMax(0.0, MathMin(100.0, out.total));
      m_last = out;
      return true;
     }

   bool              Last(SXareScore &out) const
     {
      out = m_last;
      return (out.total > 0.0 || out.trend.max > 0.0);
     }

   //--- band for a score using config thresholds
   ENUM_XARE_SCORE_BAND Band(const double score) const
     {
      return XareScoreBand(score, m_cfg.score_min, m_cfg.score_candidate,
                           m_cfg.score_trade, m_cfg.score_strong);
     }
  };

#endif // __XARE_SCOREENGINE_MQH__
