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
         -IN2OArchiver

LDFLAGS = $(ARCH) $(MIN_OS) \
          -L$(LIBARCHIVE_PREFIX)/lib \
          -larchive \
          -framework Cocoa \
          -framework UniformTypeIdentifiers

SOURCES = N2OArchiver/main.m \
          N2OArchiver/AppDelegate.m \
          N2OArchiver/NAPluginManager.m \
          N2OArchiver/NAExtractionWindowController.m \
          N2OArchiver/Plugins/NALibarchiveExtractor.m

OBJECTS = $(patsubst %.m,build/obj/%.o,$(SOURCES))

.PHONY: all clean run

all: $(BUNDLE)

$(BUNDLE): $(EXECUTABLE) N2OArchiver/Info.plist
	@cp N2OArchiver/Info.plist $(BUNDLE)/Contents/Info.plist
	@mkdir -p $(BUNDLE)/Contents/PlugIns
	@mkdir -p $(BUNDLE)/Contents/Resources
	@echo "Built $(BUNDLE)"

$(EXECUTABLE): $(OBJECTS)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS) -o $@ $(OBJECTS)

build/obj/%.o: %.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

run: $(BUNDLE)
	open $(BUNDLE)

clean:
	rm -rf build
