/*
 * miner_io.c - /dev/mem mmap helper for the FPGA register window
 */

#include "hps_regs.h"

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

int miner_io_open(miner_io_t *io)
{
    if (!io)
        return -1;

    memset(io, 0, sizeof(*io));
    io->fd       = -1;
    io->map_base = MAP_FAILED;
    io->regs     = NULL;

    io->fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (io->fd < 0) {
        fprintf(stderr, "miner_io: open(/dev/mem) failed: %s\n", strerror(errno));
        return -1;
    }

    io->map_base = mmap(NULL, MINER_SPAN,
                        PROT_READ | PROT_WRITE, MAP_SHARED,
                        io->fd, (off_t)FPGA_BASE);
    if (io->map_base == MAP_FAILED) {
        fprintf(stderr, "miner_io: mmap failed: %s\n", strerror(errno));
        close(io->fd);
        io->fd = -1;
        return -1;
    }

    io->regs = (volatile uint8_t *)io->map_base;
    return 0;
}

void miner_io_close(miner_io_t *io)
{
    if (!io)
        return;
    if (io->map_base && io->map_base != MAP_FAILED) {
        munmap(io->map_base, MINER_SPAN);
        io->map_base = MAP_FAILED;
    }
    if (io->fd >= 0) {
        close(io->fd);
        io->fd = -1;
    }
    io->regs = NULL;
}
