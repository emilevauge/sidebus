# Vecteurs de test du protocole

Référence binaire commune aux deux implémentations. Les tests Swift et Kotlin décodent
chaque fichier, vérifient les champs attendus ci dessous, réencodent et comparent octet à
octet avec le fichier d'origine.

Un changement de `PROTOCOL.md` se répercute ici avec `python3 generate.py`, et les tests
des deux côtés doivent être mis à jour dans la même commit.

| Fichier | Type | Contenu attendu |
| --- | --- | --- |
| `hello.bin` | HELLO | version 1, nom `MacBook d'Émile`, UUID `550e8400-e29b-41d4-a716-446655440000` |
| `device_info.bin` | DEVICE_INFO | 2560 × 1600, 320 dpi, codecs `0x03`, nom `Galaxy Tab S9` |
| `display_config.bin` | DISPLAY_CONFIG | 2560 × 1600, 60 fps, codec H.264 |
| `video_config.bin` | VIDEO_CONFIG | un SPS et un PPS en Annex B, 16 octets |
| `video_frame_key.bin` | VIDEO_FRAME | horodatage 1 234 567 890 µs, flags bit 0 à 1, 7 octets de NAL |
| `video_frame_delta.bin` | VIDEO_FRAME | horodatage 1 234 584 557 µs, flags à 0 |
| `input_event.bin` | INPUT_EVENT | MOVE, x 0.5, y 0.25, bouton gauche, horodatage 42 |
| `ping.bin` | PING | horodatage `0x0102030405060708` |
| `pong.bin` | PONG | même horodatage que `ping.bin` |
| `keyframe_req.bin` | KEYFRAME_REQ | payload vide |
| `stats.bin` | STATS | 120 reçues, 3 droppées, fenêtre 2000 ms |
| `bye.bin` | BYE | raison 1, bascule de transport |
| `unknown_type.bin` | 0x7F | type inconnu, payload `abc`, doit être sauté sans erreur |
| `stream_two_messages.bin` | PING + KEYFRAME_REQ | deux messages collés, le décodeur doit sortir les deux |

Le nom de `hello.bin` contient un caractère accentué, et celui de `device_info.bin` non :
les deux côtés doivent traiter l'UTF-8 multioctet correctement.
