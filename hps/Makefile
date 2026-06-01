# hps/Makefile - simple build rules for HPS utilities
# Adjust source filenames as needed to match repository layout.

CC := gcc
CFLAGS := -O2 -Wall -pthread
LDFLAGS :=

# Sources - adjust if your real repo uses different filenames
MINER_SRCS := hps.minerc.c hps.minor_io.c hps_epoch_watcher.c
TEST_SRCS := hps.minor_io_test.c hps.minor_io.c

.PHONY: all clean
all: miner miner_io_test

miner: $(MINER_SRCS)
	$(CC) $(CFLAGS) -o $@ $(MINER_SRCS) $(LDFLAGS)

miner_io_test: $(TEST_SRCS)
	$(CC) $(CFLAGS) -o $@ $(TEST_SRCS) $(LDFLAGS)

clean:
	rm -f miner miner_io_test *.o *~

# Additional targets for miner integration
.PHONY: miner miner_io_test
miner: $(MINER_SRCS)
	$(CC) $(CFLAGS) -o $@ $(MINER_SRCS) $(LDFLAGS)

miner_io_test: $(TEST_SRCS)
	$(CC) $(CFLAGS) -o $@ $(TEST_SRCS) $(LDFLAGS)

clean-miner:
	rm -f miner miner_io_test
