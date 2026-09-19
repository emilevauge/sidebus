# Visual identity

A bus seen head on, strictly symmetrical, flat, with rounded edges. The
windscreen is treated as a display panel: that is what Sidebus does, put a
Mac's screen on a tablet.

Original drawing, written by hand in SVG. The files use nothing but `path`
elements, no `rect` and no `circle`, so that converting them to an Android
VectorDrawable stays direct.

## Sources

| File | Role |
| --- | --- |
| `bus-app.svg` | Colour app icon, on a 1024 square. The rounded plate is 824 of 1024: the margin the macOS icon template asks for. |
| `bus-template.svg` | Monochrome menu bar silhouette, at rest. Solid black on a transparent background. |
| `bus-template-active.svg` | Same silhouette, sharing in progress: the panel is filled instead of hollow. |

Both templates are simpler than the colour icon. At 18 points the destination
blind, the mirror stalks and the bumper do not survive: they turn into grey
mush. So they went, the mirrors sit flush against the body, and the headlights
were enlarged to stay visible.

Palette: night blue plate `#2A3A7A` to `#111A3C`, amber body `#FFC43D`, panel
`#5793F5`, trim `#1B2647`, wheels `#5A6796`, headlights `#FFF3CE`.

## Regenerating

```sh
art/build.sh
```

The script needs `rsvg-convert` (`brew install librsvg`) and `iconutil`. It
writes:

- `mac/Resources/Sidebus.icns`, a full iconset from 16 to 512 in 1x and 2x,
  assembled by `iconutil`; the bundle declares it through `CFBundleIconFile`
  and `mac/Scripts/bundle.sh` copies it into `Contents/Resources`;
- `mac/Sources/SidebusApp/Resources/MenuBar.pdf` and `MenuBarActive.pdf`. PDF
  rather than PNG: `NSImage` loads a PDF as vector art, so one file serves both
  1x and 2x. `MenuBarIcon` reads them through `Bundle.module` and marks them
  `isTemplate`, which is what makes them invert in dark mode.

## Android

The script does not regenerate the Android icons: those are VectorDrawables
converted by hand from the same SVGs, once. The coordinates stay those of the
drawing, on a 1024 grid, and a `<group>` scales them into the 108 dp canvas.

- `android/app/src/main/res/drawable/ic_launcher_foreground.xml` takes the
  paths of `bus-app.svg` without the background plate;
- `.../drawable/ic_launcher_monochrome.xml` takes `bus-template.svg` for themed
  icons;
- `.../values/ic_launcher_background.xml` carries the background, a flat colour;
- `.../mipmap-anydpi-v26/ic_launcher.xml` and `ic_launcher_round.xml` put it all
  together. minSdk is 30, so no legacy PNG is needed.

Safe zone: on a 108 dp canvas, only the central 66 dp disc is guaranteed
visible, which is **33 dp of radius**. That is the number that counts, not the
36 dp of the largest possible round mask.

The drawing is scaled so that its point furthest from the centre lands at
30.5 dp. That margin is not a luxury: some launchers, MIUI in particular,
enlarge third party icons on top of the mask. A first version pinned at 33.9 dp,
right on the limit, had its wheels sliced off on a Xiaomi.

If the drawing changes, recompute the `<group>` scale and translation from the
centre of the bounding box and the maximum radius:

```
scale = 30.5 / max_radius
translateX = 54 - centre_x * scale
translateY = 54 - centre_y * scale
```
