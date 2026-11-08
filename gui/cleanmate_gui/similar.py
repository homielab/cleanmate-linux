"""Similar Photos, the logic: find photos that look alike (a resized or re-saved copy, an edit, shots taken
one after another), on this computer, with nothing but GdkPixbuf.

Each photo is decoded at 32 × 32 pixels and gets two 64-bit perceptual hashes: a DCT hash (the shape of the
picture's brightness) and a difference hash (which way brightness goes between neighbouring pixels). Two
photos are close when both hashes differ in few bits; a group is a set of photos that are all close to each
other (complete linkage), so a chain of small changes never pulls two different photos together.
The hashes are kept in a cache file (by path, size and modification time), so the next search reads only the
photos that are new or changed.
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


def find_photos(folder, exclusions=(), cancelled=lambda: False, min_bytes=MIN_BYTES, extensions=None, stats=None):
    """Photos under folder: [{"path", "bytes", "mtime"}]. Leaves out hidden folders, Never clean folders,
    photo manager libraries, links, hard links to a photo already listed and names that aren't UTF-8.
    `stats`, when given, gets "no_loader": how many files have a known photo extension this system's GdkPixbuf
    cannot read (HEIC/WebP/AVIF without its loader) — reported to the user, never silently dropped."""
    extensions = readable_extensions() if extensions is None else extensions
    no_loader_for = PHOTO_EXTENSIONS - extensions
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
            ext = name.rpartition(".")[2].lower()
            if "." not in name or ext not in extensions:
                if stats is not None and ext in no_loader_for:
                    stats["no_loader"] = stats.get("no_loader", 0) + 1
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
            photos.append({"path": path, "bytes": st.st_size, "mtime": int(st.st_mtime), "mtime_ns": st.st_mtime_ns})
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


# ── the hash cache: path, size and modification time → hashes, one line a photo ──
CACHE_HEADER = "# cleanmate similar-hashes 1"  # a new hash method changes the version: old lines are read again
UNREADABLE = None  # cached for a photo GdkPixbuf can't read: it isn't tried again until it changes


def cache_file():
    """~/.cache/cleanmate/similar-hashes.tsv (XDG_CACHE_HOME)."""
    return os.path.join(GLib.get_user_cache_dir(), "cleanmate", "similar-hashes.tsv")


def _stamp(photo):
    return photo["bytes"], photo.get("mtime_ns", photo["mtime"])


def load_cache(path):
    """{photo path: ((bytes, mtime_ns), hashes or UNREADABLE)}; {} when the file is missing, unreadable or of
    another version. A damaged line is skipped."""
    cache = {}
    try:
        with open(path, encoding="utf-8", errors="strict") as f:
            if f.readline().rstrip("\n") != CACHE_HEADER:
                return {}
            for line in f:
                try:
                    p, size, mtime, dct, diff, width, height = line.rstrip("\n").split("\t")
                    stamp = (int(size), int(mtime))
                    hashes = UNREADABLE if dct == "-" else (int(dct, 16), int(diff, 16), int(width), int(height))
                except ValueError:
                    continue
                if p.startswith("/"):
                    cache[p] = (stamp, hashes)
    except (OSError, UnicodeDecodeError):
        return {}
    return cache


def save_cache(path, cache):
    """Write the cache in one go (a new file moved over the old one, so a crash never leaves half a file); readable
    only by you, since it lists your photos. Nothing happens when it can't be written."""
    folder = os.path.dirname(path)
    tmp = f"{path}.{os.getpid()}.tmp"
    try:
        os.makedirs(folder, mode=0o700, exist_ok=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_CLOEXEC", 0), 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(CACHE_HEADER + "\n")
            for p, ((size, mtime), hashes) in sorted(cache.items()):
                if "\t" in p or "\n" in p:
                    continue  # a name with a tab or line break doesn't fit a line: it is read again next time
                if hashes is UNREADABLE:
                    f.write(f"{p}\t{size}\t{mtime}\t-\t-\t0\t0\n")
                else:
                    dct, diff, width, height = hashes
                    f.write(f"{p}\t{size}\t{mtime}\t{dct:x}\t{diff:x}\t{width}\t{height}\n")
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _still_there(path, stamp):
    """True when the photo of a cache line outside this search is still the same file (kept for its own folder's
    next search); a deleted or changed one is dropped."""
    try:
        st = os.stat(path)
    except OSError:
        return False
    return (st.st_size, st.st_mtime_ns) == stamp


def hash_photos(photos, cancelled=lambda: False, progress=lambda done, total: None, workers=None, cache=None):
    """Add "dct", "diff", "width", "height" to each photo that can be read; return those ([] when cancelled).
    Several threads decode at once (GdkPixbuf lets go of the GIL while it decodes); they are daemon threads, so
    quitting the app never waits for them. cache: the hash cache file (cache_file()): photos it has with the same
    size and modification time aren't read again; what was read is written back, also when cancelled."""
    known = load_cache(cache) if cache else {}
    total, results, lock = len(photos), [None] * len(photos), threading.Lock()
    got = [False] * total  # from the cache, or read in this run: written back
    todo = []
    for i, photo in enumerate(photos):
        hit = known.get(photo["path"])
        if hit and hit[0] == _stamp(photo):
            results[i], got[i] = hit[1], True
        else:
            todo.append(i)
    state = {"next": 0, "done": total - len(todo)}
    if state["done"]:
        progress(state["done"], total)

    def run():
        while not cancelled():
            with lock:
                k = state["next"]
                state["next"] += 1
            if k >= len(todo):
                return
            i = todo[k]
            results[i] = photo_hashes(photos[i]["path"])
            got[i] = True
            with lock:
                state["done"] += 1
                done = state["done"]
            progress(done, total)

    threads = [threading.Thread(target=run, daemon=True)
               for _n in range(max(1, min(workers or os.cpu_count() or 2, 8, len(todo))))] if todo else []
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if cache:
        listed = {p["path"] for p in photos}
        fresh = {p: hit for p, hit in known.items() if p not in listed and _still_there(p, hit[0])}
        for i, photo in enumerate(photos):
            if got[i]:
                fresh[photo["path"]] = (_stamp(photo), results[i])
        save_cache(cache, fresh)
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
