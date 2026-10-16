#ifndef _WORDCARD_STYLE_PROBE_H_
#define _WORDCARD_STYLE_PROBE_H_

// 一次性测量工具，不是产品界面。
//
// 8-bit 风格方案里有三件事只有真屏能判，浏览器样机判不了：
//   1. 1~4px 的硬边线在这块反射屏上看不看得见（整套风格的识别度全押在这上面）
//   2. 大面积实心黑来回翻转时的残影有多重（决定"反白带 + 硬偏移块"能不能用）
//   3. 14px 中文 / IPA / 48px 拉丁在这块屏上的实际观感和边界
//
// 用法：main.cc 里把 kStyleProbe 置 true，单独烧一次；两个按键翻页，量完改回 false。
class StyleProbe {
public:
    static void Show();  // 画当前帧
    static void Next();  // 翻到下一帧（按键回调调）
};

#endif
