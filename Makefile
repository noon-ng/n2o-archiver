APP_NAME     = N2OArchiver
BUNDLE       = build/$(APP_NAME).app
EXECUTABLE   = $(BUNDLE)/Contents/MacOS/$(APP_NAME)

CC           = clang
ARCH         = -arch arm64
MIN_OS       = -mmacosx-version-min=13.0

# Homebrew paths. libarchive and its Homebrew dependencies are linked
# statically and 7zz is copied into the bundle, so the app does not load or
# run code from the Homebrew prefix, which the user account can write to.
LIBARCHIVE_PREFIX = $(shell brew --prefix libarchive 2>/dev/null || echo /opt/homebrew/opt/libarchive)
XZ_PREFIX         = $(shell brew --prefix xz 2>/dev/null || echo /opt/homebrew/opt/xz)
ZSTD_PREFIX       = $(shell brew --prefix zstd 2>/dev/null || echo /opt/homebrew/opt/zstd)
LZ4_PREFIX        = $(shell brew --prefix lz4 2>/dev/null || echo /opt/homebrew/opt/lz4)
LIBB2_PREFIX      = $(shell brew --prefix libb2 2>/dev/null || echo /opt/homebrew/opt/libb2)
SEVENZIP_PREFIX   = $(shell brew --prefix sevenzip 2>/dev/null || echo /opt/homebrew/opt/sevenzip)

STATIC_LIBS = $(LIBARCHIVE_PREFIX)/lib/libarchive.a \
              $(XZ_PREFIX)/lib/liblzma.a \
              $(ZSTD_PREFIX)/lib/libzstd.a \
              $(LZ4_PREFIX)/lib/liblz4.a \
              $(LIBB2_PREFIX)/lib/libb2.a

CFLAGS = -fobjc-arc \
         $(ARCH) \
         $(MIN_OS) \
         -Wall -Wextra -Wno-unused-parameter \
         -I$(LIBARCHIVE_PREFIX)/include \
         -IN2OArchiver \
         -ITests

LDFLAGS = $(ARCH) $(MIN_OS) \
          $(STATIC_LIBS) \
          -lexpat -lbz2 -lz -liconv \
          -framework Cocoa \
          -framework Security \
          -framework UniformTypeIdentifiers

SOURCES = N2OArchiver/main.m \
          N2OArchiver/AppDelegate.m \
          N2OArchiver/NAPluginManager.m \
          N2OArchiver/NAExtractionWindowController.m \
          N2OArchiver/NAQuarantine.m \
          N2OArchiver/Plugins/NALibarchiveExtractor.m \
          N2OArchiver/Plugins/NA7zzTool.m \
          N2OArchiver/Plugins/NA7zzExtractor.m \
          N2OArchiver/Plugins/NA7zExtractor.m \
          N2OArchiver/Plugins/NARarExtractor.m

OBJECTS = $(patsubst %.m,build/obj/%.o,$(SOURCES))

# Test sources — main.m #imports the test .m files directly, so only
# these need to compile.  The app sources (minus main.m) are linked in.
TEST_SOURCES = Tests/main.m \
               Tests/NATestCase.m \
               Tests/NATestFixtures.m \
               Tests/NAWait.m

APP_SOURCES_NO_MAIN = $(filter-out N2OArchiver/main.m,$(SOURCES))
TEST_OBJECTS = $(patsubst %.m,build/obj/%.o,$(TEST_SOURCES)) \
               $(patsubst %.m,build/obj/%.o,$(APP_SOURCES_NO_MAIN))
TEST_BIN     = build/N2OArchiverTests

# Icon generation
ICON_SRC      = N2OArchiver/Resources/AppIcon.svg
ICONSET_DIR   = build/icon.iconset
ICON_ICNS     = $(BUNDLE)/Contents/Resources/AppIcon.icns

ICON_SIZES = 16 32 128 256 512

HELPER_7ZZ   = $(BUNDLE)/Contents/Helpers/7zz
ENTITLEMENTS = N2OArchiver/N2OArchiver.entitlements

.PHONY: all clean run test icons install uninstall verify-bundle

all: $(BUNDLE)

icons: $(ICON_ICNS)

$(ICONSET_DIR): $(ICON_SRC)
	@mkdir -p $(ICONSET_DIR)
	@for size in $(ICON_SIZES); do \
		out1="icon_$${size}x$${size}.png"; \
		out2="icon_$${size}x$${size}@2x.png"; \
		rsvg-convert -w $$size -h $$size -f png $(ICON_SRC) > $(ICONSET_DIR)/$$out1; \
		rsvg-convert -w $$((size * 2)) -h $$((size * 2)) -f png $(ICON_SRC) > $(ICONSET_DIR)/$$out2; \
	done

$(ICON_ICNS): $(ICONSET_DIR)
	@mkdir -p $(dir $@)
	iconutil -c icns $< -o $@

$(BUNDLE): $(EXECUTABLE) N2OArchiver/Info.plist $(ENTITLEMENTS) icons
	@cp N2OArchiver/Info.plist $(BUNDLE)/Contents/Info.plist
	@mkdir -p $(BUNDLE)/Contents/PlugIns $(BUNDLE)/Contents/Helpers
	@cp -f "$$(realpath $(SEVENZIP_PREFIX)/bin/7zz)" $(HELPER_7ZZ)
	@chmod 755 $(HELPER_7ZZ)
	@# Ad-hoc signatures with hardened runtime: the helper, then the app.
	codesign --force --options runtime --sign - $(HELPER_7ZZ)
	codesign --force --options runtime --entitlements $(ENTITLEMENTS) --sign - $(BUNDLE)
	@echo "Built $(BUNDLE)"

verify-bundle: $(BUNDLE)
	Tests/verify-bundle.sh $(BUNDLE)

$(EXECUTABLE): $(OBJECTS)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS) -o $@ $(OBJECTS)

build/obj/%.o: %.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

run: $(BUNDLE)
	open $(BUNDLE)

test: $(TEST_BIN)
	./$(TEST_BIN)

$(TEST_BIN): $(TEST_OBJECTS)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS) -o $@ $(TEST_OBJECTS)

install: $(BUNDLE)
	sudo cp -Rf $(BUNDLE) /Applications/
	@echo "Installed $(APP_NAME) to /Applications/"

uninstall:
	sudo rm -rf /Applications/$(APP_NAME).app
	@echo "Removed $(APP_NAME) from /Applications/"

clean:
	rm -rf build
