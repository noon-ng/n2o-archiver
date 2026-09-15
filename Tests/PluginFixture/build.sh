#!/bin/sh
# Builds Tests/Fixtures/AdHocSignedPlugin.bundle from NATestAdHocPlugin.m.
set -e
cd "$(dirname "$0")/../.."
BUNDLE=Tests/Fixtures/AdHocSignedPlugin.bundle
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp Tests/PluginFixture/Info.plist "$BUNDLE/Contents/Info.plist"
clang -fobjc-arc -arch arm64 -mmacosx-version-min=13.0 -bundle -undefined dynamic_lookup \
    -IN2OArchiver -framework Foundation \
    -o "$BUNDLE/Contents/MacOS/AdHocSignedPlugin" Tests/PluginFixture/NATestAdHocPlugin.m
# Sign the whole bundle ad hoc, so its signature is valid but not issued by Apple.
codesign --force --sign - "$BUNDLE"
