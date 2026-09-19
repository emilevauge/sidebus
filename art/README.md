# Identité visuelle

Un bus vu de face, strictement symétrique, plat, contours arrondis. Le
pare-brise est traité comme une dalle d'écran : c'est ce que fait Sidebus,
recopier l'écran d'un Mac sur une tablette.

Dessin original écrit à la main en SVG. Les fichiers n'utilisent que des
`path`, sans `rect` ni `circle`, pour que la conversion en VectorDrawable
Android reste directe.

## Sources

| Fichier | Rôle |
| --- | --- |
| `bus-app.svg` | Icône d'application en couleur, carré de 1024. La plaque arrondie fait 824 sur 1024 : la marge exigée par le gabarit d'icône macOS. |
| `bus-template.svg` | Silhouette monochrome de la barre de menus, au repos. Noir plein sur fond transparent. |
| `bus-template-actif.svg` | Même silhouette, partage en cours : la dalle est pleine au lieu d'être évidée. |

Les deux gabarits sont simplifiés par rapport à l'icône couleur. À 18 points,
la girouette de destination, les tiges de rétroviseur et le pare-chocs ne
tiennent pas : ils deviennent une bouillie grise. Ils ont donc sauté, les
rétroviseurs sont collés à la caisse, et les phares ont été agrandis pour
rester visibles.

Palette : plaque bleu nuit `#2A3A7A` vers `#111A3C`, caisse ambre `#FFC43D`,
dalle `#5793F5`, garnitures `#1B2647`, roues `#5A6796`, phares `#FFF3CE`.

## Régénérer

```sh
art/build.sh
```

Le script demande `rsvg-convert` (`brew install librsvg`) et `iconutil`. Il
écrit :

- `mac/Resources/Sidebus.icns`, iconset complet 16 à 512 en 1x et 2x,
  assemblé par `iconutil` ; le bundle le déclare via `CFBundleIconFile` et
  `mac/Scripts/bundle.sh` le copie dans `Contents/Resources` ;
- `mac/Sources/SidebusApp/Resources/MenuBar.pdf` et `MenuBarActif.pdf`. En PDF
  et non en PNG : `NSImage` charge un PDF en vectoriel, donc le même fichier
  sert en 1x et en 2x. `MenuBarIcon` les lit via `Bundle.module` et les marque
  `isTemplate`, ce qui les fait s'inverser en mode sombre.

## Android

Les icônes Android ne sont pas régénérées par le script : ce sont des
VectorDrawable convertis à la main depuis les mêmes SVG, une fois. Les
coordonnées restent celles du dessin, dans un repère de 1024, et un `<group>`
les ramène à l'échelle dans la toile de 108 dp.

- `android/app/src/main/res/drawable/ic_launcher_foreground.xml` reprend les
  chemins de `bus-app.svg` sans la plaque de fond ;
- `.../drawable/ic_launcher_monochrome.xml` reprend `bus-template.svg` pour les
  icônes thématiques ;
- `.../values/ic_launcher_background.xml` porte le fond, une couleur plate ;
- `.../mipmap-anydpi-v26/ic_launcher.xml` et `ic_launcher_round.xml` assemblent
  le tout. minSdk vaut 30, donc aucun PNG hérité.

Zone de sécurité : le système rogne, seuls les 66 dp centraux d'une toile de
108 dp sont toujours visibles, et certains masques sont ronds. Le point du
dessin le plus éloigné du centre est à 413 dans le repère 1024, soit 35 dp à
l'échelle retenue, donc à l'intérieur du masque circulaire de 36 dp de rayon.
Si le dessin change, recalculer cette échelle avant de toucher au `<group>`.
