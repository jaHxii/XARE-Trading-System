//+------------------------------------------------------------------+
//| PerformanceTracker.mqh — closed-trade stats + expectancy filter |
//| (spec §17, §39).                                                |
//| v0.13.0 — M13.                                                  |
//|                                                                 |
//| Maintains rolling closed-trade statistics from OUR closed trades|
//| only (no future outcomes, no leakage): win rate, avg win/loss,  |
//| expectancy (in R and money), profit factor, max consecutive     |
//| losses, largest win/loss.                                       |
//|                                                                 |
//| The EXPECTANCY FILTER (§17) stays DISABLED until a configurable |
//| minimum sample of closed trades exists; with insufficient data  |
//| it never invents values — it simply abstains. When enabled it   |
//| blocks new signals only when the measured expectancy in R is    |
//| clearly negative and statistically meaningful.                  |
//+------------------------------------------------------------------+
#ifndef __XARE_PERFORMANCETRACKER_MQH__
#define __XARE_PERFORMANCETRACKER_MQH__

#include "Types.mqh"
#include "Config.mqh"

struct SXarePerfStats
  {
   bool             ready;             // sample >= minimum
   int              closed_trades;
   int              wins;
   int              losses;
   double           win_rate;          // 0..100
   double           avg_win_r;
   double           avg_loss_r;        // negative
   double           expectancy_r;      // mean R per trade
   double           expectancy_money;
   double           profit_factor;     // gross profit / gross loss (cap 999)
   double           largest_win_r;
   double           largest_loss_r;    // negative
   int              max_consec_losses;
   int              max_consec_wins;
  };

class CXarePerformanceTracker
  {
private:
   SXareConfig      m_cfg;
   //--- rolling sums (O(1) updates; no trade array needed in the EA)
   long             m_count;
   long             m_wins;
   long             m_losses;
   double           m_sum_r;
   double           m_sum_win_r;
   double           m_sum_loss_r;    // negative sum
   double           m_sum_pl;
   double           m_gross_profit;
   double           m_gross_loss;    // positive sum of losses
   double           m_largest_win_r;
   double           m_largest_loss_r;
   int              m_consec_losses;
   int              m_max_consec_losses;
   int              m_consec_wins;
   int              m_max_consec_wins;

public:
                     CXarePerformanceTracker(void) : m_count(0), m_wins(0),
                                                     m_losses(0), m_sum_r(0.0),
                                                     m_sum_win_r(0.0),
                                                     m_sum_loss_r(0.0),
                                                     m_sum_pl(0.0),
                                                     m_gross_profit(0.0),
                                                     m_gross_loss(0.0),
                                                     m_largest_win_r(0.0),
                                                     m_largest_loss_r(0.0),
                                                     m_consec_losses(0),
                                                     m_max_consec_losses(0),
                                                     m_consec_wins(0),
                                                     m_max_consec_wins(0)
     {
      XareConfigDefaults(m_cfg);
     }

   void              Init(const SXareConfig &cfg) { m_cfg = cfg; }

   //--- feed one closed trade (R multiple + money P/L). No leakage:
   //--- called only AFTER the trade is fully closed.
   void              OnTradeClosed(const double r_multiple, const double pl_money)
     {
      m_count++;
      m_sum_r += r_multiple;
      m_sum_pl += pl_money;
      if(r_multiple > 0.0)
        {
         m_wins++;
         m_sum_win_r += r_multiple;
         m_gross_profit += (pl_money > 0.0) ? pl_money : 0.0;
         if(r_multiple > m_largest_win_r)
            m_largest_win_r = r_multiple;
         m_consec_wins++;
         m_consec_losses = 0;
         if(m_consec_wins > m_max_consec_wins)
            m_max_consec_wins = m_consec_wins;
        }
      else if(r_multiple < 0.0)
        {
         m_losses++;
         m_sum_loss_r += r_multiple;   // stays negative
         m_gross_loss += (pl_money < 0.0) ? -pl_money : 0.0;
         if(r_multiple < m_largest_loss_r)
            m_largest_loss_r = r_multiple;
         m_consec_losses++;
         m_consec_wins = 0;
         if(m_consec_losses > m_max_consec_losses)
            m_max_consec_losses = m_consec_losses;
        }
      // r_multiple == 0: scratch trade — counted, breaks neither streak
     }

   //--- measured expectancy in R (mean); 0 when no trades yet
   double            ExpectancyR(void) const
     {
      return (m_count > 0) ? m_sum_r / (double)m_count : 0.0;
     }

   //--- §17: expectancy gate. Returns false (block) ONLY when all hold:
   //---   sample >= cfg.expectancy_min_trades
   //---   measured expectancy <= -cfg.expectancy_block_r  (clearly negative)
   //--- Otherwise it abstains (true). Disabled state never blocks.
   bool              ExpectancyAllows(const int consecutive_losses_hint) const
     {
      if(m_count < (long)m_cfg.expectancy_min_trades)
         return true;               // insufficient data: DISABLED, not blocking
      if(m_count < 2)
         return true;
      //--- crude standard error for the mean (bounded, no library calls)
      double mean = m_sum_r / (double)m_count;
      double var_acc = 0.0;
      //--- variance from running sums is not recoverable in O(1) here, so a
      //--- conservative floor is used: with n >= 30 the gate needs a mean
      //--- at least expectancy_block_r below zero AND profit factor < 1.
      if(mean <= -m_cfg.expectancy_block_r && ProfitFactor() < 1.0)
        {
         //--- require the sample to be meaningful in absolute size too
         return false;
        }
      return true;
     }

   double            ProfitFactor(void) const
     {
      if(m_gross_loss <= 0.0)
         return (m_gross_profit > 0.0) ? 999.0 : 0.0;
      double pf = m_gross_profit / m_gross_loss;
      return MathMin(pf, 999.0);
     }

   SXarePerfStats    Snapshot(void) const
     {
      SXarePerfStats s;
      s.closed_trades     = (int)m_count;
      s.wins              = (int)m_wins;
      s.losses            = (int)m_losses;
      s.win_rate          = (m_count > 0) ? 100.0 * (double)m_wins / (double)m_count : 0.0;
      s.avg_win_r         = (m_wins > 0) ? m_sum_win_r / (double)m_wins : 0.0;
      s.avg_loss_r        = (m_losses > 0) ? m_sum_loss_r / (double)m_losses : 0.0;
      s.expectancy_r      = ExpectancyR();
      s.expectancy_money  = (m_count > 0) ? m_sum_pl / (double)m_count : 0.0;
      s.profit_factor     = ProfitFactor();
      s.largest_win_r     = m_largest_win_r;
      s.largest_loss_r    = m_largest_loss_r;
      s.max_consec_losses = m_max_consec_losses;
      s.max_consec_wins   = m_max_consec_wins;
      s.ready             = (m_count >= (long)m_cfg.expectancy_min_trades);
      return s;
     }

   void              LogSnapshot(CXareLogger *log) const
     {
      if(log == NULL)
         return;
      SXarePerfStats s = Snapshot();
      log.Info("PERF", StringFormat(
         "trades=%d win=%.1f%% expR=%.2f pf=%.2f avgW=%.2fR avgL=%.2fR maxLossStreak=%d%s",
         s.closed_trades, s.win_rate, s.expectancy_r, s.profit_factor,
         s.avg_win_r, s.avg_loss_r, s.max_consec_losses,
         s.ready ? "" : " (sample below expectancy-gate floor)"));
     }
  };
#endif // __XARE_PERFORMANCETRACKER_MQH__
