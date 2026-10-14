# Stream

Stream is a multichannel USB audio effect send for multitracking to a DAW. 1 send per track, into a stereo pair on your computer. It runs smoothly with 8 tracks into a DAW and can handle more. It needs [BlackHole 64ch](https://github.com/ExistentialAudio/BlackHole) and a Mac helper app.

One Stream per track. Pair 1 is BlackHole channels 1–2, pair 2 is 3–4, up to pair 32. Give every track its own pair. Two Streams on the same pair will fight, and the Mac keeps only one of them.

The copy is a little late (about 23 ms, plus whatever Ableton adds). The MPC's own monitoring does not wait.

## What has to be running

- The MPC plugged into the Mac with the USB cable. The plugin sends to `192.168.2.1`, port `47703`, which is the computer at the other end of that cable. Wi-Fi will not do.
- BlackHole 64ch, and Ableton, both at **44100**. If Ableton is at 48000 it switches BlackHole, and the helper has to resample.
- The Mac helper, left open the whole time. Quit it and Ableton goes silent.

## Mac helper

A small window stays open and says what Stream is doing: waiting, how many tracks, the delay, or that the MPC went quiet. The menu bar shows the same line. Leave it open. Quit it and Ableton goes silent.

On the Mac, from `mac/`:

```
make app
open Stream.app
```

The terminal helper is the same player, without the window:

```
make
./play
```

Do not run both. They both listen on port 47703, and the second one will say the port is taken.

`./play --ms 12` asks for a shorter delay. `./play --selftest` checks that a late pair still lands on the same sample as the others.

In Ableton, set the input to **BlackHole 64ch** (not BlackHole 2ch) and arm the channel pair you chose. Do not also set that device as the output, or it feeds back.

## On the MPC

This is an effect, not an instrument. Level changes only the copy. The track on the MPC stays full.

The skin photo is `vst/art/stream.jpg`. The same picture is in `screenshots/stream.jpg`. After you replace `stream.so` on a machine that already has Stream, take the plugin off the track and put it back. Do not restart the MPC app just to load a new file.

## BUILD

`src/stream.c` is the whole plugin engine. The headers it includes are the ordinary C ones (`pthread.h`, `stdatomic.h`, `arpa/inet.h`, `netinet/in.h`, `sys/socket.h`, and the rest of that list). They ship with the compiler. Nothing the build needs is missing from this repo, nothing is fetched during the build, and there is no private header that only exists somewhere else.

The VST2 wrapper and the `VSTPluginMain` entrypoint are not in this repo. They come from [sd88me/mpc-vst-plugins](https://github.com/sd88me/mpc-vst-plugins) `tools/build_port.sh`, which compiles that repo's `wrapper/vst2_wrap.c` in with `src/stream.c`. Do not copy the wrapper into this repo. The script reads `vst/vst.json`.

From a checkout of mpc-vst-plugins, with Docker running, and `$STREAM` set to this repo:

```
tools/build_port.sh "$STREAM/vst/vst.json" armv7
tools/build_port.sh "$STREAM/vst/vst.json" aarch64
```

The second word is the architecture. A `build_port.sh` that ignores that word builds the 32-bit plugin only. The docker commands further down are the engine compile for each architecture, on the images this repo expects.

`vst/vst.json` lists both targets. Shared compile flags there are `-pthread`. Shared link flags are `-pthread -lm`. Both architectures also use `-O2 -Wall -Wextra -Wno-unused-parameter -fPIC -shared -fvisibility=hidden -std=gnu11` and, at link time, `-lpthread -Wl,--no-undefined`. The arch flags below are only for that architecture. They are also `cflags_arm` and `cflags_aarch64` in `vst/vst.json`.

The two commands that follow are the engine compile. `build_port.sh` runs the same compile and adds `wrapper/vst2_wrap.c` (and the generated `params.h` include path) so the `.so` exports `VSTPluginMain`. An `.so` built from `src/stream.c` alone has no entrypoint, so the MPC cannot load it. Do not commit either binary.

### 32-bit armv7 (Gen1 MPC and Force)

Image `arm32v7/gcc:12`. The compiler in that image is `arm-linux-gnueabihf` (the `gcc` command targets that triplet). Arch flags: `-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard`.

```
docker run --rm --platform linux/arm/v7 -v "$PWD":/src -w /src arm32v7/gcc:12 \
  gcc -O2 -Wall -Wextra -Wno-unused-parameter -fPIC -shared -fvisibility=hidden -std=gnu11 \
    -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard -pthread \
    -o /tmp/stream-armv7.so src/stream.c -pthread -lm
```

### Gen2 aarch64

Image `arm64v8/gcc:12`. The compiler in that image is aarch64. Arch flags: `-march=armv8-a -mabi=lp64`.

```
docker run --rm --platform linux/arm64 -v "$PWD":/src -w /src arm64v8/gcc:12 \
  gcc -O2 -Wall -Wextra -Wno-unused-parameter -fPIC -shared -fvisibility=hidden -std=gnu11 \
    -march=armv8-a -mabi=lp64 -pthread \
    -o /tmp/stream-aarch64.so src/stream.c -pthread -lm
```

The same aarch64 line with a cross compiler, without Docker:

```
aarch64-linux-gnu-gcc -O2 -Wall -Wextra -Wno-unused-parameter -fPIC -shared \
  -fvisibility=hidden -std=gnu11 -march=armv8-a -mabi=lp64 -pthread \
  -o /tmp/stream-aarch64.so src/stream.c -pthread -lm
```

`build_port.sh` writes the 32-bit plugin to `vst/build/stream.so` and the Gen2 plugin to `vst/build/aarch64/stream.so`. Keep them apart. The packet on the wire is hand-packed little-endian integers, not a C struct, so the two builds send the same bytes.

## Install

This repo has no installer.

`tools/build_port.sh` writes the plugin folder under `vst/build/` (the skin, plus `stream.so` for 32-bit, or `vst/build/aarch64/stream.so` for Gen2). Put that folder in a Synths directory the MPC already scans. `version.xml` belongs to an existing install: leave it, and do not delete the plugin folder just to update the `.so`. After you replace `stream.so` on a machine that already has Stream, take the plugin off the track and put it back.

Registration is one entry in `MPC.settings`. Which list gets that entry depends on the architecture of the package you are installing:

- A 32-bit armv7 package registers in `pluginList-arm`.
- An aarch64 package registers in `pluginList-arm-64bit`.

Pick the list from the package architecture. A 32-bit `.so` does not go in `pluginList-arm-64bit`, and an aarch64 `.so` does not go in `pluginList-arm`. The catalogue zip, including its installer, is produced later by `tools/release.py` in sd88me/mpc-vst-plugins. This repo does not ship that installer, and it does not tag releases.
