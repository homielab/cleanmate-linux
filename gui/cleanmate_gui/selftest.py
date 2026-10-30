"""`--selftest`: drive the real window like a user would, print results, quit.

Used by tests/run.sh on a virtual display. Only cleans in dry-run mode and
never touches system items (so no password prompt can appear). The Large & Old
Files, Space Lens, Duplicates and Startup Items checks move files to the Trash for real, and the Settings
check saves settings for real, and the Docker check removes an image through a fake `docker`, but only in a
throwaway home folder they made, with the engine pointed at it.
"""
import os
import shutil
import tempfile
import time

from gi.repository import Adw, GLib

from . import i18n
from .i18n import _, ngettext


def lead(text, plural=None):
    """The fixed start of a translated message, before its first {field}."""
    return (i18n._t.ngettext(text, plural, 2) if plural else text).split("{")[0]


def screenshot(win, path, then=None, tries=15):
    """Render the window to a PNG (works on any backend, including broadway).

    Right after a page switch the window may not have drawn yet; retry briefly.
    """
    from gi.repository import Gtk
    paintable = Gtk.WidgetPaintable.new(win)
    snap = Gtk.Snapshot()
    paintable.snapshot(snap, win.get_width(), win.get_height())
    node = snap.to_node()
    if node is None:
        if tries > 0:
            GLib.timeout_add(200, lambda: (screenshot(win, path, then, tries - 1), False)[1])
        else:
            print(f"SELFTEST FAIL nothing drawn for {path}", flush=True)
            then and then()
        return
    win.get_native().get_renderer().render_texture(node, None).save_to_png(path)
    print(f"SELFTEST ok   screenshot saved: {path}", flush=True)
    then and then()


def run(app, win):
    page = win.pages["smart"]
    win.selection.remember = lambda *_: None  # never change the user's remembered choices
    if app.screenshot:  # headless displays may not animate: no transitions or fade-ins
        from gi.repository import Gtk
        Gtk.Settings.get_default().set_property("gtk-enable-animations", False)
        page.stack.set_transition_type(Gtk.StackTransitionType.NONE)
        win.content_stack.set_transition_type(Gtk.StackTransitionType.NONE)

    def report(ok, msg):
        print(f"SELFTEST {'ok  ' if ok else 'FAIL'} {msg}", flush=True)
        if not ok:
            app.selftest_failed = True

    def wait(cond, then, timeout=60.0, what="condition"):
        deadline = GLib.get_monotonic_time() + int(timeout * 1e6)

        def tick():
            if cond():
                then()
                return False
            if GLib.get_monotonic_time() > deadline:
                report(False, f"timed out waiting for {what}")
                finish()
                return False
            return True
        GLib.timeout_add(100, tick)

    def finish():
        print("SELFTEST done", flush=True)
        app.quit()

    def after_scan():
        found = [e for e in page.items.values() if e["status"] == "found"]
        report(page.stack.get_visible_child_name() == "results", "results page shown")
        report(len(page.items) > 0, f"{len(page.items)} items scanned, {len(found)} with junk")
        report(page.bar.get_revealed() == bool(found), "action bar matches the results")
        if app.screenshot:
            GLib.timeout_add(1500, lambda: (screenshot(win, app.screenshot, finish), False)[1])
            return
        if not found:
            return large_files_test(win, report, wait, finish)
        first = sorted(found, key=lambda e: (bool(e.get("locked")), -e["bytes"]))[0]  # a row that can be ticked
        before = page.summary.get_text()
        page.checks[first["id"]].set_active(not page.selected[first["id"]])
        report(page.summary.get_text() != before, f"toggling “{first['label']}” updates the summary")
        page.checks[first["id"]].set_active(not page.checks[first["id"]].get_active())  # restore
        check_group(first)
        check_locked(found)
        page.show_details(first)
        GLib.timeout_add(1500, lambda: (after_details(), False)[1])

    def check_group(first):
        groups = sorted(page.group_buttons, key=lambda g: -len(g[1]))
        if not groups:
            return report(True, "no group with several items to check")
        button, ids = groups[0]
        report(len(ids) >= 3, f"group of {len(ids)} items under test")
        for i in ids:
            page.checks[i].set_active(False)
        report(not button.get_active() and not button.get_inconsistent(), "group box: none")
        page.checks[ids[0]].set_active(True)
        report(button.get_inconsistent(), "group box: some (inconsistent)")
        for i in ids:
            page.checks[i].set_active(False)
        button.set_active(True)  # from none: every item must end up ticked
        report(all(page.selected[i] for i in ids) and button.get_active() and not button.get_inconsistent(),
               "group box selects the whole group")
        button.set_active(False)  # from all
        report(not any(page.selected[i] for i in ids), "group box clears the whole group")
        row = page.checks[ids[0]].get_ancestor(Adw.ActionRow)
        row.activate()
        report(page.selected[ids[0]], "activating the row (click, Space, Enter) toggles its box")
        page.checks[ids[0]].set_active(False)

    def check_locked(found):
        locked = [e for e in found if e.get("locked")]
        if not locked:
            return report(True, "no locked item to check")
        e = locked[0]
        check = page.checks[e["id"]]
        report(not check.get_sensitive() and not page.selected[e["id"]],
               f"locked row “{e['label']}” can't be ticked ({e['locked']} running)")
        check.get_ancestor(Adw.ActionRow).activate()
        report(not page.selected[e["id"]], "activating a locked row leaves it unticked")
        before = dict(page.selected)
        for button, _ids in page.group_buttons:
            button.set_active(True)
        report(not any(page.selected[x["id"]] for x in locked), "group boxes leave locked rows unticked")
        for i, on in before.items():  # restore
            page.checks[i].set_active(on)

    def after_details():
        user_items = [e for e in page.items.values()
                      if e["status"] == "found" and not e["root"] and not e.get("locked")]
        if not (win.engine.dry_run and user_items):
            report(True, "clean skipped (not a dry run, or nothing to clean)")
            return large_files_test(win, report, wait, finish)
        target = user_items[0]["id"]
        for i in list(page.selected):
            page.selected[i] = i == target
        page.clean([target])
        wait(lambda: page.clean_title.get_text().startswith(lead(_("Dry run: {size} would be freed"))), after_clean, 60, "dry-run clean")

    def after_clean():
        report(True, f"dry-run clean finished: {page.clean_title.get_text()}")
        large_files_test(win, report, wait, finish)

    if app.screenshot:
        return run_scene(app, win, app.scene, app.screenshot, report, wait, finish)
    page.scan()
    wait(lambda: page.running is None and page.stack.get_visible_child_name() != "scanning",
         after_scan, 120, "scan")


def large_files_test(win, report, wait, finish):
    """Search with filters, select, dry-run, then Trash and Undo in a throwaway home."""
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home = os.path.join(sandbox, "home")
    videos = os.path.join(home, "Videos")
    os.makedirs(videos)
    film, backup, note = (os.path.join(videos, n) for n in ("film.mkv", "old backup.iso", "note.txt"))
    for path, size in ((film, 120 << 20), (backup, 60 << 20), (note, 1024)):  # sparse: no real disk use
        with open(path, "wb") as f:
            f.truncate(size)
    then = time.time() - 200 * 86400
    os.utime(backup, (then, then))
    env = {"HOME": home, "XDG_DATA_HOME": os.path.join(home, ".local", "share")}

    win.show_page("large")
    page = win.pages["large"]
    real_engine = page.engine
    page.engine = Engine(real_engine.path, dry_run=True, env=env)
    page.set_folder(videos)
    page.size_drop.set_selected(0)  # 50 MB

    def idle():
        return page.running is None and page.stack.get_visible_child_name() != "searching"

    def names():
        return [os.path.basename(e["path"]) for e in page.files]

    def done():
        page.engine = real_engine
        shutil.rmtree(sandbox, ignore_errors=True)
        space_lens_test(win, report, wait, finish)

    def searched():
        report(names() == ["film.mkv", "old backup.iso"], f"large files biggest first, small one left out: {names()}")
        page.age_drop.set_selected(2)  # 90 days: changing a filter searches again
        wait(idle, aged, 60, "search by age")

    def aged():
        report(names() == ["old backup.iso"], "age filter keeps only the old file")
        page.age_drop.set_selected(0)
        wait(idle, selection, 60, "search again")

    def selection():
        before = page.summary.get_text()
        page.checks[film].set_active(True)
        report(page.summary.get_text() != before and page.all_check.get_inconsistent(),
               "ticking a file updates the summary; the All box shows some")
        page.all_check.set_active(True)
        report(page.selected == {film, backup} and not page.all_check.get_inconsistent(), "All box selects every file")
        page.all_check.set_active(False)
        report(not page.selected, "All box clears every file")
        page.checks[film].get_ancestor(Adw.ActionRow).activate()
        report(page.selected == {film}, "activating a file row toggles its box")
        page.trash([film])
        wait(lambda: page.running is None, dry_trashed, 60, "dry-run trash")

    def dry_trashed():
        report(os.path.exists(film) and film in [e["path"] for e in page.files], "dry run: the file stays")
        if os.geteuid() == 0:
            report(True, "Trash and Undo skipped: the engine refuses them as root")
            return done()
        page.engine = Engine(real_engine.path, dry_run=False, env=env)
        page.trash([film])
        wait(lambda: page.running is None, trashed, 60, "trash")

    def trashed():
        in_trash = os.path.join(home, ".local", "share", "Trash", "files", "film.mkv")
        report(not os.path.exists(film) and os.path.exists(in_trash) and names() == ["old backup.iso"],
               "Move to Trash moves the file and drops its row")
        if not page.undo_toast:
            report(False, "no Undo toast after moving to the Trash")
            return done()
        page.undo_toast.emit("button-clicked")
        wait(lambda: page.running is None and os.path.exists(film), undone, 60, "undo")

    def undone():
        report(os.path.exists(film) and names() == ["film.mkv", "old backup.iso"],
               "Undo from the toast puts the file back where it was")
        done()

    page.search()
    wait(idle, searched, 60, "large files search")


def space_lens_test(win, report, wait, finish):
    """List a throwaway home by size, go three folders deep and back, check that a folder outside
    home is view only, then move a folder to the Trash and undo it."""
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home = os.path.join(sandbox, "home")
    projects, videos = os.path.join(home, "Projects"), os.path.join(home, "Videos")
    app, build = os.path.join(projects, "App"), os.path.join(projects, "App", "Build")
    os.makedirs(build)
    os.makedirs(videos)
    for path, size in ((os.path.join(build, "out.bin"), 90 << 20), (os.path.join(projects, "notes.txt"), 1024),
                       (os.path.join(videos, "film.mkv"), 40 << 20), (os.path.join(home, "todo.txt"), 10)):
        with open(path, "wb") as f:  # sparse: no real disk use
            f.truncate(size)
    env = {"HOME": home, "XDG_DATA_HOME": os.path.join(home, ".local", "share"),
           "XDG_CONFIG_HOME": os.path.join(home, ".config")}

    win.show_page("lens")
    page = win.pages["lens"]
    real_engine = page.engine

    def idle():
        return page.running is None and not page.moving and page.stack.get_visible_child_name() != "measuring"

    def names():
        return [os.path.basename(e["path"]) for e in page.entries if not os.path.basename(e["path"]).startswith(".")]

    def done():
        page.engine = real_engine
        page.set_root(os.path.expanduser("~"))
        shutil.rmtree(sandbox, ignore_errors=True)
        duplicates_test(win, report, wait, finish)

    def first():
        report(page.stack.get_visible_child_name() in ("results", "empty"), "Space Lens lists the home folder on opening")
        page.engine = Engine(real_engine.path, dry_run=True, env=env)
        page.set_root(home)
        wait(idle, listed, 60, "Space Lens list")

    def listed():
        report(names() == ["Projects", "Videos", "todo.txt"], f"home listed biggest first: {names()}")
        page.rows[projects].activate()
        wait(lambda: idle() and page.folder == projects, level1, 60, "open Projects")

    def level1():
        report(names() == ["App", "notes.txt"], f"opening a folder lists it: {names()}")
        page.rows[app].activate()
        wait(lambda: idle() and page.folder == app, level2, 60, "open App")

    def level2():
        page.rows[build].activate()
        wait(lambda: idle() and page.folder == build, level3, 60, "open Build")

    def level3():
        report(names() == ["out.bin"] and len(page.crumb_buttons) == 4, "three folders deep, the path bar shows each")
        page.up()
        wait(lambda: idle() and page.folder == app, back1, 60, "up")

    def back1():
        report(names() == ["Build"], "Up goes back one folder")
        page.crumb_buttons[0].emit("clicked")
        wait(lambda: idle() and page.folder == home, back_home, 60, "path bar")

    def back_home():
        report(names() == ["Projects", "Videos", "todo.txt"] and not page.up_button.get_sensitive(),
               "the path bar goes back to the start")
        page.set_root(sandbox)
        wait(lambda: idle() and page.folder == sandbox, outside, 60, "outside home")

    def outside():
        check = page.checks.get(home)
        report(check is not None and not check.get_sensitive() and not page.trash_button.get_sensitive(),
               "outside the home folder: view only")
        page.set_root(home)
        wait(lambda: idle() and page.folder == home, select, 60, "home again")

    def select():
        before = page.summary.get_text()
        page.checks[videos].set_active(True)
        report(page.summary.get_text() != before and page.trash_button.get_sensitive(),
               "ticking a folder updates the summary")
        page.trash([videos])
        wait(idle, dry_trashed, 60, "dry-run trash")

    def dry_trashed():
        report(os.path.isdir(videos) and "Videos" in names(), "dry run: the folder stays")
        if os.geteuid() == 0:
            report(True, "Trash and Undo skipped: the engine refuses them as root")
            return done()
        page.engine = Engine(real_engine.path, dry_run=False, env=env)
        page.undo_toast = None
        page.trash([videos])
        wait(idle, trashed, 60, "trash")

    def trashed():
        in_trash = os.path.join(home, ".local", "share", "Trash", "files", "Videos")
        report(not os.path.exists(videos) and os.path.isdir(in_trash) and names() == ["Projects", "todo.txt"],
               "Move to Trash moves the folder and measures again")
        if not page.undo_toast:
            report(False, "no Undo toast after moving to the Trash")
            return done()
        page.undo_toast.emit("button-clicked")
        wait(lambda: idle() and os.path.isdir(videos) and "Videos" in names(), undone, 60, "undo")

    def undone():
        report(os.path.isfile(os.path.join(videos, "film.mkv")) and names() == ["Projects", "Videos", "todo.txt"],
               "Undo from the toast puts the folder back where it was")
        done()

    wait(idle, first, 120, "first Space Lens list")


def duplicates_test(win, report, wait, finish):
    """Three copies of a photo: one group with the two older copies ticked; dry run, then Trash and Undo
    in a throwaway home."""
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home = os.path.join(sandbox, "home")
    copies = [os.path.join(home, d, "beach.jpg") for d in ("Photos", "Backup", "Downloads")]
    data = os.urandom(1536 << 10)
    for i, path in enumerate(copies):  # Photos oldest, Downloads newest
        os.makedirs(os.path.dirname(path))
        with open(path, "wb") as f:
            f.write(data)
        then = time.time() - (3 - i) * 86400
        os.utime(path, (then, then))
    with open(os.path.join(home, "Photos", "other.jpg"), "wb") as f:  # same size, other content
        f.write(os.urandom(1536 << 10))
    env = {"HOME": home, "XDG_DATA_HOME": os.path.join(home, ".local", "share")}
    older, newest = copies[:2], copies[2]

    win.show_page("dupes")
    page = win.pages["dupes"]
    real_engine = page.engine
    page.engine = Engine(real_engine.path, dry_run=True, env=env)
    page.set_folder(home)

    def idle():
        return page.running is None and page.stack.get_visible_child_name() != "searching"

    def files():
        return [[f["path"] for f in g["files"]] for g in page.shown_groups()]

    def done():
        page.engine = real_engine
        shutil.rmtree(sandbox, ignore_errors=True)
        startup_test(win, report, wait, finish)

    def searched():
        report(files() == [[newest] + older[::-1]], f"one group of three copies, newest first: {files()}")
        report(page.selected == set(older) and not page.checks[newest].get_active(),
               "the older copies are ticked, the newest is kept")
        page.checks[newest].set_active(True)
        row, warning = next(iter(page.group_rows.values()))
        report(warning.get_visible() and row.get_subtitle() == _("Every copy is selected: none would be kept"),
               "ticking every copy shows a warning")
        page.checks[older[0]].get_ancestor(Adw.ActionRow).activate()
        report(not warning.get_visible() and older[0] not in page.selected, "activating a copy's row toggles its box")
        page.select_automatically()
        report(page.selected == set(older) and not page.checks[newest].get_active(),
               "Select automatically keeps the newest copy")
        page.trash(sorted(page.selected))
        wait(lambda: page.running is None, dry_trashed, 60, "dry-run trash")

    def dry_trashed():
        report(all(os.path.exists(p) for p in copies) and len(files()) == 1, "dry run: the copies stay")
        if os.geteuid() == 0:
            report(True, "Trash and Undo skipped: the engine refuses them as root")
            return done()
        page.engine = Engine(real_engine.path, dry_run=False, env=env)
        page.trash(sorted(page.selected))
        wait(lambda: page.running is None, trashed, 60, "trash")

    def trashed():
        report(os.path.exists(newest) and not any(os.path.exists(p) for p in older) and not files(),
               "Move to Trash keeps the newest copy; the group is gone")
        if not page.undo_toast:
            report(False, "no Undo toast after moving to the Trash")
            return done()
        page.undo_toast.emit("button-clicked")
        wait(lambda: page.running is None and all(os.path.exists(p) for p in older), undone, 60, "undo")

    def undone():
        report(all(os.path.exists(p) for p in copies) and files() == [[newest] + older[::-1]],
               "Undo from the toast puts the copies back in their group")
        done()

    page.search()
    wait(idle, searched, 60, "duplicates search")


def startup_test(win, report, wait, finish):
    """Login apps of a throwaway home and a fake `systemctl --user`: list, switch off and on,
    remove to the Trash and undo."""
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home, bin_dir, system = (os.path.join(sandbox, d) for d in ("home", "bin", "xdg-autostart"))
    autostart, units = os.path.join(home, ".config", "autostart"), os.path.join(home, ".config", "systemd", "user")
    for d in (autostart, units, bin_dir, system):
        os.makedirs(d)
    chat = os.path.join(autostart, "chat.desktop")
    for path, text in ((chat, "[Desktop Entry]\nType=Application\nName=Chat\nExec=chat --tray\n"),
                       (os.path.join(system, "backup.desktop"), "[Desktop Entry]\nType=Application\nName=Backup\nExec=backup\n"),
                       (os.path.join(units, "sync.service"), "[Unit]\nDescription=Sync my files\n"),
                       (os.path.join(home, "units"), "sync.service enabled enabled\npipewire.service enabled enabled\n"),
                       (os.path.join(bin_dir, "systemctl"),
                        '#!/bin/sh\nshift\ncase $1 in list-unit-files) cat "$HOME/units" ;; '
                        'enable|disable) sed -i "s/^$2 [a-z]*/$2 ${1}d/" "$HOME/units" ;; esac\n')):
        with open(path, "w") as f:
            f.write(text)
    os.chmod(os.path.join(bin_dir, "systemctl"), 0o755)
    env = {"HOME": home, "XDG_DATA_HOME": os.path.join(home, ".local", "share"),
           "XDG_CONFIG_HOME": os.path.join(home, ".config"), "CLEANMATE_SYSTEM_AUTOSTART": system,
           "PATH": bin_dir + ":" + os.environ.get("PATH", "/usr/bin:/bin")}

    win.show_page("startup")
    page = win.pages["startup"]
    real_engine = page.engine

    def idle():
        return page.running is None and not page.changing

    def text():
        with open(chat) as f:
            return f.read()

    def done():
        page.engine = real_engine
        page.load()
        shutil.rmtree(sandbox, ignore_errors=True)
        uninstaller_test(win, report, wait, finish)

    def first():
        page.engine = Engine(real_engine.path, dry_run=True, env=env)
        page.load()
        wait(idle, listed, 60, "startup list")

    def listed():
        if os.geteuid() == 0:
            report(page.stack.get_visible_child_name() == "failed", "as root the engine refuses startup items")
            return done()
        ids = sorted(page.switches)
        report(ids == ["autostart:backup.desktop", "autostart:chat.desktop", "systemd:sync.service"],
               f"startup items listed, system services hidden: {ids}")
        page.show_system.set_active(True)
        sw = page.switches.get("systemd:pipewire.service")
        report(sw is not None and not sw.get_sensitive(), "a system service is shown but can't be switched")
        page.show_system.set_active(False)
        page.switches["autostart:chat.desktop"].set_active(False)
        wait(idle, dry_switched, 60, "dry-run switch")

    def dry_switched():
        report("Hidden" not in text() and page.switches["autostart:chat.desktop"].get_active(),
               "dry run: the entry stays on")
        page.engine = Engine(real_engine.path, dry_run=False, env=env)
        page.switches["autostart:chat.desktop"].set_active(False)
        wait(idle, switched_off, 60, "switch off")

    def switched_off():
        report("Hidden=true" in text() and not page.switches["autostart:chat.desktop"].get_active(),
               "switching an app off writes Hidden=true")
        page.rows["autostart:chat.desktop"].activate()  # a click on the row; the switch animates first
        wait(lambda: idle() and "Hidden" not in text(), switched_on, 60, "switch on")

    def switched_on():
        report("Hidden" not in text() and page.switches["autostart:chat.desktop"].get_active(),
               "switching it on again removes the line")
        unit = next(u for u in page.units if u["id"] == "autostart:chat.desktop")
        page.undo_toast = None
        page.remove(unit)
        wait(lambda: idle() and page.undo_toast is not None, removed, 60, "remove")

    def removed():
        in_trash = os.path.join(home, ".local", "share", "Trash", "files", "chat.desktop")
        report(not os.path.exists(chat) and os.path.exists(in_trash) and "autostart:chat.desktop" not in page.switches,
               "Remove moves the entry to the Trash")
        page.undo_toast.emit("button-clicked")
        wait(lambda: idle() and "autostart:chat.desktop" in page.switches, undone, 60, "undo")

    def undone():
        report(os.path.exists(chat), "Undo from the toast puts the startup entry back")
        done()

    wait(idle, first, 60, "first startup list")


STUBS = {  # package tools for the Uninstaller check: gimp (apt), Spotify (Flatpak), BusyBox (part of Ubuntu)
    "dpkg": """#!/bin/sh
[ "$1" = -S ] || exit 1; shift
for f; do n=${f##*/}; n=${n%.desktop}; case $n in gimp|busybox) echo "$n: $f" ;; esac; done
""",
    "dpkg-query": """#!/bin/sh
case "$*" in
  *Status-Abbrev*) ;;
  *Installed-Size*) printf 'gimp\\t20000\\toptional\\tno\\nbusybox\\t900\\trequired\\tno\\n' ;;
  *) for p; do case $p in -*) ;; *) echo "$p optional " ;; esac; done ;;
esac
""",
    "apt-cache": "#!/bin/sh\n",
    "apt-get": """#!/bin/sh
case "$*" in "-s purge gimp") printf 'Purg gimp [2.10]\\nPurg gimp-data [2.10]\\n' ;; -s*) ;; *) echo "apt-get $*" >>"$HOME/removed.log" ;; esac
""",
    "flatpak": """#!/bin/sh
case $1 in list) printf 'com.spotify.Client\\t123.0 MB\\n' ;; uninstall) echo "flatpak $*" >>"$HOME/removed.log" ;; esac
""",
    "sudo": "#!/bin/sh\nexit 1\n",
    "pkexec": "#!/bin/sh\nexit 126\n",  # never a real password prompt
}


def uninstaller_test(win, report, wait, finish):
    """List apps from stub launchers and package tools, select, check, dry-run; then remove the
    Flatpak app for real (a stub) and put its folder back, all in a throwaway home."""
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home, bin_dir, apps_dir = (os.path.join(sandbox, d) for d in ("home", "bin", "applications"))
    for d in (bin_dir, apps_dir, os.path.join(home, ".config", "GIMP"),
              os.path.join(home, ".var", "app", "com.spotify.Client")):
        os.makedirs(d)
    for name, text in STUBS.items():
        with open(os.path.join(bin_dir, name), "w") as f:
            f.write(text)
        os.chmod(os.path.join(bin_dir, name), 0o755)
    for name, title, exe, extra in (("gimp", "GNU Image Manipulation Program", "gimp-2.10 %U", ""),
                                    ("busybox", "BusyBox", "busybox", ""),
                                    ("com.spotify.Client", "Spotify", "flatpak run com.spotify.Client",
                                     "X-Flatpak=com.spotify.Client")):
        with open(os.path.join(apps_dir, name + ".desktop"), "w") as f:
            f.write(f"[Desktop Entry]\nType=Application\nName={title}\nExec={exe}\n{extra}\n")
    for path in (os.path.join(home, ".config", "GIMP", "gimprc"),
                 os.path.join(home, ".var", "app", "com.spotify.Client", "data")):
        with open(path, "w") as f:
            f.write("data\n")
    spotify_data = os.path.join(home, ".var", "app", "com.spotify.Client")
    env = {"HOME": home, "XDG_DATA_HOME": os.path.join(home, ".local", "share"),
           "XDG_CONFIG_HOME": os.path.join(home, ".config"), "CLEANMATE_APP_DIRS": apps_dir,
           "CLEANMATE_NO_UPDATE_CHECK": "1", "PATH": bin_dir + ":" + os.environ.get("PATH", "/usr/bin:/bin")}

    win.show_page("uninstall")
    page = win.pages["uninstall"]
    real_engine = page.engine
    checked = {}
    page.confirm = lambda apps, folders, check: checked.update(check)  # the dialog itself needs a click

    def idle():
        return not page.busy

    def done():
        page.engine = real_engine
        shutil.rmtree(sandbox, ignore_errors=True)
        settings_test(win, report, wait, finish)

    def first_list():  # the real list of this machine, then the stub one
        report(page.stack.get_visible_child_name() in ("results", "empty"), "Uninstaller lists this computer's apps")
        page.engine = Engine(real_engine.path, dry_run=True, env=env)
        page.load()
        wait(idle, listed, 60, "app list")

    def listed():
        ids = sorted(page.apps)
        report(ids == ["apt:gimp", "flatpak:com.spotify.Client"] and page.hidden == 1,
               f"apps listed, part of Ubuntu hidden: {ids}, {page.hidden} hidden")
        gimp_left = os.path.join(home, ".config", "GIMP")
        before = page.summary.get_text()
        page.checks["apt:gimp"].set_active(True)
        box = page.left_checks.get(gimp_left)
        report(box is not None and box.get_active() and box.get_sensitive() and ngettext("{n} folder", "{n} folders", 1) in page.summary.get_text()
               and page.summary.get_text() != before, "ticking an app ticks its leftover folder")
        box.set_active(False)
        report(" + " not in page.summary.get_text(), "a leftover folder can be left out")
        box.set_active(True)
        page.checks["apt:gimp"].set_active(False)
        report(not box.get_active() and not box.get_sensitive(), "unticking the app clears its folders")
        page.search_entry.set_text("spot")
        wait(lambda: not page.rows["apt:gimp"].get_visible(), searched, 5, "search")

    def searched():
        report(page.rows["flatpak:com.spotify.Client"].get_visible(), "search filters the list")
        page.search_entry.set_text("")
        for i in page.apps:
            page.checks[i].set_active(True)
        page.check()
        wait(lambda: idle() and checked, checked_done, 60, "check")

    def checked_done():
        report(checked.get("ok") and checked.get("extra") == 1 and "gimp-data" in checked.get("extra_text", ""),
               "check shows the other package apt removes")
        apps, folders = page.chosen()
        page.uninstall(apps, folders)
        wait(lambda: idle() and page.work_title.get_text().startswith(
            lead("Dry run: {n} app would be uninstalled", "Dry run: {n} apps would be uninstalled")), dry_done, 60, "dry-run uninstall")

    def dry_done():
        dry = ngettext("Dry run: {n} app would be uninstalled", "Dry run: {n} apps would be uninstalled", 1)
        if os.geteuid() != 0:  # root: Flatpak refused
            dry = ngettext("Dry run: {n} app would be uninstalled", "Dry run: {n} apps would be uninstalled", 2) + \
                ngettext(", {n} folder would be moved to the Trash", ", {n} folders would be moved to the Trash", 2)
        expected = dry
        report(page.work_title.get_text() == expected and os.path.isdir(spotify_data) and not os.path.exists(os.path.join(home, "removed.log")),
               f"dry run removes nothing: {page.work_title.get_text()}")
        if os.geteuid() == 0:
            report(True, "real uninstall skipped: the engine refuses Flatpak and folders as root")
            return done()
        page.engine = Engine(real_engine.path, dry_run=False, env=env)
        wait(idle, real_run, 30, "list after the dry run")

    def real_run():
        page.selected = {"flatpak:com.spotify.Client"}
        apps, folders = page.chosen()
        page.uninstall(apps, folders)
        wait(lambda: idle() and page.work_title.get_text().startswith(
            lead("Uninstalled {n} app", "Uninstalled {n} apps")), removed, 60, "uninstall")

    def removed():
        log = open(os.path.join(home, "removed.log")).read() if os.path.exists(os.path.join(home, "removed.log")) else ""
        report("flatpak uninstall -y --noninteractive --delete-data com.spotify.Client" in log
               and not os.path.exists(spotify_data), "the Flatpak app is removed and its folder moved to the Trash")
        if not page.undo_toast:
            report(False, "no Restore folders toast after uninstalling")
            return done()
        page.undo_toast.emit("button-clicked")
        wait(lambda: idle() and os.path.isdir(spotify_data), restored, 60, "restore folders")

    def restored():
        report(os.path.isdir(spotify_data), "Restore folders in the toast puts the app's folder back")
        wait(idle, done, 30, "list after restoring")

    wait(idle, first_list, 120, "first app list")


def settings_test(win, report, wait, finish):
    """Settings of a throwaway home with a fake `systemctl --user`: show the saved values, change a
    number, turn automatic cleaning on (the timer is enabled) and forget remembered selections."""
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home, bin_dir = os.path.join(sandbox, "home"), os.path.join(sandbox, "bin")
    conf = os.path.join(home, ".config", "cleanmate")
    for d in (conf, bin_dir):
        os.makedirs(d)
    settings_file, selection = os.path.join(conf, "settings"), os.path.join(conf, "selection")
    timer = os.path.join(home, ".config", "systemd", "user", "cleanmate.timer")
    for path, text in ((settings_file, "journal_days=14\n"), (selection, "apt_cache=1\n"),
                       (os.path.join(bin_dir, "systemctl"),
                        '#!/bin/sh\nshift\nmkdir -p "$HOME/enabled"\ncase $1 in is-enabled) test -e "$HOME/enabled/$3" ;; '
                        'enable) touch "$HOME/enabled/$3" ;; disable) rm -f "$HOME/enabled/$3" ;; esac\n')):
        with open(path, "w") as f:
            f.write(text)
    os.chmod(os.path.join(bin_dir, "systemctl"), 0o755)
    env = {"HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"), "CLEANMATE_NO_UPDATE_CHECK": "1",
           "PATH": bin_dir + ":" + os.environ.get("PATH", "/usr/bin:/bin")}

    dialog = win.show_settings()
    page = win.settings_page
    real_engine = page.engine

    def idle():
        return not page.busy()

    def saved():
        with open(settings_file) as f:
            return f.read()

    def done():
        dialog.close()
        shutil.rmtree(sandbox, ignore_errors=True)
        docker_entries_test(win, report, wait, finish)

    def first():
        report("schedule" in page.rows or os.geteuid() == 0, "Settings opens from the main menu")
        page.engine = Engine(real_engine.path, dry_run=True, env=env)
        page.load()
        wait(idle, listed, 30, "settings")

    def listed():
        if os.geteuid() == 0:
            report("schedule" not in page.rows, "as root the engine refuses settings")
            return done()
        row = page.rows.get("journal_days")
        report(row is not None and row.get_value() == 14 and page.rows["journal_mb"].get_value() == 100
               and page.rows["schedule"].get_selected() == 0, "settings show the saved values and defaults")
        row.set_value(30)
        wait(idle, dry_changed, 30, "dry-run change")

    def dry_changed():
        report(saved() == "journal_days=14\n" and page.rows["journal_days"].get_value() == 14,
               "dry run: nothing is saved")
        page.engine = Engine(real_engine.path, dry_run=False, env=env)
        page.rows["journal_days"].set_value(30)
        page.rows["update_check"].set_active(False)
        wait(idle, changed, 30, "change")

    def changed():
        report("journal_days=30" in saved() and "update_check=0" in saved(),
               "a changed number and switch are saved for the terminal app")
        page.rows["schedule"].set_selected(2)
        wait(idle, scheduled, 30, "automatic cleaning")

    def scheduled():
        text = open(timer).read() if os.path.exists(timer) else ""
        report("OnCalendar=weekly" in text and os.path.exists(os.path.join(home, "enabled", "cleanmate.timer")),
               "turning automatic cleaning on enables the weekly timer")
        page.change("selections", "reset")  # the confirmation itself needs a click
        wait(idle, reset, 30, "reset selections")

    def reset():
        report(not os.path.exists(selection) and not page.rows["selections"].reset_button.get_sensitive(),
               "Reset forgets remembered selections")
        done()

    wait(idle, first, 30, "first settings")


DOCKER_STUB = """#!/bin/sh
echo "$*" >>"$HOME/docker.log"
case "$*" in
  info*) exit 0 ;;
  "context inspect"*) echo unix:///var/run/docker.sock ;;
  "system df --format"*) printf 'Images\\t200MB (10%%)\\n' ;;
  "system df -v --format"*) ;;
  "images -f dangling=true --format {{.Size}}") [ -e "$HOME/gone" ] && echo 80MB || printf '120MB\\n80MB\\n' ;;
  "images -f dangling=true --no-trunc"*) [ -e "$HOME/gone" ] || printf 'sha256:%s\\t120MB\\t3 days ago\\n' "$(printf 'a%.0s' $(seq 64))"
    printf 'sha256:%s\\t80MB\\t2 weeks ago\\n' "$(printf 'b%.0s' $(seq 64))" ;;
  rmi*) touch "$HOME/gone" ;;
esac
"""


def docker_entries_test(win, report, wait, finish):
    """Developer Junk with a fake docker: two dangling images as sub-rows; untick one, Clean removes only
    the other (for real, through the stub)."""
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home, bin_dir = os.path.join(sandbox, "home"), os.path.join(sandbox, "bin")
    for d in (home, bin_dir):
        os.makedirs(d)
    with open(os.path.join(bin_dir, "docker"), "w") as f:
        f.write(DOCKER_STUB)
    os.chmod(os.path.join(bin_dir, "docker"), 0o755)
    log = os.path.join(home, "docker.log")
    env = {"HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"), "CLEANMATE_NO_UPDATE_CHECK": "1",
           "PATH": bin_dir + ":" + os.environ.get("PATH", "/usr/bin:/bin")}
    keep, drop = "sha256:" + "b" * 64, "sha256:" + "a" * 64

    win.show_page("dev")
    page = win.pages["dev"]
    real_engine = page.engine
    page.engine = Engine(real_engine.path, dry_run=False, env=env)

    def done():
        page.engine = real_engine
        shutil.rmtree(sandbox, ignore_errors=True)
        finish()

    def scanned():
        row = page.checks.get("docker_dangling")
        row = row and row.get_ancestor(Adw.ExpanderRow)
        if not row:
            report(False, "Docker dangling images have no sub-rows")
            return done()
        row.set_expanded(True)
        wait(lambda: "docker_dangling" in page.entries, listed, 30, "Docker entries")

    def listed():
        boxes = page.entry_checks.get("docker_dangling", {})
        report(sorted(boxes) == [drop, keep] and all(b.get_active() for b in boxes.values()),
               "two dangling images listed under the item, both ticked")
        boxes[keep].set_active(False)
        box = page.checks["docker_dangling"]
        report(box.get_active() and box.get_inconsistent() and page.chosen_bytes("docker_dangling") == 120000000
               and page.size_labels["docker_dangling"].get_text().count("/") == 1,
               "unticking one: the item box is half-ticked and the size shows selected / total")
        if os.geteuid() == 0:
            report(True, "real clean skipped: as root the engine refuses home items")
            return done()
        for i in list(page.selected):
            page.selected[i] = i == "docker_dangling"
        page.clean(["docker_dangling"])
        wait(lambda: page.clean_title.get_text().startswith(lead(_("Freed {size}"))), cleaned, 60, "Docker clean")

    def cleaned():
        text = open(log).read() if os.path.exists(log) else ""
        removed = [line for line in text.splitlines() if line.startswith("rmi ")]
        report(removed == [f"rmi {drop}"] and "image prune" not in text, "Clean removes only the ticked image")
        wait(lambda: page.running is None and page.stack.get_visible_child_name() == "results", done, 60,
             "scan after cleaning")

    page.scan()
    wait(lambda: page.running is None and page.stack.get_visible_child_name() == "results", scanned, 60,
         "Developer Junk scan")


def show_scene_page(win, page_id):
    """Show a page with its sidebar row highlighted, as a click would."""
    win.show_page(page_id)
    row = win.sidebar_list.get_first_child()
    while row and getattr(row, "page_id", None) != page_id:
        row = row.get_next_sibling()
    if row:
        win.sidebar_list.select_row(row)


def tool_scene(win, scene, path, wait, finish):
    """Large & Old Files with the two biggest files ticked; the Uninstaller with a Flatpak app ticked."""
    show_scene_page(win, scene)
    page = win.pages[scene]

    def shoot():
        GLib.timeout_add(1200, lambda: (screenshot(win, path, finish), False)[1])

    if scene == "large":
        def found():
            for e in page.files[:2]:
                page.checks[e["path"]].set_active(True)
            shoot()

        page.age_drop.set_selected(2)  # unused for 90 days: the demo's old files, not its caches
        page.search()
        return wait(lambda: page.running is None and page.stack.get_visible_child_name() != "searching",
                    found, 120, "search")

    def listed():
        for app_id, row in page.rows.items():
            if app_id.startswith("flatpak:") and page.apps[app_id]["leftovers"]:
                page.checks[app_id].set_active(True)
                row.set_expanded(True)
                break
        shoot()

    wait(lambda: not page.busy, listed, 120, "app list")


def run_scene(app, win, scene, path, report, wait, finish):
    """Screenshot scenes for docs and app stores (packaging/make-screenshots.sh)."""
    if scene in ("large", "uninstall"):
        return tool_scene(win, scene, path, wait, finish)
    page_id = {"privacy": "privacy", "ai": "ai", "user": "user"}.get(scene, "smart")
    show_scene_page(win, page_id)
    page = win.pages[page_id]

    def shoot(delay_ms=1200):
        GLib.timeout_add(delay_ms, lambda: (screenshot(win, path, finish), False)[1])

    def scanned():
        return page.running is None and page.stack.get_visible_child_name() not in ("start", "scanning")

    def after_scan():
        found = sorted((e for e in page.items.values() if e["status"] == "found"), key=lambda e: -e["bytes"])
        user_items = [e for e in found if not e["root"]]
        if scene == "details" and user_items:
            # an item whose details list real folders (not the demo's stubbed Docker)
            pick = [e for e in user_items if not e["id"].startswith("docker_")] or user_items
            page.show_details(pick[0])
            return shoot(2500)
        if scene == "confirm":
            page.confirm_clean()
            return shoot(2500)
        if scene == "done":
            # only caches inside the (demo) home folder — never /tmp or anything system-wide
            safe = {"npm", "pip", "gobuild", "yarn", "thumbs", "ai_claude_cache", "ai_codex_cache", "browser_chrome"}
            ids = [e["id"] for e in user_items if e["id"] in safe]
            if not ids:
                return shoot()
            for i in list(page.selected):
                page.selected[i] = i in ids
            page.clean(ids)
            # the page rescans 1.2 s after finishing: capture the summary before that
            return wait(lambda: page.clean_title.get_text().startswith(
                (lead(_("Freed {size}")), lead(_("Dry run: {size} would be freed")), _("History cleared"))),
                        lambda: shoot(300), 120, "clean")
        shoot()

    page.scan()
    wait(scanned, after_scan, 120, "scan")
