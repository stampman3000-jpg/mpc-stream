# The helper is a small Mac program. It is not part of the MPC plugin.
# `make` builds the terminal helper. `make app` builds the window.
play: play.m stream.h
	clang -fobjc-arc -Wall -Wextra -framework AudioToolbox -framework CoreAudio -framework Foundation -o play play.m

APP = Stream.app/Contents/MacOS/Stream

.PHONY: selftest app
selftest: play
	./play --selftest

app: $(APP)

$(APP): play.m app.m stream.h Info.plist
	mkdir -p Stream.app/Contents/MacOS
	clang -fobjc-arc -Wall -Wextra -DSTREAM_APP -framework Cocoa -framework AudioToolbox -framework CoreAudio -o $(APP) app.m play.m
	cp Info.plist Stream.app/Contents/Info.plist
