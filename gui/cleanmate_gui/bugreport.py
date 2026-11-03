"""Main menu › Report a Bug…, Suggest a Feature… and Share CleanMate.

Report a Bug… shows the system details the engine gathers (`--json sysreport`, the same text `cm --version`
prints) before anything opens; Open GitHub opens a new issue in the browser with them filled in. Each item
only opens the browser or copies text: CleanMate itself sends nothing.
"""
from urllib.parse import quote

from gi.repository import Adw, Gtk

from .i18n import _

REPO_URL = "https://github.com/homielab/cleanmate-linux"
WEBSITE_URL = "https://cleanmate.homielab.com"
# issue templates in .github/ISSUE_TEMPLATE/ and the form field the report fills
BUG_TEMPLATE = "bug_report.yml"
FEATURE_TEMPLATE = "feature_request.yml"
REPORT_FIELD = "system"
# A prefilled link longer than this doesn't open (GitHub answered 500 or 414 from about 7 300 characters in
# 2026-11), so the report is copied instead. Counted on the encoded link: the encoding can triple the text.
MAX_LINK = 6000


def issue_url(template, fields=()):
    """A new issue from that template, its form fields filled from (field id, text) pairs.

    Everything but unreserved characters is percent-encoded: GitHub reads a `+` in a query as a space."""
    items = [("template", template), *fields]
    return f"{REPO_URL}/issues/new?" + "&".join(f"{k}={quote(v, safe='-._~')}" for k, v in items)


def report_link(body):
    """(url, fits): the prefilled bug report, or the bare template when the details don't fit in a link."""
    url = issue_url(BUG_TEMPLATE, [(REPORT_FIELD, body)])
    return (url, True) if len(url) <= MAX_LINK else (issue_url(BUG_TEMPLATE), False)


def copy(win, text):
    win.get_clipboard().set(text)


def share(win):
    """Copy the website link to share; a toast says so."""
    copy(win, WEBSITE_URL)
    win.toast(_("Link copied: {link}").format(link=WEBSITE_URL.split("//", 1)[1]))


def suggest_feature(win):
    win._open_url(issue_url(FEATURE_TEMPLATE))


def report_bug(win, extra=None):
    """Ask the engine for the system details, then show them (`show_report`); EXTRA (what an error page
    copies) goes below them, and alone when the engine can't answer."""
    found = {}

    def on_event(e):
        if e.get("event") == "sysreport":
            found.update(e)

    def on_done(ok, _status):
        win.set_busy(False)
        body = "\n\n".join(part for part in (found.get("body"), extra) if part)
        if body:
            show_report(win, body)
        else:
            win.toast(_("Could not read the system details."))

    win.set_busy(True)
    win.engine.run(["sysreport"], on_event, on_done)


def show_report(win, body):
    """The report text, read-only but selectable; Open GitHub, Copy or Cancel. Returns the dialog."""
    view = Gtk.TextView(editable=False, monospace=True, wrap_mode=Gtk.WrapMode.WORD_CHAR, cursor_visible=False,
                        top_margin=6, bottom_margin=6, left_margin=6, right_margin=6)
    view.get_buffer().set_text(body)
    scroll = Gtk.ScrolledWindow(child=view, min_content_height=200, min_content_width=420,
                                hscrollbar_policy=Gtk.PolicyType.NEVER, css_classes=["card"])
    dialog = Adw.AlertDialog(
        heading=_("Report a Bug"),
        body=_("Open GitHub opens a new issue in your browser with the details below filled in; describe the "
               "problem there. Nothing is sent until you submit the issue, and no user name or personal file "
               "path is included."),
        extra_child=scroll)
    dialog.add_response("cancel", _("Cancel"))
    dialog.add_response("copy", _("Copy"))
    dialog.add_response("open", _("Open GitHub"))
    dialog.set_response_appearance("open", Adw.ResponseAppearance.SUGGESTED)
    dialog.set_default_response("open")
    dialog.set_close_response("cancel")

    def on_response(_d, response):
        if response == "open":
            open_report(win, body)
        elif response == "copy":
            copy(win, body)
            win.toast(_("Report copied"))

    dialog.connect("response", on_response)
    dialog.present(win)
    win.report_dialog = dialog
    return dialog


def open_report(win, body):
    """Open the prefilled issue; a report too long for the link is copied first and the user told to paste it."""
    url, fits = report_link(body)
    if fits:
        win._open_url(url)
        return None
    copy(win, body)
    notice = Adw.AlertDialog(
        heading=_("Report copied"),
        body=_("The details are too long for the link. Paste them into “System details” on the GitHub page."))
    notice.add_response("open", _("Open GitHub"))
    notice.set_default_response("open")
    notice.set_close_response("open")
    notice.connect("response", lambda *_: win._open_url(url))
    notice.present(win)
    win.report_dialog = notice
    return notice
