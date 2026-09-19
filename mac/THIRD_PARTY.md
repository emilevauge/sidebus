# Third party code

Lists every piece of code taken from an outside project, with its licence. Each affected
file also carries the original copyright notice at the top.

## Code taken

### DeskPad, MIT licence

`https://github.com/Stengo/DeskPad`, copyright (c) 2022 Stengo.

`Sources/CGVirtualDisplayBridge/include/CGVirtualDisplayBridge.h` takes the declarations of
the private CoreGraphics classes that create a virtual display. The copyright notice and
the MIT licence text sit at the top of that file.

DeskPad also served as the development harness for phases 1 to 6, run as is and unmodified.
Merely running an application imposes nothing; only the code above is concerned.

## Code not taken

### scrcpy, Apache 2.0 licence

`https://github.com/Genymobile/scrcpy`

Sidebus talks to the adb server directly on port 5037 with the `host:track-devices` service
(`AdbWatcher`). That was written from the adb protocol, not copied from scrcpy. Its latency
choices did inspire ours though: no B frames, no queue at render time, `SurfaceView` and
never `TextureView`, `TCP_NODELAY`.

The `adb` binary is not redistributed: Sidebus uses the one on the system.

### Moonlight and Sunshine, GPLv3 licence

No code taken, no source file read. Viral copyleft: pulling in the smallest portion would
force Sidebus to ship under GPLv3.
