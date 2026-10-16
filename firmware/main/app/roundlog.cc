#include "roundlog.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <set>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_random.h"

#include "storage.h"

namespace {

constexpr char TAG[] = "RoundLog";
constexpr char kFileName[] = "rounds.tsv";

// storage 分区里的一块追加日志，一轮一块，整块一次写完：
//   R	<uid>	<total>	<forgotten>	<drilling>
//   W	<uid>	<单词>	<0|1>        × total
// 词是文字快照，不是 words.tsv 的下标：app 随时可能整表替换，届时下标指向别的词。
//
// 只有过完进小结的轮次才记（EndRound）。练到一半换模式、被新词表顶掉的那些不记 ——
// 「练了几个词都练到什么程度」这件事，宁可少一轮，也不要一条猜出来的。

std::mutex g_lock;
std::vector<std::string> g_current_words;
std::set<size_t> g_current_forgotten;
bool g_current_drilling = false;
bool g_current_open = false;
bool g_active = false;  // Init 没成就整套不干活：EndRound 攒着没人写会一直吃内存
std::vector<roundlog::Round> g_ready;   // 已过完，等落盘任务写文件
std::vector<roundlog::Round> g_rounds;  // 已写进文件，等 app 取走并确认
uint32_t g_seq = 0;
uint32_t g_nonce = 0;
bool g_rewrite = false;
SemaphoreHandle_t g_wake = nullptr;

std::string Path() { return storage::Path(kFileName); }

// uid = 开机随机数(16 位) + 本次开机内的序号。设备没有可信时间，app 只靠 uid 去重，
// 所以重启后序号从头开始也不要紧 —— 随机数换了，不会和上一轮开机撞号。
uint32_t MakeUid(uint32_t seq) { return (g_nonce << 16) | (seq & 0xFFFF); }

std::string RoundText(const roundlog::Round& round) {
    char head[64];
    snprintf(head, sizeof(head), "R\t%lu\t%d\t%d\t%d\n", static_cast<unsigned long>(round.uid),
             static_cast<int>(round.rows.size()), round.forgotten_count, round.drilling ? 1 : 0);
    std::string text = head;
    for (const auto& row : round.rows) {
        text += "W\t";
        text += std::to_string(round.uid);
        text += '\t';
        text += row.word;
        text += row.forgotten ? "\t1\n" : "\t0\n";
    }
    return text;
}

bool WriteFile(const std::string& body, std::string* err) {
    const std::string path = Path();
    const std::string tmp = path + ".tmp";
    FILE* file = fopen(tmp.c_str(), "wb");
    if (file == nullptr) {
        *err = "打不开 " + tmp;
        return false;
    }
    const bool ok = body.empty() || fwrite(body.data(), body.size(), 1, file) == 1;
    fclose(file);
    if (!ok) {
        remove(tmp.c_str());
        *err = "轮次日志没写完";
        return false;
    }
    // FatFs 的 f_rename 撞见同名目标返回 FR_EXIST，不像 POSIX 那样覆盖（和 wordstore.cc
    // 里音频改名同一个坑）。ack 之后重写文件时 rounds.tsv 必然已经存在，不先删就永远改不动，
    // 已回传的轮次会一直被 app 重新取走。
    remove(path.c_str());
    if (rename(tmp.c_str(), path.c_str()) != 0) {
        *err = "轮次日志改名失败";
        return false;
    }
    return true;
}

bool AppendRound(const roundlog::Round& round, std::string* err) {
    const std::string path = Path();
    FILE* file = fopen(path.c_str(), "ab");  // 文件不存在时 "ab" 自己会建，不用先探一次
    if (file == nullptr) {
        *err = "打不开 " + path;
        return false;
    }
    const std::string body = RoundText(round);
    const bool ok = fwrite(body.data(), body.size(), 1, file) == 1;
    fclose(file);
    if (!ok) {
        *err = "轮次没写进去";
        return false;
    }
    return true;
}

std::vector<std::string> SplitTab(const std::string& line) {
    std::vector<std::string> out;
    size_t from = 0;
    while (true) {
        const size_t tab = line.find('\t', from);
        out.push_back(line.substr(from, tab == std::string::npos ? std::string::npos : tab - from));
        if (tab == std::string::npos) {
            return out;
        }
        from = tab + 1;
    }
}

// 读回来时按块校验：W 行数对不上头部 total 的那一块丢掉。半块（断电截断）也就这样挡住。
void LoadFile() {
    const std::string path = Path();
    FILE* file = fopen(path.c_str(), "rb");
    if (file == nullptr) {
        return;
    }
    std::vector<roundlog::Round> rounds;
    roundlog::Round pending;
    int expect_total = -1;
    int seen_rows = 0;
    bool in_round = false;
    char buf[128];
    while (fgets(buf, sizeof(buf), file) != nullptr) {
        std::string line = buf;
        while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) {
            line.pop_back();
        }
        const std::vector<std::string> f = SplitTab(line);
        if (f.empty()) {
            continue;
        }
        if (f[0] == "R" && f.size() >= 5) {
            if (in_round && seen_rows != expect_total) {
                ESP_LOGW(TAG, "第 %lu 轮行数对不上（%d/%d），丢掉",
                         static_cast<unsigned long>(pending.uid), seen_rows, expect_total);
            }
            pending = roundlog::Round();
            in_round = true;
            seen_rows = 0;
            pending.uid = static_cast<uint32_t>(strtoul(f[1].c_str(), nullptr, 10));
            expect_total = atoi(f[2].c_str());
            pending.forgotten_count = atoi(f[3].c_str());
            pending.drilling = atoi(f[4].c_str()) != 0;
            if ((pending.uid >> 16) == g_nonce) {
                // 同一份开机随机数留下的号（上次崩溃前写的），序号接着走，别撞号。
                g_seq = std::max(g_seq, pending.uid & 0xFFFF);
            }
        } else if (f[0] == "W" && f.size() >= 4 && in_round && pending.uid != 0) {
            // uid 有大约一半概率大于 INT_MAX（高 16 位是开机随机数），atoi 会饱和成
            // 2147483647，于是每两台次开机就有一次的存档整轮判成行数对不上丢掉。
            if (static_cast<uint32_t>(strtoul(f[1].c_str(), nullptr, 10)) != pending.uid) {
                continue;
            }
            roundlog::Row row;
            row.word = f[2];
            row.forgotten = atoi(f[3].c_str()) != 0;
            if (!row.word.empty()) {
                pending.rows.push_back(row);
                seen_rows++;
            }
        }
    }
    fclose(file);
    if (in_round) {
        if (seen_rows == expect_total && !pending.rows.empty()) {
            rounds.push_back(pending);
        } else {
            ESP_LOGW(TAG, "最后第 %lu 轮行数对不上（%d/%d），丢掉",
                     static_cast<unsigned long>(pending.uid), seen_rows, expect_total);
        }
    }
    // 保持文件里的先后顺序：那就是实际练的先后。uid 高 16 位是开机随机数，
    // 按它排序会把后练的那轮排到前面去。
    g_rounds = std::move(rounds);
}

void RewriteAll() {
    std::string body;
    {
        std::lock_guard<std::mutex> lock(g_lock);
        for (const auto& round : g_rounds) {
            body += RoundText(round);
        }
    }
    std::string err;
    if (!WriteFile(body, &err)) {
        ESP_LOGW(TAG, "%s", err.c_str());
    }
}

void WriterTask(void*) {
    while (true) {
        xSemaphoreTake(g_wake, portMAX_DELAY);
        if (g_rewrite) {
            g_rewrite = false;
            RewriteAll();
        }
        while (true) {
            roundlog::Round round;
            {
                std::lock_guard<std::mutex> lock(g_lock);
                if (g_ready.empty()) {
                    break;
                }
                round = std::move(g_ready.front());
                g_ready.erase(g_ready.begin());
                round.uid = MakeUid(++g_seq);
            }
            std::string err;
            if (!AppendRound(round, &err)) {
                // 没落盘就等于这轮没发生过：登记进 pending 会让 app 取到一个
                // 文件里不存在的轮次，ack 时也删不掉它。
                ESP_LOGW(TAG, "%s（uid %lu）", err.c_str(),
                         static_cast<unsigned long>(round.uid));
                continue;
            }
            std::lock_guard<std::mutex> lock(g_lock);
            g_rounds.push_back(round);
        }
    }
}

}  // namespace

namespace roundlog {

bool Init() {
    if (!storage::IsMounted()) {
        return false;
    }
    g_nonce = static_cast<uint32_t>(esp_random()) & 0xFFFF;
    if (g_nonce == 0) {
        g_nonce = 1;
    }
    g_wake = xSemaphoreCreateBinary();
    if (g_wake == nullptr) {
        return false;
    }
    if (xTaskCreate(WriterTask, "roundlog", 8192, nullptr, 3, nullptr) != pdPASS) {
        ESP_LOGW(TAG, "落盘任务起不来，轮次结果只能看屏幕、存不住");
        return false;
    }
    // 任务起来了才碰文件：不然 ack 的改写没人执行，取走的轮次下次开机又冒出来。
    {
        std::lock_guard<std::mutex> lock(g_lock);
        LoadFile();
    }
    g_active = true;
    ESP_LOGI(TAG, "待回传轮次 %u 个", static_cast<unsigned>(g_rounds.size()));
    return true;
}

void Begin(const std::vector<std::string>& words, bool drilling) {
    std::lock_guard<std::mutex> lock(g_lock);
    g_current_words.clear();
    g_current_forgotten.clear();
    g_current_drilling = drilling;
    g_current_open = false;
    if (!g_active) {
        return;
    }
    // 一项都不许挑掉：MarkForgotten 传的是本轮位置，快照必须和闪卡队列逐项对齐。
    g_current_words = words;
    g_current_open = !g_current_words.empty();
}

void MarkForgotten(size_t index) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_current_open || index >= g_current_words.size()) {
        return;
    }
    // 队列里的下标一轮内不重复，同一个词最多标一次，所以这里只管记，不用去重。
    g_current_forgotten.insert(index);
}

void EndRound() {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_current_open) {
        return;
    }
    Round round;
    round.drilling = g_current_drilling;
    round.rows.reserve(g_current_words.size());
    for (size_t i = 0; i < g_current_words.size(); i++) {
        if (g_current_words[i].empty()) {
            continue;  // 空词条只在写盘时丢，位置对齐要保住
        }
        Row row;
        row.word = g_current_words[i];
        row.forgotten = g_current_forgotten.count(i) != 0;
        if (row.forgotten) {
            round.forgotten_count++;
        }
        round.rows.push_back(std::move(row));
    }
    if (round.rows.empty()) {
        // 一轮一行都没有（词表里 word 全空）就别写：total=0 的空块 app 取不到任何
        // result_rows，ack 不到，stat 里永远挂着一条清不掉的轮次。
        g_current_words.clear();
        g_current_forgotten.clear();
        g_current_open = false;
        return;
    }
    g_ready.push_back(std::move(round));
    g_current_words.clear();
    g_current_forgotten.clear();
    g_current_open = false;
    if (g_wake != nullptr) {
        xSemaphoreGive(g_wake);
    }
}

void PendingSummary(int* rounds, int* words, uint32_t* oldest_uid) {
    std::lock_guard<std::mutex> lock(g_lock);
    *rounds = static_cast<int>(g_rounds.size());
    *words = 0;
    for (const auto& round : g_rounds) {
        *words += static_cast<int>(round.rows.size());
    }
    *oldest_uid = g_rounds.empty() ? 0 : g_rounds.front().uid;
}

bool Get(uint32_t uid, Round* out) {
    std::lock_guard<std::mutex> lock(g_lock);
    for (const auto& round : g_rounds) {
        if (round.uid == uid) {
            *out = round;
            return true;
        }
    }
    return false;
}

bool Ack(uint32_t uid, std::string* err) {
    {
        std::lock_guard<std::mutex> lock(g_lock);
        const size_t before = g_rounds.size();
        g_rounds.erase(std::remove_if(g_rounds.begin(), g_rounds.end(),
                                      [uid](const Round& r) { return r.uid == uid; }),
                       g_rounds.end());
        if (g_rounds.size() == before) {
            *err = "没有这一轮: " + std::to_string(uid);
            return false;
        }
        g_rewrite = true;
    }
    if (g_wake != nullptr) {
        xSemaphoreGive(g_wake);
    }
    return true;
}

}  // namespace roundlog
