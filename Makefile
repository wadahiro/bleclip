PREFIX ?= /usr/local

.PHONY: build release install uninstall clean

build:
	swift build

release:
	swift build -c release

install: release
	install -d $(PREFIX)/bin
	install .build/release/bleclip $(PREFIX)/bin/bleclip

uninstall:
	rm -f $(PREFIX)/bin/bleclip

clean:
	swift package clean
