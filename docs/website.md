# Website

The public Noodle website lives in `website/`. It is plain HTML and CSS with local
images; it needs no package installation or build step. Only that directory is
uploaded to GitHub Pages.

## Edit and preview

Edit `website/index.html` and `website/styles.css`. From the repository root, run:

```sh
python3 -m http.server 8000 --bind 127.0.0.1 --directory website
```

Open <http://localhost:8000>. Stop the server with Control-C.

Keep asset and internal page links relative (for example, `./assets/noodle.png`),
so they work under both the default `/noodle/` path and a custom domain. The app
icon is copied from `Support/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png`;
the workspace screenshot is the main product screenshot used in the repository
README. Website images use the repository's existing Git LFS configuration.

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
