# Security

## Supported versions

Only the latest release gets security fixes. Mimic updates itself, so the fix reaches you in the
next release.

## Reporting a problem

Please don't open a public issue for a security problem. Report it privately on
[GitHub](https://github.com/yonatankarp/mimic/security/advisories/new) instead. If that doesn't
work for you, use the contact details on [the maintainer's profile](https://github.com/yonatankarp).

Say what the problem is, which version of Mimic has it, and how to reproduce it. Please keep it
private until a fix is released.

## Checking a download

From Mimic 0.10.0, every disk image on the Releases page comes with a signed record of the build
that made it. To check that yours is genuine, run
`gh attestation verify Mimic-<version>.dmg --repo yonatankarp/mimic`.
