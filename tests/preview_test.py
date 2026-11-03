"""Unit tests of the file previews (gui/cleanmate_gui/preview.py): thumbnails of photos and videos, the thumbnail
cache, access dates left alone.

Run: python3 tests/preview_test.py  (needs python3-gi with GTK 4, libadwaita and GdkPixbuf; the video tests also
GStreamer for Python with the base plugins, else they are skipped; tests/run.sh runs it).
"""
import hashlib
import os
import shutil
import sys
import tempfile
import time
import unittest

TMP = tempfile.mkdtemp(prefix="cleanmate-preview-test-")
os.environ["XDG_CACHE_HOME"] = os.path.join(TMP, "cache")  # before GLib reads it
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gui"))

import gi  # noqa: E402

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, GLib  # noqa: E402

from cleanmate_gui import preview, similar  # noqa: E402


def picture(w, h, rgb=(200, 120, 40)):
    pixbuf = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, False, 8, w, h)
    pixbuf.fill((rgb[0] << 24) | (rgb[1] << 16) | (rgb[2] << 8) | 0xFF)
    return pixbuf


def run_main_loop(until, seconds=10):
    context, deadline = GLib.MainContext.default(), time.monotonic() + seconds
    while not until() and time.monotonic() < deadline:
        context.iteration(False)
        time.sleep(0.005)


class PreviewTest(unittest.TestCase):
    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(TMP, ignore_errors=True)

    def setUp(self):
        self.dir = tempfile.mkdtemp(dir=TMP)

    def path(self, name):
        return os.path.join(self.dir, name)

    def test_media_kind(self):
        self.assertEqual(preview.media_kind("/x/Beach.JPG"), "image")
        self.assertEqual(preview.media_kind("/x/film.mkv"), "video")
        self.assertIsNone(preview.media_kind("/x/disk.iso"))
        self.assertIsNone(preview.media_kind("/x/notes.pdf"))

    def test_photo_thumbnail_keeps_its_shape(self):
        path = self.path("wide.png")
        picture(320, 240).savev(path, "png", [], [])
        thumb = preview.load_thumbnail(path, "image", 96)
        self.assertEqual((thumb.get_width(), thumb.get_height()), (96, 72))
        self.assertIsNone(preview.load_thumbnail(path, None, 96), "only images and videos get a picture")

    def test_unreadable_file_has_no_thumbnail(self):
        path = self.path("broken.jpg")
        with open(path, "wb") as f:
            f.write(os.urandom(4096))
        self.assertIsNone(preview.load_thumbnail(path, "image", 96))
        self.assertIsNone(preview.load_thumbnail(self.path("gone.jpg"), "image", 96))

    def test_huge_picture_is_skipped_unless_jpeg(self):
        png, jpg = self.path("big.png"), self.path("big.jpg")
        picture(320, 240).savev(png, "png", [], [])
        picture(320, 240).savev(jpg, "jpeg", [], [])
        self.assertIsNone(similar.load_small(png, 96, 96, fit=True, max_pixels=1000),
                          "a PNG would decode at full size first")
        self.assertIsNotNone(similar.load_small(jpg, 96, 96, fit=True, max_pixels=1000),
                             "a JPEG decodes straight at the small size")
        self.assertIsNotNone(similar.load_small(png, 96, 96, fit=True, max_pixels=320 * 240))

    def test_reading_leaves_the_access_date(self):
        path = self.path("old.png")
        picture(64, 48).savev(path, "png", [], [])
        then = time.time() - 400 * 86400
        os.utime(path, (then, then - 86400))  # opened long ago, after it was changed
        self.assertIsNotNone(preview.load_thumbnail(path, "image", 96))
        self.assertAlmostEqual(os.stat(path).st_atime, then, delta=1)

    def test_file_managers_thumbnail_comes_first(self):
        path = self.path("film.mkv")  # not a real video: only the cached picture can show it
        with open(path, "wb") as f:
            f.write(os.urandom(2048))
        uri = GLib.filename_to_uri(path, None)
        folder = os.path.join(os.environ["XDG_CACHE_HOME"], "thumbnails", "normal")
        os.makedirs(folder, exist_ok=True)
        picture(128, 72, (10, 200, 10)).savev(
            os.path.join(folder, hashlib.md5(uri.encode()).hexdigest() + ".png"), "png",
            ["tEXt::Thumb::URI", "tEXt::Thumb::MTime"], [uri, str(int(os.stat(path).st_mtime))])
        if not preview.cached_thumbnail(path):
            self.skipTest("this GLib doesn't look up the thumbnail cache")
        thumb = preview.load_thumbnail(path, "video", 96)
        self.assertEqual((thumb.get_width(), thumb.get_height()), (96, 54))
        self.assertIsNone(preview.cached_thumbnail(self.path("other.mkv")))

    def video(self, name, seconds):
        Gst = preview.gstreamer()
        if not Gst:
            self.skipTest("GStreamer for Python not installed")
        path = self.path(name)
        try:
            pipeline = Gst.parse_launch(
                f"videotestsrc num-buffers={seconds * 10} pattern=smpte ! "
                f"video/x-raw,width=320,height=180,framerate=10/1 ! theoraenc ! oggmux ! filesink location={path}")
        except GLib.Error as e:
            self.skipTest(f"GStreamer base plugins missing: {e.message}")
        pipeline.set_state(Gst.State.PLAYING)
        pipeline.get_bus().timed_pop_filtered(30 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR)
        pipeline.set_state(Gst.State.NULL)
        return path

    def test_video_frame(self):
        for seconds in (1, 6):  # a short one: its first frame; a longer one: a tenth in
            path = self.video(f"clip{seconds}.ogv", seconds)
            then = time.time() - 400 * 86400
            os.utime(path, (then, then - 86400))
            frame = preview.load_thumbnail(path, "video", 96)
            self.assertIsNotNone(frame, f"a frame of a {seconds} s video")
            self.assertEqual((frame.get_width(), frame.get_height()), (96, 54))
            self.assertAlmostEqual(os.stat(path).st_atime, then, delta=1)

    def test_not_a_video_gives_no_frame_quickly(self):
        if not preview.gstreamer():
            self.skipTest("GStreamer for Python not installed")
        path = self.path("broken.mp4")
        with open(path, "wb") as f:
            f.write(os.urandom(8192))
        start = time.monotonic()
        self.assertIsNone(preview.video_frame(path, 96))
        self.assertLess(time.monotonic() - start, 6)

    def test_thumbnails_are_read_once(self):
        path = self.path("once.png")
        picture(80, 60).savev(path, "png", [], [])
        thumbs, reads, got = preview.Thumbnails(), [], []
        real = preview.load_thumbnail
        preview.load_thumbnail = lambda *a: reads.append(a) or real(*a)
        try:
            key = (path, (1, 2), 40)
            thumbs.request(key, "image", got.append)
            thumbs.request(key, "image", got.append)  # asked again while read: waits for the same read
            run_main_loop(lambda: len(got) == 2)
            thumbs.request(key, "image", got.append)  # known: at once
            self.assertEqual(len(got), 3)
            self.assertEqual(len(reads), 1)
            self.assertEqual((got[0].get_width(), got[0].get_height()), (80, 60))
            self.assertIs(thumbs.latest[path], got[0])
            thumbs.request((path, (1, 3), 40), "image", got.append)  # the file changed: read again
            run_main_loop(lambda: len(got) == 4)
            self.assertEqual(len(reads), 2)
            skipped = []
            thumbs.request((self.path("gone.png"), None, 40), "image", skipped.append, alive=lambda: False)
            run_main_loop(lambda: not thumbs.waiting)
            self.assertEqual(skipped, [], "a row that is gone is never read")
            self.assertNotIn((self.path("gone.png"), None, 40), thumbs.cache)
        finally:
            preview.load_thumbnail = real


if __name__ == "__main__":
    unittest.main(verbosity=2)
