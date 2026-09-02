"""Lightweight regression checks for the Simplified Chinese release."""

from pathlib import Path
import re
import ast


ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / "butterfly_viewer" / "butterfly_viewer.py").read_text(encoding="utf-8")
ISS = (ROOT / "installer" / "butterfly_viewer.iss").read_text(encoding="utf-8")
README = (ROOT / "README.md").read_text(encoding="utf-8")


def test_version_is_consistent():
    assert re.search(r'VERSION\s*=\s*["\']1\.1\.0\.1["\']', MAIN)
    assert re.search(r'#define MyAppVersion\s+"1\.1\.0\.1"', ISS)
    assert "butterfly_viewer_v1.1.0.1_win64_setup" in ISS
    assert "Butterfly_Viewer_v1.1.0.1_Windows_Portable_zh-CN.zip" in README


def test_default_interface_is_chinese_and_portable():
    for phrase in ("创建", "滑动叠加创建器", "加载中……", "选择要打开的图像", "同步缩放"):
        assert phrase in MAIN or phrase in (ROOT / "butterfly_viewer" / "aux_interfaces.py").read_text(encoding="utf-8")
    assert '"butterfly_viewer.ini"' in MAIN
    assert "def get_settings()" in MAIN
    assert "QtCore.QSettings.IniFormat" in MAIN
    assert not re.search(r'QtCore\.QSettings\(\s*\)', MAIN)
    assert "https://github.com/fanqisyx/butterfly_viewer/" in MAIN
    assert '#define MyAppURL "https://github.com/fanqisyx/butterfly_viewer"' in ISS


def test_known_visible_english_phrases_are_not_left_in_ui_code():
    # Inspect string literals while excluding docstrings, so implementation
    # documentation may remain in the upstream language without masking UI leaks.
    literals = []
    for path in (ROOT / "butterfly_viewer").glob("*.py"):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        doc_nodes = set()
        for node in ast.walk(tree):
            body = getattr(node, "body", ())
            if isinstance(body, (list, tuple)) and body and isinstance(body[0], ast.Expr):
                value = body[0].value
                if isinstance(value, ast.Constant) and isinstance(value.value, str):
                    doc_nodes.add(id(value))
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in doc_nodes:
                literals.append(node.value)
    source = "\n".join(literals)
    known_untranslated = (
        "Select image...", "No filename available", "Sliding overlay creator",
        "Close image window", "Measurement ruler...", "Set background color...",
        "Save all comments of this view", "Load comments into this view",
        "Fullscreen on/off", "Hide interface", "Show interface", "File loaded",
        "Ready", "Select image(s) to open", "Cannot read file", "Loading...",
        "Side-by-side image viewer with synchronized zoom",
        "If provided, hides the interface on start.",
    )
    for phrase in known_untranslated:
        assert phrase not in source, phrase


if __name__ == "__main__":
    for test in (test_version_is_consistent, test_default_interface_is_chinese_and_portable,
                 test_known_visible_english_phrases_are_not_left_in_ui_code):
        test()
    print("localization static checks passed")
