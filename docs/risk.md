# XARE — Risk Documentation

Version: v0.1.0

Risk is the product. The strategy is an experiment.

## Position sizing (the only size path)

```
risk_money   = equity × (risk_pct / 100)
sl_distance  = |entry − SL|                (price units)
value_per_price_unit_per_lot = tick_value / tick_size
volume_raw   = risk_money / (sl_distance × value_per_price_unit_per_lot)
volume       = floor_to_step(volume_raw, volume_step), clamped [min_lot, max_lot]
```

All of `tick_value`, `tick_size`, `contract_size`, `volume_step`, `min/max lot`
are read from the **broker's symbol properties at runtime**. Nothing is assumed.

- If `volume < min_lot` ⇒ **skip the trade** (log `RISK_SKIP_BELOW_MIN_VOLUME`)
  unless `AllowMinLotOverride=true`, which is a documented high-risk override.
- If volume is clamped to `max_lot` and implied risk exceeds `risk_pct` by more
  than a tolerance ⇒ skip (log `RISK_SKIP_CLAMP_EXCEEDS_RISK`).
- Realized loss at SL can still deviate from target via slippage/gap; the risk
  engine's job is to make the *planned* loss correct and the *worst* case bounded
  by the hard SL.

## Hard limits (all configurable)

| Limit | Default (hypothesis) | Behavior on breach |
|---|---|---|
| Risk per trade | 0.5% equity | sizing input |
| Max daily loss | 3% equity (realized+floating) | stop new trades for the day |
| Max weekly loss | 6% equity | stop new trades for the week |
| Max drawdown (peak→now) | 10% CAUTION, 15% REDUCED_RISK, 20% HALTED | risk state machine |
| Consecutive losses | 3 ⇒ cooldown `N` hours, risk × 0.5 | pause / reduce |
| Max trades/day | 5 | stop new trades |
| Max trades/session | 2 | stop new trades |
| Min minutes between trades | 60 | defer entry |
| Max concurrent positions (symbol) | 1 | hard one-position rule |
| Max spread | configurable points (abnormal threshold separate) | block trades |
| Max holding time | configurable bars/hours | time exit |

## Risk states

`NORMAL → CAUTION → REDUCED_RISK → DEFENSIVE → HALTED`, driven by
peak-to-current equity drawdown (defaults above). REDUCED_RISK halves risk and
blocks the more aggressive setups. **DEFENSIVE** (v0.17, §10) additionally
triggers on consecutive losing days (default 2) or a margin level below the
floor (default 200%) and bans counter-trend mean-reversion setups via the
regime-strategy matrix. HALTED also **closes nothing by default** but blocks all
new trades and requires manual EA re-init to clear (safety latch against
oscillation).

### Adaptive risk factors (v0.17, §6)

Final risk = base × state ladder × bounded factor product. Every factor is
clamped to `[factor_min, 1.0]` (default floor 0.5): **risk can only shrink or
stay — no factor can amplify it** (test-enforced invariant). Factors without
data-backed justification are passed as N/A and skipped, not invented.

### Survival layers (v0.17)

- Profit-lock floor (§9): optional (default OFF, unvalidated); once armed the
  floor ratchets up only; breach blocks new sends.
- Capital stages (§8): research labels MICRO/GROWTH/STANDARD/SCALE (+ health
  override DEFENSIVE); stage factor is reduce-only; transitions logged.
- Weekend engine (§15): Friday final-entry cutoff; optional close-all (OFF).
- Cooldown suite (§12): post-SL, abnormal-slippage, per-session cap — stacked
  with the loss-streak cooldown.
- Margin-level floor (§10): falling margin level blocks entries (MARGIN_LEVEL).
- Startup health (§21): BLOCKED verdict blocks sends with reason HEALTH.
- State persistence (§20): restart restores anchors/counters/cooldowns and
  adopts the open position's management flags — no duplicate management, no
  duplicate orders after a crash.

## Daily accounting

- Daily anchor: **broker trading day** (`TimeTradeServer()` date), not local midnight.
- Tracks starting equity, realized P/L (closed trades this day), floating P/L
  (open positions of this EA), and daily drawdown.
- Optional `CloseOnDailyBreach` (default **false**) may flatten positions when
  the daily limit is breached; off by default to avoid forced exits, and
  documented as a researched choice.

## Protections that exist in code (not aspirational)

- Global risk switch (`InpTradingEnabled`, plus per-mode hard gates)
- Spread filter with normal/abnormal thresholds
- Volatility gate: ABNORMAL volatility blocks new entries (manages exits only)
- Streak cooldown with bounded risk reduction (× factor, floor)
- Emergency stop: data corruption, repeated order failures, state inconsistency
- No martingale: no code path multiplies risk by loss count; multiplier ∈ [0,1]
- No grid: no code path opens a second position while one exists

## What risk CANNOT do

- Prevent slippage beyond SL on gaps/news (broker-side reality; the news filter
  and abnormal-volatility gate exist to reduce exposure to those windows)
- Make a losing strategy profitable
- Guarantee the daily limit equals the worst-case day (limits are on *new risk*;
  existing positions carry their planned hard-SL risk)
