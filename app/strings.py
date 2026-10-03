#!/usr/bin/env python3
"""Keeps the String Catalog in step with the code, as Xcode would (`swift build` doesn't).

    ./strings.py          # adds the words the code uses to the catalog, drops those it no longer does
    ./strings.py --check  # changes nothing; fails if the catalog isn't in step (CI runs this)

The compiler lists every string the code looks up (SwiftUI's Text, Button, .help…, and
String(localized:)), one .stringsdata file per source file. A new key gets its English value,
the key itself, so the compiled table holds every word and the dev build can show a missing one.
Existing entries are kept as they are: plural variations and comments are edited in the catalog.
"""
import collections
import json
import pathlib
import subprocess
import sys
import tempfile

app = pathlib.Path(__file__).resolve().parent
catalog = app / "Sources/MimicCore/Resources/Localizable.xcstrings"


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


def main():
    check = sys.argv[1:] == ["--check"]
    keys = used_keys()
    old = json.loads(catalog.read_text())
    strings = {}
    for key, comment in sorted(keys.items()):
        entry = old["strings"].get(key, {"comment": comment} if comment else {})
        entry.setdefault("localizations", {}).setdefault("en", {"stringUnit": {"state": "translated", "value": key}})
        strings[key] = entry
    new = dict(old, strings=strings)
    if render(new) == catalog.read_text():
        return
    if not check:
        catalog.write_text(render(new))
        print(f"Updated {catalog.relative_to(app)}: {len(strings)} strings.")
        return
    for key in sorted(keys.keys() - old["strings"].keys()):
        print(f"missing: {key!r}")
    for key in sorted(old["strings"].keys() - keys.keys()):
        print(f"no longer used: {key!r}")
    for key in sorted(k for k, e in old["strings"].items() if k in keys and "en" not in e.get("localizations", {})):
        print(f"no English: {key!r}")
    sys.exit("The String Catalog isn't in step with the code: run app/strings.py and commit the catalog.")


main()
