CC      ?= gcc
# -Wno-overlength-strings: the dashboard HTML is one embedded literal,
# longer than the 4095-char ISO minimum; fine on gcc/clang.
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -pedantic -Wno-overlength-strings

.PHONY: all
all: odo-webd

odo-webd: odo_webd.c
	$(CC) $(CFLAGS) -o $@ $<

.PHONY: clean
clean:
	rm -f odo-webd
