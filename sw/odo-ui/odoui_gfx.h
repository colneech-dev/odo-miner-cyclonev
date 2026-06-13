/*
 * odoui_gfx.h — anti-aliased text + image helpers for the odo-ui framebuffer.
 *
 * Replaces the hand-rolled 8x8 bitmap font in odo_ui.c with real TrueType
 * rendering (via stb_truetype) and adds background-image support (via
 * stb_image). RGB565, alpha-blended, no external libraries beyond libm.
 *
 *   gfx_font_load()  — bake an ASCII atlas from a .ttf at a pixel height
 *   gfx_text()       — draw AA text (top-left origin, like the old fb_text)
 *   gfx_text_right() — right-edge aligned
 *   gfx_text_w()     — measure a string (proportional fonts need this)
 *   gfx_rect_a()     — semi-transparent fill (for panels over a photo)
 *   gfx_background() — load + scale + dim an image as the base layer
 *
 * Build: needs stb_truetype.h and stb_image.h on the include path, and -lm.
 */
#ifndef ODOUI_GFX_H
#define ODOUI_GFX_H

#include <stdint.h>
#include "stb_truetype.h"

/* Layout-compatible mirror of fb_t in odo_ui.c — you may pass (gfx_fb*)&fb. */
typedef struct {
    int fd;
    uint16_t *pix;
    int w, h, stride;          /* stride in pixels */
} gfx_fb;

#define GFX_RGB565(r,g,b) (uint16_t)((((r)>>3)<<11) | (((g)>>2)<<5) | ((b)>>3))

typedef struct {
    unsigned char *atlas;      /* aw*ah, 8-bit coverage         */
    int aw, ah;
    stbtt_bakedchar cdata[96]; /* ASCII 32..127                 */
    float px;                  /* baked pixel height            */
    int ascent;                /* pixels from top to baseline   */
} gfx_font;

/* Bake an ASCII atlas from a .ttf at the given pixel height. 0 on success. */
int  gfx_font_load(gfx_font *f, const char *ttf_path, float pixel_height);
void gfx_font_free(gfx_font *f);

/* Pixel width a string would occupy (for centering / right-aligning). */
int  gfx_text_w(gfx_font *f, const char *s);

/* Draw text. (x,y) is the TOP-LEFT of the text box — same convention as the
 * old fb_text() — the baseline offset is handled internally. Anti-aliased and
 * alpha-blended over whatever is already in the buffer. */
void gfx_text(gfx_fb *fb, gfx_font *f, int x, int y, const char *s,
              uint8_t r, uint8_t g, uint8_t b);

/* Same, but the string's right edge lands at x_right. */
void gfx_text_right(gfx_fb *fb, gfx_font *f, int x_right, int y, const char *s,
                    uint8_t r, uint8_t g, uint8_t b);

/* Semi-transparent filled rectangle (a: 0 transparent .. 255 opaque). */
void gfx_rect_a(gfx_fb *fb, int x, int y, int w, int h,
                uint8_t r, uint8_t g, uint8_t b, uint8_t a);

/* Load an image (PNG/JPG/BMP), scale to the full framebuffer and draw it as
 * the base layer. 'dim' (0..255) darkens it so foreground text stays legible
 * (~120 is a good start). Returns 0, or -1 if the file can't be loaded. */
int  gfx_background(gfx_fb *fb, const char *image_path, uint8_t dim);

#endif /* ODOUI_GFX_H */
