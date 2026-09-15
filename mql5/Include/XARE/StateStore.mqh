//+------------------------------------------------------------------+
//| StateStore.mqh — crash/restart persistence (hardening §20)       |
//| v0.17.0                                                          |
//|                                                                  |
//| Persists everything the EA must reconstruct after a terminal,    |
//| EA, or VPS restart (spec §20): risk anchors, day/week keys,      |
//| streaks, cooldowns, losing-days, profit-lock floor, Friday       |
//| close state, and the open position's management context.         |
//|                                                                  |
//| Design:                                                          |
//|   - JSON object, one "key": value pair per line (flat schema).   |
//|   - ATOMIC write: state.tmp is written+closed first, then moved  |
//|     over state.json (FileMove FILE_REWRITE). A .bak of the last  |
//|     good file is kept; parse failure falls back to .bak.         |
//|   - Encode/parse are PURE functions (SELF_TEST T17 round-trip).  |
//|   - Tester-safe: persistence is DISABLED inside the Strategy     |
//|     Tester (tester runs must not read a live account's state).   |
//|   - Restoring state can NEVER create an order (§20: restart must |
//|     not duplicate trades); it only restores counters/anchors and |
//|     adopts the management context of an ALREADY-OPEN position.   |
//+------------------------------------------------------------------+
#ifndef __XARE_STATESTORE_MQH__
#define __XARE_STATESTORE_MQH__

#include "Types.mqh"

//--- persisted state snapshot (flat; strings JSON-escaped on encode)
struct SXarePersistedState
  {
   int              version;            // schema version
   // risk anchors / counters
   long             day_key;
   long             week_key;
   double           day_start_equity;
   double           week_start_equity;
   double           peak_equity;
   double           init_equity;        // §9 lock baseline
   int              trades_today;
   int              consec_losses;
   int              consec_losing_days; // §10/§11
   datetime         cooldown_until;     // streak cooldown
   datetime         post_sl_until;      // §12 post-SL cooldown
   datetime         slip_until;         // §12 slippage cooldown
   int              trades_session;     // §12 per-session count
   string           session_name;       // session the count belongs to
   // profit lock (§9)
   double           lock_floor;         // 0 = none armed
   // Friday close-all (§15) done-flag for the current episode
   int              friday_close_done;
   // open position context (adopted after restart)
   int              pos_present;
   long             pos_ticket;      // MT5 tickets fit in long (no ulong conversion)
   int              pos_state;
   int              pos_direction;
   double           pos_volume_initial;
   double           pos_volume_current;
   double           pos_entry_price;
   double           pos_sl_price;
   double           pos_tp_price;
   double           pos_risk_pct_at_entry;
   double           pos_score_at_entry;
   int              pos_setup;
   string           pos_session;
   string           pos_regime;
   string           pos_open_reason;
   datetime         pos_open_time;
   datetime         pos_open_bar_time;
   int              pos_bars_in_trade;
   int              pos_be_done;
   int              pos_partial_done;
  };

//--- explicit reset (struct contains strings — never ZeroMemory)
void XareResetPersistedState(SXarePersistedState &s)
  {
   s.version             = 1;
   s.day_key             = -1;
   s.week_key            = -1;
   s.day_start_equity    = 0.0;
   s.week_start_equity   = 0.0;
   s.peak_equity         = 0.0;
   s.init_equity         = 0.0;
   s.trades_today        = 0;
   s.consec_losses       = 0;
   s.consec_losing_days  = 0;
   s.cooldown_until      = 0;
   s.post_sl_until       = 0;
   s.slip_until          = 0;
   s.trades_session      = 0;
   s.session_name        = "";
   s.lock_floor          = 0.0;
   s.friday_close_done   = 0;
   s.pos_present         = 0;
   s.pos_ticket          = 0;
   s.pos_state           = 0;
   s.pos_direction       = 0;
   s.pos_volume_initial  = 0.0;
   s.pos_volume_current  = 0.0;
   s.pos_entry_price     = 0.0;
   s.pos_sl_price        = 0.0;
   s.pos_tp_price        = 0.0;
   s.pos_risk_pct_at_entry = 0.0;
   s.pos_score_at_entry  = 0.0;
   s.pos_setup           = 0;
   s.pos_session         = "";
   s.pos_regime          = "";
   s.pos_open_reason     = "";
   s.pos_open_time       = 0;
   s.pos_open_bar_time   = 0;
   s.pos_bars_in_trade   = 0;
   s.pos_be_done         = 0;
   s.pos_partial_done    = 0;
  }

//--- JSON string escape (backslash first, then specials) ------------
string XareJsonEscape(const string s)
  {
   string r = s;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, "\"", "\\\"");
   StringReplace(r, "\n", "\\n");
   StringReplace(r, "\r", "\\r");
   StringReplace(r, "\t", "\\t");
   return r;
  }

//--- JSON string unescape: character scan (replace-chain order bugs
//--- are exactly how corrupt restores happen — never chain here)
string XareJsonUnescape(const string s)
  {
   string out = "";
   int    n   = StringLen(s);
   for(int i = 0; i < n; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c == '\\' && i + 1 < n)
        {
         ushort d = StringGetCharacter(s, i + 1);
         i++;
         if(d == 'n')       out += "\n";
         else if(d == 'r')  out += "\r";
         else if(d == 't')  out += "\t";
         else if(d == '"')  out += "\"";
         else if(d == '\\') out += "\\";
         else               out += ShortToString(d); // unknown: keep literal
        }
      else
         out += ShortToString(c);
     }
   return out;
  }

//--- append one "key": value line (value quoted when is_string)
void XareStateLine(string &text, const string key, const string value,
                   const bool is_string)
  {
   if(is_string)
      text += "\"" + key + "\": \"" + XareJsonEscape(value) + "\",\n";
   else
      text += "\"" + key + "\": " + value + ",\n";
  }

//--- PURE: encode the state snapshot to the file text
string XareStateEncode(const SXarePersistedState &s)
  {
   string t = "{\n";
   XareStateLine(t, "version", IntegerToString(s.version), false);
   XareStateLine(t, "day_key", IntegerToString(s.day_key), false);
   XareStateLine(t, "week_key", IntegerToString(s.week_key), false);
   XareStateLine(t, "day_start_equity", DoubleToString(s.day_start_equity, 2), false);
   XareStateLine(t, "week_start_equity", DoubleToString(s.week_start_equity, 2), false);
   XareStateLine(t, "peak_equity", DoubleToString(s.peak_equity, 2), false);
   XareStateLine(t, "init_equity", DoubleToString(s.init_equity, 2), false);
   XareStateLine(t, "trades_today", IntegerToString(s.trades_today), false);
   XareStateLine(t, "consec_losses", IntegerToString(s.consec_losses), false);
   XareStateLine(t, "consec_losing_days", IntegerToString(s.consec_losing_days), false);
   XareStateLine(t, "cooldown_until", IntegerToString((long)s.cooldown_until), false);
   XareStateLine(t, "post_sl_until", IntegerToString((long)s.post_sl_until), false);
   XareStateLine(t, "slip_until", IntegerToString((long)s.slip_until), false);
   XareStateLine(t, "trades_session", IntegerToString(s.trades_session), false);
   XareStateLine(t, "session_name", s.session_name, true);
   XareStateLine(t, "lock_floor", DoubleToString(s.lock_floor, 2), false);
   XareStateLine(t, "friday_close_done", IntegerToString(s.friday_close_done), false);
   XareStateLine(t, "pos_present", IntegerToString(s.pos_present), false);
   XareStateLine(t, "pos_ticket", IntegerToString(s.pos_ticket), false);
   XareStateLine(t, "pos_state", IntegerToString(s.pos_state), false);
   XareStateLine(t, "pos_direction", IntegerToString(s.pos_direction), false);
   XareStateLine(t, "pos_volume_initial", DoubleToString(s.pos_volume_initial, 2), false);
   XareStateLine(t, "pos_volume_current", DoubleToString(s.pos_volume_current, 2), false);
   XareStateLine(t, "pos_entry_price", DoubleToString(s.pos_entry_price, 5), false);
   XareStateLine(t, "pos_sl_price", DoubleToString(s.pos_sl_price, 5), false);
   XareStateLine(t, "pos_tp_price", DoubleToString(s.pos_tp_price, 5), false);
   XareStateLine(t, "pos_risk_pct_at_entry", DoubleToString(s.pos_risk_pct_at_entry, 4), false);
   XareStateLine(t, "pos_score_at_entry", DoubleToString(s.pos_score_at_entry, 1), false);
   XareStateLine(t, "pos_setup", IntegerToString(s.pos_setup), false);
   XareStateLine(t, "pos_session", s.pos_session, true);
   XareStateLine(t, "pos_regime", s.pos_regime, true);
   XareStateLine(t, "pos_open_reason", s.pos_open_reason, true);
   XareStateLine(t, "pos_open_time", IntegerToString((long)s.pos_open_time), false);
   XareStateLine(t, "pos_open_bar_time", IntegerToString((long)s.pos_open_bar_time), false);
   XareStateLine(t, "pos_bars_in_trade", IntegerToString(s.pos_bars_in_trade), false);
   XareStateLine(t, "pos_be_done", IntegerToString(s.pos_be_done), false);
   XareStateLine(t, "pos_partial_done", IntegerToString(s.pos_partial_done), false);
   t += "\"eof\": 1\n}\n";
   return t;
  }

//--- one-line parser: returns key + value (value still raw)
bool XareStateSplitLine(const string line, string &key_out, string &val_out)
  {
   key_out = ""; val_out = "";
   int colon = StringFind(line, ":");
   if(colon <= 0)
      return false;
   string k = StringSubstr(line, 0, colon);
   StringTrimLeft(k); StringTrimRight(k);
   if(StringLen(k) >= 2 && StringGetCharacter(k, 0) == '"')
      k = StringSubstr(k, 1, StringLen(k) - 2);
   string v = StringSubstr(line, colon + 1);
   StringTrimLeft(v); StringTrimRight(v);
   if(StringLen(v) > 0 && StringGetCharacter(v, StringLen(v) - 1) == ',')
      v = StringSubstr(v, 0, StringLen(v) - 1);
   StringTrimLeft(v); StringTrimRight(v);
   key_out = k; val_out = v;
   return (StringLen(k) > 0);
  }

//--- PURE: parse file text into the snapshot. False on corruption
//--- (missing version/eof never yields a half-trusted state).
bool XareStateParse(const string text, SXarePersistedState &s)
  {
   XareResetPersistedState(s);
   bool have_version = false, have_eof = false;
   int  pos = 0, len = StringLen(text);
   while(pos < len)
     {
      int eol = StringFind(text, "\n", pos);
      string line = (eol < 0) ? StringSubstr(text, pos)
                              : StringSubstr(text, pos, eol - pos);
      pos = (eol < 0) ? len : eol + 1;
      StringTrimLeft(line); StringTrimRight(line);
      if(line == "{" || line == "}" || StringLen(line) == 0)
         continue;
      if(StringFind(line, "\"eof\"") == 0) { have_eof = true; continue; }
      string k, v;
      if(!XareStateSplitLine(line, k, v))
         continue;
      bool is_string = (StringLen(v) >= 2 &&
                        StringGetCharacter(v, 0) == '"');
      string raw = is_string ? StringSubstr(v, 1, StringLen(v) - 2) : v;
      if(k == "version")            { s.version = (int)StringToInteger(v); have_version = true; }
      else if(k == "day_key")       { s.day_key = StringToInteger(v); }
      else if(k == "week_key")      { s.week_key = StringToInteger(v); }
      else if(k == "day_start_equity")  { s.day_start_equity = StringToDouble(v); }
      else if(k == "week_start_equity") { s.week_start_equity = StringToDouble(v); }
      else if(k == "peak_equity")       { s.peak_equity = StringToDouble(v); }
      else if(k == "init_equity")       { s.init_equity = StringToDouble(v); }
      else if(k == "trades_today")      { s.trades_today = (int)StringToInteger(v); }
      else if(k == "consec_losses")     { s.consec_losses = (int)StringToInteger(v); }
      else if(k == "consec_losing_days"){ s.consec_losing_days = (int)StringToInteger(v); }
      else if(k == "cooldown_until")    { s.cooldown_until = (datetime)StringToInteger(v); }
      else if(k == "post_sl_until")     { s.post_sl_until = (datetime)StringToInteger(v); }
      else if(k == "slip_until")        { s.slip_until = (datetime)StringToInteger(v); }
      else if(k == "trades_session")    { s.trades_session = (int)StringToInteger(v); }
      else if(k == "session_name")      { s.session_name = is_string ? XareJsonUnescape(raw) : ""; }
      else if(k == "lock_floor")        { s.lock_floor = StringToDouble(v); }
      else if(k == "friday_close_done") { s.friday_close_done = (int)StringToInteger(v); }
      else if(k == "pos_present")       { s.pos_present = (int)StringToInteger(v); }
      else if(k == "pos_ticket")        { s.pos_ticket = StringToInteger(v); }   // tickets fit in long
      else if(k == "pos_state")         { s.pos_state = (int)StringToInteger(v); }
      else if(k == "pos_direction")     { s.pos_direction = (int)StringToInteger(v); }
      else if(k == "pos_volume_initial"){ s.pos_volume_initial = StringToDouble(v); }
      else if(k == "pos_volume_current"){ s.pos_volume_current = StringToDouble(v); }
      else if(k == "pos_entry_price")   { s.pos_entry_price = StringToDouble(v); }
      else if(k == "pos_sl_price")      { s.pos_sl_price = StringToDouble(v); }
      else if(k == "pos_tp_price")      { s.pos_tp_price = StringToDouble(v); }
      else if(k == "pos_risk_pct_at_entry") { s.pos_risk_pct_at_entry = StringToDouble(v); }
      else if(k == "pos_score_at_entry"){ s.pos_score_at_entry = StringToDouble(v); }
      else if(k == "pos_setup")         { s.pos_setup = (int)StringToInteger(v); }
      else if(k == "pos_session")       { s.pos_session = is_string ? XareJsonUnescape(raw) : ""; }
      else if(k == "pos_regime")        { s.pos_regime = is_string ? XareJsonUnescape(raw) : ""; }
      else if(k == "pos_open_reason")   { s.pos_open_reason = is_string ? XareJsonUnescape(raw) : ""; }
      else if(k == "pos_open_time")     { s.pos_open_time = (datetime)StringToInteger(v); }
      else if(k == "pos_open_bar_time") { s.pos_open_bar_time = (datetime)StringToInteger(v); }
      else if(k == "pos_bars_in_trade") { s.pos_bars_in_trade = (int)StringToInteger(v); }
      else if(k == "pos_be_done")       { s.pos_be_done = (int)StringToInteger(v); }
      else if(k == "pos_partial_done")  { s.pos_partial_done = (int)StringToInteger(v); }
     }
   return (have_version && have_eof);
  }

//+------------------------------------------------------------------+
//| Stateful store: atomic save + load-with-backup.                  |
//+------------------------------------------------------------------+
class CXareStateStore
  {
private:
   bool             m_enabled;      // false in tester / when init fails
   string           m_path;         // relative to MQL5\Files
   string           m_tmp_path;
   string           m_bak_path;
   bool             m_loaded;       // a state file was successfully read
   bool             m_dirty;        // something changed since last save

public:
                     CXareStateStore(void) : m_enabled(false), m_path(""),
                                             m_tmp_path(""), m_bak_path(""),
                                             m_loaded(false), m_dirty(false) {}

   void              Init(const string dir, const bool enabled)
     {
      m_enabled = enabled;
      m_path    = dir + "\\state.json";
      m_tmp_path= dir + "\\state.tmp";
      m_bak_path= dir + "\\state.bak";
      m_loaded  = false;
      m_dirty   = false;
     }

   bool              Enabled(void) const { return m_enabled; }
   bool              Loaded(void)  const { return m_loaded; }
   void              MarkDirty(void)     { m_dirty = true; }
   bool              Dirty(void)   const { return m_dirty; }

   //--- atomic save: tmp file -> close -> move over the real file.
   //--- Previous good content stays in .bak for the load fallback.
   bool              Save(const SXarePersistedState &s, string &err_out)
     {
      err_out = "";
      m_dirty = false;
      if(!m_enabled)
         return true;               // tester: persistence deliberately off
      string text = XareStateEncode(s);
      //--- keep the current good file as .bak before overwriting
      if(FileIsExist(m_path))
        {
         if(!FileMove(m_path, 0, m_bak_path, FILE_REWRITE))
            err_out = "bak copy failed err=" + IntegerToString(GetLastError());
        }
      int h = FileOpen(m_tmp_path, FILE_WRITE|FILE_TXT|FILE_ANSI);
      if(h == INVALID_HANDLE)
        {
         err_out += " tmp open failed err=" + IntegerToString(GetLastError());
         return false;
        }
      FileWriteString(h, text);
      FileClose(h);
      if(!FileMove(m_tmp_path, 0, m_path, FILE_REWRITE))
        {
         err_out += " move failed err=" + IntegerToString(GetLastError());
         return false;
        }
      return true;
     }

   //--- load: main file first, .bak fallback on corruption
   bool              Load(SXarePersistedState &s, string &err_out)
     {
      err_out = "";
      if(!m_enabled)
         return false;
      if(TryRead(m_path, s, err_out))
        {
         m_loaded = true;
         return true;
        }
      string main_err = err_out;
      err_out = "";
      if(TryRead(m_bak_path, s, err_out))
        {
         m_loaded = true;
         err_out = "restored from .bak (main failed: " + main_err + ")";
         return true;
        }
      return false;
     }

private:
   bool              TryRead(const string path, SXarePersistedState &s,
                             string &err_out)
     {
      err_out = "";
      if(!FileIsExist(path))
        {
         err_out = "no file: " + path;
         return false;
        }
      int h = FileOpen(path, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(h == INVALID_HANDLE)
        {
         err_out = "open failed err=" + IntegerToString(GetLastError());
         return false;
        }
      string text = "";
      while(!FileIsEnding(h))
         text += FileReadString(h) + "\n";
      FileClose(h);
      if(!XareStateParse(text, s))
        {
         err_out = "parse failed (corrupt?)";
         return false;
        }
      return true;
     }
  };
#endif // __XARE_STATESTORE_MQH__
