module info.tui;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.stdio;
import std.string;
import info.reader;

version (Windows) {
    import core.sys.windows.windows;
} else {
    import core.sys.posix.unistd;
    import core.sys.posix.sys.ioctl;
}

import opentui;

private void terminalSize(out uint width, out uint height) {
    width = 80;
    height = 24;
    version (Windows) {
        HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
        CONSOLE_SCREEN_BUFFER_INFO csbi;
        if (GetConsoleScreenBufferInfo(hOut, &csbi)) {
            width = cast(uint)(csbi.srWindow.Right - csbi.srWindow.Left + 1);
            height = cast(uint)(csbi.srWindow.Bottom - csbi.srWindow.Top + 1);
        }
    } else {
        winsize w;
        if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0) {
            if (w.ws_col) width = w.ws_col;
            if (w.ws_row) height = w.ws_row;
        }
    }
    if (width == 0) width = 80;
    if (height == 0) height = 24;
}

private string findNativeLib() {
    version (Windows) {
        string[] candidates = [
            buildPath("native", "windows-x64", "opentui.dll"),
            buildPath("..", "native", "windows-x64", "opentui.dll"),
        ];
    } else version (OSX) {
        string[] candidates = [
            buildPath("native", "darwin-arm64", "libopentui.dylib"),
            buildPath("native", "darwin-x64", "libopentui.dylib"),
        ];
    } else {
        string[] candidates = [
            buildPath("native", "linux-x64", "libopentui.so"),
            buildPath("native", "linux-arm64", "libopentui.so"),
        ];
    }
    foreach (c; candidates) {
        if (exists(c)) return c;
    }
    return null;
}

private int dumpPlain(InfoDocument doc, string nodeName, bool quietTopChrome) {
    if (nodeName !in doc.nodes) return 1;
    bool quiet = quietTopChrome && (nodeName == "Top");
    write(formatNode(doc.nodes[nodeName], quiet));
    return 0;
}

private int clamp(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

private int readKeyNonBlocking() {
    version (Windows) {
        HANDLE hIn = GetStdHandle(STD_INPUT_HANDLE);
        DWORD avail = 0;
        if (!GetNumberOfConsoleInputEvents(hIn, &avail) || avail == 0) return 0;
        INPUT_RECORD rec;
        DWORD readCount = 0;
        if (!ReadConsoleInputA(hIn, &rec, 1, &readCount) || readCount == 0) return 0;
        if (rec.EventType == KEY_EVENT && rec.KeyEvent.bKeyDown) {
            return cast(int)rec.KeyEvent.AsciiChar;
        }
        return 0;
    } else {
        import core.sys.posix.poll;
        pollfd pfd;
        pfd.fd = STDIN_FILENO;
        pfd.events = POLLIN;
        if (poll(&pfd, 1, 0) <= 0) return 0;
        char c;
        if (read(STDIN_FILENO, &c, 1) == 1) return cast(int)c;
        return 0;
    }
}

/// Run an OpenTUI viewport for the given document. Falls back to dump if OpenTUI fails.
public int runTui(InfoDocument doc, string startNode, bool quietTopChrome) {
    string nodeName = startNode.length ? startNode : preferredStartNode(doc);
    if (!nodeName.length && doc.nodeOrder.length) nodeName = doc.nodeOrder[0];
    if (!nodeName.length) {
        stderr.writeln("info: empty document");
        return 1;
    }

    auto lib = findNativeLib();
    if (lib is null) {
        stderr.writeln("info: OpenTUI native library not found (fetch into ./native). Falling back to --dump.");
        return dumpPlain(doc, nodeName, quietTopChrome);
    }

    try {
        opentui.load(lib);
    } catch (Exception e) {
        stderr.writeln("info: OpenTUI load failed (", e.msg, "); dumping plaintext");
        return dumpPlain(doc, nodeName, quietTopChrome);
    }

    Renderer renderer;
    int result = 1;
    try {
        uint tw, th;
        terminalSize(tw, th);
        renderer = Renderer.create(tw, th);
        renderer.enableMouse(true);
        renderer.setBackgroundColor(black);

        int scroll;
        bool running = true;
        while (running) {
            if (nodeName !in doc.nodes) {
                stderr.writeln("info: missing node ", nodeName);
                break;
            }
            auto node = doc.nodes[nodeName];
            bool quiet = quietTopChrome && (nodeName == "Top" || nodeName == "dir");
            string primary, secondary;
            splitPrimarySecondary(node, primary, secondary);
            string header = quiet
                ? (node.name == "Top"
                    ? "Info manuals  (q quit · j/k scroll · Enter menu · n/p next/prev · c copyright)"
                    : node.name)
                : std.string.format("File: %s | Node: %s | Next: %s | Prev: %s | Up: %s",
                    node.file, node.name, node.next, node.prev, node.up);

            auto text = header ~ "\n\n" ~ primary;
            if (secondary.length) {
                text ~= "\n\n── Copyright / license (press c) ──\n" ~ secondary;
            }
            auto lines = text.splitLines();

            terminalSize(tw, th);
            renderer.resize(tw, th);
            auto buf = renderer.nextBuffer();
            int view = max(1, cast(int)th - 1);
            scroll = clamp(scroll, 0, max(0, cast(int)lines.length - view));
            buf.clear(black);
            for (int row = 0; row < view; row++) {
                int li = scroll + row;
                if (li < 0 || li >= cast(int)lines.length) break;
                auto line = lines[li];
                if (line.length > tw) line = line[0 .. tw];
                buf.drawText(line, 0, cast(uint)row, white);
            }
            auto status = std.string.format(" %s | line %d/%d | mouse enabled ",
                nodeName, scroll + 1, max(1, cast(int)lines.length));
            if (status.length > tw) status = status[0 .. tw];
            buf.drawText(status, 0, th - 1, cyan);
            renderer.renderFrame(true);

            auto key = readKeyNonBlocking();
            if (key == 0) {
                import core.thread : Thread;
                import core.time : msecs;
                Thread.sleep(16.msecs);
                continue;
            }
            if (key == 'q' || key == 'Q' || key == 27) {
                running = false;
            } else if (key == 'j') {
                scroll++;
            } else if (key == 'k') {
                scroll = max(0, scroll - 1);
            } else if (key == 'n' || key == 'N') {
                if (node.next.length && node.next in doc.nodes) {
                    nodeName = node.next;
                    scroll = 0;
                    quietTopChrome = false;
                }
            } else if (key == 'p' || key == 'P') {
                if (node.prev.length && node.prev in doc.nodes) {
                    nodeName = node.prev;
                    scroll = 0;
                    quietTopChrome = false;
                }
            } else if (key == 'u' || key == 'U') {
                if (node.up.length && node.up in doc.nodes) {
                    nodeName = node.up;
                    scroll = 0;
                }
            } else if (key == 'c' || key == 'C') {
                foreach (e; node.menuEntries) {
                    auto t = menuTarget(e);
                    if (isCopyrightish(t) && t in doc.nodes) {
                        nodeName = t;
                        scroll = 0;
                        quietTopChrome = false;
                        break;
                    }
                }
            } else if (key == '\n' || key == '\r') {
                foreach (e; node.menuEntries) {
                    auto t = menuTarget(e);
                    if (t.length && !isCopyrightish(t) && t in doc.nodes) {
                        nodeName = t;
                        scroll = 0;
                        quietTopChrome = false;
                        break;
                    }
                }
            }
        }
        result = 0;
    } catch (Exception e) {
        stderr.writeln("info: TUI error: ", e.msg);
        result = dumpPlain(doc, nodeName, quietTopChrome);
    }

    if (renderer !is null) {
        renderer.disableMouse();
        renderer.destroy();
    }
    opentui.unload();
    return result;
}
