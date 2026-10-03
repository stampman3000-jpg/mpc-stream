/* Mac side of Stream. Listens on UDP 47703 and plays each pair into
 * BlackHole 64ch. Pair 1 is channels 1-2, pair 2 is 3-4, and so on.
 * The MPC is 44100. If BlackHole is another rate, this resamples.
 *
 * Every Stream on the MPC stamps its blocks with one shared position, so
 * all pairs land on one timeline here and cannot slip against each other.
 * One play head reads every pair a fixed delay behind the newest block.
 * The MPC and Mac clocks differ slightly, so the play speed is trimmed by
 * a fraction of a percent to hold that delay.
 *
 *   ./play             wait for the MPC and play into BlackHole
 *   ./play --ms 12     ask for a shorter delay (default 23)
 *   ./play --selftest  feed itself blocks and check the pairs line up
 */
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <math.h>
#include <netinet/in.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "stream.h"

#define PORT 47703
#define SRC_RATE 44100.0
#define PAIRS 32
#define CAP 32768 /* frames, power of two */
#define ACTIVE_MS 400 /* a pair is live if a packet arrived this recently */

typedef struct {
    float ring[CAP * 2];
    atomic_uint start; /* first timeline frame this pair has */
    atomic_uint end;   /* one past the newest frame written */
    atomic_int have;
    atomic_uint last_ms;
    atomic_uint dups;
    /* old builds that send their own block count instead of the shared position */
    int legacy;
    uint32_t leg_seq0, leg_base, last_seq;
    int foreign; /* packets that belong to a second Stream on this same pair */
} Lane;

static Lane lanes[PAIRS];
static double out_rate = 48000.0;
static UInt32 out_ch = 2;
static uint32_t cushion = 1024; /* ~23 ms at 44100 */

static atomic_uint head; /* newest frame end across all pairs */
static atomic_int have_head;
static atomic_uint epoch; /* bumps when the MPC timeline starts over */

static atomic_uint packets;
static atomic_int peak;
static atomic_uint underruns, jumps;
static atomic_int ntracks, stable;
static atomic_uint pairmask;
static atomic_int delay_frames;
static atomic_int saw_legacy;
static atomic_uint cb_frames;

/* play head, only touched on the audio thread */
static double play_pos;
static int playing;
static uint32_t epoch_seen;
static double depth_avg;
static uint32_t calm_until;

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)ts.tv_sec * 1000u + (uint32_t)(ts.tv_nsec / 1000000u);
}

static void reset_timeline(uint32_t new_head) {
    int p;
    for (p = 0; p < PAIRS; p++) {
        atomic_store(&lanes[p].have, 0);
        lanes[p].legacy = 0;
    }
    atomic_store(&head, new_head);
    atomic_store(&have_head, 1);
    atomic_fetch_add(&epoch, 1);
}

static void write_block(Lane *ln, uint32_t pos, const unsigned char *pcm, uint16_t frames) {
    uint32_t i, end, h;
    if (!atomic_load(&ln->have)) {
        atomic_store(&ln->start, pos);
        atomic_store(&ln->end, pos);
        atomic_store(&ln->have, 1);
    }
    end = atomic_load(&ln->end);
    if ((int32_t)(pos - end) > CAP) {
        atomic_store(&ln->start, pos);
        end = pos;
    } else if ((int32_t)(pos - end) > 0) {
        for (i = end; i != pos; i++) {
            ln->ring[(i & (CAP - 1)) * 2] = 0;
            ln->ring[(i & (CAP - 1)) * 2 + 1] = 0;
        }
    } else if ((int32_t)(pos + frames - end) <= 0 && (int32_t)(end - pos) <= 4 * frames) {
        atomic_fetch_add(&ln->dups, 1); /* this spot was already filled: two Streams on one pair */
    }
    for (i = 0; i < frames; i++) {
        int16_t l, r;
        uint32_t k = ((pos + i) & (CAP - 1)) * 2;
        memcpy(&l, pcm + (i * 2) * sizeof(int16_t), 2);
        memcpy(&r, pcm + (i * 2 + 1) * sizeof(int16_t), 2);
        ln->ring[k] = l / 32768.0f;
        ln->ring[k + 1] = r / 32768.0f;
        if (l > peak || -l > peak) atomic_store(&peak, l < 0 ? -l : l);
    }
    if ((int32_t)(pos + frames - end) > 0) atomic_store_explicit(&ln->end, pos + frames, memory_order_release);
    h = atomic_load(&head);
    if ((int32_t)(pos + frames - h) > 0) atomic_store_explicit(&head, pos + frames, memory_order_release);
    atomic_store(&ln->last_ms, now_ms());
}

/* 'T' u8 pair, u32 shared position, u16 frames, i16[frames*2]
 * 'S' is the same with a per-Stream block count (older plugin builds). */
static void on_packet(const unsigned char *buf, ssize_t n) {
    uint32_t pos;
    uint16_t frames;
    int pair;
    Lane *ln;
    if (n < 8 || (buf[0] != 'T' && buf[0] != 'S')) return;
    pair = buf[1];
    if (pair < 1 || pair > PAIRS) return;
    ln = &lanes[pair - 1];
    memcpy(&pos, buf + 2, 4);
    memcpy(&frames, buf + 6, 2);
    if (frames == 0 || frames > 256) return;
    if ((size_t)n < 8 + (size_t)frames * 2 * sizeof(int16_t)) return;
    if (buf[0] == 'S') {
        uint32_t seq = pos;
        uint32_t end = atomic_load(&ln->end);
        int have = atomic_load(&ln->have);
        atomic_store(&saw_legacy, 1);
        if (!ln->legacy) {
            ln->legacy = 1;
            ln->leg_seq0 = seq;
            ln->last_seq = seq;
            ln->foreign = 0;
            ln->leg_base = atomic_load(&have_head) ? atomic_load(&head) : 0;
        } else if (!(seq > ln->last_seq && seq - ln->last_seq <= 4)) {
            /* Not the next block of this pair. Another Stream is aimed here,
             * or a stale packet. Taking it would play this pair at double speed. */
            if (++ln->foreign == 40) atomic_fetch_add(&ln->dups, 40);
            return;
        }
        pos = ln->leg_base + (seq - ln->leg_seq0) * frames;
        ln->last_seq = seq;
        ln->foreign = 0;
        /* A short run of missed blocks is silence. A long hole means this
         * count restarted: append, so the other pairs are not shoved forward. */
        if (have && (int32_t)(pos - end) > (int)frames * 4) {
            ln->leg_seq0 = seq;
            ln->leg_base = end;
            pos = end;
        }
    } else if (!atomic_load(&have_head)) {
        atomic_store(&head, pos);
        atomic_store(&have_head, 1);
    } else {
        int32_t d = (int32_t)(pos - atomic_load(&head));
        if (d > CAP / 2 || d < -(int32_t)CAP / 2) reset_timeline(pos);
    }
    write_block(ln, pos, buf + 8, frames);
    atomic_fetch_add_explicit(&packets, 1, memory_order_relaxed);
}

static void count_tracks(void) {
    uint32_t t = now_ms(), mask = 0;
    int p, n = 0;
    for (p = 0; p < PAIRS; p++) {
        uint32_t seen = atomic_load(&lanes[p].last_ms);
        if (atomic_load(&lanes[p].have) && seen && t - seen <= ACTIVE_MS) {
            mask |= 1u << p;
            n++;
        }
    }
    atomic_store(&ntracks, n);
    atomic_store(&pairmask, mask);
}

/* Where playback may read up to: the slowest live pair that is still within
 * 80 ms of the leader. One pair running ahead must not drag the others. */
static int clock_end(uint32_t *out) {
    uint32_t t = now_ms(), lead = 0;
    int any = 0, p;
    int32_t window = (int32_t)(SRC_RATE * 0.08);
    for (p = 0; p < PAIRS; p++) {
        uint32_t seen = atomic_load(&lanes[p].last_ms), e;
        if (!atomic_load(&lanes[p].have) || !seen || t - seen > ACTIVE_MS) continue;
        e = atomic_load_explicit(&lanes[p].end, memory_order_acquire);
        if (!any || (int32_t)(e - lead) > 0) lead = e;
        any = 1;
    }
    if (!any) return 0;
    any = 0;
    for (p = 0; p < PAIRS; p++) {
        uint32_t seen = atomic_load(&lanes[p].last_ms), e;
        if (!atomic_load(&lanes[p].have) || !seen || t - seen > ACTIVE_MS) continue;
        e = atomic_load_explicit(&lanes[p].end, memory_order_acquire);
        if ((int32_t)(lead - e) > window) continue;
        if (!any || (int32_t)(e - *out) < 0) *out = e;
        any = 1;
    }
    return any;
}

/* Fill interleaved float frames. Pair 1 is the first two channels. */
static void take(float *dst, UInt32 frames, UInt32 ch) {
    double base = SRC_RATE / out_rate, step, depth;
    uint32_t h, t = now_ms();
    uint32_t lo[PAIRS], hi[PAIRS];
    int use[PAIRS];
    int dry = 0;
    UInt32 f, p, np = 0;
    uint32_t want;

    memset(dst, 0, (size_t)frames * ch * sizeof(float));
    if (frames) atomic_store(&cb_frames, frames);
    /* A callback bigger than the cushion used to be thrown away. Grow the
     * cushion so one whole callback always fits, up to about 100 ms. */
    want = frames * 2;
    if (want > cushion && want <= (uint32_t)(SRC_RATE * 0.1)) cushion = want;
    count_tracks();
    if (!clock_end(&h)) return;
    if (atomic_load(&epoch) != epoch_seen) {
        epoch_seen = atomic_load(&epoch);
        playing = 0;
    }
    if (!playing) {
        int ready = 0, q;
        for (q = 0; q < PAIRS; q++) {
            uint32_t seen = atomic_load(&lanes[q].last_ms);
            uint32_t s, e;
            if (!atomic_load(&lanes[q].have) || !seen || t - seen > ACTIVE_MS) continue;
            s = atomic_load(&lanes[q].start);
            e = atomic_load(&lanes[q].end);
            if ((int32_t)(e - s) >= (int32_t)cushion && (int32_t)(h - e) <= (int32_t)(SRC_RATE * 0.08))
                ready = 1;
        }
        if (!ready) return;
        play_pos = (double)(uint32_t)(h - cushion);
        depth_avg = cushion;
        playing = 1;
        calm_until = t + 1000;
    }
    depth = (double)(int32_t)(h - (uint32_t)play_pos) - (play_pos - floor(play_pos));
    /* Only skip when the helper really fell behind, not on a long callback. */
    if (depth > SRC_RATE * 0.25 || depth < -(double)CAP / 2) {
        play_pos = (double)(uint32_t)(h - cushion);
        depth = cushion;
        depth_avg = cushion;
        atomic_fetch_add(&jumps, 1);
        calm_until = t + 1000;
    }
    depth_avg += (depth - depth_avg) * 0.02;
    {
        double trim = (depth_avg - cushion) / (cushion * 400.0);
        if (trim > 0.003) trim = 0.003;
        if (trim < -0.003) trim = -0.003;
        step = base * (1.0 + trim);
    }
    atomic_store(&delay_frames, (int)depth_avg);
    atomic_store(&stable, (int32_t)(t - calm_until) >= 0 && fabs(depth_avg - cushion) < 256);

    for (p = 0; p < PAIRS && p * 2 + 1 < ch; p++) {
        Lane *ln = &lanes[p];
        uint32_t s, e;
        use[p] = 0;
        if (!atomic_load(&ln->have)) continue;
        s = atomic_load(&ln->start);
        e = atomic_load_explicit(&ln->end, memory_order_acquire);
        if ((int32_t)(e - s) > CAP - 512) s = e - (CAP - 512);
        lo[p] = s;
        hi[p] = e;
        use[p] = 1;
        np++;
    }
    for (f = 0; f < frames; f++) {
        uint32_t i0;
        float frac;
        int32_t ahead;
        ahead = (int32_t)(h - (uint32_t)play_pos);
        if (ahead < (int)step + 2) {
            dry = 1;
            continue; /* hold the play head; this frame stays silent */
        }
        i0 = (uint32_t)play_pos;
        frac = (float)(play_pos - floor(play_pos));
        for (p = 0; np && p < PAIRS && p * 2 + 1 < ch; p++) {
            Lane *ln = &lanes[p];
            uint32_t k0, k1;
            if (!use[p]) continue;
            if ((int32_t)(i0 - lo[p]) < 0 || (int32_t)(i0 + 1 - hi[p]) >= 0) continue;
            k0 = (i0 & (CAP - 1)) * 2;
            k1 = ((i0 + 1) & (CAP - 1)) * 2;
            dst[f * ch + p * 2] = ln->ring[k0] + (ln->ring[k1] - ln->ring[k0]) * frac;
            dst[f * ch + p * 2 + 1] = ln->ring[k0 + 1] + (ln->ring[k1 + 1] - ln->ring[k0 + 1]) * frac;
        }
        play_pos += step;
    }
    if (dry) {
        atomic_fetch_add(&underruns, 1);
        atomic_store(&stable, 0);
    }
}

static OSStatus render_cb(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                          UInt32 bus, UInt32 frames, AudioBufferList *io) {
    (void)ref;
    (void)flags;
    (void)ts;
    (void)bus;
    if (io->mNumberBuffers == 1) {
        take(io->mBuffers[0].mData, frames, out_ch);
    } else {
        static float tmp[1024 * 64];
        UInt32 f, b;
        UInt32 n = frames > 1024 ? 1024 : frames;
        UInt32 ch = out_ch > 64 ? 64 : out_ch;
        take(tmp, n, ch);
        for (b = 0; b < io->mNumberBuffers; b++) {
            float *d = io->mBuffers[b].mData;
            for (f = 0; f < n; f++) d[f] = (b < ch) ? tmp[f * ch + b] : 0;
        }
    }
    return noErr;
}

static AudioDeviceID find_blackhole(void) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0, n, i;
    AudioDeviceID *ids, found = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size);
    n = size / sizeof(AudioDeviceID);
    ids = calloc(n ? n : 1, sizeof *ids);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, ids);
    for (i = 0; i < n; i++) {
        CFStringRef name = NULL;
        UInt32 ns = sizeof name;
        AudioObjectPropertyAddress na = {
            kAudioObjectPropertyName,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        char buf[128];
        if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &ns, &name) != noErr || !name) continue;
        buf[0] = 0;
        CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
        CFRelease(name);
        if (strcmp(buf, "BlackHole 64ch") == 0) { found = ids[i]; break; }
    }
    free(ids);
    return found;
}

static double device_rate(AudioDeviceID dev) {
    AudioObjectPropertyAddress a = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    Float64 r = 0;
    UInt32 sz = sizeof r;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &r) != noErr) return 0;
    return r;
}

static void list_pairs(uint32_t mask, char *out, size_t len) {
    int p;
    size_t used = 0;
    out[0] = 0;
    for (p = 0; p < PAIRS && used + 4 < len; p++)
        if (mask & (1u << p)) used += (size_t)snprintf(out + used, len - used, "%s%d", used ? " " : "", p + 1);
}

/* What the menu-bar window shows. The play head does not read this. */
typedef struct {
    char menu[64];
    char head[160];
    char body[640];
    int level;
} StreamView;

static StreamView views[2];
static atomic_uint view_i;

static void publish_view(StreamView v) {
    unsigned next = atomic_load_explicit(&view_i, memory_order_relaxed) ^ 1u;
    views[next] = v;
    atomic_store_explicit(&view_i, next, memory_order_release);
}

int stream_copy_status(char *menu, size_t mn, char *head, size_t hn, char *body, size_t bn) {
    unsigned i = atomic_load_explicit(&view_i, memory_order_acquire);
    StreamView v = views[i];
    if (!v.menu[0]) snprintf(v.menu, sizeof v.menu, "Stream");
    if (!v.head[0]) snprintf(v.head, sizeof v.head, "Starting");
    snprintf(menu, mn, "%s", v.menu);
    snprintf(head, hn, "%s", v.head);
    snprintf(body, bn, "%s", v.body);
    return v.level;
}

static void add_line(char *body, size_t len, const char *line) {
    size_t n = strlen(body);
    if (!line || !line[0] || n + 2 >= len) return;
    if (n) body[n++] = '\n';
    snprintf(body + n, len - n, "%s", line);
}

static uint32_t newest_audio_ms(void) {
    uint32_t best = 0;
    int p;
    for (p = 0; p < PAIRS; p++) {
        uint32_t s = atomic_load(&lanes[p].last_ms);
        if (!s) continue;
        if (!best || (int32_t)(s - best) > 0) best = s;
    }
    return best;
}

static void rate_words(double rate, char *out, size_t len) {
    if (rate < 1000) {
        snprintf(out, len, "BlackHole 64ch is not responding.");
        return;
    }
    if (rate > 44099.0 && rate < 44101.0)
        snprintf(out, len, "BlackHole 64ch, 44100 Hz, same as the MPC.");
    else
        snprintf(out, len,
                 "BlackHole 64ch is at %.0f Hz. Set Ableton to 44100. At another rate Ableton can stop hearing Stream.",
                 rate);
}

static void status_problem(const char *head, const char *body) {
    StreamView v;
    memset(&v, 0, sizeof v);
    snprintf(v.menu, sizeof v.menu, "Stream · problem");
    snprintf(v.head, sizeof v.head, "%s", head);
    snprintf(v.body, sizeof v.body, "%s", body);
    v.level = 2;
    publish_view(v);
}

static void note_status(AudioDeviceID dev, unsigned packets_per_s, const char *warn, int late, int jumped) {
    StreamView v;
    char pairs[128], rateb[240];
    int nt = atomic_load(&ntracks);
    double rate = dev ? device_rate(dev) : 0;
    uint32_t seen = newest_audio_ms();
    uint32_t t = now_ms();
    int age_ms = seen ? (int)(t - seen) : -1;
    int delay_ms = (int)(atomic_load(&delay_frames) * 1000.0 / SRC_RATE + 0.5);
    int steady = atomic_load(&stable);
    int legacy = atomic_load(&saw_legacy);
    int rate_off = rate > 1000.0 && (rate < 44099.0 || rate > 44101.0);
    memset(&v, 0, sizeof v);
    list_pairs(atomic_load(&pairmask), pairs, sizeof pairs);
    rate_words(rate, rateb, sizeof rateb);

    if (dev && !find_blackhole()) {
        snprintf(v.menu, sizeof v.menu, "Stream · no BlackHole");
        snprintf(v.head, sizeof v.head, "BlackHole 64ch disappeared");
        snprintf(v.body, sizeof v.body,
                 "Ableton cannot hear Stream without that device.\nTurn BlackHole 64ch back on, then open Stream again.");
        v.level = 2;
        publish_view(v);
        return;
    } else if (nt > 0) {
        snprintf(v.menu, sizeof v.menu, "Stream · %d", nt);
        snprintf(v.head, sizeof v.head, "%d track%s, %s", nt, nt == 1 ? "" : "s", steady ? "steady" : "settling");
        snprintf(v.body, sizeof v.body, "Pair%s %s.\nDelay about %d ms.\n%s\n%d packets a second.",
                 nt == 1 ? "" : "s", pairs[0] ? pairs : "?", delay_ms, rateb, packets_per_s);
        v.level = steady ? 0 : 1;
    } else if (seen && age_ms > (int)ACTIVE_MS) {
        int sec = age_ms / 1000;
        if (sec < 1) sec = 1;
        snprintf(v.menu, sizeof v.menu, "Stream · quiet");
        snprintf(v.head, sizeof v.head, "The MPC went quiet");
        snprintf(v.body, sizeof v.body,
                 "Ableton goes silent while nothing is arriving.\nLast audio %d second%s ago.\nStill listening on the USB cable, port 47703.\n%s",
                 sec, sec == 1 ? "" : "s", rateb);
        v.level = 2;
    } else {
        snprintf(v.menu, sizeof v.menu, "Stream · waiting");
        snprintf(v.head, sizeof v.head, "Waiting for the MPC");
        snprintf(v.body, sizeof v.body,
                 "Plug the MPC in with the USB cable, not Wi-Fi.\nOne Stream on each track. Leave this open.\n%s", rateb);
        v.level = 1;
    }
    if (nt > 0 && rate_off) {
        snprintf(v.menu, sizeof v.menu, "Stream · %.0f Hz", rate);
        v.level = 2;
    }
    if (legacy) add_line(v.body, sizeof v.body, "Old Stream build. Take Stream off the track and put it back.");
    if (warn && strstr(warn, "TWO STREAMS"))
        add_line(v.body, sizeof v.body, "Two Streams are on the same pair. Give each track its own pair.");
    if (late) add_line(v.body, sizeof v.body, "The copy is running late, so Ableton can drop out for a moment.");
    if (jumped) add_line(v.body, sizeof v.body, "The play head jumped to catch up.");
    publish_view(v);
}

static int serve(AudioDeviceID dev) {
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    uint32_t last_mask = 0;
    double last_rate = out_rate;
    if (sock < 0) {
        status_problem("Could not listen on port 47703", "Quit Stream and open it again.");
        return 1;
    }
    int yes = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(PORT);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(sock, (struct sockaddr *)&addr, sizeof addr) != 0) {
        perror("bind");
        status_problem("Port 47703 is already taken",
                       "Another Stream helper is running. Quit ./play, or quit the other Stream window, then open this again.");
        return 1;
    }
    int bufsz = 4 * 1024 * 1024;
    setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof bufsz);
    struct timeval tv = {.tv_sec = 0, .tv_usec = 200000};
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    fprintf(stderr, "stream listening on udp %d, delay %.0f ms\n", PORT, cushion * 1000.0 / SRC_RATE);
    note_status(dev, 0, "", 0, 0);
    time_t last = time(NULL);
    for (;;) {
        unsigned char buf[8 + 256 * 2 * sizeof(int16_t)];
        ssize_t n = recv(sock, buf, sizeof buf, 0);
        if (n > 0) on_packet(buf, n);
        time_t now = time(NULL);
        if (now != last) {
            char pairs[128], warn[160];
            unsigned npack = atomic_exchange(&packets, 0);
            unsigned nunder = atomic_exchange(&underruns, 0);
            unsigned njump = atomic_exchange(&jumps, 0);
            int pk = atomic_exchange(&peak, 0);
            int nt = atomic_load(&ntracks);
            uint32_t mask = atomic_load(&pairmask);
            int p;
            double r = device_rate(dev);
            last = now;
            warn[0] = 0;
            for (p = 0; p < PAIRS; p++)
                if (atomic_exchange(&lanes[p].dups, 0) > 4)
                    snprintf(warn + strlen(warn), sizeof warn - strlen(warn), "  TWO STREAMS ON PAIR %d", p + 1);
            if (mask != last_mask) {
                list_pairs(mask, pairs, sizeof pairs);
                fprintf(stderr, "%d track%s: pair%s %s\n", nt, nt == 1 ? "" : "s", nt == 1 ? "" : "s",
                        nt ? pairs : "none");
                last_mask = mask;
            }
            if (r > 0 && r != last_rate) {
                fprintf(stderr, "BlackHole changed to %.0f Hz (set Ableton to 44100 to skip resampling)\n", r);
                last_rate = r;
            }
            fprintf(stderr, "tracks %d  %s  delay %.0f ms  cb %u  packets/s %u  peak %d%s%s%s%s\n", nt,
                    !nt ? "idle" : atomic_load(&stable) ? "stable" : "settling",
                    atomic_load(&delay_frames) * 1000.0 / SRC_RATE, atomic_load(&cb_frames), npack, pk,
                    nunder ? "  late" : "", njump ? "  jumped" : "",
                    atomic_load(&saw_legacy) ? "  (old Stream build: take Stream off and back on)" : "", warn);
            note_status(dev, npack, warn, nunder > 0, njump > 0);
            atomic_store(&saw_legacy, 0);
        }
    }
}

int stream_play(void) {
    AudioDeviceID dev;
    AudioComponentDescription desc = {0};
    AudioComponent comp;
    AudioUnit unit = NULL;
    AudioStreamBasicDescription devfmt, fmt;
    AURenderCallbackStruct cb;
    UInt32 size;
    OSStatus st;
    StreamView starting;
    memset(&starting, 0, sizeof starting);
    snprintf(starting.menu, sizeof starting.menu, "Stream");
    snprintf(starting.head, sizeof starting.head, "Starting");
    snprintf(starting.body, sizeof starting.body, "Opening BlackHole 64ch.");
    starting.level = 1;
    publish_view(starting);
    dev = find_blackhole();
    if (!dev) {
        fprintf(stderr, "BlackHole 64ch is not installed\n");
        status_problem("BlackHole 64ch is not installed",
                       "Install BlackHole 64ch, then open Stream again. Ableton's input has to be that device, not BlackHole 2ch.");
        return 1;
    }
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_HALOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    comp = AudioComponentFindNext(NULL, &desc);
    if (!comp || AudioComponentInstanceNew(comp, &unit) != noErr) {
        fprintf(stderr, "could not open an output unit\n");
        status_problem("Could not open BlackHole", "The helper is not playing. Quit Stream and open it again.");
        return 1;
    }
    UInt32 one = 1, zero = 0;
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, sizeof one);
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, sizeof zero);
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, sizeof dev);
    size = sizeof devfmt;
    memset(&devfmt, 0, sizeof devfmt);
    st = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &devfmt, &size);
    if (st != noErr || devfmt.mChannelsPerFrame < 2 || devfmt.mSampleRate < 1000) {
        fprintf(stderr, "BlackHole format unusable (%d)\n", (int)st);
        status_problem("BlackHole's format is unusable", "Set BlackHole 64ch and Ableton both to 44100, then open Stream again.");
        return 1;
    }
    out_rate = devfmt.mSampleRate;
    out_ch = devfmt.mChannelsPerFrame;
    memset(&fmt, 0, sizeof fmt);
    fmt.mSampleRate = out_rate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    fmt.mChannelsPerFrame = out_ch;
    fmt.mBitsPerChannel = 32;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = 4 * out_ch;
    fmt.mBytesPerPacket = fmt.mBytesPerFrame;
    st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof fmt);
    if (st != noErr) {
        fprintf(stderr, "could not set the play format (%d)\n", (int)st);
        status_problem("Could not set the play format", "Set BlackHole 64ch and Ableton both to 44100, then open Stream again.");
        return 1;
    }
    {
        AudioObjectPropertyAddress ba = {
            kAudioDevicePropertyBufferFrameSize,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 bfs = 128, sz = sizeof bfs;
        AudioObjectSetPropertyData(dev, &ba, 0, NULL, sizeof bfs, &bfs);
        if (AudioObjectGetPropertyData(dev, &ba, 0, NULL, &sz, &bfs) == noErr)
            fprintf(stderr, "BlackHole buffer %u frames\n", bfs);
    }
    cb.inputProc = render_cb;
    cb.inputProcRefCon = NULL;
    AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    if (AudioUnitInitialize(unit) != noErr) {
        fprintf(stderr, "could not start BlackHole\n");
        status_problem("Could not start BlackHole", "Quit Stream and open it again. Leave it open while Ableton is recording.");
        return 1;
    }
    /* Ask the Mac not to pause this process. A nap is what left the pairs late. */
    static id keep_awake;
    keep_awake = [[NSProcessInfo processInfo]
        beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                          reason:@"Stream"];
    (void)keep_awake;
    if (AudioOutputUnitStart(unit) != noErr) {
        fprintf(stderr, "could not start BlackHole\n");
        status_problem("Could not start BlackHole", "Quit Stream and open it again. Leave it open while Ableton is recording.");
        return 1;
    }
    fprintf(stderr, "playing into BlackHole 64ch, %.0f Hz%s, %u channels, 32 pairs\n", out_rate,
            out_rate == SRC_RATE ? " (same as the MPC, no resampling)" : " (resampling from 44100)", out_ch);
    return serve(dev);
}

static void send_t(int pair, uint32_t pos, int tone_at) {
    unsigned char pkt[8 + 128 * 4];
    uint16_t frames = 128;
    int i;
    pkt[0] = 'T';
    pkt[1] = (unsigned char)pair;
    memcpy(pkt + 2, &pos, 4);
    memcpy(pkt + 6, &frames, 2);
    for (i = 0; i < 128; i++) {
        int16_t s = (int16_t)((int)(pos + i) == tone_at ? 20000 : 0);
        memcpy(pkt + 8 + (i * 2) * 2, &s, 2);
        memcpy(pkt + 8 + (i * 2 + 1) * 2, &s, 2);
    }
    on_packet(pkt, sizeof pkt);
}

static int selftest(void) {
    float out[4096 * 4];
    uint32_t pos = 1000000;
    int b, i, click = (int)pos + 38 * 128 + 5, at1 = -1, at2 = -1;
    out_rate = 44100;
    /* Pair 1 arrives on time. Pair 2's newest blocks turn up late in a burst. */
    for (b = 0; b < 40; b++) send_t(1, pos + b * 128, click);
    for (b = 0; b < 20; b++) send_t(2, pos + b * 128, click);
    take(out, 64, 4);
    for (b = 20; b < 40; b++) send_t(2, pos + b * 128, click);
    for (i = 0; i < 40 * 128; i += 512) {
        int f, k;
        for (k = 0; k < 4; k++, b++) {
            send_t(1, pos + b * 128, click);
            send_t(2, pos + b * 128, click);
        }
        take(out, 512, 4);
        for (f = 0; f < 512; f++) {
            if (at1 < 0 && out[f * 4] > 0.3f) at1 = i + f;
            if (at2 < 0 && out[f * 4 + 2] > 0.3f) at2 = i + f;
        }
    }
    if (at1 < 0 || at1 != at2) {
        printf("FAIL click pair1 %d pair2 %d\n", at1, at2);
        return 1;
    }
    printf("ok  late pair lands on the same frame (%d)\n", at1);
    for (i = 0; i < 10; i++, b++) {
        send_t(3, pos + b * 128, -1);
        send_t(3, pos + b * 128, -1);
    }
    if (atomic_load(&lanes[2].dups) < 4) {
        printf("FAIL two Streams on one pair not noticed\n");
        return 1;
    }
    printf("ok  two Streams on one pair noticed\n");
    return 0;
}

#ifndef STREAM_APP
int main(int argc, char **argv) {
    int i;
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--selftest")) return selftest();
        if (!strcmp(argv[i], "--ms") && i + 1 < argc) {
            double ms = atof(argv[++i]);
            if (ms < 3) ms = 3;
            if (ms > 300) ms = 300;
            cushion = (uint32_t)(ms * SRC_RATE / 1000.0);
        }
    }
    return stream_play();
}
#endif
