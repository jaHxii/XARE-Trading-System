"""Regression guards: the EA must not contain trade paths or hard-coded symbols.

These source-level guards exist because M1 has no live trading, and must stay
true until a fully validated execution engine lands (M10+).
"""
from pathlib import Path

MQL5 = Path(__file__).resolve().parents[2] / "mql5"

ALL_SOURCES = [MQL5 / "XARE.mq5"] + sorted((MQL5 / "Include" / "XARE").glob("*.mqh"))


def test_no_order_sending_apis():
    """Order APIs live ONLY in the dedicated execution layer (spec §29).

    M1 invariant was 'no order APIs anywhere'. From M10 the invariant is:
    OrderSend may appear in ExecutionEngine.mqh only; CTrade-style wrappers
    and one-liner Buy(/Sell( helpers are forbidden everywhere (the EA uses
    raw MqlTradeRequest with explicit validation, never blind convenience
    sends).
    """
    import re
    forbidden = [
        r"\bCTrade\b",
        r"\bPositionOpen\b",
        r"\bPositionClose\b",    # word boundary: not CheckPositionClosed
        r"\bPositionModify\b",
        r"\.Buy\(",
        r"\.Sell\(",
    ]
    for src in ALL_SOURCES:
        text = src.read_text(encoding="utf-8")
        for token in forbidden:
            assert not re.search(token, text), \
                f"{src.name} contains trade API /{token}/"


def test_ordersend_confined_to_execution_layer():
    """OrderSend exists only inside ExecutionEngine.mqh (single choke point)."""
    for src in ALL_SOURCES:
        text = src.read_text(encoding="utf-8")
        if src.name == "ExecutionEngine.mqh":
            assert "OrderSend" in text, "execution layer lost its send path"
        else:
            assert "OrderSend" not in text, \
                f"{src.name} must not send orders directly (use ExecutionEngine)"


def test_ordercalcmargin_is_readonly_probe():
    """Margin queries are read-only; they must never send anything."""
    ea = (MQL5 / "XARE.mq5").read_text(encoding="utf-8")
    assert "OrderCalcMargin" in ea  # probe present
    assert "OrderSend" not in ea    # EA itself never sends — execution layer does


def test_no_hardcoded_symbol():
    """Spec 6: EA must operate on _Symbol; no broker symbol hard-coded.
    Comments and #property metadata (product branding) are excluded; any
    appearance in executable logic is a failure."""
    for src in ALL_SOURCES:
        logic_lines = [
            line.split("//")[0]
            for line in text_lines(src)
            if not line.lstrip().startswith("//")
            and not line.lstrip().startswith("#property")
        ]
        code = "\n".join(logic_lines)
        for token in ("XAUUSD", "XAUUSDm", "GOLD"):
            assert token not in code, f"{src.name} hard-codes '{token}' in logic"


def text_lines(src: Path):
    return src.read_text(encoding="utf-8").splitlines()


def test_symbol_taken_from_chart():
    ea = (MQL5 / "XARE.mq5").read_text(encoding="utf-8")
    assert "g_symbol = _Symbol;" in ea


def test_version_property_compiles_clean_rule():
    """Compiler rejects 0.x majors (warning 68); property must not use them.
    Authoritative semver lives in docs/changelog.md and the git tag."""
    ea = (MQL5 / "XARE.mq5").read_text(encoding="utf-8")
    for line in ea.splitlines():
        if line.startswith("#property version"):
            ver = line.split('"')[1]
            assert not ver.startswith("0."), \
                f"#property version '{ver}' triggers compiler warning 68"
