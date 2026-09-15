#!/bin/sh
# Checks a built N2OArchiver.app: no Homebrew libraries linked, 7zz bundled,
# hardened runtime on the app and the helper, and DYLD_INSERT_LIBRARIES ignored.
# Usage: Tests/verify-bundle.sh build/N2OArchiver.app
set -u
BUNDLE="$1"
EXECUTABLE="$BUNDLE/Contents/MacOS/N2OArchiver"
HELPER="$BUNDLE/Contents/Helpers/7zz"
ENTITLEMENTS="$(dirname "$0")/../N2OArchiver/N2OArchiver.entitlements"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/n2o-verify-bundle.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
    if [ "$1" -eq 0 ]; then echo "  ok: $2"; else echo "  FAIL: $2"; failures=$((failures + 1)); fi
}

echo "Verifying $BUNDLE"

otool -L "$EXECUTABLE" | tail -n +2 | grep -Eq '/opt/homebrew|/usr/local'
[ $? -ne 0 ]; check $? "executable links no libraries from /opt/homebrew or /usr/local"

codesign --verify --strict "$BUNDLE" 2>/dev/null
check $? "app signature verifies"

codesign -dv "$EXECUTABLE" 2>&1 | grep -q 'flags=.*runtime'
check $? "app is signed with hardened runtime"

codesign -d --entitlements - "$BUNDLE" 2>/dev/null | grep -q 'disable-library-validation'
check $? "app has the disable-library-validation entitlement"

[ -x "$HELPER" ]
check $? "7zz is bundled in Contents/Helpers"

codesign -dv "$HELPER" 2>&1 | grep -q 'flags=.*runtime'
check $? "bundled 7zz is signed with hardened runtime"

version="$("$HELPER" </dev/null 2>/dev/null | sed -n 's/^7-Zip[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
[ -n "$version" ] && [ "$(printf '%s\n25.01\n' "$version" | sort -t. -k1,1n -k2,2n | head -1)" = "25.01" ]
check $? "bundled 7zz version ${version:-unknown} is at least 25.01"

# A library whose constructor writes a marker file and exits.
cat > "$WORK/inject.c" <<'SRC'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
__attribute__((constructor)) static void injected(void) {
    FILE *f = fopen(getenv("N2O_INJECT_MARKER"), "w");
    if (f) fclose(f);
    _exit(0);
}
SRC
clang -arch arm64 -dynamiclib -o "$WORK/inject.dylib" "$WORK/inject.c"

[ -x "$HELPER" ] && {
    N2O_INJECT_MARKER="$WORK/helper-marker" DYLD_INSERT_LIBRARIES="$WORK/inject.dylib" \
        "$HELPER" </dev/null >/dev/null 2>&1
    [ ! -e "$WORK/helper-marker" ]
}
check $? "bundled 7zz ignores DYLD_INSERT_LIBRARIES"

# The app itself would open a window, so the same signing options and
# entitlements are applied to a small command-line program instead.
printf 'int main(void) { return 0; }\n' > "$WORK/probe.c"
clang -arch arm64 -o "$WORK/probe" "$WORK/probe.c"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$WORK/probe" 2>/dev/null
N2O_INJECT_MARKER="$WORK/probe-marker" DYLD_INSERT_LIBRARIES="$WORK/inject.dylib" "$WORK/probe"
[ ! -e "$WORK/probe-marker" ]
check $? "a program signed like the app ignores DYLD_INSERT_LIBRARIES"

if [ "$failures" -eq 0 ]; then echo "All bundle checks passed."; else echo "$failures bundle check(s) failed."; fi
exit "$failures"
