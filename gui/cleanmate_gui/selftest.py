"""`--selftest`: drive the real window like a user would, print results, quit.

Used by tests/run.sh on a virtual display. Only cleans in dry-run mode and
never touches system items (so no password prompt can appear). The Large & Old
Files check moves files to the Trash for real, but only files it made itself in
a throwaway home folder, with the engine pointed at that folder.
"""
import os
import shutil
import tempfile
import time

from gi.repository import Adw, GLib


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
        for button, _ in page.group_buttons:
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
        wait(lambda: page.clean_title.get_text().startswith("Dry run"), after_clean, 60, "dry-run clean")

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
        finish()

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


def run_scene(app, win, scene, path, report, wait, finish):
    """Screenshot scenes for docs and app stores (packaging/make-screenshots.sh)."""
    page_id = {"privacy": "privacy", "ai": "ai", "user": "user"}.get(scene, "smart")
    win.show_page(page_id)
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
            return shoot(1200)
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
            return wait(lambda: page.clean_title.get_text().startswith(("Freed", "Dry run", "History")),
                        lambda: shoot(300), 120, "clean")
        shoot()

    page.scan()
    wait(scanned, after_scan, 120, "scan")
