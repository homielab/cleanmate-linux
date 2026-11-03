"""Previews for the file pages (Large & Old Files, Duplicates, Similar Photos): small pictures in the rows, a big
picture of the photo you point at, and Open with the default app.

Pictures are read on background threads and kept per file (for as long as its size and date stay the same), so
a list of thousands of photos scrolls without waiting and showing it again reads nothing twice. A picture the
file manager already made (the freedesktop thumbnail cache) is used first; a video's frame needs GStreamer,
when the system has it. Reading a file never changes its access date: Large & Old Files goes by it.
"""
import collections
import os
import queue
import threading

import gi
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk, Pango

from .a11y import named
from . import similar
from .i18n import _

THUMB = 40  # px, the picture at the start of a file row
MAX_PIXELS = 25_000_000  # a bigger picture that isn't a JPEG gets no thumbnail: it would decode at full size
CACHE_LIMIT = 2500  # thumbnails kept
PREVIEW = 1024  # px, the big picture is read to fit this box


def media_kind(path):
    """"image", "video" or None, from the file's name (as the file manager guesses it)."""
    content_type = Gio.content_type_guess(os.path.basename(path), None)[0]
    mime = Gio.content_type_get_mime_type(content_type) or ""
    return next((k for k in ("image", "video") if mime.startswith(k + "/")), None)


def cached_thumbnail(path):
    """The file manager's thumbnail of path (the freedesktop thumbnail cache), when there is a valid one."""
    try:
        info = Gio.File.new_for_path(path).query_info("thumbnail::path,thumbnail::is-valid",
                                                      Gio.FileQueryInfoFlags.NONE, None)
    except GLib.Error:
        return None
    thumb = info.get_attribute_byte_string("thumbnail::path")
    if not thumb or (info.has_attribute("thumbnail::is-valid") and not info.get_attribute_boolean("thumbnail::is-valid")):
        return None
    return thumb if os.path.isfile(thumb) else None


_GST, _GST_LOCK = None, threading.Lock()


def gstreamer():
    """The GStreamer module, or None when this system has no GStreamer for Python (videos then get an icon)."""
    global _GST
    with _GST_LOCK:
        if _GST is None:
            try:
                gi.require_version("Gst", "1.0")
                from gi.repository import Gst
                Gst.init(None)
                _GST = Gst
            except (ImportError, ValueError, GLib.Error):
                _GST = False
    return _GST or None


def video_frame(path, size, timeout=5):
    """A frame of the video (a tenth in, at most 10 s; the first frame of a short one) fitted in size × size, or
    None without GStreamer or a decoder for it."""
    Gst = gstreamer()
    if not Gst:
        return None
    try:
        f = similar._open(path)  # by file descriptor: reading leaves the access date as it was
    except OSError:
        return None
    pipeline = None
    try:
        # giostreamsrc, not fdsrc: fdsrc now and then cuts a short Ogg video's headers ("couldn't read header packet")
        pipeline = Gst.parse_launch(
            "giostreamsrc name=src ! decodebin ! videoconvert ! videoscale ! "
            f"video/x-raw,format=RGBA,pixel-aspect-ratio=1/1,width=[1,{size}],height=[1,{size}] ! "
            "appsink name=sink sync=false max-buffers=1 drop=true")
        pipeline.get_by_name("src").set_property("stream", _unix_input_stream(f.fileno()))
        sink = pipeline.get_by_name("sink")
        if pipeline.set_state(Gst.State.PAUSED) == Gst.StateChangeReturn.FAILURE:
            return None
        if pipeline.get_state(timeout * Gst.SECOND)[0] != Gst.StateChangeReturn.SUCCESS:
            return None
        ok, duration = pipeline.query_duration(Gst.Format.TIME)
        if ok and duration > 3 * Gst.SECOND:
            pipeline.seek_simple(Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.KEY_UNIT,
                                 min(duration // 10, 10 * Gst.SECOND))
            pipeline.get_state(timeout * Gst.SECOND)
        sample = sink.emit("pull-preroll")
        if not sample:
            return None
        caps = sample.get_caps().get_structure(0)
        w, h = caps.get_value("width"), caps.get_value("height")
        buf = sample.get_buffer()
        data = buf.extract_dup(0, buf.get_size())
        if len(data) < w * h * 4:
            return None
        pixbuf = GdkPixbuf.Pixbuf.new_from_bytes(GLib.Bytes.new(data), GdkPixbuf.Colorspace.RGB, True, 8,
                                                 w, h, w * 4)
        return fit(pixbuf, size)
    except Exception:  # GLib.Error, a pipeline that can't be built, a decoder that gives up
        return None
    finally:
        if pipeline is not None:
            pipeline.set_state(Gst.State.NULL)  # stop reading before the file is closed
        f.close()


def _unix_input_stream(fd):
    """A Gio stream reading fd, which the caller closes (GioUnix since GLib 2.80, Gio before)."""
    try:
        gi.require_version("GioUnix", "2.0")
        from gi.repository import GioUnix
        return GioUnix.InputStream.new(fd, False)
    except (ImportError, ValueError):
        return Gio.UnixInputStream.new(fd, False)


def fit(pixbuf, size):
    """pixbuf scaled down to fit size × size (never up)."""
    w, h = pixbuf.get_width(), pixbuf.get_height()
    scale = min(size / w, size / h)
    if scale >= 1:
        return pixbuf
    return pixbuf.scale_simple(max(1, round(w * scale)), max(1, round(h * scale)), GdkPixbuf.InterpType.BILINEAR)


def load_thumbnail(path, kind, size):
    """A small picture of an image or video fitted in size × size, or None."""
    cached = cached_thumbnail(path) if size <= 256 else None
    if cached:
        loaded = similar.load_small(cached, size, size, fit=True)
        if loaded:
            return loaded[0]
    if kind == "image":
        loaded = similar.load_small(path, size, size, fit=True, max_pixels=MAX_PIXELS)
        return loaded[0] if loaded else None
    if kind == "video":
        return video_frame(path, size)
    return None


def texture(pixbuf):
    fmt = Gdk.MemoryFormat.R8G8B8A8 if pixbuf.get_has_alpha() else Gdk.MemoryFormat.R8G8B8
    return Gdk.MemoryTexture.new(pixbuf.get_width(), pixbuf.get_height(), fmt, pixbuf.read_pixel_bytes(),
                                 pixbuf.get_rowstride())


class Thumbnails:
    """Small pictures of files, read by two daemon threads the first time a row shows, kept per file."""

    def __init__(self):
        self.cache = collections.OrderedDict()  # (path, stamp, px) → Gdk.Texture, or None: can't be read
        self.waiting = {}  # (path, stamp, px) → [callbacks] of the rows waiting for it
        self.latest = {}  # path → its texture read last (the preview shows it while the big one is read)
        self.jobs = None

    def image(self, path, kind, stamp=None, size=THUMB, icon_name=None, gicon=None, alive=lambda: True):
        """A Gtk.Image of size × size px: the file's icon, then its picture once read. stamp (size, date) tells a
        changed file from the one read before; alive() false = the row is gone, don't read it."""
        image = Gtk.Image(css_classes=["file-thumb"], width_request=size, height_request=size)
        if gicon:
            image.set_from_gicon(gicon)
        else:
            image.set_from_icon_name(icon_name or "text-x-generic-symbolic")
        if kind not in ("image", "video"):
            return image
        key = (path, stamp, size)

        def show(tex):
            if tex:
                image.set_pixel_size(size)
                image.set_from_paintable(tex)

        def mapped(*_a):
            if image.started:
                return
            image.started = True
            self.request(key, kind, show, alive)

        image.started = False
        image.connect("map", mapped)
        return image

    def request(self, key, kind, callback, alive=lambda: True):
        """callback(texture or None) on the main loop, at once when the picture is known."""
        if key in self.cache:
            self.cache.move_to_end(key)
            callback(self.cache[key])
            return
        if key in self.waiting:
            self.waiting[key].append(callback)
            return
        self.waiting[key] = [callback]
        if self.jobs is None:
            self.jobs = queue.Queue()
            for _n in range(2):
                threading.Thread(target=self.read, daemon=True).start()
        self.jobs.put((key, kind, alive))

    def read(self):
        while True:
            key, kind, alive = self.jobs.get()
            path, _stamp, size = key
            pixbuf = load_thumbnail(path, kind, size * 2) if alive() else False  # twice the size: sharp on HiDPI
            GLib.idle_add(self.deliver, key, pixbuf)

    def deliver(self, key, pixbuf):
        callbacks = self.waiting.pop(key, [])
        if pixbuf is False:  # skipped: the row was gone; read it again if it comes back
            return False
        tex = texture(pixbuf) if pixbuf else None
        self.cache[key] = tex
        if tex:
            self.latest[key[0]] = tex
        while len(self.cache) > CACHE_LIMIT:
            (path, _stamp, _size), old = self.cache.popitem(last=False)
            if old is not None and self.latest.get(path) is old:
                del self.latest[path]
        for callback in callbacks:
            callback(tex)
        return False


THUMBNAILS = Thumbnails()  # shared by the pages: a photo shown on two pages is read once


def open_file(window, path):
    """Open the file with its default app; a toast says why when it can't."""
    def done(_source, result):
        try:
            Gio.AppInfo.launch_default_for_uri_finish(result)
        except GLib.Error as e:
            window.toast(_("Could not open {name}: {reason}").format(name=os.path.basename(path), reason=e.message))

    context = window.get_display().get_app_launch_context()
    Gio.AppInfo.launch_default_for_uri_async(Gio.File.new_for_path(path).get_uri(), context, None, done)


def show_in_files(window, path):
    Gtk.FileLauncher.new(Gio.File.new_for_path(path)).open_containing_folder(window, None, None)


def row_buttons(row, window, path):
    """Open and Show in Files buttons at the end of a file row, and Enter on the row opens the file
    (Space and a click still tick its box)."""
    for icon, tip, action in (("document-open-symbolic", _("Open"), lambda *_a: open_file(window, path)),
                              ("folder-open-symbolic", _("Show in Files"), lambda *_a: show_in_files(window, path))):
        button = named(Gtk.Button(icon_name=icon, valign=Gtk.Align.CENTER, css_classes=["flat"], tooltip_text=tip))
        button.connect("clicked", action)
        row.add_suffix(button)
    keys = Gtk.EventControllerKey(propagation_phase=Gtk.PropagationPhase.CAPTURE)

    def pressed(_c, keyval, _code, state):
        if keyval not in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_ISO_Enter) or state & Gdk.ModifierType.CONTROL_MASK:
            return False
        focus = row.get_root().get_focus() if row.get_root() else None
        if isinstance(focus, Gtk.Button) and focus.is_ancestor(row):
            return False  # a button in the row: Enter presses it
        open_file(window, path)
        return True

    keys.connect("key-pressed", pressed)
    row.add_controller(keys)


class PreviewPane(Gtk.Box):
    """The photo you point at or move to with the keyboard, big, with its facts, Open and Show in Files."""

    def __init__(self, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=12, width_request=300,
                         margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        self.window = window
        self.path = None
        self.want = None  # the path asked for last: an older read that finishes later is dropped
        self.pending = 0  # GLib source of a preview waiting for the pointer to rest
        self.jobs = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()
        self.picture = Gtk.Picture(content_fit=Gtk.ContentFit.CONTAIN, can_shrink=True, vexpand=True,
                                   height_request=220, css_classes=["card", "preview-picture"])
        self.placeholder = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, valign=Gtk.Align.CENTER)
        self.placeholder.append(Gtk.Image(icon_name="image-x-generic-symbolic", pixel_size=64,
                                          css_classes=["dim-label"]))
        self.placeholder.append(Gtk.Label(label=_("Point at a photo to see it larger"), wrap=True,
                                          justify=Gtk.Justification.CENTER, css_classes=["dim-label"]))
        self.stack = Gtk.Stack(vexpand=True)
        self.stack.add_named(self.placeholder, "none")
        self.stack.add_named(self.picture, "picture")
        self.append(self.stack)
        self.badge = Gtk.Label(label=_("Suggested to keep"), halign=Gtk.Align.START,
                               css_classes=["keep-badge", "caption-heading"], visible=False)
        self.append(self.badge)
        self.name = Gtk.Label(xalign=0, wrap=True, wrap_mode=Pango.WrapMode.WORD_CHAR, css_classes=["heading"],
                              selectable=True)
        self.facts = Gtk.Label(xalign=0, wrap=True, wrap_mode=Pango.WrapMode.WORD_CHAR, css_classes=["dim-label"])
        self.append(self.name)
        self.append(self.facts)
        buttons = Gtk.Box(spacing=6)
        self.open_button = Gtk.Button(label=_("Open"), tooltip_text=_("Open with the default app"))
        self.open_button.connect("clicked", lambda *_a: self.path and open_file(self.window, self.path))
        self.show_button = Gtk.Button(label=_("Show in Files"))
        self.show_button.connect("clicked", lambda *_a: self.path and show_in_files(self.window, self.path))
        buttons.append(self.open_button)
        buttons.append(self.show_button)
        self.append(buttons)
        self.clear()

    def clear(self):
        self.path = self.want = None
        self.stack.set_visible_child_name("none")
        self.badge.set_visible(False)
        self.name.set_text("")
        self.facts.set_text("")
        self.open_button.set_sensitive(False)
        self.show_button.set_sensitive(False)

    def show_later(self, path, facts, suggested, delay=120):
        """Show path once the pointer rests on its row (moving across rows reads nothing)."""
        if self.pending:
            GLib.source_remove(self.pending)

        def go():
            self.pending = 0
            self.show(path, facts, suggested)
            return False

        self.pending = GLib.timeout_add(delay, go)

    def show(self, path, facts, suggested):
        if self.pending:
            GLib.source_remove(self.pending)
            self.pending = 0
        self.badge.set_visible(suggested)
        self.name.set_text(os.path.basename(path))
        self.facts.set_text(facts)
        self.open_button.set_sensitive(True)
        self.show_button.set_sensitive(True)
        if path == self.path:
            return
        self.path = self.want = path
        # the row's picture at once (blank until read), the sharp one when read
        self.picture.set_paintable(THUMBNAILS.latest.get(path))
        self.stack.set_visible_child_name("picture")
        self.jobs.put(path)

    def read(self):
        while True:
            path = self.jobs.get()
            if path != self.want:
                continue
            loaded = similar.load_small(path, PREVIEW, PREVIEW, fit=True, max_pixels=MAX_PIXELS)
            GLib.idle_add(self.loaded, path, loaded[0] if loaded else None)

    def loaded(self, path, pixbuf):
        if path != self.want:
            return False
        if pixbuf:
            self.picture.set_paintable(texture(pixbuf))
            self.stack.set_visible_child_name("picture")
        elif not self.picture.get_paintable():
            self.stack.set_visible_child_name("none")
        return False
