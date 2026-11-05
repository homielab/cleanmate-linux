"""`--selftest`: drive the real window like a user would, print results, quit.

Used by tests/run.sh on a virtual display. Only cleans in dry-run mode and
never touches system items (so no password prompt can appear). The Large & Old
Files, Space Lens, Duplicates and Startup Items checks move files to the Trash for real, and the Settings
check saves settings for real, the Docker check removes an image and a volume through a fake `docker`, the drive Trash
check empties a fake drive's Trash, the old installers check moves a download to the Trash and the Moved to the
Trash check moves files there and puts them back, but only in a throwaway folder they made, with the engine pointed
at it.
"""
import os
import shutil
import sys
import tempfile
import time

from gi.repository import Adw, Gdk, Gio, GLib, Gtk

from . import i18n
from . import preview
from . import uninstaller as U
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
    report_default = win.content_stack.get_visible_child_name()
    show_scene_page(win, "smart")
    page = win.pages["smart"]
    win.selection.remember = lambda *_: None  # never change the user's remembered choices
    if app.screenshot:  # headless displays may not animate: no transitions or fade-ins
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

    def check_item_texts():
        """Item names and descriptions in the app's language; untranslated ones are listed, not failed."""
        texts = [(e["id"], f, e[f]) for e in page.items.values() for f in ("label", "description") if e[f]]
        if not i18n.translating():
            report(all(i18n.item_text(t) == t for _i, _f, t in texts), "item names stay in English")
            return
        missing = [(i, f, t) for i, f, t in texts if i18n.untranslated(t)]
        for i, f, t in missing:
            print(f"SELFTEST warn untranslated item {f} ({i}): {t}", flush=True)
        report(len(missing) < len(texts), f"item names translated: {len(texts) - len(missing)} of {len(texts)}")

    def after_scan():
        found = [e for e in page.items.values() if e["status"] == "found"]
        check_item_texts()
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
        check_why(first)
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

    def check_why(first):
        """The ⓘ popover: four parts in the app's language; every item's why lines are translated."""
        shown = labels(page.why_popover(first))
        parts = [_("What it is"), _("Where it is"), _("After cleaning"), _("Skipped when")]
        report(all(p in shown for p in parts) and i18n.item_text(first["description"]) in shown,
               f"“{first['label']}” explains why it is safe: what, where, after cleaning, skipped when")
        lines = {t for e in page.items.values() for k in ("where_note", "after", "skipped") for t in e["why"][k]}
        missing = sorted(t for t in lines if i18n.untranslated(t))
        for t in missing:
            print(f"SELFTEST warn untranslated why line: {t}", flush=True)
        report(not missing, f"why lines translated: {len(lines) - len(missing)} of {len(lines)}")

    def after_details():
        root_found = [e["id"] for e in page.items.values() if e["status"] == "found" and e["root"] and not e.get("locked")]
        if root_found and not win.engine.can_ask_password():
            from .engine import PACKAGE_NEEDED
            shown = [i for i in root_found if i in page.checks and i in page.item_rows]
            report(shown and all(not page.checks[i].get_sensitive() and not page.selected.get(i)
                                 and page.item_rows[i].get_subtitle() == PACKAGE_NEEDED for i in shown),
                   f"not installed from a package: system items are locked, unticked, and say why: {shown}")
        user_items = [e for e in page.items.values()
                      if e["status"] == "found" and not e["root"] and not e.get("locked")]
        if not (win.engine.dry_run and user_items):
            report(True, "clean skipped (not a dry run, or nothing to clean)")
            return large_files_test(win, report, wait, finish)
        target = user_items[0]["id"]
        for i in list(page.selected):
            page.selected[i] = i == target
        app.send_notification = lambda nid, note: sent.append(nid)
        page.clean([target])
        wait(lambda: page.clean_title.get_text().startswith(lead(_("Dry run: {size} would be freed"))), after_clean, 60, "dry-run clean")

    sent = []

    def after_clean():
        report(True, f"dry-run clean finished: {page.clean_title.get_text()}")
        report(not sent, "a dry run sends no notification")
        large_files_test(win, report, wait, finish)

    if app.screenshot:
        return run_scene(app, win, app.scene, app.screenshot, report, wait, finish)
    report(report_default == "overview", "the app opens on System Overview")
    def check_shortcuts():
        """Ctrl+1…9, Ctrl+R and the shortcuts window."""
        from .window import SHORTCUT_PAGES
        accels = [app.get_accels_for_action(f"win.page::{p}") for p in SHORTCUT_PAGES]
        report(accels == [[f"<Control>{n}"] for n in range(1, 10)], "Ctrl+1…9 are bound to the first nine pages")
        report("<Control>r" in app.get_accels_for_action("win.reload"), "Ctrl+R is bound to scanning again")
        report("<Control>question" in app.get_accels_for_action("win.shortcuts"), "Ctrl+? is bound to the shortcuts")
        from .window import MORE_SHORTCUTS
        report([[Gtk.accelerator_parse(x) for x in app.get_accels_for_action(f"win.page::{p}")]
                for p, _a in MORE_SHORTCUTS] == [[Gtk.accelerator_parse(a)] for _p, a in MORE_SHORTCUTS]
               and MORE_SHORTCUTS[0] == ("large", "<Control>0"),
               "Ctrl+0 and Ctrl+Shift+1… open the other tool pages")
        ok = True
        for pid in SHORTCUT_PAGES + [p for p, _a in MORE_SHORTCUTS]:
            win.activate_action("win.page", GLib.Variant("s", pid))
            row = win.sidebar_list.get_selected_row()
            ok = ok and win.content_stack.get_visible_child_name() == pid and row and row.page_id == pid
        report(ok, "the page action opens each page and selects it in the sidebar")
        dev, real_group_on = win.pages["dev"], win.engine.group_on
        win.engine.group_on = lambda g: g != "dev"
        win.groups_changed()
        report(dev.stack.get_visible_child_name() == "off", "a group turned off in Settings shows it on its page")
        dev.scan()
        report(dev.running is None, "a group that is off doesn't scan")
        win.engine.group_on = real_group_on
        win.groups_changed()
        report(dev.stack.get_visible_child_name() == "start", "turned on again, the page can scan")
        win.activate_action("win.page", GLib.Variant("s", "smart"))
        busy = win.pages["smart"]
        busy.running = object()  # a scan in progress: Ctrl+R does nothing
        win.activate_action("win.reload", None)
        report(busy.stack.get_visible_child_name() != "scanning", "Ctrl+R does nothing while the page is busy")
        busy.running = None
        win.activate_action("win.shortcuts", None)
        report(win.shortcuts_window.get_visible(), "the shortcuts window opens")
        win.shortcuts_window.destroy()

    check_shortcuts()
    win.activate_action("win.reload", None)  # Ctrl+R on Smart Scan starts the scan
    report(page.running is not None, "Ctrl+R scans on the open page")
    wait(lambda: page.running is None and page.stack.get_visible_child_name() != "scanning",
         after_scan, 120, "scan")


def large_files_test(win, report, wait, finish):
    """Search with filters, select, dry-run, then Trash and Undo in a throwaway home."""
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home = os.path.join(sandbox, "home")
    videos = os.path.join(home, "Videos")
    os.makedirs(os.path.join(videos, ".git"))
    film, backup, note, pack = (os.path.join(videos, n) for n in ("film.mkv", "old backup.iso", "note.txt", ".git/pack"))
    for path, size in ((film, 120 << 20), (backup, 60 << 20), (note, 1024), (pack, 80 << 20)):  # sparse: no real disk use
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
        notes = [label.get_label() for label in page.notes]
        report(notes == [ngettext("{n} file skipped: it is in a cache, a Git folder or a Trash",
                                  "{n} files skipped: they are in caches, Git folders or a Trash", 1)],
               f"the file in a Git folder is counted as skipped: {notes}")
        page.age_drop.set_selected(2)  # 90 days: changing a filter searches again
        wait(idle, aged, 60, "search by age")

    def aged():
        report(names() == ["old backup.iso"], "age filter keeps only the old file")
        page.age_drop.set_selected(0)
        wait(idle, views, 60, "search again")

    def views():
        def shown():
            return [os.path.basename(e["path"]) for e in page.shown]
        page.checks[backup].set_active(True)
        page.kind_drop.set_selected(1)  # Video: no new search
        report(page.running is None and shown() == ["film.mkv"] and list(page.checks) == [film],
               f"the kind filter lists only videos: {shown()}")
        report(not page.chosen() and not page.trash_button.get_sensitive(),
               "a ticked file the kind filter hides is not moved")
        page.kind_drop.set_selected(3)  # Disk images & VMs
        report(shown() == ["old backup.iso"], f"the kind filter lists only disk images: {shown()}")
        page.kind_drop.set_selected(0)
        page.checks[backup].set_active(False)
        orders = []
        for i in (2, 1, 3, 0):  # name, date modified (oldest first), kind, size
            page.sort_drop.set_selected(i)
            orders.append(shown())
        report(orders == [["film.mkv", "old backup.iso"], ["old backup.iso", "film.mkv"],
                          ["film.mkv", "old backup.iso"], ["film.mkv", "old backup.iso"]],
               f"sort by name, date, kind and size: {orders}")
        real_open, opened = preview.open_file, []
        preview.open_file = lambda _w, path: opened.append(path)
        try:
            row = page.checks[film].get_ancestor(Adw.ActionRow)
            buttons = [w for w in walk(row) if isinstance(w, Gtk.Button) and w.get_tooltip_text() == _("Open")]
            buttons and buttons[0].emit("clicked")
            keys = [c for c in row.observe_controllers() if isinstance(c, Gtk.EventControllerKey)
                    and c.get_propagation_phase() == Gtk.PropagationPhase.CAPTURE]
            handled = keys and keys[0].emit("key-pressed", Gdk.KEY_Return, 0, 0)
            report(opened == [film, film] and handled and not page.selected,
                   "Open and Enter on a row open the file, without ticking it")
        finally:
            preview.open_file = real_open
        selection()

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
    home is view only (a lock, no box), hide and show hidden files, then move a folder to the Trash and undo it;
    on a fake writable drive move a file into the drive's Trash and undo it, check that a read-only drive is
    view only, and open /var/log from the system disk: the path bar starts at the disk, each row says why it
    stays and links to Logs."""
    from .engine import Engine
    from .spacelens import mount_of, reason_text
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home = os.path.join(sandbox, "home")
    projects, videos = os.path.join(home, "Projects"), os.path.join(home, "Videos")
    app, build = os.path.join(projects, "App"), os.path.join(projects, "App", "Build")
    os.makedirs(build)
    os.makedirs(videos)
    for path, size in ((os.path.join(build, "out.bin"), 90 << 20), (os.path.join(projects, "notes.txt"), 1024),
                       (os.path.join(videos, "film.mkv"), 40 << 20), (os.path.join(home, "todo.txt"), 10),
                       (os.path.join(sandbox, ".hidden.bin"), 1 << 20)):
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

    def has_button(widget, tip):
        stack = [widget.get_first_child()] if widget and widget.get_first_child() else []
        while stack:
            w = stack.pop()
            if isinstance(w, Gtk.Button) and w.get_tooltip_text() == tip:
                return True
            stack += [c for c in (w.get_next_sibling(), w.get_first_child()) if c]
        return False

    def outside():
        why = _("View only: {reason}").format(reason=reason_text("home")[0])
        report(page.locks.get(home) is not None and home not in page.checks and not page.trash_button.get_sensitive()
               and page.locks[home].get_tooltip_text() == why,
               "outside the home folder: view only, a lock that says why")
        report(has_button(page.rows.get(home), _("Open")) and has_button(page.rows.get(home), _("Show in Files")),
               "each row has Open and Show in Files")
        shown = [os.path.basename(e["path"]) for e in page.shown]
        page.hidden_button.set_active(False)
        hidden = [os.path.basename(e["path"]) for e in page.shown]
        report(".hidden.bin" in shown and ".hidden.bin" not in hidden and "hidden" in page.rows,
               f"hiding hidden files leaves dot names out, one row sums them up: {hidden}")
        page.hidden_button.set_active(True)
        report(".hidden.bin" in [os.path.basename(e["path"]) for e in page.shown] and "hidden" not in page.rows,
               "showing them again lists them")
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
            return to_drive()
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
        to_drive()

    def to_drive():
        page.engine = Engine(real_engine.path, dry_run=False, env=drive_env)
        page.set_root(photos)
        wait(lambda: idle() and page.folder == photos, on_drive, 60, "a drive's folder")

    # drives: every folder in media counts as a mounted drive; RO is read-only in the fake mount table
    media = os.path.join(sandbox, "media")
    usb, photos, ro = os.path.join(media, "USB"), os.path.join(media, "USB", "Photos"), os.path.join(media, "RO")
    picture, ro_file = os.path.join(photos, "beach.jpg"), os.path.join(ro, "old.bin")
    drive_trash = os.path.join(usb, f".Trash-{os.geteuid()}", "files", "beach.jpg")
    os.makedirs(photos)
    os.makedirs(ro)
    for path, size in ((picture, 30 << 20), (os.path.join(photos, "small.jpg"), 10), (ro_file, 1 << 20)):
        with open(path, "wb") as f:
            f.truncate(size)
    mounts = os.path.join(sandbox, "mounts")
    with open(mounts, "w") as f:
        f.write(f"/dev/sdz1 {ro} vfat ro,nosuid 0 0\n")
    drive_env = dict(env, CLEANMATE_VOLUME_ROOTS=media, CLEANMATE_MOUNTS=mounts)

    def on_drive():
        check = page.checks.get(picture)
        labels = [b.get_child().get_label() for b in page.crumb_buttons]
        report(page.root == usb and labels == ["USB", "Photos"] and page.up_button.get_sensitive(),
               f"a folder on a drive: the path bar starts at the drive: {labels}")
        report(check is not None and check.get_sensitive(), "a writable drive: things on it can be ticked")
        if os.geteuid() == 0:
            report(True, "drive Trash and Undo skipped: the engine refuses them as root")
            return read_only()
        page.undo_toast = None
        check.set_active(True)
        page.trash([picture])
        wait(lambda: idle() and not os.path.exists(picture), drive_trashed, 60, "trash on a drive")

    def drive_trashed():
        report(os.path.isfile(drive_trash) and names() == ["small.jpg"],
               "Move to Trash on a drive uses the drive's own Trash")
        if not page.undo_toast:
            report(False, "no Undo toast after moving to a drive's Trash")
            return done()
        page.undo_toast.emit("button-clicked")
        wait(lambda: idle() and os.path.isfile(picture), drive_undone, 60, "undo on a drive")

    def drive_undone():
        report(not os.path.exists(drive_trash) and names() == ["beach.jpg", "small.jpg"],
               "Undo puts the file back on the drive")
        read_only()

    def read_only():
        page.set_root(ro)
        wait(lambda: idle() and page.folder == ro, ro_listed, 60, "a read-only drive")

    def ro_listed():
        report(page.locks.get(ro_file) is not None and ro_file not in page.checks
               and not page.trash_button.get_sensitive(), "a read-only drive: view only")
        kinds = [p["kind"] for p in page.places]
        report(kinds[:2] == ["home", "system"] and page.places_menu.get_n_items() >= 2,
               f"Locations: your home folder, the system disk, then other disks ({kinds})")
        if not os.path.isdir("/var/log"):
            report(True, "whole disk skipped: no /var/log here")
            return done()
        page.engine = real_engine
        page.open_folder("/var/log")
        wait(lambda: idle() and page.folder == "/var/log", system_disk, 120, "/var/log")

    def system_disk():
        labels = [b.get_child().get_label() for b in page.crumb_buttons]
        disk = mount_of("/var/log")
        first = _("System disk") if disk == "/" else os.path.basename(disk)
        report(page.root == disk and labels[0] == first and labels[-1] == "log",
               f"a system folder: the path bar starts at its disk: {labels}")
        report(not page.checks and all(e["path"] in page.locks for e in page.shown)
               and all(pid == "logs" for pid in page.links.values()) and not page.trash_button.get_sensitive(),
               f"system logs: view only, each with a lock and a link to Logs ({len(page.links)} links)")
        done()

    wait(idle, first, 120, "first Space Lens list")


def duplicates_test(win, report, wait, finish):
    """Three copies of a photo: one group, nothing ticked; Select automatically keeps the oldest; dry run, then Trash and Undo
    in a throwaway home."""
    from .engine import Engine
    from .duplicates import auto_selection
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
    os.makedirs(os.path.join(home, ".backup"))
    with open(os.path.join(home, ".backup", "beach.jpg"), "wb") as f:  # a copy in a hidden folder: left out, counted
        f.write(data)
    env = {"HOME": home, "XDG_DATA_HOME": os.path.join(home, ".local", "share")}
    oldest, newer, newest = copies[0], copies[1:], copies[2]

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
        similar_photos_test(win, report, wait, finish)

    def searched():
        report(files() == [copies[::-1]], f"one group of three copies, newest first: {files()}")
        note = ngettext("{n} file skipped: it is hidden, or in a hidden folder",
                        "{n} files skipped: they are hidden, or in hidden folders", 1)
        report(note in labels(page.results), f"says a file in a hidden folder was skipped: {labels(page.results)[:4]}")
        report(not page.selected and not any(c.get_active() for c in page.checks.values()),
               "nothing is ticked after a search")
        report(auto_selection([{"files": [{"path": "c", "mtime": 3}, {"path": "b", "mtime": 1}, {"path": "a", "mtime": 2}]}])
               == {"a", "c"}, "auto_selection keeps the copy with the oldest date")
        for path in copies:
            page.checks[path].set_active(True)
        row, warning = next(iter(page.group_rows.values()))
        report(warning.get_visible() and row.get_subtitle() == _("Every copy is selected: none would be kept"),
               "ticking every copy shows a warning")
        page.checks[newest].get_ancestor(Adw.ActionRow).activate()
        report(not warning.get_visible() and newest not in page.selected, "activating a copy's row toggles its box")
        page.select_automatically()
        report(page.selected == set(newer) and not page.checks[oldest].get_active()
               and all(page.checks[p].get_active() for p in newer), "Select automatically keeps the oldest copy")
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
        report(os.path.exists(oldest) and not any(os.path.exists(p) for p in newer) and not files(),
               "Move to Trash keeps the oldest copy; the group is gone")
        if not page.undo_toast:
            report(False, "no Undo toast after moving to the Trash")
            return done()
        page.undo_toast.emit("button-clicked")
        wait(lambda: page.running is None and all(os.path.exists(p) for p in newer), undone, 60, "undo")

    def undone():
        report(all(os.path.exists(p) for p in copies) and files() == [copies[::-1]],
               "Undo from the toast puts the copies back in their group")
        done()

    page.search()
    wait(idle, searched, 60, "duplicates search")


# The longest the window may freeze (no main loop iteration) while Similar Photos reads and lists 2,000 photos.
# Measured 130-210 ms in Docker on a Mac; a person notices a freeze from about half a second.
# Shared CI runners stall for a few hundred ms now and then; a real hang is seconds, so CI gets more room.
MAX_PAUSE_MS = int(os.environ.get("CLEANMATE_SELFTEST_MAX_PAUSE_MS") or 500)


def similar_photos_test(win, report, wait, finish):
    """Duplicates › Similar Photos in a throwaway home: a photo, a smaller copy and a re-saved one group, a different
    photo, a hidden folder and a Never clean folder stay out; nothing ticked, the full-size photo suggested and
    previewed; thumbnails; Stop returns at once; 2,000 photos keep the window responsive while read, listed and
    scrolled; dry run, then Trash and Undo."""
    from gi.repository import GdkPixbuf
    from . import similar
    from .duplicates import FILES, PHOTOS
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home = os.path.join(sandbox, "home")
    pictures, private, hidden = (os.path.join(home, "Pictures", d) for d in ("", "Private", ".edits"))
    pictures, many = pictures.rstrip("/"), os.path.join(home, "Many")
    for d in (private, hidden, many, os.path.join(home, ".config", "cleanmate")):
        os.makedirs(d)
    with open(os.path.join(home, ".config", "cleanmate", "exclude"), "w") as f:
        f.write(private + "\n")

    def made_up_photo():  # 8 px grain of random colours
        grain = GdkPixbuf.Pixbuf.new_from_bytes(GLib.Bytes.new(os.urandom(80 * 60 * 3)), GdkPixbuf.Colorspace.RGB,
                                                False, 8, 80, 60, 240)
        return grain.scale_simple(640, 480, GdkPixbuf.InterpType.NEAREST)

    beach, other = made_up_photo(), made_up_photo()
    photo, smaller, resaved = (os.path.join(pictures, n) for n in ("beach.jpg", "beach small.jpg", "beach low.jpg"))
    beach.savev(photo, "jpeg", ["quality"], ["95"])  # as many pixels as the re-saved copy, a bigger file
    beach.scale_simple(320, 240, GdkPixbuf.InterpType.BILINEAR).savev(smaller, "jpeg", ["quality"], ["95"])
    beach.savev(resaved, "jpeg", ["quality"], ["60"])
    other.savev(os.path.join(pictures, "other.jpg"), "jpeg", ["quality"], ["90"])
    shutil.copy(resaved, hidden)
    if os.geteuid() == 0:  # the engine refuses settings as root, so the page gets no Never clean folders
        report(True, "Similar Photos and Never clean skipped: the engine refuses settings as root")
    else:
        shutil.copy(resaved, private)
    for i in range(2000):
        shutil.copy(resaved if i % 2 else smaller, os.path.join(many, f"{i:04d}.jpg"))
    env = {"HOME": home, "XDG_DATA_HOME": os.path.join(home, ".local", "share"),
           "XDG_CONFIG_HOME": os.path.join(home, ".config")}
    group = sorted((photo, smaller, resaved))
    others = [smaller, resaved]

    win.show_page("dupes")
    page = win.pages["dupes"]
    real_engine = page.engine
    page.mode_buttons[PHOTOS].set_active(True)
    report(page.mode == PHOTOS and not page.size_filter.get_visible(), "Similar Photos: no size filter")
    page.engine = Engine(real_engine.path, dry_run=True, env=env)
    page.set_folder(pictures)

    def idle():
        return page.running is None and page.stack.get_visible_child_name() != "searching"

    def files():
        return [sorted(f["path"] for f in g["files"]) for g in page.shown_groups()]

    def done():
        page.engine = real_engine
        page.mode_buttons[FILES].set_active(True)
        shutil.rmtree(sandbox, ignore_errors=True)
        startup_test(win, report, wait, finish)

    def searched():
        report(files() == [group], f"a photo, its smaller and its re-saved copy are one group; "
                                   f"a hidden and a Never clean folder are left out: {files()}")
        report(not page.selected and not any(c.get_active() for c in page.checks.values()),
               "nothing is ticked after a photo search")
        g = page.shown_groups()[0] if page.shown_groups() else {"files": [{"path": ""}]}
        report(g["files"][0]["path"] == photo, "the full-size photo is suggested and listed first")
        report(page.preview.path == photo and page.preview.badge.get_visible(),
               "the preview shows the suggested photo, marked")
        row = page.checks[smaller].get_ancestor(Adw.ActionRow)
        focus = [c for c in row.observe_controllers() if isinstance(c, Gtk.EventControllerFocus)]
        focus and focus[0].emit("enter")
        report(page.preview.path == smaller and not page.preview.badge.get_visible(),
               "moving to a photo's row shows it in the preview")
        thumbs = [w for w in walk(row) if isinstance(w, Gtk.Image) and w.has_css_class("file-thumb")]

        def pictures():
            big = page.preview.picture.get_paintable()
            return thumbs and thumbs[0].get_paintable() and big and big.get_width() == 320

        wait(pictures, previewed, 30, "thumbnail and preview")

    def previewed():
        report(True, "a photo row shows its thumbnail; the preview the photo itself")
        page.select_automatically()
        report(page.selected == set(others), "Select automatically keeps the suggested photo")
        page.search()
        page.stop()
        report(page.running is None and page.stack.get_visible_child_name() == "results",
               "Stop ends a photo search at once")
        real_find = similar.find_photos

        def broken(*_a):
            raise OSError("disk went away")

        similar.find_photos = broken
        page.search()

        def crashed():
            similar.find_photos = real_find
            report(page.stack.get_visible_child_name() == "failed"
                   and "disk went away" in page.failed.get_description(),
                   "an error while reading photos shows the error page, not \"no similar photos\"")
            many_photos()

        wait(idle, crashed, 60, "photo search that fails")

    def many_photos():
        page.set_folder(many)
        gaps, last, listed = {"reading": 0, "listing": 0}, [None], [0]

        def tick():  # through the search, then 3 s of listing, reading thumbnails and scrolling
            # the longest the main loop went without running this 20 ms timer: how long the window froze
            now = GLib.get_monotonic_time()
            phase = "listing" if listed[0] else "reading"
            if last[0] is not None:
                gaps[phase] = max(gaps[phase], now - last[0])
            last[0] = now
            if page.stack.get_visible_child_name() == "searching":
                return True
            listed[0] = listed[0] or now
            adj = page.scroller.get_vadjustment()
            adj.set_value((adj.get_value() + 120) % max(1, adj.get_upper() - adj.get_page_size()))
            return now - listed[0] < 3_000_000

        page.search()
        GLib.timeout_add(20, tick)
        wait(lambda: idle() and listed[0] and GLib.get_monotonic_time() - listed[0] > 3_100_000,
             lambda: many_read(gaps["reading"] // 1000, gaps["listing"] // 1000), 120, "2,000 photo search")

    def many_read(reading_ms, listing_ms):
        report(len(page.shown_groups()) == 1 and len(page.shown_groups()[0]["files"]) == 2000,
               "2,000 photos read: one group")
        report(reading_ms < MAX_PAUSE_MS,
               f"the window stays responsive while reading 2,000 photos (longest pause {reading_ms} ms)")
        report(listing_ms < MAX_PAUSE_MS and len(page.checks) > 300,
               f"the window stays responsive while listing 2,000 photos with their thumbnails and scrolling "
               f"(longest pause {listing_ms} ms, {len(page.checks)} rows in 3 s)")
        page.set_folder(pictures)
        page.search()
        wait(idle, again, 60, "photo search")

    def again():
        page.select_automatically()
        page.trash(sorted(page.selected))
        wait(lambda: page.running is None, dry_trashed, 60, "dry-run trash")

    def dry_trashed():
        report(all(os.path.exists(p) for p in group) and files() == [group], "dry run: the photos stay")
        if os.geteuid() == 0:
            report(True, "Trash and Undo skipped: the engine refuses them as root")
            return done()
        page.engine = Engine(real_engine.path, dry_run=False, env=env)
        page.trash(sorted(page.selected))
        wait(lambda: page.running is None, trashed, 60, "trash")

    def trashed():
        report(os.path.exists(photo) and not any(os.path.exists(p) for p in others) and not files(),
               "Move to Trash keeps the suggested photo; the group is gone")
        if not page.undo_toast:
            report(False, "no Undo toast after moving the photos to the Trash")
            return done()
        page.undo_toast.emit("button-clicked")
        wait(lambda: page.running is None and all(os.path.exists(p) for p in others), undone, 60, "undo")

    def undone():
        report(files() == [group] and page.shown_groups()[0]["files"][0]["path"] == photo,
               "Undo puts the photos back in their group")
        done()

    page.search()
    wait(idle, searched, 60, "similar photos search")


def labels(widget):
    """The text of every Gtk.Label inside a widget."""
    out, child = [], widget.get_first_child()
    if isinstance(widget, Gtk.Label):
        out.append(widget.get_label())
    while child:
        out += labels(child)
        child = child.get_next_sibling()
    return out


def startup_test(win, report, wait, finish):
    """Login apps of a throwaway home and a fake `systemctl --user`: list, switch off and on,
    remove to the Trash and undo; an entry whose program is gone is flagged, removed and put back."""
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home, bin_dir, system = (os.path.join(sandbox, d) for d in ("home", "bin", "xdg-autostart"))
    autostart, units = os.path.join(home, ".config", "autostart"), os.path.join(home, ".config", "systemd", "user")
    for d in (autostart, units, bin_dir, system):
        os.makedirs(d)
    chat, gone = os.path.join(autostart, "chat.desktop"), os.path.join(autostart, "gone.desktop")
    for path, text in ((chat, "[Desktop Entry]\nType=Application\nName=Chat\nExec=chat --tray\n"),
                       (os.path.join(bin_dir, "chat"), "#!/bin/sh\n"),
                       (gone, "[Desktop Entry]\nType=Application\nName=Old Sync\nExec=zz-removed-sync --tray\n"),
                       (os.path.join(system, "backup.desktop"), "[Desktop Entry]\nType=Application\nName=Backup\nExec=backup\n"),
                       (os.path.join(units, "sync.service"), "[Unit]\nDescription=Sync my files\n"),
                       (os.path.join(home, "units"), "sync.service enabled enabled\npipewire.service enabled enabled\n"),
                       (os.path.join(bin_dir, "systemctl"),
                        '#!/bin/sh\nshift\ncase $1 in list-unit-files) cat "$HOME/units" ;; '
                        'enable|disable) for u; do :; done; sed -i "s/^$u [a-z]*/$u ${1}d/" "$HOME/units" ;; esac\n')):
        with open(path, "w") as f:
            f.write(text)
    for name in ("systemctl", "chat"):
        os.chmod(os.path.join(bin_dir, name), 0o755)
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
        report(ids == ["autostart:backup.desktop", "autostart:chat.desktop", "autostart:gone.desktop",
                       "systemd:sync.service"],
               f"startup items listed, system services hidden: {ids}")
        ctrl_f(win)
        page.find_bar.entry.set_text("chat")
        page.apply_filter()
        shown = sorted(k for k, row in page.rows.items() if row.get_visible())
        report(page.find_bar.get_search_mode() and shown == ["autostart:chat.desktop"],
               f"Ctrl+F in Startup Items keeps the matching item: {shown}")
        page.find_bar.set_search_mode(False)
        page.apply_filter()
        report(all(row.get_visible() for row in page.rows.values()), "closing the search lists every item again")
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
        first = page.results.get_first_child().get_next_sibling()  # the group under the header
        broken = [u["id"] for u in page.units if u.get("missing")]
        report(broken == ["autostart:gone.desktop"] and isinstance(first, Adw.PreferencesGroup)
               and first.get_title() == _("Broken items"),
               f"an entry whose program is gone is listed first, under Broken items: {broken}")
        missing = _("Missing: {command}").format(command="zz-removed-sync")
        report(missing in labels(page.rows["autostart:gone.desktop"]), "the broken entry says what is missing")
        unit = next(u for u in page.units if u["id"] == "autostart:gone.desktop")
        page.undo_toast = None
        page.remove(unit)
        wait(lambda: idle() and page.undo_toast is not None, broken_removed, 60, "remove broken")

    def broken_removed():
        report(not os.path.exists(gone) and "autostart:gone.desktop" not in page.rows,
               "Remove moves the broken entry to the Trash")
        page.undo_toast.emit("button-clicked")
        wait(lambda: idle() and "autostart:gone.desktop" in page.rows, broken_undone, 60, "undo broken")

    def broken_undone():
        report(os.path.exists(gone), "Undo puts the broken entry back")
        done()

    wait(idle, first, 60, "first startup list")


STUBS = {  # package tools for the Uninstaller: gimp (apt), Spotify (Flatpak), VLC (Snap), BusyBox (part of Ubuntu)
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
case $1 in
  list) printf 'com.spotify.Client\\t123.0 MB\\n' ;;
  ps) [ -f "$HOME/spotify-runs" ] && echo com.spotify.Client ;;
  uninstall) echo "flatpak $*" >>"$HOME/removed.log" ;;
esac
""",
    "snap": """#!/bin/sh
case $1 in list) printf 'Name Version Rev\\nvlc 3.0 1\\n' ;; remove) echo "snap $*" >>"$HOME/removed.log" ;; esac
""",
    "sudo": "#!/bin/sh\n[ \"$1\" = -n ] && shift\nexec \"$@\"\n",
    # never a real password prompt: count the prompts, run the engine as you
    "pkexec": "#!/bin/sh\necho \"pkexec $*\" >>\"$HOME/pkexec.log\"\nexec \"$@\"\n",
}


def uninstaller_test(win, report, wait, finish):
    """List apps from stub launchers and package tools, select (the box above the list, ticks kept
    through search, sort and filter), check, dry-run; then remove three apps at once for real (stubs):
    apt and Snap through one pkexec, the running Flatpak app skipped, and put their folders back;
    the folder of a Flatpak app removed earlier is listed unticked, goes to the Trash and comes back;
    an AppImage app (launcher in your applications folder) goes to the Trash with its launcher, icon and
    folder, and Restore brings all four back; Reset of one app is refused while it runs, then moves the
    ticked folders of its data to the Trash (the app stays) and Restore brings them back; all in a throwaway home."""
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home, bin_dir, apps_dir = (os.path.join(sandbox, d) for d in ("home", "bin", "applications"))
    gone = os.path.join(home, ".var", "app", "org.example.Gone")  # a Flatpak app removed earlier
    proc = os.path.join(sandbox, "proc")
    my_apps = os.path.join(home, ".local", "share", "applications")
    for d in (bin_dir, apps_dir, my_apps, os.path.join(home, ".config", "GIMP"), os.path.join(home, "snap", "vlc"),
              os.path.join(home, ".var", "app", "com.spotify.Client"), gone, proc):
        os.makedirs(d)
    for name, text in STUBS.items():
        with open(os.path.join(bin_dir, name), "w") as f:
            f.write(text)
        os.chmod(os.path.join(bin_dir, name), 0o755)
    for name, title, exe, extra in (("gimp", "GNU Image Manipulation Program", "gimp-2.10 %U", ""),
                                    ("busybox", "BusyBox", "busybox", ""),
                                    ("com.spotify.Client", "Spotify", "flatpak run com.spotify.Client",
                                     "X-Flatpak=com.spotify.Client"),
                                    ("vlc_vlc", "VLC media player", "/snap/bin/vlc %U", "X-SnapInstanceName=vlc")):
        with open(os.path.join(apps_dir, name + ".desktop"), "w") as f:
            f.write(f"[Desktop Entry]\nType=Application\nName={title}\nExec={exe}\n{extra}\n")
    for path in (os.path.join(home, ".config", "GIMP", "gimprc"),
                 os.path.join(home, ".var", "app", "com.spotify.Client", "data"), os.path.join(gone, "data"),
                 os.path.join(home, "snap", "vlc", "data")):
        with open(path, "w") as f:
            f.write("data\n")
    spotify_data = os.path.join(home, ".var", "app", "com.spotify.Client")
    gimp_data, vlc_data = os.path.join(home, ".config", "GIMP"), os.path.join(home, "snap", "vlc")
    appimage = os.path.join(home, "Applications", "Zqnote-1.0-x86_64.AppImage")
    ai_launcher, ai_data = os.path.join(my_apps, "zqnote.desktop"), os.path.join(home, ".config", "Zqnote")
    ai_icon = os.path.join(home, ".local", "share", "icons", "zqnote.png")
    env = {"HOME": home, "XDG_DATA_HOME": os.path.join(home, ".local", "share"),
           "XDG_CONFIG_HOME": os.path.join(home, ".config"), "CLEANMATE_APP_DIRS": my_apps + ":" + apps_dir,
           "CLEANMATE_PROC": proc,  # no process of these apps runs (Spotify: `flatpak ps` when asked)
           "CLEANMATE_NO_UPDATE_CHECK": "1", "PATH": bin_dir + ":" + os.environ.get("PATH", "/usr/bin:/bin")}

    win.show_page("uninstall")
    page = win.pages["uninstall"]
    real_engine = page.engine
    checked = {}
    page.confirm = lambda apps, folders, check: checked.update(check)  # the dialog itself needs a click
    asked = {}
    real_confirm_reset = page.confirm_reset
    page.confirm_reset = lambda app, data: asked.update(app=app, data=data)
    toasts = []
    real_toast = win.toast

    def toast(text, *args, **kwargs):
        toasts.append(text)
        return real_toast(text, *args, **kwargs)
    win.toast = toast

    def idle():
        return not page.busy

    def done():
        page.engine = real_engine
        page.confirm_reset = real_confirm_reset
        win.toast = real_toast
        shutil.rmtree(sandbox, ignore_errors=True)
        settings_test(win, report, wait, finish)

    def first_list():  # the real list of this machine, then the stub one
        report(page.stack.get_visible_child_name() in ("results", "empty"), "Uninstaller lists this computer's apps")
        page.engine = Engine(real_engine.path, dry_run=True, env=env)
        page.load()
        wait(idle, listed, 60, "app list")

    def listed():
        ids = sorted(page.apps)
        report(ids == ["apt:gimp", "flatpak:com.spotify.Client", "snap:vlc"] and page.hidden == 1,
               f"apps listed, part of Ubuntu hidden: {ids}, {page.hidden} hidden")
        orphans = [o["path"] for o in page.orphans]
        report(orphans == [gone] and gone in page.orphan_checks and not page.orphan_checks[gone].get_active()
               and not page.orphan_button.get_sensitive(),
               f"the folder of a removed Flatpak app is listed on its own, not ticked: {orphans}")
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
        focused = []
        page.search_entry.grab_focus = lambda: focused.append(1)  # a headless window may not take focus
        ctrl_f(win)
        del page.search_entry.grab_focus
        report(focused == [1], "Ctrl+F in Uninstall Apps goes to its search box")
        page.search_entry.set_text("spot")
        wait(lambda: not page.rows["apt:gimp"].get_visible(), searched, 5, "search")

    def searched():
        report(page.rows["flatpak:com.spotify.Client"].get_visible(), "search filters the list")
        page.all_check.set_active(True)
        report(page.selected == {"flatpak:com.spotify.Client"} and page.all_check.get_active()
               and not page.all_check.get_inconsistent(), f"the box above the list ticks only the apps shown: {page.selected}")
        page.search_entry.set_text("")
        wait(lambda: page.rows["apt:gimp"].get_visible(), unsearched, 5, "search cleared")

    def unsearched():
        report(page.selected == {"flatpak:com.spotify.Client"} and page.all_check.get_inconsistent()
               and page.checks["flatpak:com.spotify.Client"].get_active(), "ticks stay after the search; the box shows some")
        page.sort_drop.set_selected(2)  # by name: the list is built again
        report(page.checks["flatpak:com.spotify.Client"].get_active() and not page.checks["apt:gimp"].get_active()
               and page.all_check.get_inconsistent(), "ticks stay when sorting")
        page.all_check.set_active(True)
        report(len(page.selected) == 3 and page.all_check.get_active() and not page.all_check.get_inconsistent()
               and page.remove_button.get_label() == ngettext("Uninstall {n} app…", "Uninstall {n} apps…", 3),
               f"the box above the list ticks every app: {page.remove_button.get_label()}")
        titles = sorted(row.get_title() for row in page.batch_rows.values())
        report(page.batch_box.get_first_child() is not None and titles == sorted(a["name"] for a in page.apps.values()),
               f"more than one app ticked: the panel lists each one: {titles}")
        page.unused_drop.set_selected(4)  # unused for 12+ months: their folders were just made, so none is shown
        report(len(page.selected) == 3 and not page.all_check.get_sensitive(),
               "ticks stay while the filter hides the apps")
        page.unused_drop.set_selected(0)
        page.sort_drop.set_selected(0)
        page.all_check.set_active(False)
        report(not page.selected and not page.batch_rows and not page.all_check.get_active(),
               "the box above the list unticks every app shown; no panel")
        now = 1_000_000_000
        day = 86400
        old, recent = {"last_used": now - 100 * day}, {"last_used": now - 10 * day}
        report(U.unused_visible(old, 3, False, now) and not U.unused_visible(recent, 3, False, now)
               and not U.unused_visible(old, 6, False, now) and U.unused_visible(recent, 0, False, now),
               "unused filter compares the last-used date with N months")
        report(not U.unused_visible({"last_used": 0}, 1, False, now) and U.unused_visible({"last_used": 0}, 1, True, now)
               and U.unused_visible({"last_used": 0}, 0, False, now), "apps without a date only show when asked")
        undated = [i for i, a in page.apps.items() if not a["last_used"]]
        if undated:
            page.unused_drop.set_selected(1)
            report(not page.rows[undated[0]].get_visible() and page.undated_button.get_visible(),
                   "unused filter hides apps with no date and offers to show them")
            page.undated_button.emit("clicked")
            report(page.rows[undated[0]].get_visible() and not page.undated_button.get_visible(),
                   "Show reveals apps with no date")
            page.unused_drop.set_selected(0)
            report(not page.show_undated and page.rows[undated[0]].get_visible(), "all apps again after the filter resets")
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
        dry = ngettext("Dry run: {n} app would be uninstalled", "Dry run: {n} apps would be uninstalled", 2) + \
            ngettext("; {n} could not be uninstalled", "; {n} could not be uninstalled", 1)  # root: Flatpak refused
        if os.geteuid() != 0:
            dry = ngettext("Dry run: {n} app would be uninstalled", "Dry run: {n} apps would be uninstalled", 3) + \
                ngettext(", {n} folder would be moved to the Trash", ", {n} folders would be moved to the Trash", 3)
        expected = dry
        report(page.work_title.get_text() == expected and os.path.isdir(spotify_data) and not os.path.exists(os.path.join(home, "removed.log"))
               and not os.path.exists(os.path.join(home, "pkexec.log")),
               f"dry run removes nothing and asks no password: {page.work_title.get_text()}")
        if os.geteuid() == 0:
            report(True, "real uninstall skipped: the engine refuses Flatpak and folders as root")
            return done()
        page.engine = Engine(real_engine.path, dry_run=False, env=env)
        page.engine.root_ok = False  # a copy you can change (this checkout): pkexec never runs it
        page.load()
        wait(lambda: idle() and page.stack.get_visible_child_name() == "results", held_apps, 60, "list, not a package")

    def held_apps():
        from .engine import PACKAGE_NEEDED
        held = [i for i in ("apt:gimp", "snap:vlc") if not page.checks[i].get_sensitive()
                and page.rows[i].get_subtitle() == PACKAGE_NEEDED]
        page.all_check.set_active(True)
        report(held == ["apt:gimp", "snap:vlc"] and page.checks["flatpak:com.spotify.Client"].get_sensitive()
               and [a["id"] for a in page.chosen()[0]] == ["flatpak:com.spotify.Client"],
               f"not installed from a package: apt and Snap apps are locked and say why, Select all skips them: {held}")
        page.all_check.set_active(False)
        page.engine.root_ok = True  # from here on as the package's /usr/bin/cleanmate (root's)
        page.load()
        wait(lambda: idle() and page.stack.get_visible_child_name() == "results", real_run, 60, "list as a package")

    def real_run():
        open(os.path.join(home, "spotify-runs"), "w").close()  # `flatpak ps` lists Spotify now
        checked.clear()
        page.all_check.set_active(True)
        page.check()
        wait(lambda: idle() and checked, real_checked, 60, "check of three apps")

    def real_checked():
        running = {r["id"]: r["program"] for r in checked.get("running", [])}
        report(checked.get("ok") and list(running) == ["flatpak:com.spotify.Client"],
               f"the check names the running app: {running}")
        apps, folders = page.chosen()
        report(len(apps) == 3 and len(folders) == 3, f"three apps and their folders chosen: {len(apps)}, {len(folders)}")
        page.uninstall(apps, folders, running)  # what Uninstall in the dialog does
        wait(lambda: idle() and page.work_title.get_text().startswith(
            lead("Uninstalled {n} app", "Uninstalled {n} apps")), removed, 60, "uninstall")

    def removed():
        def text(name):
            path = os.path.join(home, name)
            return open(path).read() if os.path.exists(path) else ""
        log, prompts = text("removed.log"), text("pkexec.log").splitlines()
        report(len(prompts) == 1 and sorted(prompts[0].split(" uninstall ")[-1].split()) == ["apt:gimp", "snap:vlc"]
               and " --polkit=uninstall-apps --json " in prompts[0],
               f"one password for the apt and Snap apps together, the dialog says Uninstall apps: {prompts}")
        report("apt-get purge -y gimp" in log and "snap remove --purge vlc" in log and "flatpak" not in log,
               f"apt and Snap removed, the running Flatpak app not: {log!r}")
        skipped = U.running_text("com.spotify.Client")
        report(os.path.isdir(spotify_data) and not os.path.exists(gimp_data) and not os.path.exists(vlc_data)
               and page.work_title.get_text().endswith(ngettext("; {n} app skipped because it is running",
                                                                "; {n} apps skipped because they are running", 1)),
               f"the folders of the removed apps go to the Trash, the running app's stay: {page.work_title.get_text()}")
        subtitles = []
        row = page.work_list.get_first_child()
        while row:
            subtitles.append(row.get_subtitle())
            row = row.get_next_sibling()
        report(skipped in subtitles, f"the running app says why it was skipped: {subtitles}")
        if not page.undo_toast:
            report(False, "no Restore folders toast after uninstalling")
            return done()
        page.undo_toast.emit("button-clicked")
        wait(lambda: idle() and os.path.isdir(gimp_data) and os.path.isdir(vlc_data), restored, 60, "restore folders")

    def restored():
        report(os.path.isdir(gimp_data) and os.path.isdir(vlc_data),
               "Restore folders in the toast puts the folders of all the removed apps back")
        wait(lambda: idle() and gone in page.orphan_checks, trash_orphan, 30, "list after restoring")

    def trash_orphan():
        page.orphan_checks[gone].set_active(True)
        report(page.orphan_button.get_sensitive(), "ticking a leftover folder enables Move to Trash")
        page.trash_orphans()
        wait(lambda: idle() and not os.path.exists(gone) and page.undo_toast, orphan_trashed, 60, "leftover to the Trash")

    def orphan_trashed():
        in_trash = os.path.join(home, ".local", "share", "Trash", "files", "org.example.Gone")
        report(os.path.isdir(in_trash) and gone not in page.orphan_checks,
               "Move to Trash moves the leftover folder to the Trash and off the list")
        page.undo_toast.emit("button-clicked")
        wait(lambda: idle() and os.path.isdir(gone) and gone in page.orphan_checks, orphan_back, 60, "undo leftover")

    def orphan_back():
        report(os.path.isdir(os.path.join(gone, ".")) and os.path.exists(os.path.join(gone, "data")),
               "Undo puts the leftover folder back")
        os.makedirs(os.path.dirname(appimage))
        os.makedirs(os.path.dirname(ai_icon))
        os.makedirs(ai_data)
        for path, text in ((appimage, "\0" * 2000), (ai_icon, "png\n"), (os.path.join(ai_data, "settings"), "data\n"),
                           (ai_launcher, f"[Desktop Entry]\nType=Application\nName=Zqnote\nExec={appimage} %U\nIcon=zqnote\n")):
            with open(path, "w") as f:
                f.write(text)
        os.chmod(appimage, 0o755)
        page.load()
        wait(lambda: idle() and any(a["kind"] == "appimage" for a in page.apps.values()), ai_listed, 60, "AppImage listed")

    def ai_listed():
        ai = next(i for i, a in page.apps.items() if a["kind"] == "appimage")
        a = page.apps[ai]
        report(a["name"] == "Zqnote" and a["bytes"] == 2000 and [l["path"] for l in a["leftovers"]] == [ai_data]
               and page.rows[ai].get_subtitle().startswith("AppImage"),
               f"an AppImage app is listed with its size and folder: {a['name']}, {a['bytes']}, {a['leftovers']}")
        for i in list(page.selected):  # Spotify, skipped before, is still ticked
            page.checks[i].set_active(False)
        page.checks[ai].set_active(True)
        checked.clear()
        page.check()
        wait(lambda: idle() and checked, ai_checked, 60, "check of the AppImage app")

    def ai_checked():
        apps, folders = page.chosen()
        report(checked.get("ok") and not checked.get("running") and [a["kind"] for a in apps] == ["appimage"]
               and len(folders) == 1, f"the AppImage app and its folder chosen: {len(apps)}, {len(folders)}")
        page.uninstall(apps, folders, {})
        wait(lambda: idle() and page.work_title.get_text().startswith(
            lead("Uninstalled {n} app", "Uninstalled {n} apps")), ai_removed, 60, "AppImage uninstall")

    def ai_removed():
        trash = os.path.join(home, ".local", "share", "Trash", "files")
        moved = sorted(n for n in os.listdir(trash) if n.lower().startswith("zqnote"))
        prompts = open(os.path.join(home, "pkexec.log")).read().splitlines()
        report(not any(os.path.exists(p) for p in (appimage, ai_launcher, ai_icon, ai_data)) and len(moved) == 4
               and len(prompts) == 1, f"the AppImage, its launcher, icon and folder go to the Trash, no password: {moved}")
        if not page.undo_toast:
            report(False, "no Restore toast after uninstalling the AppImage app")
            return done()
        page.undo_toast.emit("button-clicked")
        wait(lambda: idle() and all(os.path.exists(p) for p in (appimage, ai_launcher, ai_icon, ai_data)),
             ai_restored, 60, "restore the AppImage app")

    def ai_restored():
        report(all(os.path.exists(p) for p in (appimage, ai_launcher, ai_icon, os.path.join(ai_data, "settings"))),
               "Restore puts the AppImage app back: file, launcher, icon and folder")
        wait(lambda: idle() and any(a["kind"] == "appimage" for a in page.apps.values()), reset_start, 30,
             "list after restoring the AppImage app")

    spotify = "flatpak:com.spotify.Client"

    def reset_start():
        for d in ("cache", "config"):
            os.makedirs(os.path.join(spotify_data, d), exist_ok=True)
            with open(os.path.join(spotify_data, d, "x"), "w") as f:
                f.write("data\n")
        for i in list(page.selected):
            page.checks[i].set_active(False)
        page.checks[spotify].set_active(True)
        page.checks["apt:gimp"].set_active(True)
        report(not page.reset_button.get_sensitive(), "Reset needs exactly one app ticked")
        page.checks["apt:gimp"].set_active(False)
        report(page.reset_button.get_sensitive(), "one app ticked: Reset is offered")
        toasts.clear()
        page.reset_check()  # Spotify still runs (`flatpak ps`)
        wait(lambda: idle() and toasts, reset_refused, 60, "reset check of a running app")

    def reset_refused():
        report(not asked and any("com.spotify.Client" in t for t in toasts),
               f"a running app is not reset, the toast says which program: {toasts}")
        os.remove(os.path.join(home, "spotify-runs"))
        page.reset_check()
        wait(lambda: idle() and asked, reset_asked, 60, "reset check")

    def reset_asked():
        paths = sorted(d["path"] for d in asked["data"])
        report(paths == [os.path.join(spotify_data, "cache"), os.path.join(spotify_data, "config")],
               f"Reset lists the app's data folders: {paths}")
        dialog = real_confirm_reset(asked["app"], asked["data"])
        report(len(dialog.checks) == 2 and all(c.get_active() for c in dialog.checks),
               "the confirmation lists each folder, ticked")
        for c in dialog.checks:
            c.set_active(c.path.endswith("config"))  # keep the cache
        page.undo_toast = None
        dialog.emit("response", "reset")
        dialog.force_close()
        wait(lambda: idle() and page.undo_toast and spotify in page.apps, reset_done, 60, "reset")

    def reset_done():
        log = open(os.path.join(home, "removed.log")).read() if os.path.exists(os.path.join(home, "removed.log")) else ""
        report(not os.path.exists(os.path.join(spotify_data, "config")) and os.path.isdir(os.path.join(spotify_data, "cache"))
               and "flatpak uninstall" not in log and spotify in page.apps,
               "Reset moves only the ticked folder to the Trash; the app stays")
        page.undo_toast.emit("button-clicked")
        wait(lambda: idle() and os.path.isdir(os.path.join(spotify_data, "config")), reset_restored, 60, "restore after reset")

    def reset_restored():
        report(os.path.exists(os.path.join(spotify_data, "config", "x")), "Restore after Reset puts the folder back")
        wait(idle, done, 30, "list after the reset")

    wait(idle, first_list, 120, "first app list")


def settings_test(win, report, wait, finish):
    """Settings of a throwaway home with a fake `systemctl --user`: show the saved values, change a
    number, turn automatic cleaning on (the timer is enabled), turn the scan reminder on and both it and the
    low disk alert off (the daily check timer comes and goes), pick a language (Restart starts the app
    again, here through a stub), forget remembered selections and add and remove a Never clean folder."""
    from .engine import Engine
    from .messages import human
    from .settings import auto_last_text
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home, bin_dir = os.path.join(sandbox, "home"), os.path.join(sandbox, "bin")
    conf = os.path.join(home, ".config", "cleanmate")
    for d in (conf, bin_dir):
        os.makedirs(d)
    settings_file, selection = os.path.join(conf, "settings"), os.path.join(conf, "selection")
    timer = os.path.join(home, ".config", "systemd", "user", "cleanmate.timer")
    check_timer = os.path.join(home, ".config", "systemd", "user", "cleanmate-check.timer")
    for path, text in ((settings_file, "journal_days=14\n"), (selection, "apt_cache=1\n"),
                       (os.path.join(bin_dir, "systemctl"),
                        '#!/bin/sh\nshift\nmkdir -p "$HOME/enabled"\ncase $1 in is-enabled) test -e "$HOME/enabled/$3" ;; '
                        'enable) touch "$HOME/enabled/$3" ;; disable) rm -f "$HOME/enabled/$3" ;; esac\n'),
                       (os.path.join(bin_dir, "gsettings"),  # remember-recent-files kept in ~/recent
                        '#!/bin/sh\nf=$HOME/recent\n[ -e "$f" ] || echo true >"$f"\n'
                        'case $1 in get) cat "$f" ;; set) echo "$4" >"$f" ;; esac\n')):
        with open(path, "w") as f:
            f.write(text)
    for name in ("systemctl", "gsettings"):
        os.chmod(os.path.join(bin_dir, name), 0o755)
    state = os.path.join(home, ".local", "state")
    log = os.path.join(state, "cleanmate", "clean.log")
    os.makedirs(os.path.dirname(log))
    with open(log, "w") as f:
        f.write("2026-01-02 03:04:05 trash /home/alex/old.iso\n2026-01-03 10:00:00 Cleanup finished — 1.0 MB freed\n")
    with open(os.path.join(state, "cleanmate", "auto-state"), "w") as f:  # the timer's last clean failed
        f.write(f"last_items=npm\nlast_result=failed\nlast_time={int(time.time())}\nlast_why=task_failed\n")
    env = {"HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"), "XDG_STATE_HOME": state,
           "CLEANMATE_NO_UPDATE_CHECK": "1",
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
        low_disk_alert_test(win, report, wait, finish)

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
               and page.rows["schedule"].get_selected() == 0 and page.rows["language"].get_selected() == 0
               and page.rows["low_disk_pct"].values[page.rows["low_disk_pct"].get_selected()] == 10
               and page.rows["remind"].get_selected() == 0
               and not page.rows["language"].restart_button.get_visible(),
               "settings show the saved values and defaults")
        report(all(page.rows.get(f"group_{g}") and page.rows[f"group_{g}"].get_active()
                   for g in ("system", "logs", "user", "ai", "dev", "privacy")),
               "Scan groups: a switch per group, all on by default")
        last = page.rows.get("auto_last")
        failed = _("couldn't clean {items}").format(items=i18n.item_text("npm cache"))
        report(last is not None and failed in last.get_subtitle(),
               f"Automatic cleaning shows the last run and why it failed: {last and last.get_subtitle()}")
        freed = auto_last_text({"time": int(time.time()), "result": "ok", "freed": 1048576, "retrying": True})
        report(human(1048576) in freed and _("The last try didn't finish: it tries again within the hour") in freed,
               f"… or what it freed, and that it tries again: {freed}")
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
        page.rows["remind"].set_selected(1)
        wait(idle, reminded, 30, "scan reminder")

    def reminded():
        text = open(check_timer).read() if os.path.exists(check_timer) else ""
        report("remind=weekly" in saved() and "OnCalendar=daily" in text
               and os.path.exists(os.path.join(home, "enabled", "cleanmate-check.timer")),
               "turning the scan reminder on saves it and enables the daily check")
        page.rows["low_disk_pct"].set_selected(0)
        page.rows["remind"].set_selected(0)
        wait(idle, checks_off, 30, "low disk alert and reminder off")

    def checks_off():
        report("low_disk_pct=0" in saved() and "remind=off" in saved() and not os.path.exists(check_timer)
               and not os.path.exists(os.path.join(home, "enabled", "cleanmate-check.timer")),
               "with the low disk alert and the scan reminder off the daily check goes away")
        page.rows["language"].set_selected(2)
        wait(idle, language_set, 30, "language")

    app = win.get_application()
    started, quits = [], []

    def language_set():
        row = page.rows["language"]
        report("language=vi" in saved() and row.restart_button.get_visible() and row.get_subtitle(),
               "picking Tiếng Việt saves it and offers a restart")
        app.spawn, app.quit = started.append, lambda: quits.append(1)  # the real ones would end the self-test
        row.restart_button.emit("clicked")
        wait(lambda: quits, restarted, 10, "restart")

    def restarted():
        del app.spawn, app.quit
        argv = started[0] if started else []
        report(len(started) == 1 and argv[1:2] == [os.path.abspath(sys.argv[0])] and argv[2:] == sys.argv[1:],
               "Restart starts CleanMate again with the same arguments, then quits")
        page.rows["language"].set_selected(0)
        wait(idle, language_back, 30, "language back")

    def language_back():
        report("language=system" in saved() and not page.rows["language"].restart_button.get_visible(),
               "back to the language in use: no restart needed")
        page.change("selections", "reset")  # the confirmation itself needs a click
        wait(idle, reset, 30, "reset selections")

    def reset():
        report(not os.path.exists(selection) and not page.rows["selections"].reset_button.get_sensitive(),
               "Reset forgets remembered selections")
        row = page.rows["recent_files"]
        report(row.get_sensitive() and row.get_active(), "Remember recent files reads gsettings")
        row.set_active(False)
        wait(idle, recent_off, 30, "recent files")

    def recent_off():
        with open(os.path.join(home, "recent")) as f:
            report(f.read().strip() == "false", "turning Remember recent files off sets it in gsettings")
        page.rows["activity"].emit("activated")
        wait(lambda: not page.activity.loading, activity_shown, 30, "activity log")

    def activity_shown():
        act = page.activity
        titles = []
        child = act.list.get_first_child()
        while child:
            titles.append(child.get_title())
            child = child.get_next_sibling()
        report(act.stack.get_visible_child_name() == "list" and len(titles) == 2
               and titles[0].startswith("Cleanup finished") and "old.iso" in titles[1],
               "Activity log lists the log, newest first")
        os.remove(log)
        page.show_activity()
        wait(lambda: not page.activity.loading, activity_empty, 30, "empty activity log")

    def activity_empty():
        report(page.activity.stack.get_visible_child_name() == "empty", "an empty activity log says so")
        os.makedirs(project)
        page.change_exclusion("add", home)  # too broad: refused
        page.change_exclusion("add", project)
        wait(idle, excluded, 30, "Never clean")

    project = os.path.join(home, "Projects", "keep")
    exclude_file = os.path.join(conf, "exclude")

    def never_rows():
        return [r.path for r in page.rows["exclusions"].folder_rows if hasattr(r, "path")]

    def excluded():
        with open(exclude_file) as f:
            report(f.read() == project + "\n" and never_rows() == [project],
                   "Never clean: Add Folder saves it for both apps and lists it; your home folder is refused")
        page.rows["exclusions"].folder_rows[0].remove_button.emit("clicked")
        wait(idle, unexcluded, 30, "Never clean remove")

    def unexcluded():
        with open(exclude_file) as f:
            report(f.read() == "" and never_rows() == [], "Never clean: the remove button takes it off the list")
        done()

    wait(idle, first, 30, "first settings")


def low_disk_alert_test(win, report, wait, finish):
    """The low disk alert of a throwaway home with a fake `df` (5 % free): the app sends it as a Gio
    notification, never notify-send (missing in the Flatpak and without libnotify-bin), once a day."""
    from .engine import Engine
    app = win.get_application()
    if os.geteuid() == 0:  # the engine refuses checks as root
        report(True, "low disk alert skipped as root")
        return docker_entries_test(win, report, wait, finish)
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home, bin_dir = os.path.join(sandbox, "home"), os.path.join(sandbox, "bin")
    os.makedirs(home)
    os.makedirs(bin_dir)
    for name, text in (("df", '#!/bin/sh\necho "1B-blocks Avail"\necho "100000000000 5000000000"\n'),
                       ("notify-send", '#!/bin/sh\necho "$*" >>"$HOME/notify.log"\n'),
                       ("systemctl", "#!/bin/sh\nexit 0\n")):
        with open(os.path.join(bin_dir, name), "w") as f:
            f.write(text)
        os.chmod(os.path.join(bin_dir, name), 0o755)
    env = {"HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"),
           "XDG_STATE_HOME": os.path.join(home, ".local", "state"), "CLEANMATE_NO_UPDATE_CHECK": "1",
           "PATH": bin_dir + ":" + os.environ.get("PATH", "/usr/bin:/bin")}
    engine = Engine(win.engine.path, env=env)
    real_notify = app.send_notification
    sent, runs = [], []
    app.send_notification = lambda nid, note: sent.append(nid)

    def first():
        report(sent == ["check-low_disk"] and not os.path.exists(os.path.join(home, "notify.log")),
               f"a due low disk alert is sent by the app, not notify-send: {sent}")
        app.check_disk(engine, lambda ok, status: runs.append(2))
        wait(lambda: len(runs) == 2, second, 30, "low disk check again")

    def second():
        report(sent == ["check-low_disk"], "once a day: the next check sends nothing")
        app.send_notification = real_notify
        shutil.rmtree(sandbox, ignore_errors=True)
        docker_entries_test(win, report, wait, finish)

    app.check_disk(engine, lambda ok, status: runs.append(1))
    wait(lambda: runs, first, 30, "low disk check")


DOCKER_STUB = """#!/bin/sh
echo "$*" >>"$HOME/docker.log"
case "$*" in
  info*) exit 0 ;;
  "context inspect"*) echo unix:///var/run/docker.sock ;;
  "system df --format"*) printf 'Images\\t200MB (10%%)\\nLocal Volumes\\t1.52GB (90%%)\\n' ;;
  "system df -v --format {{range .Volumes}}"*) [ -e "$HOME/volume-gone" ] || echo 'pgdata|0|1.5GB|local|'
    printf '%s|0|20MB|local|com.docker.volume.anonymous=\\n' "$(printf 'f%.0s' $(seq 64))" ;;
  "system df -v --format"*) ;;
  "volume ls -qf dangling=true") [ -e "$HOME/volume-gone" ] || echo pgdata; printf 'f%.0s' $(seq 64); echo ;;
  "volume rm"*) touch "$HOME/volume-gone" ;;
  "images -f dangling=true --format {{.Size}}") [ -e "$HOME/gone" ] && echo 80MB || printf '120MB\\n80MB\\n' ;;
  "images -f dangling=true --no-trunc"*) [ -e "$HOME/gone" ] || printf 'sha256:%s\\t120MB\\t3 days ago\\n' "$(printf 'a%.0s' $(seq 64))"
    printf 'sha256:%s\\t80MB\\t2 weeks ago\\n' "$(printf 'b%.0s' $(seq 64))" ;;
  rmi*) touch "$HOME/gone" ;;
esac
"""


def docker_entries_test(win, report, wait, finish):
    """Developer Junk with a fake docker: two dangling images as sub-rows; untick one, Clean removes only
    the other (for real, through the stub). Then two unused volumes, none ticked; tick one, Clean removes
    only that one with `docker volume rm`."""
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
    anon = "f" * 64

    win.show_page("dev")
    page = win.pages["dev"]
    real_engine = page.engine
    page.engine = Engine(real_engine.path, dry_run=False, env=env)

    def done():
        page.engine = real_engine
        shutil.rmtree(sandbox, ignore_errors=True)
        drive_trash_test(win, report, wait, finish)

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
            return volumes()
        for i in list(page.selected):
            page.selected[i] = i == "docker_dangling"
        report(page.undo_note(["docker_dangling"]) == _("This can't be undone."),
               "the confirmation says an item deleted for good can't be undone")
        win.get_application().send_notification = lambda nid, note: notes.append(nid)
        page.clean(["docker_dangling"])
        wait(lambda: page.clean_title.get_text().startswith(lead(_("Freed {size}"))), cleaned, 60, "Docker clean")

    notes = []

    def cleaned():
        text = open(log).read() if os.path.exists(log) else ""
        removed = [line for line in text.splitlines() if line.startswith("rmi ")]
        report(removed == [f"rmi {drop}"] and "image prune" not in text, "Clean removes only the ticked image")
        report(page.undo_toast is None and not page.trashed, "a clean that deleted everything for good offers no Undo")
        report(notes == (["cleaned"] if not win.is_active() else []),
               "a clean while the window isn't in front sends a notification with what it freed")
        report(page.clean_disks.get_visible() and " → " in page.clean_disks.get_text(),
               f"a real clean shows free space before → after: {page.clean_disks.get_text()}")
        wait(lambda: page.running is None and page.stack.get_visible_child_name() == "results", volumes, 60,
             "scan after cleaning")

    def volumes():
        row = page.checks.get("docker_volumes")
        row = row and row.get_ancestor(Adw.ExpanderRow)
        if not row:
            report(False, "Docker volumes have no sub-rows")
            return done()
        row.set_expanded(True)
        wait(lambda: "docker_volumes" in page.entries, volumes_listed, 30, "Docker volumes")

    def volumes_listed():
        boxes = page.entry_checks.get("docker_volumes", {})
        report(sorted(boxes) == [anon, "pgdata"] and not any(b.get_active() for b in boxes.values()),
               "two unused volumes listed under the item, none ticked")
        if sorted(boxes) != [anon, "pgdata"]:
            return done()
        notes = {i: b.get_ancestor(Adw.ActionRow).get_subtitle() for i, b in boxes.items()}
        report(notes == {"pgdata": _("Named volume — may hold data"), anon: _("Anonymous volume")},
               f"a named volume may hold data, the other is anonymous: {notes}")
        boxes["pgdata"].set_active(True)
        box = page.checks["docker_volumes"]
        report(box.get_active() and box.get_inconsistent() and page.chosen_bytes("docker_volumes") == 1500000000
               and page.size_labels["docker_volumes"].get_text().count("/") == 1,
               "ticking one volume: the item box is half-ticked and the size shows selected / total")
        boxes[anon].set_active(True)
        report(not box.get_inconsistent() and page.by_entries("docker_volumes")
               and page.chosen_bytes("docker_volumes") == 1520000000,
               "both volumes ticked: Clean still removes them by name, not with docker volume prune")
        boxes[anon].set_active(False)
        if os.geteuid() == 0:
            return done()
        for i in list(page.selected):
            page.selected[i] = i == "docker_volumes"
        open(log, "w").close()
        page.clean(["docker_volumes"])
        wait(lambda: page.clean_title.get_text().startswith(lead(_("Freed {size}"))), volumes_cleaned, 60,
             "Docker volume clean")

    def volumes_cleaned():
        text = open(log).read() if os.path.exists(log) else ""
        removed = [line for line in text.splitlines() if line.startswith("volume rm") or "prune" in line]
        report(removed == ["volume rm pgdata"], f"Clean removes only the ticked volume: {removed}")
        wait(lambda: page.running is None and page.stack.get_visible_child_name() == "results", done, 60,
             "scan after cleaning volumes")

    page.scan()
    wait(lambda: page.running is None and page.stack.get_visible_child_name() == "results", scanned, 60,
         "Developer Junk scan")


def drive_trash_test(win, report, wait, finish):
    """User & App Junk with two fake drives, each with something in your Trash on it: one sub-row per drive,
    none ticked; ticking one half-ticks the item and Clean empties only that drive's Trash (for real)."""
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home, media = os.path.join(sandbox, "home"), os.path.join(sandbox, "media")
    trash = {name: os.path.join(media, name, f".Trash-{os.geteuid()}") for name in ("Backup", "USB")}
    files = {name: os.path.join(t, "files", "old.bin") for name, t in trash.items()}
    os.makedirs(home)
    for name, size in (("Backup", 1000), ("USB", 2000)):
        os.makedirs(os.path.dirname(files[name]), mode=0o700)
        os.chmod(trash[name], 0o700)
        with open(files[name], "wb") as f:
            f.write(b"\0" * size)
    env = {"HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"), "CLEANMATE_NO_UPDATE_CHECK": "1",
           "CLEANMATE_VOLUME_ROOTS": media}  # every folder in it counts as a mounted drive
    usb = os.path.join(media, "USB")

    win.show_page("user")
    page = win.pages["user"]
    real_engine = page.engine
    page.engine = Engine(real_engine.path, dry_run=False, env=env)

    def done():
        page.engine = real_engine
        shutil.rmtree(sandbox, ignore_errors=True)
        old_installers_test(win, report, wait, finish)

    def scanned():
        box = page.checks.get("trash_drives")
        row = box and box.get_ancestor(Adw.ExpanderRow)
        if not row:
            report(False, "Trash on external drives has no sub-rows")
            return done()
        report(not box.get_active(), "Trash on external drives is not ticked by default")
        row.set_expanded(True)
        wait(lambda: "trash_drives" in page.entries, listed, 30, "drive entries")

    def listed():
        boxes = page.entry_checks.get("trash_drives", {})
        report(sorted(boxes) == [os.path.join(media, "Backup"), usb] and not any(b.get_active() for b in boxes.values()),
               "one sub-row per drive, none ticked")
        if usb not in boxes:
            return done()
        boxes[usb].set_active(True)
        box = page.checks["trash_drives"]
        report(box.get_active() and box.get_inconsistent() and page.chosen_bytes("trash_drives") == 2000
               and page.size_labels["trash_drives"].get_text().count("/") == 1,
               "ticking one drive: the item box is half-ticked and the size shows selected / total")
        if os.geteuid() == 0:
            report(True, "real clean skipped: as root the engine refuses home items")
            return done()
        page.clean(["trash_drives"])
        wait(lambda: page.clean_title.get_text().startswith(lead(_("Freed {size}"))), cleaned, 60, "drive Trash clean")

    def cleaned():
        report(not os.path.exists(files["USB"]) and os.path.exists(files["Backup"])
               and os.path.isdir(os.path.join(trash["USB"], "files")),
               "Clean empties only the ticked drive's Trash and keeps the folder")
        wait(lambda: page.running is None and page.stack.get_visible_child_name() == "results", done, 60,
             "scan after cleaning")

    page.scan()
    wait(lambda: page.running is None and page.stack.get_visible_child_name() == "results", scanned, 60,
         "User & App Junk scan")


def old_installers_test(win, report, wait, finish):
    """System Junk with two old installers in Downloads: one sub-row per file, none ticked; ticking one
    half-ticks the item and Clean moves only that file to the Trash (for real, in a throwaway home).
    Then Old downloads: an old file and an old folder, each a sub-row, none ticked, no installer among them."""
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    downloads = os.path.join(sandbox, "Downloads")
    os.makedirs(os.path.join(downloads, "sub"))
    old = time.time() - 40 * 86400
    os.makedirs(os.path.join(downloads, "Trip"))
    for name, size in (("a.deb", 1000), ("b.iso", 2000), ("c.deb", 500), ("sub/d.deb", 700),
                       ("report.pdf", 3000), ("Trip/a.jpg", 4000)):
        path = os.path.join(downloads, name)
        with open(path, "wb") as f:
            f.write(b"\0" * size)
        if name != "c.deb":  # c.deb was downloaded today
            os.utime(path, (old, old))
    downloads_old = time.time() - 120 * 86400  # untouched for longer than Old downloads' 90 days
    for name in ("report.pdf", "Trip/a.jpg", "Trip"):
        os.utime(os.path.join(downloads, name), (downloads_old, downloads_old))
    env = {"HOME": sandbox, "XDG_CONFIG_HOME": os.path.join(sandbox, ".config"), "CLEANMATE_NO_UPDATE_CHECK": "1"}

    win.show_page("system")
    page = win.pages["system"]
    real_engine = page.engine
    page.engine = Engine(real_engine.path, dry_run=False, env=env)

    def done():
        page.engine = real_engine
        shutil.rmtree(sandbox, ignore_errors=True)
        scan_tools_test(win, report, wait, finish)

    def scanned():
        box = page.checks.get("old_installers")
        row = box and box.get_ancestor(Adw.ExpanderRow)
        if not row:
            report(False, "Old installers in Downloads has no sub-rows")
            return done()
        report(not box.get_active(), "Old installers in Downloads is not ticked by default")
        row.set_expanded(True)
        wait(lambda: "old_installers" in page.entries, listed, 30, "installer entries")

    def listed():
        boxes = page.entry_checks.get("old_installers", {})
        report(sorted(boxes) == ["a.deb", "b.iso"] and not any(b.get_active() for b in boxes.values()),
               "one sub-row per old installer at the top of Downloads, none ticked")
        if "a.deb" not in boxes:
            return done()
        boxes["a.deb"].set_active(True)
        box = page.checks["old_installers"]
        report(box.get_active() and box.get_inconsistent() and page.chosen_bytes("old_installers") == 1000
               and page.size_labels["old_installers"].get_text().count("/") == 1,
               "ticking one file: the item box is half-ticked and the size shows selected / total")
        report(page.undo_note(["old_installers"]) == _("Items moved to the Trash can be undone for 10 seconds; "
                                                       "the rest is deleted for good."),
               "the confirmation says an item that goes to the Trash can be undone")
        if os.geteuid() == 0:
            report(True, "real clean skipped: as root the engine refuses home items")
            return old_downloads()
        page.clean(["old_installers"])
        wait(lambda: page.clean_title.get_text().startswith(lead(_("Freed {size}"))), cleaned, 60, "installer clean")

    def cleaned():
        trash = os.path.join(sandbox, ".local", "share", "Trash", "files")
        report(not os.path.exists(os.path.join(downloads, "a.deb")) and os.path.exists(os.path.join(trash, "a.deb"))
               and os.path.exists(os.path.join(downloads, "b.iso")),
               "Clean moves only the ticked installer to the Trash")
        report(page.trashed == {"old_installers": ["a.deb"]} and page.undo_toast is not None,
               "after a clean that moved something to the Trash, a toast offers Undo")
        wait(lambda: page.running is None and page.stack.get_visible_child_name() == "results", undo, 60,
             "scan after cleaning")

    def undo():
        report(page.summary_trashed is not None and page.summary_trashed.get_label() == _("View Moved Items"),
               "the clean's summary leads to Moved to the Trash")
        if not page.undo_toast:
            return old_downloads()
        page.undo_toast.emit("button-clicked")
        wait(lambda: page.restoring is None and page.running is None
             and page.stack.get_visible_child_name() == "results"
             and page.items.get("old_installers", {}).get("bytes") == 3000, undone, 60, "undo of the clean")

    def undone():
        report(os.path.exists(os.path.join(downloads, "a.deb"))
               and not os.path.exists(os.path.join(sandbox, ".local", "share", "Trash", "files", "a.deb")),
               "Undo puts the installer back from the Trash and the scan lists it again")
        old_downloads()

    def old_downloads():
        box = page.checks.get("old_downloads")
        row = box and box.get_ancestor(Adw.ExpanderRow)
        if not row:
            report(False, "Old downloads has no sub-rows")
            return done()
        report(not box.get_active(), "Old downloads is not ticked by default")
        row.set_expanded(True)
        wait(lambda: "old_downloads" in page.entries, downloads_listed, 30, "old download entries")

    def downloads_listed():
        boxes = page.entry_checks.get("old_downloads", {})
        report(sorted(boxes) == ["Trip", "report.pdf"] and not any(b.get_active() for b in boxes.values()),
               "one sub-row per old file or folder in Downloads, none ticked, installers left to their own item")
        done()

    page.scan()
    wait(lambda: page.running is None and page.stack.get_visible_child_name() == "results", scanned, 60,
         "System Junk scan")


def scan_tools_test(win, report, wait, finish):
    """System Junk in a throwaway home: Stop ends a slow scan (a `snap` that hangs) with what was checked, and a
    new scan works at once; Ctrl+F filters items and their parts; the confirmation says where each item goes;
    Never clean takes an old folder of Downloads out for good; after a clean, its summary stays until a new scan."""
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home, bin_dir = os.path.join(sandbox, "home"), os.path.join(sandbox, "bin")
    trip = os.path.join(home, "Downloads", "Trip")
    os.makedirs(trip)
    os.makedirs(bin_dir)
    old = time.time() - 120 * 86400  # older than Old downloads' 90 days
    pictures = os.path.join(home, "Pictures")  # Old screenshots, for Never Clean in the ⓘ popover
    os.makedirs(pictures)
    for path, size in ((os.path.join(trip, "a.jpg"), 4000), (os.path.join(home, "Downloads", "notes.pdf"), 3000),
                       (os.path.join(pictures, "Screenshot from 2025-01-02.png"), 2000)):
        with open(path, "wb") as f:
            f.write(b"\0" * size)
        os.utime(path, (old, old))
    os.utime(trip, (old, old))
    real_pgrep = shutil.which("pgrep", path="/usr/bin:/bin")
    stubs = {"snap": '#!/bin/sh\necho $$ >"$HOME/snap.pid"\nexec sleep 20\n'}  # Old Snap revisions hangs
    if real_pgrep:  # the engine stops a scan's workers through `pgrep -P`; the tests stub pgrep out
        stubs["pgrep"] = f'#!/bin/sh\n[ "$1" = -P ] && exec {real_pgrep} "$@"\nexit 1\n'
    for name, text in stubs.items():
        with open(os.path.join(bin_dir, name), "w") as f:
            f.write(text)
        os.chmod(os.path.join(bin_dir, name), 0o755)
    env = {"HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"), "CLEANMATE_NO_UPDATE_CHECK": "1",
           "PATH": bin_dir + ":" + os.environ.get("PATH", "/usr/bin:/bin")}
    pid_file = os.path.join(home, "snap.pid")
    as_root = os.geteuid() == 0

    win.show_page("system")
    page = win.pages["system"]
    real_engine = page.engine
    page.engine = Engine(real_engine.path, dry_run=False, env=env)
    started = []

    def done():
        if os.path.exists(pid_file):  # never leave the hanging stub behind
            try:
                os.kill(int(open(pid_file).read()), 9)
            except (ValueError, OSError):
                pass
        page.search_bar.set_search_mode(False)
        page.engine = real_engine
        shutil.rmtree(sandbox, ignore_errors=True)
        maintenance_test(win, report, wait, finish)

    def idle():
        return page.running is None and page.stack.get_visible_child_name() in ("results", "start")

    def hanging():
        GLib.timeout_add(1500, lambda: (stop(), False)[1])  # the quick items are done by then

    def stop():
        started.append(time.monotonic())
        page.stop()
        wait(idle, stopped, 30, "the stopped scan")

    def stopped():
        took = time.monotonic() - started[0]
        report(page.stopped and took < 4.5 and "snap_old" not in page.items
               and page.items.get("old_downloads", {}).get("status") == "found",
               f"Stop ends the scan in {took:.1f}s and lists the items it checked")
        report(page.scan_header.get_last_child().get_label()
               == _("The scan was stopped: items it hadn't checked yet are not listed."),
               "the results say the scan was stopped")
        pid = int(open(pid_file).read()) if os.path.exists(pid_file) else 0
        wait(lambda: not real_pgrep or not alive(pid), rescan, 5, "the hanging scan's process to end")

    def alive(pid):
        try:
            with open(f"/proc/{pid}/stat") as f:
                return f.read().rsplit(")", 1)[1].split()[0] != "Z"
        except (OSError, IndexError):
            return False

    def rescan():
        report(True, "Stop leaves no scan process behind")
        os.remove(os.path.join(bin_dir, "snap"))
        os.remove(pid_file)
        page.scan()
        wait(lambda: idle() and page.stack.get_visible_child_name() == "results", search, 60, "the scan after Stop")

    def search():
        report(not page.stopped and page.scan_info.get("stopped") is False and "old_downloads" in page.item_rows,
               "a new scan right after Stop checks everything")
        info = page.scan_info
        took = ngettext("{n} location scanned in {secs}s", "{n} locations scanned in {secs}s", info.get("locations", 0),
                        secs=f"{info.get('durationMs', -1000) / 1000:.1f}")
        report(page.scan_header.get_first_child().get_next_sibling().get_label() == took,
               "the results show how long the scan took")
        report(win.get_application().get_accels_for_action("win.find") == ["<Control>f"],
               "Ctrl+F is bound to searching the results")
        page.find()  # what Ctrl+F does on this page
        report(page.search_bar.get_search_mode(), "Ctrl+F opens the search of the results")
        page.search_entry.set_text("old_downloads")
        page.apply_filter()
        shown = {i for i, row in page.item_rows.items() if row.get_visible()}
        report(shown == {"old_downloads"}, "the search keeps only the matching item")
        page.item_rows["old_downloads"].set_expanded(True)
        wait(lambda: "old_downloads" in page.entries, parts, 30, "the parts of Old downloads")

    def parts():
        rows = page.entry_rows.get("old_downloads", {})
        page.search_entry.set_text("trip")
        page.apply_filter()
        report(page.item_rows["old_downloads"].get_visible() and rows.get("Trip") and rows["Trip"].get_visible()
               and rows.get("notes.pdf") and not rows["notes.pdf"].get_visible(),
               "the search finds a part by name and hides the others")
        page.search_entry.set_text("no-such-thing-at-all")
        page.apply_filter()
        report(page.no_match.get_visible() and not any(r.get_visible() for r in page.item_rows.values()),
               "a search with no match says so")
        page.search_bar.set_search_mode(False)
        page.apply_filter()
        report(page.search_entry.get_text() == "" and page.item_rows["old_downloads"].get_visible()
               and rows["notes.pdf"].get_visible(), "closing the search shows everything again")
        menu = [w for w in walk(rows["Trip"]) if isinstance(w, Gtk.MenuButton)]
        report(len(menu) == 1 and not any(isinstance(w, Gtk.MenuButton) for w in walk(rows["notes.pdf"])),
               "a folder part offers Never clean, a file doesn't")
        confirm()

    def confirm():
        saved = dict(page.selected)
        other = next((i for i in ("tmp", "apt_cache") if i in page.items), None)
        page.selected = {"old_downloads": True, **({other: True} if other else {})}
        page.confirm_clean()
        kinds = dict(page.confirm_rows)
        report(kinds.get("old_downloads") == "trash" and (not other or kinds.get(other) == "delete"),
               "the confirmation marks each item: to the Trash or deleted permanently")
        page.confirm_dialog.close()
        page.selected = saved
        if as_root:
            report(True, "Never clean and the real clean skipped: as root the engine refuses home items")
            return done()
        page.never_clean("old_downloads", "Trip")
        wait(lambda: page.excluding is None, excluded, 30, "Never clean")

    def excluded():
        listed = os.path.join(home, ".config", "cleanmate", "exclude")
        text = open(listed).read() if os.path.exists(listed) else ""
        report(trip in text.splitlines() and "Trip" not in page.entry_rows["old_downloads"],
               "Never clean adds the folder to Settings › Never clean and takes it off the list")
        page.scan()
        wait(lambda: idle() and page.stack.get_visible_child_name() == "results", rescanned, 60, "the scan after Never clean")

    def rescanned():
        page.item_rows["old_downloads"].set_expanded(True)
        wait(lambda: "old_downloads" in page.entries, cleanable, 30, "the parts of Old downloads")

    def cleanable():
        ids = sorted(x["id"] for x in page.entries["old_downloads"])
        report(ids == ["notes.pdf"], "a new scan leaves the Never clean folder out")
        page.clean(["old_downloads"])
        wait(lambda: page.clean_summary is not None and idle()
             and page.stack.get_visible_child_name() == "results", summary, 60, "the clean of Old downloads")

    def summary():
        s = page.clean_summary
        report(s["cleaned"] == 1 and s["trash"] == 1 and s["deleted"] == 0 and len(s["keys"]) == 1
               and page.summary_row.get_parent() is not None and page.summary_undo is not None
               and page.summary_undo.get_visible() and os.path.isdir(trip),
               "after the clean a summary stays on the results: 1 item, to the Trash, with Undo")
        page.scan()
        wait(lambda: idle() and page.stack.get_visible_child_name() == "results", rescanned_after, 60, "a new scan")

    def rescanned_after():
        report(page.clean_summary is None, "a new scan clears the summary")
        e = page.items.get("old_screenshots", {})
        report(e.get("status") == "found" and e["why"]["folders"] == [pictures], "Old screenshots are found, in Pictures")
        if e.get("status") != "found":
            return done()
        page.never_clean_item("old_screenshots", e["why"]["folders"])
        wait(lambda: page.excluding is None, item_excluded, 30, "Never clean on an item")

    def listed():
        path = os.path.join(home, ".config", "cleanmate", "exclude")
        return open(path).read().splitlines() if os.path.exists(path) else []

    def item_excluded():
        report(pictures in listed() and not page.item_rows["old_screenshots"].get_visible()
               and not page.selected["old_screenshots"],
               "Never Clean in the ⓘ popover adds the item's folder to Settings › Never clean and hides the item")
        page.scan()
        wait(lambda: idle() and page.stack.get_visible_child_name() == "results", scan_without, 60, "the scan after Never Clean")

    def scan_without():
        report(page.items.get("old_screenshots", {}).get("status") != "found", "a new scan leaves the item out")
        page.allow_clean_all([pictures])
        wait(lambda: pictures not in listed() and idle()
             and page.items.get("old_screenshots", {}).get("status") == "found",
             allowed, 60, "Undo of Never Clean")

    def allowed():
        report(True, "Undo takes the folder out of Never clean and the item is found again")
        done()

    page.scan()
    wait(lambda: os.path.exists(pid_file) or idle(), hanging, 60, "the slow scan to start")


def walk(widget):
    """Every widget under WIDGET."""
    child = widget.get_first_child()
    while child:
        yield child
        yield from walk(child)
        child = child.get_next_sibling()


MAINT_STUBS = {  # tools of Update everything and Rebuild font cache; each logs what it was asked to do
    "fc-cache": '#!/bin/sh\necho "fc-cache $*" >>"$HOME/ran.log"\necho "fonts cached"\n',
    "apt-get": '#!/bin/sh\necho "apt-get $*" >>"$HOME/ran.log"\necho "apt-get $1 output"\n',
    "snap": '#!/bin/sh\n[ "$1" = get ] && exit 0\necho "snap $*" >>"$HOME/ran.log"\n',
    "flatpak": '#!/bin/sh\necho "flatpak $*" >>"$HOME/ran.log"\n',
    "sudo": '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n',  # credentials cached
    "pkexec": '#!/bin/sh\necho "pkexec $*" >>"$HOME/pkexec.log"\nexec "$@"\n',  # the password was right
}


def maintenance_test(win, report, wait, finish):
    """Maintenance with stub tools in a throwaway home: a missing tool locks its row, Rebuild font cache runs
    as you with its output in the log dialog, Update everything asks for the password once."""
    from .engine import Engine
    from .maintenance import MISSING
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home, bin_dir = os.path.join(sandbox, "home"), os.path.join(sandbox, "bin")
    for d in (home, bin_dir):
        os.makedirs(d)
    for name, text in MAINT_STUBS.items():
        with open(os.path.join(bin_dir, name), "w") as f:
            f.write(text)
        os.chmod(os.path.join(bin_dir, name), 0o755)
    env = {"HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"), "CLEANMATE_NO_UPDATE_CHECK": "1",
           "PATH": bin_dir + ":" + os.environ.get("PATH", "/usr/bin:/bin")}

    def read(name):
        path = os.path.join(home, name)
        return open(path).read() if os.path.exists(path) else ""

    win.show_page("maintenance")
    page = win.pages["maintenance"]
    real_engine = page.engine

    def idle():
        return not page.busy

    def done():
        if page.log:
            page.log.close()
        page.engine = real_engine
        shutil.rmtree(sandbox, ignore_errors=True)
        overview_test(win, report, wait, finish)

    def first():
        report(len(page.rows) == 9, f"Maintenance lists the terminal app's 9 tasks: {sorted(page.rows)}")
        page.engine = Engine(real_engine.path, dry_run=False, env=env)
        page.engine.root_ok = True  # as the package's /usr/bin/cleanmate (root's); a copy you can change: held()
        page.load()
        wait(idle, listed, 60, "maintenance list")

    def listed():
        items = [dict(m) for m in page.items.values()]
        report(all(page.controls[m["id"]].get_sensitive() == m["available"] for m in items),
               "only items whose tool is installed can run")
        ctrl_f(win)
        page.find_bar.entry.set_text("fonts")
        page.apply_filter()
        report(page.find_bar.get_search_mode() and page.rows["fonts"].get_visible()
               and not page.rows["update"].get_visible(), "Ctrl+F in Maintenance keeps the matching task")
        page.find_bar.set_search_mode(False)
        page.apply_filter()
        report(all(row.get_visible() for row in page.rows.values()), "closing the search lists every task again")
        for m in items:
            if m["id"] == "locate":
                m.update(available=False, reason="locate/plocate is not installed.")
        page.show_results(items)
        report(not page.controls["locate"].get_sensitive()
               and page.rows["locate"].get_subtitle() == MISSING["locate"], "a missing tool locks the row with why")
        from .engine import PACKAGE_NEEDED
        page.engine.root_ok = False  # a copy you can change: no task that needs root can run
        page.show_results(items)
        held = sorted(m["id"] for m in items if m["available"] and not page.controls[m["id"]].get_sensitive()
                      and page.rows[m["id"]].get_subtitle() == PACKAGE_NEEDED)
        root_items = sorted(m["id"] for m in items if m["available"] and m["root"])
        report(held == root_items and page.controls["fonts"].get_sensitive(),
               f"not installed from a package: the tasks that need root are locked and say why: {held}")
        page.engine.root_ok = True
        page.show_results(items)
        page.start(page.items["fonts"])
        wait(idle, fonts_done, 60, "Rebuild font cache")

    def fonts_done():
        title = _("Rebuild font cache")
        if os.geteuid() == 0:
            report(_("This task runs as you, not as root.") in page.log.text(), "as root the engine refuses the font cache")
        else:
            report("fonts cached" in page.log.text() and "fc-cache -f" in read("ran.log")
                   and page.log.status.get_text() == _("{title}: done").format(title=title)
                   and page.log.get_can_close() and not read("pkexec.log"),
                   "Rebuild font cache runs as you; the log shows its output, then done")
        page.log.close()
        page.start(page.items["update"])  # the confirmation itself needs a click
        wait(idle, updated, 60, "Update everything")

    def updated():
        calls = read("pkexec.log").splitlines()
        ran = read("ran.log")
        flatpak = os.geteuid() == 0 or "flatpak update -y --noninteractive" in ran
        report(len(calls) == 1 and "--polkit=maintenance --json maintain update" in calls[0] and "apt-get update" in ran
               and "apt-get upgrade -y" in ran
               and flatpak and "apt-get update output" in page.log.text(),
               f"Update everything asks for the password once, then runs your flatpak part: {calls}")
        wait(idle, done, 30, "list after updating")

    wait(idle, first, 60, "first maintenance list")


OVERVIEW_DF = """#!/bin/sh
case "$*" in
  *target*) printf 'Mounted on Size Used Avail Type Filesystem\\n/ 100000000000 95000000000 5000000000 ext4 /dev/sda2\\n/boot/efi 1000000000 100000000 900000000 vfat /dev/sda1\\n' ;;
  *fstype*) printf 'Size Used Avail Type\\n100000000000 90000000000 5000000000 ext4\\n' ;;
  *used,source*) printf 'Used Filesystem\\n95000000000 /dev/sda2\\n95000000000 /dev/sda2\\n' ;;
  *) printf 'Size Avail\\n100000000000 5000000000\\n' ;;
esac
"""


def overview_test(win, report, wait, finish):
    """System Overview with a fake df, swapon and a slow du: a 95 % full disk gets the warning colour, the
    page shows before the folder sizes arrive, space outside your folders and the largest folders follow,
    Refresh picks up a cleanup and free-space history recorded meanwhile, a large folder opens in
    Space Lens, and System protection (a fake /etc and /sys) shows each check last, with a command to copy
    when one is off."""
    from .engine import Engine, human
    from .overview import FreedPanel, last_scan_text
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home, bin_dir = os.path.join(sandbox, "home"), os.path.join(sandbox, "bin")
    videos, projects = os.path.join(home, "Videos"), os.path.join(home, "Projects")
    sysroot = os.path.join(sandbox, "root")
    for d in (home, bin_dir, videos, projects, os.path.join(sysroot, "etc", "ufw"),
              os.path.join(sysroot, "etc", "apt", "apt.conf.d"), os.path.join(sysroot, "sys", "module", "apparmor",
                                                                              "parameters")):
        os.makedirs(d)
    for path, text in (("etc/ufw/ufw.conf", "ENABLED=no\n"), ("sys/module/apparmor/parameters/enabled", "Y\n")):
        with open(os.path.join(sysroot, path), "w") as f:  # ufw off, AppArmor on, no unattended-upgrades, no UEFI
            f.write(text)
    for path, size in ((os.path.join(videos, "film.mkv"), 40 << 20), (os.path.join(projects, "app.bin"), 5 << 20)):
        with open(path, "wb") as f:  # sparse: no real disk use
            f.truncate(size)
    stubs = {"df": OVERVIEW_DF,
             "swapon": '#!/bin/sh\nprintf "/swap.img file 2147483648\\n"\n',
             "du": f'#!/bin/sh\nsleep 1\nexec {shutil.which("du") or "/usr/bin/du"} "$@"\n'}  # folders take a while
    for name, text in stubs.items():
        with open(os.path.join(bin_dir, name), "w") as f:
            f.write(text)
        os.chmod(os.path.join(bin_dir, name), 0o755)
    env = {"HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"), "CLEANMATE_NO_UPDATE_CHECK": "1",
           "CLEANMATE_SYSROOT": sysroot, "PATH": bin_dir + ":" + os.environ.get("PATH", "/usr/bin:/bin")}

    win.show_page("overview")
    page = win.pages["overview"]
    real_engine = page.engine

    def idle():
        return not page.busy

    def done():
        page.engine = real_engine
        shutil.rmtree(sandbox, ignore_errors=True)
        bug_report_test(win, report, wait, finish)

    def first():
        report("system" in page.data and page.stack.get_visible_child_name() == "results",
               f"System Overview shows this computer ({len(page.data.get('disk', []))} disks)")
        page.engine = Engine(real_engine.path, dry_run=False, env=env)
        page.refresh_button.emit("clicked")
        wait(idle, listed, 60, "overview")

    def listed():
        full, boot = page.bars.get("disk:/"), page.bars.get("disk:/boot/efi")
        report(full is not None and boot is not None and full.has_css_class("almost-full")
               and not boot.has_css_class("almost-full"), "a disk over 90 % full gets the warning colour")
        report(page.render_ms is not None and page.render_ms < 300,
               f"the page shows in under 300 ms once the engine answers ({page.render_ms:.0f} ms)")
        report(page.first_before_folders and page.full_ms - page.first_ms >= 900,
               f"system and disks show before the folder sizes: after {page.first_ms:.0f} ms, "
               f"folder sizes after {page.full_ms:.0f} ms (du takes 1 s here)")
        report(page.freed is None and bool(page.groups["freed"].get_description()),
               "no Freed numbers before the first cleanup, only a note")
        report(page.chart is None and "history" in page.groups, "one day of free-space history: a note, no chart yet")
        report(page.smart_button.get_label() == _("Run Smart Scan") and page.smart_button.has_css_class("suggested-action")
               and page.rows["smart"].get_subtitle() == last_scan_text(0)
               and page.results.get_first_child().get_next_sibling() is page.rows["smart"].get_ancestor(
                   Adw.PreferencesGroup),
               "System Overview opens with Run Smart Scan under its title (its label is its name for screen readers); "
               "never scanned here")
        report("outside:reserved:/" in page.rows and "outside:swapfile:/swap.img" in page.rows,
               "space outside your folders: ext4 reserved space and the swap file")
        beyond, opened_at = page.rows.get("outside_home"), []
        widgets = [beyond.get_first_child()] if beyond is not None else []
        while widgets:
            w = widgets.pop()
            if isinstance(w, Gtk.Button) and w.get_label() == _("View in Space Lens"):
                real_open = win.open_lens
                win.open_lens = opened_at.append  # not a whole-disk measurement of this computer
                w.emit("clicked")
                win.open_lens = real_open
            widgets += [c for c in (w.get_next_sibling(), w.get_first_child()) if c]
        home_bytes = page.data.get("top_dirs", {}).get("home_bytes") or 0
        report(beyond is not None and beyond.get_title() == _("Outside your home folder") and opened_at == ["/"]
               and page.data["top_dirs"].get("outside_home") == 95000000000 - home_bytes,
               f"outside your home folder: the system disk's use minus home, View in Space Lens opens / ({opened_at})")
        tops = [k[len("top:"):] for k in page.rows if k.startswith("top:")]
        report(tops[:2] == [videos, projects], f"largest folders, biggest first: {[os.path.basename(t) for t in tops]}")
        protect = {k[len("protect:"):]: r for k, r in page.rows.items() if k.startswith("protect:")}
        report(list(protect) == ["firewall", "apparmor", "updates", "secureboot"]
               and page.results.get_last_child() is page.groups.get("protection"),
               f"System protection is the last group, one row per check: {list(protect)}")
        firewall, apparmor = protect.get("firewall"), protect.get("apparmor")
        report(firewall is not None and firewall.get_subtitle().endswith("\nsudo ufw enable")
               and "sudo apt install unattended-upgrades" in protect["updates"].get_subtitle()
               and "\n" not in apparmor.get_subtitle() and "sudo" not in protect["secureboot"].get_subtitle(),
               "a check that is off shows the command that turns it on; one that is on or not applicable doesn't")
        buttons = []
        child = firewall.get_first_child() if firewall else None
        stack = [child] if child else []
        while stack:
            w = stack.pop()
            if isinstance(w, Gtk.Button) and w.get_icon_name() == "edit-copy-symbolic":
                buttons.append(w)
            if w.get_next_sibling():
                stack.append(w.get_next_sibling())
            if w.get_first_child():
                stack.append(w.get_first_child())
        copied = []
        if buttons:
            buttons[0].emit("clicked")
            def on_text(clipboard, result):
                try:
                    copied.append(clipboard.read_text_finish(result))
                except GLib.Error as error:
                    copied.append(error.message)
            page.get_clipboard().read_text_async(None, on_text)
        else:
            copied.append(None)
        wait(lambda: copied, lambda: copy_done(len(buttons), copied[0]), 10, "clipboard")

    def copy_done(n_buttons, copied):
        report(n_buttons == 1 and copied == "sudo ufw enable", f"Copy puts the command on the clipboard: {copied!r}")
        state = os.path.join(home, ".local", "state", "cleanmate")
        os.makedirs(state, exist_ok=True)
        with open(os.path.join(state, "cleanups.tsv"), "w") as f:
            f.write(f"{int(time.time()) - 86400}\t2147483648\t1073741824\n")  # freed, moved to the Trash
        with open(os.path.join(state, "stats"), "w") as f:
            f.write(f"lifetime=2147483648\nlifetime_trash=1073741824\nruns=1\nlast_time={int(time.time()) - 86400}\n"
                    "last_freed=2147483648\nlast_trash=1073741824\n")
        days = [time.strftime("%Y-%m-%d", time.localtime(time.time() - n * 86400)) for n in (14, 7)]
        with open(os.path.join(state, "disk-history.tsv"), "w") as f:
            f.write(f"{days[0]}\t9000000000\t100000000000\n{days[1]}\t7000000000\t100000000000\n")
        page.freed_shown = False  # the self-test's own cleanup may have shown the numbers already
        page.refresh_button.emit("clicked")
        wait(lambda: idle() and page.freed is not None and "top:" + videos in page.rows, refreshed, 60, "refresh")

    def refreshed():
        animated = page.freed.animated
        report(animated == Gtk.Settings.get_default().get_property("gtk-enable-animations"),
               f"the Freed numbers count up the first time they show, when animations are on ({animated})")
        wait(lambda: not page.freed.animating, counted, 10, "count up")

    def counted():
        freed = page.freed
        scans = []
        win.start_smart_scan = lambda: scans.append(1)  # a real one would scan this computer
        page.smart_button.emit("clicked")
        del win.start_smart_scan
        report(page.rows["smart"].get_subtitle() == _("Last scan: yesterday") and scans == [1],
               f"after yesterday's cleanup: {page.rows['smart'].get_subtitle()!r}; the button starts Smart Scan")
        numbers = {k: label.get_label() for k, (label, _v) in freed.numbers.items()}
        report(numbers == {"freed30": human(2147483648), "lifetime": human(2147483648), "last": human(2147483648)},
               f"Refresh shows what was freed: 30 days, in total, the last cleanup ({numbers})")
        trash = {k: label.get_label() for k, label in freed.trash_lines.items()}
        in_trash = _("{size} in the Trash").format(size=human(1073741824))
        report(trash == {"freed30": in_trash, "lifetime": in_trash, "last": in_trash},
               f"what the cleanups moved to the Trash is shown apart under each number ({trash})")
        days = freed.chart.days if freed.chart else []
        report(len(days) == 30 and [i for i, d in enumerate(days) if d["cleanups"]] == [28]
               and human(2147483648) in freed.chart.day_text(28) and freed.chart.day_text(0) != freed.chart.day_text(28)
               and freed.chart.bars(300, 120)[28] is not None and freed.chart.bars(300, 120)[0] is None,
               "freed per day: 30 days, a bar for yesterday's cleanup with its date and size")
        settings = Gtk.Settings.get_default()
        was = settings.get_property("gtk-enable-animations")
        settings.set_property("gtk-enable-animations", False)
        still = FreedPanel(page.data["freed"], animate=True)
        settings.set_property("gtk-enable-animations", was)
        report(not still.animated and still.numbers["lifetime"][0].get_label() == human(2147483648),
               "with animations off the Freed numbers show their value at once")
        page.refresh_button.emit("clicked")
        wait(lambda: idle() and page.freed is not None and "top:" + videos in page.rows, refreshed_again, 60,
             "second refresh")

    def refreshed_again():
        report(not page.freed.animated and page.freed.numbers["freed30"][0].get_label() == human(2147483648),
               "Refresh doesn't count up again")
        chart = page.chart
        report(chart is not None and [p["avail"] for p in chart.points] == [9000000000, 7000000000, 5000000000]
               and human(7000000000) in chart.point_text(1), "free-space history: a chart of three days with a "
               "date and value per day")
        page.rows["top:" + videos].activate()
        lens = win.pages["lens"]
        wait(lambda: lens.running is None and lens.folder == videos, lambda: opened(lens), 60, "Space Lens folder")

    def opened(lens):
        report(win.content_stack.get_visible_child_name() == "lens"
               and any(os.path.basename(e["path"]) == "film.mkv" for e in lens.entries),
               "a click on a large folder opens it in Space Lens")
        lens.set_root(os.path.expanduser("~"))
        win.show_page("overview")
        win.select_sidebar("overview")
        done()

    wait(idle, first, 60, "first overview")


def read_clipboard(win, wait, then):
    """then(text) with what the clipboard holds."""
    got = []

    def on_text(clipboard, result):
        try:
            got.append(clipboard.read_text_finish(result))
        except GLib.Error as error:
            got.append(error.message)
    win.get_clipboard().read_text_async(None, on_text)
    wait(lambda: got, lambda: then(got[0]), 10, "clipboard")


def bug_report_test(win, report, wait, finish):
    """Report a Bug… with a throwaway home whose activity log names personal files and the user: the preview
    shows the system details without them, Open GitHub opens the prefilled issue (through a stub, nothing
    opens), a report too long for a link is copied and the bare template opens; Suggest a Feature… opens the
    feature template and Share CleanMate copies the website link."""
    from urllib.parse import parse_qs, urlsplit

    from . import bugreport as B
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home = os.path.join(sandbox, "home", "alexsmith")
    log = os.path.join(home, ".local", "state", "cleanmate", "clean.log")
    os.makedirs(os.path.dirname(log))
    with open(log, "w") as f:
        f.write(f"2026-01-01 08:00:00 GUI cleanup finished — 2.0 MB freed (dry-run=0)\n"
                f"2026-01-02 03:04:05 trash {home}/Documents/taxes 2025.pdf\n"
                f"2026-01-02 03:04:06 rm -rf -- {home}/.cache/thumbnails\n"
                f"2026-01-02 03:04:07 trash /home/bob/.cache/x\n"
                f"2026-01-02 03:04:08 startup: removed alexsmith-sync.desktop\n"
                f"2026-01-03 10:00:00 Cleanup finished — 1.0 MB freed (dry-run=0)\n")
    env = {"HOME": home, "USER": "alexsmith", "XDG_CONFIG_HOME": os.path.join(home, ".config"),
           "XDG_STATE_HOME": os.path.join(home, ".local", "state"), "CLEANMATE_NO_UPDATE_CHECK": "1"}
    real_engine, real_open = win.engine, win._open_url
    opened = []
    win._open_url = opened.append
    win.engine = Engine(real_engine.path, dry_run=True, env=env)
    win.report_dialog = None
    menu = [win.lookup_action(a) is not None for a in ("report-bug", "suggest", "share")]
    report(all(menu), "the main menu has Report a Bug…, Suggest a Feature… and Share CleanMate")
    if i18n.translating():
        report(all(_(t) != t for t in ("Report a Bug…", "Suggest a Feature…", "Share CleanMate")),
               f"the menu items are translated: {_('Report a Bug…')}")

    def done():
        win.engine, win._open_url = real_engine, real_open
        shutil.rmtree(sandbox, ignore_errors=True)
        welcome_test(win, report, wait, finish)

    def preview_text(dialog):
        buf = dialog.get_extra_child().get_child().get_buffer()
        return buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)

    def shown():
        dialog = win.report_dialog
        text = preview_text(dialog)
        lines = text.splitlines()
        report(lines[0] == "CleanMate: " + real_engine.version() != "CleanMate: ?" and any(line.startswith("System: ") for line in lines)
               and any(line.startswith("Installed with: ") for line in lines)
               and "Recent activity (last 5, oldest first):" in lines, "the preview shows the system details and "
               "the last 5 activity lines")
        leaks = [s for s in (home, sandbox, os.path.expanduser("~"), "/home/bob", "alexsmith", "taxes", "2025.pdf")
                 if s in text]
        report(not leaks and "~/.cache/thumbnails" in text and "~/(file or folder)" in text
               and "/home/<user>/.cache/x" in text and "<user>-sync.desktop" in text,
               f"no home folder, user name or personal file name in the report (found: {leaks})")
        dialog.emit("response", "open")
        dialog.force_close()
        url = opened[-1] if opened else ""
        query = parse_qs(urlsplit(url).query)
        report(url.startswith(B.REPO_URL + "/issues/new?template=bug_report.yml&system=")
               and query.get("system") == [text] and "+" not in url and len(url) <= B.MAX_LINK,
               f"Open GitHub opens a new issue with System details filled in ({len(url)} characters)")
        long_body = text + "\n" + "é" * 3000
        notice = B.open_report(win, long_body)
        read_clipboard(win, wait, lambda copied: too_long(notice, long_body, copied))

    def too_long(notice, long_body, copied):
        n = len(opened)
        notice.emit("response", "open")
        notice.force_close()
        report(copied == long_body and len(opened) == n + 1
               and opened[-1] == B.REPO_URL + "/issues/new?template=bug_report.yml",
               "a report too long for a link is copied and the empty bug template opens")
        B.suggest_feature(win)
        report(opened[-1] == B.REPO_URL + "/issues/new?template=feature_request.yml",
               "Suggest a Feature… opens the feature template")
        win.activate_action("win.share", None)
        read_clipboard(win, wait, shared)

    def shared(copied):
        report(copied == B.WEBSITE_URL, f"Share CleanMate copies the website link: {copied!r}")
        done()

    win.activate_action("win.report-bug", None)
    wait(lambda: win.report_dialog is not None, shown, 60, "the bug report preview")


def welcome_test(win, report, wait, finish):
    """The welcome of a throwaway home with a fake `systemctl --user`: new until closed once; Next and Back move
    through the three steps; step 2 opens the terminal app (stubbed); step 3 turns automatic cleaning and the
    scan reminder on (their timers come on) and changes the low disk alert, which Settings then shows; its last
    button, Run Smart Scan, closes it, saves welcome_shown and goes to Smart Scan (stubbed); Getting Started… in the main menu opens it again and saves nothing."""
    from . import welcome as W
    from .engine import Engine
    from .settings import LOW_DISK
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home, bin_dir = os.path.join(sandbox, "home"), os.path.join(sandbox, "bin")
    config = os.path.join(home, ".config")
    settings_file = os.path.join(config, "cleanmate", "settings")
    units = os.path.join(config, "systemd", "user")
    timer, check_timer = os.path.join(units, "cleanmate.timer"), os.path.join(units, "cleanmate-check.timer")
    os.makedirs(bin_dir)
    with open(os.path.join(bin_dir, "systemctl"), "w") as f:
        f.write('#!/bin/sh\nshift\nmkdir -p "$HOME/enabled"\ncase $1 in is-enabled) test -e "$HOME/enabled/$3" ;; '
                'enable) touch "$HOME/enabled/$3" ;; disable) rm -f "$HOME/enabled/$3" ;; esac\n')
    os.chmod(os.path.join(bin_dir, "systemctl"), 0o755)
    env = {"HOME": home, "XDG_CONFIG_HOME": config, "XDG_STATE_HOME": os.path.join(home, ".local", "state"),
           "CLEANMATE_NO_UPDATE_CHECK": "1", "PATH": bin_dir + ":" + os.environ.get("PATH", "/usr/bin:/bin")}
    root = os.geteuid() == 0  # the engine refuses settings: the steps work, the options say why they're missing
    real_engine, real_terminal = win.engine, win.open_terminal
    terminals, scans = [], []
    win.open_terminal = lambda *_a: terminals.append(1)
    win.start_smart_scan = lambda: scans.append(1)
    win.engine = Engine(real_engine.path, dry_run=False, env=env)
    report(W.is_new(config), "with new settings the welcome is shown")
    report(win.lookup_action("welcome") is not None, "the main menu has Getting Started…")

    def closes(welcome):
        """Headless (no browser on the display) a dialog never finishes closing: count the close and send
        `closed` as libadwaita does once it's gone."""
        welcome.closes = 0

        def close():
            welcome.closes += 1
            welcome.emit("closed")
            return True
        welcome.close = close
        return welcome

    dialog = closes(win.show_welcome(first_run=True))
    page = dialog.options

    def idle():
        return not page.busy()

    def saved():
        try:
            with open(settings_file) as f:
                return f.read()
        except OSError:
            return ""

    def enabled(name):
        return os.path.exists(os.path.join(home, "enabled", name))

    def closed(welcome):
        return welcome.closes > 0

    def at(n):
        return lambda: dialog.index == n and abs(dialog.carousel.get_position() - n) < 0.01

    def done():
        win.engine, win.open_terminal = real_engine, real_terminal
        del win.start_smart_scan
        shutil.rmtree(sandbox, ignore_errors=True)
        flatpak_welcome_test(win, report, wait, finish)

    def step1():
        report(not dialog.back.get_visible() and dialog.skip.get_visible() and dialog.next.get_label() == _("Next"),
               "the welcome opens on step 1 with Next and Skip")
        dialog.next.emit("clicked")
        wait(at(1), step2, 10, "welcome step 2")

    def step2():
        report(dialog.back.get_visible(), "Next goes to step 2, Back shows")
        dialog.terminal_button.emit("clicked")
        report(terminals == [1], "step 2 opens the terminal app")
        dialog.next.emit("clicked")
        wait(at(2), step3, 10, "welcome step 3")

    def step3():
        report(not dialog.skip.get_visible() and dialog.next.get_label() == _("Run Smart Scan"),
               "step 3 ends with Run Smart Scan")
        wait(idle, options, 30, "welcome options")

    def options():
        if root:
            report("schedule" not in page.rows, "as root the welcome's options say settings are per user")
            dialog.close()
            return wait(lambda: closed(dialog), done, 10, "welcome closed")
        report(sorted(page.rows) == sorted(W.OPTIONS) and page.rows["schedule"].get_selected() == 0
               and page.rows["remind"].get_selected() == 0 and page.rows["language"].get_selected() == 0,
               "step 3 shows language, automatic cleaning, scan reminder and low disk alert")
        page.rows["schedule"].set_selected(1)  # daily
        page.rows["remind"].set_selected(2)  # monthly
        page.rows["low_disk_pct"].set_selected(page.rows["low_disk_pct"].values.index(LOW_DISK[3]))
        wait(idle, changed, 30, "welcome options saved")

    def changed():
        text = open(timer).read() if os.path.exists(timer) else ""
        report("OnCalendar=daily" in text and enabled("cleanmate.timer") and "remind=monthly" in saved()
               and f"low_disk_pct={LOW_DISK[3]}" in saved() and enabled("cleanmate-check.timer")
               and os.path.exists(check_timer), "the welcome turns automatic cleaning daily and the scan reminder on "
               "(both timers) and saves the low disk alert")
        settings = win.show_settings()
        wait(lambda: not win.settings_page.busy(), lambda: read_back(settings), 30, "settings")

    def read_back(settings):
        rows = win.settings_page.rows
        report(rows["schedule"].get_selected() == 1 and rows["remind"].get_selected() == 2
               and rows["low_disk_pct"].values[rows["low_disk_pct"].get_selected()] == LOW_DISK[3],
               "Settings reads back what the welcome saved")
        settings.close()
        page.rows["schedule"].set_selected(0)
        wait(idle, schedule_off, 30, "automatic cleaning off")

    def schedule_off():
        report(not os.path.exists(timer) and not enabled("cleanmate.timer"), "Off in the welcome turns the timer off")
        dialog.back.emit("clicked")
        wait(at(1), went_back, 10, "welcome back")

    def went_back():
        report(dialog.skip.get_visible() and dialog.next.get_label() == _("Next"),
               "Back goes to the step before")
        dialog.next.emit("clicked")
        wait(at(2), start, 10, "welcome step 3 again")

    def start():
        report("welcome_shown" not in saved(), "the welcome isn't marked seen while it's open")
        dialog.next.emit("clicked")  # Run Smart Scan
        wait(lambda: idle() and "welcome_shown=1" in saved(), started, 30, "welcome closed")

    def started():
        report(not W.is_new(config) and closed(dialog) and scans == [1], "Run Smart Scan closes it, saves "
               "welcome_shown (it doesn't open by itself again) and goes to Smart Scan")
        before = saved()
        win.activate_action("win.welcome", None)
        again = closes(win.welcome)
        report(again is not dialog and not again.first_run, "Getting Started… opens the welcome again")
        again.skip.emit("clicked")
        wait(lambda: closed(again) and not again.options.busy(), lambda: reopened(before), 30,
             "welcome from the menu")

    def reopened(before):
        report(saved() == before, "closing it from the menu changes no setting")
        done()

    # laid out first: the carousel loses a scroll asked before it has a size
    wait(lambda: win.get_visible_dialog() is dialog and dialog.carousel.get_width() > 0, step1, 10, "the welcome")


def flatpak_welcome_test(win, report, wait, finish):
    """The welcome and Settings of the Flatpak (as with IN_FLATPAK): no terminal app, Uninstaller, password
    step, automatic cleaning or scan reminder; step 2 and Settings link to the Flatpak's limits (opened
    through a stub)."""
    from . import welcome as W
    from .engine import FLATPAK_LIMITS_URL
    from .settings import SettingsPage
    real_open = win._open_url
    opened = []
    win._open_url = opened.append
    root = os.geteuid() == 0  # the engine refuses settings: no rows to look at
    dialog = W.Welcome(win, flatpak=True)
    limits = labels(dialog.limits_row)  # names what the Flatpak hasn't
    text = "\n".join(t for step in dialog.steps[:2] for t in labels(step) if t not in limits)
    promised = [t for t in (_("What needs your password"), _("Items with a lock"), _("Uninstaller"),
                            _("The terminal app"), _("All tools (terminal)"), _("Automatic cleaning"), "sudo cm")
                if t in text]
    report(dialog.terminal_button is None and not promised, f"the Flatpak's welcome promises only what it does "
           f"(found: {promised})")
    report(_("Limits of the Flatpak") in limits and _("Large & Old Files and Duplicates") in text,
           "its step 2 links to the Flatpak's limits; step 1 shows the file tools instead of the Uninstaller")
    dialog.limits_row.emit("activated")
    report(opened == [FLATPAK_LIMITS_URL], f"the limits row opens the page about the Flatpak: {opened}")
    settings = SettingsPage(win, flatpak=True)

    def loaded():
        rows = sorted(dialog.options.rows)
        report(root or rows == sorted(W.FLATPAK_OPTIONS), f"its options are the language and the low disk alert, "
               f"no automatic cleaning or scan reminder: {rows}")
        report(root or settings.limits_row is not None and _("Limits of the Flatpak") in labels(settings),
               "Settings of the Flatpak links to its limits")
        only_open = _("A notification when the disk is almost full, only when you open CleanMate: the "
                      "Flatpak can't check in the background")
        report(root or dialog.options.rows["low_disk_pct"].get_subtitle() == only_open
               and settings.rows["low_disk_pct"].get_subtitle() == only_open,
               "the Flatpak's low disk alert says it only warns when CleanMate opens")
        win._open_url = real_open
        honest_results_test(win, report, wait, finish)

    wait(lambda: not dialog.options.busy() and not settings.busy(), loaded, 30, "the Flatpak's options")


FAKE_ENGINE = """#!/bin/bash
# the self-test's fake engine: answers COMMAND from COMMAND.jsonl (stdout), COMMAND.err (stderr), COMMAND.rc (exit)
dir=${0%/*}
shift
while [[ ${1:-} == --* ]]; do case $1 in --only) shift 2 ;; *) shift ;; esac; done
[[ -f $dir/$1.jsonl ]] && cat "$dir/$1.jsonl"
[[ -f $dir/$1.err ]] && cat "$dir/$1.err" >&2
exit "$(cat "$dir/$1.rc" 2>/dev/null || echo 0)"
"""


def honest_results_test(win, report, wait, finish):
    """What the pages say is true, with a fake engine: a scan cut off at its time limit lists its items under
    Not finished and never says the system is clean; an engine that crashes shows its reason and last lines
    with Try Again, Copy Details and Report a Bug… on Smart Scan, Large & Old Files, Duplicates and Space Lens;
    a clean splits what was freed from what is in the Trash (Empty Trash… gets it back) and shows the free
    space of / and a separate /home; an item the engine never reported on fails with its last line; an app
    that couldn't be uninstalled keeps its row and reason; System Overview measures again after a clean."""
    import json
    from . import errorview
    from . import window as W
    from .engine import NEEDS_PACKAGE, Engine, human
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    fake = os.path.join(sandbox, "cleanmate.sh")
    with open(fake, "w") as f:
        f.write(FAKE_ENGINE)
    home = os.path.join(sandbox, "home")
    os.makedirs(home)
    engine = Engine(fake, dry_run=False, env={"HOME": home, "CLEANMATE_NO_UPDATE_CHECK": "1"})
    crash = ["Scanning…", f"{home}/.cache/x: Permission denied",
             "cleanmate.sh: line 4242: RES_BYTES: unbound variable"]

    def answer(command, events=(), rc=0, err=()):
        for ext, text in (("jsonl", "".join(json.dumps(e) + "\n" for e in events)), ("rc", f"{rc}\n"),
                          ("err", "".join(line + "\n" for line in err))):
            with open(os.path.join(sandbox, f"{command}.{ext}"), "w") as f:
                f.write(text)

    smart = win.pages["smart"]
    template = next(iter(smart.items.values()), None)
    real = {}  # page → its engine
    real_disk_space = W.disk_space
    app = win.get_application()
    real_notify = app.send_notification
    app.send_notification = lambda *_a: None  # the window may not be active: the clean would notify

    def use_fake(page):
        real.setdefault(page, page.engine)
        page.engine = engine

    def done():
        for page, original in real.items():
            page.engine = original
        W.disk_space = real_disk_space
        app.send_notification = real_notify
        win.refresh_disk()
        win.show_page("smart")
        shutil.rmtree(sandbox, ignore_errors=True)
        trashed_page_test(win, report, wait, finish)

    if template is None:
        report(False, "no scanned item to model the fake scan on")
        return done()

    def item(item_id, status, size, trash=False, category=None):
        e = dict(template, id=item_id, label=f"Fake {item_id}", status=status, bytes=size, note="", selected=True,
                 locked="", entries=False, trash=trash, root=False, durationMs=120000 if status == "timeout" else 5)
        e["category"] = category or template["category"]
        return e

    # ── 1. a scan item cut off at the time limit ──
    def timed_out():
        use_fake(smart)
        answer("scan", [item("fake_slow", "timeout", 0), item("fake_ok", "clean", 0),
                        {"event": "done", "locations": 2, "durationMs": 120000, "stopped": False}])
        smart.scan()
        wait(lambda: smart.running is None and smart.stack.get_visible_child_name() == "results", timeout_shown,
             30, "the fake scan with a timed-out item")

    def timeout_shown():
        shown = labels(smart.results)
        report(_("Your system is clean") not in shown and _("The scan didn't finish") in shown,
               "a timed-out item: the header says the scan didn't finish, never that the system is clean")
        groups = [g for g, *_r in smart.group_rows if g.get_title() == _("Not finished")]
        report(len(groups) == 1 and "Fake fake_slow" in labels(groups[0])
               and _("Scan Again") in labels(groups[0]),
               "the timed-out item is listed under Not finished with Scan Again, not among the clean ones")
        clean_rows = [e["id"] for _g, _j, _m, rows in smart.group_rows for _r, e in rows]
        report(clean_rows.count("fake_slow") == 1 and "fake_ok" in clean_rows, "the clean item stays in its group")
        crashed_pages()

    # ── 2. the engine crashes on four pages ──
    def crashed_pages():
        for command in ("scan", "large", "dupes", "lens"):
            answer(command, [{"event": "progress", "done": 0, "total": 3, "current": ""}] if command == "scan"
                   else [], rc=1, err=crash)
        pages = []
        for pid in ("smart", "large", "dupes", "lens"):
            win.show_page(pid)
            page = win.pages[pid]
            use_fake(page)
            pages.append(page)
        win.pages["smart"].scan()
        win.pages["large"].search()
        from .duplicates import FILES
        win.pages["dupes"].set_mode(FILES)
        win.pages["dupes"].search()
        lens = win.pages["lens"]
        lens.load(lens.folder, fresh=True)
        wait(lambda: all(p.stack.get_visible_child_name() == "failed" for p in pages), lambda: crash_shown(pages),
             30, "the error pages")

    def crash_shown(pages):
        for page in pages:
            text = page.failed.text.get_label()
            report(page.failed.get_description() == crash[-1] and "exit status 1" in text
                   and "~/.cache/x: Permission denied" in text and home not in text,
                   f"{type(page).__name__}: an engine crash shows its reason and last lines (home folder hidden)")
            report(page.failed.copy_button.get_visible() and page.failed.report_button.get_visible(),
                   f"{type(page).__name__}: the error offers Copy Details and Report a Bug…")
        pages[1].failed.copy()
        read_clipboard(win, wait, copied)

    def copied(text):
        report(crash[-1] in text and "cm --json large" in text, "Copy Details copies the command and its last lines")
        report(errorview.pkexec_reason(127, ["Error executing command as another user: No authentication agent "
                                             "found."]) == _("Skipped — no password dialog could open (no polkit "
                                                             "authentication agent is running)")
               and errorview.pkexec_reason(126, []) == _("Skipped — no password was entered")
               and errorview.pkexec_reason(1, ["E: boom"]) is None
               and errorview.pkexec_reason(NEEDS_PACKAGE, []) == _("Skipped — needs CleanMate installed from a package"),
               "pkexec: a dismissed dialog and a missing polkit agent each say so")
        cleaned_up()

    # ── 3. a clean: two items to the Trash, one deleted; / and /home on separate disks ──
    def cleaned_up():
        win.show_page("smart")
        answer("scan", [item("fake_a", "found", 1000, trash=True), item("fake_b", "found", 2000, trash=True),
                        item("fake_c", "found", 500), item("fake_d", "found", 700),
                        {"event": "done", "locations": 4, "durationMs": 10, "stopped": False}])
        smart.scan()
        wait(lambda: smart.running is None and smart.stack.get_visible_child_name() == "results", clean_three,
             30, "the fake scan to clean")

    def clean_three():
        gb = 1 << 30
        answer("clean", [{"event": "task", "id": i, "state": "run", "info": "", "freed": 0} for i in ("fake_a",)]
               + [{"event": "task", "id": i, "state": "ok", "info": f"{human(n)} freed", "freed": n}
                  for i, n in (("fake_a", 1000), ("fake_b", 2000), ("fake_c", 500))]
               + [{"event": "done", "freed": 3500, "to_trash": 3000, "avail_before": 30 * gb, "avail_after": 30 * gb,
                   "disks": [{"mount": "/home", "before": 20 * gb, "after": 20 * gb},
                             {"mount": "/", "before": 10 * gb, "after": 10 * gb + 500}],
                   "trash": {"fake_a": ["a.deb"], "fake_b": ["b.deb"]}}])
        smart.clean(["fake_a", "fake_b", "fake_c"])
        wait(lambda: smart.clean_summary is not None, clean_done, 30, "the fake clean")

    def clean_done():
        title = smart.clean_title.get_text()
        expected = _("Freed {size}").format(size=human(500)) + " · " + _(
            "{size} in the Trash (empty the Trash to get it back)").format(size=human(3000))
        report(title == expected, f"the summary splits freed from in the Trash: {title}")
        lines = smart.clean_disks.get_text().splitlines()
        report(len(lines) == 2 and lines[0].startswith(_("Free space on {disk}: {before} → {after}").split("{")[0])
               and "/home" in lines[1], "with / and /home on separate disks, both free spaces are shown")
        wait(lambda: smart.running is None and smart.stack.get_visible_child_name() == "results"
             and smart.summary_empty is not None, summary_shown, 30, "the results after the clean")

    def summary_shown():
        report(smart.summary_empty.get_visible(), "the summary offers Empty Trash…")
        dialog = smart.confirm_empty_trash()
        report(human(3000) in dialog.get_body(), "Empty Trash asks first and says how much this cleanup moved there")
        dialog.close()
        answer("clean", [{"event": "task", "id": "trash", "state": "ok", "info": "", "freed": 3000},
                         {"event": "done", "freed": 3000, "to_trash": 0, "avail_before": 0, "avail_after": 0,
                          "disks": [], "trash": {}}])
        smart.empty_trash()
        wait(lambda: smart.restoring is None and smart.clean_summary.get("emptied") == 3000, crashed_clean, 30,
             "Empty Trash")

    # ── 4. the engine crashes in a clean: the item it never reported on fails with its last line ──
    def crashed_clean():
        report(True, "Empty Trash empties it and the summary says what it freed")
        wait(lambda: smart.running is None and smart.stack.get_visible_child_name() == "results", crash_clean, 30,
             "the scan after Empty Trash")

    def crash_clean():
        answer("clean", [{"event": "task", "id": "fake_d", "state": "run", "info": "", "freed": 0}], rc=1, err=crash)
        smart.clean(["fake_d"])
        wait(lambda: smart.clean_summary is not None and smart.clean_summary["failed"] == 1, clean_crashed, 30,
             "the crashed clean")

    def clean_crashed():
        row = smart.task_rows["fake_d"]
        report(row.get_subtitle() == crash[-1] and smart.clean_summary["skipped"] == 0,
               "an item the crashed engine never reported on fails with the engine's last line, not skipped")
        disks()

    # ── 5. the sidebar shows / and a separate /home; System Overview measures again after a clean ──
    def disks():
        gb = 1 << 30
        W.disk_space = lambda paths=None: [("/", 10 * gb, 50 * gb), ("/home", 20 * gb, 200 * gb)]
        win.refresh_disk()
        text = win.disk_label.get_text().splitlines()
        report(len(text) == 2 and text[0].startswith("/:") and text[1].startswith("/home:"),
               "the sidebar shows the free space of / and of a separate /home")
        report(win.overview_stale, "a clean marks System Overview to measure again")
        win.show_page("overview")
        overview = win.pages["overview"]
        report(not win.overview_stale and overview.running is not None, "System Overview measures again when opened")
        wait(lambda: overview.running is None, uninstall_failed, 30, "System Overview")

    # ── 6. an app that couldn't be uninstalled keeps its row and reason ──
    def uninstall_failed():
        win.show_page("uninstall")
        page = win.pages["uninstall"]
        wait(lambda: not page.busy, lambda: uninstall(page), 30, "the Uninstaller")

    def uninstall(page):
        use_fake(page)
        answer("apps", [{"event": "done", "hidden": 0}])
        answer("uninstall", [{"event": "task", "id": "app.ok", "state": "ok", "info": "", "freed": 0},
                             {"event": "task", "id": "app.bad", "state": "fail",
                              "info": "error: app.bad is needed by the runtime", "freed": 0}])
        apps = [{"id": i, "name": name, "kind": "flatpak", "leftovers": []}
                for i, name in (("app.ok", "Fine App"), ("app.bad", "Stuck App"))]
        page.uninstall(apps, [])
        wait(lambda: not page.busy, lambda: GLib.timeout_add(2000, lambda: (uninstalled(page), False)[1]), 30,
             "the fake uninstall")

    def uninstalled(page):
        shown = labels(page.work_list)
        report(page.stack.get_visible_child_name() == "working" and "Stuck App" in shown
               and "error: app.bad is needed by the runtime" in shown and page.work_back.get_visible(),
               "a failed app keeps its row and reason after the uninstall (no reload)")
        report(ngettext("; {n} could not be uninstalled", "; {n} could not be uninstalled", 1).format(n=1)
               in page.work_title.get_text(), f"the summary counts it: {page.work_title.get_text()}")
        page.work_back.emit("clicked")
        wait(lambda: not page.busy and page.stack.get_visible_child_name() != "working", done, 30,
             "Back to the List")

    timed_out()


def trashed_page_test(win, report, wait, finish):
    """Moved to the Trash in a throwaway home: four files moved there by different tools, one emptied from the
    Trash since, are listed newest first, the emptied one greyed out with no box; the source filter and search
    narrow the list; Put Back returns the ticked file and drops its row, Put Back All… the rest; Settings leads
    here. As root the page shows why it can't list (the engine refuses)."""
    import subprocess
    from .engine import Engine
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home = os.path.join(sandbox, "home")
    trash = os.path.join(home, ".local", "share", "Trash")
    env = {"HOME": home, "XDG_DATA_HOME": os.path.join(home, ".local", "share"),
           "XDG_STATE_HOME": os.path.join(home, ".local", "state"), "XDG_CONFIG_HOME": os.path.join(home, ".config"),
           "CLEANMATE_NO_UPDATE_CHECK": "1"}
    moved = [("Downloads/a.deb", "Smart Scan › Old installers in Downloads"), ("Videos/film.mkv", "Large & Old Files"),
             ("Pictures/copy.jpg", "Duplicates"), ("Documents/gone.txt", "Space Lens")]
    win.show_page("trashed")
    page = win.pages["trashed"]
    real_engine = page.engine
    engine = Engine(real_engine.path, dry_run=False, env=env)
    settings = None

    def run(*args):
        return subprocess.run(["bash", real_engine.path, "--json", *args], env={**os.environ, **env},
                              capture_output=True, text=True, timeout=60)

    def idle():
        return page.running is None and page.stack.get_visible_child_name() != "loading"

    def keys():
        return [i["trashed"] for i in page.items]

    def visible():
        return [k for k, row in page.rows.items() if row.get_visible()]

    def done():
        if settings is not None:
            settings.force_close()
        page.engine = real_engine
        win.show_page("smart")
        shutil.rmtree(sandbox, ignore_errors=True)
        controls_test(win, report, wait, finish)

    def first():
        page.engine = engine
        page.load()
        wait(idle, listed, 60, "the Moved to the Trash list")

    def listed():
        if os.geteuid() == 0:
            report(page.stack.get_visible_child_name() == "failed" and page.failed.get_description(),
                   f"as root Moved to the Trash says why it can't list: {page.failed.get_description()}")
            return done()
        report(keys() == ["gone.txt", "copy.jpg", "film.mkv", "a.deb"],
               f"Moved to the Trash lists what was moved, newest first, also what left the Trash: {keys()}")
        gone = page.rows.get("gone.txt")
        report(gone is not None and gone.gone and "gone.txt" not in page.checks
               and _("No longer in the Trash") in gone.get_subtitle() and sorted(page.checks) == [
                   "a.deb", "copy.jpg", "film.mkv"],
               "an item emptied from the Trash is greyed out, says so and has no box")
        report([page.source_drop.get_model().get_string(i) for i in range(page.source_drop.get_model().get_n_items())]
               == [_("All sources"), _("Smart Scan"), _("Large & Old Files"), _("Duplicates"), _("Space Lens")],
               "the source filter lists the tools that moved something")
        page.source_drop.set_selected(page.sources.index("Duplicates"))
        dupes = visible()
        page.source_drop.set_selected(page.sources.index("Smart Scan"))
        smart = visible()
        page.source_drop.set_selected(0)
        report(dupes == ["copy.jpg"] and smart == ["a.deb"], f"the source filter narrows the list: {dupes} {smart}")
        page.search_entry.set_text("videos")
        page.apply_filter()  # search-changed comes after a delay
        found = visible()
        page.search_entry.set_text("")
        page.apply_filter()
        report(found == ["film.mkv"] and len(visible()) == 4, f"search finds a file by its folder: {found}")
        page.checks["a.deb"].set_active(True)
        page.source_drop.set_selected(page.sources.index("Duplicates"))
        report(not page.chosen() and not page.restore_button.get_sensitive(),
               "a ticked item the filter hides is not put back")
        page.source_drop.set_selected(0)
        report(page.chosen() == ["a.deb"] and page.restore_button.get_sensitive(), "Put Back is offered for the ticked one")
        page.restore_button.emit("clicked")
        wait(lambda: page.running is None, put_back, 60, "Put Back")

    def put_back():
        report(os.path.exists(os.path.join(home, "Downloads", "a.deb"))
               and not os.path.exists(os.path.join(trash, "files", "a.deb")) and keys() == ["gone.txt", "copy.jpg",
                                                                                             "film.mkv"],
               f"Put Back returns the file to its folder and drops its row: {keys()}")
        dialog = page.confirm_put_back_all()
        if dialog is None:
            report(False, "Put Back All… offers nothing")
            return done()
        dialog.emit("response", "restore")
        dialog.force_close()
        wait(lambda: page.running is None, all_back, 60, "Put Back All")

    def all_back():
        report(all(os.path.exists(os.path.join(home, p)) for p, _s in moved[1:3]) and keys() == ["gone.txt"]
               and not page.all_button.get_sensitive(),
               f"Put Back All… returns every item still in the Trash; the emptied one stays listed: {keys()}")
        nonlocal settings
        win.show_page("smart")
        settings = win.show_settings()
        settings_page = win.settings_page
        settings_page.engine = Engine(real_engine.path, dry_run=True, env=env)
        settings_page.load()
        wait(lambda: "trashed" in settings_page.rows and not settings_page.busy(), from_settings, 30,
             "Settings")

    def from_settings():
        win.settings_page.rows["trashed"].emit("activated")
        report(win.content_stack.get_visible_child_name() == "trashed", "Settings › Moved to the Trash opens the page")
        wait(idle, done, 60, "the list from Settings")

    if os.geteuid() != 0:
        for path, source in moved:
            full = os.path.join(home, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "wb") as f:
                f.write(b"\0" * 2048)
            out = run("trash", "--source", source, full)
            if out.returncode or os.path.exists(full):
                report(False, f"could not move {path} to the Trash: {out.stdout} {out.stderr}")
                return done()
        os.remove(os.path.join(trash, "files", "gone.txt"))  # emptied from the Trash in Files
        os.remove(os.path.join(trash, "info", "gone.txt.trashinfo"))
    wait(lambda: page.running is None, first, 60, "the first listing")


def ctrl_f(win):
    """What Ctrl+F does (`win.find`). A dialog closed on a headless display stays the window's visible dialog
    (it never gets the frame that ends it), and the window ignores Ctrl+F under a dialog: that check is
    skipped here."""
    win.get_visible_dialog = lambda: None
    try:
        win.activate_action("win.find", None)
    finally:
        del win.get_visible_dialog


def process_gone(pid):
    """PID has ended (gone, or a zombie its parent hasn't collected yet)."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rpartition(")")[2].split()[0] == "Z"
    except (OSError, IndexError):
        return True


def controls_test(win, report, wait, finish):
    """One set of controls on every list page, in a throwaway home: Stop ends a Large & Old Files search and a
    Space Lens measurement (the engine gone in under a second); Ctrl+F narrows Large & Old Files, Space Lens and
    Duplicates (Startup Items, Maintenance and Uninstall Apps are checked in their own tests), and a ticked row it
    hides is never moved; Never Clean from a row of each of the three saves the folder in Settings › Never clean;
    closing the window while something is cleaning asks first; opening CleanMate again brings this window up."""
    from .app import App
    from .engine import Engine, Run
    sandbox = tempfile.mkdtemp(prefix="cleanmate-selftest-")
    home = os.path.join(sandbox, "home")
    videos, projects = os.path.join(home, "Videos"), os.path.join(home, "Projects")
    photos, backup_dir = os.path.join(home, "Photos"), os.path.join(home, "Backup")
    film, backup, notes = (os.path.join(videos, "film.mkv"), os.path.join(videos, "old backup.iso"),
                           os.path.join(projects, "notes.bin"))
    for d in (videos, projects, photos, backup_dir):
        os.makedirs(d)
    for path, size in ((film, 120 << 20), (backup, 60 << 20), (notes, 90 << 20)):  # sparse: no real disk use
        with open(path, "wb") as f:
            f.truncate(size)
    data = os.urandom(1536 << 10)
    for d in (photos, backup_dir):
        with open(os.path.join(d, "beach.jpg"), "wb") as f:
            f.write(data)
    env = {"HOME": home, "XDG_DATA_HOME": os.path.join(home, ".local", "share"),
           "XDG_CONFIG_HOME": os.path.join(home, ".config"), "XDG_CACHE_HOME": os.path.join(home, ".cache"),
           "XDG_STATE_HOME": os.path.join(home, ".local", "state"), "CLEANMATE_NO_UPDATE_CHECK": "1"}
    exclude_file = os.path.join(home, ".config", "cleanmate", "exclude")
    root = os.geteuid() == 0  # the engine refuses settings as root: Never clean isn't saved
    engine = Engine(win.engine.path, dry_run=False, env=env)
    pages, real = {}, {}  # the pages used; their engines before

    def open_page(pid):
        win.show_page(pid)
        page = win.pages[pid]
        real.setdefault(pid, page.engine)
        page.engine = engine
        return page

    def excluded():
        return open(exclude_file).read().split("\n") if os.path.exists(exclude_file) else []

    def visible(page):
        return sorted(os.path.basename(p) for p, row in page.rows.items() if row.get_visible())

    def stopped_in_time(page, name, then):
        """Start PAGE's run, Stop it at once: its engine must be gone within a second."""
        pid = page.running and page.running.proc and int(page.running.proc.get_identifier())
        if not pid:
            report(False, f"{name}: no engine running to stop")
            return then()
        start = time.monotonic()
        page.stop()
        wait(lambda: process_gone(pid) or time.monotonic() - start > 3, lambda: (
            report(process_gone(pid) and time.monotonic() - start < 1 and page.running is None,
                   f"Stop in {name} ends the engine in {time.monotonic() - start:.2f} s"),
            then()), 10, f"{name} stopped")

    def never_clean(page, folder, then):
        """Never Clean from a row's menu (the action its menu item runs)."""
        menus = [w for w in walk(page) if isinstance(w, Gtk.MenuButton) and w.get_tooltip_text() == _("More")]
        report(bool(menus), f"{page.__class__.__name__}: rows have a More menu, named for screen readers")
        page.activate_action("rows.never-clean", GLib.Variant.new_string(folder))
        wait(lambda: page.excluding is None and not page.running, then, 60, "Never clean saved")

    # ── Large & Old Files ──
    def large():
        page = pages["large"] = open_page("large")
        page.set_folder(home)
        page.size_drop.set_selected(0)  # 50 MB
        page.files = []
        page.search()
        stopped_in_time(page, "Large & Old Files", lambda: (
            report(page.stack.get_visible_child_name() == "start", "a stopped first search goes back to the start"),
            page.search(), wait(lambda: page.running is None and page.files, large_found, 60, "large files")))

    def large_found():
        page = pages["large"]
        ctrl_f(win)
        report(page.find_bar.get_search_mode(), "Ctrl+F opens the search in Large & Old Files")
        page.find_bar.entry.set_text("backup")
        page.apply_filter()
        report(visible(page) == ["old backup.iso"], f"the search keeps the matching file: {visible(page)}")
        page.all_check.set_active(True)
        report([e["path"] for e in page.chosen()] == [backup], "the All box ticks only the files listed")
        page.all_check.set_active(False)
        page.checks[film].set_active(True)
        report(not page.chosen() and not page.trash_button.get_sensitive(), "a ticked file the search hides isn't moved")
        page.checks[film].set_active(False)
        page.find_bar.set_search_mode(False)
        page.apply_filter()
        report(visible(page) == ["film.mkv", "notes.bin", "old backup.iso"], "closing the search lists every file again")
        if root:
            report(True, "Never clean skipped: the engine refuses settings as root")
            return lens()
        never_clean(page, videos, large_excluded)

    def large_excluded():
        page = pages["large"]
        names = sorted(os.path.basename(e["path"]) for e in page.files)
        report(videos in excluded() and names == ["notes.bin"],
               f"Never Clean Its Folder (Large & Old Files) saves Videos in Settings and drops its files: {names}")
        lens()

    # ── Space Lens ──
    def lens():
        page = pages["lens"] = open_page("lens")
        before = page.shown_at
        page.set_root(home)
        stopped_in_time(page, "Space Lens", lambda: (
            report(page.stack.get_visible_child_name() != "measuring"
                   and (page.folder == before if before else page.stack.get_visible_child_name() == "stopped"),
                   "a stopped measurement shows the folder before, or Measure Again"),
            page.set_root(home),
            wait(lambda: page.running is None and page.folder == home
                 and page.stack.get_visible_child_name() == "results", lens_listed, 60, "Space Lens list")))

    def lens_listed():
        page = pages["lens"]
        ctrl_f(win)
        report(page.find_bar.get_search_mode(), "Ctrl+F opens the search in Space Lens")
        page.find_bar.entry.set_text("PROJ")
        page.apply_filter()
        report(visible(page) == ["Projects"], f"the search keeps the matching folder, any case: {visible(page)}")
        page.find_bar.set_search_mode(False)
        page.apply_filter()
        report("Projects" in visible(page) and "Photos" in visible(page), "closing the search lists everything again")
        if root:
            return dupes()
        never_clean(page, projects, lambda: wait(lambda: page.running is None
                                                 and page.stack.get_visible_child_name() == "results",
                                                 lens_excluded, 60, "Space Lens again"))

    def lens_excluded():
        page = pages["lens"]
        entry = next((e for e in page.entries if e["path"] == projects), {})
        report(projects in excluded() and entry and not entry["movable"] and projects not in page.checks,
               "Never Clean This Folder (Space Lens) saves it in Settings; it is view only from then on")
        dupes()

    # ── Duplicates ──
    def dupes():
        page = pages["dupes"] = open_page("dupes")
        page.set_folder(home)
        page.search()
        wait(lambda: page.running is None and page.stack.get_visible_child_name() != "searching", dupes_found, 60,
             "duplicates search")

    def dupes_found():
        page = pages["dupes"]
        groups = page.shown_groups()
        report(len(groups) == 1, f"one group of two copies: {len(groups)}")
        if not groups:
            return closing()
        ctrl_f(win)
        report(page.find_bar.get_search_mode(), "Ctrl+F opens the search in Duplicates")
        page.find_bar.entry.set_text("no-such-photo")
        page.apply_filter()
        page.selected = {os.path.join(backup_dir, "beach.jpg")}
        report(not page.listed_groups() and not page.chosen(), "a group the search hides is hidden and never moved")
        page.find_bar.entry.set_text("backup beach")
        page.apply_filter()
        report(len(page.listed_groups()) == 1 and len(page.chosen()) == 1, "words in any order find a copy by folder")
        page.selected = set()
        page.find_bar.set_search_mode(False)
        page.apply_filter()
        if root:
            return closing()
        never_clean(page, backup_dir, dupes_excluded)

    def dupes_excluded():
        page = pages["dupes"]
        left = [f["path"] for g in page.groups for f in g["files"]]
        report(backup_dir in excluded() and not any(p.startswith(backup_dir + "/") for p in left),
               "Never Clean Its Folder (Duplicates) saves it in Settings and drops its copies")
        closing()

    # ── closing while cleaning, a second CleanMate ──
    def closing():
        cleaning = Run()
        cleaning.writes = True  # what a clean, a move to the Trash or a put back looks like to the window
        win.engine.live.add(cleaning)
        closed = []
        # what closing the window runs (`close-request`); on a headless display an earlier dialog never quite
        # closes, and the window would close that one first
        kept = win.on_close_request()
        dialog = getattr(win, "close_dialog", None)
        report(kept and win.get_visible() and dialog is not None and win.get_visible_dialog() is dialog,
               "closing the window while something is cleaning asks first")
        win.closing("keep")
        report(win.get_visible() and not cleaning.is_cancelled(), "Keep Running leaves the window and the clean going")
        win.close = lambda: closed.append(1)  # the real one would end the self-test
        win.closing("close")
        del win.close
        report(closed and cleaning.is_cancelled(), "Stop and Close ends the clean, then closes")
        win.close_confirmed = False
        win.engine.live.discard(cleaning)
        dialog.force_close()

        app = win.get_application()
        report(not App(app.engine).get_flags() & Gio.ApplicationFlags.NON_UNIQUE,
               "CleanMate runs once: opening it again reaches the one running")
        presented = []
        win.present = lambda: presented.append(1)
        app.activate()  # what opening it again does in the running one
        del win.present
        report(presented == [1] and len(app.get_windows()) == 1, "opening it again brings this window up, no second one")
        from .window import terminal_command
        commands = [terminal_command("/opt/my apps/cleanmate.sh", True, which=lambda t, term=term: t == term)
                    for term in ("konsole", "xfce4-terminal", "gnome-terminal")]
        report(commands == [["konsole", "-e", "bash", "/opt/my apps/cleanmate.sh", "--dry-run"],
                            ["xfce4-terminal", "-x", "bash", "/opt/my apps/cleanmate.sh", "--dry-run"],
                            ["gnome-terminal", "--", "bash", "/opt/my apps/cleanmate.sh", "--dry-run"]]
               and terminal_command("/x", which=lambda t: False) is None,
               "All tools (terminal) opens cm in Konsole, Xfce Terminal or GNOME Terminal, the path one argument")
        done()

    def done():
        for pid, engine_before in real.items():
            win.pages[pid].engine = engine_before
        win.show_page("smart")
        shutil.rmtree(sandbox, ignore_errors=True)
        finish()

    large()


def show_scene_page(win, page_id):
    """Show a page with its sidebar row highlighted, as a click would."""
    win.show_page(page_id)
    win.select_sidebar(page_id)


def tool_scene(win, scene, path, wait, finish):
    """Large & Old Files with the two biggest files ticked; the Uninstaller with a Flatpak app ticked;
    Space Lens of the home folder with its biggest folder ticked; Duplicates of the home folder after
    Select automatically; Startup Items; the Settings dialog."""
    def shoot(delay_ms=1200):
        GLib.timeout_add(delay_ms, lambda: (screenshot(win, path, finish), False)[1])

    if scene == "settings":
        show_scene_page(win, "lens")
        win.show_settings().set_content_height(640)
        return shoot(3000)
    page_id = {"duplicates": "dupes"}.get(scene, scene)
    show_scene_page(win, page_id)
    page = win.pages[page_id]

    if scene == "lens":
        def measured():
            dirs = [e for e in page.entries if e["kind"] == "dir" and e["path"] in page.checks]
            if dirs:
                page.checks[max(dirs, key=lambda e: e["bytes"])["path"]].set_active(True)
            shoot()

        return wait(lambda: page.running is None and page.entries, measured, 120, "measure")
    if scene == "duplicates":
        def searched():
            page.select_automatically()
            shoot()

        page.set_folder(os.path.expanduser("~"))
        page.search()
        return wait(lambda: page.running is None and page.stack.get_visible_child_name() != "searching",
                    searched, 120, "search")
    if scene == "startup":
        return wait(lambda: page.running is None and page.units, shoot, 60, "startup list")

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
    if scene in ("large", "uninstall", "lens", "duplicates", "startup", "settings"):
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
