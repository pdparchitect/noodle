# Noodle website — v5

Plain HTML, CSS and a few lines of JavaScript. There's no build step. Copy the folder as it is.

- `index.html`: the main page
- `computer/index.html`: the Noodle Computer page, linked from the main page's Computer section; it shares `styles.css`, `app.js` and `assets/`
- `browser/index.html`: the Noodle Browser page, built the same way and linked from the Browser section
- `applet/index.html`: the Noodle Applet page, led by games, linked from the Applet section
- `styles.css`: all styles, including dark mode and phone layouts
- `app.js`: fades the nav logo and Download button in once you scroll past the hero buttons
- `assets/`: the app symbols, AI harness logos, favicon, the screenshots, `stage-launch.avif`, the photo every screenshot is staged on, `social-card.jpg`, the link preview for X, Slack and others, and `social-card-computer.jpg`, `social-card-browser.jpg` and `social-card-applet.jpg`, the previews for the three app pages. Screenshots and photos are AVIF; the link previews stay JPEG and `favicon.png` stays PNG, because `oauth/client.json` points sign-in services at it. Give each AVIF even width and height: Chrome shows nothing for a large one with an odd side

## Screenshots still to add

Five sections show a striped placeholder frame. Each frame says which screenshot it needs. To fill one, add the image to `assets/` and replace the whole `<figure class="shot placeholder">…</figure>` with:

    <figure class="shot"><img class="shot-img" src="assets/NAME.avif" alt="What the screenshot shows" /></figure>

Crop each screenshot to the app window only, the way `assets/screenshot-chloe.avif` is cropped. The page adds the rounded corners and shadow itself.
