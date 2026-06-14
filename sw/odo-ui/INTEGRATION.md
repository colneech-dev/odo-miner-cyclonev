# Wiring TrueType text + background images into `odo-ui`

This replaces the hand-rolled `font8x8[]` bitmap font in `sw/odo-ui/odo_ui.c`
with anti-aliased TrueType rendering, and adds optional background images.
Two new files do the work: **`odoui_gfx.h`** / **`odoui_gfx.c`**.

The Cyclone V's HPS runs full Linux — baking a few small ASCII atlases and
alpha-blending glyphs is trivially within budget. `stb_truetype` and
`stb_image` are single public-domain headers, so there are no new packages.

---

## 1. Get the dependencies

Run `fetch-assets.sh` on the build host (needs `curl`):

```sh
./fetch-assets.sh        # downloads stb headers -> stb/ and fonts -> fonts/
```

It fetches:

| File | Where it goes | License |
|------|---------------|---------|
| `stb_truetype.h`, `stb_image.h` | `sw/odo-ui/stb/` | public domain |
| `IBMPlexMono-Medium.ttf` | rootfs `/etc/odo-ui/fonts/` | SIL OFL 1.1 |
| `SpaceGrotesk-SemiBold.ttf` | rootfs `/etc/odo-ui/fonts/` | SIL OFL 1.1 |

> Upstream URLs occasionally move — if a download 404s, grab the file from the
> project's GitHub release page and drop it in the same path.

Copy the two `.h` files next to `odo_ui.c` (or onto the include path), and
add the two `.ttf` files to the Buildroot rootfs overlay so they land in
`/etc/odo-ui/fonts/` on the SD card (see `linux/overlay/`).

---

## 2. Makefile

```make
# sw/odo-ui/Makefile
CFLAGS  += -Istb
odo-ui: odo_ui.o odoui_gfx.o
	$(CC) $(CFLAGS) -o $@ odo_ui.o odoui_gfx.o -lm   # stb_image needs libm
```

---

## 3. Changes in `odo_ui.c`

### 3a. Include + fonts

```c
#include "odoui_gfx.h"

/* three baked sizes — tune the pixel heights to taste on the panel */
static gfx_font g_body;   /* labels + data        (IBM Plex Mono) */
static gfx_font g_head;   /* header / section     (Space Grotesk) */
static gfx_font g_hero;   /* the hashrate number  (Space Grotesk) */
```

Load them once, right after `fb_open(&fb)` succeeds in `main()`:

```c
#define FDIR "/etc/odo-ui/fonts/"
gfx_font_load(&g_body, FDIR "IBMPlexMono-Medium.ttf",  16.0f);
gfx_font_load(&g_head, FDIR "SpaceGrotesk-SemiBold.ttf", 22.0f);
gfx_font_load(&g_hero, FDIR "SpaceGrotesk-SemiBold.ttf", 64.0f);
```

### 3b. Drop-in replacement for `fb_text`

Delete the `font8x8[96][8]` table **and** the old `fb_text()` function, then
paste this in their place. It keeps the exact same signature, so **every call
site stays unchanged** — `scale` now selects a baked font instead of an
integer multiplier:

```c
/* scale 1 -> body, 2 -> header, >=3 -> hero. Maps the RGB565 colour back to
 * 8-bit channels for the AA blend. */
static int fb_text(fb_t *fb, int x, int y, const char *s, int scale, uint16_t c)
{
    gfx_font *f = (scale >= 3) ? &g_hero : (scale == 2) ? &g_head : &g_body;
    uint8_t r = (uint8_t)(((c >> 11) & 0x1F) << 3);
    uint8_t g = (uint8_t)(((c >> 5)  & 0x3F) << 2);
    uint8_t b = (uint8_t)((c & 0x1F) << 3);
    gfx_text((gfx_fb *)fb, f, x, y, s, r, g, b);
    return gfx_text_w(f, s);          /* old fb_text returned advance width */
}
```

`fb_t` and `gfx_fb` are the same struct layout, so the cast is safe.

### 3c. Centering / right-alignment

The old code positioned text with `strlen(s) * 8 * scale`. Proportional fonts
make that wrong — use the real measured width instead. For example the splash
title and the right-aligned status pill become:

```c
/* centered title */
int tw = gfx_text_w(&g_hero, title);
fb_text(fb, (fb->w - tw) / 2, fb->h/2 - 12, title, 3, C_TEXT);

/* right-aligned status pill */
gfx_text_right((gfx_fb *)&fb, fb.w - 6, 12, txt, R8(col), G8(col), B8(col));
```

(Define small `R8/G8/B8` macros, or just call `gfx_text_right` with literal
channel values.) Button-label centering uses the same `gfx_text_w` trick.

---

## 4. Background images (optional)

`gfx_background()` draws a scaled, dimmed image as the base layer; make panels
translucent with `gfx_rect_a()` so it shows through while text stays readable.

In the main draw block, replace the opaque clear:

```c
fb_rect(&fb, 0, 0, fb.w, fb.h, C_BG);            /* OLD: flat fill */
```

with an image (and keep the flat fill as a fallback):

```c
if (gfx_background((gfx_fb *)&fb, "/etc/odo-ui/bg.png", 130) != 0)
    fb_rect(&fb, 0, 0, fb.w, fb.h, C_BG);

/* header + cards as ~80% panels instead of solid fb_rect */
gfx_rect_a((gfx_fb *)&fb, 0, 0, fb.w, 36, 16, 28, 62, 205);
```

Ship a **320×240** image at `/etc/odo-ui/bg.png` (PNG/JPG). Keep it dark and
low-contrast — `dim` ~120–150 — so the hashrate still reads at a glance. The
splash screen can use the same call before drawing the logo.

---

## 5. Cleanup on exit

`gfx_font_free(&g_body); gfx_font_free(&g_head); gfx_font_free(&g_hero);`
before `return` in `main()` (optional — the process is about to die anyway).

That's the whole change: same layout code, same call sites, real type.
