"""Translations of the desktop app (gettext domain `cleanmate`).

Only the app's own text is translated; item labels and notes come from the
engine and stay in English. The .mo files are looked up in $CLEANMATE_LOCALEDIR,
gui/locale (built by po/compile.sh in a checkout), the share/locale next to an
installed app, then the system's locale folder.
"""
import gettext
import os

DOMAIN = "cleanmate"
_gui = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # …/gui or …/share/cleanmate/gui


def _translation():
    dirs = [os.environ.get("CLEANMATE_LOCALEDIR"), os.path.join(_gui, "locale"),
            os.path.join(_gui, "..", "..", "locale")]
    for d in dirs:
        if d and gettext.find(DOMAIN, d):
            return gettext.translation(DOMAIN, d)
    return gettext.translation(DOMAIN, fallback=True)


_t = _translation()
_ = _t.gettext


def ngettext(singular, plural, n, **fields):
    """The singular or plural form for n, with {n} and the other {fields} filled in."""
    return _t.ngettext(singular, plural, n).format(n=n, **fields)
