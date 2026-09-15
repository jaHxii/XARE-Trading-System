//+------------------------------------------------------------------+
//| RegimeEngine.mqh — market regime classification (spec §9)         |
//| v0.4.0 — M4.                                                     |
//| Priority order (first match wins, documented in strategy.md):    |
//|   1. UNSAFE    — invalid features / stale data                   |
//|   2. BREAKOUT  — close beyond N-bar range edge with ADX support  |
//|   3. TREND_UP  — EMA stack bullish + ADX >= min                  |
//|   4. TREND_DOWN— EMA stack bearish + ADX >= min                  |
//|   5. RANGE     — no stack agreement, ADX below min               |
//|   6. HIGH/LOW_VOLATILITY — ATR percentile overrides the label    |
//|   7. UNKNOWN   — insufficient evidence                           |
//| Confidence is a 0..100 score from evidence count — explicitly    |
//| NOT a probability (spec §9).                                     |
//+------------------------------------------------------------------+
#ifndef __XARE_REGIMEENGINE_MQH__
#define __XARE_REGIMEENGINE_MQH__

#include "Types.mqh"
#include "Config.mqh"
#include "Logger.mqh"

//--- pure classifier core: deterministic, self-testable, no terminal state.
//--- Inputs are pre-computed booleans/scores so the rule is fully inspectable.
ENUM_XARE_REGIME XareClassifyRegime(const bool breakout,
                                    const bool stack_bull, const bool stack_bear,
                                    const bool adx_strong,
                                    const bool vol_high, const bool vol_low)
  {
   if(vol_high)
      return XARE_REGIME_HIGH_VOLATILITY;
   if(vol_low)
      return XARE_REGIME_LOW_VOLATILITY;
   if(breakout)
      return XARE_REGIME_BREAKOUT;
   if(adx_strong && stack_bull)
      return XARE_REGIME_TREND_UP;
   if(adx_strong && stack_bear)
      return XARE_REGIME_TREND_DOWN;
   if(!adx_strong)
      return XARE_REGIME_RANGE;
   return XARE_REGIME_UNKNOWN;      // strong ADX but no stack agreement
  }

class CXareRegimeEngine
  {
private:
   SXareConfig      m_cfg;
   int              m_atr_period;
   SXareRegime      m_last;
   CXareLogger     *m_log;

   //--- ATR percentile of current bar vs the prior 'window' bars (0..100).
   //--- Rank of current ATR among the last N: fraction of history below it.
   bool              ATRPercentile(const string symbol, const ENUM_TIMEFRAMES tf,
                                  const int shift, const int window, double &pct) const
     {
      double atr_now[1];
      if(m_h_atr == INVALID_HANDLE)
         return false;
      if(CopyBuffer(m_h_atr, 0, shift, 1, atr_now) != 1)
         return false;
      if(atr_now[0] <= 0 || atr_now[0] == EMPTY_VALUE)
         return false;
      double hist[];
      if(CopyBuffer(m_h_atr, 0, shift + 1, window, hist) != window)
         return false;                 // need the full window; no partial stats
      int below = 0;
      for(int i = 0; i < window; i++)
         if(hist[i] > 0 && hist[i] < atr_now[0])
            below++;
      pct = 100.0 * below / window;
      return true;
     }

   //--- breakout check: close beyond the [min low, max high] of the prior
   //--- 'lookback' bars (excluding the breakout bar itself) by a small buffer.
   bool              IsBreakout(const SXareBar &bar, const int lookback,
                                const double buffer, bool &up, bool &down) const
     {
      up = false; down = false;
      int bars_total = Bars(m_symbol, m_tf);
      if(bars_total < lookback + 2)
         return false;
      double hh = -DBL_MAX, ll = DBL_MAX;
      for(int i = 2; i <= lookback + 1; i++)   // bars before the signal bar
        {
         double h = iHigh(m_symbol, m_tf, i);
         double l = iLow (m_symbol, m_tf, i);
         if(h <= 0 || l <= 0)
            return false;
         if(h > hh) hh = h;
         if(l < ll) ll = l;
        }
      double range = hh - ll;
      if(range <= 0)
         return false;
      if(bar.close > hh + buffer) { up = true;   return true; }
      if(bar.close < ll - buffer) { down = true; return true; }
      return false;
     }

public:
   string           m_symbol;        // set at Init (used by helpers)
   ENUM_TIMEFRAMES  m_tf;
   int              m_h_atr;         // borrowed ATR handle (owned by Indicators)

                     CXareRegimeEngine(void) : m_symbol(""), m_tf(PERIOD_CURRENT),
                                               m_h_atr(INVALID_HANDLE), m_log(NULL)
     {
      ZeroMemory(m_last);
     }

   bool              Init(const string symbol, const ENUM_TIMEFRAMES tf,
                          const SXareConfig &cfg, const int atr_handle,
                          CXareLogger *log)
     {
      m_symbol  = symbol;
      m_tf      = tf;
      m_cfg     = cfg;
      m_h_atr   = atr_handle;
      m_log     = log;
      return (m_h_atr != INVALID_HANDLE);
     }

   //--- evaluate regime for the closed bar at 'shift' using current features
   bool              Evaluate(const int shift, const SXareFeatures &f,
                              const SXareBar &bar, SXareRegime &out)
     {
      out.valid = false;
      out.confidence = 0;
      out.evidence = "";

      if(!f.valid || bar.close <= 0)
        {
         out.regime = XARE_REGIME_UNSAFE;
         out.evidence = "invalid features or bar data";
         out.valid = true;
         m_last = out;
         return true;
        }

      // --- evidence pieces -------------------------------------------
      bool stack_bull = (f.ema_fast > f.ema_mid && f.ema_mid > f.ema_slow);
      bool stack_bear = (f.ema_fast < f.ema_mid && f.ema_mid < f.ema_slow);
      bool adx_strong = (f.adx >= m_cfg.trend_adx_min);
      bool di_bull    = (f.di_plus > f.di_minus);
      bool di_bear    = (f.di_minus > f.di_plus);

      double buffer = f.atr * 0.10;    // small expansion filter (hypothesis)
      bool bo_up, bo_down;
      bool breakout = IsBreakout(bar, m_cfg.breakout_range_lookback, buffer, bo_up, bo_down);

      double atr_pct = 50.0;
      bool vol_ok = ATRPercentile(m_symbol, m_tf, shift, 200, atr_pct);
      bool vol_high = vol_ok && (atr_pct >= m_cfg.high_vol_atr_pct);
      bool vol_low  = vol_ok && (atr_pct <= m_cfg.low_vol_atr_pct);

      // --- classify ---------------------------------------------------
      ENUM_XARE_REGIME r = XareClassifyRegime(breakout, stack_bull, stack_bear,
                                              adx_strong, vol_high, vol_low);

      // --- confidence: counted evidence points (explicitly not probability)
      int score = 0, max_score = 6;
      if(r == XARE_REGIME_TREND_UP || r == XARE_REGIME_TREND_DOWN)
        {
         bool bull = (r == XARE_REGIME_TREND_UP);
         if(bull ? stack_bull : stack_bear)                 score += 2;
         if(adx_strong)                                     score += 1;
         if(bull ? di_bull : di_bear)                       score += 1;
         if(!(vol_high || vol_low))                         score += 1; // clean vol backdrop
         if(breakout && (bull ? bo_up : bo_down))           score += 1;
        }
      else if(r == XARE_REGIME_BREAKOUT)
        {
         if(bo_up || bo_down)                               score += 2;
         if(adx_strong)                                     score += 1;
         if(vol_high || atr_pct >= 60.0)                    score += 1; // expansion aids breaks
         if(!(stack_bull && stack_bear))                    score += 1; // stack not contradictory
         if(f.roc > 0.0 || f.roc < 0.0)                     score += 1; // momentum present
        }
      else if(r == XARE_REGIME_RANGE)
        {
         if(!stack_bull && !stack_bear)                     score += 2;
         if(!adx_strong)                                    score += 2;
         if(!vol_high && !vol_low)                          score += 1;
         if(bar.close > f.ema_slow)                         score += 1; // above macro floor
        }
      else if(r == XARE_REGIME_HIGH_VOLATILITY || r == XARE_REGIME_LOW_VOLATILITY)
        {
         score = (vol_ok ? 3 : 1);
        }
      else if(r == XARE_REGIME_UNSAFE)
        {
         score = 0;
        }

      out.regime     = r;
      out.confidence = (max_score > 0) ? (int)MathRound(100.0 * score / max_score) : 0;
      out.evidence   = StringFormat(
         "stack_bull=%d stack_bear=%d adx=%.1f(min %d) di+=%.1f di-=%.1f atr_pct=%.0f breakout=%d roc=%.2f",
         stack_bull, stack_bear, f.adx, m_cfg.trend_adx_min,
         f.di_plus, f.di_minus, atr_pct, breakout, f.roc);
      out.evaluated_at = TimeCurrent();
      out.valid      = true;
      m_last         = out;

      if(m_log != NULL)
         m_log.Debug("REGIME", StringFormat("%s conf=%d | %s",
                     XareRegimeToString(r), out.confidence, out.evidence));
      return true;
     }

   bool              Last(SXareRegime &out) const
     {
      if(!m_last.valid)
         return false;
      out = m_last;
      return true;
     }
  };

#endif // __XARE_REGIMEENGINE_MQH__
