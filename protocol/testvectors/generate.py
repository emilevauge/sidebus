#!/usr/bin/env python3
"""Regenerates the protocol test vectors.

The .bin files are the reference shared by both implementations: the Swift and Kotlin tests
decode them, check the fields, re-encode and compare byte for byte.

This script only serves to regenerate them after a change to PROTOCOL.md. It is written
flat, reusing no code from either side, so it stays an independent witness.
"""

import struct
import uuid as uuidlib
from pathlib import Path

MAGIC = 0x5B


def message(type_, payload, flags=0):
    return struct.pack("<BBHI", MAGIC, type_, flags, len(payload)) + payload


def string(value):
    encoded = value.encode("utf-8")
    assert len(encoded) <= 255, value
    return struct.pack("<H", len(encoded)) + encoded


VECTORS = {}

# 0x01 HELLO: version 1, accented name, known UUID.
VECTORS["hello.bin"] = message(
    0x01,
    struct.pack("<H", 1)
    + string("MacBook d'Émile")
    + uuidlib.UUID("550e8400-e29b-41d4-a716-446655440000").bytes,
)

# 0x02 DEVICE_INFO: 2560x1600, 320 dpi, H.264 and HEVC, with the persistent identifier.
VECTORS["device_info.bin"] = message(
    0x02,
    struct.pack("<HHHB", 2560, 1600, 320, 0x03)
    + string("Galaxy Tab S9")
    + uuidlib.UUID("7c9e6679-7425-40de-944b-e07fc1f90ae7").bytes,
)

# 0x03 DISPLAY_CONFIG: 2560x1600 at 60 fps in H.264.
VECTORS["display_config.bin"] = message(0x03, struct.pack("<HHBB", 2560, 1600, 60, 0x01))

# 0x04 VIDEO_CONFIG: one tiny SPS and one tiny PPS, in Annex B.
VECTORS["video_config.bin"] = message(
    0x04,
    bytes([0, 0, 0, 1, 0x67, 0x64, 0x00, 0x2A]) + bytes([0, 0, 0, 1, 0x68, 0xEE, 0x3C, 0xB0]),
)

# 0x05 VIDEO_FRAME: keyframe, flags bit 0 set.
VECTORS["video_frame_key.bin"] = message(
    0x05,
    struct.pack("<Q", 1_234_567_890) + bytes([0, 0, 0, 1, 0x65, 0x88, 0x84]),
    flags=0x0001,
)

# 0x05 VIDEO_FRAME: intermediate frame, flags at 0.
VECTORS["video_frame_delta.bin"] = message(
    0x05,
    struct.pack("<Q", 1_234_584_557) + bytes([0, 0, 0, 1, 0x41, 0x9A, 0x22]),
)

# 0x06 INPUT_EVENT: a move at the upper quarter, horizontally centred.
VECTORS["input_event.bin"] = message(
    0x06, struct.pack("<BffBQ", 0x01, 0.5, 0.25, 0x00, 42)
)

# 0x07 PING and 0x08 PONG: same timestamp.
VECTORS["ping.bin"] = message(0x07, struct.pack("<Q", 0x0102030405060708))
VECTORS["pong.bin"] = message(0x08, struct.pack("<Q", 0x0102030405060708))

# 0x09 KEYFRAME_REQ: empty payload.
VECTORS["keyframe_req.bin"] = message(0x09, b"")

# 0x0A STATS: 120 received, 3 dropped, a 2 s window.
VECTORS["stats.bin"] = message(0x0A, struct.pack("<IIH", 120, 3, 2000))

# 0x0B BYE: transport switch.
VECTORS["bye.bin"] = message(0x0B, struct.pack("<B", 0x01))

# 0x0C PAIR_REQUEST: six digit code.
VECTORS["pair_request.bin"] = message(0x0C, struct.pack("<I", 428_913))

# 0x0D PAIR_RESULT: pairing accepted.
VECTORS["pair_result.bin"] = message(0x0D, struct.pack("<B", 0x01))

# 0x0E CAMERA_LIST: two cameras, back and front.
VECTORS["camera_list.bin"] = message(
    0x0E,
    struct.pack("<B", 2)
    + struct.pack("<BB", 0, 0x00) + string("Back camera")
    + struct.pack("<BB", 1, 0x01) + string("Front camera"),
)

# 0x0F CAMERA_START: camera 1, 1280x720 at 30 fps in H.264.
VECTORS["camera_start.bin"] = message(
    0x0F, struct.pack("<BHHBB", 1, 1280, 720, 30, 0x01)
)

# 0x10 CAMERA_CONFIG: what the tablet actually opened, plus the parameter sets.
# Rotation 1: the sensor is mounted a quarter turn off the way the device is held.
VECTORS["camera_config.bin"] = message(
    0x10,
    struct.pack("<HHBB", 1280, 720, 0x01, 1)
    + bytes([0, 0, 0, 1, 0x67, 0x42, 0x00])
    + bytes([0, 0, 0, 1, 0x68, 0xCE]),
)

# 0x11 CAMERA_FRAME: keyframe, flags bit 0 set.
VECTORS["camera_frame.bin"] = message(
    0x11,
    struct.pack("<Q", 987_654_321) + bytes([0, 0, 0, 1, 0x65, 0x11, 0x22]),
    flags=0x0001,
)

# 0x12 CAMERA_STOP: empty payload.
VECTORS["camera_stop.bin"] = message(0x12, b"")

# 0x13 VIDEO_STOP: empty payload.
VECTORS["video_stop.bin"] = message(0x13, b"")

# Unknown type: must be skipped cleanly, without closing the connection.
VECTORS["unknown_type.bin"] = message(0x7F, b"abc")

# Two messages in one packet: the decoder must yield both.
VECTORS["stream_two_messages.bin"] = VECTORS["ping.bin"] + VECTORS["keyframe_req.bin"]


if __name__ == "__main__":
    directory = Path(__file__).parent
    for name, payload in VECTORS.items():
        (directory / name).write_bytes(payload)
        print(f"{name}: {len(payload)} bytes")
