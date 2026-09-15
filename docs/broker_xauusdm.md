# Broker reference: Exness XAUUSDm (recorded, not assumed)

Source: MetaTrader 5 **Specification dialog** for `XAUUSDm`, captured by
jaHxii on **2026-09-15**. This page is the project's ground-truth record of
one real broker symbol. It is a **reference only**: the EA never hard-codes
these values into its logic — every calculation reads live symbol
properties at runtime (master spec §6). Mismatches between this record and
the live capture are reported as warnings at EA init (spec-drift check).

## Recorded specification

| Property | Value | Note |
|---|---|---|
| Symbol | `XAUUSDm` | XAU/USD, Gold vs US Dollar |
| Category | Metals | |
| **Digits** | **3** | point = 0.001 |
| **Contract size** | **100 XAU** | |
| Spread | floating | measure live, never assume |
| **Stops level** | **0** | broker imposes no minimum stop distance |
| Margin currency | XAU | |
| Profit currency | USD | |
| Calculation | Forex | |
| Trade | Full access | trading permitted |
| Execution | Market | |
| GTC mode | Good till cancelled | |
| **Filling** | **FOK, IOC** | Fill-or-Kill / Immediate-or-Cancel; no RETURN |
| **Minimal volume** | **0.01** | |
| **Maximal volume** | **200** | |
| **Volume step** | **0.01** | |
| Swap type | in points | |
| Swap long | −533.9 | material cost for multi-day longs |
| Swap short | 0 | |
| Wednesday rate | ×3 | triple swap on Wednesdays |
| Sessions | Sun 22:01–24:00; Mon–Thu 00:00–20:58 & 22:00–…; Fri 00:00–20:58 | daily break 20:58→22:00 server time |
| Margin (initial) | ~215.08 USD/lot (buy), ~215.07 (sell) | notional-rate based; **Wednesdays ×3** |

## Consequences the EA must respect (verified in code/self-tests)

1. **Point value**: 100 oz contract ⇒ $1 per 0.01 move? No — with digits=3,
   point = 0.001 and **tick value per 0.001 ≈ $0.10**, i.e. **$100/point... per
   the EA's definition a "point" = 0.001 ⇒ ~$0.10 per point per lot**. The EA
   derives this live (`tick_value × point / tick_size`); this entry exists so
   research can sanity-check journal numbers.
2. **Stops level 0** means the SL/TP distance floor comes only from the
   live spread buffer in `XareBuildTradePlan` — the broker will accept
   very tight stops, so the strategy floors (ATR multiples) are the real
   protection.
3. **Filling = FOK/IOC only**: `XarePickFilling()` queries
   `SYMBOL_FILLING_MODE` and picks FOK first, IOC second — correct for this
   symbol; ORDER_FILLING_RETURN would be rejected.
4. **Wednesday ×3 swap/margin**: holding through Wednesday triples swap
   cost; the margin probe and any future multi-day analysis must expect it.
   Session break 20:58→22:00 means M15 bars are missing in that window —
   session/episode logic already tolerates gaps (bar-time based).
5. **Margin ≈ $215/lot** ⇒ the $50 small-account path can only trade
   0.01 lots with ~$2.15 margin — viable, but risk floors (§49) will
   correctly skip most trades below ~$1,000 equity at 0.5% risk. This is
   by design, not a bug.
