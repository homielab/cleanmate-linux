"""Translations of the desktop app (gettext domain `cleanmate`).

The app's own text, plus the cleanup items' names and descriptions the engine
sends in English (`item_text`; po/extract-items.sh puts them in the catalog,
numbers as {0}, {1}…). Texts the engine makes at scan time (apps found, scan
notes, details lines) are matched against the pattern tables below
(`note_text`, `detail_text`); one that matches none stays in English. The .mo files are looked up in $CLEANMATE_LOCALEDIR,
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
APP_CACHE = re.compile(r"Cache folders of (.+) \((.+)\)\. Rebuilt automatically — close the app before cleaning\.")


def _static():
    """Engine texts made at scan time that carry no value (so po/extract-items.sh never sees them)."""
    return {
        "A model Ollama downloaded. Removed with 'ollama rm'; layers other models use are kept.":
            _("A model Ollama downloaded. Removed with 'ollama rm'; layers other models use are kept."),
        "A model in the Hugging Face cache. Python code downloads it again the next time it is used.":
            _("A model in the Hugging Face cache. Python code downloads it again the next time it is used."),
        "A model downloaded in LM Studio. Download it again from LM Studio's Discover tab.":
            _("A model downloaded in LM Studio. Download it again from LM Studio's Discover tab."),
        "Electron app": _("Electron app"),
        "not used by any container": _("not used by any container"),
        "BuildKit cache": _("BuildKit cache"),
        "scan timed out": _("scan timed out"),
    }


def item_text(text):
    """A name, description or note from the engine, translated when the catalog or a pattern has it."""
    text = text or ""
    m = OUTSIDE_HOME.fullmatch(text)
    if m:  # the note carries a path, so it can't be a catalog key as it is
        return _("Downloads folder is outside your home folder ({path}); CleanMate only cleans inside it").format(
            path=m[1])
    m = APP_CACHE.fullmatch(text)
    if m:  # an app found on this computer
        return _("Cache folders of {app} ({kind}). Rebuilt automatically — close the app before cleaning.").format(
            app=m[1], kind=_static().get(m[2], m[2]))
    return _lookup(text) or _static().get(text) or text


# The engine's `plural N WORD`: "1 file", "3 files", "2 entries". Every noun it counts in notes and details.
_COUNTS = {
    "item": lambda n: ngettext("{n} item", "{n} items", n),
    "file": lambda n: ngettext("{n} file", "{n} files", n),
    "folder": lambda n: ngettext("{n} folder", "{n} folders", n),
    "leftover folder": lambda n: ngettext("{n} leftover folder", "{n} leftover folders", n),
    "app": lambda n: ngettext("{n} app", "{n} apps", n),
    "project": lambda n: ngettext("{n} project", "{n} projects", n),
    "package": lambda n: ngettext("{n} package", "{n} packages", n),
    "removed package": lambda n: ngettext("{n} removed package", "{n} removed packages", n),
    "package archive": lambda n: ngettext("{n} package archive", "{n} package archives", n),
    "downloaded installer": lambda n: ngettext("{n} downloaded installer", "{n} downloaded installers", n),
    "download": lambda n: ngettext("{n} download", "{n} downloads", n),
    "disabled revision": lambda n: ngettext("{n} disabled revision", "{n} disabled revisions", n),
    "version": lambda n: ngettext("{n} version", "{n} versions", n),
    "drive": lambda n: ngettext("{n} drive", "{n} drives", n),
    "list": lambda n: ngettext("{n} list", "{n} lists", n),
    "history list": lambda n: ngettext("{n} history list", "{n} history lists", n),
    "image": lambda n: ngettext("{n} image", "{n} images", n),
    "dangling image": lambda n: ngettext("{n} dangling image", "{n} dangling images", n),
    "container": lambda n: ngettext("{n} container", "{n} containers", n),
    "stopped container": lambda n: ngettext("{n} stopped container", "{n} stopped containers", n),
    "volume": lambda n: ngettext("{n} volume", "{n} volumes", n),
    "anonymous volume": lambda n: ngettext("{n} anonymous volume", "{n} anonymous volumes", n),
    "named volume": lambda n: ngettext("{n} named volume", "{n} named volumes", n),
    "AVD": lambda n: ngettext("{n} AVD", "{n} AVDs", n),
    "snapshot": lambda n: ngettext("{n} snapshot", "{n} snapshots", n),
    "session": lambda n: ngettext("{n} session", "{n} sessions", n),
    "model": lambda n: ngettext("{n} model", "{n} models", n),
    "report": lambda n: ngettext("{n} report", "{n} reports", n),
    "dump": lambda n: ngettext("{n} dump", "{n} dumps", n),
    "command": lambda n: ngettext("{n} command", "{n} commands", n),
    "entry": lambda n: ngettext("{n} entry", "{n} entries", n),
    "remembered choice": lambda n: ngettext("{n} remembered choice", "{n} remembered choices", n),
}


def _english_plural(word):
    return word[:-1] + "ies" if re.search(r"[^aeiou]y$", word) else word + "s"


_FORMS = {f: noun for noun in _COUNTS for f in (noun, _english_plural(noun))}
COUNT = re.compile(r"\b(\d+) (%s)\b" % "|".join(sorted(map(re.escape, _FORMS), key=len, reverse=True)))


def _count(m):
    """'3 files' → '3 tệp'."""
    return _COUNTS[_FORMS[m[2]]](int(m[1]))


def _sentences():
    """Notes with counts ({c0}, {c1} in the English) or values: (pattern, translated template)."""
    return [
        (r"\{c0\} in /var/log", _("{count} in /var/log")),
        (r"\{c0\} in ~/\.cache", _("{count} in ~/.cache")),
        (r"\{c0\} in \{c1\}", _("{count} in {count2}")),
        (r"\{c0\} on \{c1\}", _("{count} on {count2}")),
        (r"\{c0\}, \{c1\}", _("{count}, {count2}")),
        (r"\{c0\} still configured", _("{count} still configured")),
        (r"\{c0\} older than (?P<days>\d+) days", _("{count} older than {days} days")),
        (r"\{c0\} untouched for (?P<days>\d+)\+ days", _("{count} untouched for {days}+ days")),
        (r"\{c0\} idle for (?P<days>\d+)\+ days", _("{count} idle for {days}+ days")),
        (r"\{c0\} with entries", _("{count} with entries")),
        (r"\{c0\} that no longer exist", _("{count} that no longer exist")),
        (r"\{c0\} not your default", _("{count} not your default")),
        (r"\{c0\} no AVD uses", _("{count} no AVD uses")),
        (r"\{c0\} replaced by a newer one", _("{count} replaced by a newer one")),
        (r"\{c0\} — may contain data", _("{count} — may contain data")),
        (r"\{c0\} kept", _("{count} kept")),
        (r"\{c0\}", "{count}"),
        (r"(?P<size>\d[\d.,]* ?[KMGTP]?i?B) in total", _("{size} in total")),
        (r"skipped while running: (?P<names>.+)", _("skipped while running: {names}")),
        (r"get it back with: ollama pull (?P<ref>.+)", _("get it back with: ollama pull {ref}")),
    ]


def _note_part(text):
    known = item_text(text)
    if known != text or "{" in text or "}" in text:
        return known
    counts = []

    def hold(m):
        counts.append(_count(m))
        return "{c%d}" % (len(counts) - 1)

    shape = COUNT.sub(hold, text)
    for pattern, template in _sentences():
        m = re.fullmatch(pattern, shape)
        if m:
            fields = dict(zip(("count", "count2"), counts), **m.groupdict())
            try:
                return template.format(**fields)
            except (IndexError, KeyError):
                return text
    return text  # an unknown note stays in English


def note_text(text):
    """A scan note from the engine ("3 files in /var/log; skipped while running: …"), translated part by part."""
    if not text:
        return text or ""
    whole = item_text(text)
    if whole != text:
        return whole
    return "; ".join(_note_part(p) for p in text.split("; "))


def _details():
    """The engine's fixed phrases on a details line or a part's label: (pattern, replacement). Each is anchored
    to where the engine writes it (the end of the line, or right after a version), so a file name that happens
    to contain the same words is left alone."""
    return [
        (r"\((\d+) days old\)$", lambda m: "(" + _("{days} days old").format(days=m[1]) + ")"),
        (r" · (\d+) days old$", lambda m: " · " + _("{days} days old").format(days=m[1])),
        (r"\(untouched for (\d+) days\)$", lambda m: "(" + _("untouched for {days} days").format(days=m[1]) + ")"),
        (r" · untouched for (\d+) days$", lambda m: " · " + _("untouched for {days} days").format(days=m[1])),
        (r" · (\d+) days idle$", lambda m: " · " + _("{days} days idle").format(days=m[1])),
        (r"  \(running, skipped\)$", lambda m: "  " + _("(running, skipped)")),
        (r"^(\s*\S+  )← running \(kept\)$", lambda m: m[1] + _("← running (kept)")),
        (r"^(\s*\S+  )← kept as a fallback$", lambda m: m[1] + _("← kept as a fallback")),
        (r"^(\s*\S+  )← will be removed: ", lambda m: m[1] + _("← will be removed: ")),
        (r" \(revision (\w+)\)$", lambda m: " " + _("(revision {revision})").format(revision=m[1])),
        (r"^(\s*)Largest archived journal files:$", lambda m: m[1] + _("Largest archived journal files:")),
        (r"^(\s*)Archived and active journals take up (\S+) in the file system\.$",
         lambda m: m[1] + _("Archived and active journals take up {size} in the file system.").format(size=m[2])),
        (r"  \((\d+ \w+(?: \w+)?)\)$", lambda m: "  (" + COUNT.sub(_count, m[1]) + ")"),
    ]


def detail_text(line):
    """A line of an item's details or a part's label, with the engine's fixed phrases translated."""
    if not line or not translating():
        return line or ""
    for pattern, repl in _details():
        line = re.sub(pattern, repl, line, count=1)
    return line


def translating():
    """True when a catalog other than English is loaded."""
    return type(_t) is not gettext.NullTranslations


def untranslated(text):
    """True when the loaded catalog has no translation for this engine text."""
    return bool(text) and translating() and _lookup(text) is None
