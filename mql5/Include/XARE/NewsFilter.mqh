//+------------------------------------------------------------------+
//| NewsFilter.mqh — optional news blackout, fail-safe (spec §14)     |
//| v0.17.0 — hardening: native MT5 Economic Calendar source with    |
//| CSV fallback; failure detection + one-time warnings; entries-    |
//| only blocking (never auto-closes positions).                     |
//|                                                                  |
//| Sources (§14 hardening), tried in order:                         |
//|   1. MT5 Economic Calendar (CALENDAR_IF_AVAILABLE):              |
//|      CalendarValueHistory() filtered to HIGH-importance USD/XAU  |
//|      events inside a sliding window. Not supported in the        |
//|      Strategy Tester — detected and skipped, never guessed.      |
//|   2. Operator CSV in MQL5\Common\XARE\news_calendar.csv:         |
//|        time,event,impact                                         |
//|        2026.09.15 15:30,FOMC,HIGH                                |
//|   3. Neither available -> filter DISABLED, fail-safe CLEAR.      |
//|                                                                  |
//| Rules (§14): blackouts apply ONLY when event data actually       |
//| exists. The filter never fabricates events, never guesses.       |
//| Failure of the calendar engine is DETECTED (API error), logged   |
//| once, and degrades cleanly to the next source. Blocking applies  |
//| to NEW ENTRIES only; positions are never auto-closed here.       |
//+------------------------------------------------------------------+
#ifndef __XARE_NEWSFILTER_MQH__
#define __XARE_NEWSFILTER_MQH__

#include "Types.mqh"
#include "Config.mqh"

//--- pure blackout-window check (unit-testable): inclusive both ends
bool XareInBlackout(const datetime now, const datetime event_time,
                    const int before_min, const int after_min)
  {
   if(event_time <= 0 || before_min <= 0 || after_min <= 0)
      return false;
   return (now >= event_time - before_min * 60 &&
           now <= event_time + after_min * 60);
  }

//--- pure importance filter (unit-testable with a filled MqlCalendarEvent):
//--- only HIGH-importance events trigger blackout (config hypothesis).
bool XareEventBlocks(const ENUM_CALENDAR_EVENT_IMPORTANCE importance)
  {
   return (importance == CALENDAR_IMPORTANCE_HIGH);
  }

class CXareNewsFilter
  {
private:
   ENUM_XARE_NEWS_SOURCE m_source;   // configured source
   bool             m_calendar_ok;   // calendar engine usable (runtime probe)
   bool             m_using_calendar;// events actually loaded from calendar
   bool             m_enabled;       // ANY source loaded events
   bool             m_warned;        // one-time disabled notice
   bool             m_cal_fail_warned;
   datetime         m_loaded_at;     // hourly reload anchor
   datetime         m_times[256];    // event times (server time)
   string           m_names[256];
   int              m_count;
   int              m_before_min;    // blackout window before event
   int              m_after_min;     // blackout window after event

   //--- calendar engine: sliding window [now-1d, now+7d], USD + XAU.
   //--- Returns true when the ENGINE answered (even with 0 events);
   //--- false only on API failure (=> fall back / fail-safe).
   bool             LoadCalendar(void)
     {
      //--- calendar functions are not available in the Strategy Tester
      if(MQLInfoInteger(MQL_TESTER) != 0)
        {
         if(!m_cal_fail_warned)
           {
            PrintFormat("XARE[NEWS][INFO] economic calendar unavailable in tester — falling back to CSV/fail-safe");
            m_cal_fail_warned = true;
           }
         return false;
        }
      datetime from = TimeCurrent() - 86400;    // catch just-passed events
      datetime to   = TimeCurrent() + 7 * 86400;
      m_count = 0;
      //--- USD drives gold; XAU itself rarely appears but is queried for
      //--- completeness (an empty answer is a valid, non-failing answer)
      const int    ccy_n   = 2;
      const string ccys[2] = {"USD", "XAU"};
      for(int ci = 0; ci < ccy_n; ci++)
        {
         MqlCalendarValue vals[];
         ResetLastError();
         if(!CalendarValueHistory(vals, from, to, NULL, ccys[ci]))
           {
            if(!m_cal_fail_warned)
              {
               PrintFormat("XARE[NEWS][WARN] CalendarValueHistory failed (ccy=%s err=%d) — calendar source unavailable",
                           ccys[ci], GetLastError());
               m_cal_fail_warned = true;
              }
            return false;                     // engine failure -> fallback
           }
         for(int i = 0; i < ArraySize(vals) && m_count < 256; i++)
           {
            MqlCalendarEvent ev;
            if(!CalendarEventById(vals[i].event_id, ev))
               continue;                      // unreadable event: skip, not fail
            if(!XareEventBlocks(ev.importance))
               continue;
            m_times[m_count] = vals[i].time;
            m_names[m_count] = ev.name;
            m_count++;
           }
        }
      m_using_calendar = true;
      return true;
     }

   void             LoadCSV(void)
     {
      string file = "XARE\\news_calendar.csv";
      int h = FileOpen(file, FILE_READ|FILE_CSV|FILE_SHARE_READ|FILE_COMMON, ',');
      if(h == INVALID_HANDLE)
         return;                              // caller logs the final verdict
      while(!FileIsEnding(h) && m_count < 256)
        {
         string t = FileReadString(h);   // time or header
         string e = FileReadString(h);   // event
         string i = FileReadString(h);   // impact
         if(t == "time" || StringLen(t) < 5)
            continue;
         datetime et = StringToTime(t);
         if(et <= 0)
            continue;
         if(i != "HIGH")                      // CSV convention: HIGH only
            continue;
         m_times[m_count] = et;
         m_names[m_count] = e;
         m_count++;
        }
      FileClose(h);
     }

   void             Load(void)
     {
      m_loaded_at      = TimeCurrent();
      m_count          = 0;
      m_using_calendar = false;
      if(m_source == XARE_NEWS_CALENDAR_IF_AVAILABLE && LoadCalendar())
        {
         // engine answered; 0 events = available and clear (valid state)
        }
      else if(m_source == XARE_NEWS_CALENDAR_IF_AVAILABLE)
        {
         LoadCSV();                           // engine failed -> CSV fallback
        }
      else
        {
         LoadCSV();                           // CSV-only configuration
        }
      m_enabled = (m_count > 0);
      if(!m_enabled && !m_warned)
        {
         PrintFormat("XARE[NEWS][INFO] no event data from %s — news filter DISABLED (fail-safe: clear)",
                     m_source == XARE_NEWS_CALENDAR_IF_AVAILABLE
                        ? "calendar or CSV" : "CSV");
         m_warned = true;
        }
     }

public:
                     CXareNewsFilter(void) : m_source(XARE_NEWS_CSV_ONLY),
                                             m_calendar_ok(false),
                                             m_using_calendar(false),
                                             m_enabled(false), m_warned(false),
                                             m_cal_fail_warned(false),
                                             m_loaded_at(0), m_count(0),
                                             m_before_min(30), m_after_min(30) {}

   void              Init(const ENUM_XARE_NEWS_SOURCE source,
                          const int blackout_before_min,
                          const int blackout_after_min)
     {
      m_source     = source;
      m_before_min = MathMax(1, blackout_before_min);
      m_after_min  = MathMax(1, blackout_after_min);
      Load();
     }

   bool              Enabled(void) const { return m_enabled; }
   bool              UsingCalendar(void) const { return m_using_calendar; }

   //--- source label for init log + health check: CALENDAR | CSV | NONE
   string            SourceLabel(void) const
     {
      if(m_enabled && m_using_calendar) return "CALENDAR";
      if(m_enabled)                     return "CSV";
      return "NONE";
     }

   //--- clearance: true = no blackout (or filter disabled = fail-safe clear).
   //--- out_reason carries the blocking event when false.
   bool              Clear(const datetime now, string &out_reason)
     {
      out_reason = "";
      if(!m_enabled)
         return true;                 // §14: fail-safe — no data, no blackout
      if(TimeCurrent() - m_loaded_at >= 3600)
         Load();                      // hourly refresh
      for(int i = 0; i < m_count; i++)
        {
         if(XareInBlackout(now, m_times[i], m_before_min, m_after_min))
           {
            out_reason = StringFormat("news blackout: %s (%s)",
                                      m_names[i],
                                      TimeToString(m_times[i], TIME_DATE|TIME_MINUTES));
            return false;
           }
        }
      return true;
     }
  };
#endif // __XARE_NEWSFILTER_MQH__
