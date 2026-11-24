# Computer images

Noodle Computer's Shell and Desktop images. Rook builds the same Desktop on Kali's base
(`.github/workflows/rook-images.yml`); only its Shell and brand live in `Incubator/Rook/Images`.

- A Desktop change must work on both bases: Ubuntu LTS and Kali rolling, which carries much newer
  packages (Mesa, picom, kitty). Check both workflows before calling it done.
- Where upstream behaviour differs, branch on what the image has (a package's version, `/etc/os-release`),
  and say why in a comment beside it.
- The checks in `tests/` read rendered pixels from a dummy X server. Compare against the product's own
  wallpaper or theme, never fixed colours, so both brands pass.
