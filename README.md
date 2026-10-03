# Stream

An effect for the MPC. Put it on a track and that track still plays through the MPC. A copy is sent over the USB cable to a Mac, which plays it into [BlackHole 64ch](https://github.com/ExistentialAudio/BlackHole) so Ableton (or anything else) can record it.

One Stream per track. Pair 1 is BlackHole channels 1–2, pair 2 is 3–4, up to pair 32. Give every track its own pair. Two Streams on the same pair will fight, and the Mac keeps only one of them.

The copy is a little late (about 23 ms, plus whatever Ableton adds). The MPC's own monitoring does not wait.

## What has to be running

- The MPC plugged into the Mac with the USB cable. The plugin sends to `192.168.2.1`, port `47703`, which is the computer at the other end of that cable. Wi-Fi will not do.
- BlackHole 64ch, and Ableton, both at **44100**. If Ableton is at 48000 it switches BlackHole, and the helper has to resample.
- The Mac helper, left open the whole time. Quit it and Ableton goes silent.

## Mac helper

From `mac/`:

```
make
./play
```

`./play --ms 12` asks for a shorter delay. `./play --selftest` checks that a late pair still lands on the same sample as the others.

In Ableton, set the input to **BlackHole 64ch** (not BlackHole 2ch) and arm the channel pair you chose. Do not also set that device as the output, or it feeds back.

## On the MPC

This is an effect, not an instrument. Level changes only the copy. The track on the MPC stays full.

Build with [mpc-vst-plugins](https://github.com/sd88me/mpc-vst-plugins):

```
build_port.sh vst/vst.json
```

That needs Docker. The skin photo is `vst/art/stream.jpg`. After you replace `stream.so` on a machine that already has Stream, take the plugin off the track and put it back. Do not restart the MPC app just to load a new file.

## Not done yet

See `HANDOVER.md`. This is not on the [MPC plugin catalog](https://sd88me.github.io/mpc-vst-plugins/) yet.
