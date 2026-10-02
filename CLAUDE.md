# Mimic

Mimic is a Mac app (and the `mimic` command) that turns a picture or a description into a
3D-printable miniature. Read [CONTRIBUTING.md](CONTRIBUTING.md) for how changes are made (tests,
pull request titles, release notes) and [app/NOTES.md](app/NOTES.md) for the design decisions and
why.

## Update the docs in the same change

The user guide at https://yonatankarp.com/mimic/ is built from `docs/` with Material for MkDocs
(the pages and their order are in `mkdocs.yml`). It describes what Mimic does today, so it's part
of every change people will notice, not a follow-up: a pull request that changes what people see
or do also updates the pages that describe it.

- **Text in the app changed** (a label, menu item, shortcut, Settings control, message, or a number
  such as a size, a time or a download): search `docs/` for the old wording and update it. Bold in
  the docs means the exact label in the app.
- **Something new:** describe it on the page where people would look for it, under Using Mimic, and
  add any shortcut to `docs/shortcuts.md`.
- **The `mimic` command:** update the command's section in `docs/cli.md` and its options table.
  The size options are shared in `docs/.snippets/size-options.md`. JSON fields go in "JSON for
  scripts": they can be added, never renamed or removed. Keep `app/Sources/MimicCore/Usage.swift`
  in step.
- **Print prep** options or messages: `docs/print-prep.md`. **Files on disk:** `docs/files.md`.
- **A window looks different:** retake its screenshot in `docs/images/screens/`. Capture the window
  only, from a dev build started with `MIMIC_HOME` on a folder holding only the sample minis. If you
  can't retake it, say in the pull request which screenshots are out of date.
- **Voice:** plain English for people who aren't technical, "you", British spelling, as in the
  README. The Power users pages can be technical.
- **Check:** `uvx --with-requirements requirements-docs.txt mkdocs build --strict` passes; CI runs
  the same on every pull request. `mkdocs serve` instead of `build` shows the site as you edit.

A change only to the docs gets a `docs:` pull request title. The README stays short (what Mimic is,
installing it, a first mini) and links to the site for the rest.
