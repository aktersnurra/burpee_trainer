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

## Loading animation

The loader is a subtle, periodic deformation of the original raster contours.
It keeps the standing figure fixed while a travelling phase moves through the
crouch, plank, and low push-up contours. It does not animate separate cutouts
or attempt a literal articulated exercise demonstration.

| Export under `priv/static/images/` | Use |
|---|---|
| `burpee-loader.webp` | Preferred lossless animation on black |
| `burpee-loader.gif` | Optimized GIF fallback on black |
| `burpee-loader-transparent.webp` | Ivory contours with smooth alpha |
| `burpee-loader-transparent.gif` | Transparent GIF with binary alpha edges |
| `burpee-loader-still.png` | Original composition for reduced motion |

Each animation is 192 × 192px, 85 frames over 2.8 seconds (about 30 FPS), and
loops forever. The closing frame is identical to the opening frame. GIF uses
30/40ms frame delays to fit its centisecond timing format. A shared palette and
limited antialias coverage reduce export size and avoid palette flicker.
Transparent ivory artwork needs a dark surface for contrast.

The shared `burpee_loader/1` component chooses a still PNG for
`prefers-reduced-motion: reduce`, then animated WebP, then GIF. The status label
belongs to its surrounding loading region; the image is decorative.

To reproduce the exports, install Pillow and NumPy in a Python environment and
run `python3 scripts/render_burpee_loader.py` from the repository root.
