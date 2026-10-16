#ifndef _WORDCARD_BATTERY_H_
#define _WORDCARD_BATTERY_H_

namespace battery {

bool Init();

// 采样一次（内部 10 次平均 + EMA 平滑）。percent / millivolts 允许传 nullptr。
bool Read(int* percent, int* millivolts);

}  // namespace battery

#endif
