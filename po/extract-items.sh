#!/usr/bin/env bash
# The cleanup items' names, descriptions and "Why is this safe?" lines (every `reg` and `why` of
# cleanmate.sh, as `--json items` lists them with default settings) → po/items.pot, then merged into po/cleanmate.pot. Run it after
# xgettext (CONTRIBUTING.md › Translations). Numbers become {0}, {1}… like the desktop app's
# lookup (gui/cleanmate_gui/i18n.py), so "older than 30 days" is translated for any number of days.
# Needs bash 4+, python3 and msgcat (gettext).
set -euo pipefail
cd "$(dirname "$0")/.."
home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
env -i HOME="$home" PATH=/usr/bin:/bin LANG=C.UTF-8 CLEANMATE_NO_UPDATE_CHECK=1 bash cleanmate.sh --json items |
  python3 -c '
import json, re, sys
number = re.compile(r"\b\d+\b")
order, where = [], {}
for line in sys.stdin:
    e = json.loads(line)
    if e.get("event") != "item":
        continue
    why = e.get("why") or {}
    texts = [(e["label"], "label"), (e["description"], "description")]
    texts += [(t, "why") for k in ("where_note", "after", "skipped") for t in why.get(k, [])]
    texts += [(t, "why") for t in why.get("running", []) if " " in t]  # "the emulator", not process names
    for text, field in texts:
        if not text:
            continue
        brace = False
        if "{" not in text and "}" not in text and number.search(text):
            n = iter(range(99))
            text, brace = number.sub(lambda _m: "{%d}" % next(n), text), True
        if text not in where:
            order.append(text)
            where[text] = [brace]
        if len(where[text]) < 7:  # a line many items share names a few of them
            where[text].append(e["id"] + " " + field)
q = lambda s: "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
print("# Cleanup item names, descriptions and why lines from cleanmate.sh (po/extract-items.sh).")
print("msgid \"\"\nmsgstr \"\"\n\"Content-Type: text/plain; charset=UTF-8\\n\"\n")
for text in order:
    brace, *ids = where[text]
    print("#. " + ", ".join(ids))
    if brace:
        print("#, python-brace-format")
    print("msgid " + q(text) + "\nmsgstr \"\"\n")
' >po/items.pot
msgcat --use-first -o po/cleanmate.pot po/cleanmate.pot po/items.pot
echo "po/items.pot: $(grep -c '^msgid "[^"]' po/items.pot) strings, merged into po/cleanmate.pot"
