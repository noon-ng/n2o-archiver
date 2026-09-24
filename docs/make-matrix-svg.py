#!/usr/bin/env python3
"""Draws docs/architecture-matrix.svg: which slice implements each feature.

Each row is a feature and each cell names the code that does the work. A chip
starting with "!" is a known limitation, one starting with "?" a path no test
covers. Run from the repository root after changing the data below:

    python3 docs/make-matrix-svg.py
"""

import pathlib

COLUMNS = [
    ("entry", "macOS entry points", "Info.plist · main.m", "outside"),
    ("app", "AppDelegate", "main thread", "main"),
    ("wc", "Window controller", "main thread", "main"),
    ("job", "Extraction job", "main · queue", "main"),
    ("pm", "Plugin manager", "main thread", "main"),
    ("la", "libarchive", "dispatch queue", "bg"),
    ("sz", "7z + 7zz", "queue · process", "bg"),
    ("build", "Build", "Makefile", "outside"),
]

ROWS = [
    ("Open from Finder", "double-click or Open With", {
        "entry": ["CFBundleDocumentTypes: the 17 extractor UTIs", "no system type for .lz, .zst, .ar"],
        "app": ["application:openURLs:", "extractFileAtURL:"],
        "wc": ["beginExtraction"], "job": ["start"]}),
    ("Choose archives in a panel", "at launch with no files, or File ▸ Open…", {
        "entry": ["NSOpenPanel", "NAMainMenu: File ▸ Open… ⌘O"],
        "app": ["applicationDidFinishLaunching:", "openDocument:", "allowedContentTypes: UTIs + extensions"],
        "pm": ["allPluginClasses"]}),
    ("Pick an extractor", "content first, then file extension", {
        "app": ["registerBuiltinExtractors", "registerExtractorClass:"],
        "job": ["pluginManager injected"], "pm": ["extractorForFileAtURL:"],
        "la": ["canHandleFileAtURL: needs an entry, not empty, raw only if compressed"],
        "sz": ["NA7zzExtractor +signatures", "+formatTypeForFileAtURL: → -t"]}),
    ("Extract zip, rar, tar, cpio, iso and more", "all libarchive formats except mtree; RAR4 and RAR5", {
        "job": ["dispatch_async global queue"],
        "la": ["NANewArchiveReader()", "extractArchiveAtURL:…", "no data step for directories (RAR5)",
               "continues on ARCHIVE_WARN, fails on read errors", "no entries → error"]}),
    ("Keep extracted files private and removable", "no world-writable, setuid, ACLs or flags from the archive", {
        "la": ["sanitizedPermissionsForEntry:", "no EXTRACT_PERM, ACL, FFLAGS"],
        "sz": ["7zz applies the umask"]}),
    ("Decompress a single .gz, .bz2 or .xz", "plain.txt.gz → plain.txt", {
        "job": ["dispatch_async global queue"],
        "la": ["raw format behind a filter", "entry named after the archive"]}),
    ("Extract 7z", "RAR is not given to 7zz: Homebrew builds it without the RAR codec", {
        "job": ["dispatch_async global queue"],
        "sz": ["NA7zExtractor : NA7zzExtractor", "NA7zzTool -t7z", "!exit code 1 treated as failure",
               "toolPath: Contents/Helpers/7zz first, ≥ 25.01"]}),
    ("Keep files inside the output folder", "no ../, no writes through symlinks", {
        "la": ["SECURE_NODOTDOT", "SECURE_SYMLINKS", "rebaseEntry:"],
        "sz": ["7zz refuses outside symlinks (exit 2)", "?../ entries untested"]}),
    ("Create a new output folder", "hidden staging, then name, name 2…; removed on failure", {
        "job": ["createStagingDirectoryForArchive:error:", "moveStagingDirectory:…",
                "renamex_np RENAME_EXCL", "failed output removed"]}),
    ("Unwrap a single top-level folder", None, {
        "job": ["unwrapSingleItemDirectoryAtURL:"]}),
    ("Show progress", None, {
        "wc": ["progress bar, status label"],
        "job": ["NSProgress polled every 0.1 s", "progressHandler"],
        "la": ["completedUnitCount = archive_filter_bytes", "fileURL per entry"],
        "sz": ["7zz -bsp1", "NA7zzProgressParser → percent"]}),
    ("Reveal in Finder, then quit", None, {
        "app": ["terminateIfIdle"],
        "wc": ["jobDidFinish:", "extractionFinishedAtURL:", "revealHandler → activateFileViewerSelectingURLs:"],
        "job": ["Succeeded · destinationURL"]}),
    ("Cancel, close or quit mid-extraction", "output removed before the window closes", {
        "entry": ["⌘Q"], "app": ["applicationShouldTerminate:", "NSTerminateLater"],
        "wc": ["cancelExtraction: (Esc)", "windowShouldClose:"],
        "job": ["cancel → Cancelling → Cancelled", "-[NSProgress cancel]", "staging folder removed"],
        "la": ["progress.isCancelled per block"], "sz": ["progress.isCancelled poll", "NSTask terminate"]}),
    ("Show errors", "short summary; long output in collapsed, scrollable details", {
        "wc": ["presentError:title:", "NSAlert sheet + Show Details", "400×180 pt scroll view"],
        "job": ["error property"], "la": ["archive_error_string"],
        "sz": ["errorForStatus:stderrData:fallback:", "stderr as failure reason"]}),
    ("List archive contents", "protocol method; no caller in the app", {
        "la": ["contentsOfArchiveAtURL:error:"], "sz": ["7zz l -slt -p --", "members after ----------"]}),
    ("Load extractor plugins", "skipped unless signed by an Apple-issued certificate", {
        "app": ["applicationWillFinishLaunching:", "pluginDirectoryURLs"],
        "pm": ["+defaultPluginDirectoryURLs", "loadPluginsFromDirectoryURLs:", "isTrustedPluginAtURL:error:",
               "anchor apple generic", "NAExtractorPlugin"]}),
    ("Stop before the disk fills", "free space below min(1 GB, 5%)", {
        "wc": ["error sheet"], "job": ["startMonitor", "statfs every 0.1 s", "cancel + stopError"],
        "la": ["progress.isCancelled"], "sz": ["progress.isCancelled → terminate"]}),
    ("Keep running during extraction", "no App Nap, sudden or automatic termination", {
        "entry": ["no NSSupportsAutomaticTermination"],
        "job": ["held while isActive", "NSProcessInfo beginActivity…"]}),
    ("Mark extracted files as downloaded", "copies the archive's com.apple.quarantine", {
        "job": ["NAQuarantine copyQuarantineFromURL:toTreeAtURL:error:",
                "openat O_NOFOLLOW, fsetxattr, fchmod", "before rename, also on failure and cancel"]}),
    ("Build, sign, install", "hardened runtime, no Homebrew code at runtime", {
        "build": ["static libarchive.a and deps", "7zz → Contents/Helpers", "codesign --options runtime",
                  "make verify-bundle", "make strings → en.lproj", "rsvg-convert → iconutil",
                  "make install (ditto, replaces)", "make test", "-MMD -MP dependencies",
                  "?static libs built for macOS 26, target 13.0"]}),
]

FEATURE_W, COL_W = 250, 150
PAD, CHIP_PAD_X, CHIP_PAD_Y, CHIP_GAP = 12, 6, 4, 5
CHIP_SIZE, CHIP_LINE = 12.0, 15
MONO_CHAR, SANS_CHAR, DETAIL_CHAR = 0.63, 0.55, 0.52
HEAD_H, TRACK_OFFSET = 70, 22


def wrap(text, width_px, char_ratio, size):
    """Greedy wrap, breaking inside a word when it cannot fit on its own line."""
    limit = max(1, int(width_px / (char_ratio * size)))
    lines, line = [], ""
    for word in text.split(" "):
        while len(word) > limit:
            if line:
                lines.append(line)
                line = ""
            lines.append(word[:limit])
            word = word[limit:]
        candidate = word if not line else line + " " + word
        if len(candidate) <= limit:
            line = candidate
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


def escape(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def chip_lines(text):
    kind = "chip"
    if text.startswith("!"):
        kind, text = "chip limit", text[1:]
    elif text.startswith("?"):
        kind, text = "chip gap", text[1:]
    return kind, wrap(text, COL_W - 2 * PAD - 2 * CHIP_PAD_X, MONO_CHAR, CHIP_SIZE)


def main():
    out = []
    # Measure every row first: a row is as tall as its tallest cell.
    measured = []
    for feature, detail, cells in ROWS:
        title_lines = wrap(feature, FEATURE_W - 2 * PAD, SANS_CHAR, 13)
        detail_lines = wrap(detail, FEATURE_W - 2 * PAD, DETAIL_CHAR, 12) if detail else []
        height = PAD * 2 + len(title_lines) * 17 + len(detail_lines) * 15
        drawn = {}
        for key, _, _, _ in COLUMNS:
            if key not in cells:
                continue
            chips, y = [], PAD
            for item in cells[key]:
                kind, lines = chip_lines(item)
                box_h = len(lines) * CHIP_LINE + 2 * CHIP_PAD_Y
                chips.append((kind, lines, y, box_h))
                y += box_h + CHIP_GAP
            drawn[key] = chips
            height = max(height, y - CHIP_GAP + PAD)
        measured.append((title_lines, detail_lines, drawn, height))

    width = FEATURE_W + COL_W * len(COLUMNS)
    total = HEAD_H + sum(m[3] for m in measured)

    out.append('<?xml version="1.0" encoding="UTF-8"?>')
    out.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {total}" '
               f'width="{width}" height="{total}" role="img" '
               'aria-label="A matrix of N2O Archiver features against the components that implement them: '
               'macOS entry points, AppDelegate, the window controller, the extraction job, the plugin manager, '
               'the libarchive extractor, the 7z extractor with 7zz, and the build.">')
    out.append(f'<rect width="{width}" height="{total}" fill="var(--surface)"/>')
    out.append("""<style>
    svg { --surface:#FFFFFF; --ink:#1E1A17; --ink-2:#5B544E; --rule:#D9D5D0;
          --wood:#7E4D35; --steel:#2F6A8A; --limit:#B42318; --limit-tint:#FBEAE7;
          --gap:#8A6A00; --gap-tint:#FFF3D1;
          font-family:"IBM Plex Sans","Helvetica Neue",Arial,sans-serif; }
    @media (prefers-color-scheme: dark) {
      svg { --surface:#1D1B19; --ink:#EDE8E3; --ink-2:#A9A19A; --rule:#3A3632;
            --wood:#D3A47E; --steel:#7DB5D3; --limit:#F28B7D; --limit-tint:#3A1C18;
            --gap:#E5C160; --gap-tint:#312913; }
    }
    .where { font: 500 10px "IBM Plex Mono",Menlo,monospace; letter-spacing:0.06em; fill: var(--ink-2); }
    .colname { font-size: 12px; font-weight: 600; fill: var(--ink); }
    .feature { font-size: 13px; font-weight: 600; fill: var(--ink); }
    .detail { font-size: 12px; fill: var(--ink-2); }
    .rule { stroke: var(--rule); stroke-width: 1; }
    .track { stroke: var(--rule); stroke-width: 2; }
    .chipbox { fill: var(--surface); stroke: var(--rule); rx: 3; }
    .chipbox.main { stroke: var(--wood); }
    .chipbox.bg { stroke: var(--steel); }
    .chipbox.limit { stroke: var(--limit); fill: var(--limit-tint); }
    .chipbox.gap { stroke: var(--gap); fill: var(--gap-tint); stroke-dasharray: 4 3; }
    .chiptext { font: 400 12px "IBM Plex Mono",Menlo,monospace; fill: var(--ink); }
    .chiptext.limit { fill: var(--limit); }
    .chiptext.gap { fill: var(--gap); }
  </style>""")

    # Header.
    out.append(f'<text class="where" x="{PAD}" y="{HEAD_H - 34}">feature</text>')
    for i, (_, name, where, kind) in enumerate(COLUMNS):
        x = FEATURE_W + i * COL_W
        stroke = {"main": "var(--wood)", "bg": "var(--steel)"}.get(kind, "var(--rule)")
        out.append(f'<rect x="{x}" y="0" width="{COL_W}" height="3" fill="{stroke}"/>')
        out.append(f'<text class="where" x="{x + PAD}" y="{HEAD_H - 34}">{escape(where)}</text>')
        for j, line in enumerate(wrap(name, COL_W - 2 * PAD, SANS_CHAR, 12)):
            out.append(f'<text class="colname" x="{x + PAD}" y="{HEAD_H - 16 + j * 14}">{escape(line)}</text>')
    out.append(f'<line class="rule" x1="0" y1="{HEAD_H}" x2="{width}" y2="{HEAD_H}"/>')

    y = HEAD_H
    for index, (title_lines, detail_lines, drawn, height) in enumerate(measured):
        if index:
            out.append(f'<line class="rule" x1="0" y1="{y}" x2="{width}" y2="{y}"/>')

        touched = [i for i, (key, _, _, _) in enumerate(COLUMNS) if key in drawn]
        if len(touched) > 1:
            x1 = FEATURE_W + touched[0] * COL_W + COL_W / 2
            x2 = FEATURE_W + touched[-1] * COL_W + COL_W / 2
            out.append(f'<line class="track" x1="{x1}" y1="{y + TRACK_OFFSET}" '
                       f'x2="{x2}" y2="{y + TRACK_OFFSET}"/>')

        text_y = y + PAD + 13
        for line in title_lines:
            out.append(f'<text class="feature" x="{PAD}" y="{text_y}">{escape(line)}</text>')
            text_y += 17
        for line in detail_lines:
            out.append(f'<text class="detail" x="{PAD}" y="{text_y}">{escape(line)}</text>')
            text_y += 15

        for i, (key, _, _, kind) in enumerate(COLUMNS):
            if key not in drawn:
                continue
            x = FEATURE_W + i * COL_W + PAD
            for chip_kind, lines, offset, box_h in drawn[key]:
                classes = chip_kind if chip_kind != "chip" else "chip " + kind
                box_class = classes.replace("chip", "chipbox", 1)
                text_class = classes.replace("chip", "chiptext", 1)
                if kind == "outside" and box_class == "chipbox outside":
                    box_class, text_class = "chipbox", "chiptext"
                box_w = COL_W - 2 * PAD
                out.append(f'<rect class="{box_class}" x="{x}" y="{y + offset}" '
                           f'width="{box_w}" height="{box_h}"/>')
                line_y = y + offset + CHIP_PAD_Y + 10
                for line in lines:
                    out.append(f'<text class="{text_class}" x="{x + CHIP_PAD_X}" y="{line_y}">'
                               f'{escape(line)}</text>')
                    line_y += CHIP_LINE
        y += height

    out.append("</svg>")
    target = pathlib.Path(__file__).with_name("architecture-matrix.svg")
    target.write_text("\n".join(out) + "\n")
    print(f"wrote {target} ({width}×{total})")


if __name__ == "__main__":
    main()
