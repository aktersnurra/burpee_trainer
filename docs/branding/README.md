# Burpee Trainer icon

The icon depicts the six-count burpee as overlapping movement around a standing
figure, in cream on black. Imported from the approved burpee icon package.

| File | Purpose |
|---|---|
| `icon-master.png` | 1254 × 1254 raster master for future exports |
| `icon-1024.png` | 1024 × 1024 high-resolution export |
| `../../priv/static/images/icon-512.png` | 512 × 512 PWA icon |
| `../../priv/static/images/icon-192.png` | 192 × 192 PWA icon |
| `../../priv/static/images/apple-touch-icon.png` | 180 × 180 iOS home-screen icon |
| `../../priv/static/images/favicon-32.png` | 32 × 32 browser icon |
| `../../priv/static/favicon.ico` | Multi-size ICO browser fallback |

These files have an opaque black background; the master is a raster image, not
an editable SVG. The master and 1024px export stay outside the public assets.

The root layout links the favicons and Apple touch icon. The existing
`priv/static/manifest.webmanifest` lists the install icons and retains the app's
name, start URL, scope, and warm-stone launch colors.

On iPhone, open the app in Safari and choose Share → Add to Home Screen. If an
existing installation still shows the old icon, remove and re-add its home-screen
shortcut. Run the normal `mix assets.deploy` step when deploying to regenerate
digested assets.

## Approved loading animation

The loader uses illustrated poses based on the logo's sculpted ivory silhouette
and black contour channels. It performs a six-count military burpee, including
the push-up, with no upward jump or clap.

The approved version has a deliberate pose-by-pose rhythm: 19 source frames over
2.8 seconds. The first and last standing poses match. Identical holds may be
coalesced by the encoders. This version does not use optical-flow interpolation.

The poses are ivory on black; the exports invert them for the light-only app: a dark
ink silhouette (`#20201D`) on a transparent background, so the loader sits on any surface.

Exports under `priv/static/images/`:

- `burpee-loader.webp`: preferred lossless animation with smooth alpha.
- `burpee-loader.gif`: fallback with binary alpha, soft edges matted against the stone.
- `burpee-loader-still.png`: standing pose for reduced motion.

All exports are 192px square. The shared `burpee_loader/1` component selects the still
image when `prefers-reduced-motion: reduce` is enabled. Existing status labels provide
accessible loading announcements.

## Launch screens

`apple-touch-startup-image` files in `priv/static/images/startup/` show the app icon on
the warm-stone background while a home-screen launch loads. Regenerate them with
`python3 scripts/render_startup_screens.py` (Pillow required). iOS caches launch images
per home-screen shortcut: remove and re-add the shortcut to see a new one.

The approved source poses are preserved in `loader-poses.zip`. Reproduce all
exports with `python3 scripts/render_burpee_loader.py` (Pillow and NumPy required).
