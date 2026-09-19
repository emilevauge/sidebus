#!/usr/bin/env python3
"""Régénère les vecteurs de test du protocole.

Les fichiers .bin sont la référence commune aux deux implémentations : les tests Swift et
Kotlin les décodent, vérifient les champs, réencodent et comparent octet à octet.

Ce script ne sert qu'à les régénérer après une évolution de PROTOCOL.md. Il est écrit à
plat, sans réutiliser de code des deux côtés, pour rester un témoin indépendant.
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

# 0x01 HELLO : version 1, nom avec accents, UUID connu.
VECTORS["hello.bin"] = message(
    0x01,
    struct.pack("<H", 1)
    + string("MacBook d'Émile")
    + uuidlib.UUID("550e8400-e29b-41d4-a716-446655440000").bytes,
)

# 0x02 DEVICE_INFO : 2560x1600, 320 dpi, H.264 et HEVC, avec l'identifiant persistant.
VECTORS["device_info.bin"] = message(
    0x02,
    struct.pack("<HHHB", 2560, 1600, 320, 0x03)
    + string("Galaxy Tab S9")
    + uuidlib.UUID("7c9e6679-7425-40de-944b-e07fc1f90ae7").bytes,
)

# 0x03 DISPLAY_CONFIG : 2560x1600 à 60 fps en H.264.
VECTORS["display_config.bin"] = message(0x03, struct.pack("<HHBB", 2560, 1600, 60, 0x01))

# 0x04 VIDEO_CONFIG : un SPS et un PPS minuscules, en Annex B.
VECTORS["video_config.bin"] = message(
    0x04,
    bytes([0, 0, 0, 1, 0x67, 0x64, 0x00, 0x2A]) + bytes([0, 0, 0, 1, 0x68, 0xEE, 0x3C, 0xB0]),
)

# 0x05 VIDEO_FRAME : keyframe, flags bit 0 à 1.
VECTORS["video_frame_key.bin"] = message(
    0x05,
    struct.pack("<Q", 1_234_567_890) + bytes([0, 0, 0, 1, 0x65, 0x88, 0x84]),
    flags=0x0001,
)

# 0x05 VIDEO_FRAME : frame intermédiaire, flags à 0.
VECTORS["video_frame_delta.bin"] = message(
    0x05,
    struct.pack("<Q", 1_234_584_557) + bytes([0, 0, 0, 1, 0x41, 0x9A, 0x22]),
)

# 0x06 INPUT_EVENT : déplacement au quart haut, milieu horizontal.
VECTORS["input_event.bin"] = message(
    0x06, struct.pack("<BffBQ", 0x01, 0.5, 0.25, 0x00, 42)
)

# 0x07 PING et 0x08 PONG : même horodatage.
VECTORS["ping.bin"] = message(0x07, struct.pack("<Q", 0x0102030405060708))
VECTORS["pong.bin"] = message(0x08, struct.pack("<Q", 0x0102030405060708))

# 0x09 KEYFRAME_REQ : payload vide.
VECTORS["keyframe_req.bin"] = message(0x09, b"")

# 0x0A STATS : 120 reçues, 3 droppées, fenêtre de 2 s.
VECTORS["stats.bin"] = message(0x0A, struct.pack("<IIH", 120, 3, 2000))

# 0x0B BYE : bascule de transport.
VECTORS["bye.bin"] = message(0x0B, struct.pack("<B", 0x01))

# 0x0C PAIR_REQUEST : code à six chiffres.
VECTORS["pair_request.bin"] = message(0x0C, struct.pack("<I", 428_913))

# 0x0D PAIR_RESULT : appairage accepté.
VECTORS["pair_result.bin"] = message(0x0D, struct.pack("<B", 0x01))

# Type inconnu : doit être sauté proprement, sans fermer la connexion.
VECTORS["unknown_type.bin"] = message(0x7F, b"abc")

# Deux messages collés dans le même paquet : le décodeur doit sortir les deux.
VECTORS["stream_two_messages.bin"] = VECTORS["ping.bin"] + VECTORS["keyframe_req.bin"]


if __name__ == "__main__":
    directory = Path(__file__).parent
    for name, payload in VECTORS.items():
        (directory / name).write_bytes(payload)
        print(f"{name}: {len(payload)} octets")
