---
name: cleanmate
description: Free up disk space on Ubuntu/Linux with CleanMate (`cm`). Use when the user asks to clean up, free disk space, find what is taking up space, remove caches, logs, old snaps, Docker leftovers or developer junk on a Linux machine, or to get back files CleanMate moved to the Trash. Scans first, shows what it found by group, and deletes only what the user confirms.
---

# CleanMate for Linux

CleanMate (`cm`) is a command-line cleaner. This skill drives its headless mode. Output is JSON, one object per line.

## Rules

1. Never install anything yourself. If `cm` is missing, look for `cleanmate.sh`; if both are missing, tell the user how to install (see below) and stop.
2. Always scan first. Never run a clean you have not shown to the user.
3. Clean only after the user confirms the exact items (or groups). Pass them with `--only` or as item IDs.
4. Never include the `privacy` group (browser history, cookies) unless the user named it.
5. Do not clean `locked` items (the app is running); tell the user to close it and rescan.
6. Items with `"data_loss":true` (Docker volumes, stopped containers) are deleted for good and may hold the user's data (databases, files written inside a container). Clean one only when the user names that item after seeing the list, as its own `cm --json clean ID`; never fold it into a group clean, never pick it just because it is `selected`. `cm --clean --yes` always skips them.
7. Items with `"root":true` need root: CleanMate asks for `sudo` or `pkexec`. Say so before cleaning them. Never run `cm` itself as root.
8. Never move or delete user files by hand — no `rm`. When the user confirmed exact paths after seeing a list, move them with `cm --json trash PATH…`: it refuses paths outside the home folder or excluded in *Never clean* and says why; read that reason to the user instead of working around it. Report every `restore` key it returns and how to put things back (`cm --json restore KEY…`).
9. When unsure, run the command with `--dry-run` first.
10. After cleaning, report freed space, what went to the Trash (undoable) and what was skipped or failed.

## Find it

```bash
command -v cm || ls ~/.local/bin/cm ./cleanmate.sh
```

Not installed: Ubuntu 24.04 or newer `sudo add-apt-repository ppa:homielab/cleanmate && sudo apt install cleanmate`; any Ubuntu without sudo: `curl -fsSLO https://raw.githubusercontent.com/homielab/cleanmate-linux/main/cleanmate.sh && bash cleanmate.sh --install`.

## Scan

```bash
cm --json scan                    # default groups (no privacy)
cm --json scan --only logs,dev    # selected groups
```

Groups: `system, logs, user, browser, apps, ai, models, dev, privacy`. Each `"event":"item"` line has `id`, `category`, `label`, `description`, `bytes`, `status` (`found`, `clean`, `timeout`), `note`, `selected` (pre-selected by CleanMate), `locked` (empty, or the program that is running), `root`, `trash` (goes to the Trash, undoable; otherwise deleted for good), `data_loss` (may hold the user's data, see rule 6), `durationMs` (how long its scan took), `why` (why it is safe: `effect` `regenerated`/`trash`/`delete`, `where`, `after`, `skipped`, `running`; read it to the user when they ask what an item is or what they would lose). The last line is `{"event":"done","total_bytes":…,"durationMs":…}`.

Show the user items with `status":"found"` and `bytes` > 0 grouped by `category`, with sizes (human readable), marking locked, root, delete-for-good and `data_loss` items. Suggest the `selected` ones, except `data_loss` items. `cm --json items` lists every item without scanning; `cm --json details ID` explains one item.

## Clean

```bash
cm --json --dry-run clean ID [ID…]   # preview, deletes nothing
cm --json clean ID [ID…]             # after the user confirmed
cm --clean --yes --only logs,user    # whole groups, plain text output
```

`cm --clean --yes` cleans what is ticked in the user's saved choices but always skips `data_loss` items, printing `… skipped: may hold data — run cm --json clean ID`.

`--json clean` streams `{"event":"task","id","state","info","freed"}` with state `run`, `ok`, `skip` (app running) or `fail`, then `{"event":"done","freed","to_trash","avail_before","avail_after","disks":[{"mount","before","after"}],"trash":{ID:[keys]}}`: `freed` includes `to_trash`, which only frees space once the Trash is emptied; `disks` gives the free space of `/` and, when it is another filesystem, of the home folder. Items in `trash` can be restored with `cm --json restore KEY…`.

Exit code: 0 ok, 1 error, 2 bad arguments (a JSON `error` event says why).

## What is taking up space

```bash
cm --json lens                          # home folder, biggest entries first (`kind`, `count`)
cm --json lens --path DIR               # drill into the biggest folder
cm --json large --days 90 --limit 50    # big files: `path`, `bytes`, `mtime`, `atime`, `kind`
cm --json dupes --limit 50              # groups of identical files, newest copy first
```

Start with `lens`; drill into the biggest sounding folder with `--path` until you can name what
fills the disk. `large --days N` lists files neither changed nor opened for N days. In `dupes`
every group is identical copies, newest first — the last file in a group is usually the original.
`done` tells you the totals, so shorter lists know how much is left out.

Trash only paths the user named or confirmed after seeing the list — never pick them yourself
(not even a duplicate set's "extra" copies). Space Lens paths go with `--home-only`:

```bash
cm --json --dry-run trash PATH…         # preview, nothing moves
cm --json trash [--home-only] PATH…     # after the user confirmed; task lines carry the restore key
cm --json restore KEY…                  # put it back
```

## Get something back later

When the user wants back something CleanMate moved to the Trash (also in an earlier session, or
from the app), list it, let the user pick, then restore only those:

```bash
cm --json restore --list [--limit N]    # newest first: trashed (the key), path, size, kind, date, source
cm --json restore KEY…                  # KEY = the "trashed" value of each item the user picked
```

Show date, size, original path and source (e.g. `Command Line`, `Large & Old Files`,
`Smart Scan › Old downloads`). Items the user trashed without CleanMate are not in the list: point
them to the Trash in Files.

## Beyond Smart Scan

Startup items, app uninstall, app reset, maintenance and the System Overview are in the terminal
app (`cm`) or the desktop app (`cm --gui`). Point the user there; do not delete files by hand.

More: [reference.md](reference.md).
