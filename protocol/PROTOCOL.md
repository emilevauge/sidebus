# Sidebus protocol

Protocol version: **1**

This file is the source of truth for the wire format. Every change lands here first, then
propagates to the Mac side and the Android side in the same commit, with the vectors in
`protocol/testvectors/` regenerated.

---

## 1. Transport layer

- TCP, a single bidirectional socket, port **27183**.
- The server is the **Android tablet**. The Mac is always the client, on USB as on Wi-Fi.
- `TCP_NODELAY` on both sides.
- TLS 1.3 from phase 6 onwards (self signed certificate on the Android side, pinning on the
  Mac side). In phase 3 the link was in the clear, over the adb tunnel only.
- Byte order: **little endian** for every integer and float in the protocol. Floats are
  IEEE 754 binary32.
- Messages go out on the socket in order, with no multiplexing and no interleaving: one
  message is written in full before the next.

## 2. Message header

8 bytes, in front of every message.

| Offset | Size | Field  | Description                     |
| ------ | ---- | ------ | ------------------------------- |
| 0      | 1    | magic  | always `0x5B`                   |
| 1      | 1    | type   | see the type table              |
| 2      | 2    | flags  | depends on the type, `0` unused |
| 4      | 4    | length | payload size, in bytes          |

Reading rules:

- A `magic` other than `0x5B` is fatal: close the socket, do not try to resynchronise.
- An unknown `type` is skipped cleanly: read and discard `length` bytes, carry on. That is
  what will let messages be added without breaking earlier versions.
- `length` is bounded to **8,388,608 bytes (8 MiB)**. Beyond that, fatal. The bound guards
  against an allocation dictated by the peer and leaves ample room for an intra frame at
  15 Mbit/s.
- A message with no payload has `length = 0` and no bytes after it.

## 3. Primitive payload types

| Notation | Encoding                                                              |
| -------- | --------------------------------------------------------------------- |
| `u8`     | 1 unsigned byte                                                       |
| `u16`    | 2 unsigned bytes, little endian                                       |
| `u32`    | 4 unsigned bytes, little endian                                       |
| `u64`    | 8 unsigned bytes, little endian                                       |
| `f32`    | 4 bytes, IEEE 754 binary32, little endian                             |
| `uuid`   | 16 raw bytes, big endian (RFC 4122 order, the one of the text form)   |
| `string` | `u16` length in bytes, then that many UTF-8 bytes, no terminator      |

A `string` is bounded to 255 useful bytes. Both sides truncate on a character boundary when
sending, and reject the message on receipt if the length goes over.

Fields are serialised in table order, with no alignment and no padding.

## 4. Message types

| Value  | Name           | Direction          | Payload                                 |
| ------ | -------------- | ------------------ | --------------------------------------- |
| `0x01` | HELLO          | Mac to Android     | see 4.1                                 |
| `0x02` | DEVICE_INFO    | Android to Mac     | see 4.2                                 |
| `0x03` | DISPLAY_CONFIG | Mac to Android     | see 4.3                                 |
| `0x04` | VIDEO_CONFIG   | Mac to Android     | see 4.4                                 |
| `0x05` | VIDEO_FRAME    | Mac to Android     | see 4.5                                 |
| `0x06` | INPUT_EVENT    | Android to Mac     | see 4.6                                 |
| `0x07` | PING           | bidirectional      | `u64` timestamp in µs                   |
| `0x08` | PONG           | bidirectional      | `u64` echo of the PING timestamp        |
| `0x09` | KEYFRAME_REQ   | Android to Mac     | empty                                   |
| `0x0A` | STATS          | Android to Mac     | see 4.10                                |
| `0x0B` | BYE            | bidirectional      | `u8` reason code                        |
| `0x0C` | PAIR_REQUEST   | Mac to Android     | `u32` pairing code, see 4.12            |
| `0x0D` | PAIR_RESULT    | Android to Mac     | `u8` 0 refused, 1 accepted, see 4.13    |
| `0x0E` | CALL_ACCESS    | Mac to Android     | see 10.2                                |
| `0x0F` | CALL_GRANT     | Android to Mac     | see 10.2                                |
| `0x10` | CALL_STATUS    | Android to Mac     | see 10.3                                |
| `0x11` | CALL_START     | Mac to Android     | empty, see 10.4                         |
| `0x12` | CALL_STOP      | bidirectional      | empty, see 10.4                         |
| `0x13` | CALL_AUDIO     | bidirectional      | see 10.4                                |
| `0x14` | CONTACTS_REQ   | Mac to Android     | empty, see 10.5                         |
| `0x15` | CONTACTS       | Android to Mac     | see 10.5                                |
| `0x16` | CALLER_ID      | Android to Mac     | see 10.6                                |
| `0x17` | PHOTOS_REQ     | Mac to Android     | see 10.7                                |
| `0x18` | PHOTO          | Android to Mac     | see 10.7                                |

Receiving a message in the wrong direction (a HELLO on the Mac side, say) is fatal: close
the socket.

### 4.1 HELLO (`0x01`)

| Field   | Type     | Description                              |
| ------- | -------- | ---------------------------------------- |
| version | `u16`    | protocol version the Mac speaks          |
| name    | `string` | name of the Mac, shown on the tablet     |
| uuid    | `uuid`   | persistent identifier of the Mac         |

The **Mac** sends HELLO, since it is the one opening the connection.

If `version` is higher than the one the tablet knows, it answers DEVICE_INFO anyway: the
Mac, which knows both versions, decides whether to carry on or send BYE with code 2.

### 4.2 DEVICE_INFO (`0x02`)

| Field   | Type     | Description                                        |
| ------- | -------- | -------------------------------------------------- |
| width   | `u16`    | panel width, in pixels                             |
| height  | `u16`    | panel height, in pixels                            |
| density | `u16`    | density, in dpi (`DisplayMetrics.densityDpi`)      |
| codecs  | `u8`     | bitmask of decodable codecs, see 5.1               |
| name    | `string` | device name (`Settings.Global.DEVICE_NAME`)        |
| uuid    | `uuid`   | persistent identifier of the device                |

`width` and `height` describe the panel in landscape orientation, whatever the current
orientation is.

`uuid` is the same identifier as the `id` key of the mDNS advertisement, generated on first
launch and kept afterwards. It is what makes arbitration between transports possible:
without it, a tablet seen on both USB and Wi-Fi looks like two devices, since the USB side
is known by its adb serial and the Wi-Fi side by this identifier.

### 4.3 DISPLAY_CONFIG (`0x03`)

| Field  | Type  | Description                            |
| ------ | ----- | -------------------------------------- |
| width  | `u16` | video stream width, in pixels          |
| height | `u16` | video stream height, in pixels         |
| fps    | `u8`  | target frames per second               |
| codec  | `u8`  | chosen codec, single value, see 5.1    |

The Mac chooses. The tablet applies it, or sends BYE code 2 if it cannot.

### 4.4 VIDEO_CONFIG (`0x04`)

Payload: the codec parameters in **Annex B**, that is NAL units prefixed with
`00 00 00 01`, concatenated in order.

- H.264: SPS then PPS.
- HEVC: VPS then SPS then PPS.

On the Android side this payload goes straight into `csd-0`.

A VIDEO_CONFIG always precedes the first VIDEO_FRAME, and is sent again on every encoder
configuration change (resolution, codec).

### 4.5 VIDEO_FRAME (`0x05`)

| Field     | Type | Description                                      |
| --------- | ---- | ------------------------------------------------ |
| timestamp | `u64`| capture timestamp, in µs                         |
| data      | rest | NAL units in Annex B, to the end of the payload  |

Flags:

| Bit | Meaning                  |
| --- | ------------------------ |
| 0   | the frame is a keyframe  |

The other bits are reserved and hold `0`.

The timestamp comes from the Mac's monotonic clock (`mach_absolute_time` converted to µs).
It does not pace rendering, which is immediate, but measures latency and timestamps the
statistics.

### 4.6 INPUT_EVENT (`0x06`)

| Field     | Type  | Description                        |
| --------- | ----- | ---------------------------------- |
| kind      | `u8`  | see 5.2                            |
| x         | `f32` | normalised abscissa, 0.0 to 1.0    |
| y         | `f32` | normalised ordinate, 0.0 to 1.0    |
| button    | `u8`  | see 5.3                            |
| timestamp | `u64` | event timestamp, in µs             |

Coordinates are normalised against the tablet's display surface, whatever resolution was
negotiated. The origin is **top left**. The Mac maps them onto
`CGDisplayBounds(displayID)`.

A value outside `[0.0, 1.0]` is clamped on receipt, without error.

### 4.10 STATS (`0x0A`)

| Field    | Type  | Description                            |
| -------- | ----- | -------------------------------------- |
| received | `u32` | frames received during the window      |
| dropped  | `u32` | frames dropped during the window       |
| window   | `u16` | measurement window duration, in ms     |

The counters cover the window that just elapsed, not the whole session.

### 4.11 BYE (`0x0B`)

| Field  | Type | Description |
| ------ | ---- | ----------- |
| reason | `u8` | see 5.4     |

The sender closes the socket after sending, without waiting for an answer.

### 4.12 PAIR_REQUEST (`0x0C`)

| Field | Type  | Description                                         |
| ----- | ----- | --------------------------------------------------- |
| code  | `u32` | six digit code derived from the fingerprint, see 7  |

The Mac sends it after DEVICE_INFO, and only when it did not already know the fingerprint
of the certificate presented: that is, when it has just asked its own user for
confirmation. The tablet then shows the code and asks in turn.

The Mac only records the fingerprint after an accepted PAIR_RESULT. A pairing refused on
one side therefore leaves nothing behind on the other.

The tablet compares the code it received with the one it derives from its own certificate.
They must match: a difference means the certificate the Mac sees is not the tablet's, and
the tablet says so in its confirmation prompt.

### 4.13 PAIR_RESULT (`0x0D`)

| Field    | Type | Description             |
| -------- | ---- | ----------------------- |
| accepted | `u8` | 0 refused, 1 accepted   |

Any value other than 1 counts as a refusal.

The Mac waits at most 120 s for this message after PAIR_REQUEST. Past that, it treats the
silence as a refusal and sends BYE with code 0.

## 5. Enumerations

### 5.1 Codecs

| Bit | Bitmask value | Single value (`codec`) | Codec |
| --- | ------------- | ---------------------- | ----- |
| 0   | `0x01`        | `0x01`                 | H.264 |
| 1   | `0x02`        | `0x02`                 | HEVC  |

In DEVICE_INFO, `codecs` is a bitmask and several bits may be set. In DISPLAY_CONFIG,
`codec` names a single codec, and the value is that of the matching bit.

### 5.2 Input event kinds

| Value  | Name | Android origin  |
| ------ | ---- | --------------- |
| `0x00` | DOWN | `ACTION_DOWN`   |
| `0x01` | MOVE | `ACTION_MOVE`   |
| `0x02` | UP   | `ACTION_UP`     |

`ACTION_CANCEL` is sent as an UP.

### 5.3 Buttons

| Value  | Button |
| ------ | ------ |
| `0x00` | left   |
| `0x01` | right  |
| `0x02` | middle |

In v1 the tablet only sends `0x00`.

### 5.4 BYE reason codes

| Value  | Meaning           |
| ------ | ----------------- |
| `0x00` | normal close      |
| `0x01` | transport switch  |
| `0x02` | error             |

## 6. Connection sequence

1. The Mac opens the socket (Wi-Fi directly, or `127.0.0.1:27183` through the adb tunnel),
   then the TLS handshake.
2. Mac sends HELLO. Android answers DEVICE_INFO.
3. If the device was not paired, the Mac sends PAIR_REQUEST and waits for PAIR_RESULT. A
   refusal ends the connection with a BYE of code 0.
4. Mac picks the resolution and the codec, creates the virtual display, sends
   DISPLAY_CONFIG.
5. Mac sends VIDEO_CONFIG, then a stream of VIDEO_FRAME starting with a keyframe.
6. PING every second in both directions. A peer with no PONG and no traffic for 5 s counts
   as disconnected: close the socket.
7. STATS every 2 s, from the tablet. Feeds the bitrate adaptation.

INPUT_EVENT and KEYFRAME_REQ can be sent at any time once DISPLAY_CONFIG has passed.

Neither side lets a timeout run while a dialog waits for a human. The 5 s silence rule and
the ordinary read timeouts apply once the handshake is through, not during it: pairing asks
a question of both users, and they need longer than a few seconds to answer.

## 7. Security and pairing

TLS 1.3 only, in both transport modes. The tablet is the server and presents a long lived
self signed certificate, generated on first launch and kept in the Android Keystore. The
Mac is the client and presents no certificate.

Verification on the Mac side does not validate a chain of trust, there is none: it compares
the SHA-256 fingerprint of the presented certificate with the one recorded for that device.
This is SSH's `known_hosts` model.

### Pairing code

On the first connection to an unknown device, both sides derive the same six digit code
from the certificate fingerprint:

```
fingerprint = SHA-256(certificate in DER form)
code        = (fingerprint[0] << 24 | fingerprint[1] << 16 | fingerprint[2] << 8 | fingerprint[3]) mod 1,000,000
```

The result is shown on six digits, leading zeros included. Comparing the two displayed
codes stays visual and out of band: that is what protects against a peer impersonating the
tablet, and no protocol exchange can take its place.

Pairing asks for confirmation on **both sides**, in this order:

1. The Mac shows the code as soon as the TLS handshake reaches it, since that is where it
   discovers the fingerprint. A refusal closes the socket and records nothing.
2. Once DEVICE_INFO has arrived, the Mac sends PAIR_REQUEST. The tablet shows the code in
   turn and answers PAIR_RESULT.

The tablet keeps its code on the waiting screen throughout, and that is what makes step 1
meaningful: the Mac asks first, so without the tablet's own code in sight the user would
accept blind.

PAIR_REQUEST carries no secret: the code follows from the certificate, which anyone
listening to the handshake sees go by. It exists to trigger the confirmation on the tablet
and to let the tablet notice that the Mac is not seeing the certificate it presented.

The Mac records the fingerprint in the keychain, tied to the device's `uuid`, once both
confirmations are in. If the fingerprint of a known device changes, the connection is
refused and the user warned, with no one click way to override.

## 8. TXT records of the mDNS advertisement

Service type: `_sidebus._tcp`, port 27183. TXT values in ASCII.

| Key  | Content                                                       |
| ---- | ------------------------------------------------------------- |
| `v`  | protocol version, in decimal                                  |
| `id` | persistent device UUID, RFC 4122 text form                    |
| `w`  | width in pixels, in decimal                                   |
| `h`  | height in pixels, in decimal                                  |
| `d`  | density in dpi, in decimal                                    |
| `c`  | codec bitmask, in decimal                                     |
| `fp` | first 8 bytes of the certificate SHA-256, lowercase hex       |

## 9. Test vectors

`protocol/testvectors/` holds one file per case, encoded once and for all. The unit tests on
both sides decode each vector, check the fields, re-encode and compare byte for byte with
the original file.

The vectors arrived in phase 3, alongside `MessageCodec`.

## 10. Phone calls

A phone running Sidebus can carry its calls to the Mac. Bluetooth (HFP, between the Mac and
the phone directly) places, answers and ends them; this channel carries their sound and the
phone's contacts.

### 10.1 Transport

The phone runs a second server for calls, apart from the one of sections 1 and 6: TCP port
**27185**, the same TLS identity, advertised over mDNS as `_sidebus-call._tcp` with the `v`,
`id` and `fp` keys of section 8. On USB the Mac reaches it through `adb forward`, as the
display server. It runs in the background, screen off, so long as the phone is on.

The sequence opens as in section 6: HELLO, DEVICE_INFO, then PING and PONG every second.
The Mac connects only to a device it already paired with (section 7); this server never
pairs. DISPLAY_CONFIG and the video messages are not used here.

A live connection keeps the phone's Wi-Fi awake, so the Mac only holds one when needed:
from the moment Bluetooth announces a call, placed or ringing, until it ends, and every
15 minutes for a short check, which ends once CALL_STATUS, CONTACTS and the photos asked
for have come.

Call audio is not reachable from an app: the phone side holds a helper process started over
adb, which lives until the phone restarts. The app relays between it and this channel.

### 10.2 CALL_ACCESS (`0x0E`) and CALL_GRANT (`0x0F`)

TLS authenticates the phone to the Mac, not the Mac to the phone. Before anything else on
this channel, the Mac proves the phone's user allowed it:

CALL_ACCESS, Mac to Android:

| Field | Type | Description                                                     |
| ----- | ---- | --------------------------------------------------------------- |
| token | rest | the token from an earlier CALL_GRANT, or empty the first time   |

CALL_GRANT, Android to Mac:

| Field  | Type | Description                                                    |
| ------ | ---- | -------------------------------------------------------------- |
| status | `u8` | 0 refused, 1 granted, 2 waiting for the phone's user           |
| token  | rest | 32 random bytes when granted, empty otherwise                  |

A token the phone knows is granted at once. Otherwise the phone asks its user, through a
notification, whether this Mac (HELLO's name) may carry its calls, answers 2 right away,
then 1 or 0 once the user has answered. The token goes out inside TLS to a pinned
certificate, so only the phone and that Mac know it. The Mac keeps it in the keychain, tied
to the device's uuid.

Until a CALL_GRANT with status 1, the phone ignores every message below.

### 10.3 CALL_STATUS (`0x10`)

| Field | Type | Description                                                  |
| ----- | ---- | ------------------------------------------------------------ |
| flags | `u8` | bit 0: the audio helper runs, bit 1: contacts are readable, bit 2: caller names are readable, bit 3: call audio can go in 48 kHz |

Sent after CALL_GRANT, then on every change.

### 10.4 CALL_START (`0x11`), CALL_STOP (`0x12`) and CALL_AUDIO (`0x13`)

The Mac sends CALL_START once a call is placed or answered. Its payload is empty, or one
`u8`: 1 when the Mac wants the audio in 48 kHz, which it may ask only when bit 3 of
CALL_STATUS is set. 16 kHz cannot carry what lies above 8 kHz, which calls coded in EVS
(VoLTE, VoWiFi) do carry. The phone then sends the other
party's voice as CALL_AUDIO, and plays the CALL_AUDIO it receives into the call, until the
call ends or either side sends CALL_STOP.

CALL_AUDIO's payload is mono 16 bit little endian PCM, at the rate CALL_START chose (16 kHz
by default), to the end of the message, usually 20 ms (640 bytes at 16 kHz) per message.

### 10.5 CONTACTS_REQ (`0x14`) and CONTACTS (`0x15`)

The Mac asks with CONTACTS_REQ; the phone answers CONTACTS, or nothing when bit 1 of
CALL_STATUS is clear.

| Field   | Type | Description                                                     |
| ------- | ---- | --------------------------------------------------------------- |
| entries | rest | UTF-8 text, one line per number: name, tab, number, tab, `0` or `1` for starred, tab, photo id |

The photo id names the contact's photo, and changes when the photo does. It is empty, or
missing, when the contact has none.

### 10.6 CALLER_ID (`0x16`)

What the phone's own call screen shows for a ringing call: a contact, a business found
online, a spam warning. The phone reads it from its dialer's incoming call notification,
with the notification access its user granted (bit 2 of CALL_STATUS), and sends it as soon
as it shows, or right after CALL_GRANT when the call already rings.

| Field   | Type | Description                                                       |
| ------- | ---- | ----------------------------------------------------------------- |
| caller  | rest | UTF-8 text: the notification's title, then a newline and its text |

### 10.7 PHOTOS_REQ (`0x17`) and PHOTO (`0x18`)

The Mac keeps the photos it received, and asks only for the ids of CONTACTS it does not
hold yet.

PHOTOS_REQ, Mac to Android:

| Field | Type | Description                                 |
| ----- | ---- | ------------------------------------------- |
| ids   | rest | UTF-8 text, one photo id per line           |

The phone answers each id with one PHOTO:

| Field | Type  | Description                                                    |
| ----- | ----- | -------------------------------------------------------------- |
| id    | `u64` | the photo id                                                   |
| image | rest  | the contact's thumbnail, JPEG, about 96 pixels square; empty when the photo is gone |
