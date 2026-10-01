# Contributing to Mimic

Thanks for helping. Mimic is a hobby project, so every bug report, idea and fix makes a real
difference.

## Reporting a problem

The quickest way is in Mimic: **Help → Report a Problem…**, or **Report a Problem…** on a mini that
didn't finish. It makes a file with the logs, the mini's settings, and your Mimic version and Mac,
with keys and your home folder taken out, shows it in Finder and opens the form below already
filled in; drag the file in. The mini's picture goes in only if you tick the box, since issues are
public.

Or [open an issue](https://github.com/yonatankarp/mimic/issues/new/choose) and pick **Something
went wrong**. The form asks for what helps most:

- Your Mimic version (at the bottom of Settings → Advanced, or Mimic → About Mimic), your Mac (Apple menu → About This Mac) and macOS version.
- What you did, what you expected, and what happened instead.
- For a mini that failed or came out wrong: its picture, and its log files. Right-click the mini
  → **Show in Finder**; the logs are `generate.job.log`, `pixal3d.log` and `prep.log` in its folder.
- **Settings** (⌘,): a screenshot, if any check is red.

## Suggesting something

Open an issue and pick **An idea**. Say what you'd like to do that Mimic doesn't let you do yet;
the problem matters more than a specific solution.

## Sending a change

1. For anything bigger than a small fix, open an issue first, so we can agree on the approach
   before you spend time on it.
2. Fork, make a branch, and keep the change focused on one thing.
3. `cd app && swift test` passes, and anything new has a test. The tests here plant the bug
   they guard against first (see `app/NOTES.md`); keep that habit.
4. Text people see is plain English, for people who aren't technical. No jargon, no file names.
5. Open a pull request that says what changed and why, and how you checked it. Its title starts
   with the kind of change: `feat:` (a new feature), `change:` (an improvement) or `fix:` (a bug
   fix) for what people will notice, `docs:`, `chore:`, `ci:`, `test:` or `refactor:` otherwise.
   Add `(cli)` for a change only `mimic` in Terminal has (`fix(cli): ...`): it goes under In
   Terminal in the release notes.
6. The release notes are made from pull requests, so there's no need to edit `CHANGELOG.md`. A
   `feat`, `fix` or `change` goes into the draft under its title, or under the first paragraph of a
   `## Release note` section in the description, which is published as it is, so write it for
   people who use Mimic: one line (or a short list, one change per line) starting with a short
   **bold lead**, about 20 words, saying what they can now do. No code, model or file names unless
   people choose them in Mimic, and Terminal options only in a `(cli)` pull request. `none` leaves
   it out. Links and HTML are taken out (a link keeps its text), so don't rely on them.

By contributing, you agree that your contribution is licensed under Mimic's
[MIT licence](LICENSE).

# Working on Mimic

## Layout

| Path | What |
|---|---|
| `app/` | The Mac app, a Swift package. `MimicCore` is everything but the windows (jobs, Draw Things, checks, the gallery on disk); `Mimic` is one binary that is the app, or the `mimic` command with arguments. `app/NOTES.md` has the design decisions and why. Print prep is `MimicCore/Prep.swift`; its header lists every tuning option (`mimic _prep in.glb out.stl …` runs it by hand). |
| `tools/package_dmg.sh` | Builds `Mimic.app` into the disk image a release publishes. |
| `tools/release_notes.py` | Writes a release's notes from the pull requests merged since the last one. |
| `tools/package_pixal3d.sh`, `tools/pixal3d-steps.patch`, `tools/LICENSE-image-to-3dlab` | Build and package the Pixal3D engine the app downloads on first launch. |
| `.github/workflows/release.yml` | Tests every change, builds the disk image, and publishes a release from a version tag. |
| `.github/workflows/engine.yml` | Builds that engine twice, run by hand, and checks both builds are the same. |
| `runs/`, `engine/`, `queue/` | The dev build's minis, 3D engine (`trellis-cli`, each model set in `engine/models/<id>/`) and queue, when this checkout is its Mimic folder. All are git-ignored. An installed Mimic keeps them in `~/Documents/Mimic` (or the folder chosen in Settings) and `~/Library/Application Support/Mimic` instead; `app/NOTES.md` says how it chooses. |

## Building and testing

```bash
cd app
swift test                         # the engine: jobs, Stop, sizes, checks, rename, Draw Things, print prep
./bundle.sh && open "build/Mimic Dev.app"
MIMIC_HOME=.. swift run mimic list # the command line, without the app
```

`bundle.sh` makes *Mimic Dev*, a separate app with its own settings, so it never replaces the
Mimic you use. Several tests plant the bug they guard against first; keep that habit when
adding one.

## Trying first launch

Setup needs no terminal, so try it the way a new Mac sees it, without touching your own Mimic:

```bash
MIMIC_FAKE_HOME=/tmp/newmac "build/Mimic Dev.app/Contents/MacOS/mimic"
```

`MIMIC_FAKE_HOME` treats that folder as the home folder of a Mac that has never run Mimic.
`MIMIC_DOWNLOAD_MIRROR=http://127.0.0.1:8000` downloads from a local server holding the
files (by name) instead of the internet. `swift test` covers the downloads against a local
server; `MIMIC_NETWORK_TEST=/tmp/newmac swift test --filter testRealDownloadOfTheSmallFiles`
downloads the real engine and the small model files, never the 8 GB of weights.

## Releasing

1. Check the release notes: `tools/release_notes.py 0.3.0 origin/main` prints what the release
   will publish, on GitHub and in Mimic's update window. It lists the pull requests merged since
   the last version under New features, Improvements, Bug fixes and In Terminal, with a line on
   top that counts them. To change a line, edit that pull request's `## Release note`. The notes
   are read from the pull requests when the tag is pushed, not when they were merged, so an edit to
   a merged pull request's description changes them: read this preview right before tagging. A version
   with no `feat`, `fix` or `change` fails before anything is published. (A
   `release-notes/0.3.0.md` file, if you add one, is published instead, word for word.)
2. Push a version tag:

   ```bash
   git tag v0.3.0 && git push origin v0.3.0
   ```

The workflow tests, builds `Mimic-0.3.0.dmg` and publishes it as a GitHub release with those
notes, which Mimic's updater shows too. The README's install steps link to the latest release, so nothing else
needs updating.

## Signing

Releases are signed with Mimic's own code-signing certificate ("Mimic", made by the maintainer,
valid to 2036), not by Apple. It doesn't avoid the one-time Open Anyway step, which only an Apple
Developer ID would, but every release has the same signer, so macOS treats an update as the same
app and doesn't ask again for saved AI keys.

- CI reads it from the secrets `MIMIC_SIGNING_P12` (the certificate and its key, as base64) and
  `MIMIC_SIGNING_PASSWORD`, trusts it on the runner and signs with it, only when building a `v*`
  tag. Pull requests, pushes to main and the daily build are signed ad hoc. A tag that builds
  without the certificate fails instead of shipping an ad hoc build.
- Tag builds run in the `release` environment, so these secrets and `SPARKLE_PRIVATE_KEY` can be
  kept there, limited to `v*` tags, instead of in the repository secrets.
- The maintainer's copy is `~/.config/mimic/` (`signing.p12`, `signing.password`,
  `signing.crt`), readable only by its owner. Keep a backup: a new certificate works, but every
  user's Mac would ask once more for saved keys after that update.
- Local builds (`bundle.sh`, `package_dmg.sh`) are ad hoc unless `MIMIC_SIGN_IDENTITY` names the
  certificate in a keychain that trusts it.

## Releasing a new Pixal3D build

The app downloads a pre-built Pixal3D so that nobody needs Xcode.

1. Run the **Engine** workflow (Actions → Engine → Run workflow) with the pixal3d.cpp commit to
   build. It runs `tools/package_pixal3d.sh` twice on a macOS runner, in two different folders,
   and fails unless both tarballs are byte for byte the same; the tarball and its sha256 are the
   run's artifact. The script applies `tools/pixal3d-steps.patch`, builds for macOS 14 with the
   source and build paths mapped away, and writes `VERSION`: the commit, the patch's sha256 and
   the Xcode, SDK, clang and cmake that built it. On a Mac with Xcode, cmake and ninja, the same
   script gives the same tarball for the same Xcode (its header says how).
   The patch makes pixal3d.cpp honour `PIXAL3D_STEPS` (its log says "PIXAL3D_STEPS=8 overrides
   12 steps"): stock pixal3d.cpp ignores it, and Mimic stops any run whose engine does. It isn't
   Mimic's own code: it's the change `scripts/patch_pixal3d_steps.py` in
   [image-to-3dlab](https://github.com/Bingeljell/image-to-3dlab) (Bingeljell, Apache-2.0)
   makes, as a diff. Its header says where from, and `tools/LICENSE-image-to-3dlab` (that
   licence and image-to-3dlab's NOTICE) ships in the tarball.
2. Check the artifact, then upload the tarball to a GitHub release by hand. The workflow never
   publishes anything.
3. Update `EngineDownload.version` and `EngineDownload.engine` (URL, size, sha256) in
   `app/Sources/MimicCore/EngineDownload.swift`. Installed copies replace an engine whose
   `VERSION` doesn't match the next time setup runs (Settings → General → Repair).
