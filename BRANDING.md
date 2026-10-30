# Distyll // Pencil Bridge

Pencil Bridge uses Distyll's **Toolpath** system. The implementation was checked against the owner's master Toolpath guide and the existing Distyll Notch and Hermes application guides, with source findings retrieved from Claude on Omaga. The master palette and voice take precedence over older app-specific approximations.

## Palette

| Role | Value |
| --- | --- |
| Graphite ground | `#1C1E22` |
| Instrument surface | `#24262B` |
| Recessed surface | `#2B2E34` |
| Structural border | `#36393F` |
| Primary text on dark | `#FFFFFF` |
| Machine Grey | `#9AA3AE` |
| Nozzle Orange | `#FF5A1F` |
| PEI Blue, subordinate links | `#0E63B3` |
| Build Plate, light surfaces | `#EDEFF2` |
| Body Ink, text on light | `#3A3F47` |

The three additional dark-surface tokens come from the Notch application guide. Body Ink is not a border token. Do not introduce WALT Labs Elemental colours or replace the palette with similar teal/coral accents.

## Typography and layout

- Space Grotesk Bold for sentence-case display headings.
- Inter Regular for reading; Inter Semibold for emphasis.
- IBM Plex Mono Regular/Medium for codes, measurements, status and metadata.
- Five font files are bundled locally on both platforms. No runtime font download is required. Their original OFL notices are included in the app resources and under `Resources/FontLicenses`.
- Flat tonal panels and one-point borders establish depth. No decorative shadows or glass cards.
- Native forms, navigation, controls and accessibility behavior remain native.
- Use 8-point digit wells, 12-point controls, 16-point panels and 24-point focal instruments. Maintain generous spacing while keeping the active drawing surface large.

## Orange and layer lines

Use one orange action or active state per screen and keep orange below approximately 10% of the composition. Orange is never body text.

- iPad pairing: the scan action owns orange.
- Input workspace: the live pen cursor owns orange; controls and the stroke preview remain neutral.
- Settings and shortcut editor: the Done action owns orange. The local pen test stays neutral.
- Mac companion: the sharing action owns orange. The QR code retains a white quiet zone for scanning.
- Product icon: one orange pen against a graphite surface and neutral tablet outline.

Layer lines are faint, horizontal, one-pixel background strokes, at approximately 10-point spacing in the native UI. Keep them away from body text and readouts. The drawing surface reserves clear space around its pressure readout.

## Marks and copy

The product icon is an original, code-drawn pen and input surface. Its source is `scripts/render-icons.swift`. It is not a replacement for the supplied personal M/A publisher monogram, and it uses no SF Symbols artwork. Do not recreate or alter the personal monogram to make a product icon.

Keep the product name **Pencil Bridge** and show **Distyll** attribution in the UI. Use concrete descriptions, sentence-case labels and `//` separators in metadata. Avoid hype, em dashes and editorial arrow characters.

The existing application bundle identifiers are preserved so branding changes do not intentionally create a new app identity or discard existing macOS permissions.

## Rebuilding assets

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift scripts/render-icons.swift
python3 scripts/generate-project.py
```

The generator bundles fonts, their licences and the platform asset catalogs. The iPad icon is opaque; the macOS icon includes the standard transparent outside margin.
