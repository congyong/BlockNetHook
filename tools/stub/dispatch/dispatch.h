#ifndef DISPATCH_STUB_H
#define DISPATCH_STUB_H
#include <stdint.h>
typedef void *dispatch_queue_t;
typedef long dispatch_once_t;
typedef uint64_t dispatch_time_t;
#define DISPATCH_TIME_NOW (0ull)
#define NSEC_PER_SEC 1000000000ull
extern dispatch_queue_t dispatch_get_main_queue(void);
extern dispatch_time_t dispatch_time(dispatch_time_t when, int64_t delta);
extern void dispatch_async(dispatch_queue_t q, void (^block)(void));
extern void dispatch_after(dispatch_time_t when, dispatch_queue_t q, void (^block)(void));
extern void dispatch_once_t_stub(void);
#define dispatch_once(pred, block) do { dispatch_once_t *_p = (pred); if (!_p) { (block)(); *_p = 1; } } while (0)
#endif
