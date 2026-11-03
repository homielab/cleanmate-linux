"""The window's remembered page and size (gui/cleanmate_gui/state.py)."""
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gui"))
from cleanmate_gui import state  # noqa: E402


class WindowState(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.file = os.path.join(self.dir, "cleanmate", "window")

    def test_nothing_saved(self):
        self.assertEqual(state.load(self.file), {})

    def test_round_trip(self):
        state.save("dupes", 1200, 800, False, self.file)
        self.assertEqual(state.load(self.file), {"page": "dupes", "width": 1200, "height": 800, "maximized": False})

    def test_odd_size_is_ignored(self):
        state.save("lens", 5, 800, True, self.file)
        self.assertEqual(state.load(self.file), {"page": "lens", "maximized": True})

    def test_broken_file(self):
        os.makedirs(os.path.dirname(self.file))
        with open(self.file, "w") as f:
            f.write("not a key file\x00")
        self.assertEqual(state.load(self.file), {})


if __name__ == "__main__":
    unittest.main()
