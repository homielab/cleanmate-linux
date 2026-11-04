"""Similar Photos, the logic: find photos that look alike (a resized or re-saved copy, an edit, shots taken
one after another), on this computer, with nothing but GdkPixbuf.

Each photo is decoded at 32 × 32 pixels and gets two 64-bit perceptual hashes: a DCT hash (the shape of the
picture's brightness) and a difference hash (which way brightness goes between neighbouring pixels). Two
photos are close when both hashes differ in few bits; a group is a set of photos that are all close to each
other (complete linkage), so a chain of small changes never pulls two different photos together.
The page (`duplicates.py`) shows the groups; moving to the Trash and undo go through the engine.
"""
import math
import os
import stat
import threading

import gi

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, GLib  # noqa: E402

# Photos only: JPEG, PNG, WebP, HEIC/HEIF, TIFF, AVIF, when this system's GdkPixbuf can read them
# (WebP needs webp-pixbuf-loader, HEIC/AVIF heif-gdk-pixbuf / libavif).
PHOTO_EXTENSIONS = {"jpg", "jpeg", "jpe", "png", "webp", "heic", "heif", "tif", "tiff", "avif"}
MIN_BYTES = 20 << 10  # smaller files are icons and thumbnails, not photos
# A folder with one of these files is a photo manager's library (Shotwell, digiKam): its photos are left to it.
LIBRARY_FILES = {"photo.db", "digikam4.db", "thumbnails-digikam.db"}
# Bits two close photos may differ by. Measured: a resized, re-saved, brightened or 3 % cropped copy differs by
# 0–4 (DCT) and 0–6 (difference) bits, different photos by 20 or more; screenshots of different pages of one
# app come as close as 6 and 5, so it takes both hashes.
DCT_MAX = 6
DIFF_MAX = 10
GROUPS_LIMIT = 500  # the biggest groups are listed, like Duplicates

if hasattr(int, "bit_count"):
    def distance(a, b):
        """Hamming distance of two 64-bit hashes."""
        return (a ^ b).bit_count()
else:  # Python < 3.10
    def distance(a, b):
        return bin(a ^ b).count("1")


def readable_extensions():
    """The photo extensions this system's GdkPixbuf has a loader for."""
    found = {ext.lower() for f in GdkPixbuf.Pixbuf.get_formats() for ext in f.get_extensions()}
    return PHOTO_EXTENSIONS & found


def excluded(path, exclusions):
    return any(path == ex or path.startswith(ex.rstrip("/") + "/") for ex in exclusions)


def find_photos(folder, exclusions=(), cancelled=lambda: False, min_bytes=MIN_BYTES, extensions=None):
    """Photos under folder: [{"path", "bytes", "mtime"}]. Leaves out hidden folders, Never clean folders,
    photo manager libraries, links, hard links to a photo already listed and names that aren't UTF-8."""
    extensions = readable_extensions() if extensions is None else extensions
    folder = os.path.abspath(folder)
    if excluded(folder, exclusions):
        return []
    photos, seen = [], set()
    for top, dirs, files in os.walk(folder, onerror=lambda _e: None):
        if cancelled():
            return []
        if LIBRARY_FILES.intersection(files):
            dirs[:] = []
            continue
        dirs[:] = sorted(d for d in dirs if not d.startswith(".") and not excluded(os.path.join(top, d), exclusions))
        for name in sorted(files):
            if name.rpartition(".")[2].lower() not in extensions or "." not in name:
                continue
            path = os.path.join(top, name)
            try:
                path.encode("utf-8")
                st = os.lstat(path)
            except (UnicodeEncodeError, OSError):
                continue
            if not stat.S_ISREG(st.st_mode) or st.st_size < min_bytes or (st.st_dev, st.st_ino) in seen:
                continue
            seen.add((st.st_dev, st.st_ino))
            photos.append({"path": path, "bytes": st.st_size, "mtime": int(st.st_mtime)})
    return photos


_ARITHMETIC = threading.Lock()

# DCT-II basis for 32 samples, the first 8 frequencies only (the hash keeps the 8 × 8 lowest)
_COS = [[math.cos((2 * x + 1) * u * math.pi / 64) for x in range(32)] for u in range(8)]


def _gray(pixbuf):
    """Rows of brightness 0–255; transparent pixels count as white."""
    w, h = pixbuf.get_width(), pixbuf.get_height()
    n, stride, alpha = pixbuf.get_n_channels(), pixbuf.get_rowstride(), pixbuf.get_has_alpha()
    data = pixbuf.get_pixels()
    rows = []
    for y in range(h):
        line = data[y * stride:y * stride + w * n]
        row = [0.299 * r + 0.587 * g + 0.114 * b for r, g, b in zip(line[0::n], line[1::n], line[2::n])]
        if alpha:
            row = [v * (a / 255) + 255 * (1 - a / 255) for v, a in zip(row, line[3::n])]
        rows.append(row)
    return rows


def dct_hash(gray):
    """64 bits: the 8 × 8 lowest frequencies of the 32 × 32 DCT, each above or below their median."""
    rows = [[sum(c * v for c, v in zip(_COS[u], line)) for u in range(8)] for line in gray]
    coef = [sum(_COS[v][y] * rows[y][u] for y in range(32)) for v in range(8) for u in range(8)]
    median = sorted(coef[1:])[31]  # the DC term (overall brightness) is left out of the median
    bits = 0
    for c in coef:
        bits = bits << 1 | (c > median)
    return bits


def diff_hash(gray):
    """64 bits: for 8 rows of 9 brightness values, whether each is brighter than the next."""
    bits = 0
    for row in gray:
        for a, b in zip(row, row[1:]):
            bits = bits << 1 | (a > b)
    return bits


def _open(path):
    """The file for reading, without changing its access date when you own it (so reading a photo never makes
    it look recently used: Old Screenshots goes by that date)."""
    cloexec = getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(path, os.O_RDONLY | cloexec | getattr(os, "O_NOATIME", 0))
    except PermissionError:  # O_NOATIME is only for the file's owner
        fd = os.open(path, os.O_RDONLY | cloexec)
    return os.fdopen(fd, "rb")


def load_small(path, width, height, fit=False, max_pixels=None):
    """(pixbuf of the photo at width × height — fit: its shape kept inside that box —, full width, full height),
    turned upright by its EXIF orientation; None when it can't be read. max_pixels: give up on a bigger picture,
    unless it is a JPEG (only JPEG decodes straight at the small size; other formats decode at full size first)."""
    loader, full, too_big = GdkPixbuf.PixbufLoader(), [], []

    def prepared(ld, w, h):
        full[:] = [w, h]
        fmt = ld.get_format()
        if max_pixels and w * h > max_pixels and (fmt.get_name() if fmt else "") != "jpeg":
            too_big.append(True)
            ld.set_size(1, 1)  # never allocate the full picture
            return
        if fit:
            scale = min(width / w, height / h, 1)
            ld.set_size(max(1, round(w * scale)), max(1, round(h * scale)))
        else:
            ld.set_size(width, height)

    loader.connect("size-prepared", prepared)
    try:
        with _open(path) as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                loader.write(chunk)
                if too_big:
                    raise ValueError("too big")
        loader.close()  # a small file is only read here
        if too_big:
            return None
        pixbuf = loader.get_pixbuf()
    except Exception:  # GLib.Error, OSError, or a loader that gives up half way
        try:
            loader.close()
        except GLib.Error:  # closing a loader that already gave up fails too; the photo is skipped either way
            pass
        return None
    if pixbuf is None or not full:
        return None
    return pixbuf.apply_embedded_orientation() or pixbuf, full[0], full[1]


def photo_hashes(path):
    """(dct hash, difference hash, width, height) of a photo, or None when it can't be read."""
    loaded = load_small(path, 32, 32)
    if not loaded:
        return None
    small, width, height = loaded
    if small.get_width() != 32 or small.get_height() != 32:
        small = small.scale_simple(32, 32, GdkPixbuf.InterpType.BILINEAR)
    tiny = small.scale_simple(9, 8, GdkPixbuf.InterpType.BILINEAR)
    # Decoding runs in parallel without the GIL; the arithmetic in Python needs it, so one thread at a time does
    # it: the window then competes with one busy thread, not eight, and stays responsive.
    with _ARITHMETIC:
        return dct_hash(_gray(small)), diff_hash(_gray(tiny)), width, height


def hash_photos(photos, cancelled=lambda: False, progress=lambda done, total: None, workers=None):
    """Add "dct", "diff", "width", "height" to each photo that can be read; return those ([] when cancelled).
    Several threads decode at once (GdkPixbuf lets go of the GIL while it decodes); they are daemon threads, so
    quitting the app never waits for them."""
    total, results, lock, state = len(photos), [None] * len(photos), threading.Lock(), {"next": 0, "done": 0}

    def run():
        while not cancelled():
            with lock:
                i = state["next"]
                state["next"] += 1
            if i >= total:
                return
            results[i] = photo_hashes(photos[i]["path"])
            with lock:
                state["done"] += 1
                done = state["done"]
            progress(done, total)

    threads = [threading.Thread(target=run, daemon=True)
               for _n in range(max(1, min(workers or os.cpu_count() or 2, 8, total)))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if cancelled():
        return []
    read = []
    for photo, hashes in zip(photos, results):
        if hashes:
            photo["dct"], photo["diff"], photo["width"], photo["height"] = hashes
            read.append(photo)
    return read


def close(a, b):
    return distance(a["dct"], b["dct"]) <= DCT_MAX and distance(a["diff"], b["diff"]) <= DIFF_MAX


def _close_pairs(photos, cancelled):
    """(distance, i, j) for every close pair, found through a BK-tree of the DCT hashes."""
    tree = None  # [index, {distance: subtree}]
    pairs = []
    for j, p in enumerate(photos):
        if j % 256 == 0 and cancelled():
            return None
        h = p["dct"]
        if tree is not None:
            stack = [tree]
            while stack:
                i, children = stack.pop()
                d = distance(photos[i]["dct"], h)
                if d <= DCT_MAX and distance(photos[i]["diff"], p["diff"]) <= DIFF_MAX:
                    pairs.append((d + distance(photos[i]["diff"], p["diff"]), i, j))
                stack.extend(sub for k, sub in children.items() if d - DCT_MAX <= k <= d + DCT_MAX)
            node = tree
            while True:
                d = distance(photos[node[0]]["dct"], h)
                if d not in node[1]:
                    node[1][d] = [j, {}]
                    break
                node = node[1][d]
        else:
            tree = [j, {}]
    return pairs


def keep_key(photo):
    """The photo to keep: most pixels, then the biggest file, then the newest."""
    return photo["width"] * photo["height"], photo["bytes"], photo["mtime"]


def group_photos(photos, cancelled=lambda: False):
    """Groups of photos that are all close to each other, the one to keep first; groups with most to free first.
    Each group: {"key": a stable id, "files": the photos}. None when cancelled."""
    pairs = _close_pairs(photos, cancelled)
    if pairs is None:
        return None
    near = {(i, j) for _d, i, j in pairs}
    # closest pairs merge first. Buckets, not sorted(): a sort of millions of pairs holds the GIL in one call and
    # freezes the window; a loop lets the main thread run
    by_distance = [[] for _d in range(DCT_MAX + DIFF_MAX + 1)]
    for d, i, j in pairs:
        by_distance[d].append((i, j))
    del pairs
    cluster = {}  # index → its member list (shared)
    for i, j in (pair for bucket in by_distance for pair in bucket):
        a, b = cluster.get(i, [i]), cluster.get(j, [j])
        if a is b or not all((min(x, y), max(x, y)) in near for x in a for y in b):
            continue
        merged = a + b
        for k in merged:
            cluster[k] = merged
    groups, done = [], set()
    for members in cluster.values():
        if id(members) in done:
            continue
        done.add(id(members))
        files = sorted((photos[k] for k in members), key=keep_key, reverse=True)
        groups.append({"key": "photos:" + files[0]["path"], "files": files})
    groups.sort(key=lambda g: (-freeable(g), g["key"]))
    return groups


def keeper(g):
    """Path of the photo the group suggests keeping."""
    return max(g["files"], key=keep_key)["path"]


def freeable(g):
    """Bytes freed by keeping only the suggested photo."""
    keep = keeper(g)
    return sum(f["bytes"] for f in g["files"] if f["path"] != keep)
