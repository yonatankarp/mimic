#!/usr/bin/env python3
"""Keeps the String Catalog in step with the code, as Xcode would (`swift build` doesn't).

    ./strings.py          # adds the words the code uses to the catalog, drops those it no longer does,
                          # and compiles its English table
    ./strings.py --check  # changes nothing; fails if the catalog or its table isn't in step (CI runs this)

The compiler lists every string the code looks up (SwiftUI's Text, Button, .help…, and
String(localized:)), one .stringsdata file per source file. A new key gets its English value,
the key itself, so the compiled table holds every word and the dev build can show a missing one.
Existing entries are kept as they are: plural variations and comments are edited in the catalog.

The table (Resources/en.lproj) is compiled here and committed, not by `swift build`: Swift 6.2,
which CI builds with, copies a String Catalog into the app without compiling it.
"""
import collections
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

app = pathlib.Path(__file__).resolve().parent
catalog = app / "Sources/MimicCore/Localizable.xcstrings"
table = app / "Sources/MimicCore/Resources/en.lproj"


def used_keys():
    # The compiler names each .stringsdata after its source file, so two files with one name
    # would leave one's strings out.
    names = collections.Counter(p.name for p in (app / "Sources").rglob("*.swift"))
    if same := sorted(n for n, c in names.items() if c > 1):
        sys.exit(f"Two source files are called {', '.join(same)}: rename one, or the check misses its strings.")
    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp, "strings")
        out.mkdir()
        # A fresh build: the compiler lists a file's strings only when it compiles that file.
        subprocess.run(["swift", "build", "--scratch-path", f"{tmp}/build",
                        "-Xswiftc", "-emit-localized-strings", "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", str(out)],
                       cwd=app, check=True, stdout=subprocess.DEVNULL)
        keys = {}
        # Where they land depends on the build system: in `out` (native, Swift 6.2), or beside
        # each target's objects (swiftbuild, newer Swift), which also lists generated code.
        for f in sorted(pathlib.Path(tmp).rglob("*.stringsdata")):
            data = json.loads(f.read_text())
            if not data["source"].startswith(str(app / "Sources")):
                continue
            for table, strings in data["tables"].items():
                if table != "Localizable":
                    sys.exit(f"{f.stem}.swift uses the table {table}: Mimic has one, Localizable.")
                for s in strings:
                    if s["comment"] and not keys.get(s["key"]):
                        keys[s["key"]] = s["comment"]
                    keys.setdefault(s["key"], "")
        if not keys:
            sys.exit("The compiler listed no strings: is this Swift too old to -emit-localized-strings?")
        return keys


def render(data):
    return json.dumps(data, indent=2, ensure_ascii=False, separators=(",", " : ")) + "\n"


def compile_table(text, folder):
    """The English table Xcode would build from the catalog `text`, in `folder`/en.lproj."""
    source = pathlib.Path(folder, "Localizable.xcstrings")
    source.write_text(text)
    subprocess.run(["xcrun", "xcstringstool", "compile", str(source), "--output-directory", folder], check=True)
    return pathlib.Path(folder, "en.lproj")


def parsed(folder):
    """Each file of a table, read: two Xcodes may write the same table differently."""
    read = lambda f: json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", str(f)],
                                               capture_output=True, check=True).stdout)
    return {f.name: read(f) for f in sorted(folder.glob("*"))} if folder.exists() else {}


def main():
    check = sys.argv[1:] == ["--check"]
    keys = used_keys()
    old = json.loads(catalog.read_text())
    strings = {}
    for key, comment in sorted(keys.items()):
        entry = old["strings"].get(key, {"comment": comment} if comment else {})
        entry.setdefault("localizations", {}).setdefault("en", {"stringUnit": {"state": "translated", "value": key}})
        strings[key] = entry
    text = render(dict(old, strings=strings))
    with tempfile.TemporaryDirectory() as tmp:
        compiled = compile_table(text, tmp)
        if not check:
            catalog.write_text(text)
            shutil.rmtree(table, ignore_errors=True)
            shutil.copytree(compiled, table)
            print(f"Updated {catalog.relative_to(app)} ({len(strings)} strings) and its table.")
            return
        table_ok = parsed(compiled) == parsed(table)
    if text == catalog.read_text() and table_ok:
        return
    for key in sorted(keys.keys() - old["strings"].keys()):
        print(f"missing: {key!r}")
    for key in sorted(old["strings"].keys() - keys.keys()):
        print(f"no longer used: {key!r}")
    for key in sorted(k for k, e in old["strings"].items() if k in keys and "en" not in e.get("localizations", {})):
        print(f"no English: {key!r}")
    if not table_ok:
        print(f"{table.relative_to(app)} isn't compiled from the catalog as it is.")
    sys.exit("The String Catalog isn't in step with the code: run app/strings.py and commit what it changes.")


main()
