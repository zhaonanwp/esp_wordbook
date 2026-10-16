#include "pronouncer.h"

#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <unistd.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "esp_mp3_dec.h"

#include "board/audio_out.h"
#include "wordstore.h"

namespace {

constexpr char TAG[] = "Pronouncer";

constexpr size_t kWordCap = 32;
constexpr size_t kInCap = 4096;    // mp3 码流缓冲
constexpr size_t kOutCap = 8192;   // 一帧立体声 1152×2×2=4608，够放
constexpr size_t kStreamCap = 2048;

struct Request {
    char word[kWordCap];
};

QueueHandle_t g_queue = nullptr;
// 播放任务在每次写 DMA 前看一眼；翻页、换词都会先把它置真。
volatile bool g_stop = false;

uint16_t Le16(const uint8_t* p) {
    return static_cast<uint16_t>(p[0] | (p[1] << 8));
}

uint32_t Le32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

bool ResolvePath(const char* word, char* out, size_t cap) {
    for (const char* ext : {"mp3", "wav"}) {
        std::string path = Wordstore::AudioPath(word, ext);
        if (path.empty() || path.size() >= cap) {
            continue;
        }
        if (access(path.c_str(), F_OK) != 0) {
            continue;
        }
        memcpy(out, path.c_str(), path.size() + 1);
        return true;
    }
    return false;
}

// 有道偶尔把同一个词返回成 RIFF/WAVE（Content-Type 仍谎报 audio/mpeg），
// 所以容器只看文件头魔数，不看任何声明。
bool PlayWav(FILE* f) {
    uint8_t riff[12];
    if (fseek(f, 0, SEEK_SET) != 0 || fread(riff, 1, sizeof(riff), f) != sizeof(riff)) {
        return false;
    }
    if (memcmp(riff, "RIFF", 4) != 0 || memcmp(riff + 8, "WAVE", 4) != 0) {
        return false;
    }

    bool have_fmt = false;
    bool have_data = false;
    uint16_t format = 0;
    uint16_t channels = 0;
    uint16_t bits = 0;
    uint32_t rate = 0;
    uint32_t data_size = 0;

    while (true) {
        uint8_t chunk[8];
        if (fread(chunk, 1, sizeof(chunk), f) != sizeof(chunk)) {
            break;
        }
        uint32_t size = Le32(chunk + 4);
        if (memcmp(chunk, "fmt ", 4) == 0) {
            uint8_t fmt[16];
            size_t take = size < sizeof(fmt) ? size : sizeof(fmt);
            if (fread(fmt, 1, take, f) != take || take < 16) {
                break;
            }
            format = Le16(fmt);
            channels = Le16(fmt + 2);
            rate = Le32(fmt + 4);
            bits = Le16(fmt + 14);
            have_fmt = true;
        } else if (memcmp(chunk, "data", 4) == 0) {
            data_size = size;
            have_data = true;
            break;
        } else {
            // 未知块按偶数字节跳过（WAV 要求块长补齐到 2 字节）
            if (fseek(f, static_cast<long>(size + (size & 1)), SEEK_CUR) != 0) {
                break;
            }
        }
    }

    if (!have_fmt || !have_data) {
        ESP_LOGW(TAG, "WAV 块结构不完整");
        return false;
    }
    if (format != 1 || bits != 16 || channels == 0 || channels > 2) {
        ESP_LOGW(TAG, "WAV 不支持：format=%u bits=%u ch=%u", static_cast<unsigned>(format),
                 static_cast<unsigned>(bits), static_cast<unsigned>(channels));
        return false;
    }
    if (!audio::Begin(rate, static_cast<uint8_t>(channels))) {
        return false;
    }

    uint8_t* buf = static_cast<uint8_t*>(malloc(kStreamCap));
    if (buf == nullptr) {
        return false;
    }
    // 有些导出工具把 data 长度写成 0 或 0xFFFFFFFF，这两种都按读到文件尾为止
    bool sized = data_size != 0 && data_size != 0xFFFFFFFFu;
    uint32_t left = data_size;
    while (!g_stop && (!sized || left > 0)) {
        size_t want = kStreamCap;
        if (sized && left < want) {
            want = left;
        }
        size_t got = fread(buf, 1, want, f);
        if (got == 0) {
            break;
        }
        if (!audio::Write(buf, got)) {
            break;
        }
        if (sized) {
            left -= static_cast<uint32_t>(got);
        }
    }
    free(buf);
    return true;
}

// 一直喂码流直到文件读完。解码器一次只吃完整帧，所以 consumed 之后的尾巴
// 要挪到缓冲开头再补读，这也是 eof && 无进展 才收尾的原因。
size_t DecodeMp3(FILE* f, void* dec, uint8_t* in, uint8_t* out) {
    size_t in_len = 0;
    bool eof = false;
    bool started = false;
    int idle = 0;
    size_t pcm_bytes = 0;

    while (!g_stop) {
        if (!eof && in_len < kInCap) {
            size_t got = fread(in + in_len, 1, kInCap - in_len, f);
            if (got == 0) {
                eof = true;
            } else {
                in_len += got;
            }
        }
        if (in_len == 0) {
            break;
        }

        esp_audio_dec_in_raw_t raw = {};
        raw.buffer = in;
        raw.len = static_cast<uint32_t>(in_len);
        esp_audio_dec_out_frame_t frame = {};
        frame.buffer = out;
        frame.len = kOutCap;
        esp_audio_dec_info_t info = {};

        const esp_audio_err_t ret = esp_mp3_dec_decode(dec, &raw, &frame, &info);
        if (ret != ESP_AUDIO_ERR_OK && ret != ESP_AUDIO_ERR_DATA_LACK &&
            ret != ESP_AUDIO_ERR_CONTINUE && ret != ESP_AUDIO_ERR_BUFF_NOT_ENOUGH) {
            ESP_LOGW(TAG, "mp3 解码中断 ret=%d", static_cast<int>(ret));
            break;
        }
        if (raw.consumed > in_len) {
            raw.consumed = static_cast<uint32_t>(in_len);
        }
        if (raw.consumed > 0) {
            memmove(in, in + raw.consumed, in_len - raw.consumed);
            in_len -= raw.consumed;
        }
        if (frame.decoded_size > 0) {
            if (!started) {
                // 采样率和声道数要解出第一帧才知道，所以通路是这时候才开的
                const uint8_t channels = info.channel != 0 ? info.channel : 1;
                if (!audio::Begin(info.sample_rate, channels)) {
                    break;
                }
                started = true;
                ESP_LOGI(TAG, "mp3 %uHz %u声道", static_cast<unsigned>(info.sample_rate),
                         static_cast<unsigned>(channels));
            }
            if (!audio::Write(out, frame.decoded_size)) {
                break;
            }
            pcm_bytes += frame.decoded_size;
        }
        if (frame.decoded_size == 0 && raw.consumed == 0) {
            if (++idle >= 3) {
                break;
            }
        } else {
            idle = 0;
        }
    }
    return pcm_bytes;
}

bool PlayMp3(FILE* f) {
    void* dec = nullptr;
    if (esp_mp3_dec_open(nullptr, 0, &dec) != ESP_AUDIO_ERR_OK) {
        ESP_LOGW(TAG, "mp3 解码器打不开");
        return false;
    }

    uint8_t* in = static_cast<uint8_t*>(malloc(kInCap));
    uint8_t* out = static_cast<uint8_t*>(malloc(kOutCap));
    size_t pcm_bytes = 0;

    if (in != nullptr && out != nullptr && fseek(f, 0, SEEK_SET) == 0) {
        pcm_bytes = DecodeMp3(f, dec, in, out);
    }
    free(in);
    free(out);
    esp_mp3_dec_close(dec);

    if (pcm_bytes == 0) {
        ESP_LOGW(TAG, "一个样本都没解出来，文件可能截断了或不是 mp3");
    }
    return pcm_bytes > 0;
}

void PlayOne(const char* word) {
    char path[96];
    if (!ResolvePath(word, path, sizeof(path))) {
        ESP_LOGI(TAG, "%s 没有发音文件", word);
        return;
    }
    FILE* f = fopen(path, "rb");
    if (f == nullptr) {
        ESP_LOGW(TAG, "%s 打不开", path);
        return;
    }

    uint8_t magic[4] = {};
    const bool got_magic = fread(magic, 1, sizeof(magic), f) == sizeof(magic);
    if (got_magic && memcmp(magic, "RIFF", 4) == 0) {
        PlayWav(f);
    } else {
        PlayMp3(f);
    }
    audio::End();
    fclose(f);
}

void Task(void*) {
    Request req;
    while (true) {
        if (xQueueReceive(g_queue, &req, portMAX_DELAY) == pdTRUE) {
            g_stop = false;
            PlayOne(req.word);
        }
    }
}

}  // namespace

namespace pron {

bool Init() {
    if (!audio::Init()) {
        return false;
    }
    g_queue = xQueueCreate(2, sizeof(Request));
    if (g_queue == nullptr) {
        return false;
    }
    xTaskCreate(Task, "pron", 8192, nullptr, 5, nullptr);
    return true;
}

bool HasAudio(const char* word) {
    char path[96];
    return ResolvePath(word, path, sizeof(path));
}

void Play(const char* word) {
    if (g_queue == nullptr || word == nullptr || *word == '\0') {
        return;
    }
    Request req = {};
    snprintf(req.word, sizeof(req.word), "%s", word);
    // 先掐掉当前这段，再清空排队，保证按下去听到的是屏幕上这个词
    g_stop = true;
    xQueueReset(g_queue);
    xQueueSend(g_queue, &req, 0);
}

void Stop() {
    g_stop = true;
    if (g_queue != nullptr) {
        xQueueReset(g_queue);
    }
}

}  // namespace pron
