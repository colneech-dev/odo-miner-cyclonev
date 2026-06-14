CC      ?= gcc
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -pedantic -I./stb

.PHONY: all
all: odo-ui

odo-ui: odo_ui.c odoui_gfx.c
	$(CC) $(CFLAGS) -o $@ $^ -Wl,-Bstatic -lm -Wl,-Bdynamic

.PHONY: clean
clean:
	rm -f odo-ui
