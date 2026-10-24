# LocalFlow for iPhone app icon

`AppIcon.svg` is the editable vector source. It is the Wilderness Labs ridge
mark from the wilderness-labs-site repository (`public/favicon.svg`): an aurora
green (`#6DFFA8`) W-shaped ridge line over a glacier cyan (`#67E8F9`) dot, on a
forest-night (`#0A1114` to `#05080A`) square with a faint aurora glow. The
development variant, `AppIcon-Dev.svg`, adds a small ember (`#F5C66B`) badge.
Both are full-bleed 1024 squares, because iOS applies its own mask, and use no
external assets or fonts. The macOS app keeps its own icon in `../Resources/`.

The committed 1024-pixel PNG exports feed the Makefile, which flattens them
into the compiled asset catalog. After editing the SVGs, export them with an
SVG renderer; for example, with `rsvg-convert` installed, from `iOS/`:

```sh
rsvg-convert -w 1024 -h 1024 -o Resources/AppIcon-Source.png Resources/AppIcon.svg
rsvg-convert -w 1024 -h 1024 -o Resources/AppIcon-Dev-Source.png Resources/AppIcon-Dev.svg
```

Commit the SVGs and PNG exports together, and check the masked rendering on
the Home Screen and at Settings and Spotlight sizes.
