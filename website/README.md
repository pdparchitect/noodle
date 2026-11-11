# Noodle website — v5

Plain HTML, CSS and a few lines of JavaScript. There's no build step. Copy the folder as it is.

- `index.html`: the main page
- `computer/index.html`: the Noodle Computer page, linked from the main page's Computer section; it shares `styles.css`, `app.js` and `assets/`
- `browser/index.html`: the Noodle Browser page, built the same way and linked from the Browser section
- `applet/index.html`: the Noodle Applet page, led by games, linked from the Applet section
- `enterprise/index.html`: the Noodle Enterprise page, for organisations that manage Noodle on their Macs, linked from every page's footer
- `office/index.html`: the AI office page, for small teams running the whole suite on one office Mac, linked from the main page's Hub section and every page's footer
- `styles.css`: all styles, including dark mode and phone layouts
- `app.js`: fades the nav logo and Download button in once you scroll past the hero buttons
- `assets/`: the app symbols, AI harness logos, favicon, the screenshots, `stage-wallpaper.avif`, the blurred wallpaper behind the hero (the other screenshots sit on muted tiles drawn in `styles.css`), `social-card.jpg`, the link preview for X, Slack and others, and `social-card-computer.jpg`, `social-card-browser.jpg` and `social-card-applet.jpg`, the previews for the three app pages. `office-macs.svg` and `office-diagram.svg` are Oscar's drawings for the AI office page: a Mac mini beside a Mac Studio, drawn to scale, and the office Mac linked to the team's devices. Screenshots and photos are AVIF; the link previews stay JPEG, 2400 × 1260 and under 150 KB. `favicon.png` stays PNG at 1024 px, because `oauth/client.json` points sign-in services at it; the pages' tab icon is the 32 px `favicon-32.png`. Give each AVIF even width and height: Chrome shows nothing for a large one with an odd side

## Phone-sized screenshots

Every screenshot over 40 KB has a smaller copy beside it, `NAME-small.avif`, so phones don't download the desktop size. Make it as wide as the image shows on a 440 pt phone at 3x (the `sizes` width at 396 px, times 3), keep its height in proportion and both sides even, and encode it at the same quality as the full image. List both in `srcset` with their widths, and set `sizes` to the width the image shows at in `styles.css`, never less: a window in a `stage-one` takes its size from `sizes`, so a smaller value shrinks it.

    <img class="win" src="assets/NAME.avif" srcset="assets/NAME-small.avif 900w, assets/NAME.avif 1242w" sizes="(max-width: 1124px) calc(75vw - 33px), 810px" width="1242" height="862" loading="lazy" decoding="async" alt="…" />

The first screenshot in each page's hero has `fetchpriority="high"`. Every other screenshot has `decoding="async"`, and those below the hero also `loading="lazy"`.

## Screenshots still to add

Five sections show a striped placeholder frame. Each frame says which screenshot it needs. To fill one, add the image to `assets/` and replace the whole `<figure class="shot placeholder">…</figure>` with:

    <figure class="shot"><img class="shot-img" src="assets/NAME.avif" alt="What the screenshot shows" /></figure>

Crop each screenshot to the app window only, the way `assets/screenshot-chloe.avif` is cropped. The page adds the rounded corners and shadow itself.
