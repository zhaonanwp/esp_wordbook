#ifndef _WORDCARD_WORDSTORE_H_
#define _WORDCARD_WORDSTORE_H_

#include <cstddef>
#include <cstdint>
#include <string>

// storage 分区（挂在 /wordbook）里的词库文件由这一层独占写入：
//   words.tsv        设备读的正式词表
//   words.tsv.tmp    BLE 推送过程中的临时文件
//   words.bak        改名前的旧词表，用来在掉电后恢复
//   audio/<slug>.mp3 逐词发音（slug 由词本身推出）
// BLE 传输层只管收字节，容器格式、容量、命名都在这里挡掉。
class Wordstore {
public:
    // 挂载后调一次：建 audio 目录，并把掉电中断留下的半套状态收拾干净。
    void Recover();

    // 一轮词表推送。BeginWordbook 会另开 tmp，已存在的正式词表此刻不受影响。
    bool BeginWordbook(std::string* err);
    bool AddWord(const char* word, const char* phonetic, const char* meaning,
                 const char* example, std::string* err);
    bool EndWordbook(std::string* err);
    void AbortWordbook();

    // 一个词的发音。fmt 必须由 app 按文件头魔数判定（mp3 / wav）——
    // 有道的 Content-Type 会把 RIFF/WAVE 也报成 audio/mpeg，设备端不信 header。
    bool BeginAudio(const char* word, const char* fmt, uint32_t len, uint32_t crc32,
                    std::string* err);
    bool AddAudioData(const uint8_t* data, size_t len, std::string* err);
    bool EndAudio(std::string* err);
    void AbortAudio();

    bool FreeBytes(uint64_t* free_bytes, uint64_t* total_bytes);

    // 词 → 文件名。只允许 a-z0-9 和连字符，大写转小写，空格转 '-'，
    // 首尾和连续连字符去掉。含非 ASCII（中文、重音字母）一律拒绝，
    // 这样 BLE 收到的字符串不可能拼出 ".." 或 '/' 这种路径。
    static bool Slug(const char* word, char* out, size_t cap);

    // audio/<slug>.<fmt>，供播放侧直接用。slug 非法返回空串。
    static std::string AudioPath(const char* word, const char* fmt);

    // 设备当前词表的条数由上层在每次 Load 之后回填，BLE 侧只负责在 stat 里报给 app。
    void SetStoredWords(int count) { stored_words_ = count; }

    int words_received() const { return words_received_; }
    int stored_words() const { return stored_words_; }
    int audio_ok() const { return audio_ok_; }
    int audio_failed() const { return audio_failed_; }
    bool audio_open() const { return audio_ != nullptr; }
    uint32_t audio_written() const { return audio_written_; }

private:
    FILE* tsv_ = nullptr;
    int words_received_ = 0;
    int stored_words_ = 0;

    FILE* audio_ = nullptr;
    char audio_part_[96] = "";     // 正在写的 .part
    char audio_final_[96] = "";    // 校验通过后改名成
    char audio_slug_[40] = "";
    char audio_fmt_[8] = "";
    uint32_t audio_len_ = 0;
    uint32_t audio_written_ = 0;
    uint32_t audio_crc_ = 0;
    uint32_t audio_run_crc_ = 0;
    int audio_ok_ = 0;
    int audio_failed_ = 0;
};

#endif
