#!/bin/sh
# fetch-assets.sh — download the stb single-header libs and the two OFL fonts
# needed by odoui_gfx.c. Run from sw/odo-ui/. Requires curl.
set -e

mkdir -p stb fonts

echo "==> stb single-header libraries (public domain)"
curl -fL -o stb/stb_truetype.h \
  https://raw.githubusercontent.com/nothings/stb/master/stb_truetype.h
curl -fL -o stb/stb_image.h \
  https://raw.githubusercontent.com/nothings/stb/master/stb_image.h

echo "==> Fonts (SIL OFL 1.1)"
curl -fL -o fonts/IBMPlexMono-Medium.ttf \
  https://github.com/IBM/plex/raw/master/IBM-Plex-Mono/fonts/complete/ttf/IBMPlexMono-Medium.ttf
curl -fL -o fonts/SpaceGrotesk-SemiBold.ttf \
  https://github.com/floriankarsten/space-grotesk/raw/master/fonts/ttf/SpaceGrotesk-SemiBold.ttf

cat <<'EOF'

Done.
  stb/*.h                    -> keep next to odo_ui.c (CFLAGS += -Istb)
  fonts/*.ttf                -> install to rootfs /etc/odo-ui/fonts/
                                (add to linux/overlay/ so they land on the SD card)

If a URL 404s the upstream layout moved — grab the same file from the
project's GitHub releases page and drop it in the same path.
EOF
