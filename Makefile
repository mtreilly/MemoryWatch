.PHONY: build test install snapshot daemon io report suspects release-app

build:
	cd MemoryWatchApp && swift build -c release

test:
	cd MemoryWatchApp && swift test -q

install: build
	cp MemoryWatchApp/.build/release/MemoryWatch /usr/local/bin/memwatch

snapshot:
	MemoryWatchApp/.build/release/MemoryWatch snapshot

daemon:
	MemoryWatchApp/.build/release/MemoryWatch daemon

io:
	MemoryWatchApp/.build/release/MemoryWatch io

report:
	MemoryWatchApp/.build/release/MemoryWatch report

suspects:
	MemoryWatchApp/.build/release/MemoryWatch suspects

release-app:
	./scripts/release_build.sh
