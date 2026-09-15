//+------------------------------------------------------------------+
//| Diagnostics.mqh — optional chart dashboard (spec §35/§68)        |
//| v0.1.0 — M1: panel scaffold; risk/signal lines populate later.   |
//+------------------------------------------------------------------+
#ifndef __XARE_DIAGNOSTICS_MQH__
#define __XARE_DIAGNOSTICS_MQH__

#include "Types.mqh"

//--- simple fixed-prefix panel; MQL5 Comment() alternative would fight with
//--- other tools, so we use OBJ_LABEL objects on one corner.
class CXareDiagnostics
  {
private:
   bool             m_enabled;
   string           m_prefix;
   string           m_version;
   int              m_x, m_y, m_line_h;
   int              m_rows;

   void              Row(const int idx, const string text, const color clr)
     {
      string name = m_prefix + "r" + IntegerToString(idx);
      if(ObjectFind(0, name) < 0)
        {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, m_x);
         ObjectSetInteger(0, name, OBJPROP_YDISTANCE, m_y + idx*m_line_h);
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
         ObjectSetString (0, name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
        }
      ObjectSetString (0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      m_rows = MathMax(m_rows, idx+1);
     }

   void              Clear(void)
     {
      for(int i=0; i<m_rows; i++)
         ObjectDelete(0, m_prefix + "r" + IntegerToString(i));
      m_rows = 0;
     }

public:
                     CXareDiagnostics(void) : m_enabled(false), m_prefix("XARE_UI_"),
                                              m_version("v0.1.0"),
                                              m_x(12), m_y(24), m_line_h(16), m_rows(0) {}

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

   //--- M1 snapshot; NO-TRADE reason line added when SignalEngine exists
   void              Update(const string symbol, const string timeframe,
                            const ENUM_XARE_MODE mode, const double price,
                            const int spread_points, const string regime,
                            const int regime_conf, const string signal,
                            const double score, const string risk_state,
                            const double daily_pl, const double cur_dd_pct,
                            const int open_positions, const string session,
                            const bool trading_allowed)
     {
      if(!m_enabled)
         return;
      Clear();

      color c_good   = clrLimeGreen;
      color c_bad    = clrOrangeRed;
      color c_neut   = clrSilver;
      color c_warn   = clrGold;

      bool connected = TerminalInfoInteger(TERMINAL_CONNECTED)!=0;
      Row(0,  "XARE " + m_version + "  |  " + (connected?"CONNECTED":"OFFLINE"),
          connected ? c_good : c_bad);
      Row(1,  "SYM/TF : " + symbol + " " + timeframe + "   MODE: " + XareModeToString(mode), c_neut);
      Row(2,  "PRICE  : " + DoubleToString(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) +
              "   SPREAD: " + IntegerToString(spread_points) + "pt", c_neut);
      Row(3,  "REGIME : " + regime + " (" + IntegerToString(regime_conf) + ")", c_neut);
      Row(4,  "SIGNAL : " + signal + "   SCORE: " + DoubleToString(score,0), c_neut);
      Row(5,  "RISK   : " + risk_state, risk_state=="NORMAL" ? c_good :
              (risk_state=="HALTED" ? c_bad : c_warn));
      bool pl_ok = (daily_pl>=0.0);
      Row(6,  "DAY P/L: " + DoubleToString(daily_pl,2) + "   DD: " + DoubleToString(cur_dd_pct,1) + "%",
              pl_ok ? c_good : c_bad);
      Row(7,  "POS    : " + IntegerToString(open_positions) + "   SESSION: " + session, c_neut);
      bool allowed = trading_allowed;
      Row(8,  "PERMIT : " + (allowed ? "TRADING ALLOWED" : "TRADING BLOCKED"),
              allowed ? c_good : c_bad);
      Row(9,  "ACTION : " + (open_positions>0 ? "MANAGE POSITION" : "WAIT FOR SETUP"), c_neut);

      ChartRedraw(0);
     }
  };

#endif // __XARE_DIAGNOSTICS_MQH__
