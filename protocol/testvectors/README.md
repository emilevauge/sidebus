# Protocol test vectors

A binary reference shared by both implementations. The Swift and Kotlin tests decode each
file, check the fields listed below, re-encode and compare byte for byte with the original.

A change to `PROTOCOL.md` propagates here with `python3 generate.py`, and the tests on both
sides must be updated in the same commit.

| File | Type | Expected content |
| --- | --- | --- |
| `hello.bin` | HELLO | version 1, name `MacBook d'Émile`, UUID `550e8400-e29b-41d4-a716-446655440000` |
| `device_info.bin` | DEVICE_INFO | 2560 × 1600, 320 dpi, codecs `0x03`, name `Galaxy Tab S9` |
| `display_config.bin` | DISPLAY_CONFIG | 2560 × 1600, 60 fps, H.264 codec |
| `video_config.bin` | VIDEO_CONFIG | one SPS and one PPS in Annex B, 16 bytes |
| `video_frame_key.bin` | VIDEO_FRAME | timestamp 1,234,567,890 µs, flags bit 0 set, 7 bytes of NAL |
| `video_frame_delta.bin` | VIDEO_FRAME | timestamp 1,234,584,557 µs, flags at 0 |
| `input_event.bin` | INPUT_EVENT | MOVE, x 0.5, y 0.25, left button, timestamp 42 |
| `ping.bin` | PING | timestamp `0x0102030405060708` |
| `pong.bin` | PONG | same timestamp as `ping.bin` |
| `keyframe_req.bin` | KEYFRAME_REQ | empty payload |
| `stats.bin` | STATS | 120 received, 3 dropped, 2000 ms window |
| `bye.bin` | BYE | reason 1, transport switch |
| `pair_request.bin` | PAIR_REQUEST | code 428913 |
| `pair_result.bin` | PAIR_RESULT | pairing accepted |
| `unknown_type.bin` | 0x7F | unknown type, payload `abc`, must be skipped without error |
| `stream_two_messages.bin` | PING + KEYFRAME_REQ | two messages in one packet, the decoder must yield both |

The name in `hello.bin` carries an accented character and the one in `device_info.bin` does
not: both sides must handle multibyte UTF-8 correctly.
