# Website

The public Noodle website lives in `website/`. It uses plain HTML, CSS, local
images, and a small inline script for the CSS animated version; it needs no
package installation or build step. An optional model comparison uses locally
vendored Three.js. Only that directory is
uploaded to GitHub Pages.

## Edit and preview

Edit `website/index.html` and `website/styles.css`. From the repository root, run:

```sh
python3 -m http.server 8000 --bind 127.0.0.1 --directory website
```

Open <http://localhost:8000>. Stop the server with Control-C.

The original light design remains at `index.html`. A separate dark alternative
is available at <http://localhost:8000/dark.html>, using `dark.html` and `dark.css`
alongside the shared styles. Its header links back to the light version.

The dark page places the original workspace screenshot over a generated MacBook
hardware render, keeping the app content unchanged. Display positioning and the
camera-notch mask are proportional, so both layers scale together. The additional
hardware asset is `website/assets/macbook-dark.jpg`; its generation prompt is
recorded in [website-dark-image-prompt.md](website-dark-image-prompt.md).

A third version is available at <http://localhost:8000/animated.html>. Scroll to
turn a closed MacBook toward its front edge, open its lid, and gradually illuminate
the real workspace screenshot. Scrolling backward reverses the sequence. The
screen belongs to the lid's CSS 3D surface, so its perspective stays attached to
the hinge instead of fading in as a flat overlay. Both still versions are kept.
The opening shows the laptop against black, with a text-only, 14px
"Scroll to reveal" cue at the bottom and a white shimmer every 2.2 seconds.
The cue fades away as scrolling starts and
its shimmer pauses while hidden. It is omitted from reduced-motion and static
views, and from the slider-driven comparison. Once the screen is illuminated,
the Noodle name, headline, and download button fade in over the final part of the
scroll. This version has no top navigation bar, app icon, or compatibility line;
the download button sits directly below the headline. The laptop
settles below the copy, and scrolling backward hides the text again. Reduced
motion and static fallbacks show the content immediately.
The lid and base use matching rounded perimeters with continuous side walls,
keeping the silhouette flush through the closed, edge-on, and open poses. Shell
dimensions, thickness, and corner radius are defined as CSS variables; the
geometry builder and viewport fitting read the same dimensions. The keyboard's
78 keycap rectangles and the deck/trackpad proportions were measured from the
user-supplied M5 model. These are embedded numeric measurements, so this version
does not download the model or a rendering library. Text selection and image
dragging are disabled on this version.

The keys use matte CSS surfaces with dark gaps, without luminous outlines. Their
markings are a single small vector layer, `assets/keyboard-legends.svg`, extracted
from the supplied model's lettering. This preserves the actual Mac symbols and
label positions without rendering the 3D geometry. Regenerate the vector with:

```sh
python3 scripts/prepare-website-keyboard.py /path/to/macbook-pro-14-inch-m5.zip
```

Customize the matte-black aluminum through `--metal-light`, `--metal-mid`,
`--metal-dark`, and `--metal-edge-level` in `.laptop`. The notch has rounded lower
corners and curved joins with the top bezel.

`animated.html` contains its own CSS and JavaScript. Its display and static
fallback use `assets/workspace-launch.png`, an unchanged copy of the supplied
2052 × 1539 screenshot, `Xnapper-2026-09-15-23.42.39.png`, showing the Noodle Launch
group over the Golden Gate Bridge wallpaper. The animated screen uses a centered
130% crop to make the app window larger while keeping the entire window in view.
Its illumination uses opacity without a brightness filter, and the reflection
fades out completely when open. The static fallback shows the full source image.
The still alternatives retain their
original screenshot. It adds no runtime library or build step. Scroll progress drives a bounded
animation-frame loop; projected geometry is fitted to the viewport as the lid
opens, with a maximum visible width of 960 CSS pixels to leave breathing room on
large displays. Smaller screens retain the same responsive fit. Reduced-motion
preferences show the open laptop without the long scroll
sequence. Browsers without CSS 3D or JavaScript get a static screenshot.

### Model comparison

Open <http://localhost:8000/comparison.html> for synchronized CSS and 3D versions.
The slider, Closed, and Open controls move both through the same sequence; the
headings open each full page. Reduced motion shows both open and disables
scrubbing. The independent 3D page is <http://localhost:8000/model.html>.

The supplied `macbook-pro-14-inch-m5.zip` contains a GLB with separate lid and base
groups but no animation. `model.js` adds the hinge rotation and places the shared
Noodle screenshot on the existing display mesh. It uses local Three.js 0.180.0
files under `vendor/three`, including the MIT license, downloaded from the
official npm package. No CDN requests occur at runtime. Loading or WebGL failures
fall back to the existing screenshot.

`scripts/prepare-website-model.py` removes unused white vertex colors, secondary
UV coordinates, and the original wallpaper while preserving the geometry and
remaining materials. It produces a deterministic gzip-wrapped GLB, decoded by
the browser's `DecompressionStream`, reducing the supplied 10.85 MB GLB to
3.85 MB. Regenerate it with:

```sh
python3 scripts/prepare-website-model.py /path/to/macbook-pro-14-inch-m5.zip
```

The supplied USDZ remains a reference; it is not downloaded by the website.
Only the optional comparison/model pages load the GLB and rendering library.

Keep asset and internal page links relative (for example, `./assets/noodle.png`),
so they work under both the default `/noodle/` path and a custom domain. The app
icon is copied from `Support/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png`;
the workspace screenshot is the main product screenshot used in the repository
README. Website images use the repository's existing Git LFS configuration.

## Design

The landing page uses local system fonts and plain CSS. The typography and spacing
were compared with Apple's [MacBook Air](https://www.apple.com/macbook-air/) and
[macOS](https://www.apple.com/os/macos/) pages on September 15, 2026. Those pages use
SF Pro Display for headings and SF Pro Text for smaller copy. Noodle keeps the
local Apple system-font stack instead of downloading web fonts.

Keep headline tracking close to normal: Apple's inspected 64px headline used
normal spacing, and its 48px headline used `-0.003em`. Avoid strongly negative
tracking, which compresses the system font. In the light version, keep the white
background, compact header, simple blue pill button, and unframed product image.
Use the font size and available width to control mobile wrapping rather than
tightening the letters.

After changing the stylesheet, update its version query in `index.html` so
returning visitors receive the new styles.

## Deploy

In the repository's **Settings → Pages**, set **Build and deployment → Source** to
**GitHub Actions**. This is a one-time repository setting.

Commit and push the website changes to `main`. The **Deploy website** workflow
in `.github/workflows/website.yml` publishes when `website/` or the workflow
changes. It can also be run manually from the Actions tab on `main`.

The default address is <https://pdparchitect.github.io/noodle/>. The first
successful deployment makes it available. The workflow retrieves only website
images from Git LFS and uploads only `website/`, keeping app binaries, source,
and internal project files out of the published artifact.

The website workflow does not change product versions or publish app releases.
Existing release workflows still run under their normal triggers; see
[releases](releases.md) before changing any product's `VERSION` file.

The download button uses GitHub's latest-release URL for `Noodle-arm64.zip`.
Deployment first checks that this download is available; otherwise it retains
the existing website. After the first Noodle release with the fixed filename,
run **Deploy website** manually if the initial deployment was deferred. Later
releases update the download automatically through GitHub's latest-release URL.

## Add a custom domain

1. Verify ownership of the domain in your GitHub account's Pages settings.
2. In this repository's **Settings → Pages → Custom domain**, enter the domain
   and save it.
3. Configure DNS with your domain provider. For a subdomain such as
   `www.example.com`, create a `CNAME` record pointing to
   `pdparchitect.github.io` (without `/noodle`). For an apex domain such as
   `example.com`, follow GitHub's current `ALIAS`, `ANAME`, or `A` record guidance.
4. Wait for GitHub's DNS check and certificate provisioning, then enable
   **Enforce HTTPS** when available.

With a custom Actions workflow, GitHub stores the domain in Pages settings;
adding a repository `CNAME` file is neither required nor used. The website's
relative links work without a rebuild or path rewrite when the domain changes.

See GitHub's [custom domain instructions](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site)
and [domain verification instructions](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/verifying-your-custom-domain-for-github-pages).
