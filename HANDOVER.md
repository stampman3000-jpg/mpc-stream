# Handover

For the next agent. Johnny is a hobby builder. Explain in plain language. Do not rewrite the audio path unless a loose end below actually needs it. He already uses Stream on his MPC One; a change he cannot hear is a failure.

The working copy he plays with is still in his MPCBoy folder (`stream/` there). This repo is the public source. Do not delete or retarget the MPCBoy git repo. Do not kill the helper he already has running (`./stream/mac/play` in MPCBoy, UDP 47703). Cable on UDP 47701 and Pair on 47702 are other projects. Leave them alone.

## What this is

- `src/stream.c` — MPC effect. Copies the track to the MPC output. A side thread sends UDP. The audio thread never touches the socket.
- `mac/play.m` — Mac helper. Listens on UDP 47703 and plays into the device named exactly `BlackHole 64ch`.
- `vst/` — plugin description, knobs (Level, Pair), and the photo on the page.

Packet, little endian: `'T'`, pair byte 1–32, uint32 position in frames, uint16 frame count, then interleaved int16 stereo. Pair 1 is channels 1–2. Older builds send `'S'` with a private block count instead of the shared position. The helper still accepts those, but they are not sample-locked. After a new `stream.so` is installed he must remove Stream and insert it again or the MPC keeps the old copy in memory.

Every Stream on the device shares one clock and one sender thread, so blocks from the same audio cycle share one position. The helper plays them with one play head. A second Stream aimed at a pair that is already in use is dropped, on purpose: taking both made that pair run fast and the helper skipped.

## Build and check

Mac helper, from `mac/`:

```
make && make selftest
```

Needs CoreAudio as well as AudioToolbox. The selftest must keep saying the late pair lands on the same frame.

MPC plugin, from a checkout of sd88me/mpc-vst-plugins (Docker running):

```
build_port.sh /path/to/mpc-stream/vst/vst.json
```

Do not run the host test (`test_port.sh`) and treat a crash as a Stream bug. That test calls an effect with no input buffer. `clang -DSTREAM_TEST` on `src/stream.c` is the real plugin check. The effect warning about `render_frames` being unused means the build is an effect, which is correct.

Install path on the device is `/media/EOS_DIGITAL/Synths`, never `/sdcard/Synths`. Copy the new `stream.so` to a temp name, then rename it into place. Do not delete the plugin folder (keep `version.xml`). Do not restart the MPC software unless a brand-new plugin has to be registered. Stream is already registered on his machine.

## Loose ends, in this order

1. **License.** MIT is in the root `LICENSE`, copyright Johnny 2026. Leave that file as it is.

2. **Mac status window.** `mac/app.m` is the double-click helper (`make app`, then `open Stream.app`). The menu bar and the window say waiting, how many tracks, the delay, or that the MPC went quiet / BlackHole is missing or at the wrong rate. It runs the same `play.m` player. Do not run it at the same time as `./play` (both want UDP 47703). Do not replace BlackHole. Do not bundle BlackHole. Do not commit `Stream.app`.

3. **Human setup, on one page.** USB cable, not Wi-Fi. BlackHole 64ch and Ableton both at 44100. Helper left open. One Stream per track, each with its own Pair. Input in Ableton is BlackHole 64ch only, not also the output. Level does not change the MPC.

4. **A GitHub release zip**, only after the license exists. From mpc-vst-plugins: `tools/release.py` with the built `.so`, the skin folder, `pluginlist-entry.xml`, version, `--repo`, and `--license`. The zip asset the catalog expects is named `*-mpc-armv7.zip`. Do not commit `vst/build/` or the `play` binary.

5. **Catalog.** Do not open a pull request on `sd88me/mpc-vst-plugins` unless Johnny says to. When he does, the entry is one `catalog/plugins/stream.json`: kind `effect`, style `utility`, repo this one, the license you added. No checksums in that file. His MPC One at 44100 is the machine it was tested on.

## Leave alone

- The shared plugin wrapper. Do not patch it for Stream.
- The USB gadget. Do not try to make the MPC a USB sound card.
- Windows. BlackHole is Mac-only. A Windows helper is a different project.
- Time-stretch, Chop, Steps, Cable, Pair. Not this repo.
