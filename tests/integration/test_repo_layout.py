"""Regression guard: core project artifacts must exist (M0/M1).

If one of these disappears, the repository layout broke — fail loudly.
"""
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

REQUIRED_FILES = [
    "README.md",
    "LICENSE",
    ".gitignore",
    "docs/architecture.md",
    "docs/strategy.md",
    "docs/risk.md",
    "docs/testing.md",
    "docs/parameters.md",
    "docs/changelog.md",
    "experiments/README.md",
    "experiments/experiment_registry.csv",
    "python/requirements.txt",
    "mql5/XARE.mq5",
    "mql5/Include/XARE/Types.mqh",
    "mql5/Include/XARE/Config.mqh",
    "mql5/Include/XARE/Logger.mqh",
    "mql5/Include/XARE/Diagnostics.mqh",
]


def test_required_files_exist():
    missing = [f for f in REQUIRED_FILES if not (REPO / f).is_file()]
    assert not missing, f"missing project files: {missing}"


def test_registry_header_intact():
    line = (REPO / "experiments/experiment_registry.csv").read_text(
        encoding="utf-8").splitlines()[0]
    for col in ("experiment_id", "code_version", "param_version",
                "robustness_label", "notes"):
        assert col in line, f"registry header lost column {col}"


def test_ea_defaults_are_safe():
    """Spec 63: defaults must never trade. Parse XARE.mq5 input defaults."""
    src = (REPO / "mql5/XARE.mq5").read_text(encoding="utf-8")
    assert "InpMode            = XARE_MODE_SIGNAL_ONLY" in src
    assert "InpTradingEnabled  = false" in src


def test_config_defaults_are_safe():
    """Spec 63 mirrored in Config.mqh defaults."""
    src = (REPO / "mql5/Include/XARE/Config.mqh").read_text(encoding="utf-8")
    assert "XARE_MODE_SIGNAL_ONLY" in src
    assert "c.trading_enabled        = false" in src


def test_no_mql4_strict_property():
    src = (REPO / "mql5/XARE.mq5").read_text(encoding="utf-8")
    assert "#property strict" not in src, "MQL4-only directive present"
