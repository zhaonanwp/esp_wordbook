#include "wordstore.h"

#include <cctype>
#include <cstdio>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>

#include "esp_log.h"
#include "esp_rom_crc.h"
#include "esp_vfs_fat.h"

#include "storage.h"

static const char* TAG = "Wordstore";

namespace {

constexpr const char* kTsv = "words.tsv";
constexpr const char* kTsvTmp = "words.tsv.tmp";
constexpr const char* kTsvBak = "words.bak";
constexpr const char* kAudioDir = "audio";

// 单个 TSV 字段的上限。BLE 一条消息本来就塞不进 509 字节以上，
// 超了只能说明 app 拼错了，截断比丢掉整词好。
constexpr size_t kWordCap = 32;
constexpr size_t kPhoneticCap = 64;
constexpr size_t kMeaningCap = 128;
constexpr size_t kExampleCap = 256;

// 按字节截断会把多字节汉字切成半个，LVGL 画出来是缺字方块。
// 找到最后一个码点的起始字节，长度不够就整段不要。
void CloseUtf8(char* s, size_t len) {
    if (len == 0) {
        s[0] = '\0';
        return;
    }
    size_t start = len;
    while (start > 0 && (static_cast<uint8_t>(s[start - 1]) & 0xC0) == 0x80) {
        start--;
    }
    uint8_t head = static_cast<uint8_t>(s[start]);
    size_t need = head < 0x80 ? 1 : (head < 0xE0 ? 2 : (head < 0xF0 ? 3 : 4));
    s[(len - start >= need) ? len : start] = '\0';
}

void CopyField(char* dst, size_t cap, const char* src) {
    size_t n = 0;
    if (src != nullptr) {
        for (; src[n] != '\0' && n + 1 < cap; n++) {
            char c = src[n];
            dst[n] = (c == '\t' || c == '\n' || c == '\r') ? ' ' : c;
        }
    }
    dst[n] = '\0';
    CloseUtf8(dst, n);
}

bool Exists(const std::string& path) {
    return access(path.c_str(), F_OK) == 0;
}

}  // namespace

bool Wordstore::Slug(const char* word, char* out, size_t cap) {
    if (word == nullptr) {
        return false;
    }
    size_t n = 0;
    for (const uint8_t* p = reinterpret_cast<const uint8_t*>(word); *p != '\0'; p++) {
        uint8_t raw = *p;
        char c;
        if (raw >= 'A' && raw <= 'Z') {
            c = static_cast<char>(raw - 'A' + 'a');
        } else if ((raw >= 'a' && raw <= 'z') || (raw >= '0' && raw <= '9')) {
            c = static_cast<char>(raw);
        } else if (raw == ' ' || raw == '-' || raw == '_') {
            c = '-';
        } else {
            return false;  // 含 '/' '.' 非 ASCII 等，直接拒绝当文件名
        }
        if (c == '-' && (n == 0 || out[n - 1] == '-')) {
            continue;
        }
        if (n + 1 >= cap) {
            return false;
        }
        out[n++] = c;
    }
    while (n > 0 && out[n - 1] == '-') {
        n--;
    }
    out[n] = '\0';
    return n > 0;
}

std::string Wordstore::AudioPath(const char* word, const char* fmt) {
    char slug[40];
    if (!Slug(word, slug, sizeof(slug))) {
        return std::string();
    }
    return std::string(storage::kMountPoint) + "/" + kAudioDir + "/" + slug + "." + fmt;
}

void Wordstore::Recover() {
    std::string dir = storage::Path(kAudioDir);
    mkdir(dir.c_str(), 0777);

    // 上一轮改名改到一半掉电：正式词表没了但备份还在，先还回去。
    std::string tsv = storage::Path(kTsv);
    std::string bak = storage::Path(kTsvBak);
    if (!Exists(tsv) && Exists(bak)) {
        if (rename(bak.c_str(), tsv.c_str()) == 0) {
            ESP_LOGW(TAG, "上次推送中断，已从 %s 恢复词表", kTsvBak);
        }
    }
    remove(storage::Path(kTsvTmp).c_str());
}

bool Wordstore::BeginWordbook(std::string* err) {
    if (audio_ != nullptr) {
        *err = "有音频正在传输，先 au_end";
        return false;
    }
    if (tsv_ != nullptr) {
        *err = "上一轮词表还没 wb_end";
        return false;
    }
    words_received_ = 0;

    tsv_ = fopen(storage::Path(kTsvTmp).c_str(), "wb");
    if (tsv_ == nullptr) {
        *err = std::string("打不开 ") + kTsvTmp;
        return false;
    }
    return true;
}

bool Wordstore::AddWord(const char* word, const char* phonetic, const char* meaning,
                        const char* example, std::string* err) {
    if (tsv_ == nullptr) {
        *err = "没收到 wb_begin";
        return false;
    }

    char w[kWordCap], p[kPhoneticCap], m[kMeaningCap], s[kExampleCap];
    CopyField(w, sizeof(w), word);
    CopyField(p, sizeof(p), phonetic);
    CopyField(m, sizeof(m), meaning);
    CopyField(s, sizeof(s), example);

    if (w[0] == '\0' || w[0] == '#') {
        *err = "词条没有单词字段";
        return false;
    }

    fprintf(tsv_, "%s\t%s\t%s\t%s\n", w, p, m, s);
    words_received_++;
    return true;
}

bool Wordstore::EndWordbook(std::string* err) {
    if (tsv_ == nullptr) {
        *err = "没有正在传输的词表";
        return false;
    }
    fclose(tsv_);
    tsv_ = nullptr;

    if (words_received_ == 0) {
        remove(storage::Path(kTsvTmp).c_str());
        *err = "一个词都没收到，旧词表保留";
        return false;
    }

    std::string tsv = storage::Path(kTsv);
    std::string bak = storage::Path(kTsvBak);
    std::string tmp = storage::Path(kTsvTmp);

    // FAT 的 rename 遇到同名目标会失败，所以先把旧表挪开再改名，
    // 两步之间掉电的情况由 Recover() 从 bak 兜底。
    remove(bak.c_str());
    bool had_old = Exists(tsv);
    if (had_old && rename(tsv.c_str(), bak.c_str()) != 0) {
        remove(tmp.c_str());
        *err = "旧词表挪不去 bak";
        return false;
    }
    if (rename(tmp.c_str(), tsv.c_str()) != 0) {
        if (had_old) {
            rename(bak.c_str(), tsv.c_str());
        }
        *err = "tmp 改名成 words.tsv 失败（磁盘可能满了）";
        return false;
    }
    remove(bak.c_str());

    ESP_LOGI(TAG, "词表更新完成，%d 条", words_received_);
    return true;
}

void Wordstore::AbortWordbook() {
    if (tsv_ != nullptr) {
        fclose(tsv_);
        tsv_ = nullptr;
    }
    remove(storage::Path(kTsvTmp).c_str());
    words_received_ = 0;
}

bool Wordstore::BeginAudio(const char* word, const char* fmt, uint32_t len, uint32_t crc32,
                           std::string* err) {
    if (tsv_ != nullptr) {
        *err = "词表还在传输中，先 wb_end";
        return false;
    }
    if (audio_ != nullptr) {
        AbortAudio();
    }
    if (len == 0 || len > 512u * 1024u) {
        *err = "音频长度不合理";
        return false;
    }
    if (strcmp(fmt, "mp3") != 0 && strcmp(fmt, "wav") != 0) {
        *err = std::string("不支持的容器: ") + fmt;
        return false;
    }

    char slug[40];
    if (!Slug(word, slug, sizeof(slug))) {
        *err = "这个词不能做文件名";
        return false;
    }

    uint64_t free_bytes = 0, total_bytes = 0;
    if (!FreeBytes(&free_bytes, &total_bytes)) {
        *err = "读不到剩余空间";
        return false;
    }
    // .part 改成正名还要再占一份目录项和簇，留 4KB 余量。
    if (static_cast<uint64_t>(len) + 4096 > free_bytes) {
        *err = "storage 只剩 " + std::to_string(free_bytes / 1024) + "KB，放不下 "
               + std::to_string(len / 1024) + "KB";
        return false;
    }

    snprintf(audio_slug_, sizeof(audio_slug_), "%s", slug);
    snprintf(audio_fmt_, sizeof(audio_fmt_), "%s", fmt);
    snprintf(audio_part_, sizeof(audio_part_), "%s/%s/%s.%s.part", storage::kMountPoint,
             kAudioDir, slug, fmt);
    snprintf(audio_final_, sizeof(audio_final_), "%s/%s/%s.%s", storage::kMountPoint,
             kAudioDir, slug, fmt);

    audio_ = fopen(audio_part_, "wb");
    if (audio_ == nullptr) {
        *err = std::string("打不开 ") + audio_part_;
        return false;
    }
    audio_len_ = len;
    audio_written_ = 0;
    audio_crc_ = crc32;
    audio_run_crc_ = 0;
    return true;
}

bool Wordstore::AddAudioData(const uint8_t* data, size_t len, std::string* err) {
    if (audio_ == nullptr) {
        *err = "没收到 au_begin";
        return false;
    }
    if (audio_written_ + len > audio_len_) {
        *err = "收到的字节比声明的多";
        AbortAudio();
        return false;
    }
    if (fwrite(data, 1, len, audio_) != len) {
        *err = "写 FAT 失败（磁盘满？）";
        AbortAudio();
        return false;
    }
    audio_run_crc_ = esp_rom_crc32_le(audio_run_crc_, data, static_cast<unsigned>(len));
    audio_written_ += static_cast<uint32_t>(len);
    return true;
}

bool Wordstore::EndAudio(std::string* err) {
    if (audio_ == nullptr) {
        *err = "没有正在传输的音频";
        return false;
    }
    fclose(audio_);
    audio_ = nullptr;

    if (audio_written_ != audio_len_ || audio_run_crc_ != audio_crc_) {
        audio_failed_++;
        remove(audio_part_);
        *err = "校验不过（" + std::to_string(audio_written_) + "/"
               + std::to_string(audio_len_) + " 字节），这个词没有发音";
        return false;
    }

    // FatFs 的 f_rename 撞见同名目标返回 FR_EXIST，不会像 POSIX 那样覆盖（ff.c FAT32 分支），
    // 所以重推同一个词必须先删掉旧文件：否则整份音频传完、长度和 crc 都对上了，
    // 才在最后一步失败。中间断电就丢这一个词的发音，下次重推即可。
    remove(audio_final_);
    if (rename(audio_part_, audio_final_) != 0) {
        audio_failed_++;
        remove(audio_part_);
        *err = std::string("改名失败: ") + audio_final_;
        return false;
    }

    // 同一个词换容器重推（有道偶尔给 mp3 偶尔给 wav）时不留两份。
    const char* other = (strcmp(audio_fmt_, "mp3") == 0) ? "wav" : "mp3";
    char stale[96];
    snprintf(stale, sizeof(stale), "%s/%s/%s.%s", storage::kMountPoint, kAudioDir,
             audio_slug_, other);
    remove(stale);

    audio_ok_++;
    ESP_LOGI(TAG, "发音已存 %s (%u 字节)", audio_final_, static_cast<unsigned>(audio_len_));
    return true;
}

void Wordstore::AbortAudio() {
    if (audio_ != nullptr) {
        fclose(audio_);
        audio_ = nullptr;
        audio_failed_++;
    }
    if (audio_part_[0] != '\0') {
        remove(audio_part_);
    }
}

bool Wordstore::FreeBytes(uint64_t* free_bytes, uint64_t* total_bytes) {
    if (!storage::IsMounted()) {
        return false;
    }
    return esp_vfs_fat_info(storage::kMountPoint, total_bytes, free_bytes) == ESP_OK;
}
