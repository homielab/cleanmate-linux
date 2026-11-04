"""Which copy of the engine the desktop app runs as root (gui/cleanmate_gui/engine.py).

pkexec only runs root's own copy (the package's /usr/bin/cleanmate): a copy you can change never gets your
password. Each command goes with the polkit action of its page, so the password dialog says what it's for.
pkexec is a stub here, like in the self-test: it logs how it was called and asks for nothing.
"""
import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "gui"))
os.environ["CLEANMATE_LOCALEDIR"] = os.path.join(ROOT, "no-locale")  # the English texts, whatever the system's
from gi.repository import GLib  # noqa: E402

from cleanmate_gui import engine as E  # noqa: E402

SYSTEM_PROGRAM = os.path.realpath("/bin/sh")  # root's, in folders only root can change


def root_owned_chain(path):
    """The test's own idea of a root-owned path, to skip on a system where /bin/sh isn't."""
    p = os.path.realpath(path)
    while True:
        st = os.stat(p)
        if st.st_uid != 0 or st.st_mode & 0o022:
            return False
        if os.path.dirname(p) == p:
            return True
        p = os.path.dirname(p)


class RootOwned(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.copy = os.path.join(self.dir, "cleanmate")
        shutil.copy(os.path.join(ROOT, "cleanmate.sh"), self.copy)
        os.chmod(self.copy, 0o755)

    def test_a_copy_you_can_change_is_not(self):
        # yours (a clone, `cm --install`), or root's in a folder anyone can write to (/tmp)
        self.assertFalse(E.root_owned(self.copy))

    def test_missing_file_is_not(self):
        self.assertFalse(E.root_owned(os.path.join(self.dir, "nothing")))
        self.assertFalse(E.root_owned(self.dir))  # a folder isn't an engine

    def test_system_program_is(self):
        if not root_owned_chain(SYSTEM_PROGRAM):
            self.skipTest(f"{SYSTEM_PROGRAM} isn't root's on this system")
        self.assertTrue(E.root_owned(SYSTEM_PROGRAM))

    def test_a_link_counts_by_what_it_points_to(self):
        if not root_owned_chain(SYSTEM_PROGRAM):
            self.skipTest(f"{SYSTEM_PROGRAM} isn't root's on this system")
        link = os.path.join(self.dir, "cm")
        os.symlink(SYSTEM_PROGRAM, link)
        self.assertTrue(E.root_owned(link))
        os.symlink(self.copy, os.path.join(self.dir, "cm2"))
        self.assertFalse(E.root_owned(os.path.join(self.dir, "cm2")))

    @unittest.skipIf(os.geteuid() == 0, "as root the app asks for no password at all")
    def test_engine_in_your_folder_cant_ask_for_the_password(self):
        self.assertFalse(E.Engine(self.copy).can_ask_password())

    def test_package_engine_can(self):
        if not root_owned_chain(SYSTEM_PROGRAM):
            self.skipTest(f"{SYSTEM_PROGRAM} isn't root's on this system")
        self.assertTrue(E.Engine(SYSTEM_PROGRAM).can_ask_password())


class RunAsRoot(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.bin = os.path.join(self.dir, "bin")
        os.makedirs(self.bin)
        self.log = os.path.join(self.dir, "pkexec.log")
        stub = os.path.join(self.bin, "pkexec")
        with open(stub, "w") as f:
            f.write(f'#!/bin/sh\necho "pkexec $*" >>"{self.log}"\necho \'{{"event":"done"}}\'\n')
        os.chmod(stub, 0o755)
        self.copy = os.path.join(self.dir, "cleanmate")
        shutil.copy(os.path.join(ROOT, "cleanmate.sh"), self.copy)

    def engine(self, path=None, root_ok=None):
        e = E.Engine(path or self.copy, env={"PATH": self.bin + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
                                             "HOME": self.dir})
        if root_ok is not None:
            e.root_ok = root_ok
        return e

    def run_engine(self, engine, call):
        """call(on_event, on_done) starts a run; returns (events, exit status) once it ended."""
        loop, events, result = GLib.MainLoop(), [], {}

        def done(ok, status):
            result["status"] = status
            loop.quit()
        call(events.append, done)
        GLib.timeout_add_seconds(20, loop.quit)
        loop.run()
        return events, result.get("status")

    def prompts(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return f.read().splitlines()

    def test_copy_you_can_change_never_calls_pkexec(self):
        engine = self.engine(root_ok=False)  # what can_ask_password() says of a copy in your home folder
        for call in (lambda ev, dn: engine.clean(["apt_cache"], ev, dn, as_root=True),
                     lambda ev, dn: engine.uninstall(["apt:gimp"], ev, dn, as_root=True),
                     lambda ev, dn: engine.maintain("update", ev, dn, as_root=True)):
            events, status = self.run_engine(engine, call)
            self.assertEqual(status, E.NEEDS_PACKAGE)
            self.assertIn({"event": "failed", "status": E.NEEDS_PACKAGE, "stderr": []}, events)
        self.assertEqual(self.prompts(), [])

    def test_package_engine_asks_with_the_action_of_its_page(self):
        engine = self.engine(root_ok=True)  # as the package's /usr/bin/cleanmate is
        real = os.path.realpath(self.copy)
        for call, line in (
                (lambda ev, dn: engine.clean(["apt_cache"], ev, dn, as_root=True),
                 f"pkexec {real} --polkit=clean-system --json clean apt_cache"),
                (lambda ev, dn: engine.uninstall(["apt:gimp"], ev, dn, as_root=True),
                 f"pkexec {real} --polkit=uninstall-apps --json uninstall apt:gimp"),
                (lambda ev, dn: engine.maintain("update", ev, dn, as_root=True),
                 f"pkexec {real} --polkit=maintenance --json maintain update")):
            _events, status = self.run_engine(engine, call)
            self.assertEqual(status, 0)
            self.assertEqual(self.prompts()[-1], line)

    def test_system_path_goes_to_pkexec(self):
        if not root_owned_chain(SYSTEM_PROGRAM):
            self.skipTest(f"{SYSTEM_PROGRAM} isn't root's on this system")
        engine = self.engine(SYSTEM_PROGRAM)  # checked for real: root's, like /usr/bin/cleanmate
        _events, status = self.run_engine(engine, lambda ev, dn: engine.uninstall(["snap:vlc"], ev, dn, as_root=True))
        self.assertEqual(status, 0)
        self.assertEqual(self.prompts(), [f"pkexec {SYSTEM_PROGRAM} --polkit=uninstall-apps --json uninstall snap:vlc"])

    def test_only_commands_with_an_action_run_as_root(self):
        engine = self.engine(root_ok=True)
        _events, status = self.run_engine(engine, lambda ev, dn: engine.run(["trash", "/x"], ev, dn, as_root=True))
        self.assertEqual(status, E.NEEDS_PACKAGE)
        self.assertEqual(self.prompts(), [])


if __name__ == "__main__":
    unittest.main()
