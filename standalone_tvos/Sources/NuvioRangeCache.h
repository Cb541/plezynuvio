#ifndef NUVIO_RANGE_CACHE_H
#define NUVIO_RANGE_CACHE_H
#include <stdint.h>
// Serial, disk-backed byte ranges. Callbacks use negative errno on failure.
typedef struct NuvioRangeCache NuvioRangeCache;
typedef int (*NuvioRangeRead)(void *, uint8_t *, int);
typedef int64_t (*NuvioRangeSeek)(void *, int64_t);
typedef int (*NuvioRangeInterrupt)(void *);
NuvioRangeCache *nuvio_range_create(const char *directory, int64_t size,
    NuvioRangeRead read, NuvioRangeSeek seek, NuvioRangeInterrupt interrupt, void *opaque);
void nuvio_range_free(NuvioRangeCache *cache);
int nuvio_range_read(NuvioRangeCache *cache, uint8_t *buffer, int count);
int64_t nuvio_range_seek(NuvioRangeCache *cache, int64_t offset, int whence);
// Monotonic count of bytes actually written into sparse range-cache files.
uint64_t nuvio_range_written_bytes(void);
#endif
