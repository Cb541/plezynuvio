#include "NuvioRangeCache.h"
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define BLOCK_SIZE (1024 * 1024)
struct NuvioRangeCache {
    char *directory;
    int64_t size, position;
    NuvioRangeRead read;
    NuvioRangeSeek seek;
    NuvioRangeInterrupt interrupt;
    void *opaque;
    int diskFailed;
};

NuvioRangeCache *nuvio_range_create(const char *directory, int64_t size,
    NuvioRangeRead read, NuvioRangeSeek seek, NuvioRangeInterrupt interrupt, void *opaque) {
    if (!directory || size <= 0 || !read || !seek) return NULL;
    NuvioRangeCache *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->directory = strdup(directory);
    if (!c->directory) { free(c); return NULL; }
    c->size = size; c->read = read; c->seek = seek;
    c->interrupt = interrupt; c->opaque = opaque;
    return c;
}

void nuvio_range_free(NuvioRangeCache *c) {
    if (!c) return;
    free(c->directory); free(c);
}

int64_t nuvio_range_seek(NuvioRangeCache *c, int64_t offset, int whence) {
    if (!c) return -EINVAL;
    int64_t base;
    if (whence == SEEK_SET) base = 0;
    else if (whence == SEEK_CUR) base = c->position;
    else if (whence == SEEK_END) base = c->size;
    else return -EINVAL;
    if ((offset > 0 && base > INT64_MAX - offset) ||
        (offset < 0 && offset < -base)) return -EINVAL;
    int64_t position = base + offset;
    if (position < 0) return -EINVAL;
    c->position = position;
    return position;
}

static int interrupted(NuvioRangeCache *c) {
    return c->interrupt && c->interrupt(c->opaque);
}

// Download one contiguous range through the reusable network connection.
// Only 64 KiB is resident; partial blocks are never marked as cache hits.
static int fill(NuvioRangeCache *c, const char *path, int64_t start, int expected) {
    if (interrupted(c)) return -ECANCELED;
    if (c->seek(c->opaque, start) != start) return -EIO;
    char temporary[PATH_MAX];
    if (snprintf(temporary, sizeof(temporary), "%s.part", path) >= sizeof(temporary))
        return -ENAMETOOLONG;
    FILE *f = fopen(temporary, "wb");
    if (!f) { c->diskFailed = 1; return -errno; }
    uint8_t buffer[65536];
    int total = 0, error = 0;
    while (total < expected) {
        if (interrupted(c)) { error = -ECANCELED; break; }
        int count = expected - total;
        if (count > sizeof(buffer)) count = sizeof(buffer);
        int n = c->read(c->opaque, buffer, count);
        if (n <= 0) { error = n < 0 ? n : -EIO; break; }
        if (n > count) { error = -EIO; break; }
        if (fwrite(buffer, 1, n, f) != (size_t)n) {
            error = -EIO; c->diskFailed = 1; break;
        }
        total += n;
    }
    if (fclose(f) != 0) { error = -EIO; c->diskFailed = 1; }
    if (!error && rename(temporary, path) != 0) {
        error = -errno; c->diskFailed = 1;
    }
    if (error) unlink(temporary);
    return error;
}

int nuvio_range_read(NuvioRangeCache *c, uint8_t *buffer, int count) {
    if (!c || !buffer || count <= 0) return -EINVAL;
    if (interrupted(c)) return -ECANCELED;
    if (c->position >= c->size) return 0;
    int64_t remaining = c->size - c->position;
    if (count > remaining) count = (int)remaining;
    if (c->diskFailed) {
        if (c->seek(c->opaque, c->position) != c->position) return -EIO;
        int n = c->read(c->opaque, buffer, count);
        if (n > 0) c->position += n;
        return n;
    }
    int64_t block = c->position / BLOCK_SIZE;
    int64_t start = block * BLOCK_SIZE;
    int expected = (int)((c->size - start) < BLOCK_SIZE ? c->size - start : BLOCK_SIZE);
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/%lld.range", c->directory, (long long)block) >= sizeof(path)) {
        c->diskFailed = 1;
        return nuvio_range_read(c, buffer, count);
    }
    struct stat info;
    if (stat(path, &info) != 0 || info.st_size != expected) {
        int error = fill(c, path, start, expected);
        if (error) return c->diskFailed ? nuvio_range_read(c, buffer, count) : error;
    }
    FILE *f = fopen(path, "rb");
    if (!f) { c->diskFailed = 1; return nuvio_range_read(c, buffer, count); }
    int offset = (int)(c->position - start);
    if (count > expected - offset) count = expected - offset;
    if (fseek(f, offset, SEEK_SET) != 0) {
        fclose(f); c->diskFailed = 1; return nuvio_range_read(c, buffer, count);
    }
    int n = (int)fread(buffer, 1, count, f);
    fclose(f);
    if (n <= 0) { unlink(path); return -EIO; }
    c->position += n;
    return n;
}
