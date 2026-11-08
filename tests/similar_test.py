"""Unit tests of Similar Photos (gui/cleanmate_gui/similar.py): hashes and groups of generated photos.

Run: python3 tests/similar_test.py  (needs python3-gi and GdkPixbuf; tests/run.sh runs it).
"""
import os
import random
import shutil
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gui"))

import gi  # noqa: E402

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, GLib  # noqa: E402

from cleanmate_gui import similar  # noqa: E402

W, H = 320, 240


def picture(seed, w=W, h=H):
    """A made-up photo: soft coloured blobs on a gradient with 8 px grain, different for each seed."""
    rnd = random.Random(seed)
    blobs = [(rnd.uniform(0, w), rnd.uniform(0, h), rnd.uniform(25, 110) ** 2,
              [rnd.randrange(256) for _c in range(3)]) for _b in range(6)]
    top, bottom = [rnd.randrange(256) for _c in range(3)], [rnd.randrange(256) for _c in range(3)]
    grain = [[rnd.randint(-24, 24) for _x in range(w // 8 + 1)] for _y in range(h // 8 + 1)]
    data = bytearray()
    for y in range(h):
        t = y / h
        for x in range(w):
            px = [a + (b - a) * t for a, b in zip(top, bottom)]
            for bx, by, r2, color in blobs:
                d2 = (x - bx) ** 2 + (y - by) ** 2
                if d2 < r2:
                    k = 1 - d2 / r2
                    px = [p + (c - p) * k for p, c in zip(px, color)]
            g = grain[y // 8][x // 8]
            data += bytes(max(0, min(255, int(p + g))) for p in px)
    return GdkPixbuf.Pixbuf.new_from_bytes(GLib.Bytes.new(bytes(data)), GdkPixbuf.Colorspace.RGB, False, 8, w, h, w * 3)


def save(pixbuf, path, kind="png", **options):
    pixbuf.savev(path, kind, list(options), [str(v) for v in options.values()])
    return path


def brighter(pixbuf, by):
    data = bytes(min(255, b + by) for b in pixbuf.get_pixels())
    return GdkPixbuf.Pixbuf.new_from_bytes(GLib.Bytes.new(data), GdkPixbuf.Colorspace.RGB, False, 8,
                                           pixbuf.get_width(), pixbuf.get_height(), pixbuf.get_rowstride())


class SimilarPhotosTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp(prefix="cleanmate-similar-test-")
        d = cls.dir
        beach = picture(1)
        cls.beach = save(beach, os.path.join(d, "beach.png"))
        cls.beach_small = save(beach.scale_simple(W // 2, H // 2, GdkPixbuf.InterpType.BILINEAR),
                               os.path.join(d, "beach small.jpg"), "jpeg", quality=90)
        cls.beach_low = save(beach, os.path.join(d, "beach low.jpg"), "jpeg", quality=40)
        cls.beach_bright = save(brighter(beach, 18), os.path.join(d, "beach bright.jpg"), "jpeg", quality=85)
        cls.beach_crop = save(beach.new_subpixbuf(W * 3 // 100, H * 3 // 100, W * 94 // 100, H * 94 // 100),
                              os.path.join(d, "beach crop.jpg"), "jpeg", quality=80)
        city = picture(2)
        cls.city = save(city, os.path.join(d, "city.jpg"), "jpeg", quality=95)
        cls.city_copy = save(city.scale_simple(W * 3 // 4, H * 3 // 4, GdkPixbuf.InterpType.HYPER),
                             os.path.join(d, "city 75.webp" if "webp" in similar.readable_extensions() else "city 75.png"),
                             "webp" if "webp" in similar.readable_extensions() else "png")
        cls.others = [save(picture(seed), os.path.join(d, f"other {seed}.jpg"), "jpeg", quality=85)
                      for seed in range(3, 13)]

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    def hashed(self, folder=None, **kw):
        return similar.hash_photos(similar.find_photos(folder or self.dir, min_bytes=0, **kw))

    def test_distances(self):
        h = {p["path"]: p for p in self.hashed()}
        beach = h[self.beach]
        for path in (self.beach_small, self.beach_low, self.beach_bright, self.beach_crop):
            self.assertLessEqual(similar.distance(beach["dct"], h[path]["dct"]), 4, path)
            self.assertLessEqual(similar.distance(beach["diff"], h[path]["diff"]), 6, path)
        pictures = [self.beach, self.city] + self.others
        for i, a in enumerate(pictures):
            for b in pictures[i + 1:]:
                self.assertGreaterEqual(similar.distance(h[a]["dct"], h[b]["dct"]), 16, (a, b))

    def test_groups(self):
        groups = similar.group_photos(self.hashed())
        paths = sorted(sorted(os.path.basename(f["path"]) for f in g["files"]) for g in groups)
        self.assertEqual(paths, [sorted(os.path.basename(p) for p in (self.beach, self.beach_small, self.beach_low,
                                                                      self.beach_bright, self.beach_crop)),
                                 sorted(os.path.basename(p) for p in (self.city, self.city_copy))])

    def test_keeps_most_pixels_then_biggest(self):
        groups = {g["key"]: g for g in similar.group_photos(self.hashed())}
        beach = next(g for g in groups.values() if any(f["path"] == self.beach_small for f in g["files"]))
        full = [f for f in beach["files"] if f["width"] == W]
        self.assertEqual(similar.keeper(beach), max(full, key=lambda f: f["bytes"])["path"])
        self.assertEqual(beach["files"][0]["path"], similar.keeper(beach))
        self.assertEqual(similar.freeable(beach), sum(f["bytes"] for f in beach["files"][1:]))

    def test_hash_bits(self):
        flat = [[100.0] * 9 for _r in range(8)]
        self.assertEqual(similar.diff_hash(flat), 0)
        falling = [[float(255 - 20 * x) for x in range(9)] for _r in range(8)]
        self.assertEqual(similar.diff_hash(falling), (1 << 64) - 1)
        self.assertEqual(similar.distance(0b1011, 0b0001), 2)
        light_left = [[255.0 if x < 16 else 0.0 for x in range(32)] for _r in range(32)]
        light_right = [row[::-1] for row in light_left]
        self.assertGreater(similar.distance(similar.dct_hash(light_left), similar.dct_hash(light_right)), 0)

    def test_complete_linkage(self):
        # a chain a–b–c where a and c are far apart: b joins one of them, never both
        a, b, c = (dict(path=p, bytes=1, mtime=0, width=1, height=1, diff=0) for p in "abc")
        a["dct"], b["dct"], c["dct"] = 0, (1 << similar.DCT_MAX) - 1, (1 << 2 * similar.DCT_MAX) - 1
        groups = similar.group_photos([a, b, c])
        self.assertEqual(len(groups), 1)
        self.assertEqual(len(groups[0]["files"]), 2)

    def test_skips_hidden_excluded_libraries_links_and_small(self):
        root = tempfile.mkdtemp(prefix="cleanmate-similar-walk-")
        try:
            for sub in ("Trips", ".thumbnails", "Private", "Managed", "Trips/Day 1"):
                os.makedirs(os.path.join(root, sub))
                shutil.copy(self.beach, os.path.join(root, sub, "p.png"))
            open(os.path.join(root, "Managed", "digikam4.db"), "w").close()
            os.symlink(os.path.join(root, "Trips", "p.png"), os.path.join(root, "link.png"))
            os.link(os.path.join(root, "Trips", "p.png"), os.path.join(root, "Trips", "hard.png"))
            with open(os.path.join(root, "tiny.png"), "wb") as f:
                f.write(b"x" * 100)
            with open(os.path.join(root, "notes.txt"), "wb") as f:
                f.write(b"x" * 50000)
            found = similar.find_photos(root, exclusions=[os.path.join(root, "Private")], min_bytes=1000)
            rel = sorted(os.path.relpath(p["path"], root) for p in found)
            self.assertIn(rel, (["Trips/Day 1/p.png", "Trips/hard.png"], ["Trips/Day 1/p.png", "Trips/p.png"]))
            self.assertEqual(similar.find_photos(os.path.join(root, "Private"), exclusions=[os.path.join(root, "Private")]), [])
        finally:
            shutil.rmtree(root, ignore_errors=True)

    def test_unreadable_photo_is_left_out(self):
        root = tempfile.mkdtemp(prefix="cleanmate-similar-bad-")
        try:
            with open(os.path.join(root, "broken.jpg"), "wb") as f:
                f.write(os.urandom(30000))
            self.assertEqual(self.hashed(root), [])
        finally:
            shutil.rmtree(root, ignore_errors=True)

    def test_cancel_returns_at_once(self):
        stop = threading.Event()
        stop.set()
        photos = similar.find_photos(self.dir, min_bytes=0)
        self.assertEqual(similar.hash_photos(photos, cancelled=stop.is_set), [])
        self.assertIsNone(similar.group_photos([dict(p, dct=0, diff=0) for p in photos], cancelled=stop.is_set))
        self.assertEqual(similar.find_photos(self.dir, cancelled=stop.is_set), [])


class HashCacheTest(unittest.TestCase):
    """The hash cache: a second search of unchanged photos decodes none of them."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="cleanmate-similar-cache-")
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.photos = os.path.join(self.dir, "Pictures")
        os.makedirs(self.photos)
        beach = picture(1)
        self.beach = save(beach, os.path.join(self.photos, "beach.png"))
        self.beach_low = save(beach, os.path.join(self.photos, "beach low.jpg"), "jpeg", quality=40)
        self.city = save(picture(2), os.path.join(self.photos, "city.jpg"), "jpeg", quality=90)
        with open(os.path.join(self.photos, "broken.jpg"), "wb") as f:
            f.write(os.urandom(30000))
        self.cache = os.path.join(self.dir, "cache", "cleanmate", "similar-hashes.tsv")
        self.loads = []
        real = similar.load_small

        def counted(path, *args, **kw):
            self.loads.append(os.path.basename(path))
            return real(path, *args, **kw)

        similar.load_small = counted
        self.addCleanup(setattr, similar, "load_small", real)

    def search(self, **kw):
        self.loads.clear()
        read = similar.hash_photos(similar.find_photos(self.photos, min_bytes=0), cache=self.cache, **kw)
        return {os.path.basename(p["path"]): (p["dct"], p["diff"], p["width"], p["height"]) for p in read}

    def cached_names(self):
        with open(self.cache, encoding="utf-8") as f:
            return sorted(os.path.basename(line.split("\t")[0]) for line in f if not line.startswith("#"))

    def test_second_search_reads_nothing(self):
        first = self.search()
        self.assertEqual(sorted(self.loads), ["beach low.jpg", "beach.png", "broken.jpg", "city.jpg"])
        self.assertEqual(sorted(first), ["beach low.jpg", "beach.png", "city.jpg"])
        self.assertEqual(self.search(), first)
        self.assertEqual(self.loads, [], "unchanged photos (and the unreadable one) are not decoded again")
        self.assertEqual(os.stat(self.cache).st_mode & 0o777, 0o600)
        self.assertEqual(self.cached_names(), ["beach low.jpg", "beach.png", "broken.jpg", "city.jpg"])

    def test_changed_photo_is_read_again_deleted_one_leaves_the_cache(self):
        first = self.search()
        save(picture(7), self.city, "jpeg", quality=90)
        st = os.stat(self.city)
        os.utime(self.city, ns=(st.st_atime_ns, st.st_mtime_ns + 2_000_000_000))
        os.remove(self.beach_low)
        again = self.search()
        self.assertEqual(self.loads, ["city.jpg"])
        self.assertNotEqual(again["city.jpg"], first["city.jpg"])
        self.assertEqual(again["beach.png"], first["beach.png"])
        self.assertEqual(self.cached_names(), ["beach.png", "broken.jpg", "city.jpg"])
        self.assertEqual(self.search(), again)
        self.assertEqual(self.loads, [])

    def test_other_folders_lines_stay_while_their_photos_do(self):
        self.search()
        other = os.path.join(self.dir, "Other")
        os.makedirs(other)
        save(picture(3), os.path.join(other, "sea.jpg"), "jpeg", quality=85)
        similar.hash_photos(similar.find_photos(other, min_bytes=0), cache=self.cache)
        self.assertIn("beach.png", self.cached_names())
        self.assertIn("sea.jpg", self.cached_names())
        os.remove(self.beach)
        similar.hash_photos(similar.find_photos(other, min_bytes=0), cache=self.cache)
        self.assertNotIn("beach.png", self.cached_names(), "a deleted photo's line goes, whichever folder is searched")

    def test_damaged_cache_is_ignored(self):
        first = self.search()
        for junk in (os.urandom(4000), b"# cleanmate similar-hashes 0\n/x\t1\t2\t3\t4\t5\t6\n",
                     b"# cleanmate similar-hashes 1\nnot a line\n/a\tb\n" + self.beach.encode() + b"\tx\ty\n"):
            with open(self.cache, "wb") as f:
                f.write(junk)
            self.assertEqual(self.search(), first)
            self.assertEqual(len(self.loads), 4, "a damaged cache: every photo is read, the search works")
        os.remove(self.cache)
        os.makedirs(self.cache)  # can't be read or written: the search still works
        self.assertEqual(self.search(), first)

    def test_stopped_search_keeps_what_it_read(self):
        stop = threading.Event()
        self.assertEqual(self.search(workers=1, progress=lambda done, total: done >= 2 and stop.set(),
                                     cancelled=stop.is_set), {})
        read = list(self.loads)
        self.assertGreaterEqual(len(read), 2)
        self.search()
        self.assertEqual(sorted(self.loads + read), ["beach low.jpg", "beach.png", "broken.jpg", "city.jpg"])

    def test_cache_file_is_in_the_user_cache_folder(self):
        self.assertEqual(similar.cache_file(), os.path.join(GLib.get_user_cache_dir(), "cleanmate",
                                                            "similar-hashes.tsv"))


class NoLoaderStats(unittest.TestCase):
    """The count of photos whose format this system cannot read (no GdkPixbuf loader)."""

    def test_counts_photos_this_system_cannot_read(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        def blob(kind, size=24 << 10):
            with open(os.path.join(d, kind), "wb") as f:
                f.write(bytes(size))
        blob("keep.jpg")
        blob("skip.heic")
        blob("skip.webp")
        blob("note.txt")
        stats = {}
        found = similar.find_photos(d, extensions={"jpg"}, stats=stats)
        self.assertEqual([os.path.basename(p["path"]) for p in found], ["keep.jpg"])
        self.assertEqual(stats.get("no_loader"), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)

