module info.reader;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.regex;
import std.stdio;
import std.string;
import std.process : environment;

/// One Info node.
public struct InfoNode {
    string name;
    string file;
    string next;
    string prev;
    string up;
    string bodyText;
    string[] menuEntries;
}

public struct InfoDocument {
    string fileLabel;
    InfoNode[string] nodes;
    string[] nodeOrder;
}

public string[] defaultInfoPaths() {
    string[] paths;
    version (Windows) {
        auto root = environment.get("INFOPATH", "");
        if (root.length) {
            foreach (p; root.split(";")) if (p.length) paths ~= p;
        }
        foreach (p; [`C:\msys64\usr\share\info`]) {
            if (exists(p)) paths ~= p;
        }
    } else {
        auto root = environment.get("INFOPATH", "");
        if (root.length) {
            foreach (p; root.split(":")) if (p.length) paths ~= p;
        }
        foreach (p; ["/usr/share/info", "/usr/local/share/info", "/opt/local/share/info"]) {
            if (exists(p)) paths ~= p;
        }
    }
    return paths;
}

/// Find an info file for a manual name.
public string findInfoFile(string manual) {
    if (manual.length == 0) return "";
    if (exists(manual) && isFile(manual)) return manual;

    string[] names = [
        manual ~ ".info",
        manual,
    ];
    foreach (dir; defaultInfoPaths()) {
        foreach (n; names) {
            auto p = buildPath(dir, n);
            if (exists(p) && isFile(p)) return p;
        }
        if (manual == "dir") {
            auto p = buildPath(dir, "dir");
            if (exists(p)) return p;
        }
    }
    return "";
}

/// Parse a single Info file into nodes.
public InfoDocument parseInfoFile(string path) {
    string text = readText(path);
    auto parts = text.split("\x1f");
    InfoDocument doc;
    doc.fileLabel = baseName(path);

    auto headerRx = ctRegex!(`File:\s*([^,]*),\s*Node:\s*([^,]*)(?:,\s*Next:\s*([^,]*))?(?:,\s*Prev:\s*([^,]*))?(?:,\s*Up:\s*([^\n]*))?`);

    foreach (part; parts) {
        auto body = part.stripLeft();
        if (!body.length) continue;
        if (body.startsWith("Tag Table:") || body.startsWith("Indirect:") || body.startsWith("End Tag Table")) {
            continue;
        }

        auto m = matchFirst(body, headerRx);
        InfoNode node;
        string rest;
        if (m) {
            node.file = m[1].strip();
            node.name = m[2].strip();
            if (m.length > 3 && m[3].length) node.next = m[3].strip();
            if (m.length > 4 && m[4].length) node.prev = m[4].strip();
            if (m.length > 5 && m[5].length) node.up = m[5].strip();
            auto nl = body.indexOf('\n');
            rest = nl >= 0 ? body[nl + 1 .. $] : "";
        } else {
            node.name = "Top";
            node.file = doc.fileLabel;
            rest = body;
        }

        bool inMenu = false;
        auto lines = appender!(string[])();
        auto menu = appender!(string[])();
        foreach (line; rest.splitLines()) {
            if (line.strip() == "* Menu:") {
                inMenu = true;
                continue;
            }
            if (inMenu) {
                auto s = line.strip();
                if (s.startsWith("* ")) {
                    menu.put(s);
                } else if (s.length == 0) {
                } else if (!s.startsWith("*") && menu.data.length > 0 && !s.startsWith(" ")) {
                    inMenu = false;
                    lines.put(line);
                }
            } else {
                lines.put(line);
            }
        }
        node.bodyText = lines.data.join("\n").strip();
        node.menuEntries = menu.data;
        if (node.name.length) {
            doc.nodes[node.name] = node;
            doc.nodeOrder ~= node.name;
        }
    }

    return doc;
}

public bool isCopyrightish(string nodeName) {
    auto n = nodeName.toLower();
    return n.canFind("copying") || n.canFind("copyright") || n == "gnu free documentation license"
        || n.canFind("fdl") || n.canFind("license") || n.canFind("warranty");
}

public bool isDescriptionish(string nodeName) {
    auto n = nodeName.toLower();
    return n == "top" || n.canFind("overview") || n.canFind("introduction")
        || n.canFind("description") || n.canFind("getting started") || n == "intro";
}

public string preferredStartNode(InfoDocument doc) {
    if ("Top" in doc.nodes) {
        auto top = doc.nodes["Top"];
        foreach (entry; top.menuEntries) {
            auto nodeName = menuTarget(entry);
            if (nodeName.length && isDescriptionish(nodeName) && !isCopyrightish(nodeName)) {
                return nodeName;
            }
        }
        foreach (entry; top.menuEntries) {
            auto nodeName = menuTarget(entry);
            if (nodeName.length && !isCopyrightish(nodeName)) {
                return nodeName;
            }
        }
        return "Top";
    }
    foreach (name; doc.nodeOrder) {
        if (!isCopyrightish(name)) return name;
    }
    return doc.nodeOrder.length ? doc.nodeOrder[0] : "";
}

public string menuTarget(string menuLine) {
    auto s = menuLine.strip();
    if (!s.startsWith("* ")) return "";
    s = s[2 .. $];
    auto colon = s.indexOf(':');
    if (colon < 0) return "";
    auto after = s[colon + 1 .. $].strip();
    if (after.startsWith(":")) {
        return s[0 .. colon].strip();
    }
    auto end = after.indexOf('.');
    if (end >= 0) after = after[0 .. end];
    return after.strip();
}

public string formatNode(InfoNode node, bool quietChrome) {
    auto buf = appender!string();
    if (!quietChrome) {
        buf.put(std.string.format("File: %s,  Node: %s", node.file.length ? node.file : "?", node.name));
        if (node.next.length) buf.put(std.string.format(",  Next: %s", node.next));
        if (node.prev.length) buf.put(std.string.format(",  Prev: %s", node.prev));
        if (node.up.length) buf.put(std.string.format(",  Up: %s", node.up));
        buf.put("\n\n");
    } else {
        buf.put(node.name == "Top" ? "Info manuals\n\n" : node.name ~ "\n\n");
    }
    string primary, secondary;
    splitPrimarySecondary(node, primary, secondary);
    if (primary.length) {
        buf.put(primary);
        buf.put("\n");
    }
    if (secondary.length) {
        buf.put("\n── Copyright / license (secondary) ──\n");
        buf.put(secondary);
        buf.put("\n");
    }
    return buf.data;
}

public void splitPrimarySecondary(InfoNode node, out string primary, out string secondary) {
    auto prim = appender!string();
    auto sec = appender!string();
    if (isCopyrightish(node.name)) {
        secondary = node.bodyText;
        primary = "";
        return;
    }
    prim.put(node.bodyText);
    auto menuPrim = appender!string();
    auto menuSec = appender!string();
    foreach (e; node.menuEntries) {
        auto t = menuTarget(e);
        if (isCopyrightish(t)) menuSec.put(e ~ "\n");
        else menuPrim.put(e ~ "\n");
    }
    if (menuPrim.data.length) {
        prim.put("\n\nMenu:\n");
        prim.put(menuPrim.data);
    }
    if (menuSec.data.length) {
        sec.put("Copyright / license topics:\n");
        sec.put(menuSec.data);
    }
    primary = prim.data.strip();
    secondary = sec.data.strip();
}
