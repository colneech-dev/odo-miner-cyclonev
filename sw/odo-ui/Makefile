CC      ?= gcc
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -pedantic -I./stb

.PHONY: all
all: odo-ui

odo-ui: odo_ui.c odoui_gfx.c
	$(CC) $(CFLAGS) -o $@ $^ -Wl,-Bstatic -lm -Wl,-Bdynamic

# Framebuffer clipping regression under ASan/UBSan (no display needed).
.PHONY: test_gfx_bounds
test_gfx_bounds: test_gfx_bounds.c odoui_gfx.c
	$(CC) $(CFLAGS) -fsanitize=address,undefined -o $@ $^ -lm
	./test_gfx_bounds

.PHONY: clean
clean:
	rm -f odo-ui test_gfx_bounds
