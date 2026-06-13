/*
 * odoui_gfx.c — implementation of the odo-ui text/image helpers.
 *
 * This is the ONLY translation unit that defines the stb implementations,
 * so stb_truetype.h / stb_image.h may be included as declarations elsewhere.
 */
#define STB_TRUETYPE_IMPLEMENTATION
#define STB_IMAGE_IMPLEMENTATION

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "stb_image.h"
#include "odoui_gfx.h"   /* pulls in stb_truetype.h (with implementation) */

/* ------------------------------------------------------------------ */
/* Font loading                                                        */
/* ------------------------------------------------------------------ */
int gfx_font_load(gfx_font *f, const char *path, float px)
{
    memset(f, 0, sizeof(*f));

    FILE *fp = fopen(path, "rb");
    if (!fp) { fprintf(stderr, "gfx: cannot open font %s\n", path); return -1; }
    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (sz <= 0) { fclose(fp); return -1; }

    unsigned char *ttf = (unsigned char *)malloc((size_t)sz);
    if (!ttf || fread(ttf, 1, (size_t)sz, fp) != (size_t)sz) {
        fclose(fp); free(ttf); return -1;
    }
    fclose(fp);

    f->aw = 512;
    f->ah = 512;
    f->px = px;
    f->atlas = (unsigned char *)malloc((size_t)f->aw * f->ah);
    if (!f->atlas) { free(ttf); return -1; }

    int rows = stbtt_BakeFontBitmap(ttf, 0, px, f->atlas,
                                    f->aw, f->ah, 32, 96, f->cdata);
    if (rows <= 0)
        fprintf(stderr, "gfx: atlas overflow for %s @ %.0fpx "
                        "(raise atlas size or lower px)\n", path, px);

    /* ascent so callers can position by the text-box top, like fb_text did */
    stbtt_fontinfo info;
    if (stbtt_InitFont(&info, ttf, stbtt_GetFontOffsetForIndex(ttf, 0))) {
        int a, d, l;
        stbtt_GetFontVMetrics(&info, &a, &d, &l);
        f->ascent = (int)(a * stbtt_ScaleForPixelHeight(&info, px) + 0.5f);
    } else {
        f->ascent = (int)(px * 0.8f);
    }

    free(ttf);
    return 0;
}

void gfx_font_free(gfx_font *f)
{
    if (f->atlas) { free(f->atlas); f->atlas = NULL; }
}

/* ------------------------------------------------------------------ */
/* Pixel plotting with alpha                                           */
/* ------------------------------------------------------------------ */
static inline void put565a(gfx_fb *fb, int x, int y,
                           uint8_t r, uint8_t g, uint8_t b, uint8_t a)
{
    if (x < 0 || y < 0 || x >= fb->w || y >= fb->h || a == 0) return;
    uint16_t *p = &fb->pix[(size_t)y * fb->stride + x];
    if (a == 255) { *p = GFX_RGB565(r, g, b); return; }

    uint16_t d = *p;
    uint8_t dr = (uint8_t)(((d >> 11) & 0x1F) << 3);
    uint8_t dg = (uint8_t)(((d >> 5)  & 0x3F) << 2);
    uint8_t db = (uint8_t)((d & 0x1F) << 3);

    uint8_t orr = (uint8_t)((r * a + dr * (255 - a)) / 255);
    uint8_t og  = (uint8_t)((g * a + dg * (255 - a)) / 255);
    uint8_t ob  = (uint8_t)((b * a + db * (255 - a)) / 255);
    *p = GFX_RGB565(orr, og, ob);
}

/* ------------------------------------------------------------------ */
/* Text                                                                */
/* ------------------------------------------------------------------ */
int gfx_text_w(gfx_font *f, const char *s)
{
    float x = 0, y = 0;
    stbtt_aligned_quad q;
    for (; *s; s++) {
        int c = (unsigned char)*s;
        if (c < 32 || c >= 128) c = '?';
        stbtt_GetBakedQuad(f->cdata, f->aw, f->ah, c - 32, &x, &y, &q, 1);
    }
    return (int)(x + 0.5f);
}

void gfx_text(gfx_fb *fb, gfx_font *f, int x, int y, const char *s,
              uint8_t r, uint8_t g, uint8_t b)
{
    float xpos = (float)x;
    float ypos = (float)(y + f->ascent);   /* GetBakedQuad expects a baseline */

    for (; *s; s++) {
        int c = (unsigned char)*s;
        if (c < 32 || c >= 128) c = '?';

        stbtt_aligned_quad q;
        stbtt_GetBakedQuad(f->cdata, f->aw, f->ah, c - 32, &xpos, &ypos, &q, 1);

        int gw  = (int)(q.x1 - q.x0 + 0.5f);
        int gh  = (int)(q.y1 - q.y0 + 0.5f);
        int dx0 = (int)(q.x0 + 0.5f);
        int dy0 = (int)(q.y0 + 0.5f);
        int sx  = (int)(q.s0 * f->aw + 0.5f);
        int sy  = (int)(q.t0 * f->ah + 0.5f);

        for (int gy = 0; gy < gh; gy++) {
            int ay = sy + gy;
            if (ay < 0 || ay >= f->ah) continue;
            for (int gx = 0; gx < gw; gx++) {
                int ax = sx + gx;
                if (ax < 0 || ax >= f->aw) continue;
                uint8_t cov = f->atlas[(size_t)ay * f->aw + ax];
                if (cov) put565a(fb, dx0 + gx, dy0 + gy, r, g, b, cov);
            }
        }
    }
}

void gfx_text_right(gfx_fb *fb, gfx_font *f, int x_right, int y, const char *s,
                    uint8_t r, uint8_t g, uint8_t b)
{
    gfx_text(fb, f, x_right - gfx_text_w(f, s), y, s, r, g, b);
}

/* ------------------------------------------------------------------ */
/* Shapes + image                                                      */
/* ------------------------------------------------------------------ */
void gfx_rect_a(gfx_fb *fb, int x, int y, int w, int h,
                uint8_t r, uint8_t g, uint8_t b, uint8_t a)
{
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > fb->w) w = fb->w - x;
    if (y + h > fb->h) h = fb->h - y;
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++)
            put565a(fb, x + i, y + j, r, g, b, a);
}

int gfx_background(gfx_fb *fb, const char *path, uint8_t dim)
{
    int w, h, n;
    unsigned char *img = stbi_load(path, &w, &h, &n, 3);
    if (!img) { fprintf(stderr, "gfx: cannot load image %s\n", path); return -1; }

    for (int y = 0; y < fb->h; y++) {
        int sy = (h > 0) ? y * h / fb->h : 0;
        for (int x = 0; x < fb->w; x++) {
            int sx = (w > 0) ? x * w / fb->w : 0;     /* nearest-neighbour */
            unsigned char *p = img + ((size_t)sy * w + sx) * 3;
            uint8_t r = p[0], g = p[1], b = p[2];
            if (dim) {
                r = (uint8_t)(r * (255 - dim) / 255);
                g = (uint8_t)(g * (255 - dim) / 255);
                b = (uint8_t)(b * (255 - dim) / 255);
            }
            fb->pix[(size_t)y * fb->stride + x] = GFX_RGB565(r, g, b);
        }
    }
    stbi_image_free(img);
    return 0;
}
