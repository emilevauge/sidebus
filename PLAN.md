# Sidebus, plan de développement

Document de référence pour l'implémentation. À lire intégralement avant d'écrire du code.

---

## 1. Objectif

Sidebus transforme une tablette Android en écran secondaire pour un Mac.

Le Mac déclare un écran virtuel, capture son framebuffer, l'encode en H.264/HEVC, et le transmet à la tablette qui le décode et l'affiche. Les événements tactiles remontent vers le Mac et sont injectés comme des événements souris.

Deux transports, tous deux requis en v1 :

- **USB**, via tunnel adb. Latence minimale, recharge la tablette.
- **Wi-Fi**, avec découverte automatique par annonce mDNS. La tablette s'annonce, le Mac la trouve seul.

Cible de performance :

- latence bout en bout inférieure à 60 ms en USB, inférieure à 100 ms en Wi-Fi 5 GHz
- 60 fps sur contenu animé, descente automatique en dessous sur contenu statique
- consommation CPU côté Mac inférieure à 10 %

Non objectifs pour la v1 : pression du stylet, multi tablettes simultanées, audio, écran miroir (on ne fait que l'extension).

---

## 2. Décision structurante : la tablette est le serveur

**Android écoute, le Mac se connecte.** Dans les deux modes de transport, sans exception.

C'est contre intuitif (le Mac est la machine principale) mais c'est ce qui unifie tout le reste :

- En **Wi-Fi**, la tablette s'annonce en mDNS et écoute. Le Mac parcourt le réseau, trouve l'annonce, se connecte à l'IP et au port publiés. Une annonce sert à trouver un serveur, donc le serveur doit être du côté qui s'annonce.
- En **USB**, `adb forward tcp:27183 tcp:27183` mappe un port local du Mac vers un port en écoute **sur l'appareil**. C'est exactement la direction dont on a besoin. (`adb reverse` ferait l'inverse et imposerait un code différent.)

Résultat : une fois le socket établi, le code est strictement identique dans les deux cas. La différence entre USB et Wi-Fi tient dans une centaine de lignes de découverte, pas dans le pipeline.

---

## 3. Architecture

```
┌─────────────────────────── macOS ──────────────────────────┐
│                                                            │
│  VirtualDisplay ──► ScreenCaptureKit ──► VideoToolbox      │
│  (CGVirtualDisplay)   (IOSurface)        (H.264/HEVC HW)   │
│                                               │            │
│  EventInjector ◄──── InputDecoder             ▼            │
│  (CGEventPost)                           TransportClient   │
│                                          (NWConnection)    │
│                                               ▲            │
│  PeerDiscovery ───────────────────────────────┘            │
│  ├── BonjourBrowser  (NWBrowser, _sidebus._tcp)            │
│  └── AdbWatcher      (adb track-devices + adb forward)     │
└───────────────────────────────┬────────────────────────────┘
                                │
              Wi-Fi direct  ou  │  tunnel USB (adb forward)
                                │
┌─────────────────────────── Android ────────────────────────┐
│                          TransportServer                   │
│                          (ServerSocket 27183, TLS)         │
│                                │                           │
│  ServiceAdvertiser             ▼                           │
│  (NsdManager)             MediaCodec                       │
│                                │                           │
│  TouchListener ──► InputEncoder│                           │
│                                ▼                           │
│                           SurfaceView                      │
└────────────────────────────────────────────────────────────┘
```

Règle structurante : **les pixels ne passent jamais par le CPU côté Mac.** ScreenCaptureKit rend un `CMSampleBuffer` adossé à un `IOSurface` en mémoire GPU, passé tel quel à `VTCompressionSessionEncodeFrame`. Aucun `memcpy` de framebuffer. Si tu manipules des `UnsafePointer` sur des pixels, tu t'es trompé de chemin.

---

## 4. Structure du repo

```
sidebus/
├── README.md
├── PLAN.md                      (ce fichier)
├── protocol/
│   ├── PROTOCOL.md              (spec du fil, source de vérité partagée)
│   └── testvectors/             (vecteurs binaires communs aux deux côtés)
├── mac/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── SidebusCore/         (logique, testable, sans UI)
│   │   │   ├── VirtualDisplay/
│   │   │   ├── Capture/
│   │   │   ├── Encoder/
│   │   │   ├── Transport/       (TransportClient, BonjourBrowser, AdbWatcher)
│   │   │   ├── Pairing/
│   │   │   ├── Input/
│   │   │   └── Protocol/
│   │   └── SidebusApp/          (menu bar app, SwiftUI)
│   └── Tests/
└── android/
    ├── settings.gradle.kts
    └── app/src/main/java/app/sidebus/
        ├── transport/           (TransportServer, ServiceAdvertiser)
        ├── pairing/
        ├── protocol/
        ├── decoder/
        ├── ui/
        └── input/
```

`protocol/PROTOCOL.md` est la source de vérité. Toute modification du format se fait là d'abord, puis se répercute des deux côtés dans la même commit.

---

## 5. Réutilisation de code existant

Trois projets couvrent des morceaux de Sidebus. Leurs licences dictent ce qu'on peut faire de chacun, et cette distinction n'est pas négociable.

### DeskPad, licence MIT

`https://github.com/Stengo/DeskPad`

**Copie autorisée.** La licence MIT permet la réutilisation dans un produit propriétaire, à condition de conserver l'avis de copyright et le texte de licence.

DeskPad sert à deux titres dans ce projet.

**Comme harnais de développement, en phase 1.** On l'installe et on le lance tel quel, sans toucher à son code. Il fournit un vrai écran virtuel à capturer pendant qu'on met au point l'encodage, le transport et l'affichage. C'est aussi le test qui valide que `CGVirtualDisplay` fonctionne sur la version de macOS ciblée.

**Comme source de code, en phase 7.** Reprendre directement son header de pont et les déclarations des classes privées plutôt que de reconstituer les signatures à l'aveugle. Ça élimine la seule tâche de rétro ingénierie du projet, et surtout les détails qu'on ne devine pas : calcul de la taille physique en mm pour obtenir la bonne densité, déclaration correcte des modes HiDPI, cycle de vie de l'objet display.

Obligations : un fichier `mac/THIRD_PARTY.md` recensant l'attribution, et l'avis de copyright conservé en tête de chaque fichier repris. Le simple fait de lancer l'application n'impose évidemment rien, seule la reprise de code est concernée.

### scrcpy, licence Apache 2.0

`https://github.com/Genymobile/scrcpy`

**Copie autorisée.** Apache 2.0 est compatible avec un produit propriétaire. Obligations : attribution, mention des modifications, et le fichier NOTICE s'il y a lieu.

Sidebus est scrcpy à l'envers (scrcpy encode sur Android et décode sur le bureau), donc le pipeline vidéo ne se transpose pas. En revanche toute la plomberie adb de la phase 3 est directement réutilisable : localisation du binaire, flux `track-devices`, gestion du forward, lancement à distance de l'application, reconnexion au rebranchement.

À reprendre aussi : leurs choix de latence, qui sont le fruit de plusieurs années de mesures. Pas de B frames, aucune file d'attente au rendu, `SurfaceView` et jamais `TextureView`, `TCP_NODELAY`. Ces décisions sont déjà dans le présent plan, elles viennent de là.

À ne pas reprendre : leur binaire `adb`. Le code d'adb est sous Apache 2.0 mais les conditions de redistribution du SDK Android sont plus restrictives que la licence du code. Utiliser celui du système, et proposer un téléchargement guidé s'il manque.

### Moonlight et Sunshine, licence GPLv3

`https://github.com/moonlight-stream/moonlight-android` et `https://github.com/LizardByte/Sunshine`

**Copie interdite.** La GPLv3 est une licence copyleft virale : intégrer la moindre portion de ce code dans Sidebus obligerait à publier l'intégralité de Sidebus sous GPLv3.

Ces projets font pourtant déjà presque exactement ce que fait Sidebus : découverte mDNS des hôtes sur le réseau local avec ajout manuel par IP en repli, appairage par code PIN, TLS, H.264/HEVC basse latence, client Android sur MediaCodec et SurfaceView, adaptation de débit. C'est précisément ce qui les rend dangereux comme référence.

**Règle de travail, à respecter strictement :** Moonlight et Sunshine servent de référence de *comportement*, jamais d'implémentation. Autrement dit, on peut observer l'application en fonctionnement pour décider à quoi doit ressembler un bon appairage, quel délai de reconnexion paraît naturel, à quel moment baisser le débit. On n'ouvre pas leurs fichiers source pour écrire les nôtres. Lire du code GPL puis produire un équivalent est une zone grise juridique qu'on ne veut pas explorer.

Si tu as besoin d'une référence de code sur ces sujets, cherche du côté d'implémentations permissives, ou pose la question plutôt que d'ouvrir le dépôt.

### Aucune dépendance tierce

Sidebus n'a besoin d'aucune bibliothèque externe. Tout est fourni par les deux systèmes :

| Besoin | macOS | Android |
| --- | --- | --- |
| Capture, encodage | ScreenCaptureKit, VideoToolbox | |
| Décodage, affichage | | MediaCodec, SurfaceView |
| Réseau, TLS | Network.framework | `SSLServerSocket`, Conscrypt intégré |
| Découverte mDNS | `NWBrowser` | `NsdManager` |
| Clés et certificats | Trousseau | Android Keystore |

Détail utile : pas besoin de BouncyCastle pour le certificat auto signé. Un `KeyPairGenerator` configuré avec un `KeyGenParameterSpec` génère automatiquement un certificat auto signé dans le Keystore, qu'on récupère ensuite depuis l'entrée.

Seules exceptions envisageables, et seulement plus tard : **libusb** (LGPL, acceptable en liaison dynamique) si on implémente l'AOA.

Toute proposition d'ajout de dépendance doit être justifiée explicitement et validée avant d'être introduite.

## 6. Protocole

Transport : TCP, un seul socket bidirectionnel, chiffré TLS. Ordre des octets : little endian. `TCP_NODELAY` activé des deux côtés.

### En tête de message (8 octets)

| Offset | Taille | Champ | Description |
| --- | --- | --- | --- |
| 0 | 1 | magic | 0x5B |
| 1 | 1 | type | voir table ci dessous |
| 2 | 2 | flags | dépend du type |
| 4 | 4 | length | taille du payload en octets |

### Types de messages

| Valeur | Nom | Sens | Payload |
| --- | --- | --- | --- |
| 0x01 | HELLO | Mac vers Android | version protocole (u16), nom du Mac (chaîne), UUID du Mac (16 o) |
| 0x02 | DEVICE_INFO | Android vers Mac | largeur px (u16), hauteur px (u16), densité (u16), codecs supportés (bitmask u8), nom de l'appareil (chaîne) |
| 0x03 | DISPLAY_CONFIG | Mac vers Android | largeur (u16), hauteur (u16), fps cible (u8), codec retenu (u8) |
| 0x04 | VIDEO_CONFIG | Mac vers Android | SPS/PPS (H.264) ou VPS/SPS/PPS (HEVC), en Annex B |
| 0x05 | VIDEO_FRAME | Mac vers Android | timestamp µs (u64) puis NAL units en Annex B. flags bit 0 = keyframe |
| 0x06 | INPUT_EVENT | Android vers Mac | type (u8), x normalisé (f32 0..1), y normalisé (f32 0..1), bouton (u8), timestamp µs (u64) |
| 0x07 | PING | bidirectionnel | timestamp µs (u64) |
| 0x08 | PONG | bidirectionnel | echo du timestamp du PING |
| 0x09 | KEYFRAME_REQ | Android vers Mac | vide |
| 0x0A | STATS | Android vers Mac | frames reçues (u32), frames droppées (u32), fenêtre ms (u16) |
| 0x0B | BYE | bidirectionnel | code de raison (u8) : 0 normal, 1 bascule de transport, 2 erreur |

Noter l'inversion par rapport à un schéma classique : c'est le **Mac** qui envoie HELLO, puisque c'est lui qui se connecte.

### Séquence de connexion

1. Le Mac établit le socket (Wi-Fi direct ou via le tunnel adb), puis le handshake TLS.
2. Mac envoie HELLO. Android répond DEVICE_INFO.
3. Mac choisit la résolution et le codec, crée l'écran virtuel, envoie DISPLAY_CONFIG.
4. Mac envoie VIDEO_CONFIG puis un flux de VIDEO_FRAME démarrant par une keyframe.
5. PING toutes les secondes dans les deux sens, timeout de déconnexion à 5 s.
6. STATS toutes les 2 s, utilisé pour l'adaptation de débit.

### Coordonnées d'entrée

Normalisées entre 0.0 et 1.0, indépendantes de la résolution négociée. Le Mac les remappe sur `CGDisplayBounds(displayID)`.

---

## 7. Découverte réseau

### Annonce côté Android

`NsdManager.registerService()` avec :

- type de service : `_sidebus._tcp`
- nom : le nom de l'appareil (`Settings.Global.DEVICE_NAME`), l'utilisateur doit pouvoir le reconnaître
- port : 27183 (fixe, pour rester compatible avec `adb forward`)

Enregistrements TXT :

| Clé | Contenu |
| --- | --- |
| `v` | version du protocole |
| `id` | UUID persistant de l'appareil, généré au premier lancement |
| `w` | largeur en pixels |
| `h` | hauteur en pixels |
| `d` | densité |
| `c` | bitmask des codecs supportés |
| `fp` | 8 premiers octets du SHA-256 du certificat, en hexadécimal |

Le champ `fp` permet au Mac de reconnaître un appareil déjà appairé **avant** d'ouvrir la connexion, donc d'afficher "MaTablette (appairée)" plutôt qu'une liste anonyme.

L'annonce démarre quand l'app est au premier plan et s'arrête en arrière plan, pour ne pas polluer le réseau.

### Recherche côté Mac

`NWBrowser` avec `NWBrowser.Descriptor.bonjour(type: "_sidebus._tcp", domain: nil)`. Les résultats alimentent une liste observable affichée dans le menu bar. Se connecter à un résultat se fait directement avec son `NWEndpoint`, sans résolution manuelle d'IP.

**Autorisation Réseau local.** Depuis macOS 15, l'accès au réseau local est soumis à autorisation, exactement comme sur iOS. Il faut :

- `NSLocalNetworkUsageDescription` dans l'Info.plist, avec un texte explicite
- `NSBonjourServices` déclarant `_sidebus._tcp`
- une application **signée**, sinon l'autorisation ne persiste pas entre les lancements et l'utilisateur revoit la demande à chaque fois

C'est un piège classique : sans ces clés, le browser ne renvoie jamais rien et ne produit aucune erreur exploitable.

### Repli manuel

`NsdManager` est notoirement inégal selon les constructeurs, et beaucoup de réseaux d'entreprise bloquent le multicast. Prévoir dès le départ :

- la tablette affiche son IP et son port en clair dans son interface
- le Mac propose un champ de saisie manuelle "Connexion par adresse IP"

Ce n'est pas une fonctionnalité de repli optionnelle, c'est ce qui sauve l'expérience sur la moitié des réseaux.

### Découverte USB

`AdbWatcher` surveille en continu la sortie de `adb track-devices` (flux persistant, pas de polling). À chaque appareil qui apparaît :

1. `adb forward tcp:27183 tcp:27183`
2. tentative de connexion sur `127.0.0.1:27183`
3. si elle échoue, l'app n'est probablement pas lancée sur la tablette : proposer `adb shell am start -n app.sidebus/.MainActivity`

Localisation du binaire `adb` : PATH, puis `/opt/homebrew/bin`, `/usr/local/bin`, `~/Library/Android/sdk/platform-tools`. Si introuvable, l'indiquer clairement et basculer sur le Wi-Fi seul plutôt que d'échouer silencieusement.

### Arbitrage entre transports

Si le même `id` d'appareil est visible en USB et en Wi-Fi, **l'USB gagne toujours**. Il est plus rapide, plus stable, et il recharge la tablette.

La bascule se fait proprement : BYE avec code 1, fermeture, reconnexion sur le nouveau transport. Ne pas tenter une migration de socket à chaud, le gain ne vaut pas la complexité. Une interruption de 200 ms au branchement du câble est parfaitement acceptable.

---

## 8. Appairage et sécurité

En USB, le lien physique suffit. En Wi-Fi, n'importe qui sur le réseau peut se connecter à une tablette qui s'annonce, et recevoir en clair le contenu d'un écran. C'est inacceptable, il faut du chiffrement et de l'authentification dès la première version Wi-Fi.

Modèle retenu : **TLS avec certificat auto signé côté tablette et épinglage à l'appairage.** C'est le modèle SSH, éprouvé et implémentable des deux côtés sans dépendance lourde.

**Android (serveur).** Au premier lancement, génération d'une paire de clés dans l'Android Keystore et d'un certificat auto signé de longue durée. `SSLServerSocket` via un `KeyManager` personnalisé. TLS 1.3 uniquement.

**Mac (client).** `NWProtocolTLS` avec `sec_protocol_options_set_verify_block`. La vérification ne valide pas une chaîne de confiance (il n'y en a pas), elle compare le SHA-256 du certificat présenté à celui enregistré pour cet `id` dans le trousseau.

**Appairage.** À la première connexion à un `id` inconnu :

1. Les deux côtés dérivent un code à 6 chiffres du SHA-256 du certificat.
2. La tablette l'affiche, le Mac l'affiche.
3. L'utilisateur confirme qu'ils sont identiques.
4. Le Mac enregistre l'empreinte dans le trousseau, associée à l'`id`.

Aucun message de protocole supplémentaire : la comparaison est visuelle et hors bande. Si l'empreinte d'un appareil connu change, refuser la connexion et alerter, sans proposer de "continuer quand même" en un clic.

Le chiffrement reste actif en USB, pour n'avoir qu'un seul chemin de code à maintenir et tester. Le surcoût du TLS 1.3 avec AES-NI est négligeable devant l'encodage vidéo.

---

## 9. Phases

Chaque phase doit être fonctionnelle et testable seule avant de passer à la suivante. Ne pas anticiper.

### Phase 0 : socle

- Repo initialisé, deux projets qui compilent et ne font rien.
- Mac : package SwiftPM, cible macOS 14 minimum, app menu bar SwiftUI avec un menu vide.
- Android : projet Gradle, minSdk 30, une activité plein écran noire.
- `PROTOCOL.md` rédigé.

Validation : les deux projets se lancent.

### Phase 1 : cible d'affichage et harnais de développement

Pas de dongle HDMI, et pas encore notre propre `CGVirtualDisplay`. On utilise **DeskPad comme harnais de développement** : c'est une application, on la lance, elle crée un vrai écran virtuel que macOS traite comme n'importe quel moniteur, et on le capture.

Ce choix apporte trois choses :

- **Un vrai second écran dès le premier jour**, sans matériel et sans code. Les fenêtres qu'on y glisse disparaissent de l'écran principal, ce qui rend les phases 2 à 6 réalistes.
- **Le test de risque du projet, gratuit.** Si DeskPad se lance et crée un écran, c'est que `CGVirtualDisplay` fonctionne sur cette version de macOS. C'est précisément l'inconnue qui pouvait condamner Sidebus, et elle est levée en trente secondes. Si DeskPad échoue, arrêter et tout réévaluer avant d'écrire une ligne.
- **Un environnement sain pour la phase 5.** Injecter des événements souris dans l'écran qu'on est en train de capturer, quand c'est l'écran principal, est confus et risqué : le curseur injecté est le vrai curseur. Sur un écran séparé, le comportement est observable.

À faire :

- `DisplayEnumerator` : liste les `CGDirectDisplayID` via `CGGetActiveDisplayList`, avec bornes et résolutions. Alimente un sélecteur dans le menu bar.
- Abstraction `VirtualDisplayProvider`, avec pour l'instant une seule implémentation, `ExistingDisplayProvider`, qui ne crée rien et cible un écran déjà présent, qu'il soit physique ou créé par DeskPad. Elle restera ensuite comme mode dégradé si l'API privée casse sur une future version de macOS.
- Rien d'autre. Notre propre implémentation de `CGVirtualDisplay` arrive en phase 7, une fois la chaîne complète fonctionnelle.

Validation : DeskPad lancé, son écran virtuel apparaît dans le sélecteur du menu bar aux bonnes dimensions, et une fenêtre qu'on y glisse disparaît de l'écran principal. Refaire ce test sur chaque version majeure de macOS visée.

Piège à éviter : ne pas déplacer la fenêtre de DeskPad sur l'écran virtuel qu'elle recopie, ça produit un miroir infini. La laisser sur l'écran principal.

### Phase 2 : capture et encodage

- `ScreenCapturer` : `SCContentFilter` ciblant le `CGDirectDisplayID` choisi, `SCStreamConfiguration` avec :
  - `pixelFormat` en `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`
  - `minimumFrameInterval` à `CMTime(value: 1, timescale: 60)`
  - `queueDepth` à 3 (bas, pour la latence)
  - `showsCursor` à true
- Implémenter `SCStreamOutput`, vérifier le `SCStreamFrameInfoStatus` de chaque sample, ignorer `.idle` et `.blank`.
- `VideoEncoder` : `VTCompressionSession` H.264 avec :
  - `kVTCompressionPropertyKey_RealTime` = true
  - `kVTCompressionPropertyKey_AllowFrameReordering` = false (pas de B frames)
  - `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` = true
  - `kVTCompressionPropertyKey_MaxKeyFrameInterval` = 300
  - `kVTCompressionPropertyKey_AverageBitRate` = 15 000 000 par défaut
  - `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` = true
- Sortie temporaire : flux Annex B dans `/tmp/sidebus.h264`.

Validation : `ffplay /tmp/sidebus.h264` affiche l'écran capturé. CPU sous 10 % dans Activity Monitor.

### Phase 3 : protocole et transport USB

- `MessageCodec` des deux côtés, avec tests unitaires et vecteurs partagés. C'est le seul endroit du projet où un bug silencieux coûte une journée de recherche au mauvais endroit.
- Android : `TransportServer`, `ServerSocket` sur 27183, **en clair pour l'instant**, une seule connexion à la fois.
- Mac : `TransportClient` sur `NWConnection`, et `AdbWatcher` (track-devices, forward, lancement de l'app). **S'appuyer sur scrcpy** (Apache 2.0, voir section 5) pour toute cette plomberie adb, elle y est déjà résolue proprement, y compris les cas tordus de rebranchement et d'appareils multiples.
- Handshake HELLO / DEVICE_INFO, PING/PONG, affichage de la latence aller retour dans les logs.

Validation : branchement du câble, connexion automatique, latence affichée.

### Phase 4 : décodage et affichage

- `SurfaceView` plein écran. **Pas de `TextureView`**, elle ajoute systématiquement une frame de latence.
- `MediaCodec` en mode asynchrone (`setCallback`), configuré directement sur la `Surface`.
- `MediaFormat.KEY_LOW_LATENCY` à 1, `KEY_PRIORITY` à 0.
- SPS/PPS de VIDEO_CONFIG injectés via `csd-0`.
- Rendu : `releaseOutputBuffer(index, true)` immédiat, aucune file d'attente. En retard on drop, on ne bufferise jamais.
- Wake lock, mode immersif (`WindowInsetsController`), `setSustainedPerformanceMode(true)`.
- **Overlay de debug** : fps, latence, bitrate, frames droppées, transport actif. Indispensable pour tout le reste du projet, à faire maintenant et pas à la fin.

Validation : l'écran du Mac s'affiche sur la tablette en USB. Mesurer la latence réelle en filmant les deux écrans avec un chronomètre à l'image.

### Phase 5 : entrée tactile

- Android : `onTouchEvent` sur la `SurfaceView`, normalisation, envoi en INPUT_EVENT. ACTION_DOWN, ACTION_MOVE, ACTION_UP.
- Mac : `EventInjector`, remappage sur `CGDisplayBounds`, `CGEventCreateMouseEvent` et `CGEventPost(.cghidEventTap, event)`.
- Autorisation Accessibilité via `AXIsProcessTrustedWithOptions`, avec un onboarding clair si elle manque.

Validation : un toucher déplace le curseur et permet de cliquer une fenêtre.

### Phase 6 : Wi-Fi, découverte et appairage

La plus grosse phase. Le pipeline fonctionne déjà, on ajoute un second chemin pour établir le socket.

**Rappel de la section 5 :** Moonlight et Sunshine résolvent exactement ces problèmes, et sont en GPLv3. Les utiliser comme référence de comportement (installer Moonlight, observer son écran d'appairage, chronométrer sa reconnexion) est utile et légitime. Ouvrir leur code source pour écrire le nôtre ne l'est pas.

1. **TLS d'abord**, sur le transport USB existant, pour valider la couche de sécurité sur un lien déjà fiable. Génération du certificat côté Android, épinglage côté Mac, écran d'appairage à 6 chiffres.
2. **Annonce** : `ServiceAdvertiser` avec `NsdManager`, enregistrements TXT complets. Vérifier avec `dns-sd -B _sidebus._tcp` depuis le Mac avant d'écrire la moindre ligne de code côté Mac.
3. **Recherche** : `BonjourBrowser` avec `NWBrowser`, liste observable dans le menu bar. Ajouter `NSLocalNetworkUsageDescription` et `NSBonjourServices` dans l'Info.plist, et signer l'app, sinon rien ne remontera.
4. **Repli manuel** : affichage de l'IP côté tablette, saisie manuelle côté Mac.
5. **Arbitrage** : `PeerRegistry` fusionne les résultats USB et Wi-Fi par `id`, USB prioritaire, bascule par BYE code 1 puis reconnexion.

Validation : tablette et Mac sur le même Wi-Fi, la tablette apparaît seule dans le menu, appairage en 6 chiffres, affichage. Puis branchement du câble : bascule automatique en USB, visible dans l'overlay. Débranchement : retour au Wi-Fi.

### Phase 7 : écran virtuel intégré

Remplacement du harnais DeskPad par notre propre implémentation, en cours de processus. L'API est déjà validée depuis la phase 1, il ne reste que l'intégration.

- Header de pont repris de DeskPad (MIT, voir section 5), avec attribution.
- `CGVirtualDisplayProvider` : descripteur configuré avec le nom, la taille physique en mm (calculée pour obtenir la bonne densité), et une liste de `CGVirtualDisplayMode` incluant le mode HiDPI (`pixelsWide` et `pixelsHigh` au double de `width` et `height`).
- **Création à la demande** : l'écran est créé à la connexion d'une tablette et détruit à la déconnexion. Un écran fantôme qui persiste sans tablette branchée perturbe l'agencement des fenêtres de l'utilisateur, c'est le reproche principal fait à ce type d'outil.
- **Résolution dérivée de DEVICE_INFO** plutôt que fixée en dur. C'est ce que le harnais DeskPad ne permettait pas de faire, et c'est la vraie valeur ajoutée d'une implémentation intégrée : l'écran virtuel épouse exactement la dalle de la tablette.
- `ExistingDisplayProvider` reste en place comme mode dégradé.

Validation : DeskPad arrêté et désinstallé. L'écran apparaît dans Réglages > Moniteurs au lancement de la tablette, à sa résolution native, et disparaît proprement à la déconnexion. Vérifier que l'agencement des fenêtres de l'utilisateur est restauré.

### Phase 8 : adaptation et robustesse

Le Wi-Fi rend cette phase obligatoire, elle n'est plus du confort.

- **Frame rate adaptatif** : gain le plus important. ScreenCaptureKit ne livre une frame que sur changement, il faut en profiter. Écran statique = zéro encodage, pas 60 fps de frames identiques.
- **Bitrate adaptatif** : surveiller le remplissage du buffer d'envoi et les STATS reçus, ajuster `AverageBitRate` via `VTSessionSetProperty`. Profils différents par transport : agressif en USB, prudent en Wi-Fi.
- **Keyframe à la demande** : sur KEYFRAME_REQ, forcer via `kVTEncodeFrameOptionKey_ForceKeyFrame`.
- **HEVC** si le bitmask de DEVICE_INFO l'indique. 30 à 40 % de débit en moins, ce qui compte beaucoup en Wi-Fi.
- **Résolution négociée** : réglage 1x / 0.75x / 0.5x, avec un défaut plus bas en Wi-Fi.
- **Reconnexion** : coupure Wi-Fi, mise en veille de la tablette, changement de réseau. Reconnexion automatique avec backoff exponentiel, sans redemander l'appairage.
- **Throttling thermique** : détecter les droppes répétées via STATS et baisser le fps avant que ça ne devienne visible.

### Phase 9 : packaging

- Signature Developer ID et notarisation. **App Store exclu** à cause de `CGVirtualDisplay`, distribution hors store uniquement.
- Entitlements et usage descriptions : Screen Recording, Réseau local.
- Onboarding guidé pour les autorisations TCC (Enregistrement de l'écran, Accessibilité, Réseau local). Elles ne prennent effet qu'après relance de l'app, il faut le gérer explicitement.
- Sparkle ou équivalent pour les mises à jour.
- APK signé, distribution directe ou Play Store (aucun blocage de ce côté).

### Plus tard, hors v1

- **AOA (Android Open Accessory)** : le Mac agit en hôte USB via libusb, bascule la tablette en mode accessoire, échange sur les endpoints bulk. Avantage décisif : aucune option développeur à activer, et l'app se lance automatiquement au branchement. Débit plus limité qu'ADB sur certains appareils, à mesurer avant de s'engager.
- **UDP avec FEC** pour le Wi-Fi, afin d'éliminer le head of line blocking du TCP. Gain réel mais complexité forte, à ne considérer qu'avec des mesures qui le justifient.
- Pression du stylet, qui nécessite un pilote `HIDDriverKit` émulant un digitizer.

---

## 10. Points de vigilance

**Autorisation Réseau local sur macOS 15+.** Sans `NSLocalNetworkUsageDescription`, `NSBonjourServices` et une signature valide, `NWBrowser` ne renvoie rien et n'émet aucune erreur exploitable. C'est le premier endroit à vérifier si la découverte ne marche pas.

**NsdManager.** Inégal selon les constructeurs, et beaucoup de réseaux bloquent le multicast. Le repli par IP manuelle n'est pas optionnel.

**Isolation des clients Wi-Fi.** Énormément de box et de réseaux d'entreprise isolent les clients entre eux. Aucun code ne peut contourner ça, il faut un message d'erreur qui l'explique au lieu d'un timeout muet.

**API privée.** `CGVirtualDisplay` peut casser à chaque macOS majeur, et c'est la dépendance la plus fragile du projet. Tout passe par `VirtualDisplayProvider`, jamais d'appel direct disséminé dans le code. En cas d'échec de l'initialisation : détection explicite, bascule automatique sur `ExistingDisplayProvider` (recopie d'un écran physique), et message clair à l'utilisateur. Jamais de crash, jamais d'écran noir inexpliqué. Tester sur chaque bêta de macOS dès leur sortie, c'est le seul moyen de ne pas être pris de court à la rentrée de septembre.

**Autorisations TCC.** Screen Recording et Accessibility ne prennent effet qu'après relance. Ne pas boucler sur une vérification qui ne passera jamais dans la session courante.

**Latence cachée.** Coupables habituels, par fréquence : `TextureView` au lieu de `SurfaceView`, une file d'attente côté décodeur, les B frames, un `queueDepth` trop élevé, l'algorithme de Nagle (mettre `TCP_NODELAY`).

**Thermique.** Le mode de défaillance typique n'apparaît qu'après 20 à 40 minutes d'usage continu, jamais dans un test de cinq minutes. Prévoir une session longue dans les tests manuels, dans les deux modes de transport.

**HiDPI.** Un mode HiDPI se déclare avec `pixelsWide` et `pixelsHigh` au double de `width` et `height`. Se tromper là donne un affichage flou ou une interface minuscule.

---

## 11. Conventions

- Swift : async/await partout, pas de complétions imbriquées. Un acteur par composant détenant de l'état mutable. Aucune dépendance externe.
- Kotlin : coroutines, `Dispatchers.IO` pour le transport, callbacks MediaCodec sur un `HandlerThread` dédié. Dépendances minimales.
- Logs structurés avec niveaux. L'overlay de debug côté tablette affiche en permanence : fps, latence, bitrate, frames droppées, transport actif.
- Tests unitaires obligatoires sur `MessageCodec` des deux côtés, avec les vecteurs partagés de `protocol/testvectors/`.
- Toute logique de transport passe par les abstractions `Transport` et `PeerDiscovery`. Aucun code métier ne doit savoir s'il tourne en USB ou en Wi-Fi.
- Aucune dépendance tierce sans justification explicite et validation préalable. Tout code repris d'un projet externe est signalé en tête de fichier et recensé dans `THIRD_PARTY.md`, avec sa licence.

---

## 12. Ordre de travail demandé

Commence par la phase 0, puis attends validation avant d'enchaîner. À chaque phase :

1. Annonce ce que tu vas faire et les fichiers que tu vas créer.
2. Implémente.
3. Indique précisément comment tester, avec les commandes exactes.
4. N'anticipe pas sur la phase suivante.

Si une décision technique n'est pas tranchée dans ce document, pose la question plutôt que de choisir seul.
