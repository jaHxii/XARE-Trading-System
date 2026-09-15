//+------------------------------------------------------------------+
//| Logger.mqh — structured logging + trade journal CSV (spec §34,69)|
//| v0.1.0 — M1: leveled Print logging, journal CSV scaffolding.     |
//| Research feature CSV rows arrive with the M13 research logger.   |
//+------------------------------------------------------------------+
#ifndef __XARE_LOGGER_MQH__
#define __XARE_LOGGER_MQH__

#include "Types.mqh"

//--- log levels; production default INFO to keep journals readable
#define XARE_LOG_DEBUG  0
#define XARE_LOG_INFO   1
#define XARE_LOG_WARN   2
#define XARE_LOG_ERROR  3

class CXareLogger
  {
private:
   int              m_level;
   string           m_symbol;
   long             m_magic;
   bool             m_journal_enabled;
   string           m_journal_path;
   int              m_journal_handle;
   bool             m_journal_failed;   // latch: do not retry a broken file forever

public:
                     CXareLogger(void) : m_level(XARE_LOG_INFO),
                                         m_symbol(""), m_magic(0),
                                         m_journal_enabled(false),
                                         m_journal_handle(INVALID_HANDLE),
                                         m_journal_failed(false) {}

   bool              Init(const string symbol, const long magic,
                          const int level, const bool journal_enabled,
                          const string journal_dir)
     {
      m_symbol          = symbol;
      m_magic           = magic;
      m_level           = level;
      m_journal_enabled = journal_enabled;

      if(!m_journal_enabled)
         return true;

      // Ensure the folder exists; FileOpen creates paths under MQL5\Files only.
      // FolderCreate returns false both for "exists" and real errors, so we
      // verify by opening the journal afterwards rather than trusting the code.
      FolderCreate(journal_dir, FILE_COMMON);
      ResetLastError();
      m_journal_path = journal_dir + "\\trade_journal.csv";
      ResetLastError();
      m_journal_handle = FileOpen(m_journal_path,
                                  FILE_READ|FILE_WRITE|FILE_CSV|FILE_SHARE_READ|FILE_COMMON,
                                  ',');
      if(m_journal_handle == INVALID_HANDLE)
        {
         m_journal_failed = true;
         PrintFormat("XARE[J][ERROR] cannot open journal '%s' err=%d",
                     m_journal_path, GetLastError());
         return false;
        }
      FileSeek(m_journal_handle, 0, SEEK_END);
      if(FileTell(m_journal_handle) == 0)
         WriteHeader();
      return true;
     }

   void              Deinit(void)
     {
      if(m_journal_handle != INVALID_HANDLE)
        {
         FileClose(m_journal_handle);
         m_journal_handle = INVALID_HANDLE;
        }
     }

   //--- leveled log: [XARE][LEVEL] tag | message
   void              Log(const int level, const string tag, const string msg)
     {
      if(level < m_level)
         return;
      string lvl = (level==XARE_LOG_DEBUG) ? "D" :
                   (level==XARE_LOG_WARN)  ? "W" :
                   (level==XARE_LOG_ERROR) ? "E" : "I";
      PrintFormat("XARE[%s] %s | %s", lvl, tag, msg);
     }

   void              Debug(const string tag, const string msg) { Log(XARE_LOG_DEBUG, tag, msg); }
   void              Info(const string tag, const string msg)  { Log(XARE_LOG_INFO,  tag, msg); }
   void              Warn(const string tag, const string msg)  { Log(XARE_LOG_WARN,  tag, msg); }
   void              Error(const string tag, const string msg) { Log(XARE_LOG_ERROR, tag, msg); }

   //--- one CSV row per closed trade (columns fixed for research parsing)
   void              WriteHeader(void)
     {
      if(!JournalReady())
         return;
      FileWrite(m_journal_handle,
                "close_time","ticket","symbol","direction","setup","regime","score",
                "risk_pct","volume","entry","sl","tp","exit_price","exit_reason",
                "session","pl_money","r_multiple","bars_in_trade","slippage_points",
                "open_reason");
     }

   bool              JournalReady(void) const
     {
      return (m_journal_enabled && !m_journal_failed &&
              m_journal_handle != INVALID_HANDLE);
     }

   //--- trade journal row (§69). Called by PerformanceTracker on close (M11+).
   void              JournalRow(const datetime close_time, const ulong ticket,
                                const int direction, const string setup,
                                const string regime, const double score,
                                const double risk_pct, const double volume,
                                const double entry, const double sl, const double tp,
                                const double exit_price, const string exit_reason,
                                const string session, const double pl_money,
                                const double r_multiple, const int bars_in_trade,
                                const double slippage_points, const string open_reason)
     {
      if(!JournalReady())
         return;
      FileWrite(m_journal_handle,
                TimeToString(close_time, TIME_DATE|TIME_SECONDS),
                IntegerToString((long)ticket), m_symbol,
                (direction>0 ? "BUY" : (direction<0 ? "SELL" : "FLAT")),
                setup, regime, DoubleToString(score,1),
                DoubleToString(risk_pct,3), DoubleToString(volume,2),
                DoubleToString(entry,5), DoubleToString(sl,5), DoubleToString(tp,5),
                DoubleToString(exit_price,5), exit_reason, session,
                DoubleToString(pl_money,2), DoubleToString(r_multiple,3),
                IntegerToString(bars_in_trade), DoubleToString(slippage_points,1),
                open_reason);
      FileFlush(m_journal_handle);
     }

   string            JournalPath(void) const { return m_journal_path; }
  };

#endif // __XARE_LOGGER_MQH__
