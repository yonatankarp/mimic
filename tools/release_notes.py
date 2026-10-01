#!/usr/bin/env python3
"""Writes a version's release notes from the pull requests merged since the last version.

    tools/release_notes.py 0.8.0            # the notes for tag v0.8.0
    tools/release_notes.py 0.8.0 origin/main  # a preview, before the tag exists

Each pull request's title says what kind of change it is, which picks its heading: `feat: ...` is a
new feature, `change: ...` an improvement and `fix: ...` a bug fix. A `(cli)` scope (`feat(cli): ...`)
puts it under In Terminal instead, since most people never use it. Other kinds (docs, chore, ci,
test, refactor) are left out. A line on top counts what the version brings. The line is the first paragraph under the PR's `## Release note`, written for people
who use Mimic, or its title when it has none; `none` leaves it out.

A release-notes/<version>.md file, when there is one, is published instead, word for word: an
escape hatch for a version whose notes need more than its pull requests say. A version with its own section in
CHANGELOG.md (0.7.0 and before) uses that instead.
Needs `git` with the tags fetched, and `gh` signed in (GH_TOKEN on CI).
"""
import json
import re
import subprocess
import sys

HEADINGS = {"feat": "✨ New features", "change": "🔧 Improvements", "fix": "🐞 Bug fixes"}
TERMINAL = "⌨️ In Terminal"
KINDS = set(HEADINGS) | {"docs", "chore", "ci", "test", "refactor"}
TITLE = re.compile(r"^(?P<kind>[a-z]+)(\((?P<scope>[^)]*)\))?!?: (?P<text>.+)$")
COUNTED = {"feat": ("new feature", "new features"), "change": ("improvement", "improvements"),
           "fix": ("bug fix", "bug fixes"), "cli": ("", "")}


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def changelog_section(version):
    try:
        lines = open("CHANGELOG.md").read().splitlines()
    except FileNotFoundError:
        return ""
    section, on = [], False
    for line in lines:
        if line.startswith("## "):
            on = line == f"## {version}"
            continue
        if on:
            section.append(line)
    return "\n".join(section).strip()


def release_note(body):
    """The first paragraph under the PR's `## Release note`, or None when it has none."""
    body = re.sub(r"<!--.*?-->", "", body or "", flags=re.S)
    match = re.search(r"^##\s*Release notes?\s*$(.*?)(?=^##\s|\Z)", body, flags=re.M | re.S | re.I)
    return re.split(r"\n\s*\n", match.group(1).strip())[0] if match else None


def bullets(note):
    """A note that is already a list stays one; a paragraph becomes one bullet."""
    lines = [line.rstrip() for line in note.splitlines() if line.strip()]
    if lines[0].startswith(("- ", "* ")):
        return ["- " + line[2:] if line.startswith("* ") else line for line in lines]
    return ["- " + " ".join(line.strip() for line in lines)]


def pull_requests(since, ref):
    subjects = run("git", "log", "--first-parent", "--format=%s", f"{since}..{ref}").splitlines()
    numbers = []
    for subject in reversed(subjects):  # oldest first, the order they landed in
        match = re.match(r"Merge pull request #(\d+)", subject) or re.search(r"\(#(\d+)\)$", subject)
        if match and match.group(1) not in numbers:
            numbers.append(match.group(1))
    return numbers


def edited(version):
    try:
        return open(f"release-notes/{version}.md").read().strip()
    except FileNotFoundError:
        return ""


def notes(version, ref):
    if written := edited(version) or changelog_section(version):
        return written
    since = run("git", "describe", "--tags", "--abbrev=0", "--match", "v*", f"{ref}^").strip()
    sections = {heading: [] for heading in [*HEADINGS.values(), TERMINAL]}
    counts = dict.fromkeys(COUNTED, 0)
    for number in pull_requests(since, ref):
        pr = json.loads(run("gh", "pr", "view", number, "--json", "title,body"))
        title = TITLE.match(pr["title"])
        if not title or title["kind"] not in KINDS:
            print(f"#{number} has no kind in its title, left out: {pr['title']}", file=sys.stderr)
            continue
        note = release_note(pr["body"])
        if title["kind"] not in HEADINGS or (note or "").lower().rstrip(".") == "none":
            continue
        if not note:
            text = title["text"]
            note = text[0].upper() + text[1:]
        terminal = title["scope"] == "cli"
        lines = bullets(note)
        sections[TERMINAL if terminal else HEADINGS[title["kind"]]] += lines
        counts["cli" if terminal else title["kind"]] += len(lines)
    body = "\n\n".join(f"### {heading}\n" + "\n".join(lines) for heading, lines in sections.items() if lines)
    return f"{summary(counts)}\n\n{body}" if body else ""


def summary(counts):
    """"This update has 7 new features, 2 improvements and 5 bug fixes, plus more in Terminal."."""
    parts = [f"{n} {COUNTED[kind][n != 1]}" for kind, n in counts.items() if n and kind != "cli"]
    terminal = "more in Terminal" if parts else "changes in Terminal"
    if not parts:
        return f"This update has {terminal}." if counts["cli"] else ""
    listed = parts[0] if len(parts) == 1 else ", ".join(parts[:-1]) + " and " + parts[-1]
    return f"This update has {listed}" + (f", plus {terminal}." if counts["cli"] else ".")

if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    version = sys.argv[1].removeprefix("v")
    text = notes(version, sys.argv[2] if len(sys.argv) == 3 else f"v{version}")
    if not text:
        sys.exit(f"Nothing for people who use Mimic in {version}: no feat, fix or change pull request.")
    print(text)
