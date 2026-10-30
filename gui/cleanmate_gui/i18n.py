"""Translations of the desktop app (gettext domain `cleanmate`).

The app's own text, plus the cleanup items' names and descriptions the engine
sends in English (`item_text`; po/extract-items.sh puts them in the catalog,
numbers as {0}, {1}…). The .mo files are looked up in $CLEANMATE_LOCALEDIR,
gui/locale (built by po/compile.sh in a checkout), the share/locale next to an
installed app, then the system's locale folder.

The language is the system's, unless Settings › Language picked one (`language=en|vi` in the
settings file, read here directly so start-up doesn't wait for the engine); a change shows after a
restart. The system's own LANGUAGE is never changed.
"""
import gettext
import os
import re

DOMAIN = "cleanmate"
_gui = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # …/gui or …/share/cleanmate/gui


LANGUAGES = ("system", "en", "vi")  # the engine's `language` choices, the default first


def chosen_language():
    """The language saved in Settings: "en", "vi", or "system" (also when the file has none or a wrong one)."""
    config = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    found = "system"
    try:
        with open(os.path.join(config, "cleanmate", "settings"), encoding="utf-8", errors="replace") as f:
            for line in f:  # the engine's rule: a value it doesn't know reads as the default
                key, _sep, value = line.rstrip("\n").partition("=")
                if key == "language":
                    found = value if value in LANGUAGES else "system"
    except OSError:
        pass
    return found


def _translation(language):
    langs = None if language == "system" else [language]  # None: LANGUAGE, LC_ALL, LC_MESSAGES, LANG
    dirs = [os.environ.get("CLEANMATE_LOCALEDIR"), os.path.join(_gui, "locale"),
            os.path.join(_gui, "..", "..", "locale")]
    for d in dirs:
        if d and gettext.find(DOMAIN, d, languages=langs):
            return gettext.translation(DOMAIN, d, languages=langs)
    return gettext.translation(DOMAIN, languages=langs, fallback=True)  # "en": no catalog, the text as written


AT_LAUNCH = chosen_language()  # Settings offers a restart while the saved language differs
_t = _translation(AT_LAUNCH)
_ = _t.gettext


def ngettext(singular, plural, n, **fields):
    """The singular or plural form for n, with {n} and the other {fields} filled in."""
    return _t.ngettext(singular, plural, n).format(n=n, **fields)


NUMBER = re.compile(r"\b\d+\b")


def _template(text):
    """'Keeps the last 7 days' → ('Keeps the last {0} days', ['7']); same as po/extract-items.sh."""
    nums = NUMBER.findall(text)
    if not nums or "{" in text or "}" in text:
        return None, []
    count = iter(range(len(nums)))
    return NUMBER.sub(lambda _m: "{%d}" % next(count), text), nums


def _lookup(text):
    """The translation of an engine text, or None."""
    catalog = getattr(_t, "_catalog", {})  # a name like "Firefox" may translate to itself
    if not text:
        return None
    if catalog.get(text):
        return catalog[text]
    tmpl, nums = _template(text)
    if tmpl and catalog.get(tmpl):
        try:
            return catalog[tmpl].format(*nums)
        except (IndexError, KeyError, ValueError):
            return None
    return None


OUTSIDE_HOME = re.compile(r"Downloads folder is outside your home folder \((.*)\); CleanMate only cleans inside it")


def item_text(text):
    """A name, description or note from the engine, translated when the catalog has it."""
    m = OUTSIDE_HOME.fullmatch(text or "")
    if m:  # the note carries a path, so it can't be a catalog key as it is
        return _("Downloads folder is outside your home folder ({path}); CleanMate only cleans inside it").format(
            path=m[1])
    return _lookup(text) or text


def translating():
    """True when a catalog other than English is loaded."""
    return type(_t) is not gettext.NullTranslations


def untranslated(text):
    """True when the loaded catalog has no translation for this engine text."""
    return bool(text) and translating() and _lookup(text) is None
