//+------------------------------------------------------------------+
//| Config.mqh — all XARE parameters in one place (spec §62)          |
//| v0.1.0 — M1: general/data/logging groups; risk/session/etc join   |
//|          in later milestones alongside their engines.             |
//| NOTE: MQL5 has no `input struct`; inputs are declared in XARE.mq5 |
//| and copied into this struct once at init (single source of truth).|
//+------------------------------------------------------------------+
#ifndef __XARE_CONFIG_MQH__
#define __XARE_CONFIG_MQH__

#include "Types.mqh"

//--- resolved, immutable-after-init configuration
struct SXareConfig
  {
   // General (spec §62: General)
   ENUM_XARE_MODE   mode;
   bool             trading_enabled;      // global risk switch (§18)
   long             magic;
   string           order_comment;
   bool             dashboard_enabled;

   // Market Data (§5, §28)
   bool             use_closed_bars_only;
   int              max_spread_points;        // block entries above
   int              abnormal_spread_points;   // abnormal condition gate
   int              max_bars_without_data;    // staleness tolerance

   // Logging / Research (§34, §37)
   int              log_level;            // 0=DEBUG 1=INFO 2=WARN 3=ERROR
   bool             research_csv_enabled; // RESEARCH mode feature rows
   bool             journal_csv_enabled;  // trade journal (§69)
   string           journal_dir;          // under MQL5\Files
  };

//--- defaults: safety-first (spec §63). Values are hypotheses (docs/parameters.md)
void XareConfigDefaults(SXareConfig &c)
  {
   c.mode                   = XARE_MODE_SIGNAL_ONLY;   // never default to trading
   c.trading_enabled        = false;
   c.magic                  = 860001;
   c.order_comment          = "XARE";
   c.dashboard_enabled      = true;

   c.use_closed_bars_only   = true;
   c.max_spread_points      = 350;    // XAUUSDm typical ≈100–200pt — MEASURE, don't trust
   c.abnormal_spread_points = 600;
   c.max_bars_without_data  = 3;

   c.log_level              = 1;      // INFO
   c.research_csv_enabled   = false;  // enabled by RESEARCH mode itself
   c.journal_csv_enabled    = true;
   c.journal_dir            = "XARE";
  }

#endif // __XARE_CONFIG_MQH__
