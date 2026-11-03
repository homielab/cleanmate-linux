"""Every icon-only button of the desktop app gets a name for screen readers (a11y.named).

Usage: a11y_check.py GUI_PACKAGE_DIR — lists the Gtk.Button / MenuButton / ToggleButton calls with
icon_name= and no label= that aren't wrapped in named(…), and fails when there is one.
"""
import ast
import os
import sys

BUTTONS = {"Button", "MenuButton", "ToggleButton"}


def is_icon_button(node):
    if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in BUTTONS
            and isinstance(node.func.value, ast.Name) and node.func.value.id == "Gtk"):
        return False
    kws = {k.arg for k in node.keywords}
    return "icon_name" in kws and "label" not in kws


def main(folder):
    missing, named = [], 0
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".py") or name == "selftest.py":
            continue
        path = os.path.join(folder, name)
        with open(path, encoding="utf-8") as f:
            tree = ast.parse(f.read(), path)
        wrapped = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "named" and node.args:
                wrapped.add(id(node.args[0]))
        for node in ast.walk(tree):
            if is_icon_button(node):
                if id(node) in wrapped:
                    named += 1
                else:
                    missing.append(f"{name}:{node.lineno}")
    if missing:
        print("\n".join(missing))
        return 1
    print(f"{named} icon-only buttons have an accessible name")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
