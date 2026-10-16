#ifndef _WORDCARD_BATTERYLOG_H_
#define _WORDCARD_BATTERYLOG_H_

#include <cstdint>

namespace batterylog {

// Append 的 flags 位。
constexpr uint8_t kFlagWarn = 1 << 0;  // 低电预警档
constexpr uint8_t kFlagDead = 1 << 1;  // 过放冻结档

// 往 storage 分区的 batlog.bin 追加一条定长记录，写完就关（不长期占文件句柄）。
// seq 由文件当前长度推出来，所以重开机 / 换词表把文件清空了也不会和上一批混在一起。
// 没挂载、写失败都静默跳过 —— 日志不能影响背单词。
void Append(int millivolts, int percent, uint8_t flags);

}  // namespace batterylog

#endif
