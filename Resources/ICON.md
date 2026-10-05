# LocalFlow app icon

`AppIcon.svg` is the editable vector source. Nine rounded audio bars form two
soft pulses, with a restrained mint gradient on a midnight blue tile. Small
pupil dots inside the two tallest bars give the waveform a subtle pair of eyes. The
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
icon's matching menu-bar glyph is drawn as a resolution-independent AppKit
template in `Sources/MenuBarIcon.swift`. It uses the same nine bar heights and
paired pupil proportions, with transparent pupil cutouts so macOS can tint it
for light, dark, and highlighted backgrounds. The development glyph has a small
upper-right badge. Recording and transcription retain their existing status
symbols. `MenuBarIcon.svg` and `MenuBarIcon-Dev.svg` are vector previews of the
idle glyph; no SVG renderer or resource loading is needed at runtime.
