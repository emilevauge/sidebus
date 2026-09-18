# Code tiers

Recense tout code repris d'un projet externe, avec sa licence, conformément à la section 5
de `PLAN.md`. Chaque fichier concerné porte aussi l'avis de copyright d'origine en tête.

## Code repris

### DeskPad, licence MIT

`https://github.com/Stengo/DeskPad`, copyright (c) 2022 Stengo.

`Sources/CGVirtualDisplayBridge/include/CGVirtualDisplayBridge.h` reprend les déclarations
des classes privées de CoreGraphics qui créent un écran virtuel. L'avis de copyright et le
texte de licence MIT figurent en tête du fichier.

DeskPad a aussi servi de harnais de développement des phases 1 à 6, lancé tel quel sans
modification. Le simple fait de lancer une application n'impose rien ; seule la reprise de
code ci dessus est concernée.

## Code non repris

### scrcpy, licence Apache 2.0

`https://github.com/Genymobile/scrcpy`

La plomberie adb de Sidebus (`AdbWatcher`) parle directement au serveur adb sur le port
5037 avec le service `host:track-devices`. Elle a été écrite à partir du protocole adb, pas
copiée depuis scrcpy. Les choix de latence de scrcpy ont en revanche inspiré ceux du plan :
pas de B frames, aucune file d'attente au rendu, `SurfaceView` et jamais `TextureView`,
`TCP_NODELAY`.

Le binaire `adb` n'est pas redistribué : Sidebus utilise celui du système.

### Moonlight et Sunshine, licence GPLv3

Aucun code repris, aucun fichier source consulté. Copyleft viral : intégrer la moindre
portion obligerait à publier Sidebus sous GPLv3.
