APP     = dist/DNS Pilot.app
BIN     = .build/release/DNSPilot

.PHONY: build app install run clean

## Compile le binaire en mode release
build:
	swift build -c release

## Construit le bundle "DNS Pilot.app" dans dist/
app: build
	rm -rf dist
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$(BIN)" "$(APP)/Contents/MacOS/DNSPilot"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"
	@echo "✓ Bundle créé : $(APP)"

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
