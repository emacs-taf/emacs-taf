#!/usr/bin/env python3
"""Capture a command's terminal output as a PNG and a plain-text screen.

The command runs in its own pseudo-terminal of the requested size, so a
full-screen program lays itself out exactly as it would in a real terminal.
pyte interprets the escape sequences it writes, Pillow renders the resulting
screen, and the same screen is written beside the image as text, for diffs and
assertions. This is the acceptance path for terminal (TUI) behaviour; it does
not replace a GUI capture of a graphical frame.

Dependencies: pyte and Pillow (``pip install pyte pillow``) on macOS or Linux.

    python3 scripts/tui-capture.py --cols 80 --rows 24 --out /tmp/app.png -- \
        /opt/homebrew/bin/emacs -nw -Q -l /tmp/probe.el

``--out`` receives the image and ``<out>.txt`` the text screen; both are written
even when the command times out or exits with a failure. The exit status is the
command's own, 124 after ``--timeout`` and 2 for a usage error.
"""
from __future__ import annotations

import argparse
import codecs
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time
import unicodedata
from pathlib import Path

try:
    import pyte
except ImportError:  # Reported by main() so --help works without the modules.
    pyte = None

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    Image = ImageDraw = ImageFont = None

DEFAULT_COLUMNS = 120
DEFAULT_ROWS = 40
DEFAULT_TIMEOUT = 90.0
FONT_SIZE = 16
CELL_HEIGHT = 18
MAX_CELLS = 200000
BACKGROUND = (24, 24, 24)
FOREGROUND = (220, 220, 220)
PROGRAM = "tui-capture.py"

ANSI_COLORS = {
    "black": (0, 0, 0), "red": (205, 49, 49), "green": (13, 188, 121),
    "brown": (229, 229, 16), "blue": (36, 114, 200), "magenta": (188, 63, 188),
    "cyan": (17, 168, 205), "white": (229, 229, 229),
}
BRIGHT_COLORS = {
    "black": (102, 102, 102), "red": (241, 76, 76), "green": (35, 209, 139),
    "brown": (245, 245, 67), "blue": (59, 142, 234), "magenta": (214, 112, 214),
    "cyan": (41, 184, 219), "white": (255, 255, 255),
}
XTERM_BASE = (
    (0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0), (0, 0, 128),
    (128, 0, 128), (0, 128, 128), (192, 192, 192), (128, 128, 128),
    (255, 0, 0), (0, 255, 0), (255, 255, 0), (0, 0, 255), (255, 0, 255),
    (0, 255, 255), (255, 255, 255),
)

# Sarasa Mono SC first: it measures ASCII and CJK at a clean 1:2 and is what
# this workspace's terminal screenshots are drawn with. Every path is probed;
# a missing font file, or all of them missing, falls back to Menlo, DejaVu and
# finally Pillow's own default.
FONT_CANDIDATES = (
    ("Sarasa Mono SC", (
        "~/Library/Fonts/Sarasa-Regular.ttc",
        "~/Library/Fonts/SarasaMonoSC-Regular.ttf",
        "/Library/Fonts/Sarasa-Regular.ttc",
        "/Library/Fonts/SarasaMonoSC-Regular.ttf",
        "/usr/share/fonts/truetype/sarasa/Sarasa-Regular.ttc",
        "/usr/share/fonts/opentype/sarasa/Sarasa-Regular.ttc",
    )),
    ("Menlo", ("/System/Library/Fonts/Menlo.ttc", "/Library/Fonts/Menlo.ttc")),
    ("DejaVu Sans Mono", (
        "/Library/Fonts/DejaVuSansMono.ttf",
        "/System/Library/Fonts/Supplemental/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    )),
)

SGR = re.compile(r"\x1b\[([0-9;:]*)m")
ESCAPE_ARGUMENT = frozenset(b"()*+-./#%")


class CaptureError(Exception):
    """A problem reported to the user as one line, without a traceback."""


def normalize_sgr(text):
    """Rewrite ISO 8613-6 colon SGR parameters into the semicolon form pyte reads.

    Emacs emits ``ESC[38:2::r:g:b m`` for truecolor faces. pyte only parses
    semicolons and would draw the parameters as text, so colors are converted
    here. A colon parameter that is not a color keeps its first field, which is
    the attribute pyte does know (the underline style ``4:3`` becomes ``4``).
    """
    def fix(match):
        parameters = match.group(1)
        if ":" not in parameters:
            return match.group(0)
        out = []
        for part in parameters.split(";"):
            fields = part.split(":")
            if len(fields) == 1:
                out.append(part)
            elif fields[0] in ("38", "48", "58") and fields[1] == "2":
                values = [value for value in fields[2:] if value]
                out.append(";".join([fields[0], "2"] + values[-3:])
                           if len(values) >= 3 else fields[0])
            elif fields[0] in ("38", "48", "58") and fields[1] == "5" and len(fields) > 2:
                out.append(";".join([fields[0], "5", fields[2]]))
            else:
                out.append(fields[0])
        return "\x1b[" + ";".join(out) + "m"

    return SGR.sub(fix, text)


def escape_end(data, start):
    """Return the index just past the escape sequence at START, or None."""
    if start + 1 >= len(data):
        return None
    kind = data[start + 1]
    if kind == 0x5B:                       # CSI: parameters, then a final byte.
        for index in range(start + 2, len(data)):
            if 0x40 <= data[index] <= 0x7E:
                return index + 1
        return None
    if kind == 0x5D:                       # OSC: text, then BEL or ESC backslash.
        index = start + 2
        while index < len(data):
            if data[index] == 0x07:
                return index + 1
            if data[index] == 0x1B:
                if index + 1 >= len(data):
                    return None
                if data[index + 1] == 0x5C:
                    return index + 2
            index += 1
        return None
    if kind in ESCAPE_ARGUMENT:            # Charset designator: ESC ( B.
        return start + 3 if start + 2 < len(data) else None
    return start + 2


def complete_prefix_length(data):
    """Return the length of DATA that ends outside an unfinished escape sequence."""
    index = 0
    while True:
        index = data.find(0x1B, index)
        if index < 0:
            return len(data)
        end = escape_end(data, index)
        if end is None:
            return index
        index = end


class TerminalFeeder:
    """Feed pty bytes to a pyte stream, holding what is not decodable yet.

    Reads split SGR sequences and multi-byte characters at arbitrary byte
    offsets. Holding the unfinished tail means ``normalize_sgr`` only sees whole
    sequences and pyte only receives complete UTF-8, so neither parameter text
    nor replacement characters reach the screen.
    """

    def __init__(self, stream):
        self.stream = stream
        self.held = b""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def feed(self, data):
        if not data:
            return
        self.held += data
        cut = complete_prefix_length(self.held)
        if cut:
            chunk, self.held = self.held[:cut], self.held[cut:]
            text = self.decoder.decode(chunk)
            if text:
                self.stream.feed(normalize_sgr(text))

    def flush(self):
        """Flush a trailing partial character; a half-written escape is dropped."""
        text = self.decoder.decode(b"", final=True)
        if text:
            self.stream.feed(normalize_sgr(text))
        self.held = b""


def xterm_256(index):
    """Return the RGB of an xterm 256-colour index, or None outside the range."""
    if 0 <= index <= 15:
        return XTERM_BASE[index]
    if 16 <= index <= 231:
        index -= 16
        return tuple(0 if value == 0 else 55 + 40 * value
                     for value in (index // 36, (index // 6) % 6, index % 6))
    if 232 <= index <= 255:
        level = 8 + 10 * (index - 232)
        return (level, level, level)
    return None


def parse_color(value, default):
    """Convert a pyte colour attribute (name, index or hex) into RGB."""
    if value is None or value == "default":
        return default
    if isinstance(value, int):
        return xterm_256(value) or default
    text = str(value)
    if text.isdigit():
        return xterm_256(int(text)) or default
    if re.fullmatch(r"#?[0-9a-fA-F]{6}", text):
        text = text.lstrip("#")
        return tuple(int(text[index:index + 2], 16) for index in (0, 2, 4))
    if text.startswith("bright"):
        return BRIGHT_COLORS.get(text[6:], default)
    return ANSI_COLORS.get(text, default)


class Metrics:
    """Pixel size of one emulated terminal cell, and the font that draws it."""

    def __init__(self, font, description):
        self.font = font
        self.description = description
        advance = font.getlength("M")
        self.cell_width = max(1, int(round(advance))) if advance > 0 else 1
        self.cell_height = CELL_HEIGHT

    def span(self, text):
        """Return the cells TEXT occupies, from its advance in the font.

        East Asian wide and fullwidth characters always take two cells: pyte
        lays them out that way, and a terminal falls back to a CJK font for a
        font that lacks the glyph. Everything else follows the font advance, so
        an ambiguous symbol such as U+25AE that the font draws two cells wide
        shows the half-cell offset instead of hiding it.
        """
        if len(text) != 1:
            return 2
        if unicodedata.east_asian_width(text) in ("W", "F"):
            return 2
        width = self.font.getlength(text)
        return max(1, min(2, int(round(width / float(self.cell_width)))))


def open_font(path, index=None):
    """Open PATH at FONT_SIZE, choosing the Mono SC face of a collection."""
    if index is not None:
        return ImageFont.truetype(str(path), FONT_SIZE, index=index)
    first = None
    for candidate in range(64):
        try:
            font = ImageFont.truetype(str(path), FONT_SIZE, index=candidate)
        except OSError:
            break
        if "Mono SC" in font.getname()[0]:
            return font
        if first is None:
            first = font
    return first


def split_font_spec(spec):
    """Split ``PATH[:INDEX]``, accepting the colon only before an existing file."""
    head, _, tail = spec.rpartition(":")
    if head and tail.isdigit() and Path(head).expanduser().is_file():
        return Path(head).expanduser(), int(tail)
    return Path(spec).expanduser(), None


def load_font(spec):
    """Return (font, description) for an explicit font or the first candidate."""
    if spec:
        path, index = split_font_spec(spec)
        if not path.is_file():
            raise CaptureError("font file not found: %s" % path)
        font = open_font(path, index)
        if font is None:
            raise CaptureError("cannot open font: %s" % path)
        return font, "%s%s" % (path.name, "" if index is None else ":%d" % index)
    for name, paths in FONT_CANDIDATES:
        for candidate in paths:
            path = Path(candidate).expanduser()
            if path.is_file():
                font = open_font(path)
                if font is not None:
                    return font, name
    try:
        return ImageFont.load_default(size=FONT_SIZE), "Pillow default"
    except TypeError:
        return ImageFont.load_default(), "Pillow default"


def walk_row(screen, y, columns, metrics):
    """Yield (column, span, text, cell) for the drawn cells of one screen row.

    pyte stores an empty continuation cell after a two-cell character; the
    column advances by the glyph's advance in the rendering font and the
    continuation cell is skipped, so the image and the text screen agree.
    """
    column = 0
    index = 0
    row = screen.buffer[y]
    while index < columns and column < columns:
        cell = row[index]
        text = cell.data
        if text == "":
            index += 1
            continue
        span = min(metrics.span(text), columns - column)
        yield column, span, text, cell
        column += span
        index += 1


def screen_text(screen, metrics, columns, rows):
    """Return the final screen as text, one line per row, without trailing blanks.

    The walking is the same one the image uses, so a continuation cell is
    skipped. No padding is inserted for a wide glyph: the text keeps exactly
    the characters the emulated screen holds, which is what assertions and
    diffs read.
    """
    lines = []
    for y in range(rows):
        parts = [text for _column, _span, text, _cell
                 in walk_row(screen, y, columns, metrics)]
        lines.append("".join(parts).rstrip())
    return "\n".join(lines) + "\n"


def render_image(screen, metrics, columns, rows):
    """Draw the final screen into a new RGB image."""
    image = Image.new("RGB", (columns * metrics.cell_width, rows * metrics.cell_height),
                      BACKGROUND)
    draw = ImageDraw.Draw(image)
    font = metrics.font
    width = metrics.cell_width
    height = metrics.cell_height
    for y in range(rows):
        for column, span, text, cell in walk_row(screen, y, columns, metrics):
            foreground = parse_color(cell.fg, FOREGROUND)
            background = parse_color(cell.bg, BACKGROUND)
            if cell.reverse:
                foreground, background = background, foreground
            left = column * width
            top = y * height
            right = (column + span) * width - 1
            draw.rectangle([left, top, right, top + height - 1], fill=background)
            if text.strip():
                draw.text((left, top), text, font=font, fill=foreground,
                          stroke_width=0.4 if cell.bold else 0, stroke_fill=foreground)
            if cell.underscore:
                draw.line([left, top + height - 2, right - 1, top + height - 2], fill=foreground)
            if getattr(cell, "strikethrough", False):
                draw.line([left, top + height // 2, right - 1, top + height // 2], fill=foreground)
    return image


def child_environment():
    """Return the environment the captured command runs in."""
    environment = dict(os.environ)
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["LANG"] = "en_US.UTF-8"
    environment.pop("LC_ALL", None)
    environment.pop("INSIDE_EMACS", None)
    return environment


def exec_child(master, slave, command):
    """Become COMMAND in a new session whose controlling terminal is SLAVE."""
    try:
        os.close(master)
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for descriptor in (0, 1, 2):
            os.dup2(slave, descriptor)
        if slave > 2:
            os.close(slave)
        os.execvpe(command[0], command, child_environment())
    except BaseException as error:         # The child must never return here.
        try:
            os.write(2, ("%s: cannot run %s: %s\n"
                         % (PROGRAM, command[0], error)).encode("utf-8", "replace"))
        finally:
            os._exit(127)


def read_ready(master):
    """Read what the pty has, treating a closed slave side as end of output."""
    try:
        return os.read(master, 65536)
    except OSError:
        return b""


def drain(master):
    """Return everything still buffered in the pty, without waiting long."""
    chunks = []
    while True:
        ready, _, _ = select.select([master], [], [], 0.1)
        if not ready:
            break
        data = read_ready(master)
        if not data:
            break
        chunks.append(data)
    return b"".join(chunks)


def wait_quietly(pid, seconds):
    """Reap PID within SECONDS, or return None while it is still running."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            return status
        time.sleep(0.05)
    return None


def kill_process(pid):
    """End PID without failing when it already exited."""
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def reap(pid):
    """Wait for PID and return its wait status."""
    try:
        return os.waitpid(pid, 0)[1]
    except ChildProcessError:
        return 0


def exit_code(status):
    """Return a shell-style exit status for a wait status."""
    if status is None:
        return 124
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


def capture(command, columns, rows, timeout, metrics, out_path):
    """Run COMMAND in a pty and write OUT_PATH and OUT_PATH.txt.

    The screen is written from a finally block, so a timeout, a killed child or
    an error inside the loop still leaves the captured screen on disk.
    """
    try:
        master, slave = pty.openpty()
    except OSError as error:
        raise CaptureError("cannot allocate a pseudo-terminal (%s); "
                           "this tool needs a Unix pty" % error)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
    pid = os.fork()
    if pid == 0:
        exec_child(master, slave, command)
    os.close(slave)

    screen = pyte.Screen(columns, rows)
    feeder = TerminalFeeder(pyte.Stream(screen))
    status = None
    note = None                      # Why the command had to be ended.
    deadline = time.monotonic() + timeout
    text_path = str(out_path) + ".txt"
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                note = "no exit within %gs" % timeout
                break
            ready, _, _ = select.select([master], [], [], min(0.2, remaining))
            if ready:
                data = read_ready(master)
                if not data:
                    break
                feeder.feed(data)
                continue
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                break
        if status is None and note is None:
            status = wait_quietly(pid, 2.0)
            if status is None:
                note = "still running 2s after its terminal closed"
        if status is None:
            kill_process(pid)
            status = reap(pid)
    finally:
        if status is None:
            kill_process(pid)
            status = reap(pid)
        feeder.feed(drain(master))
        os.close(master)
        feeder.flush()
        with open(text_path, "w", encoding="utf-8") as handle:
            handle.write(screen_text(screen, metrics, columns, rows))
        render_image(screen, metrics, columns, rows).save(out_path)

    if note:
        sys.stderr.write("%s: %s; captured the screen as it stood\n" % (PROGRAM, note))
    return (124 if note else exit_code(status)), text_path, note


def build_parser():
    parser = argparse.ArgumentParser(
        prog=PROGRAM,
        description="Run a command in a pseudo-terminal and save the final screen "
                    "as a PNG plus a text file.",
        epilog="Give the command after --. Example:\n"
               "  python3 scripts/tui-capture.py --cols 80 --rows 24 "
               "--out /tmp/app.png -- emacs -nw -Q",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cols", type=int, default=DEFAULT_COLUMNS, metavar="N",
                        help="terminal width in cells (default %d)" % DEFAULT_COLUMNS)
    parser.add_argument("--rows", type=int, default=DEFAULT_ROWS, metavar="N",
                        help="terminal height in cells (default %d)" % DEFAULT_ROWS)
    parser.add_argument("--out", required=True, metavar="PATH",
                        help="PNG to write; PATH.txt receives the text screen")
    parser.add_argument("--font", metavar="SPEC",
                        help="font file, or PATH:INDEX for a font collection; "
                             "defaults to Sarasa Mono SC, Menlo, DejaVu Sans Mono")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, metavar="SECONDS",
                        help="hard limit for the command (default %g)" % DEFAULT_TIMEOUT)
    return parser


def split_command(argv):
    """Split argv into this tool's options and the command after ``--``."""
    if "--" in argv:
        cut = argv.index("--")
        return argv[:cut], argv[cut + 1:]
    return argv, []


def run(args, command):
    """Validate the request, capture the screen and report the result."""
    if pyte is None or ImageFont is None:
        missing = [name for name, module in (("pyte", pyte), ("Pillow", ImageFont))
                   if module is None]
        raise CaptureError("missing Python module(s): %s; install them with: "
                           "pip install pyte pillow" % ", ".join(missing))
    if not command:
        raise CaptureError("no command given; put it after -- (see --help)")
    if not hasattr(os, "fork"):
        raise CaptureError("this tool needs a Unix pty and os.fork (macOS or Linux)")
    if args.cols < 1 or args.rows < 1:
        raise CaptureError("--cols and --rows must be at least 1")
    if args.cols * args.rows > MAX_CELLS:
        raise CaptureError("--cols x --rows exceeds %d cells" % MAX_CELLS)
    if args.timeout <= 0:
        raise CaptureError("--timeout must be greater than 0")

    out_path = Path(args.out).expanduser()
    if not out_path.parent.is_dir():
        raise CaptureError("output directory does not exist: %s" % out_path.parent)
    font, description = load_font(args.font)
    metrics = Metrics(font, description)
    sys.stdout.write("%s: font=%s cells=%dx%d screen=%dx%d\n"
                     % (PROGRAM, description, metrics.cell_width, metrics.cell_height,
                        args.cols, args.rows))
    sys.stdout.flush()

    code, text_path, note = capture(command, args.cols, args.rows, args.timeout,
                                    metrics, out_path)
    sys.stdout.write("%s: exit=%s png=%s text=%s\n"
                     % (PROGRAM, "timeout" if note else code,
                        out_path, text_path))
    return code


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    options, command = split_command(argv)
    args = build_parser().parse_args(options)
    try:
        return run(args, command)
    except CaptureError as error:
        sys.stderr.write("%s: %s\n" % (PROGRAM, error))
        return 2


if __name__ == "__main__":
    sys.exit(main())
