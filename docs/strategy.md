# XARE — Strategy Documentation

Version: v0.1.0

> Everything in this document is a **hypothesis to be tested**, not a claim.
> The scoring weights, setup definitions, and thresholds are initial guesses
> chosen to be sensible and explainable — their correctness is exactly what
> the research pipeline must establish or refute.

## Instrument and timeframe

- Symbol: broker gold symbol (`XAUUSDm` on Exness at time of writing)
- Execution TF: **M15** (all decisions on closed M15 bars)
- Context TFs: H4 (macro), H1 (intermediate), M5 (optional refinement, off by default)

## Context stack

1. **Regime** (TREND_UP / TREND_DOWN / RANGE / BREAKOUT / HIGH_VOL / LOW_VOL /
   UNSAFE / UNKNOWN) from EMA structure, ADX, ATR percentile, and realized range
   behavior. Confidence 0–100 with textual evidence; it is a *score*, not a probability.
2. **Structure**: swing highs/lows (fractal pivots, confirmed after N bars),
   trend label (HH/HL vs LH/LL), BOS and CHoCH events, approximate S/R zones.
3. **Liquidity**: prior-day high/low, session highs/lows, recent swing extremes.
   Objective sweep definition: price trades through a level by ≥ x·ATR and
   closes back on the origin side within k bars.
4. **Session**: Asian / London / NY / London-NY overlap, computed in **broker
   time** from configurable windows (Exness server = UTC+0 by default; verify
   with the `scripts/check_broker_time.py` probe before trusting session logic).

## Setups (v0.1)

| Setup | Direction | Precondition | Trigger (closed M15) |
|---|---|---|---|
| TREND_CONTINUATION | with regime trend | TREND_UP/DOWN, alignment matches | momentum re-acceleration in trend direction |
| TREND_PULLBACK | with regime trend | TREND_UP/DOWN, alignment matches | pullback to EMA20/50 zone, rejection close back in trend direction |
| BREAKOUT | with regime | RANGE/BREAKOUT | close beyond range edge with expansion |
| BREAKOUT_RETEST | with regime | BREAKOUT | return to broken edge, rejection close |
| RANGE_REVERSAL | counter-move | RANGE regime only | rejection at range extreme toward range middle |
| LIQUIDITY_SWEEP_REVERSAL | counter-move | sweep of PDH/PDL or session extreme + rejection | reclaim close |

Each setup returns: direction, type, confidence (0–100), entry zone,
invalidation condition, and evidence list. The engine can always return
NO_TRADE — that is the default answer.

## Scoring

0–100 weighted sum; weights are configurable hypotheses (see
`docs/parameters.md`):

trend 20 · MTF alignment 15 · structure 15 · momentum 10 · liquidity 15 ·
volatility 10 · session 5 · setup quality 10

Bands (configurable): < `MinScore` = no trade; `MinScore..Candidate` =
candidate; above Candidate = trade candidate; above Strong = high quality.
The score is not a probability and is never presented as one.

## Exits

Priority order (first applicable wins per bar):

1. Hard SL (always present, set at entry, never widened)
2. Regime-flip exit (regime turns against the position with confidence ≥ threshold)
3. Signal-reversal exit (opposite setup fires with score ≥ threshold)
4. Time exit (max bars / max hours in trade without reaching +x R)
5. Trailing stop (ATR-based once beyond threshold R; ratchet only)
6. Break-even move (at +y R; ratchet only)
7. Partial close (at +z R, configurable fraction)
8. TP (fixed R multiple, structure target, or ATR target — configurable)

## Anti-goals (hard rejects)

- No martingale/recovery sizing; risk adjustment after losses is bounded and
  downward only.
- No adding to losing positions; v0.1 = one position per symbol, no scaling.
- No stop widening; stops only tighten (BE/trailing are ratchets).
- No trade without a hard SL validated against broker stops level.
- No "the score is high enough, ignore the regime flip".
