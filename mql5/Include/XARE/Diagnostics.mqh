//+------------------------------------------------------------------+
//| Diagnostics.mqh — optional chart dashboard (spec §35/§68)        |
//| v0.15.0 — M19: full two-column panel.                            |
//|                                                                  |
//| Design rules (§68): compact, non-cluttering, readable labels,    |
//| clear green/red/neutral states. Two columns keep the panel       |
//| short; a NO-TRADE explanation block appears only when relevant.  |
//| All state arrives pre-formatted from XARE.mq5 — this class only  |
//| renders, it never queries engines (single responsibility).       |
//+------------------------------------------------------------------+
#ifndef __XARE_DIAGNOSTICS_MQH__
#define __XARE_DIAGNOSTICS_MQH__

#include "Types.mqh"

class CXareDiagnostics
  {
private:
   bool             m_enabled;
   string           m_prefix;
   string           m_version;
   int              m_x, m_y, m_line_h, m_col2_x;
   int              m_rows;          // highest row index used last frame

   //--- create-once, update-every-tick label rendering
   void              Cell(const int idx, const int x_off, const string text,
                          const color clr, const int font_size = 9)
     {
      string name = m_prefix + "r" + IntegerToString(idx) +
                    (x_off > 0 ? "c" : "l");
      if(ObjectFind(0, name) < 0)
        {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, m_x + x_off);
         ObjectSetInteger(0, name, OBJPROP_YDISTANCE, m_y + idx*m_line_h);
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, font_size);
         ObjectSetString (0, name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
         ObjectSetInteger(0, name, OBJPROP_BACK, false);
        }
      ObjectSetString (0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
     }

   void              Row(const int idx, const string text, const color clr,
                         const int font_size = 9)
     {
      Cell(idx, 0, text, clr, font_size);
      Cell(idx, m_col2_x, "", clr);       // keep the right column blank
     }

   //--- delete labels beyond the current row count (panel can shrink)
   void              Prune(const int rows_now)
     {
      for(int i = rows_now; i < m_rows; i++)
        {
         ObjectDelete(0, m_prefix + "r" + IntegerToString(i) + "l");
         ObjectDelete(0, m_prefix + "r" + IntegerToString(i) + "c");
        }
      m_rows = rows_now;
     }

   void              Clear(void)
     {
      Prune(0);
     }

public:
                     CXareDiagnostics(void) : m_enabled(false), m_prefix("XARE_UI_"),
                                              m_version("v0.1.0"),
                                              m_x(12), m_y(24), m_line_h(15),
                                              m_col2_x(260), m_rows(0) {}

   void              Init(const bool enabled, const string version)
     {
      m_enabled = enabled;
      m_version = version;
     }

   void              Deinit(void)
     {
      if(!m_enabled)
         return;
      Clear();
      ChartRedraw(0);
     }

   //--- snapshot struct: everything the panel shows, assembled by the EA
   struct PanelData
     {
      string           version;
      bool             connected;
      string           symbol;
      string           timeframe;
      datetime         candle_time;     // current candle open time (server)
      double           price;
      int              digits;
      int              spread_points;
      string           regime;
      int              regime_conf;
      string           signal;          // "LONG"/"SHORT"/"NO_TRADE (REASON)"
      double           score;
      string           components;      // one-line component breakdown
      string           risk_state;
      double           daily_pl;
      double           daily_dd_pct;
      double           cur_dd_pct;
      int              open_positions;
      string           pos_detail;      // "BUY 0.08 @ 2000.00 SL 1994.0 TP 2012.0"
      string           session;
      string           news;            // "CLEAR" / "BLACKOUT: FOMC" / "NO DATA"
      bool             trading_allowed;
      string           notrade_reason;  // full NO_TRADE explanation ("" = none)
      string           action;
      //--- v0.17.0 hardening additions (§22)
      string           account;         // "1012345 DEMO" / broker company
      string           server_time;     // server clock, hh:mm
      string           stage;           // capital stage label
      double           weekly_pl;
      double           margin_level;    // %, 0 = flat
      string           health;          // READY / BLOCKED (short)
     };

   void              Update(const PanelData &d)
     {
      if(!m_enabled)
         return;
      Clear();

      color c_good = clrLimeGreen;    // healthy / permitted / in profit
      color c_bad  = clrOrangeRed;    // blocked / losing / offline
      color c_neut = clrSilver;       // neutral information
      color c_warn = clrGold;         // caution / degraded
      color c_head = clrDeepSkyBlue;  // header

      int r = 0;
      Row(r, "XARE " + d.version + "   " + (d.connected ? "CONNECTED" : "OFFLINE"),
          d.connected ? c_head : c_bad);
      r++;
      Row(r, d.symbol + " " + d.timeframe + "   candle " +
          TimeToString(d.candle_time, TIME_DATE|TIME_MINUTES), c_neut);
      r++;
      Row(r, "ACCT " + d.account + "   SRV " + d.server_time, c_neut);
      r++;
      Row(r, "PRICE " + DoubleToString(d.price, d.digits) +
          "   SPREAD " + IntegerToString(d.spread_points) + "pt", c_neut);
      r++;

      //--- regime with traffic-light confidence
      color rc = (d.regime_conf >= 65) ? c_good :
                 (d.regime_conf >= 45 ? c_warn : c_neut);
      Row(r, "REGIME " + d.regime + "  conf " + IntegerToString(d.regime_conf), rc);
      r++;

      //--- signal + score; green when an actual signal exists
      bool has_sig = (StringFind(d.signal, "NO_TRADE") != 0 && d.signal != "-");
      Row(r, "SIGNAL " + d.signal + "   SCORE " + DoubleToString(d.score, 0),
          has_sig ? c_good : c_neut);
      r++;
      Row(r, "  " + d.components, c_neut);
      r++;

      //--- risk state: green NORMAL, gold CAUTION..DEFENSIVE, red HALTED
      color rkc = (d.risk_state == "NORMAL") ? c_good : c_warn;
      if(d.risk_state == "HALTED")
         rkc = c_bad;
      Row(r, "RISK " + d.risk_state + "  STAGE " + d.stage +
          "  day " + DoubleToString(d.daily_pl, 2) +
          "  wk " + DoubleToString(d.weekly_pl, 2) +
          "  dayDD " + DoubleToString(d.daily_dd_pct, 1) + "%" +
          "  dd " + DoubleToString(d.cur_dd_pct, 1) + "%",
          (d.daily_pl >= 0.0 && d.risk_state != "HALTED") ? rkc : c_bad);
      r++;
      Row(r, "MARGIN-LVL " +
          (d.margin_level > 0.0 ? DoubleToString(d.margin_level, 0) + "%" : "flat") +
          "   HEALTH " + d.health,
          (StringLen(d.health) > 0 && StringFind(d.health, "READY") < 0) ? c_bad : c_good);
      r++;

      //--- open position / flat
      if(d.open_positions > 0)
         Row(r, "POS " + d.pos_detail, c_good);
      else
         Row(r, "POS flat", c_neut);
      r++;

      Row(r, "SESS " + d.session + "   NEWS " + d.news,
          d.news == "CLEAR" ? c_good : (d.news == "NO DATA" ? c_neut : c_bad));
      r++;

      //--- trading permission: the single clearest red/green line
      Row(r, d.trading_allowed ? "PERMIT TRADING ALLOWED" : "PERMIT TRADING BLOCKED",
          d.trading_allowed ? c_good : c_bad);
      r++;

      //--- NO-TRADE explanation block: only when there is something to explain
      if(StringLen(d.notrade_reason) > 0)
        {
         Row(r, "NO TRADE: " + d.notrade_reason, c_warn);
         r++;
        }
      Row(r, "ACTION " + d.action, c_neut);
      r++;

      Prune(r);
      ChartRedraw(0);
     }
  };
#endif // __XARE_DIAGNOSTICS_MQH__
