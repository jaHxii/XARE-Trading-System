//+------------------------------------------------------------------+
//| NewsFilter.mqh — optional news blackout, fail-safe (spec §14)     |
//| v0.12.0 — M12.                                                   |
//|                                                                  |
//| No external news API is assumed. The ONLY data source is an      |
//| optional operator-provided CSV in MQL5\Common (FILE_COMMON):     |
//|                                                                  |
//|   MQL5\Common\XARE\news_calendar.csv                             |
//|   time,event,impact                                              |
//|   2026.09.15 15:30,FOMC,HIGH                                     |
//|                                                                  |
//| Rules (§14): blackouts apply ONLY when event data actually       |
//| exists. If the file is missing or unreadable the filter is       |
//| DISABLED and says so — it never fabricates events, never guesses.|
//+------------------------------------------------------------------+
#ifndef __XARE_NEWSFILTER_MQH__
#define __XARE_NEWSFILTER_MQH__

#include "Types.mqh"

//--- pure blackout-window check (unit-testable): inclusive both ends
bool XareInBlackout(const datetime now, const datetime event_time,
                    const int before_min, const int after_min)
  {
   if(event_time <= 0 || before_min <= 0 || after_min <= 0)
      return false;
   return (now >= event_time - before_min * 60 &&
           now <= event_time + after_min * 60);
  }

class CXareNewsFilter
  {
private:
   bool             m_enabled;        // file present and parsed
   bool             m_warned;         // one-time disabled notice
   datetime         m_loaded_at;      // hourly reload anchor
   datetime         m_times[128];     // event times (server time)
   string           m_names[128];
   int              m_count;
   int              m_before_min;     // blackout window before event
   int              m_after_min;      // blackout window after event

   void             Load(void)
     {
      m_loaded_at = TimeCurrent();
      string file = "XARE\\news_calendar.csv";
      int h = FileOpen(file, FILE_READ|FILE_CSV|FILE_SHARE_READ|FILE_COMMON, ',');
      if(h == INVALID_HANDLE)
        {
         m_enabled = false;
         if(!m_warned)
           {
            PrintFormat("XARE[NEWS][INFO] no calendar at MQL5\\Common\\%s — news filter DISABLED (fail-safe: clear)",
                        file);
            m_warned = true;
           }
         return;
        }
      m_count = 0;
      while(!FileIsEnding(h) && m_count < 128)
        {
         string t = FileReadString(h);   // time or header
         string e = FileReadString(h);   // event
         string i = FileReadString(h);   // impact
         if(t == "time" || StringLen(t) < 5)
            continue;
         datetime et = StringToTime(t);
         if(et <= 0)
            continue;
         //--- only HIGH impact events trigger blackout
         if(i != "HIGH")
            continue;
         m_times[m_count] = et;
         m_names[m_count] = e;
         m_count++;
        }
      FileClose(h);
      m_enabled = (m_count > 0);
      if(!m_enabled && !m_warned)
        {
         PrintFormat("XARE[NEWS][INFO] calendar present but no HIGH-impact rows — filter effectively disabled");
         m_warned = true;
        }
     }

public:
                     CXareNewsFilter(void) : m_enabled(false), m_warned(false),
                                             m_loaded_at(0), m_count(0),
                                             m_before_min(30), m_after_min(30) {}

   void              Init(const int blackout_before_min, const int blackout_after_min)
     {
      m_before_min = MathMax(1, blackout_before_min);
      m_after_min  = MathMax(1, blackout_after_min);
      Load();
     }

   bool              Enabled(void) const { return m_enabled; }

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
