//+------------------------------------------------------------------+
//| PositionManager.mqh — position state machine (spec §30)          |
//| v0.11.0 — M11.                                                   |
//|                                                                  |
//| Owns the single tracked position (v1: one position per symbol,   |
//| §32). Responsibilities:                                          |
//|   - poll terminal position state by magic (GetState)             |
//|   - classify the position (OPEN/PROTECTED/PARTIAL/TRAILING)      |
//|   - on close: build a full exit record (reason + R multiple)     |
//|   - duplicate-order protection: refuses to plan a send while     |
//|     a position with our magic exists                             |
//| It does NOT send, modify, or close orders (that is execution's   |
//| job / future management actions).                                |
//+------------------------------------------------------------------+
#ifndef __XARE_POSITIONMANAGER_MQH__
#define __XARE_POSITIONMANAGER_MQH__

#include "Types.mqh"
#include "Logger.mqh"

//--- exit record for a closed trade (journal + research)
struct SXareExitRecord
  {
   bool             present;
   ulong            ticket;
   int              direction;
   double           volume;
   double           entry_price;
   double           exit_price;
   double           sl_price;
   double           tp_price;
   double           pl_money;
   double           r_multiple;
   int              bars_in_trade;
   ENUM_XARE_EXIT_REASON reason;
   ENUM_XARE_SETUP  setup;
   string           session;
   string           regime;
   double           score;
   double           risk_pct;
   double           slippage_points;
   string           open_reason;
   datetime         close_time;
  };

class CXarePositionManager
  {
private:
   long             m_magic;
   CXareLogger     *m_log;
   SXarePosition    m_ctx;          // tracked context for OUR position
   bool             m_have_ctx;
   ulong            m_ticket;

   //--- find OUR position ticket by magic+symbol; 0 when none
   ulong            FindTicket(void) const
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || !PositionSelectByTicket(tk))
            continue;
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == m_magic)
            return tk;
        }
      return 0;
     }

   //--- price-based exit-reason classification (§30: every exit has a reason).
   //--- Public static: unit-testable without a terminal.
   static ENUM_XARE_EXIT_REASON ClassifyExitStatic(const int direction,
                                                   const double entry,
                                                   const double sl,
                                                   const double tp,
                                                   const double exit_price)
     {
      return ClassifyExit(direction, entry, sl, tp, exit_price);
     }

   static ENUM_XARE_EXIT_REASON ClassifyExit(const int direction,
                                             const double entry,
                                             const double sl,
                                             const double tp,
                                             const double exit_price)
     {
      if(direction > 0)
        {
         if(exit_price <= sl) return XARE_EXIT_HARD_SL;
         if(exit_price >= tp) return XARE_EXIT_TP;
        }
      else if(direction < 0)
        {
         if(exit_price >= sl) return XARE_EXIT_HARD_SL;
         if(exit_price <= tp) return XARE_EXIT_TP;
        }
      return XARE_EXIT_NONE;      // manual/unknown close: reported as NONE
     }

public:
                     CXarePositionManager(void) : m_magic(0), m_log(NULL),
                                                  m_have_ctx(false), m_ticket(0)
     {
      ResetCtx();
     }

   void              Init(const long magic, CXareLogger *log)
     {
      m_magic = magic;
      m_log   = log;
     }

   void              ResetCtx(void)
     {
      m_have_ctx = false;
      m_ticket   = 0;
      m_ctx.state = XARE_POS_NONE;
     }

   //--- plan registration when a send succeeds (called by the EA)
   void              OnOpened(const SXareTradeDecision &plan,
                              const SXareExecutionResult &res,
                              const datetime bar_time,
                              const string regime_label)
     {
      m_ticket            = res.ticket;
      m_have_ctx          = true;
      m_ctx.state         = XARE_POS_OPEN;
      m_ctx.ticket        = res.ticket;
      m_ctx.direction     = plan.direction;
      m_ctx.volume_initial= plan.volume;
      m_ctx.volume_current= plan.volume;
      m_ctx.entry_price   = res.fill_price;
      m_ctx.sl_price      = plan.sl_price;
      m_ctx.tp_price      = plan.tp_price;
      m_ctx.risk_pct_at_entry = plan.risk_pct;
      m_ctx.score_at_entry    = plan.score;
      m_ctx.setup         = plan.setup;
      m_ctx.session       = plan.session;
      m_ctx.regime        = regime_label;
      m_ctx.open_reason   = plan.reason;
      m_ctx.open_time     = TimeCurrent();
      m_ctx.open_bar_time = bar_time;
      m_ctx.bars_in_trade = 0;
      m_ctx.be_done       = false;
      m_ctx.partial_done  = false;
     }

   bool              HaveContext(void) const { return m_have_ctx; }
   ulong             Ticket(void) const      { return m_ticket; }

   //--- copy-out of the tracked context (for the pure ExitEngine)
   bool              GetContext(SXarePosition &out) const
     {
      if(!m_have_ctx)
         return false;
      out = m_ctx;
      return true;
     }

   //--- record a successfully applied management order (state machine §30)
   void              OnManagementApplied(const ENUM_XARE_MGMT_ACTION action,
                                         const string reason)
     {
      if(!m_have_ctx)
         return;
      if(action == XARE_MGMT_MODIFY_SL)
        {
         if(StringFind(reason, "break-even") >= 0)
           {
            m_ctx.be_done = true;
            m_ctx.state   = XARE_POS_PROTECTED;
           }
         else if(StringFind(reason, "trailing") >= 0)
            m_ctx.state = XARE_POS_TRAILING;
        }
      else if(action == XARE_MGMT_PARTIAL_CLOSE)
        {
         m_ctx.partial_done = true;
         m_ctx.state        = XARE_POS_PARTIAL_PROFIT;
        }
     }

   //--- live state of OUR position: XARE_POS_NONE when none exists
   ENUM_XARE_POS_STATE GetState(int &open_count_out) const
     {
      open_count_out = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || !PositionSelectByTicket(tk))
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
            PositionGetInteger(POSITION_MAGIC) != m_magic)
            continue;
         open_count_out++;
         double sl  = PositionGetDouble(POSITION_SL);
         double tp  = PositionGetDouble(POSITION_TP);
         double vol = PositionGetDouble(POSITION_VOLUME);

         if(sl > 0.0 && tp == 0.0)
            return XARE_POS_TRAILING;   // TP removed: management in progress
         //--- partial detection: current volume below the tracked initial
         //--- volume (MQL5 exposes no POSITION_VOLUME_INITIAL property)
         if(m_have_ctx && m_ctx.volume_initial > 0.0 &&
            vol < m_ctx.volume_initial - 1e-8)
            return XARE_POS_PARTIAL_PROFIT;
         return XARE_POS_OPEN;
        }
      return XARE_POS_NONE;
     }

   //--- open-position count for OUR magic+symbol (for caps/gates)
   int               CountOpen(void) const
     {
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || !PositionSelectByTicket(tk))
            continue;
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == m_magic)
            n++;
        }
      return n;
     }

   //--- duplicate-order protection (§30/§29): never plan a second position
   bool              DuplicateGuardOK(void) const
     {
      return (CountOpen() == 0);
     }

   //--- bar-close bookkeeping: on close, classify exit + build record.
   //--- slippage entry: recorded fill vs original plan entry (points).
   bool              CheckClosed(const SXareSymbolProps &props,
                                 SXareExitRecord &rec)
     {
      rec.present = false;
      if(!m_have_ctx)
         return false;

      int cnt = 0;
      ENUM_XARE_POS_STATE st = GetState(cnt);
      if(st != XARE_POS_NONE)
        {
         m_ctx.bars_in_trade++;          // still open: one bar older
         return false;
        }

      //--- position gone: closed. Use history to classify the exit.
      if(!HistorySelectByPosition(m_ticket))
        {
         if(m_log != NULL)
            m_log.Error("POS", StringFormat("history select failed for #%I64u", m_ticket));
         ResetCtx();
         return false;
        }

      double exit_price = 0.0;
      double pl_money   = 0.0;
      datetime close_time = TimeCurrent();
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
        {
         ulong dt = HistoryDealGetTicket(i);
         if(dt == 0)
            continue;
         long entry_flag = HistoryDealGetInteger(dt, DEAL_ENTRY);
         if(entry_flag == DEAL_ENTRY_OUT || entry_flag == DEAL_ENTRY_OUT_BY)
           {
            exit_price  = HistoryDealGetDouble(dt, DEAL_PRICE);
            pl_money   += HistoryDealGetDouble(dt, DEAL_PROFIT)
                        + HistoryDealGetDouble(dt, DEAL_SWAP)
                        + HistoryDealGetDouble(dt, DEAL_COMMISSION);
            close_time  = (datetime)HistoryDealGetInteger(dt, DEAL_TIME);
           }
        }

      rec.present       = true;
      rec.ticket        = m_ticket;
      rec.direction     = m_ctx.direction;
      rec.volume        = m_ctx.volume_initial;
      rec.entry_price   = m_ctx.entry_price;
      rec.exit_price    = exit_price;
      rec.sl_price      = m_ctx.sl_price;
      rec.tp_price      = m_ctx.tp_price;
      rec.pl_money      = pl_money;
      rec.bars_in_trade = m_ctx.bars_in_trade;
      rec.reason        = ClassifyExit(m_ctx.direction, m_ctx.entry_price,
                                       m_ctx.sl_price, m_ctx.tp_price, exit_price);
      rec.setup         = m_ctx.setup;
      rec.session       = m_ctx.session;
      rec.regime        = "";
      rec.score         = m_ctx.score_at_entry;
      rec.risk_pct      = m_ctx.risk_pct_at_entry;
      rec.slippage_points = 0.0;
      rec.open_reason   = m_ctx.open_reason;
      rec.close_time    = close_time;

      //--- R multiple from actual stop distance (never re-derived wrongly)
      double sl_dist = MathAbs(m_ctx.entry_price - m_ctx.sl_price);
      rec.r_multiple = (sl_dist > 0.0)
                       ? ((rec.direction > 0)
                          ? (exit_price - m_ctx.entry_price) / sl_dist
                          : (m_ctx.entry_price - exit_price) / sl_dist)
                       : 0.0;

      if(m_log != NULL)
         m_log.Info("POS", StringFormat(
            "closed #%I64u %s %s exit=%s pl=%.2f r=%.2f bars=%d",
            rec.ticket, rec.direction > 0 ? "BUY" : "SELL",
            XareExitToString(rec.reason),
            DoubleToString(exit_price, props.digits),
            rec.pl_money, rec.r_multiple, rec.bars_in_trade));

      ResetCtx();
      return true;
     }
  };
#endif // __XARE_POSITIONMANAGER_MQH__
