# LocalFlow app icon

`AppIcon.svg` is the editable vector source. Nine rounded audio bars form two
soft pulses, with a restrained mint gradient on a midnight blue tile. The
development variant, `AppIcon-Dev.svg`, adds a small amber badge. Both use a
1024-square viewBox, transparent outer margins, and no external assets or fonts.

The committed 1024-pixel PNG exports feed the existing Make/iconutil pipeline,
so building the app needs no new dependency. After editing the SVGs, export
them with an SVG renderer; for example, with `rsvg-convert` installed:

```sh
rsvg-convert -w 1024 -h 1024 -o Resources/AppIcon-Source.png Resources/AppIcon.svg
rsvg-convert -w 1024 -h 1024 -o Resources/AppIcon-Dev-Source.png Resources/AppIcon-Dev.svg
make icon
make icon APP_NAME=LocalFlow
```

Commit the SVGs, PNG exports, and both ICNS files together. Check the actual
rendering at 16, 32, 64, and 128 pixels on light and dark backgrounds. The app
icon is independent of the existing monochrome menu-bar status symbol.
