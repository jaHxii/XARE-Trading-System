//+------------------------------------------------------------------+
//| HealthCheck.mqh — startup self-diagnostic (hardening §21)        |
//| v0.17.0                                                          |
//|                                                                  |
//| Produces ONE verdict the operator can trust at a glance:         |
//|    XARE HEALTH: READY   |   XARE HEALTH: BLOCKED (reasons...)    |
//|                                                                  |
//| Component checks are EXECUTED BY THE EA (they need the terminal);|
//| this module owns the check record + pure aggregation so the      |
//| READY/BLOCKED rule is unit-testable (SELF_TEST T19).             |
//| BLOCKED blocks sends (via SafetyEngine), never signal evaluation |
//| — a blocked EA still reports signals and reasons.                |
//+------------------------------------------------------------------+
#ifndef __XARE_HEALTHCHECK_MQH__
#define __XARE_HEALTHCHECK_MQH__

#include "Types.mqh"

//--- the 12 §21 check domains
enum ENUM_XARE_HEALTH_DOMAIN
  {
   XARE_HC_DATA = 0,
   XARE_HC_INDICATORS,
   XARE_HC_SYMBOL,
   XARE_HC_BROKER,
   XARE_HC_MARGIN,
   XARE_HC_PERMISSION,
   XARE_HC_NEWS,
   XARE_HC_TIME,
   XARE_HC_RISK,
   XARE_HC_EXECUTION,
   XARE_HC_STATE,
   XARE_HC_LOGGING
  };

//--- one check result: pass + exact reason when failed
struct SXareHealthCheck
  {
   bool             ok;
   string           reason;      // "" when ok
  };

string XareHealthDomainToString(const ENUM_XARE_HEALTH_DOMAIN d)
  {
   switch(d)
     {
      case XARE_HC_DATA:      return "DATA";
      case XARE_HC_INDICATORS:return "INDICATORS";
      case XARE_HC_SYMBOL:    return "SYMBOL";
      case XARE_HC_BROKER:    return "BROKER";
      case XARE_HC_MARGIN:    return "MARGIN";
      case XARE_HC_PERMISSION:return "PERMISSION";
      case XARE_HC_NEWS:      return "NEWS";
      case XARE_HC_TIME:      return "TIME";
      case XARE_HC_RISK:      return "RISK";
      case XARE_HC_EXECUTION: return "EXECUTION";
      case XARE_HC_STATE:     return "STATE";
      case XARE_HC_LOGGING:   return "LOGGING";
      default:                return "?";
     }
  }

//--- PURE aggregation (T19): any failed check => BLOCKED; every failure
//--- reason appears in the verdict line. Unknown (no checks) => UNKNOWN.
ENUM_XARE_HEALTH XareHealthAggregate(const SXareHealthCheck &checks[],
                                     int checks_total,
                                     string &reasons_out)
  {
   reasons_out = "";
   if(checks_total <= 0)
      return XARE_HEALTH_UNKNOWN;
   string fails = "";
   for(int i = 0; i < checks_total; i++)
     {
      if(!checks[i].ok)
         fails += (StringLen(fails) > 0 ? "; " : "") + checks[i].reason;
     }
   reasons_out = fails;
   return (StringLen(fails) > 0) ? XARE_HEALTH_BLOCKED : XARE_HEALTH_READY;
  }

//+------------------------------------------------------------------+
//| Record-keeper: the EA runs each check, records pass/fail+reason. |
//+------------------------------------------------------------------+
class CXareHealthCheck
  {
private:
   SXareHealthCheck m_checks[12];
   ENUM_XARE_HEALTH m_verdict;
   string           m_reasons;

public:
                     CXareHealthCheck(void) : m_verdict(XARE_HEALTH_UNKNOWN),
                                              m_reasons("")
     {
      for(int i = 0; i < 12; i++)
        {
         m_checks[i].ok = false;
         m_checks[i].reason = "not run";
        }
     }

   //--- record one domain result (false + reason = failure)
   void              Record(const ENUM_XARE_HEALTH_DOMAIN d, const bool ok,
                            const string reason)
     {
      int idx = (int)d;
      if(idx < 0 || idx >= 12)
         return;
      m_checks[idx].ok     = ok;
      m_checks[idx].reason = ok ? "" : XareHealthDomainToString(d) + ": " + reason;
     }

   bool              DomainOk(const ENUM_XARE_HEALTH_DOMAIN d) const
     {
      int idx = (int)d;
      if(idx < 0 || idx >= 12)
         return false;
      return m_checks[idx].ok;
     }

   //--- aggregate + log the final verdict line (§21)
   ENUM_XARE_HEALTH  Finalize(const bool log_enabled)
     {
      m_verdict = XareHealthAggregate(m_checks, 12, m_reasons);
      if(log_enabled)
        {
         if(m_verdict == XARE_HEALTH_READY)
            PrintFormat("XARE HEALTH: READY");
         else if(m_verdict == XARE_HEALTH_BLOCKED)
            PrintFormat("XARE HEALTH: BLOCKED (%s)", m_reasons);
         else
            PrintFormat("XARE HEALTH: UNKNOWN (no checks recorded)");
        }
      return m_verdict;
     }

   ENUM_XARE_HEALTH  Verdict(void) const { return m_verdict; }
   string            Reasons(void) const { return m_reasons; }
  };
#endif // __XARE_HEALTHCHECK_MQH__
