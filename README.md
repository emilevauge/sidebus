# Sidebus

Sidebus turns an Android tablet into a second display for a Mac.

The Mac declares a virtual display, captures its framebuffer, encodes it as H.264 or HEVC
and sends it to the tablet, which decodes and shows it. Touches on the tablet travel back
and are injected as mouse events. Two transports: USB through an adb tunnel, and Wi-Fi with
mDNS discovery.

`protocol/PROTOCOL.md` describes the wire format. It is the shared source of truth for both
sides.

Phases 0 to 9 are done. Sidebus creates a virtual display matching the tablet's panel,
captures it, encodes it with the hardware H.264 or HEVC encoder, ships it over TLS 1.3 on
USB or Wi-Fi, and shows it on the tablet, whose touches come back as mouse events. Bitrate
and frame rate follow what the tablet reports.

## macOS

Requires macOS 14 or later, and Xcode or the command line tools with Swift 6.

```sh
cd mac
swift build            # compile
swift test             # unit tests
swift run SidebusApp   # run the app directly, without a bundle
./Scripts/bundle.sh    # build and sign mac/build/Sidebus.app
open build/Sidebus.app # run the bundle
```

The app has no Dock icon, it lives in the menu bar.

The script signs with the first codesigning identity in the keychain, and falls back to ad
hoc signing when it finds none. The difference matters to TCC, which remembers permissions
(Screen Recording, Accessibility, Local Network) by signing rule:

- ad hoc: `identifier "app.sidebus" and cdhash H"..."`, which changes on every rebuild, so
  the permission is lost every time
- identity: `identifier "app.sidebus" and certificate leaf = H"..."`, stable

Force a choice with `SIDEBUS_CODESIGN_IDENTITY`. Developer ID and notarization come in
phase 9.

If a permission stays stuck after a signature change: `tccutil reset ScreenCapture
app.sidebus`, then relaunch.

### Development harness

Up to phase 7, the display to capture came from
[DeskPad](https://github.com/Stengo/DeskPad), run alongside and left unmodified:

```sh
brew install --cask deskpad
open -a DeskPad
```

Its virtual display then shows up in the picker under Settings > Video. Do not move the
DeskPad window onto the display it mirrors, that produces an infinite mirror.

### Capture (phase 2)

Under Settings > Video: pick a display, then "Record the stream to a file". macOS asks for
Screen Recording permission on the first attempt, and it only takes effect after the app
restarts. The stream lands in `/tmp/sidebus.h264`, playable with:

```sh
ffplay /tmp/sidebus.h264
```

Encoder settings: hardware H.264, realtime, no B frames, low latency rate control,
15 Mbit/s, keyframe every 300 frames.

Development hooks, to measure without going through the menu:

```sh
open --env SIDEBUS_AUTOCAPTURE=DeskPad \
     --env SIDEBUS_CAPTURE_SCALE=0.5 \
     --env SIDEBUS_FPS=30 \
     mac/build/Sidebus.app
```

`SIDEBUS_AUTOCAPTURE` starts capturing at launch, on the first display whose name contains
the given value, and writes a trace to `/tmp/sidebus-debug.log`.

Benchmark of the encoding path alone:

```sh
cd mac && SIDEBUS_BENCH=1 swift test -c release --filter EncoderBenchmark
```

## Android

Requires the Android SDK with platform 36, and JDK 17 or later.
`android/local.properties` must point at the SDK (`sdk.dir=...`), and is not versioned.

```sh
cd android
./gradlew assembleDebug           # build the APK
./gradlew installDebug            # install on the attached device
adb shell am start -n app.sidebus/.MainActivity
```

minSdk 30, landscape only. The app listens on port 27183: the tablet is the server, on USB
as on Wi-Fi.

## USB transport

Nothing to do, plugging the cable is enough. The Mac follows the adb server's
`host:track-devices` stream, sets up `adb forward tcp:27183 tcp:27183`, connects and sends
HELLO. If the tablet does not answer with DEVICE_INFO, the app is not in the foreground:
the Mac starts it with `adb shell am start` and tries again.

State and latency show up in the menu. To follow them in detail:

```sh
log stream --predicate 'subsystem == "app.sidebus"' --level debug --style compact
```

Development hooks: `SIDEBUS_AUTO_PAIR=1` accepts pairing on the Mac without a dialog,
`SIDEBUS_DISABLE_USB=1` forces the Wi-Fi path, `SIDEBUS_MANUAL_PEER=host:port` prefills an
address.

Without a tablet, an emulator exercises the whole path. It shows up as an adb device:

```sh
~/Library/Android/sdk/emulator/emulator -avd <name> &
cd android && ./gradlew installDebug
```

## Virtual display

On connection, Sidebus creates a virtual display at the resolution and density the tablet
announces, and destroys it on disconnection. A ghost display that outlives the session
disturbs the window layout, and that is the main complaint aimed at tools of this kind.

The classes involved are private and can vanish with any macOS release. Failure is detected
explicitly: Sidebus then mirrors an existing display and says so in the menu, rather than
crashing or showing an unexplained black screen. Picking a display in the settings forces
that mode.

The physical size declared in millimetres is computed to land on the wanted density, and
the mode is declared in points with `hiDPI` set to 1. Getting that wrong yields either a
blurry picture or a minuscule interface.

## Adaptation

The tablet sends its counters every two seconds. The Mac derives the bitrate from them: a
sharp cut as soon as 15 % of frames are dropped, a 10 % climb back after six quiet seconds.
Profiles differ per transport, generous on USB, careful on Wi-Fi. When the floor bitrate is
still not enough, the limit is the decoder or the heat, not the network: the frame rate
then drops to 30 fps.

When the tablet loses the thread it asks for a keyframe and **stops feeding its decoder**
meanwhile. Handing it intermediate frames without their reference produces green and
magenta blocks that linger. The Mac answers by re-encoding the last picture right away,
without which a still screen would leave the tablet corrupted until the next movement. The
maximum keyframe interval is expressed in seconds rather than frames: 300 frames at 7 fps
is 43 seconds of broken picture.

**HEVC wins as soon as the tablet announces it.** Measured on a Xiaomi 15 with the
Qualcomm hardware decoder: 0.5 Mbit/s against 1.4 in H.264 on the same content, at 57 and
60 fps, 6 to 7 ms of decoding, not a frame lost.

Beware software decoders. The Android emulator's returns broken chroma in HEVC, green and
magenta blocks, where H.264 sails through on the same material. `SIDEBUS_CODEC=h264` forces
the fallback.

## Where the work happens

Nothing heavy touches the CPU. Capture, scaling and format conversion happen in the system
graphics path, encoding on the dedicated media engine, and on the tablet side the hardware
decoder writes straight into the `Surface`, composited without a copy. Do not insert a
hand-written GPU step into that path: rendering into a texture instead of a `SurfaceView`
would add a frame of latency.

What remains on the CPU only touches bytes that are already compressed:

- the conversion to Annex B happens **in place**. The AVCC length prefix and the start code
  are both four bytes, so rewriting the four length bytes is enough, with no allocation.
- the receive buffer on the Android side works by moving an index, and the socket is read
  straight into it. The naive version copied everything pending on each packet: a frame
  arriving in several pieces paid for as many full copies. Measured on a Xiaomi 15 under
  load: 28.5 % CPU before, 25.0 % after.
- a frame with no dirty rectangle is not encoded at all. Still screen: 0.4 % CPU on the
  Mac, 0.3 % on the phone.

## Rendering on the tablet

`MediaCodec` in async mode, configured directly on the `Surface`, with `KEY_LOW_LATENCY`
and `KEY_PRIORITY` at 0. Rendering is immediate: `releaseOutputBuffer` as soon as the
decoder produces, no queue. When no input buffer is free, the frame is dropped rather than
queued, with one exception: a keyframe gets a short waiting window, because it is the only
recovery point and the next one can be five seconds away.

The counters overlay is **hidden by default**: those numbers are there to diagnose, not to
sit across the shared screen. To show it:

```sh
adb shell settings put global sidebus_overlay 1   # 0 hides it again
```

The setting is read again on every return to the foreground, without restarting the app.
The view keeps counting even while invisible: it is what feeds the STATS messages.

It refreshes at 4 Hz. Updating it on every frame would cost more than the rest of the
pipeline, as measured on the Mac side in phase 2.

Four traps met along the way, not to be reintroduced:

- the decoder must be created **synchronously** when VIDEO_CONFIG arrives. Created later it
  misses the keyframe that immediately follows, and stays stuck on unusable intermediate
  frames.
- setting the `SurfaceView` to `INVISIBLE` destroys its surface, which is never recreated
  afterwards. To hide the picture, lay a black view over it.
- do not clear the surface with `lockCanvas`: that connects it to the CPU producer and
  `MediaCodec` can no longer attach, so `configure` fails with an opaque
  `IllegalArgumentException` (`surfaceConnectWithListener ... Invalid argument`).
- a decoder that refuses to configure must not take the connection down with it: the
  exception used to travel up to the read loop and close the link.

## Wi-Fi transport and pairing

The tablet advertises itself over mDNS as `_sidebus._tcp` whenever it is in the foreground,
along with its resolution, its codecs and its certificate fingerprint. The Mac finds it
with `NWBrowser` and connects straight to the published endpoint, without resolving the
address by hand.

On the first connection both sides show the same six digit code, derived from the
certificate fingerprint, and **both must confirm**. The Mac asks first, during the TLS
handshake since that is where it discovers the fingerprint; it then sends PAIR_REQUEST and
the tablet asks in turn. Nothing is stored before both agree, so a refusal on one side
leaves no trace on the other. If the fingerprint changes for a known device, the connection
is refused.

Neither side lets a timeout run while a dialog waits for a human. On the Mac the eight
second connection deadline pauses while a question is open; on the tablet the handshake has
its own deadline, far longer than the ordinary read timeout. Without that, pairing only
worked when both people answered within a few seconds.

Four things worth knowing, all met during implementation:

- the Keystore key must allow the `NONE` digest. In TLS 1.3 Conscrypt hashes the message
  itself then asks for a raw ECDSA signature; without that digest the Keystore refuses
  (`INCOMPATIBLE_DIGEST`) and the handshake dies without an alert, which looks like a
  network failure.
- a tablet that is advertised but unreachable, the case of a network isolating its clients,
  returns nothing at all: no acceptance, no refusal. The connection is therefore bounded to
  eight seconds and the error message explains the likely cause.
- `NWConnection.connect()` must be cancellable, otherwise the deadline above is useless: a
  task group waits for its children on the way out, and a task blocked in a continuation
  ignores cancellation.
- the pairing code stays on the tablet's waiting screen on purpose. The Mac asks first, so
  without that code in sight you would accept on the Mac blind. The check the tablet's
  dialog performs does not replace the comparison: it works on a code that travelled
  through the link, so it can be forged by the very party you are guarding against.

On networks where multicast does not pass, the settings offer "Connect by IP address", and
the tablet shows its own address.

## Devices and sharing

The menu lists devices under "Devices", with an icon that carries the state: a link to
pair, a screen to share, a stop square while streaming, an hourglass while the connection
comes up, a crossed out tablet when offline. Clicking a row does the one thing it offers.

Nothing streams without a gesture. One exception, and it is deliberate: a device that was
being shared to picks up again when it reappears, otherwise plugging a cable back in would
mean reopening the menu every time. Stopping the share drops that intent, and cutting the
capture from the macOS Control Center counts as a stop.

Sharing to several tablets at once is possible by construction: each device has its own
session, virtual display, encoder and bitrate controller, with no shared state to arbitrate.
The CPU cost adds up.

Settings > Devices lists the paired ones, offline included, and lets you forget one or all
of them.

## Touch

Touches on the video view leave as INPUT_EVENT, in coordinates normalised against the view
rather than the tablet's panel: the stream keeps its aspect ratio and may be letterboxed,
so the picture is the reference. The Mac maps them onto the `CGDisplayBounds` of the
captured display and posts the event with `CGEventPost`.

A move between a press and a release becomes a drag, not a plain cursor move, otherwise
nothing moves and nothing gets selected.

**Accessibility permission is mandatory.** Without it `CGEventPost` is ignored with no
error: touches do reach the Mac, they simply produce nothing. System Settings > Privacy and
Security > Accessibility, enable Sidebus, then **restart the app**: the permission only
takes effect on the next launch. The device row reports the missing permission while
streaming.

## Distribution

```sh
cd mac
SIDEBUS_DEVELOPER_ID="Developer ID Application: … (TEAMID)" \
SIDEBUS_NOTARY_PROFILE=sidebus \
./Scripts/release.sh
```

The script builds, signs with the hardened runtime, makes a disk image, notarizes it and
staples the ticket. The App Store is out of reach: `CGVirtualDisplay` is a private API.

On the Android side, `./gradlew assembleRelease` produces a signed APK when `sidebus.keystore`
and its passwords are supplied as Gradle properties or environment variables, and an
unsigned APK otherwise. No secret lives in the repository.

Settings > Permissions shows the state of the three TCC permissions, opens the right System
Settings pane, and can restart the app, since they only take effect on the next launch.

## Releasing

One version number for both applications, in the `VERSION` file at the root.
`mac/Scripts/bundle.sh` stamps it into the bundle's `CFBundleShortVersionString`, and the
Gradle build reads the same file for `versionName`.

```sh
Scripts/publish.sh patch            # 0.1.0 -> 0.1.1
Scripts/publish.sh minor            # 0.1.0 -> 0.2.0
Scripts/publish.sh 1.4.2            # an explicit version
Scripts/publish.sh patch --dry-run  # builds and packages, publishes nothing
```

The script refuses a dirty tree or a branch other than `main`, runs both test suites,
builds the bundle and the APK, packages `Sidebus.dmg`, commits the bump, tags `vX.Y.Z` and
creates the GitHub release with both artifacts attached.

The Mac application asks the GitHub releases API once a day, and again when the Mac wakes
up, since a `Timer` does not tick while the machine sleeps. A newer version shows up as a
row in the menu; Settings > About has the current version and a button that checks on
demand. Installing downloads the disk image and hands over to a detached helper script: the
application cannot rewrite its own bundle while running, so the helper waits for it to
exit, swaps the bundle, and relaunches. The old bundle is moved aside rather than deleted,
and restored if the copy fails, so the user is never left without an application.

The disk image is signed with the local identity, not a Developer ID. The self update path
works because the helper strips the quarantine flag. A disk image downloaded by hand onto
another Mac would be refused by Gatekeeper, and needs either `xattr -dr
com.apple.quarantine` or a properly notarized build through `mac/Scripts/release.sh`.

## Protocol

`protocol/PROTOCOL.md` describes the wire format, `protocol/testvectors/` holds its binary
vectors. The tests on both sides decode them, check the fields, re-encode and compare byte
for byte. Any change to the format goes into `PROTOCOL.md` first, then
`python3 protocol/testvectors/generate.py`, then both sides in the same commit.
