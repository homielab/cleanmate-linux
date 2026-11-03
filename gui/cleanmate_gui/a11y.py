"""Names for screen readers."""
from gi.repository import Gtk


def named(widget, label=None):
    """Give an icon-only button its accessible name: LABEL, else its tooltip. Returns the button."""
    text = label or widget.get_tooltip_text()
    if text:
        widget.update_property([Gtk.AccessibleProperty.LABEL], [text])
    return widget
