"""Every code the engine sends has a text in the desktop app, and that text is in Vietnamese
(gui/cleanmate_gui/messages.py, po/vi.po).

The codes are read from cleanmate.sh: the literal code of each `json_error`, `json_task`,
`json_file_task`, `json_startup_task`, `json_step` and `notify` call, each `code=` / `*_CODE=`
assignment, and the `# codes: …` note on a line that sends a code from a variable.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "gui"))
os.environ["CLEANMATE_LOCALEDIR"] = os.path.join(ROOT, "no-locale")  # the English texts, whatever the system's
from cleanmate_gui import messages  # noqa: E402

CALL = re.compile(r"\b(?:json_task|json_file_task|json_startup_task|json_step)\s+\S+\s+(?:ok|fail|skip)\s+([a-z][a-z_]*)\b")
PATTERNS = (
    re.compile(r"\bjson_error\s+([a-z][a-z_]*)\b"),
    CALL,
    re.compile(r"^\s*notify\s+([a-z][a-z_]*)\s"),  # a call starts the line (the --help text says "notify when")
    re.compile(r'(?:^|[\s;{(])(?:code|[A-Z]+_CODE(?:\[[^]]*\])?)="?([a-z][a-z_]*)\b'),
)
NOT_CODES = {"ok", "fail", "skip", "run"}


def engine_codes():
    """{code: first line number} of every code cleanmate.sh sends."""
    found = {}
    with open(os.path.join(ROOT, "cleanmate.sh"), encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            code_part, _hash, note = line.partition(" # ")
            if code_part.lstrip().startswith("#"):
                continue
            for pattern in PATTERNS:
                for code in pattern.findall(code_part):
                    found.setdefault(code, n)
            if note.startswith("codes:"):
                for code in note[len("codes:"):].split():
                    found.setdefault(code, n)
    return {c: n for c, n in found.items() if c not in NOT_CODES}


def po_entries(path):
    """msgid → msgstr (msgid_plural keeps its first form's msgid); fuzzy entries count as untranslated."""
    entries, cur, field, fuzzy = {}, {}, None, False

    def flush():
        if "msgid" in cur and cur["msgid"]:
            entries[cur["msgid"]] = "" if fuzzy else cur.get("msgstr", cur.get("msgstr[0]", ""))

    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                flush()
                cur, field, fuzzy = {}, None, False
            elif line.startswith("#,") and "fuzzy" in line:
                fuzzy = True
            elif line.startswith("#"):
                continue
            elif line.startswith('"'):
                cur[field] += _unquote(line)
            else:
                field, _sp, rest = line.partition(" ")
                cur[field] = _unquote(rest)
    flush()
    return entries


def _unquote(s):
    return s[1:-1].replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def asked_texts():
    """Every English text messages.py asks gettext for (messages, notifications, values)."""
    asked = []
    real_, real_n = messages._, messages.ngettext
    messages._ = lambda s: asked.append(s) or s
    messages.ngettext = lambda s, p, n, **kw: asked.append(s) or s
    try:
        messages.texts(), messages.maint_missing(), messages._values()
        for code in messages.NOTIFICATIONS:
            messages.notification(code, SAMPLE_ARGS[code])
        messages.text({"code": "trimmed", "args": {"n": "2"}})
    finally:
        messages._, messages.ngettext = real_, real_n
    return asked


SAMPLE_ARGS = {
    "low_disk": {"bytes": "1073741824", "pct": "4"},
    "remind": {"days": "9"},
    "remind_first": {},
    "auto_clean": {"freed": "2147483648", "item1": "524288000 Thumbnail cache"},
}


class EngineCodes(unittest.TestCase):
    def test_codes_are_found(self):
        codes = engine_codes()
        for code in ("usage", "freed", "trashed", "turned_off", "outside_home", "schedule_on", "apt_refused",
                     "ram_freed", "low_disk", "auto_clean", "would_run", "step_failed"):
            self.assertIn(code, codes)

    def test_every_engine_code_has_a_text(self):
        missing = {c: n for c, n in engine_codes().items() if not messages.known(c)}
        self.assertEqual(missing, {}, "codes cleanmate.sh sends (code: line) without a text in messages.py")

    def test_no_text_for_a_code_the_engine_never_sends(self):
        codes = engine_codes()
        gui_only = {"engine_failed"}  # the app's own: the engine didn't start
        unused = sorted(c for c in list(messages.texts()) + list(messages.NOTIFICATIONS)
                        if c not in codes and c not in gui_only)
        self.assertEqual(unused, [], "texts in messages.py for codes cleanmate.sh doesn't send")

    def test_every_code_gives_text(self):
        args = {"id": "x", "path": "/home/u/a", "key": "k", "min": "1", "max": "9", "app": "apt:x", "detail": "d",
                "packages": "libc6", "program": "firefox", "bytes": "1024", "before": "1", "after": "2", "n": "3",
                "value": "daily"}
        for code in messages.texts():
            out = messages.text({"code": code, "args": args, "info": "ENGLISH"})
            self.assertTrue(out and out != "ENGLISH" and "{" not in out, f"{code}: {out!r}")
        for code in messages.NOTIFICATIONS:
            title, body = messages.notification(code, SAMPLE_ARGS[code])
            self.assertTrue(title and body and "{" not in title + body, code)

    def test_unknown_code_keeps_english(self):
        self.assertEqual(messages.text({"code": "no_such_code", "info": "as sent"}), "as sent")
        self.assertEqual(messages.text({"message": "no code"}), "no code")

    def test_every_text_is_in_vietnamese(self):
        vi = po_entries(os.path.join(ROOT, "po", "vi.po"))
        untranslated = sorted({s for s in asked_texts() if not vi.get(s)})
        self.assertEqual(untranslated, [], "texts of messages.py without a Vietnamese translation in po/vi.po")

    def test_notification_command(self):
        """The engine's `notify` asks `python3 -m cleanmate_gui.messages`; in Vietnamese when the catalog is built."""
        env = dict(os.environ, PYTHONPATH=os.path.join(ROOT, "gui"), LANGUAGE="vi", LC_ALL="C.UTF-8")
        env.pop("XDG_CONFIG_HOME", None)
        work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, work)
        env["XDG_CONFIG_HOME"] = work  # no saved language
        compiled = bool(shutil.which("msgfmt"))
        if compiled:
            subprocess.run(["bash", os.path.join(ROOT, "po", "compile.sh"), os.path.join(work, "locale")], check=True)
            env["CLEANMATE_LOCALEDIR"] = os.path.join(work, "locale")
        out = subprocess.run([sys.executable, "-m", "cleanmate_gui.messages", "notify", "low_disk",
                              "bytes", "1073741824", "pct", "4"], env=env, capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        title, _nl, body = out.stdout.partition("\n")
        self.assertIn("1.0 GB", body)
        if compiled:
            self.assertNotEqual(title, "Disk almost full")
        bad = subprocess.run([sys.executable, "-m", "cleanmate_gui.messages", "notify", "nope"], env=env,
                             capture_output=True, text=True)
        self.assertEqual(bad.returncode, 1)


if __name__ == "__main__":
    unittest.main()
