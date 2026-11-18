#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct NVThumbHandle NVThumbHandle;
typedef struct NVThumbEvent NVThumbEvent;
NVThumbHandle *nvthumb_open(const char *url, const char *headers_json, uint32_t width);
void nvthumb_prepare(NVThumbHandle *h);
void nvthumb_want(NVThumbHandle *h, uint64_t milliseconds);
int64_t nvthumb_keyframe(NVThumbHandle *h, uint64_t milliseconds);
void nvthumb_clear(NVThumbHandle *h);
NVThumbEvent *nvthumb_take(NVThumbHandle *h);
int64_t nvthumb_event_time(const NVThumbEvent *e);
const uint8_t *nvthumb_event_data(const NVThumbEvent *e, size_t *length);
void nvthumb_event_free(NVThumbEvent *e);
void nvthumb_close(NVThumbHandle *h);
#ifdef __cplusplus
}
#endif
