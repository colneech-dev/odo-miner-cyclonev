/* test_gfx_bounds.c — framebuffer clipping regression for odoui_gfx.
 *
 * Drives gfx_rect_a() and gfx_text() with rectangles/strings that fall partly
 * or wholly outside the framebuffer (every edge, negative origin, absurd size,
 * very long string) against a heap-allocated fake framebuffer. Built with
 * ASan/UBSan: any out-of-bounds pixel write traps. A clean run proves the
 * clipping in put565a / gfx_rect_a / gfx_text holds. No display needed.
 *
 *   make test_gfx_bounds   (see sw/odo-ui/Makefile)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "odoui_gfx.h"

int main(void)
{
    const int W = 320, H = 240, S = 320;
    uint16_t *pix = calloc((size_t)S * H, sizeof(uint16_t));
    if (!pix) return 2;
    gfx_fb fb = { .fd = -1, .pix = pix, .w = W, .h = H, .stride = S };

    /* rectangles off every edge / negative origin / absurd size, opaque + alpha */
    gfx_rect_a(&fb, -1000, -1000, 100, 100, 1, 2, 3, 255);
    gfx_rect_a(&fb,  W + 50, H + 50, 100, 100, 4, 5, 6, 255);
    gfx_rect_a(&fb, -50, -50, 60, 60, 7, 8, 9, 128);          /* straddle top-left, alpha */
    gfx_rect_a(&fb, W - 1, H - 1, 50, 50, 1, 1, 1, 200);      /* straddle bottom-right */
    gfx_rect_a(&fb, 0, 0, 1000000, 1000000, 9, 9, 9, 255);   /* absurd size clamps */
    gfx_rect_a(&fb, 10, 10, 0, 0, 1, 1, 1, 255);             /* zero size */
    gfx_rect_a(&fb, 100, 100, -20, -20, 1, 1, 1, 255);       /* negative size */

    /* text far off-screen / overrunning the right edge / very long string */
    gfx_font f;
    const char *ttf = "../../linux/overlay/etc/odo-ui/fonts/IBMPlexMono-Medium.ttf";
    if (gfx_font_load(&f, ttf, 16.0f) == 0) {
        char big[4096];
        memset(big, 'W', sizeof(big) - 1); big[sizeof(big) - 1] = 0;
        gfx_text(&fb, &f, -2000, -2000, big, 255, 255, 255);
        gfx_text(&fb, &f,  W + 10, H + 10, big, 255, 255, 255);
        gfx_text(&fb, &f, 0, 0, big, 255, 255, 255);          /* overruns right edge */
        gfx_text(&fb, &f, W - 4, 4, "edge", 255, 255, 255);
        gfx_text_right(&fb, &f, 3, 4, big, 200, 200, 200);    /* right-align off left */
        gfx_font_free(&f);
        printf("gfx bounds OK (rects + text, no ASan/UBSan trap)\n");
    } else {
        /* Font is optional for the core rect-clipping coverage. */
        printf("gfx bounds OK (rects; font not found, text skipped)\n");
    }

    free(pix);
    return 0;
}
