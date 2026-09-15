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
//| v0.17.0 hardening adds (pure, all SELF_TESTable):                |
//|   XareAdaptiveRiskPct()  — bounded factor product (§6); result   |
//|                            NEVER exceeds base risk, factors      |
//|                            clamped [factor_min, 1.0] each        |
//|   XareStageForEquity()   — §8 capital-stage ladder               |
//|   XareStageRiskFactor()  — stage factor (reduce-only)            |
//|   XareWeekendState()     — §15 Friday-cutoff / weekend predicate |
//|   XareLockFloor()        — §9 profit-lock floor math             |
//|                                                                  |
//| Stateful layer (fed by the EA): equity/peak tracking, broker-day |
//| and ISO-week rollover, daily trade count, loss streak + cooldown,|
//| losing-days counter, profit-lock floor, DEFENSIVE inputs.        |
//|                                                                  |
//| NEVER moves risk upward because of losses. No martingale (§31).  |
//| Adaptive factors are hard-bounded: the product can only shrink   |
//| risk. If min volume makes even the floor risk unachievable, the  |
//| plan builder refuses (micro-account §7 rule).                    |
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

//--- §7 micro-account clarity: the risk % that would be taken if the trade
//--- were forced onto the broker MINIMUM volume (pure; no assumptions).
double XareMinLotRiskPct(const double equity, const double sl_points,
                         const SXareSymbolProps &p)
  {
   if(!p.valid || equity <= 0.0 || sl_points <= 0.0)
      return 0.0;
   double point_value = XarePointValuePerLot(p);
   if(point_value <= 0.0)
      return 0.0;
   return p.volume_min * sl_points * point_value / equity * 100.0;
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

//--- state-scaled effective risk (§25 + §10): moderate DD reduces risk,
//--- large DD stops new trades, DEFENSIVE halves (config). Multipliers come
//--- from config (never above 1.0 applied here; HALTED is a hard zero).
double XareEffectiveRiskPct(const ENUM_XARE_RISK_STATE state,
                            const double base_pct,
                            const double mult_caution,
                            const double mult_reduced,
                            const double mult_defensive)
  {
   switch(state)
     {
      case XARE_RISK_HALTED:    return 0.0;
      case XARE_RISK_DEFENSIVE: return base_pct * MathMin(mult_defensive, 1.0);
      case XARE_RISK_REDUCED:   return base_pct * MathMin(mult_reduced, 1.0);
      case XARE_RISK_CAUTION:   return base_pct * MathMin(mult_caution, 1.0);
      default:                  return base_pct;
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
//| v0.17.0 hardening — pure functions (all SELF_TESTable)           |
//+------------------------------------------------------------------+

//--- §6 adaptive risk: final = base × Π(factors), each factor clamped
//--- to [factor_min, 1.0]. Risk can only shrink or stay: no factor can
//--- exceed 1.0, the product is additionally clamped to <= base. A factor
//--- passed as <= 0 means "not applicable" and is skipped (never zeroed
//--- here — the quality gate is the score band, not a factor).
double XareAdaptiveRiskPct(const double base_pct, const double factor_min,
                           const double quality, const double regime,
                           const double volatility, const double health,
                           const double drawdown, const double performance,
                           const double stage)
  {
   if(base_pct <= 0.0)
      return 0.0;
   const double lo = (factor_min > 0.0) ? factor_min : 0.0;
   double product = 1.0;
   //--- MQL5 requires constant-size arrays: fixed slots for the 7 factors
   double f[7];
   f[0] = quality; f[1] = regime; f[2] = volatility; f[3] = health;
   f[4] = drawdown; f[5] = performance; f[6] = stage;
   for(int i = 0; i < 7; i++)
     {
      if(f[i] <= 0.0)
         continue;                       // not applicable
      product *= MathMax(lo, MathMin(1.0, f[i]));
     }
   return MathMin(base_pct, base_pct * product);   // never above base
  }

//--- §8 capital stage from equity (DEFENSIVE is health-driven and passed
//--- separately; a defensive stage outranks any equity bucket)
ENUM_XARE_STAGE XareStageForEquity(const double equity,
                                   const double micro_max,
                                   const double growth_max,
                                   const double standard_max,
                                   const bool health_defensive)
  {
   if(health_defensive)
      return XARE_STAGE_DEFENSIVE;
   if(equity < micro_max)     return XARE_STAGE_MICRO;
   if(equity < growth_max)    return XARE_STAGE_GROWTH;
   if(equity < standard_max)  return XARE_STAGE_STANDARD;
   return XARE_STAGE_SCALE;
  }

//--- §8 stage risk factor: reduce-only, DEFENSIVE matches the config's
//--- defensive multiplier; equity stages are neutral until research
//--- validates stage-specific scales (documented hypothesis: no effect).
double XareStageRiskFactor(const ENUM_XARE_STAGE stage,
                           const double defensive_mult)
  {
   if(stage == XARE_STAGE_DEFENSIVE)
      return MathMin(MathMax(defensive_mult, 0.0), 1.0);
   return 1.0;
  }

//--- §15 weekend state. day_of_week: 0=Sun..5=Fri..6=Sat (TimeDayOfWeek).
//--- Friday: entries blocked from friday_cutoff_min (final entry must START
//--- before the cutoff). Saturday: always WEEKEND. Sunday: blocked until
//--- sunday_open_min (avoid pre-open spread spikes) when > 0.
ENUM_XARE_WEEKEND XareWeekendState(const int day_of_week, const int minute_of_day,
                                   const int friday_cutoff_min,
                                   const int sunday_open_min)
  {
   if(day_of_week == 5)                       // Friday
      return (minute_of_day >= friday_cutoff_min) ? XARE_WKEND_FRIDAY_CUTOFF
                                                  : XARE_WKEND_NONE;
   if(day_of_week == 6)                       // Saturday
      return XARE_WKEND_WEEKEND;
   if(day_of_week == 0 && sunday_open_min > 0 &&
      minute_of_day < sunday_open_min)        // Sunday before open
      return XARE_WKEND_WEEKEND;
   return XARE_WKEND_NONE;
  }

//--- §9: floor value once the milestone is reached (pure, used by the EA);
//--- arming itself is a stateful ratchet in CXareRiskEngine (never lowers)
double XareLockFloorValue(const double init_equity, const double milestone_pct,
                          const double floor_pct)
  {
   if(init_equity <= 0.0 || milestone_pct <= 0.0 || floor_pct <= 0.0)
      return 0.0;
   double gain = init_equity * (milestone_pct / 100.0);
   return init_equity + gain * (floor_pct / 100.0);
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
   //--- v0.17.0 hardening state
   double           m_init_equity;         // §9 lock baseline
   double           m_lock_floor;          // §9 protected floor (0 = none)
   int              m_consec_losing_days;  // §10/§11
   int              m_losing_days_total;   // days (not necessarily consecutive)
   bool             m_today_was_loss;      // day flagged as losing
   datetime         m_post_sl_until;       // §12 cooldown after SL loser
   datetime         m_slip_until;          // §12 cooldown after abnormal slippage
   int              m_trades_session;      // §12 per-session count
   string           m_session_name;        // session owning the count
   ENUM_XARE_STAGE  m_stage;               // §8 last computed stage
   ENUM_XARE_STAGE  m_stage_prev;          // for transition logging
   bool             m_friday_close_done;   // §15 close-all done this episode

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
                                             m_ready(false),
                                             m_init_equity(0.0),
                                             m_lock_floor(0.0),
                                             m_consec_losing_days(0),
                                             m_losing_days_total(0),
                                             m_today_was_loss(false),
                                             m_post_sl_until(0),
                                             m_slip_until(0),
                                             m_trades_session(0),
                                             m_session_name(""),
                                             m_stage(XARE_STAGE_MICRO),
                                             m_stage_prev(XARE_STAGE_MICRO),
                                             m_friday_close_done(false)
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
      m_init_equity      = eq;          // §9 baseline
      m_lock_floor       = 0.0;
      m_consec_losing_days = 0;
      m_losing_days_total  = 0;
      m_today_was_loss     = false;
      m_post_sl_until    = 0;
      m_slip_until       = 0;
      m_trades_session   = 0;
      m_session_name     = "";
      m_stage_prev       = XARE_STAGE_MICRO;
      m_stage            = XareStageForEquity(eq, m_cfg.stage_micro_max_equity,
                                             m_cfg.stage_growth_max_equity,
                                             m_cfg.stage_standard_max_equity,
                                             false);
      m_friday_close_done = false;
      m_ready            = (eq > 0.0);
     }

   //--- restore persisted state after restart (§20). Returns false when
   //--- the anchors are stale/incompatible (caller keeps fresh init).
   bool              RestoreAnchors(const long day_key, const long week_key,
                                    const double day_eq, const double week_eq,
                                    const double peak_eq, const double init_eq,
                                    const int trades_today, const int consec_losses,
                                    const int consec_losing_days,
                                    const datetime cooldown_until,
                                    const datetime post_sl_until,
                                    const datetime slip_until,
                                    const int trades_session,
                                    const string session_name,
                                    const double lock_floor,
                                    const bool friday_close_done,
                                    string &note_out)
     {
      note_out = "";
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq <= 0.0)
        {
         note_out = "equity unavailable — anchors stay fresh-init";
         return false;
        }
      m_day_key          = (day_key > 0) ? day_key : DayKey(TimeCurrent());
      m_week_key         = (week_key > 0) ? week_key : WeekKey(TimeCurrent());
      //--- day/week anchors from the file only if the buckets still match;
      //--- a new broker day/week re-anchors in Update() anyway.
      if(day_key == DayKey(TimeCurrent()) && day_eq > 0.0)
         m_day_start_equity = day_eq;
      if(week_key == WeekKey(TimeCurrent()) && week_eq > 0.0)
         m_week_start_equity = week_eq;
      m_peak_equity        = MathMax(peak_eq, eq);   // peak never lowers
      m_init_equity        = (init_eq > 0.0) ? init_eq : eq;
      m_trades_today       = trades_today;
      m_consec_losses      = consec_losses;
      m_consec_losing_days = consec_losing_days;
      m_cooldown_until     = cooldown_until;
      m_post_sl_until      = post_sl_until;
      m_slip_until         = slip_until;
      m_trades_session     = trades_session;
      m_session_name       = session_name;
      m_lock_floor         = MathMax(lock_floor, 0.0);
      m_friday_close_done  = friday_close_done;
      note_out = "risk state restored";
      return true;
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
         //--- §11: yesterday was a losing day?
         if(m_day_start_equity > 0.0 &&
            AccountInfoDouble(ACCOUNT_EQUITY) < m_day_start_equity)
           {
            m_losing_days_total++;
            m_consec_losing_days++;
           }
         else
            m_consec_losing_days = 0;   // a non-losing day resets the streak
         m_day_key          = dk;
         m_day_start_equity = eq;      // anchor = first equity seen on new day
         m_trades_today     = 0;
         m_today_was_loss  = false;
        }
      if(wk != m_week_key)
        {
         m_week_key         = wk;
         m_week_start_equity= eq;
        }
      if(eq > m_peak_equity)
         m_peak_equity = eq;

      //--- §8 stage transitions (equity can cross boundaries intraday)
      m_stage = XareStageForEquity(eq, m_cfg.stage_micro_max_equity,
                                   m_cfg.stage_growth_max_equity,
                                   m_cfg.stage_standard_max_equity,
                                   DefensiveActive());
      if(m_stage != m_stage_prev)
        {
         PrintFormat("XARE[RISK][INFO] account stage transition: %s -> %s",
                     XareStageToString(m_stage_prev), XareStageToString(m_stage));
         m_stage_prev = m_stage;
        }

      //--- §9 profit-lock ratchet (once armed, the floor never lowers)
      if(m_cfg.profit_lock_enabled && m_init_equity > 0.0 &&
         eq >= m_init_equity * (1.0 + m_cfg.lock_milestone_pct / 100.0))
        {
         double floor = XareLockFloorValue(m_init_equity, m_cfg.lock_milestone_pct,
                                           m_cfg.lock_floor_pct);
         if(floor > m_lock_floor)
           {
            m_lock_floor = floor;
            PrintFormat("XARE[RISK][INFO] profit lock armed: floor %.2f (init %.2f)",
                        m_lock_floor, m_init_equity);
           }
        }
     }

   //--- §10 DEFENSIVE inputs (each independently configured; 0/off values
   //--- never trigger). Margin level 0 = no open positions = not defensive.
   bool              DefensiveActive(void) const
     {
      if(m_cfg.max_consec_losing_days > 0 &&
         m_consec_losing_days >= m_cfg.max_consec_losing_days)
         return true;
      double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      if(m_cfg.min_margin_level_pct > 0.0 && ml > 0.0 &&
         ml < m_cfg.min_margin_level_pct)
         return true;
      return false;
     }

   //--- §9 lock state
   double            LockFloor(void)       const { return m_lock_floor; }
   bool              FloorBreached(void) const
     {
      return (m_lock_floor > 0.0 &&
              AccountInfoDouble(ACCOUNT_EQUITY) < m_lock_floor);
     }
   double            InitEquity(void)      const { return m_init_equity; }
   int               ConsecLosingDays(void) const { return m_consec_losing_days; }
   ENUM_XARE_STAGE   Stage(void)           const { return m_stage; }

   //--- §20 persistence readouts (state restore needs exact anchors)
   long              DayKeyForPersist(void) const { return m_day_key; }
   long              WeekKeyForPersist(void) const { return m_week_key; }
   double            DayStartEquityForPersist(void) const { return m_day_start_equity; }
   double            WeekStartEquityForPersist(void) const { return m_week_start_equity; }
   double            PeakEquityForPersist(void) const { return m_peak_equity; }
   datetime          CooldownUntilForPersist(void) const { return m_cooldown_until; }
   datetime          PostSLUntilForPersist(void) const { return m_post_sl_until; }
   datetime          SlipUntilForPersist(void) const { return m_slip_until; }

   //--- §12 cooldown suite
   void              ArmPostSLCooldown(const datetime bar_time)
     {
      m_post_sl_until = XareCooldownUntil(bar_time, m_cfg.post_sl_cooldown_bars,
                                          PeriodSeconds(m_cfg.working_tf));
     }
   void              ArmSlipCooldown(const datetime bar_time)
     {
      m_slip_until = XareCooldownUntil(bar_time, m_cfg.slip_cooldown_bars,
                                       PeriodSeconds(m_cfg.working_tf));
     }
   bool              PostSLCooldownActive(const datetime now) const
     {
      return (m_post_sl_until > 0 && now < m_post_sl_until);
     }
   bool              SlipCooldownActive(const datetime now) const
     {
      return (m_slip_until > 0 && now < m_slip_until);
     }
   void              CountSessionTrade(const string session_name)
     {
      if(session_name != m_session_name)
        {
         m_session_name  = session_name;   // new session episode: reset count
         m_trades_session = 0;
        }
      m_trades_session++;
     }
   int               TradesSession(void) const { return m_trades_session; }
   string            SessionName(void)   const { return m_session_name; }
   void              MarkFridayCloseDone(void)   { m_friday_close_done = true; }
   bool              FridayCloseDone(void) const { return m_friday_close_done; }

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
      ENUM_XARE_RISK_STATE s = XareRiskStateFromDD(dd, m_cfg.dd_caution_pct,
                                                   m_cfg.dd_reduced_pct,
                                                   m_cfg.dd_halt_pct);
      //--- §10: DEFENSIVE sits between REDUCED and HALTED
      if(DefensiveActive())
         s = XareRiskStateWorst(s, XARE_RISK_DEFENSIVE);
      return s;
     }

   //--- effective risk % after state scaling (0 when halted)
   double            EffectiveRiskPct(void) const
     {
      return XareEffectiveRiskPct(State(), m_cfg.risk_per_trade_pct,
                                  m_cfg.risk_mult_caution,
                                  m_cfg.risk_mult_reduced,
                                  m_cfg.risk_mult_defensive);
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
   //--- plus the §12 post-SL cooldown on any SL loser
   void              OnTradeClosed(const double pl_money, const datetime bar_time,
                                   const bool closed_by_sl)
     {
      if(pl_money < 0.0)
        {
         m_consec_losses++;
         m_today_was_loss = true;
         if(closed_by_sl && m_cfg.post_sl_cooldown_bars > 0)
            ArmPostSLCooldown(bar_time);
        }
      else if(pl_money > 0.0)
         m_consec_losses = 0;          // scratch trades do not reset the streak
      if(m_cfg.max_consecutive_losses > 0 &&
         m_consec_losses >= m_cfg.max_consecutive_losses)
        {
         m_cooldown_until = XareCooldownUntil(bar_time, m_cfg.cooldown_bars,
                                              PeriodSeconds(m_cfg.working_tf));
         m_consec_losses  = 0;         // streak consumed by the cooldown
        }
     }

   //--- compatibility shim for existing callers without the SL flag
   void              OnTradeClosed(const double pl_money, const datetime bar_time)
     {
      OnTradeClosed(pl_money, bar_time, false);
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
      //--- v0.17.0 hardening fields
      s.weekly_pl          = s.equity - m_week_start_equity;
      s.margin_level_pct   = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      s.consec_losing_days = m_consec_losing_days;
      s.protected_floor    = m_lock_floor;
      s.floor_breached     = FloorBreached();
      s.stage              = m_stage;
      return s;
     }
  };
#endif // __XARE_RISKENGINE_MQH__
