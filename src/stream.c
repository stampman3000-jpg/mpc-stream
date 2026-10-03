/* Stream. Put this on one MPC track as an effect.
 * The track still plays through the MPC. A copy of each block is posted
 * up the USB network to the Mac, which plays it into BlackHole.
 *
 * The audio thread only copies. It never waits on the socket.
 *
 * Every Stream in the MPC shares this file, so they share one clock: each
 * block is stamped with the same position as the other tracks' blocks from
 * that audio cycle, and the Mac lines them up by it. One sender thread
 * serves all of them.
 *
 * Packet, little endian, UDP port 47703, to 192.168.2.1:
 *   'T' u8 pair, u32 position in frames, u16 frames, i16[frames*2]
 * pair 1 is BlackHole channels 1-2, pair 2 is 3-4, and so on.
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define PORT 47703
#define MAX_FRAMES 256
#define SLOTS 64 /* ~185 ms of 128-frame blocks before the sender has to skip */
#define PAIRS 32
#define MAX_INST 64
#define RATE 44100

typedef struct {
    void *(*create)(const char *data_dir);
    void (*destroy)(void *inst);
    void (*midi)(void *inst, const uint8_t *msg, int len);
    void (*set_param)(void *inst, const char *key, const char *val);
    int (*get_param)(void *inst, const char *key, char *buf, int buf_len);
    void (*render)(void *inst, int16_t *out_lr, int frames);
    void (*process)(void *inst, const int16_t *in_lr, int16_t *out_lr, int frames);
} mpc_engine_t;

typedef struct {
    uint16_t frames;
    uint8_t pair; /* 1..32 */
    uint32_t pos; /* shared position of the first frame */
    int16_t lr[MAX_FRAMES * 2];
    atomic_uint pub; /* seq + 1 once the samples are written; 0 = being written */
} Slot;

typedef struct {
    atomic_int level; /* 0..100, scales what is sent, not what the MPC plays */
    atomic_int pair;  /* 1..32, which BlackHole stereo pair */
    atomic_uint seq;  /* next slot number the audio thread will write */
    uint32_t sent;    /* sender thread only */
    uint32_t my_pos;  /* audio thread only: position of this Stream's last block */
    uint64_t my_ns;
    int have_pos;
    Slot slots[SLOTS];
} Stream;

/* Shared by every Stream in the MPC. */
static pthread_mutex_t g_life = PTHREAD_MUTEX_INITIALIZER; /* create/destroy */
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER; /* the list, held by the sender while it reads */
static Stream *g_inst[MAX_INST];
static int g_n;
static pthread_t g_thread;
static int g_started;
static atomic_int g_run;
static int g_sock = -1;
static struct sockaddr_in g_mac;
static atomic_uint g_pos;   /* position of the current audio cycle's block */
static atomic_ullong g_ns;  /* when g_pos last moved */

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int send_one(Stream *s) {
    uint32_t next = atomic_load_explicit(&s->seq, memory_order_acquire);
    if (next - s->sent > SLOTS - 4) s->sent = next - 1; /* drop a backlog, stay near now */
    if (s->sent >= next) return 0;
    Slot *sl = &s->slots[s->sent % SLOTS];
    uint32_t a = atomic_load_explicit(&sl->pub, memory_order_acquire);
    if (a != s->sent + 1) return 0;
    uint16_t frames = sl->frames;
    uint8_t pair = sl->pair ? sl->pair : 1;
    uint32_t pos = sl->pos;
    unsigned char pkt[8 + MAX_FRAMES * 2 * sizeof(int16_t)];
    if (frames == 0 || frames > MAX_FRAMES) frames = 128;
    memcpy(pkt + 8, sl->lr, (size_t)frames * 2 * sizeof(int16_t));
    if (atomic_load_explicit(&sl->pub, memory_order_acquire) != a) { /* the audio thread reused this slot */
        s->sent++;
        return 1;
    }
    pkt[0] = 'T';
    pkt[1] = pair;
    memcpy(pkt + 2, &pos, 4);
    memcpy(pkt + 6, &frames, 2);
    if (g_sock >= 0)
        sendto(g_sock, pkt, 8 + (size_t)frames * 2 * sizeof(int16_t), MSG_NOSIGNAL,
               (struct sockaddr *)&g_mac, sizeof g_mac);
    s->sent++;
    return 1;
}

static void *net_main(void *arg) {
    struct sched_param sp;
    (void)arg;
    /* Above the MPC's screen thread, below its MIDI and audio threads. */
    memset(&sp, 0, sizeof sp);
    sp.sched_priority = 2;
    pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);
    while (atomic_load_explicit(&g_run, memory_order_acquire)) {
        int i, more = 1, rounds = 0;
        pthread_mutex_lock(&g_lock);
        while (more && rounds++ < SLOTS) {
            more = 0;
            for (i = 0; i < g_n; i++) more |= send_one(g_inst[i]);
        }
        pthread_mutex_unlock(&g_lock);
        usleep(1000);
    }
    return NULL;
}

static void *create(const char *data_dir) {
    Stream *s = calloc(1, sizeof *s);
    (void)data_dir;
    if (!s) return NULL;
    atomic_store(&s->level, 100);
    atomic_store(&s->pair, 1);
    pthread_mutex_lock(&g_life);
    pthread_mutex_lock(&g_lock);
    if (g_n < MAX_INST) g_inst[g_n++] = s;
    pthread_mutex_unlock(&g_lock);
    if (!g_started) {
        if (g_sock < 0) {
            int sz = 1024 * 1024;
            g_sock = socket(AF_INET, SOCK_DGRAM, 0);
            if (g_sock >= 0) setsockopt(g_sock, SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz);
            memset(&g_mac, 0, sizeof g_mac);
            g_mac.sin_family = AF_INET;
            g_mac.sin_port = htons(PORT);
            inet_aton("192.168.2.1", &g_mac.sin_addr);
        }
        atomic_store(&g_run, 1);
        if (pthread_create(&g_thread, NULL, net_main, NULL) == 0) g_started = 1;
    }
    pthread_mutex_unlock(&g_life);
    return s;
}

static void destroy(void *inst) {
    Stream *s = inst;
    int i, empty;
    if (!s) return;
    pthread_mutex_lock(&g_life);
    pthread_mutex_lock(&g_lock);
    for (i = 0; i < g_n; i++)
        if (g_inst[i] == s) {
            g_inst[i] = g_inst[--g_n];
            break;
        }
    empty = g_n == 0;
    pthread_mutex_unlock(&g_lock);
    if (empty && g_started) {
        atomic_store_explicit(&g_run, 0, memory_order_release);
        pthread_join(g_thread, NULL);
        g_started = 0;
        if (g_sock >= 0) close(g_sock);
        g_sock = -1;
    }
    pthread_mutex_unlock(&g_life);
    free(s);
}

static void midi(void *inst, const uint8_t *msg, int len) {
    (void)inst;
    (void)msg;
    (void)len;
}

static void set_param(void *inst, const char *key, const char *val) {
    Stream *s = inst;
    int v;
    if (!s || !key || !val) return;
    if (!strcmp(key, "level")) {
        v = atoi(val);
        if (v < 0) v = 0;
        if (v > 100) v = 100;
        atomic_store(&s->level, v);
    } else if (!strcmp(key, "pair")) {
        v = atoi(val);
        if (v < 1) v = 1;
        if (v > PAIRS) v = PAIRS;
        atomic_store(&s->pair, v);
    } else if (!strcmp(key, "state")) {
        int level = 100, pair = 1, n;
        n = sscanf(val, "v1 %d %d", &level, &pair);
        if (n >= 1) {
            if (level < 0) level = 0;
            if (level > 100) level = 100;
            atomic_store(&s->level, level);
        }
        if (n >= 2) {
            if (pair < 1) pair = 1;
            if (pair > PAIRS) pair = PAIRS;
            atomic_store(&s->pair, pair);
        }
    }
}

static int get_param(void *inst, const char *key, char *buf, int len) {
    Stream *s = inst;
    if (!s || !key || !buf || len < 2) return 0;
    if (!strcmp(key, "level")) return snprintf(buf, len, "%d", atomic_load(&s->level));
    if (!strcmp(key, "pair")) return snprintf(buf, len, "%d", atomic_load(&s->pair));
    if (!strcmp(key, "state"))
        return snprintf(buf, len, "v1 %d %d", atomic_load(&s->level), atomic_load(&s->pair));
    return 0;
}

static void render(void *inst, int16_t *out, int frames) {
    (void)inst;
    if (!out || frames < 1) return;
    memset(out, 0, (size_t)frames * 2 * sizeof(int16_t));
}

/* Which shared position this audio cycle's block sits at. A Stream that
 * already used the current position knows a new cycle has begun. One that
 * missed the last cycle (just inserted) goes by the clock instead. */
static uint32_t cycle_pos(Stream *s, int frames, uint64_t t) {
    uint64_t period = (uint64_t)frames * 1000000000ull / RATE;
    uint32_t p = atomic_load_explicit(&g_pos, memory_order_acquire);
    int fresh = !s->have_pos || t - s->my_ns > period + period / 2;
    int bump = s->have_pos && s->my_pos == p;
    if (!bump && fresh) bump = t - atomic_load(&g_ns) > period * 3 / 4;
    if (bump) {
        uint32_t want = p + (uint32_t)frames;
        if (atomic_compare_exchange_strong(&g_pos, &p, want)) {
            p = want;
            atomic_store(&g_ns, t);
        }
    }
    s->my_pos = p;
    s->my_ns = t;
    s->have_pos = 1;
    return p;
}

static void process(void *inst, const int16_t *in, int16_t *out, int frames) {
    Stream *s = inst;
    int n, i, level, pair;
    uint32_t seq, pos;
    Slot *sl;
    if (!s || frames < 1) return;
    n = frames > MAX_FRAMES ? MAX_FRAMES : frames;
    if (out) {
        if (in) memcpy(out, in, (size_t)frames * 2 * sizeof(int16_t));
        else memset(out, 0, (size_t)frames * 2 * sizeof(int16_t));
    }
    if (!in) return;
    pos = cycle_pos(s, n, now_ns());
    level = atomic_load_explicit(&s->level, memory_order_relaxed);
    pair = atomic_load_explicit(&s->pair, memory_order_relaxed);
    if (pair < 1) pair = 1;
    if (pair > PAIRS) pair = PAIRS;
    seq = atomic_fetch_add_explicit(&s->seq, 1, memory_order_acq_rel);
    sl = &s->slots[seq % SLOTS];
    atomic_store_explicit(&sl->pub, 0, memory_order_release);
    sl->frames = (uint16_t)n;
    sl->pair = (uint8_t)pair;
    sl->pos = pos;
    if (level >= 100) {
        memcpy(sl->lr, in, (size_t)n * 2 * sizeof(int16_t));
    } else if (level <= 0) {
        memset(sl->lr, 0, (size_t)n * 2 * sizeof(int16_t));
    } else {
        for (i = 0; i < n * 2; i++) sl->lr[i] = (int16_t)((in[i] * level) / 100);
    }
    atomic_store_explicit(&sl->pub, seq + 1, memory_order_release);
}

static const mpc_engine_t API = { create, destroy, midi, set_param, get_param, render, process };
const mpc_engine_t *mpc_engine(void) { return &API; }

#ifdef STREAM_TEST
static int fails;
static void expect(const char *name, int got, int want) {
    if (got == want) printf("ok  %s = %d\n", name, got);
    else { printf("FAIL %s = %d want %d\n", name, got, want); fails++; }
}

int main(void) {
    int16_t in[256], out[256];
    int i, c;
    char b[32];
    Stream *s = create(0), *t, *u;
    for (i = 0; i < 256; i++) in[i] = (int16_t)(1000 + i);
    memset(out, 0, sizeof out);
    process(s, in, out, 128);
    expect("passthrough", out[10], in[10]);
    expect("queued", s->slots[0].frames, 128);
    expect("sample", s->slots[0].lr[10], in[10]);
    set_param(s, "level", "50");
    get_param(s, "level", b, sizeof b);
    expect("level", atoi(b), 50);
    process(s, in, out, 128);
    expect("half", s->slots[1].lr[10], (int16_t)(in[10] * 50 / 100));
    expect("mpc still full", out[10], in[10]);
    expect("pair starts at 1", s->slots[1].pair, 1);
    set_param(s, "pair", "4");
    process(s, in, out, 128);
    expect("pair 4", s->slots[2].pair, 4);
    expect("one block apart", (int)(s->slots[2].pos - s->slots[1].pos), 128);

    /* Two more tracks join. Whatever order the MPC runs them in, one cycle
     * shares one position. */
    t = create(0);
    u = create(0);
    usleep(3000);
    for (c = 0; c < 6; c++) {
        Stream *order[3] = { s, t, u };
        if (c & 1) { order[0] = u; order[2] = s; }
        if (c == 4) { order[0] = t; order[1] = s; }
        for (i = 0; i < 3; i++) process(order[i], in, out, 128);
        if (s->my_pos != t->my_pos || t->my_pos != u->my_pos) {
            printf("FAIL cycle %d positions %u %u %u\n", c, s->my_pos, t->my_pos, u->my_pos);
            fails++;
        }
        usleep(2900);
    }
    expect("cycles step one block", (int)(s->slots[(atomic_load(&s->seq) - 1) % SLOTS].pos -
                                          s->slots[(atomic_load(&s->seq) - 2) % SLOTS].pos), 128);
    destroy(t);
    destroy(u);
    printf("%s\n", fails ? "FAILED" : "ok");
    destroy(s);
    return fails ? 1 : 0;
}
#endif
