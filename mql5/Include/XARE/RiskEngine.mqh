//+------------------------------------------------------------------+
//| RiskEngine.mqh — sizing, loss limits, risk states (§18,19,24-27,49,50)
//| v0.9.0 — M9.                                                     |
//|                                                                  |
//| PURE calculation core (no terminal calls — every input passed in,|
//| every broker property comes from SXareSymbolProps captured at    |
//| init; NOTHING about XAUUSD contract size / tick value / min lot  |
//| is assumed):                                                     |
//|   XarePointValuePerLot() — money per point per 1.0 lot (dynamic) |
//|   XareVolumeForRisk()    — lots so SL loss <= risk money         |
//|   XareSnapVolumeDown()   — floor to broker volume step           |
//|   XareRiskStateFromDD()  — drawdown % -> NORMAL..HALTED ladder   |
//|   XareEffectiveRiskPct() — state-scaled risk (HALTED => zero)    |
//|   XareStopDistance()     — ATR/structure/hybrid SL distance      |
//|   XareTpDistance()       — fixed-R / ATR TP distance             |
//|   XareCooldownUntil()    — cooldown deadline math                |
//|                                                                  |
//| Stateful layer (fed by the EA): equity/peak tracking, broker-day |
//| and ISO-week rollover, daily trade count, loss streak + cooldown.|
//|                                                                  |
//| NEVER moves risk upward because of losses. No martingale (§31).  |
//+------------------------------------------------------------------+
#ifndef __XARE_RISKENGINE_MQH__
#define __XARE_RISKENGINE_MQH__

#include "Types.mqh"
#include "Config.mqh"

//--- money lost per 1.0 lot when price moves 1 point against the position.
//--- Derived ONLY from actual broker properties: tick_value is per tick_size,
//--- so points-per-tick scaling must use point/tick_size (§19: never assume
//--- 0.01 lot = fixed money). Returns 0.0 when properties are unusable.
double XarePointValuePerLot(const SXareSymbolProps &p)
  {
   if(p.point <= 0.0 || p.tick_size <= 0.0 || p.tick_value <= 0.0)
      return 0.0;
   double ticks_per_point = p.point / p.tick_size;
   return p.tick_value * ticks_per_point;
  }

//--- floor a raw volume to the broker volume step (never rounds UP — that
//--- would silently exceed risk). Returns 0 for non-positive input.
double XareSnapVolumeDown(const double raw_volume, const double step)
  {
   if(raw_volume <= 0.0 || step <= 0.0)
      return 0.0;
   double lots = MathFloor(raw_volume / step + 1e-9) * step;
   return NormalizeDouble(lots, 8);   // kill fp dust; step grid preserved
  }

//--- core sizing (§19): volume so that (SL distance × volume) loss does not
//--- exceed risk money, from ACTUAL symbol properties. On success vol_out is
//--- broker-valid (>= min, <= max, on step, <= emergency cap). Returns false
//--- when the safe volume is below the broker minimum or inputs are invalid —
//--- the caller must then SKIP the trade (or apply the explicit §49 override).
bool XareVolumeForRisk(const double equity, const double risk_pct,
                       const double sl_points, const SXareSymbolProps &p,
                       const double emergency_max_lot,
                       double &vol_out, double &risk_money_out)
  {
   vol_out        = 0.0;
   risk_money_out = 0.0;
   if(!p.valid || equity <= 0.0 || risk_pct <= 0.0 || sl_points <= 0.0)
      return false;

   double point_value = XarePointValuePerLot(p);
   if(point_value <= 0.0)
      return false;

   risk_money_out = equity * risk_pct / 100.0;
   double loss_per_lot  = sl_points * point_value;
   if(loss_per_lot <= 0.0)
      return false;

   double raw  = risk_money_out / loss_per_lot;
   double snapped = XareSnapVolumeDown(raw, p.volume_step);

   //--- emergency hard ceiling (§50): never exceeded for any reason
   if(emergency_max_lot > 0.0 && snapped > emergency_max_lot)
      snapped = XareSnapVolumeDown(emergency_max_lot, p.volume_step);
   if(snapped > p.volume_max)
      snapped = XareSnapVolumeDown(p.volume_max, p.volume_step);

   if(snapped < p.volume_min)
      return false;                  // below broker minimum: skip, do not pad

   vol_out = snapped;
   return true;
  }

//--- drawdown % -> risk-state ladder (§25). Thresholds are config hypotheses.
ENUM_XARE_RISK_STATE XareRiskStateFromDD(const double dd_pct,
                                         const double caution_pct,
                                         const double reduced_pct,
                                         const double halt_pct)
  {
   if(dd_pct >= halt_pct)    return XARE_RISK_HALTED;
   if(dd_pct >= reduced_pct) return XARE_RISK_REDUCED;
   if(dd_pct >= caution_pct) return XARE_RISK_CAUTION;
   return XARE_RISK_NORMAL;
  }

//--- state-scaled effective risk (§25): moderate DD reduces risk, large DD
//--- stops new trades. Multipliers come from config (never above 1.0 applied
//--- here; HALTED is a hard zero).
double XareEffectiveRiskPct(const ENUM_XARE_RISK_STATE state,
                            const double base_pct,
                            const double mult_caution,
                            const double mult_reduced)
  {
   switch(state)
     {
      case XARE_RISK_HALTED:  return 0.0;
      case XARE_RISK_REDUCED: return base_pct * MathMin(mult_reduced, 1.0);
      case XARE_RISK_CAUTION: return base_pct * MathMin(mult_caution, 1.0);
      default:                return base_pct;
     }
  }

//--- SL distance in PRICE units (§20). direction: +1 long / -1 short.
//--- structure_level: protective swing (swing low for longs, high for shorts);
//--- ignored when it is not beyond the close. HYBRID takes the WIDER of the
//--- two (documented conservative default — hypothesis, not assumed optimal).
//--- min_dist is a hard floor in price units (stops level + spread buffer).
bool XareStopDistance(const int direction, const double bar_close,
                      const double structure_level, const double atr,
                      const double atr_mult, const ENUM_XARE_SL_MODE mode,
                      const double min_dist, double &dist_out)
  {
   dist_out = 0.0;
   if(direction == 0 || bar_close <= 0.0 || min_dist <= 0.0)
      return false;

   double atr_dist = (atr > 0.0 && atr_mult > 0.0) ? atr * atr_mult : 0.0;

   double struct_dist = 0.0;
   if(structure_level > 0.0)
     {
      double d = (direction > 0) ? (bar_close - structure_level)
                                 : (structure_level - bar_close);
      if(d > 0.0)
         struct_dist = d;            // protective level must be beyond entry
     }

   double dist = 0.0;
   switch(mode)
     {
      case XARE_SL_ATR:
         dist = atr_dist;
         break;
      case XARE_SL_STRUCTURE:
         dist = (struct_dist > 0.0) ? struct_dist : atr_dist; // ATR fallback
         break;
      case XARE_SL_HYBRID:
      default:
         dist = MathMax(atr_dist, struct_dist);
         break;
     }

   if(dist <= 0.0)
      return false;
   dist_out = MathMax(dist, min_dist);   // broker/floor floor — never inside
   return true;
  }

//--- TP distance in PRICE units (§21): fixed-R multiple of the SL distance,
//--- or ATR multiple. Both adapt to current volatility; no fixed dollar TP.
bool XareTpDistance(const ENUM_XARE_TP_MODE mode, const double sl_dist,
                    const double atr, const double r_multiple,
                    const double atr_mult, double &dist_out)
  {
   dist_out = 0.0;
   if(sl_dist <= 0.0)
      return false;
   double d = (mode == XARE_TP_ATR_MULT && atr > 0.0 && atr_mult > 0.0)
              ? atr * atr_mult
              : sl_dist * r_multiple;
   if(d <= 0.0)
      return false;
   dist_out = d;
   return true;
  }

//--- cooldown deadline from bar time + N bars of the working timeframe
datetime XareCooldownUntil(const datetime bar_time, const int bars,
                           const int period_seconds)
  {
   if(bar_time <= 0 || bars <= 0 || period_seconds <= 0)
      return 0;
   return (datetime)(bar_time + (long)bars * period_seconds);
  }

//+------------------------------------------------------------------+
//| Stateful risk tracker: equity anchors, limits, streaks.          |
//+------------------------------------------------------------------+
class CXareRiskEngine
  {
private:
   SXareConfig      m_cfg;
   SXareSymbolProps m_props;
   double           m_peak_equity;
   double           m_day_start_equity;
   double           m_week_start_equity;
   long             m_day_key;         // broker days since epoch
   long             m_week_key;        // ISO-style Mon-Sun bucket (epoch trick)
   int              m_trades_today;
   int              m_consec_losses;
   datetime         m_cooldown_until;
   bool             m_ready;

   static long      DayKey(const datetime t)     { return (long)t / 86400; }
   //--- epoch day 0 = Thursday => +3 aligns buckets to Mon..Sun (broker time)
   static long      WeekKey(const datetime t)    { return (DayKey(t) + 3) / 7; }

public:
                     CXareRiskEngine(void) : m_peak_equity(0.0),
                                             m_day_start_equity(0.0),
                                             m_week_start_equity(0.0),
                                             m_day_key(-1), m_week_key(-1),
                                             m_trades_today(0),
                                             m_consec_losses(0),
                                             m_cooldown_until(0),
                                             m_ready(false)
     {
      ZeroMemory(m_props);
     }

   void              Init(const SXareConfig &cfg, const SXareSymbolProps &props)
     {
      m_cfg   = cfg;
      m_props = props;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      datetime now = TimeCurrent();
      m_peak_equity      = eq;
      m_day_start_equity = eq;
      m_week_start_equity= eq;
      m_day_key          = DayKey(now);
      m_week_key         = WeekKey(now);
      m_ready            = (eq > 0.0);
     }

   bool              Ready(void) const { return m_ready; }

   //--- per-tick/per-bar refresh: rollovers use BROKER server time only (§24)
   void              Update(void)
     {
      if(!m_ready)
         return;
      datetime now = TimeCurrent();
      long dk = DayKey(now);
      long wk = WeekKey(now);
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);

      if(dk != m_day_key)
        {
         m_day_key          = dk;
         m_day_start_equity = eq;      // anchor = first equity seen on new day
         m_trades_today     = 0;
        }
      if(wk != m_week_key)
        {
         m_week_key         = wk;
         m_week_start_equity= eq;
        }
      if(eq > m_peak_equity)
         m_peak_equity = eq;
     }

   //--- daily realized+floating P/L (equity-based, includes open positions)
   double            DailyPL(void) const
     {
      return AccountInfoDouble(ACCOUNT_EQUITY) - m_day_start_equity;
     }
   double            DailyDDPct(void) const
     {
      if(m_day_start_equity <= 0.0) return 0.0;
      double loss = m_day_start_equity - AccountInfoDouble(ACCOUNT_EQUITY);
      return (loss > 0.0) ? loss / m_day_start_equity * 100.0 : 0.0;
     }
   double            WeeklyDDPct(void) const
     {
      if(m_week_start_equity <= 0.0) return 0.0;
      double loss = m_week_start_equity - AccountInfoDouble(ACCOUNT_EQUITY);
      return (loss > 0.0) ? loss / m_week_start_equity * 100.0 : 0.0;
     }
   double            CurrentDDPct(void) const
     {
      if(m_peak_equity <= 0.0) return 0.0;
      double loss = m_peak_equity - AccountInfoDouble(ACCOUNT_EQUITY);
      return (loss > 0.0) ? loss / m_peak_equity * 100.0 : 0.0;
     }

   ENUM_XARE_RISK_STATE State(void) const
     {
      double dd = MathMax(CurrentDDPct(), DailyDDPct());
      return XareRiskStateFromDD(dd, m_cfg.dd_caution_pct,
                                 m_cfg.dd_reduced_pct, m_cfg.dd_halt_pct);
     }

   //--- effective risk % after state scaling (0 when halted)
   double            EffectiveRiskPct(void) const
     {
      return XareEffectiveRiskPct(State(), m_cfg.risk_per_trade_pct,
                                  m_cfg.risk_mult_caution,
                                  m_cfg.risk_mult_reduced);
     }

   bool              DailyLossBreached(void) const
     {
      return DailyDDPct() >= m_cfg.daily_loss_limit_pct;
     }
   bool              WeeklyLossBreached(void) const
     {
      return WeeklyDDPct() >= m_cfg.weekly_loss_limit_pct;
     }
   int               TradesToday(void) const { return m_trades_today; }
   void              CountTradeOpened(void)  { m_trades_today++; }
   int               ConsecutiveLosses(void) const { return m_consec_losses; }

   bool              CooldownActive(const datetime now) const
     {
      return (m_cooldown_until > 0 && now < m_cooldown_until);
     }

   //--- feed closed-trade P/L: tracks the loss streak and arms cooldown (§26)
   void              OnTradeClosed(const double pl_money, const datetime bar_time)
     {
      if(pl_money < 0.0)
         m_consec_losses++;
      else if(pl_money > 0.0)
         m_consec_losses = 0;          // scratch trades do not reset the streak
      if(m_consec_losses >= m_cfg.max_consecutive_losses)
        {
         m_cooldown_until = XareCooldownUntil(bar_time, m_cfg.cooldown_bars,
                                              PeriodSeconds(m_cfg.working_tf));
         m_consec_losses  = 0;         // streak consumed by the cooldown
        }
     }

   //--- drawdown breach of the HALT threshold is latched by SafetyEngine;
   //--- here it is reported, not enforced, so states stay observable.
   SXareRiskSnapshot Snapshot(void) const
     {
      SXareRiskSnapshot s;
      s.ready              = m_ready;
      s.state              = State();
      s.equity             = AccountInfoDouble(ACCOUNT_EQUITY);
      s.peak_equity        = m_peak_equity;
      s.day_start_equity   = m_day_start_equity;
      s.daily_pl           = DailyPL();
      s.daily_dd_pct       = DailyDDPct();
      s.weekly_dd_pct      = WeeklyDDPct();
      s.current_dd_pct     = CurrentDDPct();
      s.trades_today       = m_trades_today;
      s.consecutive_losses = m_consec_losses;
      s.cooldown_active    = CooldownActive(TimeCurrent());
      s.cooldown_until     = m_cooldown_until;
      return s;
     }
  };
#endif // __XARE_RISKENGINE_MQH__
