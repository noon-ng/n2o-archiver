# N2O Archiver

A macOS archive extractor written in Objective-C with a programmatic AppKit UI:
double-click an archive, watch a progress window, get a folder next to the
archive. Zip, RAR, tar and similar formats are read by a statically linked
libarchive; 7z is extracted by a bundled `7zz`.

It is a clone of [The Unarchiver](https://theunarchiver.com), built by coding
agents under direction, for personal use and to learn agentic coding
techniques. It is not a supported product: there is no notarized build, one
language, and Apple silicon only.

[docs/architecture.md](docs/architecture.md) draws the architecture: a figure
of the components and the threads they run on, and a table mapping each feature
to the code that implements it.

## Requirements

- macOS 13 or later, Apple silicon. Developed on macOS 27.
- Xcode Command Line Tools.
- Homebrew packages: `libarchive`, `xz`, `zstd`, `lz4`, `libb2` (linked
  statically), `sevenzip` (its `7zz` is copied into the app), `librsvg` (builds
  the icon).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), only to generate an Xcode
  project from `project.yml`.

Homebrew supplies the build, not the runtime: the libraries are linked
statically and `7zz` is copied into the bundle, so the built app does not read
anything from `/opt/homebrew`.

## Build

```bash
brew install libarchive xz zstd lz4 libb2 sevenzip librsvg
make                 # build/N2OArchiver.app
make run             # build and open
make test            # 132 tests, standalone runner, no Xcode needed
make verify-bundle   # checks linkage, bundled 7zz, signatures, DYLD injection
make install         # replaces /Applications/N2OArchiver.app (uses sudo)
make strings         # regenerates the English strings table with genstrings
```

`make install` takes `INSTALL_DIR` and `SUDO` overrides, for example
`make install INSTALL_DIR="$HOME/Applications" SUDO=`.

For Xcode, or to run the same tests under XCTest:

```bash
xcodegen generate
xcodebuild test -project N2OArchiver.xcodeproj -scheme N2OArchiver
```

The app is signed ad hoc, so Gatekeeper refuses it on first launch: open it
once from the context menu (Control-click ▸ Open) to run it.

## What it does

- **One window per archive.** Selecting several archives in Finder opens them
  in one call, and they extract concurrently, each with its own window.
- **Output lands next to the archive**, named after it — `photos.zip` gives
  `photos`, and `photos 2` if that name is taken. An archive whose contents sit
  in a single top-level folder is unwrapped, so one folder is created, not two.
- **Nothing visible until it is finished.** Extraction writes into a hidden
  `.n2o-extract-<UUID>` folder, which is given the archive's
  `com.apple.quarantine` value and only then renamed. Gatekeeper therefore
  checks anything executable that came out of a downloaded archive.
- **A failed or cancelled extraction leaves nothing behind.** Cancelling, closing
  the window or quitting stops the extractor, removes the partial output, and
  only then closes the window.
- **It stops before filling the disk.** Free space on the destination volume is
  checked while extracting; below the smaller of 1 GB and 5% of the volume, the
  extraction stops and the output is removed.
- **Errors are readable.** A sheet names the archive and gives a short summary;
  long tool output goes into a collapsible, scrollable details area rather than
  a dialog taller than the screen.

## Formats

| Read by | Formats |
| --- | --- |
| libarchive (static) | zip, rar (RAR4 and RAR5), tar plain or compressed, cpio, iso, cab, lzh/lha, warc, xar, ar |
| libarchive (static) | single compressed files: `.gz`, `.bz2`, `.xz`, `.lzma`, `.zst`, `.lz` |
| bundled `7zz` (≥ 25.01) | 7z |

RAR goes to libarchive rather than `7zz`: Homebrew builds `7zz` without the RAR
codecs, which yields empty files for compressed RAR entries. `mtree` is not
enabled, because it matches most text files and can reference files elsewhere
on disk.

Password-protected archives are reported as such, not prompted for. The app
only extracts; it does not create archives.

## Handling of untrusted input

Archives are untrusted input, so the extraction path is deliberately narrow:

- Entry paths are rejected if they contain `..` or resolve through a symlink
  (`ARCHIVE_EXTRACT_SECURE_NODOTDOT`, `_SECURE_SYMLINKS`), and the destination
  is `realpath`-resolved first so the check covers every component.
- Permissions come from the app, not the archive: no `PERM`, `ACL` or `FFLAGS`
  restore, and each mode is masked to `0755` — dropping group and other write
  along with the setuid, setgid and sticky bits — then given owner read, or
  owner read, write and execute for a directory, so the output can always be
  listed, marked and removed.
- `7zz` runs with `stdin` on `/dev/null`, an empty `-p`, and an explicit
  `-t<format>` so it cannot be talked into another format by file content.
  Version 25.01 or later is required, the first with fixes for CVE-2025-11001,
  CVE-2025-11002 and CVE-2025-55188.
- Extended attributes are not restored from archives, so an archive cannot
  supply its own quarantine value.
- The bundle uses the hardened runtime; library validation is disabled only so
  that plugins can load, and `make verify-bundle` checks that `DYLD_INSERT_LIBRARIES`
  is ignored.
- `Tests/Fixtures` holds crafted hostile archives on purpose — path traversal
  through `..`, absolute paths, symlinks and hardlinks, a damaged header, zero
  blocks, an ACL and `uchg` flags. `encrypted.7z` is encrypted with the
  password `secret`. They are inputs for the tests, not examples to extract.

## Plugins

Extractors are classes conforming to `NAExtractorPlugin`
([N2OArchiver/NAExtractorPlugin.h](N2OArchiver/NAExtractorPlugin.h)): declare
the extensions and UTIs handled, sniff a file, and extract it into a
directory while updating an `NSProgress` the caller owns and cancels.

Bundles are loaded from `Contents/PlugIns` in the app and from
`~/Library/Application Support/N2OArchiver/Plugins`, and only if their
signature chains to an Apple-issued certificate — any process running as the
user can write to Application Support, so an ad-hoc signature is not enough.
No third-party plugins exist; the built-in extractors use the same protocol.

## Tests

132 tests across nine suites, run by two runners from the same files:
`make test` builds a standalone runner that needs no Xcode, and `xcodebuild
test` runs them as XCTest with `NA_XCTEST=1`. Tests that need `7zz` report a
skip when it is not installed. The XCTest bundle has no host app, so running
the tests never launches the app.

## Known limitations

- Ad-hoc signed and not notarized, so first launch needs Control-click ▸ Open.
- The deployment target is macOS 13, but Homebrew's static libraries are built
  for macOS 26, which produces 106 linker warnings. The app has only been run
  on macOS 27.
- Apple silicon only; the architecture is fixed in the Makefile.
- Exit code 1 from `7zz` (a warning) is treated as a failure.
- No fixture covers compressed RAR or RAR5; RAR5 extraction was checked by hand
  against a 3703-entry archive.
- No cap on concurrent extractions: opening fifty archives starts fifty.
- English only, though the strings are localizable.
- No drag and drop, no Quick Look extension, no password prompt.
- Finder does not offer the app for `.lz`, `.zst`, `.zstd` and `.ar`, which have
  no system content type; they can still be chosen in the open panel.
- Extraction runs in the app process. Moving it into a sandboxed XPC service is
  planned for a later version.

## License

MIT, see [LICENSE](LICENSE).

The app links or bundles third-party components under their own licenses:

| Component | License | How it ships |
| --- | --- | --- |
| libarchive | BSD-2-Clause | linked statically |
| liblzma (xz) | 0BSD | linked statically |
| zstd | BSD-3-Clause | linked statically |
| lz4 | BSD-2-Clause | linked statically |
| libb2 | CC0-1.0 | linked statically |
| 7-Zip (`7zz`) | LGPL-2.1-or-later | separate executable in `Contents/Helpers`, run as a subprocess |

Distributing a built app, rather than this source, carries their notice
requirements: the BSD licenses ask for their copyright notices to accompany the
binary, and 7-Zip's LGPL asks for its license text and a pointer to the source
of the bundled version.
