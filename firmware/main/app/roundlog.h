#ifndef _WORDCARD_ROUNDLOG_H_
#define _WORDCARD_ROUNDLOG_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

// 一轮练习的结果：这轮过的是哪些词、哪个被按了「想不起来」。
//
// 设备只存事实，不存结论：没有墙钟，判不出「这轮是哪一天」，档位和归账日期都由
// 手机 app 定。手机上设备是断开状态练的，所以结果必须活过关机 —— 落 rounds.tsv，
// 等 app 连上取走、确认入账之后才删。
namespace roundlog {

struct Row {
    std::string word;
    bool forgotten = false;
};

struct Round {
    // 本次开机随机数拼上开机内序号：跨重启不重号，app 那边靠它去重，
    // 不需要设备有可信时间。
    uint32_t uid = 0;
    bool drilling = false;  // 错词重练的一轮，也算一轮
    std::vector<Row> rows;
    int forgotten_count = 0;
};

// 读回 rounds.tsv 里还没确认掉的轮次，并起落盘任务。storage 没挂上就返回 false。
bool Init();

// 开一轮。词按本轮顺序存文字快照而不是词表下标 —— app 随时可能整表替换，
// 届时下标会指向另一个词。
void Begin(const std::vector<std::string>& words, bool drilling);

// 右键短按标记当前词。只动内存：按键回调跑在 esp_timer 任务，栈只有 3584，
// 在这儿写盘就是一次复位（音量落盘踩过的坑，见 main.cc 的 RequestVolumeSave）。
void MarkForgotten(size_t index);

// 一轮过完（进小结）。数据交给落盘任务，这里不等文件写完。
void EndRound();

// 只数数不拷贝，给 stat 用：轮数、总行数、最早一轮的 uid（没有轮次时 uid 为 0）。
void PendingSummary(int* rounds, int* words, uint32_t* oldest_uid);

// 取某一轮的完整内容（app 按 PendingSummary 报出来的 uid 来要）。
bool Get(uint32_t uid, Round* out);

// app 确认这轮已入账，从文件里去掉。在 BLE 任务里调，落盘任务不并发写同一个文件。
bool Ack(uint32_t uid, std::string* err);

}  // namespace roundlog

#endif
