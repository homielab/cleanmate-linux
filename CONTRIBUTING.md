# Contributing to CleanMate

Thanks for helping! This page explains how the project fits together, how to add something new
to clean, and how to check your change. Questions: open an
[issue](https://github.com/homielab/cleanmate-linux/issues) or write to contact@homielab.com.

## How it fits together

```
cleanmate.sh                the engine + terminal app (one Bash script, the source of truth)
gui/                        the desktop app (Python, GTK 4 + libadwaita) — talks to the engine
po/                         translations of the desktop app (gettext)
data/                       launcher, AppStream metainfo, icon
packaging/                  .deb build script, polkit policy, Flathub manifest (flathub/)
snap/                       Snap Store draft
tests/                      test suite (run.sh) and the terminal-UI smoke test
docs/                       screenshots, roadmap, publishing guide
```

- **One engine.** Everything that scans or deletes lives in `cleanmate.sh`. The desktop app
  never decides what to delete: it runs `cleanmate.sh --json …` and reads one JSON event per
  line (`items`, `scan`, `details ID`, `clean ID…`). Both apps share the same rules, tests and
  remembered selections.
- **The registry.** Every cleanable thing is an *item*: `reg ID CATEGORY "Label" DEFAULT "Description"`
  plus three functions — `scan_ID` (how much is there?), `clean_ID` (remove it) and, optionally,
  `details_ID` (what exactly?). Scans run in parallel: an item gets its own process, except the
  light ones (`ITEM_LIGHT`), which share a few.
- **Privileges.** Items that need root are listed in `ITEM_ROOT`. The terminal app uses `sudo`;
  the desktop app uses `pkexec`, and the engine refuses non-system items when it runs as root.
  pkexec runs only a root-owned engine (`/usr/bin/cleanmate` from the package; `root_owned` in
  `gui/cleanmate_gui/engine.py`), never a copy in a home folder, with `--polkit=ACTION` first so
  polkit shows the action of the page: `clean-system`, `uninstall-apps` or `maintenance`
  (`packaging/polkit/com.homielab.CleanMate.policy`; the engine refuses an action that doesn't
  match its command). A new root command needs an action there and in `POLKIT_ACTIONS`.

## Adding something to clean

```bash
reg my_cache user "My app cache" 1 "What it is, and why it's safe to remove."
why my_cache regenerated "~/.cache/my-app"   # effect, where it is, then when it is skipped (optional)
scan_my_cache()    { dev_scan "~/.cache/my-app" "$HOME/.cache/my-app"; }  # sets SCAN_BYTES/SCAN_NOTE
clean_my_cache()   { empty_dir "$HOME/.cache/my-app"; }                    # removes it
details_my_cache() { detail_paths "$HOME/.cache/my-app"; }                 # optional
```

Every item needs a `why` (`tests/run.sh every_item_explains` fails without one): the desktop app's
ⓘ *Why is this safe?* popover and `cm --json scan` (`why`) show it. The effect is `regenerated`
(deleted, its app or tool rebuilds it), `trash` or `delete` (deleted for good). Where it is: one line
per path (`~/…` or `/…`), `@NAME` for a function, array or variable that lists the paths, or a
sentence when there is no fixed path. Skipped-when lines can name a setting as `%CACHE_DAYS%`; the
general ones (Never clean, open files, password, automatic cleaning) are added for you. Extra lines go
in `ITEM_AFTER[ID]` (what cleaning does) and `ITEM_RUNNING[ID]` (the programs, `|`-separated, its
`lockedby_ID` checks). An item whose home folders are all in *Settings › Never clean* is skipped. Then
run `po/extract-items.sh` (Translations below).

`scan_*` returns 0 when there's something to clean, 2 when it's clean, 1 when it doesn't apply
(the app isn't installed). For a whole family of folders, look at `reg_cache_item` (browsers,
apps), `reg_list_item` (AI tools; `LIST_CAT=dev reg_list_item …` for another group), `reg_model_item` (one item per downloaded AI model),
`reg_folders_item` (one ticked row per cache folder, emptied: game launchers, Steam, Minecraft) and
`reg_privacy_item` (histories) — they generate the three
functions for you.

A `scan_ID` that only looks at folders in your home (`test`, `du`, `dev_scan`) and runs no program
that could hang (a package manager, `docker`, a tool's own CLI) or a walk over the whole home can go
in `ITEM_LIGHT`: a scan then runs it in a shared process, which costs less than one of its own.
`reg_cache_item`, `reg_list_item` and `reg_folders_item` items are light already. A light scan must not `cd`, `exit` or
leave variables behind that the next item reads; globals it fills carry its own prefix (`IV_`, `GR_`…).

`cm --scan` ends with the three slowest items (`cm --json scan`: each item's `durationMs`): check that
a new item isn't one of them.

Each `$(…)` starts a process (about half a millisecond). Code that runs on every start (item
registration) or in a scan uses the helpers that set a variable instead of printing:
`env_valuev`, `env_home_dirv`, `runtime_dirv`, `du_sumv`, `open_filesv`, `pluralv`, `humanv` —
`env_valuev v NAME`, not `v=$(env_value NAME)`.

Rules of thumb:

- **Delete only through the helpers** — `run`, `run_root`, `empty_dir`, `move_to_trash` — so
  `--dry-run`, the protected-path checks and the activity log keep working.
- **Prefer the tool's own cleanup command** (`npm cache clean`, `docker image prune`, …).
- **Be conservative.** Personal data starts unselected; anything a running app might use gets a
  `precheck_ID`, plus a `lockedby_ID` that prints the running program, so a scan can show the
  item locked (`reg_cache_item` and `reg_list_item` make both from their process pattern); history
  items only remove things older than a limit.
- **Add a test** that creates the files your item should remove *and* the ones it must keep.
- A folder in `~/.config`, `~/.local/share`, `~/.local/state` or `~/.cache` that the Uninstaller
  lists under *Leftovers of removed apps* although it isn't one (the desktop's own, shared by many
  apps, or one your new item cleans): add its name to `ORPHAN_SHARED` in `cleanmate.sh` and a case
  to `test_leftovers_of_removed_apps`.

## Checking your change

Each test gets its own `WORK` folder and fake home, so tests run in parallel: don't change the shared
stubs (`$STUBS`) in a test — put a stub in `$WORK/<dir>` and prefix `BASE_PATH`. Never wait with a fixed
`sleep`: `wait_for SECONDS "what" CMD…` polls CMD and fails with "timed out waiting for what"
(`holds_open PID FILE`, `runs_exe PID EXE`, `port_open PORT`, `not_running PID`). A test that measures how
fast the app answers goes in `ALONE` at the end of `tests/run.sh`.

```bash
tests/run.sh               # all tests, in parallel (one per CPU) — safe on your own machine
tests/run.sh -j 1          # one after another, e.g. to read a failing test's details in order
tests/run.sh -v docker     # only tests with "docker" in the name, with details ('docker|snap': either)
python3 tests/similar_test.py   # Similar Photos: hashes and grouping on generated photos (needs python3-gi)
python3 tests/preview_test.py   # thumbnails and video frames of the file pages (python3-gi; videos also gir1.2-gstreamer-1.0)
python3 tests/messages_test.py  # every code the engine sends has a text in the desktop app, in Vietnamese too
LC_ALL=vi_VN.UTF-8 tests/run.sh   # same, in a language with a decimal comma (also de_DE.UTF-8; needs `sudo locale-gen vi_VN.UTF-8`). CI runs both on the tests that format or sort numbers and texts
shellcheck -S warning -x cleanmate.sh tests/run.sh tests/bench-*.sh packaging/*.sh packaging/flathub/build.sh po/*.sh   # CI pins ShellCheck 0.11.0
python3 -m py_compile gui/cleanmate-gui $(find gui tests -name '*.py')
bash cleanmate.sh --dry-run   # try it for real without deleting anything
```

The tests use a throwaway home folder, stub out `sudo`, `pgrep` and `docker`, and fail if your real
`~/.config` or `~/.local/state` folders change. The terminal-UI test needs `pip install pyte`; the
desktop-app test needs `gtk4-broadwayd` (package `libgtk-4-bin`) and runs on an invisible display;
the browser-privacy test needs `sqlite3`; the test of sizes in a language with a decimal comma needs
such a locale (`sudo locale-gen vi_VN.UTF-8`).
They also pass as root (for example in a container): the engine refuses home items as root, so those
cleanups run as `nobody` through `setpriv`.

`tests/bench-projects.sh [PROJECTS [FILES [ROUNDS]]]` times a Smart Scan on a throwaway home with 50
idle projects (node_modules of 2000 files each, some with `target/`, `.venv/`, `Pods/`): the first
scan and a repeat scan, both the whole `--json scan` and the three items that measure projects alone.
Run it in a container limited to the CPUs you want to compare
(`docker run --cpuset-cpus 0-3 … bash tests/bench-projects.sh`); `CLEANMATE_SCRIPT=old.sh` times
another copy. A whole scan waits for its slowest item, so compare medians.
`tests/bench-scan.sh [ROUNDS [SLOWEST]]` times a whole Smart Scan of the machine it runs on (a throwaway
home, the real system): the first scan with nothing cached and a repeat scan, then the slowest items
on their own, and checks the unused packages against `apt-get -s autoremove`. Run it as an ordinary
user on a machine with many packages; `CLEANMATE_SCRIPT=old.sh` times another copy.
With `BENCH_LIMITS=tests/bench-limits.sh` it fails when a median is over the limits there; the
Benchmark workflow (`.github/workflows/bench.yml`) runs it that way weekly and on demand.
`tests/bench-dupes.sh [COUNT [ROUNDS [SIZE_BYTES]]]` times Duplicates on a throwaway folder of 20,000
files of one size (300 KB; sparse, so little disk), every one read: a tenth are copies, the rest differ
at the start or only at the end. It prints the median and a checksum of the groups found, which must
be the same for both copies you compare (`CLEANMATE_SCRIPT=old.sh`, CPUs limited as above).
CI runs everything on Ubuntu 22.04 and 24.04 for every pull request.

The PPA gets one source package per Ubuntu release, listed in `SERIES` at the top of
`.github/workflows/ppa.yml` (only releases Launchpad still builds for; the workflow fails on a closed
one and points out a new one). `packaging/build-source.sh -us -uc` builds them unsigned in
`dist/ppa/` (`SERIES=noble` for one), each versioned `<debian/changelog version>~<series>`; never write a series
name into `debian/changelog` by hand.

## Desktop app

```bash
bash cleanmate.sh --gui --dry-run     # run it from your clone
```

Pages live in `gui/cleanmate_gui/scanpage.py` (cleanup), `spacelens.py` (Space Lens), `largefiles.py`
(Large & Old Files), `duplicates.py`, `uninstaller.py` and `startup.py`; the window and sidebar in `window.py`, the engine wrapper in `engine.py`. Keep all
deletion logic in the engine: pages only call `--json` commands (see the protocol in `docs/ROADMAP.md`).
`CLEANMATE_APP_DIRS` (colon-separated) replaces the launcher folders the app list reads, and
`CLEANMATE_SYSTEM_AUTOSTART` the system's autostart folder (`/etc/xdg/autostart`), for tests.
`CLEANMATE_VOLUME_ROOTS` (colon-separated) replaces where drives are mounted (`/media/$USER`,
`/run/media/$USER`, `/mnt`); every folder in it counts as a drive with its own Trash, for tests.
`CLEANMATE_SYSROOT` makes System protection read `/etc`, `/sys`, `/run` and `/usr/bin` under another folder
(systemctl and mokutil still come from `PATH`), for tests.
`CLEANMATE_PROC` replaces `/proc` where the Uninstaller looks for running snaps, apt and AppImage apps, for tests.

### Screenshots

`packaging/make-screenshots.sh` regenerates `docs/screenshots/` from a throwaway demo home (no
personal data) on an invisible display, so it needs no screen. Run it as a normal user, not root.
In a container:

```bash
docker run --rm -v "$PWD":/src:ro -v "$PWD/docs/screenshots":/out ubuntu:24.04 bash -c '
  apt-get update && apt-get install -y python3-gi python3-pyte python3-pil gir1.2-gtk-4.0 \
    gir1.2-adw-1 libgtk-4-bin fonts-ubuntu fonts-noto-color-emoji
  cp -r /src /w && useradd -m u && chown -R u /w
  su u -c "OUT=/tmp/shots bash /w/packaging/make-screenshots.sh" && cp /tmp/shots/*.png /out/'
```

A new screenshot scene goes in `run_scene` / `tool_scene` (`gui/cleanmate_gui/selftest.py`) and in
the script's scene list; README and `data/*.metainfo.xml` link the images.

## Translations

The desktop app is translated with gettext (domain `cleanmate`, files in `po/`); the engine and the
terminal app are English only. The desktop app translates the names and descriptions of cleanup items
the engine sends (`item_text` in `gui/cleanmate_gui/i18n.py`): `po/extract-items.sh` takes them from
`--json items` into `po/items.pot`, numbers as `{0}`, `{1}`… so a description matches whatever number
of days or MB the settings give. Texts the engine makes at scan time — apps found on the computer,
scan notes ("3 files in /var/log"), the lines of an item's details — go through pattern tables in
`i18n.py` (`item_text`, `note_text`, `detail_text`; counted nouns in `_COUNTS`). A new note or
counted noun in `cleanmate.sh` needs a pattern there, or it shows in English; add a case to
`tests/run.sh gui_scan_texts_translated`.

Errors, task results and background notifications (low disk, scan reminder, automatic cleaning)
carry a stable `code` and its `args` next to the English text (`json_code` in `cleanmate.sh`); the
desktop app turns the code into its language in `gui/cleanmate_gui/messages.py`, and `notify` gets
the text from `python3 -m cleanmate_gui.messages notify CODE [KEY VALUE]…`. A new code needs a text
there and in `po/vi.po`: `tests/run.sh engine_messages` (`tests/messages_test.py`) reads every code
from `cleanmate.sh` and fails on one without. A code set from a variable gets a `# codes: a b` note
on its line, so the test finds it.

The password dialog's texts are in `packaging/polkit/com.homielab.CleanMate.policy`: each
action's `<description>` and `<message>` once per language, with `xml:lang` (`tests/run.sh polkit`
checks the Vietnamese ones).

- In code, wrap text in `_("…")`, and counts in `ngettext("{n} file", "{n} files", n)` (it fills in
  `{n}` and any other `{field}=` you pass). Put values in `{named}` fields, never glue sentences together.
- After changing text, update the template and the translations:
  ```bash
  xgettext -L Python -k_ -kngettext:1,2 --from-code=UTF-8 -o po/cleanmate.pot \
    $(ls gui/cleanmate_gui/*.py | grep -v selftest)
  po/extract-items.sh   # item names and descriptions (bash 4+, so on Linux): po/items.pot → po/cleanmate.pot
  msgmerge -U --backup=none po/vi.po po/cleanmate.pot
  ```
- New language: `msginit -i po/cleanmate.pot -l <lang> -o po/<lang>.po`, translate, done — packaging
  compiles every `po/*.po`.
- The app follows the system's language unless Settings › Language saved `language=en|vi` in
  `~/.config/cleanmate/settings` (`chosen_language` in `i18n.py`); a new language also goes in
  `LANGUAGES` there, `LANGUAGE_TITLES` in `settings.py` and `SETTING_CHOICES` in `cleanmate.sh`.
- Check: `msgfmt --check po/vi.po`, then `po/compile.sh gui/locale` and
  `LANG=vi_VN.UTF-8 bash cleanmate.sh --gui --dry-run`. `tests/run.sh gui_selftest` runs the self-test
  in English and Vietnamese; `tests/run.sh -v gui_selftest` lists item texts without a translation
  (`SELFTEST warn untranslated item …`) and fails on any `Gtk-WARNING` or `Pango-WARNING`.
- Rows show text, not markup: build an `Adw.*Row` with `plain_row(Adw.ActionRow, title=…, subtitle=…)`
  (`rows.py`), and pass a status page's or group's description through `GLib.markup_escape_text`.
- Vietnamese uses the macOS app's terms: Dọn dẹp, Thùng rác, Rác developer, Quét thông minh.

## Releasing

Bump `VERSION` in `cleanmate.sh` and `snap/snapcraft.yaml`, update
`CHANGELOG.md` and the metainfo release notes, merge to `main`, push a `vX.Y.Z` tag — CI tests,
builds the `.deb` and creates the GitHub release with the `.deb` and the snap.
Once CleanMate is on Flathub, the Flathub bot opens a pull request in `flathub/com.homielab.CleanMate`
for the new tag; copy its `tag` and `commit` into `packaging/flathub/com.homielab.CleanMate.yml`
([packaging/flathub/README.md](packaging/flathub/README.md)).