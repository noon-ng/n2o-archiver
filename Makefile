APP_NAME     = N2OArchiver
BUNDLE       = build/$(APP_NAME).app
EXECUTABLE   = $(BUNDLE)/Contents/MacOS/$(APP_NAME)

CC           = clang
ARCH         = -arch arm64
MIN_OS       = -mmacosx-version-min=13.0

# Homebrew libarchive paths
LIBARCHIVE_PREFIX = $(shell brew --prefix libarchive 2>/dev/null || echo /opt/homebrew/opt/libarchive)

CFLAGS = -fobjc-arc \
         $(ARCH) \
         $(MIN_OS) \
         -Wall -Wextra -Wno-unused-parameter \
         -I$(LIBARCHIVE_PREFIX)/include \
         -IN2OArchiver \
         -ITests

LDFLAGS = $(ARCH) $(MIN_OS) \
          -L$(LIBARCHIVE_PREFIX)/lib \
          -larchive \
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
          N2OArchiver/Plugins/NA7zExtractor.m \
          N2OArchiver/Plugins/NARarExtractor.m

OBJECTS = $(patsubst %.m,build/obj/%.o,$(SOURCES))

# Test sources — main.m #imports the test .m files directly, so only
# these need to compile.  The app sources (minus main.m) are linked in.
TEST_SOURCES = Tests/main.m \
               Tests/NATestCase.m \
               Tests/NATestFixtures.m

APP_SOURCES_NO_MAIN = $(filter-out N2OArchiver/main.m,$(SOURCES))
TEST_OBJECTS = $(patsubst %.m,build/obj/%.o,$(TEST_SOURCES)) \
               $(patsubst %.m,build/obj/%.o,$(APP_SOURCES_NO_MAIN))
TEST_BIN     = build/N2OArchiverTests

# Icon generation
ICON_SRC      = N2OArchiver/Resources/AppIcon.svg
ICONSET_DIR   = build/icon.iconset
ICON_ICNS     = $(BUNDLE)/Contents/Resources/AppIcon.icns

ICON_SIZES = 16 32 128 256 512

.PHONY: all clean run test icons install uninstall

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

$(BUNDLE): $(EXECUTABLE) N2OArchiver/Info.plist icons
	@cp N2OArchiver/Info.plist $(BUNDLE)/Contents/Info.plist
	@mkdir -p $(BUNDLE)/Contents/PlugIns
	@echo "Built $(BUNDLE)"

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
