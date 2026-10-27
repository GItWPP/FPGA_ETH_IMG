/* Bounded UDP Sobel DATA window. Image processing remains entirely in the FPGA.
 * The socket is connected and nonblocking, owned by one Python worker.
 * CRC/sequence/length checks and retry semantics match the Python implementation.
 */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uint32_t retries, bad, peak, error_seq, error_code, sent;
} stream_metrics;

typedef struct {
    uint16_t seq, length, expected;
    uint32_t offset, attempts;
    int received;
    uint64_t deadline;
    unsigned char bytes[1038];
} stream_entry;

static uint16_t get16(const unsigned char *p) {
    return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}
static void put16(unsigned char *p, uint16_t value) {
    p[0] = (unsigned char)value;
    p[1] = (unsigned char)(value >> 8);
}
static uint16_t crc16(const unsigned char *p, uint32_t length, const uint16_t *table) {
    uint16_t crc = 0xffff;
    while (length--) crc = (uint16_t)((crc << 8) ^ table[((crc >> 8) ^ *p++) & 255]);
    return crc;
}
static uint64_t now_us(uint64_t frequency) {
    LARGE_INTEGER counter;
    QueryPerformanceCounter(&counter);
    return (uint64_t)counter.QuadPart / frequency * 1000000 +
           ((uint64_t)counter.QuadPart % frequency) * 1000000 / frequency;
}
static uint32_t output_prefix(uint32_t pixels, uint32_t width) {
    uint32_t rows = pixels / (width + 1), columns = pixels % (width + 1);
    return rows ? (rows - 1) * width + (columns ? columns - 1 : 0) : 0;
}
static int send_entry(SOCKET sock, stream_entry *entry, uint64_t timeout_us,
                      uint64_t frequency, int (*cancel)(void), stream_metrics *metrics) {
    uint64_t deadline = now_us(frequency) + timeout_us;
    for (;;) {
        int sent = send(sock, (const char *)entry->bytes, entry->length, 0);
        if (sent == entry->length) {
            metrics->sent++;
            entry->deadline = now_us(frequency) + timeout_us;
            return 0;
        }
        int error = WSAGetLastError();
        if (sent != SOCKET_ERROR || error != WSAEWOULDBLOCK) {
            metrics->error_code = (uint32_t)error;
            return -1;
        }
        if (cancel && cancel()) return -4;
        if (now_us(frequency) >= deadline) return -3;
        fd_set writable;
        FD_ZERO(&writable);
        FD_SET(sock, &writable);
        struct timeval tv = {0, 2000};
        if (select(0, NULL, &writable, NULL, &tv) == SOCKET_ERROR) {
            metrics->error_code = (uint32_t)WSAGetLastError();
            return -1;
        }
    }
}

__declspec(dllexport) int stream_sobel_exchange(uintptr_t socket_handle,
    const unsigned char *input, uint32_t input_length, uint32_t width, uint32_t height,
    uint16_t transfer_id, uint32_t window, uint32_t timeout_ms, uint32_t attempts,
    unsigned char *output, uint32_t output_length, int (*cancel)(void), stream_metrics *metrics) {
    stream_entry entries[64];
    uint16_t table[256];
    unsigned char reply[2048];
    LARGE_INTEGER qpc_frequency;
    uint32_t head = 1, next = 1, committed = 0;
    uint32_t packets = (input_length + 1023) / 1024;
    SOCKET sock = (SOCKET)socket_handle;
    memset(metrics, 0, sizeof(*metrics));
    if (!width || width > 1920 || !height || height > 1080 || window < 1 || window > 64 || !attempts || !timeout_ms ||
        input_length != (width + 1) * (height + 1) * 2 || output_length != width * height || packets > 65534)
        return -5;
    QueryPerformanceFrequency(&qpc_frequency);
    uint64_t frequency = (uint64_t)qpc_frequency.QuadPart;
    uint64_t timeout_us = (uint64_t)timeout_ms * 1000;
    uint64_t cancel_time = 0;
    for (uint32_t i = 0; i < 256; ++i) {
        uint16_t value = (uint16_t)(i << 8);
        for (int bit = 0; bit < 8; ++bit)
            value = (uint16_t)((value << 1) ^ ((value & 0x8000) ? 0x1021 : 0));
        table[i] = value;
    }
    while (head <= packets) {
        uint64_t now = now_us(frequency);
        if (now >= cancel_time) {
            if (cancel && cancel()) return -4;
            cancel_time = now + 1000;
        }
        /* An out-of-order reply retains its logical slot until all earlier replies arrive. */
        while (next <= packets && next - head < window) {
            stream_entry *entry = &entries[(next - 1) & 63];
            uint32_t pos = (next - 1) * 1024;
            uint32_t length = input_length - pos;
            if (length > 1024) length = 1024;
            entry->seq = (uint16_t)next;
            entry->length = (uint16_t)(length + 14);
            entry->offset = output_prefix(pos / 2, width);
            entry->expected = (uint16_t)(output_prefix((pos + length) / 2, width) - entry->offset);
            entry->attempts = 1;
            entry->received = 0;
            memcpy(entry->bytes, "\x55\xaa\x5a\xa5\x01\x41", 6);
            put16(entry->bytes + 6, transfer_id);
            put16(entry->bytes + 8, entry->seq);
            put16(entry->bytes + 10, (uint16_t)length);
            memcpy(entry->bytes + 12, input + pos, length);
            put16(entry->bytes + 12 + length, crc16(entry->bytes + 4, length + 8, table));
            int status = send_entry(sock, entry, timeout_us, frequency, cancel, metrics);
            if (status) return status;
            next++;
            if (next - head > metrics->peak) metrics->peak = next - head;
        }
        now = now_us(frequency);
        uint64_t earliest = now + 5000;
        for (uint32_t seq = head; seq < next; ++seq) {
            stream_entry *entry = &entries[(seq - 1) & 63];
            if (entry->received) continue;
            if (now >= entry->deadline) {
                metrics->error_seq = seq;
                if (entry->attempts >= attempts) return -3;
                int status = send_entry(sock, entry, timeout_us, frequency, cancel, metrics);
                if (status) return status;
                entry->attempts++;
                metrics->retries++;
            }
            if (entry->deadline < earliest) earliest = entry->deadline;
        }
        int length = recv(sock, (char *)reply, sizeof(reply), 0);
        if (length == SOCKET_ERROR) {
            int error = WSAGetLastError();
            if (error == WSAECONNRESET) continue;
            if (error == WSAEMSGSIZE) { metrics->bad++; continue; }
            if (error != WSAEWOULDBLOCK) { metrics->error_code = (uint32_t)error; return -1; }
            now = now_us(frequency);
            uint64_t remaining = earliest > now ? earliest - now : 0;
            if (remaining > 5000) remaining = 5000;
            fd_set readable;
            FD_ZERO(&readable);
            FD_SET(sock, &readable);
            struct timeval tv = {0, (long)remaining};
            if (select(0, &readable, NULL, NULL, &tv) == SOCKET_ERROR) {
                metrics->error_code = (uint32_t)WSAGetLastError(); return -1;
            }
            continue;
        }
        if (length < 14 || length > 1038 || memcmp(reply, "\x55\xaa\x5a\xa5", 4) || reply[4] != 1 ||
            get16(reply + 10) > 1024 || length != 14 + get16(reply + 10) ||
            crc16(reply + 4, (uint32_t)length - 6, table) != get16(reply + length - 2)) {
            metrics->bad++; continue;
        }
        uint32_t seq = get16(reply + 8);
        if (get16(reply + 6) != transfer_id || seq < head || seq >= next) continue;
        stream_entry *entry = &entries[(seq - 1) & 63];
        if (reply[5] == 255) {
            uint32_t code = get16(reply + 10) ? reply[12] : 0;
            if (code == 4) continue;
            metrics->error_seq = seq; metrics->error_code = code; return -2;
        }
        if (reply[5] != 0xc1 || get16(reply + 10) != entry->expected || entry->received) continue;
        if (entry->offset + entry->expected > output_length) return -5;
        memcpy(output + entry->offset, reply + 12, entry->expected);
        entry->received = 1;
        while (head < next && entries[(head - 1) & 63].received) {
            committed += entries[(head - 1) & 63].expected;
            head++;
        }
    }
    return committed == output_length ? 0 : -5;
}
