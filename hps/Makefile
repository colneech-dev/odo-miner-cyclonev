CC  ?= gcc
CXX ?= g++
CPPFLAGS ?= -I.
CFLAGS   ?= -std=c11   -O2 -Wall -Wextra -pedantic $(CPPFLAGS)
CXXFLAGS ?= -std=c++14 -O2 -Wall -Wextra $(CPPFLAGS)
LDFLAGS  ?=
TARGET   ?= odod

SRCS = miner_daemon.c stratum.c job.c odocrypt_header.c odocrypt_state.c miner_io.c
OBJS = $(SRCS:.c=.o)

SMOKE_SRCS   = fpga_smoke_test.c
SMOKE_TARGET = fpga_smoke_test

UPSTREAM_CRYPTO   ?= ../upstream/odo-miner/src/crypto
TEST_C_SRCS        = test_odo.c odocrypt_state.c miner_io.c \
                     $(UPSTREAM_CRYPTO)/KeccakP-800-reference.c
TEST_C_TARGET      = test_odo
TEST_C_CFLAGS      = $(CFLAGS) -I$(UPSTREAM_CRYPTO)

UPSTREAM_CRYPTO   = ../upstream/odo-miner/src/crypto
TEST_UP_SRCS      = test_odo_upstream.cpp $(UPSTREAM_CRYPTO)/odocrypt.cpp \
                    $(UPSTREAM_CRYPTO)/KeccakP-800-reference.c
TEST_UP_TARGET    = test_odo_upstream
TEST_UP_CXXFLAGS  = $(CXXFLAGS) -I$(UPSTREAM_CRYPTO)

.PHONY: all smoke_test test test_upstream check clean

all: $(TARGET)

smoke_test: $(SMOKE_SRCS)
	$(CC) $(LDFLAGS) -o $(SMOKE_TARGET) $< $(CPPFLAGS)

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

# Native self-test (no hardware required)
test: $(TEST_C_TARGET)
	./$(TEST_C_TARGET)

$(TEST_C_TARGET): $(TEST_C_SRCS)
	$(CC) $(TEST_C_CFLAGS) -o $@ $^

# Upstream C++ cross-check (requires g++ and upstream submodule)
test_upstream: $(TEST_UP_TARGET)
	./$(TEST_UP_TARGET)

$(TEST_UP_TARGET): $(TEST_UP_SRCS)
	$(CC)  $(CFLAGS) -I$(UPSTREAM_CRYPTO) -c $(UPSTREAM_CRYPTO)/KeccakP-800-reference.c -o /tmp/keccak800_ref.o
	$(CXX) $(TEST_UP_CXXFLAGS) -o $@ test_odo_upstream.cpp $(UPSTREAM_CRYPTO)/odocrypt.cpp /tmp/keccak800_ref.o

# Run both and diff — no output means our port matches the upstream
check: $(TEST_C_TARGET) $(TEST_UP_TARGET)
	@echo "--- Diffing our output against upstream ---"
	@bash -c "diff <(./$(TEST_C_TARGET) 2>/dev/null | grep '^key=') \
	               <(./$(TEST_UP_TARGET) 2>/dev/null | grep '^key=') \
	           && echo 'MATCH: our implementation agrees with upstream' \
	           || echo 'MISMATCH: see diff above'"

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET) $(SMOKE_TARGET) \
	      $(TEST_C_TARGET) $(TEST_UP_TARGET)
