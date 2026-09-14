#!/bin/bash
# Patch the KasmVNC web client: strip its branding and chrome, inject this
# desktop's assets, and fix the browser title.
#
# Run once by the desktop base after installing the kasmvnc .deb. A product
# image may run it again with a different brand; the second run rebrands in
# place rather than injecting the asset links a second time.
#
# Usage: kasm-patch [brand]

set -euo pipefail

brand="${1:-${DESKTOP_BRAND:-Desktop}}"
www=/usr/share/kasmvnc/www
stamp="$www/.desktop-brand"

# sed uses | as its delimiter below and the brand is interpolated into both the
# pattern and the replacement.
case "$brand" in
    *'|'* | *'&'* | *'\'*)
        echo "[kasm-patch] brand may not contain | & or backslash" >&2
        exit 1
        ;;
esac

rebrand() {
    local previous="$1" next="$2"

    find "$www" -maxdepth 1 -name '*.html' -exec sed -i \
        -e "s|<title>${previous}</title>|<title>${next}</title>|" \
        {} +
    find "$www/assets" -name 'ui-*.js' -exec sed -i \
        -e "s|\"${previous}\"|\"${next}\"|g" \
        {} +
}

if [ -f "$stamp" ]; then
    rebrand "$(cat "$stamp")" "$brand"
    printf '%s\n' "$brand" > "$stamp"
    echo "[kasm-patch] rebranded the KasmVNC client as ${brand}"
    exit 0
fi

head_injection="<link rel=\"icon\" type=\"image/svg+xml\" href=\"./assets/favicon.svg\">"
head_injection+="<link rel=\"stylesheet\" href=\"./assets/custom.css\">"
head_injection+="</head>"

# Inject this desktop's assets, set the title, and drop upstream icon links.
find "$www" -maxdepth 1 -name '*.html' -exec sed -i \
    -e "s|<title>[^<]*</title>|<title>${brand}</title>|" \
    -e 's|<link[^>]*rel="icon"[^>]*>||g' \
    -e 's|<link[^>]*rel="apple-touch-icon"[^>]*>||g' \
    -e "s|</head>|${head_injection}|" \
    {} +

if ! grep -Rq -F 'assets/custom.css' "$www"/*.html; then
    echo "[kasm-patch] the custom stylesheet was not injected" >&2
    exit 1
fi

# Replace the KasmVNC brand string, and stop the client rewriting the title
# after connecting - upstream appends the VNC desktop name, which is Docker's
# generated hostname.
find "$www/assets" -name 'ui-*.js' -exec sed -i \
    -e "s|\"KasmVNC\"|\"${brand}\"|g" \
    -e 's|document.title=r.detail.name+" - "+ox|document.title=ox|g' \
    {} +

if grep -ERq 'document\.title=[[:alnum:]_$]+\.detail\.name\+" - "\+' \
    "$www/assets"/ui-*.js; then
    echo "[kasm-patch] the dynamic VNC desktop title was not removed" >&2
    exit 1
fi

printf '%s\n' "$brand" > "$stamp"
echo "[kasm-patch] KasmVNC client patched and branded as ${brand}"
