# The helper is a small Mac program. It is not part of the MPC plugin.
play: play.m
	clang -fobjc-arc -Wall -Wextra -framework AudioToolbox -framework CoreAudio -framework Foundation -o play play.m

.PHONY: selftest
selftest: play
	./play --selftest
