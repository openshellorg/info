module app;

import std.stdio;
import std.string;
import std.file;
import std.path;
import info.reader;
import info.orient;
import info.tui;

version (Windows) {
    import core.sys.windows.windows;
} else {
    import core.sys.posix.unistd;
}

private bool isTTY() {
    version (Windows) {
        HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
        DWORD mode;
        return GetConsoleMode(hOut, &mode) != 0;
    } else {
        return isatty(STDOUT_FILENO) != 0;
    }
}

private void printUsage() {
    writeln("Usage: info [options] [manual]");
    writeln();
    writeln("OpenShellOrg Info TUI — browse GNU Info manuals.");
    writeln();
    writeln("Options:");
    writeln("  -h, --help       Show this help");
    writeln("  -v, --version    Version");
    writeln("  --dump           Plaintext to stdout (no TUI)");
    writeln("  --orient         Emit orientation.sdl for about/help");
    writeln("  --node=NAME      Start at node NAME");
    writeln();
    writeln("With no manual, opens the system dir/Top index with quiet chrome.");
    writeln("See also: about <cmd>, help <cmd>, man <cmd>");
}

void main(string[] argv) {
    string[] args = argv.length > 1 ? argv[1 .. $].dup : [];
    bool dump;
    bool orientMode;
    string nodeOverride;
    string manual;

    while (args.length) {
        auto a = args[0];
        if (a == "-h" || a == "--help") {
            printUsage();
            return;
        }
        if (a == "-v" || a == "--version") {
            writeln("info (openshellorg) 0.1.0");
            return;
        }
        if (a == "--dump") {
            dump = true;
            args = args[1 .. $];
            continue;
        }
        if (a == "--orient") {
            orientMode = true;
            args = args[1 .. $];
            continue;
        }
        if (a.startsWith("--node=")) {
            nodeOverride = a["--node=".length .. $];
            args = args[1 .. $];
            continue;
        }
        if (a == "--node") {
            if (args.length < 2) {
                stderr.writeln("info: --node needs a name");
                return;
            }
            nodeOverride = args[1];
            args = args[2 .. $];
            continue;
        }
        if (a.startsWith("-")) {
            stderr.writeln("info: unknown option ", a);
            printUsage();
            return;
        }
        manual = a;
        args = args[1 .. $];
        break;
    }

    bool quietTop = manual.length == 0;
    if (!manual.length) manual = "dir";

    string path = findInfoFile(manual);
    if (!path.length) {
        // Try dir then give up
        if (manual != "dir") {
            stderr.writefln("info: no Info file for '%s' in INFOPATH / default paths", manual);
            stderr.writeln("Try: man ", manual, "  or  help ", manual);
            return;
        }
        // Synthesize a minimal Top when no dir exists
        stderr.writeln("info: no system dir file found; create INFOPATH or install info docs.");
        stderr.writeln("Searched:");
        foreach (p; defaultInfoPaths()) stderr.writeln("  ", p);
        return;
    }

    InfoDocument doc;
    try {
        doc = parseInfoFile(path);
    } catch (Exception e) {
        stderr.writeln("info: parse failed: ", e.msg);
        return;
    }

    string start = nodeOverride.length ? nodeOverride : (quietTop ? "Top" : preferredStartNode(doc));
    if (start == "Top" && "Top" !in doc.nodes && doc.nodeOrder.length) {
        start = doc.nodeOrder[0];
    }

    string cmdName = manual == "dir" ? "info" : manual;

    if (orientMode) {
        write(orientationFromInfo(cmdName, doc));
        return;
    }

    if (dump || !isTTY()) {
        if (start in doc.nodes) {
            write(formatNode(doc.nodes[start], quietTop && start == "Top"));
        } else {
            stderr.writeln("info: node not found: ", start);
        }
        return;
    }

    runTui(doc, start, quietTop);
}
