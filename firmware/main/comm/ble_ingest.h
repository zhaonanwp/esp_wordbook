#ifndef _WORDCARD_BLE_INGEST_H_
#define _WORDCARD_BLE_INGEST_H_

#include <cstdint>
#include <functional>
#include <string>

class Wordstore;

// 单词机不联网，词表和发音全靠手机 app 往这三个特征写：
//
//   0xFFE0  service
//   0xFFE1  write      JSON 命令，一条一个 ATT 写，上限 509 字节（MTU 512 − 3）
//   0xFFE2  read|notify 设备回报；app 必须先写 CCCD 订阅，否则收不到任何错误
//   0xFFE3  write      音频裸帧
//
// JSON 命令（"t" 是类型，字段缺省即空串）:
//   {"t":"wb_begin","n":12,"v":"2026W41"}
//   {"t":"wb_word","w":"cold","p":"kəʊld","m":"n. 感冒","s":"Lily has got a cold."}
//   {"t":"wb_end"}
//   {"t":"au_begin","w":"cold","fmt":"mp3","len":11234,"crc32":4046945303}
//   {"t":"au_end"}
//   {"t":"stat"}
//
// 0xFFE3 帧头 10 字节：A5 5A | type=1 | flags(bit0 首帧 bit1 末帧) | offset u32 小端
//   | payload 长度 u16 小端 | payload。offset 必须等于已收字节数，
//   对不上就整条废弃并回错误，app 重推这个词。
//
// fmt 必须由 app 按文件头魔数判定（"mp3" / "wav"），有道的 Content-Type 不可信。
// crc32 是标准 CRC-32（多项式 0xEDB88320，即 CRC32("123456789") = 0xCBF43926），
// 无符号 32 位，超过 int 范围时按 double 取。
namespace ble {

struct Callbacks {
    // words.tsv 已被整表替换，请上层重载词表。在 ingest 任务里调，不是 BLE 协议栈线程。
    std::function<void()> wordbook_replaced;
    // 屏幕进度与错误，上层直接送 ShowNotice。已经按 ~400ms 节流，收尾会强制刷一次。
    std::function<void(const std::string& title, const std::string& detail)> notice;
};

bool Init(Wordstore* store, Callbacks callbacks);

bool Connected();

}  // namespace ble

#endif
