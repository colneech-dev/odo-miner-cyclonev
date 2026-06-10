CC      ?= gcc
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -pedantic

.PHONY: all
all: odo-ui

odo-ui: odo_ui.c
	$(CC) $(CFLAGS) -o $@ $<

.PHONY: clean
clean:
	rm -f odo-ui
