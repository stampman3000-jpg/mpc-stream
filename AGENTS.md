# AGENTS.md

Stream is an MPC effect plugin. On the Akai MPC it copies one track and sends that copy over the USB cable to a small Mac helper. The helper plays the copy into BlackHole 64ch so a DAW can record one stereo pair per track. The track on the MPC keeps playing at full level. Stream is listed in the sd88me MPC plugin catalogue.

`README.md` is the human setup. `HANDOVER.md` is the longer note for the next person. Follow both, and follow the Do not list below.

## Repo layout

- `src/stream.c` — the MPC effect. The audio thread only copies samples. A side thread sends UDP. Every Stream on the device shares one clock and one sender.
- `mac/play.m` — the Mac player. It listens on UDP port 47703 and plays into the device named exactly `BlackHole 64ch`.
- `mac/app.m` — the window and menu-bar helper. It runs the same player as `play.m`.
- `mac/Makefile`, `mac/stream.h`, `mac/Info.plist` — the Mac helper build.
- `vst/vst.json`, `vst/params.json`, `vst/layout.conf`, `vst/art/stream.jpg` — plugin description, Level and Pair knobs, and the skin photo.
- `tested.json` — the recorded on-device test (MPC One, firmware 3.9.1.2, 2026-10-10).
- `screenshots/stream.png` — the plugin screen.
- `LICENSE` — MIT, copyright Stampman3000 2026. Leave this file as it is.

The packet is little endian, sent to `192.168.2.1` port `47703`: `'T'`, pair byte 1–32, uint32 position in frames, uint16 frame count, then interleaved int16 stereo. Pair 1 is BlackHole channels 1–2.

## Build and test

Plugin check, from the repo root. This compiles the `STREAM_TEST` program at the bottom of `src/stream.c`:

```
clang -DSTREAM_TEST -pthread -o /tmp/stream-test src/stream.c
/tmp/stream-test
```

It prints `ok` for each check and a final `ok`, then exits 0. Keep that binary out of the repo.

The installable plugin is built with [mpc-vst-plugins](https://github.com/sd88me/mpc-vst-plugins), which is a separate checkout and needs Docker. Point its `build_port.sh` at this repo's `vst/vst.json`. That file compiles `src/stream.c` into `stream.so` with `-pthread`. `test_port.sh` in mpc-vst-plugins calls an effect with no input buffer, so the plugin check for this repo is the `STREAM_TEST` program above.

Mac helper, from `mac/`. The targets live in `mac/Makefile`. They link Apple frameworks (AudioToolbox, CoreAudio, and Foundation; the window also needs Cocoa), so they build on macOS:

```
make
make selftest
make app
```

`make` writes `./play`. `make selftest` runs `./play --selftest` and should report that the late pair lands on the same frame. `make app` writes `Stream.app`; open it with `open Stream.app`. Run one of `./play` or `Stream.app`. Both listen on port 47703.

Leave `mac/play`, `mac/Stream.app/`, and `vst/build/` untracked. `.gitignore` already lists them.

## Do not

- Don't bundle BlackHole, or any other third-party audio driver, in the repo or in releases.
- Don't rewrite the audio path. That is the copy and the UDP send in `src/stream.c`, and the player in `mac/play.m`.
- Never kill or restart the `./stream/mac/play` process. If it is already running, leave it.
- Leave the UDP ports 47701–47703 as they are. This plugin uses 47703. Ports 47701 and 47702 belong to other projects.
- No 64-bit build is needed. Newer MPCs already stream audio over USB-C.
- Don't touch the existing open PR #1 or its branch `cursor/gen2-catalogue-build-c7d4`. Leave that pull request and that branch as they are: https://github.com/stampman3000-jpg/mpc-stream/pull/1
