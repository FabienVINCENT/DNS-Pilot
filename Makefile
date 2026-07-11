APP     = dist/DNS Pilot.app
BIN     = .build/release/DNSPilot
# Version injectée dans l'Info.plist du bundle. Par défaut celle du dépôt ;
# surchargez avec `make dmg VERSION=1.2.3 BUILD=42` (c'est ce que fait la CI).
VERSION ?= $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist 2>/dev/null || echo 1.0.0)
BUILD   ?= 1
DMG     = dist/DNS-Pilot-$(VERSION).dmg

.PHONY: build app dmg install run clean

## Compile le binaire en mode release
build:
	swift build -c release

## Construit le bundle "DNS Pilot.app" dans dist/
app: build
	rm -rf dist
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$(BIN)" "$(APP)/Contents/MacOS/DNSPilot"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD)" "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"
	@echo "✓ Bundle créé : $(APP) (v$(VERSION), build $(BUILD))"

## Construit l'image disque dist/DNS-Pilot-$(VERSION).dmg (app + raccourci /Applications)
dmg: app
	rm -rf dist/dmg "$(DMG)"
	mkdir -p dist/dmg
	cp -R "$(APP)" dist/dmg/
	ln -s /Applications dist/dmg/Applications
	hdiutil create -volname "DNS Pilot $(VERSION)" -srcfolder dist/dmg -ov -format UDZO "$(DMG)"
	rm -rf dist/dmg
	@echo "✓ DMG créé : $(DMG)"

## Installe dans ~/Applications
install: app
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/DNS Pilot.app"
	cp -R "$(APP)" "$(HOME)/Applications/"
	@echo "✓ Installé : ~/Applications/DNS Pilot.app — lancez-le depuis le Finder ou Spotlight."

## Lance en mode développement (sans bundle)
run:
	swift run DNSPilot

clean:
	rm -rf .build dist
