#ifndef _RLCD_DISPLAY_H_
#define _RLCD_DISPLAY_H_

#include <cstdint>
#include "lvgl.h"
#include "rlcd_driver.h"

// RLCD + LVGL 显示层
//
// 沿用现有工程在这块屏上验证过的做法：
//   esp_lvgl_port 管 LVGL 任务/定时器/锁，display 手动 lv_display_create，
//   整屏 RGB565 缓冲放 PSRAM，PARTIAL 模式下把 flush 区间转成 1-bit 推给驱动。
class RlcdDisplay {
public:
    static RlcdDisplay* GetInstance();

    lv_obj_t* root() const { return screen_; }

    // 所有 UI 改动都要包在 Lock/Unlock 之间（或直接调用 CallOnLvglTask）
    void Lock();
    void Unlock();
    void CallOnLvglTask(void (*fn)(void* user), void* user);

    // 里程碑自检用：黑底白字显示两行文本
    void ShowTestCard(const char* line1, const char* line2);

private:
    RlcdDisplay() = default;
    void Init();

    static void FlushCb(lv_display_t* disp, const lv_area_t* area, uint8_t* color_p);

    RlcdDriver* rlcd_ = nullptr;
    lv_display_t* display_ = nullptr;
    lv_obj_t* screen_ = nullptr;
    lv_obj_t* line1_label_ = nullptr;
    lv_obj_t* line2_label_ = nullptr;
    bool ready_ = false;
};

#endif
