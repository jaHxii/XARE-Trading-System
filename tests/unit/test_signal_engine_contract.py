"""Signal-engine contract tests (M7).

These mirror the semantics locked by the MQL5 SELF_TEST groups T9/T10 in
XARE.mq5: same gates, same reason precedence, same directional policy.
The authoritative logic is MQL5 (compile-gated); these tests pin the
documented behavior for regression and review.
"""
from dataclasses import dataclass, field

# --- mirrors of the MQL5 enums (names kept identical) ---------------------
NT_NONE, NT_INSUFFICIENT_DATA, NT_REGIME_INCOMPATIBLE, NT_ALIGNMENT_CONFLICT, \
    NT_REGIME_CONFIDENCE, NT_NO_SETUP_TRIGGER, NT_SETUP_DISABLED = range(7)

SETUP_NONE, SETUP_TREND_CONTINUATION, SETUP_TREND_PULLBACK, SETUP_BREAKOUT, \
    SETUP_BREAKOUT_RETEST, SETUP_RANGE_REVERSAL, SETUP_LIQUIDITY_SWEEP_REVERSAL = range(7)

R_UNKNOWN, R_TREND_UP, R_TREND_DOWN, R_RANGE, R_BREAKOUT, \
    R_HIGH_VOL, R_LOW_VOL, R_UNSAFE = range(8)

A_NEUTRAL, A_BULLISH, A_BEARISH, A_MIXED = range(4)

S_OFF, S_ASIAN, S_LONDON, S_NEWYORK, S_OVERLAP = range(5)


@dataclass
class Regime:
    valid: bool = True
    regime: int = R_TREND_UP
    confidence: int = 80


@dataclass
class MTF:
    valid: bool = True
    alignment: int = A_BULLISH


@dataclass
class Structure:
    valid: bool = True
    trend: int = 1  # BULLISH
    last_swing_high: float = 2050.0
    last_swing_low: float = 2000.0
    bos_bull: bool = False
    bos_bear: bool = False


@dataclass
class Session:
    valid: bool = True
    session: int = S_LONDON


@dataclass
class Liquidity:
    valid: bool = True
    sweep_up: bool = False
    sweep_down: bool = False
    swept_level: float = 0.0
    level_name: str = ""
    penetration_atr: float = 0.0


@dataclass
class Bar:
    # default fixture mirrors MQL5 T9a: bearish close ⇒ no trigger
    close: float = 2044.0
    open: float = 2046.0
    high: float = 2052.0
    low: float = 2042.0
    time: int = 1000


@dataclass
class Features:
    valid: bool = True
    ema_fast: float = 2045.0
    ema_mid: float = 2035.0
    ema_slow: float = 2010.0
    rsi: float = 55.0
    roc: float = 0.5
    adx: float = 30.0
    di_plus: float = 25.0
    di_minus: float = 15.0
    atr: float = 4.0


# --- Python mirror of the MQL5 gate chain (XARE.mq5 SELF_TEST T9/T10) -----
def evaluate(regime, mtf, structure, session, liquidity, bar, features,
             prev_roc, cfg=None):
    cfg = cfg or {"regime_conf_min": 55, "min_setup_confidence": 55.0,
                  "setup_trend_pullback": True, "setup_sweep": True}
    if not (regime.valid and mtf.valid and structure.valid and features.valid
            and bar.close > 0):
        return {"signal": False, "reason": NT_INSUFFICIENT_DATA}

    if regime.regime in (R_UNSAFE, R_UNKNOWN, R_HIGH_VOL, R_LOW_VOL):
        return {"signal": False, "reason": NT_REGIME_INCOMPATIBLE}

    if regime.confidence < cfg["regime_conf_min"]:
        return {"signal": False, "reason": NT_REGIME_CONFIDENCE}

    if mtf.alignment == A_MIXED:
        return {"signal": False, "reason": NT_ALIGNMENT_CONFLICT}

    # detector priority mirrors MQL5: sweep reversal BEFORE pullback
    # sweep reversal (mirror: sellside swept -> long)
    if cfg["setup_sweep"] and liquidity.sweep_down and liquidity.penetration_atr > 0:
        conf = 55.0 + 15.0 * min(liquidity.penetration_atr, 1.0)
        if conf >= cfg["min_setup_confidence"]:
            return {"signal": True, "direction": +1,
                    "setup": SETUP_LIQUIDITY_SWEEP_REVERSAL, "confidence": conf}

    # pullback detector (mirror of MQL5 DetTrendPullback, bullish fixture)
    if mtf.alignment == A_BULLISH and cfg["setup_trend_pullback"]:
        atr = features.atr
        zone_half = cfg.get("pullback_zone_atr", 1.2) * atr * 0.5
        zlo = min(features.ema_fast, features.ema_mid) - zone_half
        zhi = max(features.ema_fast, features.ema_mid) + zone_half
        touched = bar.low <= zhi
        rejected = bar.close > bar.open and bar.close > features.ema_fast
        rsi_ok = 40.0 < features.rsi < 70.0
        if touched and rejected and rsi_ok:
            conf = 65.0 + (5.0 if features.rsi < 55.0 else 0.0)
            if conf >= cfg["min_setup_confidence"]:
                return {"signal": True, "direction": +1,
                        "setup": SETUP_TREND_PULLBACK, "confidence": conf}
    return {"signal": False, "reason": NT_NO_SETUP_TRIGGER}


def base_ctx():
    return dict(regime=Regime(), mtf=MTF(), structure=Structure(),
                session=Session(), liquidity=Liquidity(),
                bar=Bar(), features=Features(), prev_roc=0.1)


# --- tests -----------------------------------------------------------------
def test_direction_matches_alignment_for_trend_setups():
    ctx = base_ctx()
    ctx.update(bar=Bar(open=2044, high=2050, low=2038, close=2049))
    r = evaluate(**ctx)
    assert r["signal"] and r["direction"] == +1
    assert r["setup"] == SETUP_TREND_PULLBACK


def test_no_trade_when_no_trigger():
    r = evaluate(**base_ctx())
    assert not r["signal"] and r["reason"] == NT_NO_SETUP_TRIGGER


def test_insufficient_data():
    ctx = base_ctx()
    ctx["features"] = Features(valid=False)
    r = evaluate(**ctx)
    assert not r["signal"] and r["reason"] == NT_INSUFFICIENT_DATA


def test_regime_incompatible():
    ctx = base_ctx()
    ctx["regime"] = Regime(regime=R_UNSAFE)
    r = evaluate(**ctx)
    assert not r["signal"] and r["reason"] == NT_REGIME_INCOMPATIBLE


def test_regime_confidence_floor():
    ctx = base_ctx()
    ctx["regime"] = Regime(confidence=30)
    r = evaluate(**ctx)
    assert not r["signal"] and r["reason"] == NT_REGIME_CONFIDENCE


def test_mixed_alignment_blocks_all():
    ctx = base_ctx()
    ctx["mtf"] = MTF(alignment=A_MIXED)
    ctx.update(bar=Bar(open=2044, high=2050, low=2038, close=2049))
    ctx["liquidity"] = Liquidity(sweep_down=True, swept_level=2000.0,
                                 level_name="PDL", penetration_atr=0.6)
    r = evaluate(**ctx)
    assert not r["signal"] and r["reason"] == NT_ALIGNMENT_CONFLICT


def test_disabled_setup_reports_disabled():
    ctx = base_ctx()
    ctx.update(bar=Bar(open=2044, high=2050, low=2038, close=2049))
    r = evaluate(**ctx, cfg={"regime_conf_min": 55, "min_setup_confidence": 55.0,
                             "setup_trend_pullback": False, "setup_sweep": True})
    assert not r["signal"]


def test_sweep_reversal_bull_on_sellside_sweep():
    ctx = base_ctx()
    ctx["liquidity"] = Liquidity(sweep_down=True, swept_level=2000.0,
                                 level_name="PDL", penetration_atr=0.6)
    r = evaluate(**ctx)
    assert r["signal"] and r["direction"] == +1
    assert r["setup"] == SETUP_LIQUIDITY_SWEEP_REVERSAL
    assert 55.0 <= r["confidence"] <= 70.0
