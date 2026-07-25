module info.orient;

import std.algorithm;
import std.array;
import std.range : take;
import std.string;
import info.reader;

/// Build an orientation SDL fragment from an Info document.
public string orientationFromInfo(string command, InfoDocument doc) {
    string summary;
    string description;
    string history;

    if ("Top" in doc.nodes) {
        auto top = doc.nodes["Top"];
        auto lines = top.bodyText.splitLines().filter!(l => l.strip().length > 0).array;
        // Skip copyright-first paragraphs
        size_t i = 0;
        while (i < lines.length) {
            auto low = lines[i].toLower();
            if (low.canFind("copyright") || low.canFind("permission is granted")
                    || low.canFind("free software foundation") || low.startsWith("this file is")) {
                i++;
                continue;
            }
            break;
        }
        if (i < lines.length) {
            summary = lines[i].strip();
            auto descLines = appender!string();
            size_t taken = 0;
            for (; i < lines.length && taken < 6; i++, taken++) {
                auto low = lines[i].toLower();
                if (low.canFind("copyright") && taken > 0) break;
                if (descLines.data.length) descLines.put(" ");
                descLines.put(lines[i].strip());
            }
            description = descLines.data;
        }
    }

    auto start = preferredStartNode(doc);
    if ((!summary.length || summary.length < 12) && start.length && start in doc.nodes) {
        auto n = doc.nodes[start];
        auto lines = n.bodyText.splitLines().filter!(l => l.strip().length > 0).array;
        if (lines.length) {
            if (!summary.length) summary = lines[0].strip();
            if (description.length < 40) {
                description = lines[0 .. min(4, lines.length)].join(" ").strip();
            }
        }
    }

    if (!summary.length) summary = "Info manual: " ~ command;

    // History: look for a History / Background node
    foreach (name; doc.nodeOrder) {
        auto low = name.toLower();
        if (low.canFind("history") || low.canFind("background") || low.canFind("overview")) {
            if (isCopyrightish(name)) continue;
            auto body = doc.nodes[name].bodyText.splitLines()
                .filter!(l => l.strip().length > 0).take(4).join(" ");
            if (body.length) {
                history = body;
                break;
            }
        }
    }

    auto buf = appender!string();
    buf.put("orientation \"");
    buf.put(escape(command));
    buf.put("\" {\n");
    buf.put("    summary \"");
    buf.put(escape(summary));
    buf.put("\"\n");
    if (description.length) {
        buf.put("    description \"");
        buf.put(escape(description));
        buf.put("\"\n");
    }
    if (history.length) {
        buf.put("    history \"");
        buf.put(escape(history));
        buf.put("\"\n");
    }
    buf.put("    see-also \"help\" \"info\" \"man\"\n");
    buf.put("}\n");
    return buf.data;
}

private string escape(string s) {
    return s.replace(`\`, `\\`).replace(`"`, `\"`).replace("\n", `\n`).replace("\r", "");
}
