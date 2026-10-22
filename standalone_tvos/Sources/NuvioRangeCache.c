#include "NuvioRangeCache.h"
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define BLOCK_SIZE (1024 * 1024)

// Actual bytes written by the preview seek decoder's sparse video range
// cache, independent of mpv's disk-cache statistics and thumbnail JPEGs.
static atomic_uint_fast64_t sDiskBytesWritten = 0;
uint64_t nuvio_range_written_bytes(void) {
    return atomic_load_explicit(&sDiskBytesWritten, memory_order_relaxed);
}

struct NuvioRangeCache {
    char *directory;
    int64_t size, position;
    NuvioRangeRead read;
    NuvioRangeSeek seek;
    NuvioRangeInterrupt interrupt;
    void *opaque;
    int diskFailed;
    int progressive;
    int64_t networkPosition; // actual cursor of the independent FFmpeg HTTP input
    FILE *partial;
    int64_t partialStart;
    int partialWritten, partialExpected;
    char partialPath[PATH_MAX];
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
    c->networkPosition = -1;
    c->partialStart = -1;
    return c;
}

static void discard_partial(NuvioRangeCache *c) {
    if (!c) return;
    if (c->partial) fclose(c->partial);
    c->partial = NULL;
    if (c->partialPath[0]) unlink(c->partialPath);
    c->partialPath[0] = '\0';
    c->partialStart = -1;
    c->partialWritten = 0;
    c->partialExpected = 0;
}

void nuvio_range_free(NuvioRangeCache *c) {
    if (!c) return;
    discard_partial(c);
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

void nuvio_range_set_progressive(NuvioRangeCache *c, int enabled) {
    if (!c) return;
    enabled = !!enabled;
    if (c->progressive == enabled) return;
    discard_partial(c); // never expose an incomplete block as a cache hit
    c->progressive = enabled;
    c->networkPosition = -1;
}

// Read only what FFmpeg requests rather than blocking for a full 1 MiB.
// The independent HTTP cursor remains open and contiguous reads are reused.
static int progressive_network(NuvioRangeCache *c, uint8_t *buffer, int count) {
    if (interrupted(c)) return -ECANCELED;
    if (c->networkPosition != c->position) {
        if (c->seek(c->opaque, c->position) != c->position) return -EIO;
        c->networkPosition = c->position;
    }
    int n = c->read(c->opaque, buffer, count);
    if (n <= 0) return n < 0 ? n : -EIO;
    if (n > count) return -EIO;
    c->networkPosition += n;
    c->position += n;
    return n;
}

static int progressive_read(NuvioRangeCache *c, uint8_t *buffer, int count) {
    if (interrupted(c)) return -ECANCELED;
    if (c->position >= c->size) return 0;
    int64_t block = c->position / BLOCK_SIZE;
    int64_t start = block * BLOCK_SIZE;
    int expected = (int)(c->size - start < BLOCK_SIZE ? c->size - start : BLOCK_SIZE);
    int offset = (int)(c->position - start);
    if (count > expected - offset) count = expected - offset;
    if (c->partial && c->partialStart != start) discard_partial(c);
    if (c->diskFailed) return progressive_network(c, buffer, count);

    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/%lld.range",
                 c->directory, (long long)block) >= sizeof(path)) {
        c->diskFailed = 1;
        discard_partial(c);
        return progressive_network(c, buffer, count);
    }
    struct stat info;
    if (stat(path, &info) == 0 && info.st_size == expected) {
        FILE *f = fopen(path, "rb");
        if (f) {
            int n = 0;
            if (fseek(f, offset, SEEK_SET) == 0)
                n = (int)fread(buffer, 1, count, f);
            fclose(f);
            if (n > 0) { c->position += n; return n; }
        }
        // A damaged or unreadable block is not a valid preview cache hit.
        unlink(path);
    }

    // Sparse seeks generally start partway through an HTTP range. Don't
    // download the unused leading bytes just to produce one uncached frame.
    // Sequential reads reaching an aligned block can still cache it fully.
    if (!c->partial && offset != 0)
        return progressive_network(c, buffer, count);

    if (!c->partial) {
        if (snprintf(c->partialPath, sizeof(c->partialPath),
                     "%s.part", path) >= sizeof(c->partialPath)) {
            c->partialPath[0] = '\0';
            c->diskFailed = 1;
            return progressive_network(c, buffer, count);
        }
        c->partial = fopen(c->partialPath, "w+b");
        if (!c->partial) {
            c->diskFailed = 1;
            c->partialPath[0] = '\0';
            return progressive_network(c, buffer, count);
        }
        c->partialStart = start;
        c->partialExpected = expected;
        c->partialWritten = 0;
    }
    if (offset < c->partialWritten) {
        // FFmpeg may re-read an already delivered prefix after seeking.
        fflush(c->partial);
        int ready = c->partialWritten - offset;
        if (count > ready) count = ready;
        ssize_t n = pread(fileno(c->partial), buffer, (size_t)count, offset);
        if (n > 0) { c->position += n; return (int)n; }
        discard_partial(c);
        return progressive_network(c, buffer, count);
    }
    if (offset != c->partialWritten) {
        discard_partial(c);
        return progressive_network(c, buffer, count);
    }
    // Deliver the first network chunk now; do not force the remaining
    // megabyte into memory or onto disk before returning to FFmpeg.
    int n = progressive_network(c, buffer, count);
    if (n <= 0) { discard_partial(c); return n; }
    if (fwrite(buffer, 1, (size_t)n, c->partial) != (size_t)n) {
        discard_partial(c);
        c->diskFailed = 1;
        return n; // data was valid even if thumbnail-only disk storage failed
    }
    atomic_fetch_add_explicit(&sDiskBytesWritten, (uint64_t)n,
                              memory_order_relaxed);
    c->partialWritten += n;
    if (c->partialWritten == c->partialExpected) {
        fclose(c->partial);
        c->partial = NULL;
        if (rename(c->partialPath, path) != 0) unlink(c->partialPath);
        c->partialPath[0] = '\0';
        c->partialStart = -1;
        c->partialWritten = 0;
        c->partialExpected = 0;
    }
    return n;
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
        size_t written = fwrite(buffer, 1, n, f);
        if (written > 0) {
            atomic_fetch_add_explicit(&sDiskBytesWritten,
                (uint64_t)written, memory_order_relaxed);
        }
        if (written != (size_t)n) {
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
    if (c->progressive) return progressive_read(c, buffer, count);
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
