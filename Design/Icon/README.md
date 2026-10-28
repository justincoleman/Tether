# Tether — Connected prompt

## Included
- `macOS/Tether.icns`: packaged Dock/Finder icon, 16–1024 pixels.
- `macOS/AppIcon.appiconset`: macOS Xcode asset catalog icon set.
- `macOS/Tether.iconset`: complete source PNGs for iconutil.
- `iOS/AppIcon.appiconset`: 1024-pixel default, dark, and tinted grayscale appearances. Opaque, square, no baked corner mask. Xcode generates smaller sizes.
- `MenuBar/TetherMenuBar.imageset`: 22-point template image, 1× and 2×. A supplemental 3× PNG is included but not referenced by the macOS asset catalog.
- `MenuBar/TetherMenuBar.pdf`: vector template, 22 × 22 points.
- `Source/`: editable SVG artwork and the reproducible native renderer.
- `IconComposer-Layers/`: 1024-pixel background and transparent foreground inputs for Icon Composer.
- `Tether-Preview.png`: visual contact sheet; iOS corners here are for presentation only.

## Use
Import the appropriate AppIcon.appiconset into each target’s asset catalog. Both platform sets use the standard name AppIcon; keep them in their respective target catalogs. Add TetherMenuBar.imageset to the Mac target’s catalog. Its template intent is already set. For manually loaded PDF/PNG images, set NSImage.isTemplate = true and use a 22 × 22 point image size. macOS supplies the light/dark tint; the white reverse shown in the preview is not a separate production image.

The .icns and asset catalogs are static icon exports. The layer inputs are provided for an optional Icon Composer workflow; this package does not contain a compiled .icon project or authored Liquid Glass clear variants.

## Design
Navy background: #233D60 → #0C1D33 → #050E18.
Mint mark: #C4FFED → #51FBD4 → #12C6B6.
The menu bar version is optically simplified and drawn separately at 22 points.
The selected concept was rebuilt as vector geometry; production exports are not crops of the AI concept sheet.

## Rebuild
Run `swift Source/Render.swift /absolute/path/to/Tether-Icon-Suite` with the package folders present, then `iconutil -c icns macOS/Tether.iconset -o macOS/Tether.icns` from this directory. The renderer uses native AppKit/Core Graphics with no external dependencies.

## Validation scope
PNG dimensions, opacity/transparency, asset references, and ICNS round-trip are checked locally. The preview is inspected at full size and includes small-size examples. No host app integration, simulator install, or App Store validation is included.

Apple references:
- https://developer.apple.com/documentation/xcode/configuring-your-app-icon
- https://developer.apple.com/design/human-interface-guidelines/app-icons/
