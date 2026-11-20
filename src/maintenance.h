#ifndef EDID_MAINTENANCE_H
#define EDID_MAINTENANCE_H
#include <stdint.h>
#define EP_POLL_SECOND UINT64_C(1000000000)
#define EP_POLL_IDLE_NS (5*EP_POLL_SECOND)
#define EP_POLL_EVENT_NS EP_POLL_SECOND
#define EP_POLL_RETRY_NS (2*EP_POLL_SECOND)
#define EP_POLL_MAX_RETRIES 4u

/* One deadline and a bounded retry count, with no heap allocations. A new
 * event may bring work forward, but cannot postpone an existing deadline. */
typedef struct {
    uint64_t due;
    unsigned retries;
} EPMaintenance;

static inline void ep_poll_init(EPMaintenance *s,uint64_t now) {
    s->due=now+EP_POLL_IDLE_NS; s->retries=0;
}
static inline void ep_poll_request(EPMaintenance *s,uint64_t now) {
    uint64_t requested=now+EP_POLL_EVENT_NS;
    if (requested<s->due) s->due=requested;
    s->retries=EP_POLL_MAX_RETRIES;
}
static inline void ep_poll_finished(EPMaintenance *s,uint64_t now) {
    if (s->retries) --s->retries;
    s->due=now+(s->retries ? EP_POLL_RETRY_NS : EP_POLL_IDLE_NS);
}
static inline uint64_t ep_poll_delay(const EPMaintenance *s,uint64_t now) {
    return s->due>now ? s->due-now : 0;
}
#endif
