//+------------------------------------------------------------------+
//| SignalEngine.mqh — setup detectors (spec §15)                     |
//| v0.7.0 — M7.                                                     |
//| PURE module: decision math performs no terminal calls; all       |
//| context arrives as verdict structs (M2–M6 outputs).              |
//|                                                                  |
//| Gate order (first match wins):                                   |
//|   1. insufficient data  → NT_INSUFFICIENT_DATA                   |
//|   2. regime incompatible→ NT_REGIME_INCOMPATIBLE                 |
//|   3. regime confidence  → NT_REGIME_CONFIDENCE                   |
//|   4. MIXED alignment    → NT_ALIGNMENT_CONFLICT (blocks all)     |
//|   5. detectors          → candidate or NT_NO_SETUP_TRIGGER       |
//| Direction policy (documented): trend/breakout setups follow the  |
//| MTF alignment; NEUTRAL alignment permits only counter-move       |
//| setups (range reversal, sweep reversal), whose direction comes   |
//| from the event itself, not from alignment.                       |
//| Detector priority (hypothesis, docs/strategy.md): sweep reversal |
//| > range reversal > breakout retest > breakout > pullback >       |
//| continuation.                                                    |
//+------------------------------------------------------------------+
#ifndef __XARE_SIGNALENGINE_MQH__
#define __XARE_SIGNALENGINE_MQH__

#include "Types.mqh"
#include "Config.mqh"

//--- explicit reset (struct contains strings; never ZeroMemory those)
void XareResetDecision(SXareDecision &d)
  {
   d.has_signal       = false;
   d.nt_reason        = XARE_NT_NONE;
   d.direction        = 0;
   d.setup            = XARE_SETUP_NONE;
   d.setup_confidence = 0.0;
   d.entry_lo         = 0.0;
   d.entry_hi         = 0.0;
   d.invalidation     = "";
   d.evidence         = "";
   d.bar_time         = 0;
  }

//--- pure helpers (unit-testable, no state) ---------------------------
// Pullback zone around the EMA20/50 band, half-width = zone_atr * ATR
void XarePullbackZone(const double ema_fast, const double ema_mid,
                      const double atr, const double zone_atr,
                      double &zone_lo, double &zone_hi)
  {
   double lo = MathMin(ema_fast, ema_mid);
   double hi = MathMax(ema_fast, ema_mid);
   double w  = zone_atr * atr * 0.5;
   zone_lo = lo - w;
   zone_hi = hi + w;
  }

// BREAKOUT_RETEST pure core: a BOS happened 'bars_since' bars ago at 'level';
// the current bar revisits the edge and rejects back on the breakout side.
bool XareRetestTrigger(const int bos_direction, const double bos_level,
                       const int bars_since_bos, const int retest_valid_bars,
                       const double bar_low, const double bar_high,
                       const double bar_close, const double atr,
                       double &confidence)
  {
   confidence = 0.0;
   if(bos_direction == 0 || bos_level <= 0 || bars_since_bos < 1 ||
      bars_since_bos > retest_valid_bars || atr <= 0)
      return false;
   double tol = 0.25 * atr;                 // revisit tolerance (hypothesis)
   if(bos_direction > 0)
     {
      if(bar_low <= bos_level + tol && bar_close > bos_level)
        {
         confidence = 60.0 + (bars_since_bos <= 3 ? 10.0 : 0.0);
         return true;
        }
     }
   else
     {
      if(bar_high >= bos_level - tol && bar_close < bos_level)
        {
         confidence = 60.0 + (bars_since_bos <= 3 ? 10.0 : 0.0);
         return true;
        }
     }
   return false;
  }

class CXareSignalEngine
  {
private:
   SXareConfig      m_cfg;
   //--- minimal cross-bar memory for BREAKOUT_RETEST (last BOS not yet retested)
   int              m_bos_dir;          // 0 none, +1 bull, -1 bear
   double           m_bos_level;
   datetime         m_bos_time;
   SXareDecision    m_last;

   bool              Enabled(const ENUM_XARE_SETUP s) const
     {
      switch(s)
        {
         case XARE_SETUP_TREND_CONTINUATION:       return m_cfg.setup_trend_continuation;
         case XARE_SETUP_TREND_PULLBACK:           return m_cfg.setup_trend_pullback;
         case XARE_SETUP_BREAKOUT:                 return m_cfg.setup_breakout;
         case XARE_SETUP_BREAKOUT_RETEST:          return m_cfg.setup_breakout_retest;
         case XARE_SETUP_RANGE_REVERSAL:           return m_cfg.setup_range_reversal;
         case XARE_SETUP_LIQUIDITY_SWEEP_REVERSAL: return m_cfg.setup_liquidity_sweep_reversal;
         default:                                  return false;
        }
     }

   //--- detectors: fill candidate, return true on match ------------------
   bool              DetTrendContinuation(const int dir, const SXareFeatures &f,
                                          const SXareBar &bar, const double prev_roc,
                                          const SXareStructure &st,
                                          SXareDecision &c) const
     {
      bool bull = (dir > 0);
      if(!(bull ? st.trend == XARE_STRUCT_BULLISH : st.trend == XARE_STRUCT_BEARISH))
         return false;
      if(!(bull ? (f.roc > 0.0 && f.roc > prev_roc)
                : (f.roc < 0.0 && f.roc < prev_roc)))
         return false;
      if(!(bull ? bar.close > f.ema_mid : bar.close < f.ema_mid))
         return false;
      c.direction        = dir;
      c.setup            = XARE_SETUP_TREND_CONTINUATION;
      c.setup_confidence = 60.0 + (bull ? (f.di_plus > f.di_minus ? 10.0 : 0.0)
                                        : (f.di_minus > f.di_plus ? 10.0 : 0.0));
      c.entry_lo         = f.ema_fast;
      c.entry_hi         = bar.close;
      c.invalidation     = StringFormat("close beyond EMA50 %s against trend",
                            DoubleToString(f.ema_mid, 2));
      c.evidence         = StringFormat("structure %s, roc %.2f→%.2f re-accel, DI %s",
                            bull ? "BULL" : "BEAR", prev_roc, f.roc,
                            bull ? (f.di_plus > f.di_minus ? "+" : "-")
                                 : (f.di_minus > f.di_plus ? "-" : "+"));
      return true;
     }

   bool              DetTrendPullback(const int dir, const SXareFeatures &f,
                                      const SXareBar &bar, const double atr,
                                      SXareDecision &c) const
     {
      bool bull = (dir > 0);
      double zlo, zhi;
      XarePullbackZone(f.ema_fast, f.ema_mid, atr, m_cfg.pullback_ema_zone_atr, zlo, zhi);
      bool touched = (bull ? (bar.low <= zhi) : (bar.high >= zlo));
      bool rejected= (bull ? (bar.close > bar.open && bar.close > f.ema_fast)
                           : (bar.close < bar.open && bar.close < f.ema_fast));
      bool rsi_ok  = (bull ? (f.rsi > 40.0 && f.rsi < 70.0)
                           : (f.rsi > 30.0 && f.rsi < 60.0));
      if(!(touched && rejected && rsi_ok))
         return false;
      c.direction        = dir;
      c.setup            = XARE_SETUP_TREND_PULLBACK;
      c.setup_confidence = 65.0 + (bull ? (f.rsi < 55.0 ? 5.0 : 0.0)
                                        : (f.rsi > 45.0 ? 5.0 : 0.0));
      c.entry_lo         = zlo;
      c.entry_hi         = zhi;
      c.invalidation     = StringFormat("close beyond zone %s..%s against trend",
                            DoubleToString(zlo,2), DoubleToString(zhi,2));
      c.evidence         = StringFormat("pullback into EMA zone %s..%s, %s rejection, rsi %.1f",
                            DoubleToString(zlo,2), DoubleToString(zhi,2),
                            bull ? "bullish" : "bearish", f.rsi);
      return true;
     }

   bool              DetBreakout(const int dir, const SXareBar &bar,
                                 const SXareStructure &st, const double atr,
                                 SXareDecision &c) const
     {
      bool bull = (dir > 0);
      bool bos  = (bull ? st.bos_bull : st.bos_bear);
      if(!bos)
         return false;
      double level  = (bull ? st.last_swing_high : st.last_swing_low);
      double beyond = (bull ? (bar.close - level) : (level - bar.close));
      if(beyond < 0.10 * atr)
         return false;
      c.direction        = dir;
      c.setup            = XARE_SETUP_BREAKOUT;
      c.setup_confidence = 60.0 + (beyond >= 0.25*atr ? 10.0 : 0.0);
      c.entry_lo         = level;
      c.entry_hi         = bar.close;
      c.invalidation     = StringFormat("close back inside %s voids breakout",
                            DoubleToString(level, 2));
      c.evidence         = StringFormat("BOS %s level %s by %.2f (%.2f ATR)",
                            bull ? "above" : "below", DoubleToString(level,2),
                            beyond, beyond/atr);
      return true;
     }

   bool              DetRangeReversal(const int dir, const SXareBar &bar,
                                      const SXareStructure &st, const double atr,
                                      SXareDecision &c) const
     {
      bool bull = (dir > 0);
      double sup = st.last_swing_low, res = st.last_swing_high;
      if(sup <= 0 || res <= 0 || res <= sup)
         return false;
      double edge = 0.10 * atr;
      bool at_support  = (bull && bar.low  <= sup + edge && bar.close > sup);
      bool at_resist   = (!bull && bar.high >= res - edge && bar.close < res);
      bool reject_cndl = (bull ? bar.close > bar.open : bar.close < bar.open);
      if(!((at_support || at_resist) && reject_cndl))
         return false;
      c.direction        = dir;
      c.setup            = XARE_SETUP_RANGE_REVERSAL;
      c.setup_confidence = 55.0;
      c.entry_lo         = bull ? sup : res;
      c.entry_hi         = bull ? sup + edge : res - edge;
      c.invalidation     = StringFormat("close beyond %s kills the range",
                            DoubleToString(bull ? sup : res, 2));
      c.evidence         = StringFormat("range rejection at %s %s",
                            bull ? "support" : "resistance",
                            DoubleToString(bull ? sup : res, 2));
      return true;
     }

   bool              DetSweepReversal(const int dir, const SXareLiquidity &liq,
                                      SXareDecision &c) const
     {
      bool bull = (dir > 0);
      bool swept = (bull ? liq.sweep_down : liq.sweep_up); // sellside swept → long
      if(!swept)
         return false;
      double q = MathMin(liq.penetration_atr, 1.0);
      c.direction        = dir;
      c.setup            = XARE_SETUP_LIQUIDITY_SWEEP_REVERSAL;
      c.setup_confidence = 55.0 + 15.0 * q;
      c.entry_lo         = liq.swept_level;
      c.entry_hi         = liq.swept_level + (bull ? 0.25 : -0.25);
      c.invalidation     = StringFormat("close beyond swept %s (%s) voids reclaim",
                            liq.level_name, DoubleToString(liq.swept_level, 2));
      c.evidence         = StringFormat("%s swept and reclaimed (depth %.2f ATR)",
                            liq.level_name, liq.penetration_atr);
      return true;
     }

public:
                     CXareSignalEngine(void) : m_bos_dir(0),
                                               m_bos_level(0.0), m_bos_time(0)
     {
      XareConfigDefaults(m_cfg);
      XareResetDecision(m_last);
     }

   void              Init(const SXareConfig &cfg) { m_cfg = cfg; }

   //--- test hook: inject BOS memory deterministically
   void              SetBosState(const int dir, const double level, const datetime t)
     {
      m_bos_dir = dir; m_bos_level = level; m_bos_time = t;
     }

   //--- PURE evaluation. prev_roc = ROC at shift 2 (caller-computed).
   bool              Evaluate(const SXareRegime &regime, const SXareMTF &mtf,
                              const SXareStructure &st, const SXareSession &session,
                              const SXareLiquidity &liq, const SXareBar &bar,
                              const SXareFeatures &f, const double prev_roc,
                              SXareDecision &out)
     {
      XareResetDecision(out);
      out.bar_time = f.bar_time;

      // --- gate 1: insufficient data ----------------------------------
      if(!regime.valid || !mtf.valid || !st.valid || !f.valid || bar.close <= 0)
        {
         out.nt_reason = XARE_NT_INSUFFICIENT_DATA;
         out.evidence  = "one or more context verdicts invalid";
         m_last = out;
         return true;
        }

      // --- gate 2: regime compatibility --------------------------------
      if(regime.regime == XARE_REGIME_UNSAFE ||
         regime.regime == XARE_REGIME_UNKNOWN ||
         regime.regime == XARE_REGIME_HIGH_VOLATILITY ||
         regime.regime == XARE_REGIME_LOW_VOLATILITY)
        {
         out.nt_reason = XARE_NT_REGIME_INCOMPATIBLE;
         out.evidence  = StringFormat("regime %s offers no setup precondition",
                         XareRegimeToString(regime.regime));
         m_last = out;
         return true;
        }

      // --- gate 3: regime confidence floor ------------------------------
      if(regime.confidence < m_cfg.regime_conf_min)
        {
         out.nt_reason = XARE_NT_REGIME_CONFIDENCE;
         out.evidence  = StringFormat("regime conf %d < min %d",
                         regime.confidence, m_cfg.regime_conf_min);
         m_last = out;
         return true;
        }

      // --- gate 4: alignment conflict (MIXED blocks everything) ---------
      if(mtf.alignment == XARE_ALIGN_MIXED)
        {
         out.nt_reason = XARE_NT_ALIGNMENT_CONFLICT;
         out.evidence  = StringFormat("MTF MIXED (%s)", mtf.evidence);
         m_last = out;
         return true;
        }

      bool dir_ok_bull = (mtf.alignment == XARE_ALIGN_BULLISH);
      bool dir_ok_bear = (mtf.alignment == XARE_ALIGN_BEARISH);
      bool neutral_ok  = (mtf.alignment == XARE_ALIGN_NEUTRAL); // counter setups only
      double atr = f.atr;

      // --- BOS memory snapshot (retest consumes PREVIOUS BOS) -----------
      int  bos_dir_now = 0;
      double bos_lvl_now = 0.0;
      if(st.bos_bull)      { bos_dir_now = +1; bos_lvl_now = st.last_swing_high; }
      else if(st.bos_bear) { bos_dir_now = -1; bos_lvl_now = st.last_swing_low;  }
      int bars_since_bos = 0;
      if(m_bos_dir != 0 && m_bos_time > 0 && bar.time > m_bos_time)
         bars_since_bos = (int)((bar.time - m_bos_time) / PeriodSeconds());

      // --- detector chain (priority order) ------------------------------
      SXareDecision cand;
      XareResetDecision(cand);
      bool matched_disabled = false;
      ENUM_XARE_SETUP disabled_setup = XARE_SETUP_NONE;
      bool attempted = false;

      // 1) liquidity sweep reversal — direction from the event
      if(dir_ok_bull || dir_ok_bear || neutral_ok)
        {
         int dir = 0;
         SXareDecision t; XareResetDecision(t);
         if(DetSweepReversal(+1, liq, t)) dir = +1;
         else if(DetSweepReversal(-1, liq, t)) dir = -1;
         if(dir != 0)
           {
            attempted = true;
            if(Enabled(t.setup)) { cand = t; }
            else { matched_disabled = true; disabled_setup = t.setup; }
           }
        }
      // 2) range reversal — RANGE regime only; direction from the extreme
      if(cand.direction == 0 && regime.regime == XARE_REGIME_RANGE)
        {
         SXareDecision t; XareResetDecision(t);
         int dir = 0;
         if(DetRangeReversal(+1, bar, st, atr, t)) dir = +1;
         else if(DetRangeReversal(-1, bar, st, atr, t)) dir = -1;
         if(dir != 0)
           {
            attempted = true;
            if(Enabled(t.setup)) { cand = t; }
            else { matched_disabled = true; disabled_setup = t.setup; }
           }
        }
      // 3) breakout retest — needs prior BOS memory
      if(cand.direction == 0 && m_bos_dir != 0)
        {
         double conf = 0.0;
         if(XareRetestTrigger(m_bos_dir, m_bos_level, bars_since_bos,
                              m_cfg.retest_valid_bars, bar.low, bar.high,
                              bar.close, atr, conf))
           {
            attempted = true;
            if(m_cfg.setup_breakout_retest)
              {
               cand.direction        = m_bos_dir;
               cand.setup            = XARE_SETUP_BREAKOUT_RETEST;
               cand.setup_confidence = conf;
               cand.entry_lo         = m_bos_level - 0.25*atr;
               cand.entry_hi         = m_bos_level + 0.25*atr;
               cand.invalidation     = StringFormat("close beyond %s against break",
                                       DoubleToString(m_bos_level, 2));
               cand.evidence         = StringFormat("retest of %s BOS level %s, %d bars after",
                                       m_bos_dir > 0 ? "bull" : "bear",
                                       DoubleToString(m_bos_level, 2), bars_since_bos);
              }
            else { matched_disabled = true; disabled_setup = XARE_SETUP_BREAKOUT_RETEST; }
           }
        }
      // 4) breakout — follows alignment direction
      if(cand.direction == 0 && (dir_ok_bull || dir_ok_bear))
        {
         int dir = dir_ok_bull ? +1 : -1;
         SXareDecision t; XareResetDecision(t);
         if(DetBreakout(dir, bar, st, atr, t))
           {
            attempted = true;
            if(Enabled(t.setup)) { cand = t; }
            else { matched_disabled = true; disabled_setup = t.setup; }
           }
        }
      // 5) trend pullback — follows alignment direction
      if(cand.direction == 0 && (dir_ok_bull || dir_ok_bear))
        {
         int dir = dir_ok_bull ? +1 : -1;
         SXareDecision t; XareResetDecision(t);
         if(DetTrendPullback(dir, f, bar, atr, t))
           {
            attempted = true;
            if(Enabled(t.setup)) { cand = t; }
            else { matched_disabled = true; disabled_setup = t.setup; }
           }
        }
      // 6) trend continuation — follows alignment direction
      if(cand.direction == 0 && (dir_ok_bull || dir_ok_bear))
        {
         int dir = dir_ok_bull ? +1 : -1;
         SXareDecision t; XareResetDecision(t);
         if(DetTrendContinuation(dir, f, bar, prev_roc, st, t))
           {
            attempted = true;
            if(Enabled(t.setup)) { cand = t; }
            else { matched_disabled = true; disabled_setup = t.setup; }
           }
        }

      // --- BOS memory maintenance (after retest consumed old memory) ----
      if(bos_dir_now != 0)
        {
         m_bos_dir   = bos_dir_now;
         m_bos_level = bos_lvl_now;
         m_bos_time  = bar.time;
        }
      else if(m_bos_dir != 0 && m_bos_time > 0 && bar.time > m_bos_time)
        {
         if((bar.time - m_bos_time) > (long)m_cfg.retest_valid_bars * PeriodSeconds())
            m_bos_dir = 0;                    // window expired
        }

      // --- finalize -------------------------------------------------------
      if(cand.direction != 0 && cand.setup != XARE_SETUP_NONE)
        {
         if(cand.setup_confidence < m_cfg.min_setup_confidence)
           {
            out.nt_reason = XARE_NT_NO_SETUP_TRIGGER;
            out.evidence  = StringFormat("candidate %s too weak (%.0f < %.0f)",
                            XareSetupToString(cand.setup),
                            cand.setup_confidence, m_cfg.min_setup_confidence);
           }
         else
           {
            out.has_signal       = true;
            out.direction        = cand.direction;
            out.setup            = cand.setup;
            out.setup_confidence = cand.setup_confidence;
            out.entry_lo         = cand.entry_lo;
            out.entry_hi         = cand.entry_hi;
            out.invalidation     = cand.invalidation;
            out.evidence         = StringFormat("%s | regime %s(%d) mtf %s struct %s sess %s",
                                   cand.evidence,
                                   XareRegimeToString(regime.regime), regime.confidence,
                                   XareAlignmentToString(mtf.alignment),
                                   XareStructTrendToString(st.trend),
                                   XareSessionToString(session.session));
           }
        }
      else
        {
         out.nt_reason = matched_disabled ? XARE_NT_SETUP_DISABLED
                                          : XARE_NT_NO_SETUP_TRIGGER;
         out.evidence  = matched_disabled
            ? StringFormat("setup %s matched but disabled in config",
                XareSetupToString(disabled_setup))
            : (attempted ? "detectors attempted, none passed filters"
                         : "context valid, no setup trigger this bar");
        }
      m_last = out;
      return true;
     }

   bool              Last(SXareDecision &out) const
     {
      out = m_last;
      return true;
     }
  };

#endif // __XARE_SIGNALENGINE_MQH__
