# Sidebus

Sidebus transforme une tablette Android en écran secondaire pour un Mac.

Le Mac déclare un écran virtuel, capture son framebuffer, l'encode en H.264/HEVC et le
transmet à la tablette, qui le décode et l'affiche. Les touchers de la tablette remontent
vers le Mac et sont injectés comme des événements souris. Deux transports : USB via un
tunnel adb, et Wi-Fi avec découverte mDNS.

- `PLAN.md` : le plan de développement, à lire avant d'écrire du code.
- `protocol/PROTOCOL.md` : le format sur le fil, source de vérité partagée entre les deux côtés.

État : **phases 0 à 9 faites**. Sidebus crée un écran virtuel aux dimensions de la
tablette, le capture, l'encode en H.264 ou HEVC matériel, le transmet en TLS 1.3 sur USB ou
Wi-Fi, et l'affiche sur la tablette dont les touchers reviennent en événements souris. Le
débit et la cadence s'ajustent à ce que la tablette rapporte.

## macOS

Prérequis : macOS 14 minimum, Xcode ou les outils en ligne de commande avec Swift 6.

```sh
cd mac
swift build            # compile
swift test             # tests unitaires
swift run SidebusApp   # lance l'app directement, sans bundle
./Scripts/bundle.sh    # construit et signe mac/build/Sidebus.app
open build/Sidebus.app # lance le bundle
```

L'application n'a pas d'icône dans le Dock, elle apparaît dans la barre de menus.

Le script signe avec la première identité de signature du trousseau, et retombe sur l'ad hoc
s'il n'en trouve aucune. La différence compte pour TCC, qui mémorise les autorisations
(Enregistrement de l'écran, Accessibilité, Réseau local) par règle de signature :

- ad hoc : `identifier "app.sidebus" and cdhash H"..."`, qui change à chaque recompilation,
  donc l'autorisation est perdue à chaque build
- identité : `identifier "app.sidebus" and certificate leaf = H"..."`, stable

Forcer un choix avec `SIDEBUS_CODESIGN_IDENTITY`. Developer ID et notarisation en phase 9.

Si une autorisation reste bloquée après un changement de signature :
`tccutil reset ScreenCapture app.sidebus`, puis relancer.

### Harnais de développement

Jusqu'à la phase 7, l'écran à capturer vient de [DeskPad](https://github.com/Stengo/DeskPad),
lancé à côté et non modifié :

```sh
brew install --cask deskpad
open -a DeskPad
```

Son écran virtuel apparaît alors dans le sélecteur de Réglages > Vidéo. Ne pas déplacer la
fenêtre de DeskPad sur l'écran qu'elle recopie, ça produit un miroir infini.

### Capture (phase 2)

Dans Réglages > Vidéo : choisir un écran, puis « Enregistrer le flux dans un fichier ».
macOS demande
l'autorisation Enregistrement de l'écran au premier essai ; elle ne prend effet qu'après
relance de l'application. Le flux part dans `/tmp/sidebus.h264`, relisible avec :

```sh
ffplay /tmp/sidebus.h264
```

Réglages de l'encodeur : H.264 matériel, temps réel, sans B frames, contrôle de débit basse
latence, 15 Mbit/s, keyframe toutes les 300 frames.

Crochets de développement, pour mesurer sans passer par le menu :

```sh
open --env SIDEBUS_AUTOCAPTURE=DeskPad \
     --env SIDEBUS_CAPTURE_SCALE=0.5 \
     --env SIDEBUS_FPS=30 \
     mac/build/Sidebus.app
```

`SIDEBUS_AUTOCAPTURE` démarre la capture au lancement sur le premier écran dont le nom
contient la valeur donnée, et écrit une trace dans `/tmp/sidebus-debug.log`.

Benchmark du seul chemin d'encodage :

```sh
cd mac && SIDEBUS_BENCH=1 swift test -c release --filter EncoderBenchmark
```

## Android

Prérequis : le SDK Android, avec la plateforme 36 et un JDK 17 ou plus récent.
`android/local.properties` doit pointer sur le SDK (`sdk.dir=...`), il n'est pas versionné.

```sh
cd android
./gradlew assembleDebug           # compile l'APK
./gradlew installDebug            # installe sur l'appareil branché
adb shell am start -n app.sidebus/.MainActivity
```

minSdk 30, cible la tablette en paysage. L'application écoute sur le port 27183 : c'est la
tablette qui est le serveur, en USB comme en Wi-Fi.

## Transport USB

Rien à faire : brancher le câble suffit. Le Mac suit le flux `host:track-devices` du serveur
adb, pose `adb forward tcp:27183 tcp:27183`, se connecte et envoie HELLO. Si la tablette ne
répond pas de DEVICE_INFO, c'est que l'application n'est pas au premier plan : le Mac la
lance avec `adb shell am start` et réessaie.

L'état et la latence s'affichent dans le menu. Pour les suivre en détail :

```sh
log stream --predicate 'subsystem == "app.sidebus"' --level debug --style compact
```

Crochets de développement : `SIDEBUS_AUTO_PAIR=1` accepte l'appairage côté Mac sans
dialogue, `SIDEBUS_DISABLE_USB=1` force la branche Wi-Fi, `SIDEBUS_MANUAL_PEER=hôte:port`
préremplit une adresse.

Faute de tablette, un émulateur suffit à exercer tout le chemin, il apparaît comme un
appareil adb :

```sh
~/Library/Android/sdk/emulator/emulator -avd <nom> &
cd android && ./gradlew installDebug
```

## Écran virtuel

À la connexion, Sidebus crée un écran virtuel à la résolution et à la densité annoncées par
la tablette, et le détruit à la déconnexion. Un écran fantôme qui persiste dérange
l'agencement des fenêtres, c'est le reproche principal fait à ce genre d'outil.

Les classes utilisées sont privées et peuvent disparaître à n'importe quelle version de
macOS. L'échec est détecté explicitement : Sidebus recopie alors un écran existant et le
signale dans le menu, sans jamais planter ni afficher un écran noir inexpliqué. Choisir un
écran dans le menu force ce mode.

La taille physique déclarée, en millimètres, est calculée pour obtenir la densité voulue,
et le mode est déclaré en points avec `hiDPI` à 1. Se tromper là donne un affichage flou ou
une interface minuscule.

## Adaptation

La tablette envoie ses compteurs toutes les deux secondes. Le Mac en déduit le débit :
baisse franche dès 15 % de frames droppées, remontée de 10 % après six secondes calmes.
Profils différents par transport, généreux en USB, prudent en Wi-Fi. Si le débit plancher
ne suffit toujours pas, c'est le décodeur ou la chaleur qui limitent, pas le réseau : la
cadence tombe alors à 30 fps.

Quand la tablette perd le fil, elle demande une keyframe et **cesse d'alimenter son
décodeur** en attendant : continuer à lui donner des frames intermédiaires sans leur
référence produit des blocs verts et magenta qui persistent. Le Mac répond en réencodant
immédiatement la dernière image, sans quoi un écran immobile laisserait la tablette
corrompue jusqu'au prochain mouvement. L'intervalle maximal entre keyframes est exprimé en
secondes et non en frames : 300 frames à 7 fps font 43 secondes d'image cassée.

**HEVC est retenu dès que la tablette l'annonce.** Mesuré sur un Xiaomi 15, décodeur
matériel Qualcomm : 0,5 Mbit/s contre 1,4 en H.264 sur le même contenu, à 57 et 60 fps,
décodage 6 à 7 ms, sans frame perdue.

Attention aux décodeurs logiciels. Celui de l'émulateur Android rend des chromas cassées en
HEVC, blocs verts et magenta, là où H.264 passe parfaitement sur le même montage.
`SIDEBUS_CODEC=h264` force le repli.

## Où passe le travail

Rien de lourd ne touche le CPU. La capture, la mise à l'échelle et la conversion de format
se font dans le chemin graphique du système, l'encodage sur le moteur média dédié, et côté
tablette le décodage matériel écrit directement dans la `Surface`, composée sans copie. Il
ne faut surtout pas insérer d'étape GPU à la main dans ce chemin : rendre dans une texture
au lieu d'une `SurfaceView` ajouterait une frame de latence.

Ce qui reste sur CPU ne concerne que des octets déjà compressés :

- la conversion vers Annex B se fait **sur place**. Le préfixe de longueur AVCC et le code
  de départ font tous deux quatre octets, il suffit donc de réécrire les quatre octets de
  longueur, sans allouer.
- le tampon de réception côté Android travaille par déplacement d'index, et le socket est
  lu directement dedans. La version naïve recopiait tout l'en cours à chaque paquet : une
  frame arrivant en plusieurs morceaux se payait autant de recopies complètes. Mesuré sur
  un Xiaomi 15 sous charge : 28,5 % de CPU avant, 25,0 % après.
- une frame sans rectangle modifié n'est pas encodée du tout. Écran immobile : 0,4 % de CPU
  sur le Mac, 0,3 % sur le téléphone.

## Rendu côté tablette

`MediaCodec` en mode asynchrone, configuré directement sur la `Surface`, avec
`KEY_LOW_LATENCY` et `KEY_PRIORITY` à 0. Le rendu est immédiat : `releaseOutputBuffer` dès
la sortie du décodeur, aucune file d'attente. Quand aucun buffer d'entrée n'est libre, la
frame est jetée plutôt que mise en attente, à une exception près : une keyframe obtient une
courte fenêtre d'attente, parce qu'elle est le seul point de reprise et que la suivante peut
être à cinq secondes.

L'overlay des compteurs est **masqué par défaut** : ces chiffres servent à diagnostiquer,
pas à rester en travers de l'écran partagé. Pour l'afficher :

```sh
adb shell settings put global sidebus_overlay 1   # 0 pour le cacher
```

Le réglage est relu à chaque retour au premier plan, sans relancer l'application. La vue
continue de compter même invisible : c'est elle qui alimente les messages STATS.

Elle se rafraîchit à 4 Hz. La mettre à jour à chaque frame coûterait plus cher que tout le
reste du pipeline, comme mesuré côté Mac en phase 2.

Deux pièges rencontrés, à ne pas réintroduire :

- le décodeur doit être créé **synchronement** à la réception de VIDEO_CONFIG. Créé en
  différé, il rate la keyframe qui suit immédiatement et reste bloqué sur des frames
  intermédiaires inexploitables.
- passer la `SurfaceView` en `INVISIBLE` détruit sa surface, qui n'est jamais recréée
  ensuite. Pour masquer l'image, poser une vue noire par dessus.
- ne pas effacer la surface avec `lockCanvas` : cela la connecte au producteur CPU et
  `MediaCodec` ne peut plus s'y attacher, `configure` échoue alors avec un
  `IllegalArgumentException` opaque (`surfaceConnectWithListener ... Invalid argument`).
- un décodeur qui refuse de se configurer ne doit pas emporter la connexion : l'exception
  remontait jusqu'à la boucle de lecture et fermait le lien.

## Transport Wi-Fi et appairage

La tablette s'annonce en mDNS sous `_sidebus._tcp` dès qu'elle est au premier plan, avec sa
résolution, ses codecs et l'empreinte de son certificat. Le Mac la trouve avec `NWBrowser`
et se connecte directement à l'endpoint publié, sans résoudre l'adresse à la main.

À la première connexion, les deux côtés affichent le même code à six chiffres, dérivé de
l'empreinte du certificat, et **les deux doivent confirmer**. Le Mac demande le premier,
pendant le handshake TLS puisque c'est là qu'il découvre l'empreinte ; il envoie ensuite
PAIR_REQUEST et la tablette demande à son tour. Rien n'est enregistré avant les deux
accords, donc un refus d'un côté ne laisse aucune trace de l'autre. Si l'empreinte change
pour un appareil connu, la connexion est refusée.

Trois choses à savoir, toutes rencontrées pendant l'implémentation :

- la clé du Keystore doit autoriser le digest `NONE`. En TLS 1.3, Conscrypt hache lui même
  puis demande une signature ECDSA brute ; sans ce digest, le Keystore refuse
  (`INCOMPATIBLE_DIGEST`) et le handshake meurt sans alerte, ce qui ressemble à une panne
  réseau.
- une tablette annoncée mais injoignable, cas d'un réseau qui isole ses clients, ne renvoie
  rien du tout : ni acceptation, ni refus. La connexion est donc bornée à huit secondes et
  le message d'erreur explique la cause probable.
- `NWConnection.connect()` doit être annulable, sinon le délai ci dessus ne sert à rien :
  un groupe de tâches attend ses enfants à la sortie, et une tâche bloquée dans une
  continuation ignore l'annulation.

Sur les réseaux où le multicast ne passe pas, le menu propose « Connexion par adresse IP »,
et la tablette affiche son adresse.

## Appareils et partage

Le menu liste les appareils sous « Appareils », avec une icône qui porte l'état : lien à
appairer, écran à partager, carré d'arrêt pendant la diffusion, sablier tant que la
connexion se monte, tablette barrée hors ligne. Un clic sur la ligne fait la seule chose
qu'elle propose.

Rien ne se diffuse sans un geste. Une seule exception, voulue : un appareil dont le partage
était actif reprend tout seul quand il réapparaît, sinon rebrancher un câble demanderait de
rouvrir le menu à chaque fois. Arrêter le partage retire cette intention, et la coupure
depuis le Centre de contrôle de macOS compte comme un arrêt.

Le partage vers plusieurs tablettes en parallèle est prévu par construction : chaque
appareil a sa session, son écran virtuel, son encodeur et son contrôleur de débit, sans
état commun à arbitrer. Le coût CPU s'additionne.

Réglages > Appareils liste les appairés, y compris hors ligne, et permet d'en oublier un ou
tous.

## Tactile

Les touchers de la vue vidéo partent en INPUT_EVENT, en coordonnées normalisées sur la vue
et non sur l'écran de la tablette : le flux garde son rapport d'aspect et peut être bordé de
bandes noires, c'est l'image qui fait référence. Le Mac les remappe sur
`CGDisplayBounds` de l'écran capturé et poste l'événement avec `CGEventPost`.

Un déplacement entre un appui et un relâchement devient un glissement, pas un simple
mouvement de curseur, sinon rien ne se déplace ni ne se sélectionne.

**Autorisation Accessibilité obligatoire.** Sans elle, `CGEventPost` est ignoré sans erreur :
les touchers arrivent bien au Mac, ils ne produisent simplement rien. Réglages >
Confidentialité et sécurité > Accessibilité, activer Sidebus, puis **relancer
l'application** : l'autorisation ne prend effet qu'au lancement suivant. La ligne de
l'appareil signale l'absence d'autorisation pendant la diffusion.

## Distribution

```sh
cd mac
SIDEBUS_DEVELOPER_ID="Developer ID Application: … (TEAMID)" \
SIDEBUS_NOTARY_PROFILE=sidebus \
./Scripts/release.sh
```

Le script construit, signe avec le runtime renforcé, fabrique une image disque, la notarise
et l'agrafe. L'App Store est exclu : `CGVirtualDisplay` est une API privée.

Côté Android, `./gradlew assembleRelease` produit un APK signé si `sidebus.keystore` et les
mots de passe associés sont fournis en propriétés Gradle ou en variables d'environnement,
sinon un APK non signé. Aucun secret dans le dépôt.

Réglages > Autorisations montre l'état des trois autorisations TCC, ouvre le bon panneau
des Réglages système et sait relancer l'application, puisqu'elles ne prennent effet qu'au
lancement suivant.

## Protocole

`protocol/PROTOCOL.md` décrit le format sur le fil, `protocol/testvectors/` en contient les
vecteurs binaires. Les tests des deux côtés les décodent, vérifient les champs, réencodent
et comparent octet à octet. Toute évolution du format se fait dans `PROTOCOL.md` d'abord,
puis `python3 protocol/testvectors/generate.py`, puis les deux côtés dans la même commit.
