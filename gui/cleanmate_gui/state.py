"""What the window remembers between runs: the open page and the window size (`~/.config/cleanmate/window`)."""
import os

from gi.repository import GLib


def path():
    return os.path.join(GLib.get_user_config_dir(), "cleanmate", "window")


def load(file=None):
    """{"page": str, "width": int, "height": int, "maximized": bool} with what was saved; {} when nothing is."""
    kf = GLib.KeyFile()
    try:
        kf.load_from_file(file or path(), GLib.KeyFileFlags.NONE)
    except GLib.Error:
        return {}
    state = {}
    for key, get in (("page", kf.get_string), ("width", kf.get_integer), ("height", kf.get_integer),
                     ("maximized", kf.get_boolean)):
        try:
            state[key] = get("window", key)
        except GLib.Error:
            pass
    if not (200 <= state.get("width", 0) <= 20000 and 200 <= state.get("height", 0) <= 20000):
        state.pop("width", None)
        state.pop("height", None)
    return state


def save(page, width, height, maximized, file=None):
    """Write the state; a folder or file that can't be written is left as it is."""
    file = file or path()
    kf = GLib.KeyFile()
    kf.set_string("window", "page", page)
    kf.set_integer("window", "width", width)
    kf.set_integer("window", "height", height)
    kf.set_boolean("window", "maximized", maximized)
    try:
        os.makedirs(os.path.dirname(file), exist_ok=True)
        kf.save_to_file(file)
    except (OSError, GLib.Error):
        pass
