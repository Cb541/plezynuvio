#include "NuvioRangeCache.h"
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define SIZE (3 * 1024 * 1024 + 137)
typedef struct { int64_t position, bytes; int cancelled, failAfter; } Source;
static uint8_t value(int64_t p) { return (uint8_t)((p * 17 + p / 251) % 253); }
static int readSource(void *opaque, uint8_t *b, int count) {
    Source *s = opaque;
    if (s->failAfter == 1) return -EIO;
    if (s->failAfter > 1) s->failAfter--;
    if (count > SIZE - s->position) count = (int)(SIZE - s->position);
    if (count <= 0) return 0;
    // Exercise legal short network reads too.
    if (count > 7919) count = 7919;
    for (int i = 0; i < count; i++) b[i] = value(s->position + i);
    s->position += count; s->bytes += count; return count;
}
static int64_t seekSource(void *opaque, int64_t p) { ((Source *)opaque)->position = p; return p; }
static int interrupt(void *opaque) { return ((Source *)opaque)->cancelled; }
static void check(NuvioRangeCache *c, int64_t pos, int count) {
    assert(nuvio_range_seek(c, pos, SEEK_SET) == pos);
    uint8_t data[8192]; int total = 0;
    while (total < count) {
        int ask = count - total; if (ask > sizeof(data)) ask = sizeof(data);
        int n = nuvio_range_read(c, data, ask); assert(n > 0);
        for (int j = 0; j < n; j++) assert(data[j] == value(pos + total + j));
        total += n;
    }
}
int main(void) {
    char dir[] = "/tmp/nuvio-range-test-XXXXXX"; assert(mkdtemp(dir));
    Source source = {0};
    NuvioRangeCache *c = nuvio_range_create(dir, SIZE, readSource, seekSource, interrupt, &source);
    assert(c);
    check(c, 99, 25000);
    int64_t fetched = source.bytes;
    check(c, 12000, 13000); assert(source.bytes == fetched); // genuine disk hit
    check(c, 1024 * 1024 - 17, 9000); // read across cached/missing boundary
    check(c, SIZE - 137, 137); // short final range
    uint8_t b[20]; assert(nuvio_range_read(c, b, sizeof(b)) == 0);
    assert(nuvio_range_seek(c, -1, SEEK_SET) == -EINVAL);
    assert(nuvio_range_seek(c, -1, SEEK_END) == SIZE - 1);
    assert(nuvio_range_seek(c, INT64_MAX, SEEK_CUR) == -EINVAL);
    source.cancelled = 1; assert(nuvio_range_read(c, b, 1) == -ECANCELED); source.cancelled = 0;
    source.failAfter = 3;
    assert(nuvio_range_seek(c, 2 * 1024 * 1024, SEEK_SET) >= 0);
    assert(nuvio_range_read(c, b, sizeof(b)) == -EIO);
    char partial[512]; snprintf(partial, sizeof(partial), "%s/2.range.part", dir);
    assert(access(partial, F_OK) != 0); // aborted block must not become valid
    source.failAfter = 0; check(c, 2 * 1024 * 1024 + 10, 9000);
    nuvio_range_free(c);
    fetched = source.bytes;
    c = nuvio_range_create(dir, SIZE, readSource, seekSource, interrupt, &source);
    check(c, 100, 4000); assert(source.bytes == fetched); // decoder reconnect reuse
    nuvio_range_free(c);
    c = nuvio_range_create("/nonexistent/nuvio-cache-test", SIZE, readSource, seekSource, interrupt, &source);
    check(c, 1024, 9000); // disk failure preserves direct reads
    nuvio_range_free(c);
    for (int i = 0; i < 4; i++) { snprintf(partial,sizeof(partial),"%s/%d.range",dir,i); unlink(partial); }
    rmdir(dir);
    puts("Range cache: byte accuracy, reuse, reconnect, boundaries, cancellation, failed reads and disk fallback passed");
}
