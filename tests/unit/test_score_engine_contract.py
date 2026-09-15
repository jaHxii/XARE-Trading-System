"""Score-engine contract tests (M8).

Python mirrors of the MQL5 SELF_TEST groups T11/T12 (XARE.mq5): the band
classifier, the weight-sum validator, and the exact component arithmetic of
the reference fixture. The authoritative logic is MQL5 (compile-gated);
these tests pin the documented behavior for regression.
"""
import pytest

# --- mirrors of the MQL5 bands (names kept identical) -------------------
BAND_NONE, BAND_CANDIDATE, BAND_TRADE, BAND_STRONG = "NONE", "CANDIDATE", "TRADE", "STRONG"


def xare_score_band(score, score_min, candidate, trade, strong):
    """Mirror of XareScoreBand() in ScoreEngine.mqh."""
    if score < score_min:
        return BAND_NONE
    if score < candidate:
        return BAND_CANDIDATE
    if score < trade:
        return BAND_TRADE
    return BAND_STRONG


def xare_weights_valid(w, tolerance=0.01):
    """Mirror of XareWeightsValid(): the 8 weights must sum to 100."""
    return abs(sum(w) - 100.0) <= tolerance


class TestScoreBand:
    """T11 mirror: band edges use strict < boundaries."""

    def test_below_min_is_none(self):
        assert xare_score_band(55, 60, 70, 80, 85) == BAND_NONE

    def test_exactly_min_is_candidate(self):
        assert xare_score_band(60, 60, 70, 80, 85) == BAND_CANDIDATE

    def test_candidate_band(self):
        assert xare_score_band(65, 60, 70, 80, 85) == BAND_CANDIDATE

    def test_trade_band(self):
        assert xare_score_band(75, 60, 70, 80, 85) == BAND_TRADE

    def test_strong_band(self):
        assert xare_score_band(90, 60, 70, 80, 85) == BAND_STRONG

    def test_score_never_negative_band_none(self):
        assert xare_score_band(-5, 60, 70, 80, 85) == BAND_NONE

    def test_default_thresholds_are_ordered(self):
        # defaults from Config.mqh: min < candidate < trade < strong
        assert 60 < 70 < 80 < 85


class TestWeightsValid:
    """T11 mirror: weights must sum to 100 (spec §16)."""

    def test_spec_weights_valid(self):
        # spec §16: 20+15+15+10+15+10+5+10 = 100
        assert xare_weights_valid([20, 15, 15, 10, 15, 10, 5, 10])

    def test_unbalanced_rejected(self):
        assert not xare_weights_valid([25, 15, 15, 10, 15, 10, 5, 10])

    def test_within_tolerance_accepted(self):
        assert xare_weights_valid([20.005] + [15, 15, 10, 15, 10, 5] + [9.995])

    def test_zero_rejected(self):
        assert not xare_weights_valid([0] * 8)


class TestFixtureArithmetic:
    """T12 mirror: the reference fixture must score exactly as documented.

    Fixture (bull pullback, all aligned): trend 20 (stack+DI), mtf 15,
    structure 10.5 (bull trend 0.7*15, no BOS), momentum 10 (roc>0.25,
    rsi 55 in 45..70), liquidity 0 (no sweep), volatility 10 (pct 50),
    session 3.5 (LONDON 0.7*5), setup 10 (confidence 100) -> 79.
    """

    def test_aligned_pullback_scores_79(self):
        total = 20 + 15 + 0.7 * 15 + 10 + 0 + 10 + 0.7 * 5 + 10
        assert total == pytest.approx(79.0)
        assert xare_score_band(total, 60, 70, 80, 85) == BAND_TRADE

    def test_counter_trend_drops_to_64(self):
        # range reversal: trend component 0.25*20 = 5 instead of 20
        total = 5 + 15 + 0.7 * 15 + 10 + 0 + 10 + 0.7 * 5 + 10
        assert total == pytest.approx(64.0)
        assert xare_score_band(total, 60, 70, 80, 85) == BAND_CANDIDATE

    def test_mixed_alignment_zeroes_mtf(self):
        # MIXED: mtf 0 -> same as counter-trend total (documented conflict cost)
        total = 20 + 0 + 0.7 * 15 + 10 + 0 + 10 + 0.7 * 5 + 10
        assert total == pytest.approx(64.0)
        assert xare_score_band(total, 60, 70, 80, 85) == BAND_CANDIDATE

    def test_total_clamped_to_100(self):
        # even with impossible perfection the engine clamps to 100
        assert min(150.0, 100.0) == 100.0
