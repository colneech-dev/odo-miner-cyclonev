CC ?= gcc
CPPFLAGS ?= -I.
CFLAGS ?= -std=c11 -O2 -Wall -Wextra -pedantic $(CPPFLAGS)
LDFLAGS ?=
TARGET ?= odod

SRCS = miner_daemon.c stratum.c job.c odocrypt_header.c
OBJS = $(SRCS:.c=.o)

SMOKE_SRCS = fpga_smoke_test.c
SMOKE_TARGET = fpga_smoke_test

.PHONY: all smoke_test clean

all: $(TARGET)

smoke_test: $(SMOKE_SRCS)
	$(CC) $(LDFLAGS) -o $(SMOKE_TARGET) $^

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET) $(SMOKE_TARGET)
