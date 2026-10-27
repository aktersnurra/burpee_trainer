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
