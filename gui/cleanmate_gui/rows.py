"""Rows whose title and subtitle are plain text.

Adw rows read their title and subtitle as Pango markup by default, so a name like "VS Code & forks" or a size
like "<1%" prints a GTK warning and shows nothing. Keyword arguments don't help: the text may be set before
use-markup. plain_row turns markup off first, then sets the text.
"""


def plain_row(cls, title=None, subtitle=None, **props):
    """An Adw.ActionRow (or ExpanderRow, SwitchRow, ComboRow, SpinRow) of class CLS showing TITLE and SUBTITLE
    as they are."""
    row = cls(use_markup=False, **props)
    if title is not None:
        row.set_title(title)
    if subtitle is not None:
        row.set_subtitle(subtitle)
    return row
