# Noodle website — v5

Plain HTML, CSS and a few lines of JavaScript. There's no build step. Copy the folder as it is.

- `index.html`: the main page
- `computer/index.html`: the Noodle Computer page, linked from the main page's Computer section; it shares `styles.css`, `app.js` and `assets/`
- `styles.css`: all styles, including dark mode and phone layouts
- `app.js`: fades the nav logo and Download button in once you scroll past the hero buttons
- `assets/`: the app symbols, AI harness logos, favicon, the screenshots, `stage-launch.jpg`, the photo every screenshot is staged on, and `social-card.png`, the link preview for X, Slack and others

## Screenshots still to add

Five sections show a striped placeholder frame. Each frame says which screenshot it needs. To fill one, add the image to `assets/` and replace the whole `<figure class="shot placeholder">…</figure>` with:

    <figure class="shot"><img class="shot-img" src="assets/NAME.png" alt="What the screenshot shows" /></figure>

Crop each screenshot to the app window only, the way `assets/screenshot-chloe.png` is cropped. The page adds the rounded corners and shadow itself.
