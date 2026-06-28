CC       ?= gcc
CXX      ?= g++
CPPFLAGS ?= -I.
CFLAGS   ?= -std=c11   -O2 -Wall -Wextra -pedantic -pthread $(CPPFLAGS) \
             -I$(UPSTREAM_CRYPTO)
CXXFLAGS ?= -std=c++14 -O2 -Wall -Wextra -pthread $(CPPFLAGS)
LDFLAGS  ?= -lpthread

UPSTREAM_CRYPTO = ../third_party/odo-miner/src/crypto

# -----------------------------------------------------------------------
# Targets
# -----------------------------------------------------------------------

# 2. odo-miner — new integrated miner (miner.c + epoch_watcher)
# Add -DODO_VALIDATE_HASH and $(UPSTREAM_CRYPTO)/KeccakP-800-reference.c to
# CFLAGS/MINER_SRCS to enable per-nonce software cross-check (debug builds only).
MINER_SRCS = miner.c epoch_watcher.c stratum.c job.c odocrypt_header.c \
             odocrypt_state.c miner_io.c
MINER_OBJS = $(patsubst %.c,%.o,$(MINER_SRCS))

# 3. odo-miner-watcher — miner with integrated epoch watcher thread
WATCHER_SRCS = miner_with_watcher.c epoch_watcher.c stratum.c job.c \
               odocrypt_header.c odocrypt_state.c miner_io.c
WATCHER_OBJS = $(WATCHER_SRCS:.c=.o)

# 4. Smoke test — FPGA MMIO register validation
SMOKE_TARGET = fpga_smoke_test

# 4b. Pipelined miner smoke test — on-board bring-up for the pipelined core
SMOKE_PIPE_SRCS = fpga_smoke_pipe.c miner_io_pipe.c odocrypt_state.c \
                  $(UPSTREAM_CRYPTO)/KeccakP-800-reference.c

# 4c. Pipelined mining daemon (stratum loop, free-running pipelined core)
PIPE_MINER_SRCS = miner_pipe.c miner_io_pipe.c stratum.c job.c odocrypt_header.c \
                  odocrypt_state.c thermal.c \
                  $(UPSTREAM_CRYPTO)/KeccakP-800-reference.c

# 4d. Pipelined daemon, UIO backend (non-root + IRQ-driven; WS3 of
# docs/uio-miner-io-scope.md). Identical to 4c but swaps the /dev/mem register
# layer (miner_io_pipe.c) for the UIO one (miner_io_pipe_uio.c). Needs the
# kernel UIO device from WS2 to run; builds + links standalone for CI/regression.
PIPE_MINER_UIO_SRCS = miner_pipe.c miner_io_pipe_uio.c stratum.c job.c \
                  odocrypt_header.c odocrypt_state.c thermal.c \
                  $(UPSTREAM_CRYPTO)/KeccakP-800-reference.c

# 5. miner_io_test — hardware bring-up test for miner_io layer
MINER_IO_TEST_SRCS = miner_io_test.c miner_io.c odocrypt_state.c

# 6. Algorithm self-test (C implementation vs upstream C++)
TEST_C_SRCS  = test_odo.c odocrypt_state.c miner_io.c \
               $(UPSTREAM_CRYPTO)/KeccakP-800-reference.c
TEST_C_FLAGS = $(CFLAGS) -I$(UPSTREAM_CRYPTO)

TEST_UP_SRCS = test_odo_upstream.cpp $(UPSTREAM_CRYPTO)/odocrypt.cpp

# -----------------------------------------------------------------------
# Default target
# -----------------------------------------------------------------------
.PHONY: all
all: odo-miner-pipe odo-miner-pipe-uio $(SMOKE_TARGET)

# -----------------------------------------------------------------------
# Binaries
# -----------------------------------------------------------------------
.PHONY: odo-miner odo-miner-watcher smoke_test miner_io_test smoke_pipe odo-miner-pipe odo-miner-pipe-uio

odo-miner: $(MINER_OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

odo-miner-watcher: $(WATCHER_OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

smoke_test $(SMOKE_TARGET): fpga_smoke_test.c
	$(CC) $(CFLAGS) -o $(SMOKE_TARGET) $<

miner_io_test: $(MINER_IO_TEST_SRCS)
	$(CC) $(CFLAGS) -o $@ $^

smoke_pipe: $(SMOKE_PIPE_SRCS)
	$(CC) $(CFLAGS) -o $@ $^

odo-miner-pipe: $(PIPE_MINER_SRCS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

odo-miner-pipe-uio: $(PIPE_MINER_UIO_SRCS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

# -----------------------------------------------------------------------
# Algorithm tests
# -----------------------------------------------------------------------
.PHONY: test test_upstream check test_units

test_units: test_units.c job.c odocrypt_header.c
	$(CC) $(CFLAGS) -o $@ $^
	./test_units

# Loopback: drive the real stratum/job/header/odocrypt code against a running
# solo Stratum bridge (tools/testnet). Needs the upstream Keccak reference for
# the full PoW hash. Run: ./test_stratum_loopback <host> <port>
test_stratum_loopback: test_stratum_loopback.c stratum.c job.c odocrypt_header.c odocrypt_state.c
	$(CC) $(CFLAGS) -I$(UPSTREAM_CRYPTO) -c $(UPSTREAM_CRYPTO)/KeccakP-800-reference.c \
	      -o /tmp/keccak800_lb.o
	$(CC) $(CFLAGS) -I$(UPSTREAM_CRYPTO) -o $@ $^ /tmp/keccak800_lb.o $(LDFLAGS)

test: test_odo
	./test_odo

test_odo: $(TEST_C_SRCS)
	$(CC) $(TEST_C_FLAGS) -o $@ $^

test_upstream: test_odo_upstream
	./test_odo_upstream

test_odo_upstream: $(TEST_UP_SRCS)
	$(CC) $(CFLAGS) -I$(UPSTREAM_CRYPTO) -c $(UPSTREAM_CRYPTO)/KeccakP-800-reference.c \
	      -o /tmp/keccak800_ref.o
	$(CXX) $(CXXFLAGS) -I$(UPSTREAM_CRYPTO) -o $@ \
	      test_odo_upstream.cpp $(UPSTREAM_CRYPTO)/odocrypt.cpp /tmp/keccak800_ref.o

check: test_odo test_odo_upstream
	@echo "--- Diffing C port against upstream C++ ---"
	@bash -c "diff <(./test_odo 2>/dev/null | grep '^key=') \
	               <(./test_odo_upstream 2>/dev/null | grep '^key=') \
	           && echo 'MATCH: our implementation agrees with upstream' \
	           || { echo 'MISMATCH: see diff above'; exit 1; }"

# -----------------------------------------------------------------------
# Compilation rules
# -----------------------------------------------------------------------
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# -----------------------------------------------------------------------
# Housekeeping
# -----------------------------------------------------------------------
.PHONY: clean
clean:
	rm -f $(MINER_OBJS) $(WATCHER_OBJS) \
	      odo-miner odo-miner-watcher \
	      $(SMOKE_TARGET) miner_io_test \
	      test_odo test_odo_upstream \
	      *.o /tmp/keccak800_ref.o
