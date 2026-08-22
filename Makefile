# terminal-notifier
#
# Builds with the Command Line Tools alone. The Xcode project is still there if
# you prefer it, but nothing here needs it.

SRC_DIR   := Terminal Notifier
PLIST     := $(SRC_DIR)/Terminal Notifier-Info.plist

NAME      := terminal-notifier
VERSION   := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '$(PLIST)')
BUNDLE_ID := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '$(PLIST)')

MIN_MACOS := 10.14
ARCHS     := -arch arm64 -arch x86_64
FRAMEWORKS := -framework Cocoa -framework UserNotifications
CFLAGS    := -fobjc-arc -std=gnu11 -Os -Wall -mmacosx-version-min=$(MIN_MACOS)

BUILD_DIR := build
APP       := $(BUILD_DIR)/$(NAME).app

# Where `make install` puts things. /Applications keeps the bundle somewhere
# LaunchServices scans, which notification permissions depend on.
APPDIR    ?= /Applications
PREFIX    ?= /usr/local

ICON      ?=
APP_NAME  ?=

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo 'terminal-notifier $(VERSION)'
	@echo
	@echo 'Targets:'
	@echo '  make app                       build $(APP)'
	@echo '  make install                   install to $(APPDIR) and link into $(PREFIX)/bin'
	@echo '  make uninstall                 remove both'
	@echo '  make icon ICON=path/to.png     build a copy with your own icon'
	@echo '           [APP_NAME=my-tool]    (see "Custom icons" in the README)'
	@echo '  make doctor                    check every documented option works'
	@echo '                                 (prompts you for the interactive ones)'
	@echo '  make test                      everything that runs without a person'
	@echo '  make test-native               the doctor'"'"'s unattended checks only'
	@echo '  make test-ruby                 the Ruby gem specs'
	@echo '  make screenshots               regenerate the images in assets/'
	@echo '  make clean                     remove $(BUILD_DIR)'
	@echo
	@echo 'install may need sudo, depending on $(APPDIR) and $(PREFIX).'

# Two source files that compile in a couple of seconds, and a directory name
# containing a space. Rebuilding unconditionally is simpler and more reliable
# than teaching make to track prerequisites through the quoting.
.PHONY: app
app:
	@echo '==> building $(NAME) $(VERSION) (universal, macOS $(MIN_MACOS)+)'
	@rm -rf '$(APP)'
	@mkdir -p '$(APP)/Contents/MacOS' '$(APP)/Contents/Resources'
	@clang $(CFLAGS) $(ARCHS) $(FRAMEWORKS) \
		-o '$(APP)/Contents/MacOS/$(NAME)' \
		'$(SRC_DIR)/main.m' '$(SRC_DIR)/AppDelegate.m'
	@# Xcode expands these two; doing it by hand keeps the plist identical.
	@sed -e 's/$${EXECUTABLE_NAME}/$(NAME)/' \
	     -e 's/$${PRODUCT_NAME}/$(NAME)/' \
	     '$(PLIST)' > '$(APP)/Contents/Info.plist'
	@printf 'APPL????' > '$(APP)/Contents/PkgInfo'
	@cp Terminal.icns '$(APP)/Contents/Resources/Terminal.icns'
	@cp -R '$(SRC_DIR)/en.lproj' '$(APP)/Contents/Resources/'
	@# Ad-hoc signature. A notification is attributed to a bundle identity, so
	@# an unsigned bundle gets unreliable permissions on modern macOS.
	@codesign --force --sign - '$(APP)'
	@echo '==> $(APP)'
	@lipo -info '$(APP)/Contents/MacOS/$(NAME)' | sed 's/^/    /'

.PHONY: install
install: app
	@echo '==> installing to $(APPDIR)'
	rm -rf '$(APPDIR)/$(NAME).app'
	cp -R '$(APP)' '$(APPDIR)/'
	mkdir -p '$(PREFIX)/bin'
	ln -sf '$(APPDIR)/$(NAME).app/Contents/MacOS/$(NAME)' '$(PREFIX)/bin/$(NAME)'
	@echo '==> $(PREFIX)/bin/$(NAME) -> $(APPDIR)/$(NAME).app'

.PHONY: uninstall
uninstall:
	rm -rf '$(APPDIR)/$(NAME).app'
	rm -f '$(PREFIX)/bin/$(NAME)'

# macOS has no API to override a notification's icon. It always comes from the
# app bundle, so a custom icon means a custom bundle: its own name, its own
# identifier and therefore its own row in System Settings > Notifications.
.PHONY: icon
icon: app
	@if [ -z '$(ICON)' ]; then \
		echo 'usage: make icon ICON=path/to/image.png [APP_NAME=my-tool]'; exit 1; fi
	@if [ ! -f '$(ICON)' ]; then echo 'no such file: $(ICON)'; exit 1; fi
	@set -e; \
	name='$(APP_NAME)'; \
	if [ -z "$$name" ]; then name=$$(basename '$(ICON)' | sed 's/\.[^.]*$$//'); fi; \
	dest='$(BUILD_DIR)/'"$$name"'.app'; \
	echo "==> building $$dest"; \
	rm -rf "$$dest"; \
	cp -R '$(APP)' "$$dest"; \
	case '$(ICON)' in \
	  *.icns) cp '$(ICON)' "$$dest/Contents/Resources/icon.icns" ;; \
	  *) \
	    set='$(BUILD_DIR)/icon.iconset'; \
	    rm -rf "$$set"; mkdir -p "$$set"; \
	    for size in 16 32 128 256 512; do \
	      sips -z $$size $$size '$(ICON)' --out "$$set/icon_$${size}x$${size}.png" >/dev/null; \
	      double=$$((size * 2)); \
	      sips -z $$double $$double '$(ICON)' --out "$$set/icon_$${size}x$${size}@2x.png" >/dev/null; \
	    done; \
	    iconutil --convert icns "$$set" --output "$$dest/Contents/Resources/icon.icns"; \
	    rm -rf "$$set" ;; \
	esac; \
	rm -f "$$dest/Contents/Resources/Terminal.icns"; \
	/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile icon' "$$dest/Contents/Info.plist"; \
	/usr/libexec/PlistBuddy -c 'Set :CFBundleName '"$$name" "$$dest/Contents/Info.plist"; \
	/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier $(BUNDLE_ID).'"$$name" "$$dest/Contents/Info.plist"; \
	codesign --force --sign - "$$dest"; \
	echo "==> $$dest"; \
	echo "    bundle id  $(BUNDLE_ID).$$name"; \
	echo "    it will ask for notification permission separately the first time"

.PHONY: test
test: test-native test-ruby

# Everything here runs without a notification permission, so it works headless
# and in CI. Actually delivering a notification needs a TCC grant, which cannot
# be given non-interactively — see test-delivery.
.PHONY: doctor
doctor: app
	@tests/doctor.sh

# Everything the doctor can check without a person. Delivery needs a granted
# permission and a GUI session, so those checks report as skipped rather than
# failed when they are unavailable, and the exit status stays 0.
.PHONY: test-native
test-native: app
	@tests/doctor.sh --unattended

.PHONY: test-ruby
test-ruby:
	@echo '==> ruby specs'
	@cd Ruby && bundle exec rspec

# Needs Screen Recording permission for the terminal you run it from.
.PHONY: screenshots
screenshots: app
	@tools/screenshots.sh

.PHONY: clean
clean:
	rm -rf '$(BUILD_DIR)'
