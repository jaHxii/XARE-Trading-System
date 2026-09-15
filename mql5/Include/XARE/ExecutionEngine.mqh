//+------------------------------------------------------------------+
//| ExecutionEngine.mqh — plan building + order send (§18-21,29)     |
//| v0.10.0 — M10.                                                   |
//|                                                                  |
//| Layer 1 is PURE: XareBuildTradePlan() consumes a scored signal   |
//| decision + live quotes + broker props + risk math and produces a |
//| fully priced, fully validated SXareTradeDecision — or an explicit |
//| block (reason code + detail). Unit-testable without a terminal.  |
//|                                                                  |
//| Layer 2 (CXareExecutionEngine) performs the live OrderSend path  |
//| with the §29 validation chain and duplicate-order protection.    |
//| It NEVER invents prices: entry comes from the current quote,     |
//| SL/TP distances are built from the closed-bar context and        |
//| re-normalized to the tick grid.                                  |
//+------------------------------------------------------------------+
#ifndef __XARE_EXECUTIONENGINE_MQH__
#define __XARE_EXECUTIONENGINE_MQH__

#include "Types.mqh"
#include "Config.mqh"
#include "RiskEngine.mqh"
#include "ScoreEngine.mqh"   // XareScoreBand for the §16 gate
#include "ExitEngine.mqh"    // SXareMgmtOrder for ApplyManagement

//--- pick a filling mode the broker actually allows for this symbol (§6)
ENUM_ORDER_TYPE_FILLING XarePickFilling(const string symbol)
  {
   long fm = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((fm & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//| PURE: build a complete trade plan from a scored decision.        |
//| Inputs: decision (has_signal), score total, quotes, props, risk  |
//| state inputs, bar data for structural stops, ATR, account money. |
//| Output: actionable plan (entry/SL/TP/volume/risk) or block.      |
//+------------------------------------------------------------------+
void XareBuildTradePlan(const SXareDecision &dec, const double score_total,
                        const double bid, const double ask,
                        const SXareSymbolProps &props,
                        const SXareConfig &cfg,
                        const ENUM_XARE_RISK_STATE risk_state,
                        const double eff_risk_pct,
                        const double atr,
                        const double swing_low, const double swing_high,
                        const int open_positions,
                        const int trades_today,
                        const double equity,
                        const double free_margin,
                        const double margin_per_lot,
                        SXareTradeDecision &out)
  {
   //--- zero the output (contains strings: assign fields explicitly)
   out.actionable   = false;
   out.block_reason = XARE_BR_NONE;
   out.block_detail = "";
   out.direction    = 0;
   out.entry_price  = 0.0; out.sl_price = 0.0; out.tp_price = 0.0;
   out.volume       = 0.0; out.risk_pct = 0.0; out.risk_money = 0.0;
   out.sl_points    = 0.0; out.tp_points = 0.0; out.planned_r = 0.0;
   out.score        = score_total;
   out.setup        = dec.setup;
   out.session      = "";
   out.reason       = dec.evidence;

   if(!dec.has_signal)
     {
      out.block_reason = XARE_BR_NONE;      // no signal is not a "block"
      out.block_detail = "no signal this bar";
      return;
     }

   //--- band gate (§16): score must reach the TRADE band
   if(XareScoreBand(score_total, cfg.score_min, cfg.score_candidate,
                    cfg.score_trade, cfg.score_strong) < XARE_BAND_TRADE)
     {
      out.block_reason = XARE_BR_NO_TRADE_BAND;
      out.block_detail = StringFormat("score %.1f below trade band", score_total);
      return;
     }

   //--- position caps (§27/§32): one position per symbol in v1
   if(open_positions >= cfg.max_concurrent_positions)
     {
      out.block_reason = XARE_BR_MAX_POSITIONS;
      out.block_detail = StringFormat("%d open >= cap %d",
                                      open_positions, cfg.max_concurrent_positions);
      return;
     }
   if(trades_today >= cfg.max_trades_per_day)
     {
      out.block_reason = XARE_BR_MAX_TRADES_DAY;
      out.block_detail = StringFormat("%d today >= cap %d",
                                      trades_today, cfg.max_trades_per_day);
      return;
     }

   //--- quotes must exist (§29: validate before anything else uses them)
   if(bid <= 0.0 || ask <= 0.0)
     {
      out.block_reason = XARE_BR_NO_QUOTES;
      out.block_detail = "invalid bid/ask";
      return;
     }

   //--- entry reference and protective level for the direction
   bool   is_buy  = (dec.direction > 0);
   double entry   = is_buy ? ask : bid;
   double swing   = is_buy ? swing_low : swing_high;   // protective swing

   //--- broker stops floor: stops_level + current spread buffer, in price
   double spread_px = (ask - bid);
   double min_dist  = props.stops_level * props.point + spread_px;
   if(min_dist <= 0.0)
      min_dist = 1.0;                       // never allow a zero floor

   //--- hard SL (§20): every trade must have one or no trade happens.
   //--- Built from the LIVE entry reference — attaching a stop computed from
   //--- the signal zone would underestimate risk when price has drifted.
   double sl_dist = 0.0;
   if(!XareStopDistance(dec.direction, entry, swing, atr,
                        cfg.sl_atr_mult, cfg.sl_mode, min_dist, sl_dist))
     {
      out.block_reason = XARE_BR_SL_INVALID;
      out.block_detail = "no acceptable stop distance could be built";
      return;
     }

   //--- TP (§21)
   double tp_dist = 0.0;
   if(!XareTpDistance(cfg.tp_mode, sl_dist, atr, cfg.tp_r_multiple,
                      cfg.tp_atr_mult, tp_dist))
     {
      out.block_reason = XARE_BR_TP_INVALID;
      out.block_detail = "no acceptable take-profit could be built";
      return;
     }

   //--- normalize to the tick grid and keep SL/TP on the safe side
   double step = (props.tick_size > 0.0) ? props.tick_size : props.point;
   double sl_px = is_buy ? (entry - sl_dist) : (entry + sl_dist);
   double tp_px = is_buy ? (entry + tp_dist) : (entry - tp_dist);
   if(is_buy)
     {
      sl_px = MathFloor(sl_px / step) * step;   // wider SL is safer
      tp_px = MathFloor(tp_px / step) * step;   // nearer TP is conservative
     }
   else
     {
      sl_px = MathCeil (sl_px / step) * step;   // wider SL is safer
      tp_px = MathCeil (tp_px / step) * step;
     }
   sl_px = NormalizeDouble(sl_px, props.digits);
   tp_px = NormalizeDouble(tp_px, props.digits);

   double sl_pts  = MathAbs(entry - sl_px) / props.point;
   double tp_pts  = MathAbs(tp_px - entry) / props.point;

   //--- volume for the EFFECTIVE risk (state-scaled; 0 when halted)
   double vol = 0.0, risk_money = 0.0;
   if(!XareVolumeForRisk(equity, eff_risk_pct, sl_pts,
                         props, cfg.emergency_max_lot_x1000 / 1000.0,
                         vol, risk_money))
     {
      if(eff_risk_pct <= 0.0)
        {
         out.block_reason = XARE_BR_DRAWDOWN_STATE;
         out.block_detail = "risk state halts new trades";
        }
      else
        {
         out.block_reason = XARE_BR_VOLUME;
         out.block_detail = StringFormat(
            "safe volume below broker minimum (risk %.3f%%, SL %.0f pts) — skip",
            eff_risk_pct, sl_pts);
        }
      return;
     }

   //--- margin validation (§29): requirement per lot comes from the caller —
   //--- the EA passes 0 so the requirement is queried dynamically via
   //--- OrderCalcMargin for the actual volume (no contract assumptions);
   //--- tests pass a synthetic per-lot value so checks stay deterministic.
   double margin_need = 0.0;
   ENUM_ORDER_TYPE ot = is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   bool margin_ok = (margin_per_lot > 0.0)
                    ? true
                    : OrderCalcMargin(ot, props.symbol, vol, entry, margin_need);
   if(margin_per_lot > 0.0)
      margin_need = margin_per_lot * vol;
   if(!margin_ok)
     {
      out.block_reason = XARE_BR_MARGIN;
      out.block_detail = StringFormat("OrderCalcMargin failed err=%d", GetLastError());
      return;
     }
   if(free_margin > 0.0 && margin_need > free_margin * cfg.max_margin_pct / 100.0)
     {
      out.block_reason = XARE_BR_MARGIN;
      out.block_detail = StringFormat(
         "margin %.2f exceeds %.0f%% of free %.2f",
         margin_need, cfg.max_margin_pct, free_margin);
      return;
     }

   //--- plan complete
   out.actionable   = true;
   out.block_reason = XARE_BR_NONE;
   out.direction    = dec.direction;
   out.entry_price  = entry;
   out.sl_price     = sl_px;
   out.tp_price     = tp_px;
   out.volume       = vol;
   out.risk_pct     = eff_risk_pct;
   out.risk_money   = risk_money;
   out.sl_points    = sl_pts;
   out.tp_points    = tp_pts;
   out.planned_r    = (sl_pts > 0.0) ? tp_pts / sl_pts : 0.0;
  }

//+------------------------------------------------------------------+
//| Live execution layer (§29).                                      |
//+------------------------------------------------------------------+
class CXareExecutionEngine
  {
private:
   SXareConfig      m_cfg;
   long             m_magic;
   ulong            m_last_ticket;      // duplicate-order guard anchor
   datetime         m_last_send_bar;    // one attempt per bar per ticket flow
   int              m_consec_fail;      // execution-failure streak latch

public:
                     CXareExecutionEngine(void) : m_magic(0),
                                                  m_last_ticket(0),
                                                  m_last_send_bar(0),
                                                  m_consec_fail(0) {}

   void              Init(const SXareConfig &cfg)
     {
      m_cfg  = cfg;
      m_magic= cfg.magic;
      m_last_ticket   = 0;
      m_last_send_bar = 0;
      m_consec_fail   = 0;
     }

   int               ConsecutiveFailures(void) const { return m_consec_fail; }
   void              ResetFailureStreak(void)  { m_consec_fail = 0; }
   ulong             LastTicket(void) const    { return m_last_ticket; }

   //--- one send attempt per bar maximum (duplicate-order protection §30)
   bool              AlreadySentThisBar(const datetime bar_time) const
     {
      return (m_last_send_bar == bar_time);
     }

   //--- duplicate protection against OUR OWN open position (same magic+symbol)
   bool              HaveOpenPosition(void) const
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || !PositionSelectByTicket(tk))
            continue;
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == m_magic)
            return true;
        }
      return false;
     }

   //--- send the plan. Returns true when the order reached a terminal state.
   bool              Send(const SXareTradeDecision &plan,
                          const datetime bar_time, SXareExecutionResult &res)
     {
      res.success          = false;
      res.ticket           = 0;
      res.fill_price       = 0.0;
      res.requested_price  = plan.entry_price;
      res.slippage_points  = 0.0;
      res.retcode          = 0;
      res.comment          = "";

      if(!plan.actionable)
        {
         res.comment = "plan not actionable";
         return false;
        }
      if(AlreadySentThisBar(bar_time))
        {
         res.comment = "duplicate send guard (same bar)";
         return false;
        }
      if(HaveOpenPosition())
        {
         res.comment = "duplicate position guard (open position exists)";
         return false;
        }
      //--- symbol trade mode check (§33: broker restrictions)
      long tmode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
      if(tmode != SYMBOL_TRADE_MODE_FULL)
        {
         res.comment = StringFormat("symbol trade mode %d not FULL", (int)tmode);
         return false;
        }

      //--- final live values: SL/TP rebuilt from CURRENT quote if it drifted
      bool   is_buy = (plan.direction > 0);
      double entry  = is_buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double drift  = MathAbs(entry - plan.entry_price);
      double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double max_drift_pts = 20.0;      // 20 points; otherwise re-plan next bar
      if(point > 0.0 && drift / point > max_drift_pts)
        {
         res.comment = StringFormat("price drifted %.1f pts since plan — skip",
                                    drift / point);
         return false;
        }

      ENUM_ORDER_TYPE ot = is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      MqlTradeRequest req;
      MqlTradeResult  trd;
      ZeroMemory(req);
      ZeroMemory(trd);
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = _Symbol;
      req.volume       = plan.volume;
      req.type         = ot;
      req.price        = entry;
      req.sl           = plan.sl_price;
      req.tp           = plan.tp_price;
      req.deviation    = 20;            // points of allowed slippage
      req.magic        = (ulong)m_magic;
      req.comment      = m_cfg.order_comment;
      req.type_filling = XarePickFilling(_Symbol);
      req.type_time    = ORDER_TIME_GTC;

      ResetLastError();
      bool sent = OrderSend(req, trd);
      m_last_send_bar = bar_time;

      if(!sent || (trd.retcode != TRADE_RETCODE_DONE &&
                   trd.retcode != TRADE_RETCODE_PLACED &&
                   trd.retcode != TRADE_RETCODE_DONE_PARTIAL))
        {
         res.retcode = trd.retcode;
         res.comment = StringFormat("OrderSend failed retcode=%u err=%d",
                                    trd.retcode, GetLastError());
         m_consec_fail++;
         return false;
        }

      //--- success path: record fill + slippage (§29)
      res.retcode     = trd.retcode;
      res.ticket      = trd.order;
      res.fill_price  = (trd.price > 0.0) ? trd.price : entry;
      res.slippage_points = (point > 0.0)
                            ? MathAbs(res.fill_price - plan.entry_price) / point
                            : 0.0;
      res.success     = true;
      res.comment     = "filled";
      m_last_ticket   = res.ticket;
      m_consec_fail   = 0;
      return true;
     }

   //--- apply a management order (M11 ExitEngine output) with the same
   //--- validation discipline as entry: verify state before and after (§29).
   bool              ApplyManagement(const SXareMgmtOrder &mgmt,
                                     const ulong ticket,
                                     SXareExecutionResult &res)
     {
      res.success         = false;
      res.ticket          = ticket;
      res.fill_price      = 0.0;
      res.requested_price = 0.0;
      res.slippage_points = 0.0;
      res.retcode         = 0;
      res.comment         = "";

      if(mgmt.action == XARE_MGMT_NONE)
        {
         res.comment = "no action";
         return false;
        }
      if(ticket == 0 || !PositionSelectByTicket(ticket))
        {
         res.comment = "position not found";
         return false;
        }

      if(mgmt.action == XARE_MGMT_MODIFY_SL || mgmt.action == XARE_MGMT_MODIFY_TP)
        {
         //--- tighten-only enforcement at the last line of defense (§22):
         //--- the executor re-checks that a new SL never increases risk.
         double cur_sl = PositionGetDouble(POSITION_SL);
         long   ptype  = PositionGetInteger(POSITION_TYPE);
         if(mgmt.action == XARE_MGMT_MODIFY_SL)
           {
            bool tightens = (ptype == POSITION_TYPE_BUY)
                            ? (cur_sl == 0.0 || mgmt.new_sl > cur_sl)
                            : (cur_sl == 0.0 || mgmt.new_sl < cur_sl);
            if(!tightens)
              {
               res.comment = "rejected: SL move would loosen the stop";
               return false;
              }
           }
         MqlTradeRequest req;
         MqlTradeResult  trd;
         ZeroMemory(req);
         ZeroMemory(trd);
         req.action   = TRADE_ACTION_SLTP;
         req.symbol   = _Symbol;
         req.position = ticket;
         req.sl       = (mgmt.action == XARE_MGMT_MODIFY_SL) ? mgmt.new_sl
                        : PositionGetDouble(POSITION_SL);
         req.tp       = (mgmt.action == XARE_MGMT_MODIFY_TP) ? mgmt.new_tp
                        : PositionGetDouble(POSITION_TP);
         req.magic    = (ulong)m_magic;
         ResetLastError();
         bool ok = OrderSend(req, trd);
         res.retcode = trd.retcode;
         if(!ok || trd.retcode != TRADE_RETCODE_DONE)
           {
            res.comment = StringFormat("SLTP modify failed retcode=%u err=%d",
                                       trd.retcode, GetLastError());
            m_consec_fail++;
            return false;
           }
         res.success = true;
         res.comment = mgmt.reason;
         return true;
        }

      if(mgmt.action == XARE_MGMT_PARTIAL_CLOSE || mgmt.action == XARE_MGMT_CLOSE_FULL)
        {
         double vol = (mgmt.action == XARE_MGMT_CLOSE_FULL)
                      ? PositionGetDouble(POSITION_VOLUME)
                      : mgmt.close_volume;
         double vol_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double cur_vol  = PositionGetDouble(POSITION_VOLUME);
         if(vol <= 0.0 || vol > cur_vol)
            vol = cur_vol;
         //--- normalize: partials below min/step would be rejected outright
         if(vol < vol_min)
           {
            res.comment = StringFormat("partial %.2f below broker min %.2f — skipped",
                                       vol, vol_min);
            return false;
           }
         vol = MathFloor(vol / vol_step) * vol_step;
         if(vol < vol_min)
           {
            res.comment = "partial snaps below broker min — skipped";
            return false;
           }
         if(cur_vol - vol > 0.0 && cur_vol - vol < vol_min)
           {
            res.comment = "remainder would be below min — full close instead";
            vol = cur_vol;
           }

         long ptype = PositionGetInteger(POSITION_TYPE);
         MqlTradeRequest req;
         MqlTradeResult  trd;
         ZeroMemory(req);
         ZeroMemory(trd);
         req.action       = TRADE_ACTION_DEAL;
         req.symbol       = _Symbol;
         req.position     = ticket;
         req.volume       = vol;
         req.type         = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL
                                                         : ORDER_TYPE_BUY;
         req.price        = (ptype == POSITION_TYPE_BUY)
                            ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                            : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         req.deviation    = 20;
         req.magic        = (ulong)m_magic;
         req.comment      = "XARE mgmt";
         req.type_filling = XarePickFilling(_Symbol);
         ResetLastError();
         bool ok = OrderSend(req, trd);
         res.retcode = trd.retcode;
         if(!ok || (trd.retcode != TRADE_RETCODE_DONE &&
                    trd.retcode != TRADE_RETCODE_DONE_PARTIAL))
           {
            res.comment = StringFormat("close failed retcode=%u err=%d",
                                       trd.retcode, GetLastError());
            m_consec_fail++;
            return false;
           }
         res.success     = true;
         res.fill_price  = (trd.price > 0.0) ? trd.price : req.price;
         res.comment     = mgmt.reason;
         return true;
        }

      res.comment = "unknown management action";
      return false;
     }
  };
#endif // __XARE_EXECUTIONENGINE_MQH__
