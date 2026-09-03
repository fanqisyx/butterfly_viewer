"""Regression check for the PyQt5 startup crash fixed in v1.1.0.2."""

import ast
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "butterfly_viewer" / "aux_interfaces.py"


def test_qpainter_draw_rect_arguments_contain_no_float_literals():
    """PyQt5's integer drawRect overload rejects float-derived arguments."""
    tree = ast.parse(SOURCE_PATH.read_text(encoding="utf-8"), filename=str(SOURCE_PATH))
    slider_class = next(
        node for node in tree.body
        if isinstance(node, ast.ClassDef) and node.name == "SliderDeluxe"
    )
    draw_rect_calls = [
        node for node in ast.walk(slider_class)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "drawRect"
    ]
    assert draw_rect_calls
    for call in draw_rect_calls:
        float_literals = [
            node.value for argument in call.args for node in ast.walk(argument)
            if isinstance(node, ast.Constant) and isinstance(node.value, float)
        ]
        assert not float_literals, float_literals


if __name__ == "__main__":
    test_qpainter_draw_rect_arguments_contain_no_float_literals()
    print("startup regression check passed")
