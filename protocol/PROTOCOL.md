# Protocole Sidebus

Version du protocole : **1**

Ce fichier est la source de vérité du format sur le fil. Toute modification se fait ici
d'abord, puis se répercute côté Mac et côté Android dans la même commit, avec les vecteurs
de `protocol/testvectors/` mis à jour.

---

## 1. Couche de transport

- TCP, un seul socket bidirectionnel, port **27183**.
- Le serveur est la **tablette Android**. Le Mac est toujours le client, en USB comme en Wi-Fi.
- `TCP_NODELAY` activé des deux côtés.
- TLS 1.3 à partir de la phase 6 (certificat auto signé côté Android, épinglage côté Mac).
  En phase 3 le lien est en clair, sur le tunnel adb uniquement.
- Ordre des octets : **little endian** pour tous les entiers et flottants du protocole.
  Les flottants sont au format IEEE 754 binary32.
- Les messages sont émis dans l'ordre sur le socket, sans multiplexage ni entrelacement :
  un message est écrit intégralement avant le suivant.

## 2. En tête de message

8 octets, présents devant chaque message.

| Offset | Taille | Champ  | Description                        |
| ------ | ------ | ------ | ---------------------------------- |
| 0      | 1      | magic  | toujours `0x5B`                    |
| 1      | 1      | type   | voir la table des types            |
| 2      | 2      | flags  | dépend du type, `0` si non utilisé |
| 4      | 4      | length | taille du payload, en octets       |

Règles de lecture :

- Un `magic` différent de `0x5B` est une erreur fatale : fermer le socket, ne pas tenter de
  resynchroniser.
- Un `type` inconnu se saute proprement : lire et jeter `length` octets, continuer.
  C'est ce qui permettra d'ajouter des messages sans casser les versions antérieures.
- `length` est borné à **8 388 608 octets (8 MiB)**. Au delà, erreur fatale. La borne protège
  contre une allocation dictée par le pair et couvre largement une frame intra à 15 Mbit/s.
- Un message sans payload a `length = 0` et aucun octet à sa suite.

## 3. Types primitifs du payload

| Notation | Encodage                                                          |
| -------- | ----------------------------------------------------------------- |
| `u8`     | 1 octet non signé                                                 |
| `u16`    | 2 octets non signés, little endian                                |
| `u32`    | 4 octets non signés, little endian                                |
| `u64`    | 8 octets non signés, little endian                                |
| `f32`    | 4 octets, IEEE 754 binary32, little endian                        |
| `uuid`   | 16 octets bruts, big endian (ordre RFC 4122, celui de la forme texte) |
| `string` | `u16` longueur en octets, puis ce nombre d'octets en UTF-8, sans terminateur |

Une `string` est bornée à 255 octets utiles. Les deux côtés tronquent à l'émission sur une
frontière de caractère, et refusent le message à la réception si la longueur dépasse.

Les champs sont sérialisés dans l'ordre du tableau, sans alignement ni remplissage.

## 4. Types de messages

| Valeur | Nom            | Sens               | Payload                                   |
| ------ | -------------- | ------------------ | ----------------------------------------- |
| `0x01` | HELLO          | Mac vers Android   | voir 4.1                                  |
| `0x02` | DEVICE_INFO    | Android vers Mac   | voir 4.2                                  |
| `0x03` | DISPLAY_CONFIG | Mac vers Android   | voir 4.3                                  |
| `0x04` | VIDEO_CONFIG   | Mac vers Android   | voir 4.4                                  |
| `0x05` | VIDEO_FRAME    | Mac vers Android   | voir 4.5                                  |
| `0x06` | INPUT_EVENT    | Android vers Mac   | voir 4.6                                  |
| `0x07` | PING           | bidirectionnel     | `u64` timestamp µs                        |
| `0x08` | PONG           | bidirectionnel     | `u64` echo du timestamp du PING           |
| `0x09` | KEYFRAME_REQ   | Android vers Mac   | vide                                      |
| `0x0A` | STATS          | Android vers Mac   | voir 4.10                                 |
| `0x0B` | BYE            | bidirectionnel     | `u8` code de raison                       |
| `0x0C` | PAIR_REQUEST   | Mac vers Android   | `u32` code d'appairage, voir 4.12         |
| `0x0D` | PAIR_RESULT    | Android vers Mac   | `u8` 0 refusé, 1 accepté, voir 4.13       |

Recevoir un message dans le mauvais sens (par exemple un HELLO côté Mac) est une erreur
fatale : fermer le socket.

### 4.1 HELLO (`0x01`)

| Champ    | Type     | Description                          |
| -------- | -------- | ------------------------------------ |
| version  | `u16`    | version du protocole parlée par le Mac |
| name     | `string` | nom du Mac, affiché sur la tablette  |
| uuid     | `uuid`   | identifiant persistant du Mac        |

C'est le **Mac** qui envoie HELLO, puisque c'est lui qui ouvre la connexion.

Si `version` est supérieure à celle que connaît la tablette, elle répond quand même
DEVICE_INFO : c'est le Mac, qui connaît les deux versions, qui décide de continuer ou
d'envoyer BYE avec le code 2.

### 4.2 DEVICE_INFO (`0x02`)

| Champ    | Type     | Description                                        |
| -------- | -------- | -------------------------------------------------- |
| width    | `u16`    | largeur de la dalle, en pixels                     |
| height   | `u16`    | hauteur de la dalle, en pixels                     |
| density  | `u16`    | densité, en dpi (`DisplayMetrics.densityDpi`)      |
| codecs   | `u8`     | bitmask des codecs décodables, voir 5.1            |
| name     | `string` | nom de l'appareil (`Settings.Global.DEVICE_NAME`)  |
| uuid     | `uuid`   | identifiant persistant de l'appareil               |

`width` et `height` décrivent la dalle en orientation paysage, indépendamment de
l'orientation courante.

`uuid` est le même identifiant que la clé `id` de l'annonce mDNS, généré au premier
lancement et conservé ensuite. Il est indispensable à l'arbitrage entre transports : sans
lui, une tablette vue à la fois en USB et en Wi-Fi apparaît comme deux appareils, le port
USB étant repéré par son numéro de série adb et le Wi-Fi par cet identifiant.

### 4.3 DISPLAY_CONFIG (`0x03`)

| Champ  | Type  | Description                            |
| ------ | ----- | -------------------------------------- |
| width  | `u16` | largeur du flux vidéo, en pixels       |
| height | `u16` | hauteur du flux vidéo, en pixels       |
| fps    | `u8`  | images par seconde visées              |
| codec  | `u8`  | codec retenu, valeur unique, voir 5.1  |

Le Mac choisit. La tablette applique, ou envoie BYE code 2 si elle ne peut pas.

### 4.4 VIDEO_CONFIG (`0x04`)

Payload : les paramètres du codec en **Annex B**, c'est à dire les NAL units préfixées par
`00 00 00 01`, concaténées dans l'ordre.

- H.264 : SPS puis PPS.
- HEVC : VPS puis SPS puis PPS.

Côté Android, ce payload est passé tel quel dans `csd-0`.

Un VIDEO_CONFIG est toujours envoyé avant le premier VIDEO_FRAME, et de nouveau à chaque
changement de configuration de l'encodeur (résolution, codec).

### 4.5 VIDEO_FRAME (`0x05`)

| Champ     | Type  | Description                                 |
| --------- | ----- | ------------------------------------------- |
| timestamp | `u64` | horodatage de capture, en µs                |
| data      | reste | NAL units en Annex B, jusqu'au bout du payload |

Flags :

| Bit | Signification            |
| --- | ------------------------ |
| 0   | la frame est une keyframe |

Les autres bits sont réservés et valent `0`.

Le timestamp est issu de l'horloge monotone du Mac (`mach_absolute_time` converti en µs).
Il ne sert pas à cadencer le rendu, qui est immédiat, mais à mesurer la latence et à
horodater les statistiques.

### 4.6 INPUT_EVENT (`0x06`)

| Champ     | Type  | Description                         |
| --------- | ----- | ----------------------------------- |
| kind      | `u8`  | voir 5.2                            |
| x         | `f32` | abscisse normalisée, 0.0 à 1.0      |
| y         | `f32` | ordonnée normalisée, 0.0 à 1.0      |
| button    | `u8`  | voir 5.3                            |
| timestamp | `u64` | horodatage de l'événement, en µs    |

Les coordonnées sont normalisées sur la surface d'affichage de la tablette, indépendamment
de la résolution négociée. L'origine est en **haut à gauche**. Le Mac remappe sur
`CGDisplayBounds(displayID)`.

Une valeur hors de `[0.0, 1.0]` est ramenée dans l'intervalle à la réception, sans erreur.

### 4.10 STATS (`0x0A`)

| Champ    | Type  | Description                                  |
| -------- | ----- | -------------------------------------------- |
| received | `u32` | frames reçues pendant la fenêtre             |
| dropped  | `u32` | frames droppées pendant la fenêtre           |
| window   | `u16` | durée de la fenêtre de mesure, en ms         |

Les compteurs portent sur la fenêtre écoulée, pas depuis le début de la session.

### 4.11 BYE (`0x0B`)

| Champ  | Type | Description        |
| ------ | ---- | ------------------ |
| reason | `u8` | voir 5.4           |

L'émetteur ferme le socket après l'envoi, sans attendre de réponse.

### 4.12 PAIR_REQUEST (`0x0C`)

| Champ | Type  | Description                                          |
| ----- | ----- | ---------------------------------------------------- |
| code  | `u32` | code à six chiffres dérivé de l'empreinte, voir 7    |

Le Mac l'envoie après DEVICE_INFO, et seulement quand il ne connaissait pas l'empreinte du
certificat présenté : c'est à dire quand il vient lui même de demander confirmation à son
utilisateur. La tablette affiche alors le code et demande confirmation à son tour.

Le Mac n'enregistre l'empreinte qu'après un PAIR_RESULT accepté. Un appairage refusé d'un
côté ne laisse donc rien derrière lui de l'autre.

La tablette compare le code reçu à celui qu'elle dérive de son propre certificat. Ils
doivent être identiques : une différence signifie que le certificat vu par le Mac n'est pas
celui de la tablette, et la tablette le signale dans sa demande de confirmation.

### 4.13 PAIR_RESULT (`0x0D`)

| Champ    | Type | Description            |
| -------- | ---- | ---------------------- |
| accepted | `u8` | 0 refusé, 1 accepté    |

Toute valeur autre que 1 vaut refus.

Le Mac attend ce message au plus 120 s après PAIR_REQUEST. Passé ce délai, il traite
l'absence de réponse comme un refus et envoie BYE avec le code 0.

## 5. Énumérations

### 5.1 Codecs

| Bit | Valeur du bitmask | Valeur unique (`codec`) | Codec |
| --- | ----------------- | ----------------------- | ----- |
| 0   | `0x01`            | `0x01`                  | H.264 |
| 1   | `0x02`            | `0x02`                  | HEVC  |

Dans DEVICE_INFO, `codecs` est un bitmask, plusieurs bits peuvent être à 1. Dans
DISPLAY_CONFIG, `codec` désigne un seul codec, la valeur est celle du bit correspondant.

### 5.2 Types d'événement d'entrée

| Valeur | Nom  | Origine Android |
| ------ | ---- | --------------- |
| `0x00` | DOWN | `ACTION_DOWN`   |
| `0x01` | MOVE | `ACTION_MOVE`   |
| `0x02` | UP   | `ACTION_UP`     |

`ACTION_CANCEL` est émis comme un UP.

### 5.3 Boutons

| Valeur | Bouton  |
| ------ | ------- |
| `0x00` | gauche  |
| `0x01` | droit   |
| `0x02` | milieu  |

En v1 la tablette n'émet que `0x00`.

### 5.4 Codes de raison de BYE

| Valeur | Signification          |
| ------ | ---------------------- |
| `0x00` | fermeture normale      |
| `0x01` | bascule de transport   |
| `0x02` | erreur                 |

## 6. Séquence de connexion

1. Le Mac établit le socket (Wi-Fi direct, ou `127.0.0.1:27183` via le tunnel adb), puis
   le handshake TLS.
2. Mac envoie HELLO. Android répond DEVICE_INFO.
3. Si l'appareil n'était pas appairé, Mac envoie PAIR_REQUEST et attend PAIR_RESULT. Un
   refus met fin à la connexion par un BYE de code 0.
4. Mac choisit la résolution et le codec, crée l'écran virtuel, envoie DISPLAY_CONFIG.
5. Mac envoie VIDEO_CONFIG, puis un flux de VIDEO_FRAME démarrant par une keyframe.
6. PING toutes les secondes dans les deux sens. Un pair sans PONG ni trafic pendant 5 s est
   considéré déconnecté : fermer le socket.
7. STATS toutes les 2 s, depuis la tablette. Alimente l'adaptation de débit.

INPUT_EVENT et KEYFRAME_REQ peuvent être émis à tout moment une fois DISPLAY_CONFIG passé.

## 7. Sécurité et appairage

TLS 1.3 uniquement, dans les deux modes de transport. La tablette est le serveur et
présente un certificat auto signé de longue durée, généré au premier lancement et conservé
dans l'Android Keystore. Le Mac est le client et ne présente aucun certificat.

La vérification côté Mac ne valide pas une chaîne de confiance, il n'y en a pas : elle
compare l'empreinte SHA-256 du certificat présenté à celle enregistrée pour cet appareil.
C'est le modèle de `known_hosts` de SSH.

### Code d'appairage

À la première connexion à un appareil inconnu, les deux côtés dérivent le même code à six
chiffres de l'empreinte du certificat :

```
empreinte = SHA-256(certificat au format DER)
code      = (empreinte[0] << 24 | empreinte[1] << 16 | empreinte[2] << 8 | empreinte[3]) mod 1 000 000
```

Le résultat est affiché sur six chiffres, zéros de tête compris. La comparaison des deux
codes affichés reste visuelle et hors bande : c'est elle qui protège du pair qui se fait
passer pour la tablette, et aucun échange de protocole ne peut la remplacer.

L'appairage demande une confirmation **des deux côtés**, dans cet ordre :

1. Le Mac affiche le code dès le handshake TLS, puisque c'est là qu'il découvre
   l'empreinte. Un refus ferme le socket, rien n'est enregistré.
2. Une fois DEVICE_INFO reçu, le Mac envoie PAIR_REQUEST. La tablette affiche le code à son
   tour et répond PAIR_RESULT.

PAIR_REQUEST ne transporte pas un secret : le code se déduit du certificat, que quiconque
écoute le handshake voit passer. Il sert à déclencher la confirmation sur la tablette et à
lui permettre de détecter que le Mac ne voit pas le même certificat qu'elle présente.

Le Mac enregistre l'empreinte dans le trousseau, associée à l'`uuid` de l'appareil, une
fois les deux confirmations obtenues.
Si l'empreinte d'un appareil connu change, la connexion est refusée et l'utilisateur
alerté, sans proposition de passer outre en un clic.

## 8. Enregistrements TXT de l'annonce mDNS

Type de service : `_sidebus._tcp`, port 27183. Valeurs TXT en ASCII.

| Clé  | Contenu                                                    |
| ---- | ---------------------------------------------------------- |
| `v`  | version du protocole, en décimal                           |
| `id` | UUID persistant de l'appareil, forme texte RFC 4122        |
| `w`  | largeur en pixels, en décimal                              |
| `h`  | hauteur en pixels, en décimal                              |
| `d`  | densité en dpi, en décimal                                 |
| `c`  | bitmask des codecs, en décimal                             |
| `fp` | 8 premiers octets du SHA-256 du certificat, en hexadécimal minuscule |

## 9. Vecteurs de test

`protocol/testvectors/` contient un fichier par cas, encodé une fois pour toutes. Les tests
unitaires des deux côtés décodent chaque vecteur, vérifient les champs, réencodent et
comparent octet à octet avec le fichier d'origine.

Les vecteurs arrivent en phase 3, avec `MessageCodec`.
