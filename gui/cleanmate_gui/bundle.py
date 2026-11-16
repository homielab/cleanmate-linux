"""The app running on its own Python, GTK 4 and libadwaita (the AppImage, packaging/build-appimage.sh).

Its starter (`usr/bin/cleanmate-gui` in the image) points this process at the bundled libraries and data
with environment variables, names them in CLEANMATE_BUNDLE_ENV and keeps what each one was in
CLEANMATE_HOST_<NAME>. Everything the app starts would inherit them: the engine, the browser and the file
manager would load the image's libraries instead of the computer's. So once GTK is up (`leave`, from the
application's startup) every variable goes back to what it was; this process has read them by then.
"""
import os

ACTIVE = bool(os.environ.get("CLEANMATE_BUNDLE_ENV"))
# the starter itself: a restart runs it again (the Python that runs this can't start without its variables)
LAUNCHER = os.environ.get("CLEANMATE_GUI_LAUNCHER") if ACTIVE else None


def restore(environ):
    """Put the variables named in CLEANMATE_BUNDLE_ENV back, in ENVIRON; returns the starter's temporary file."""
    for name in environ.pop("CLEANMATE_BUNDLE_ENV", "").split():
        host = environ.pop(f"CLEANMATE_HOST_{name}", None)
        if host is None:
            environ.pop(name, None)
        else:
            environ[name] = host
    return environ.pop("CLEANMATE_BUNDLE_TMP", None)


def leave():
    """Read what GTK and GLib read from the environment only when first asked, then restore it (once)."""
    if "CLEANMATE_BUNDLE_ENV" not in os.environ:
        return
    from gi.repository import Gdk, GdkPixbuf, Gio, Gtk

    GdkPixbuf.Pixbuf.get_formats()  # the list of image loaders (GDK_PIXBUF_MODULE_FILE)
    Gio.SettingsSchemaSource.get_default()  # the settings schemas (XDG_DATA_DIRS)
    Gio.Vfs.get_default()  # GIO's modules (GIO_MODULE_DIR)
    Gio.content_type_guess(None, b"<svg")  # the file type database, which tells an SVG icon (XDG_DATA_DIRS)
    display = Gdk.Display.get_default()
    if display is not None:
        Gtk.IconTheme.get_for_display(display).has_icon("image-missing")  # the icon folders (XDG_DATA_DIRS)
    tmp = restore(os.environ)
    if tmp:
        try:
            os.unlink(tmp)
        except OSError:
            pass
