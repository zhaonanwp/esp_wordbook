#include "style_probe.h"

#include "lvgl.h"
#include "rlcd_display.h"

LV_FONT_DECLARE(font_puhui_14_1);
LV_FONT_DECLARE(font_ipa_14_1);

namespace {

constexpr int kWidth = 400;
constexpr int kHeight = 300;
constexpr int kFrameCount = 5;

lv_obj_t* g_root = nullptr;
int g_frame = 0;

lv_obj_t* Block(int x, int y, int w, int h, bool white = false) {
    lv_obj_t* o = lv_obj_create(g_root);
    lv_obj_remove_style_all(o);
    lv_obj_set_size(o, w, h);
    lv_obj_set_pos(o, x, y);
    lv_obj_set_style_bg_color(o, white ? lv_color_white() : lv_color_black(), 0);
    lv_obj_set_style_bg_opa(o, LV_OPA_COVER, 0);
    return o;
}

lv_obj_t* Text(int x, int y, const char* s, const lv_font_t* font = &font_puhui_14_1,
               bool white = false) {
    lv_obj_t* l = lv_label_create(g_root);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, white ? lv_color_white() : lv_color_black(), 0);
    lv_label_set_text(l, s);
    lv_obj_set_pos(l, x, y);
    return l;
}

// 定宽居中，用来测"这行字在这块屏上放得下几个"
lv_obj_t* CenterText(int y, int w, const char* s, const lv_font_t* font, bool white = false) {
    lv_obj_t* l = lv_label_create(g_root);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, white ? lv_color_white() : lv_color_black(), 0);
    lv_obj_set_width(l, w);
    lv_label_set_long_mode(l, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_text(l, s);
    lv_obj_align(l, LV_ALIGN_TOP_MID, 0, y);
    return l;
}

void Frame(const char* name) {
    Text(8, 4, name);
    Text(8, 280, "按键 = 下一帧");
}

// 1 · 线宽：整套 8-bit 骨架的识别度全押在硬边线上，这条不成立风格就塌
void DrawLines() {
    Frame("探针 1/4 · 线宽");
    static const int kWeights[4] = {1, 2, 3, 4};
    const char* kLabels[4] = {"1px 横线", "2px 横线", "3px 横线", "4px 横线"};
    for (int i = 0; i < 4; i++) {
        Block(16, 40 + i * 26, 150, kWeights[i]);
        Text(176, 33 + i * 26, kLabels[i]);
    }
    for (int i = 0; i < 4; i++) {
        Block(250 + i * 26, 40, kWeights[i], 100);
    }
    Text(250, 145, "1 2 3 4px 竖线");

    // 孤立小方块：阶梯角和缺口就是这种东西，看它会不会整块糊掉
    Block(16, 180, 5, 5);
    Block(36, 180, 7, 7);
    Block(58, 180, 10, 10);
    Text(76, 176, "5 / 7 / 10px 孤立方块");

    // 反白块四角盖白 = 阶梯角。真机上如果盖不住或发虚，这手法出局
    Block(16, 206, 140, 54);
    Block(16, 206, 7, 7, true);
    Block(149, 206, 7, 7, true);
    Block(16, 253, 7, 7, true);
    Block(149, 253, 7, 7, true);
    Text(170, 210, "黑块四角盖 7px 白方块");
    Text(170, 230, "= 阶梯角，看角上糊不糊");
}

// 2 · 抖动：游戏机拿细条纹冒充灰阶。这块屏上它是"灰"还是"脏"，一眼定生死
void DrawDither() {
    Frame("探针 2/4 · 抖动 / 灰阶");
    struct Patch {
        int period, on;
        const char* label;
    };
    static const Patch kPatches[4] = {
        {2, 1, "1px 黑 / 1px 白\n= 50%"},
        {3, 1, "1 / 2\n= 33%"},
        {4, 1, "1 / 3\n= 25%"},
        {4, 2, "2 / 2\n= 50% 粗"},
    };
    for (int p = 0; p < 4; p++) {
        const int x0 = 16 + p * 70;
        const Patch& patch = kPatches[p];
        for (int x = 0; x < 60; x += patch.period) {
            Block(x0 + x, 44, patch.on, 54);
        }
        Block(x0, 44, 1, 54);
        Block(x0 + 59, 44, 1, 54);
        Text(x0, 102, patch.label);
    }
    Block(16, 150, 60, 40);
    Text(16, 194, "纯黑对照");
    Block(96, 150, 60, 40);
    for (int x = 0; x < 60; x += 4) {
        Block(96 + x, 150, 2, 2);
    }
    Text(96, 194, "2px 棋盘 50%");
    CenterText(232, kWidth - 40, "条纹/棋盘看起来是「脏」而不是「灰」的话，抖动这条出局",
               &font_puhui_14_1);
}

// 3 · 字体：现在的 14px 中文、IPA、48px 拉丁在这块屏上的实际边界
void DrawFonts() {
    Frame("探针 3/4 · 字体边界");
    Text(16, 36, "14px 中文：杯子");
    Text(16, 58, "14px 中文：我想起来了");
    CenterText(80, kWidth - 32, "今天天气很好我们一起把这周单词背完好吗谢谢", &font_puhui_14_1);
    Text(16, 102, "↑ 上面这行 21 字，看有没有挤到一起");
    CenterText(126, kWidth - 32, "/kʌp/ ˈʌndəreɪt ɪɡˈzæmpl ʃ θ ʒ ŋ ɒ ɜː", &font_ipa_14_1);
    Text(16, 148, "↑ IPA 字体，看生僻音标缺不缺字");
    CenterText(170, kWidth - 16, "cup", &lv_font_montserrat_48);
    CenterText(222, kWidth - 16, "refrigerator", &lv_font_montserrat_48);
    Text(16, 212, "↑ 48px 12 字母：换行还是截断？");
    Text(16, 258, "0123456789  12 / 12");
}

// 4 · 残影：和上一帧互为最大反相，来回按三次，盯住看白字残不残
void DrawInvert() {
    Block(0, 0, kWidth, kHeight);
    CenterText(120, kWidth - 40, "这帧几乎全黑", &font_puhui_14_1, true);
    CenterText(146, kWidth - 40, "按回上一帧（几乎全白）再按回来，重复三次", &font_puhui_14_1, true);
    CenterText(172, kWidth - 40, "盯这行字 5 秒：残影重不重", &font_puhui_14_1, true);
}

void DrawIntro() {
    Frame("探针 0/4 · 说明");
    CenterText(60, kWidth - 40, "这不是产品界面，是量屏用的", &font_puhui_14_1);
    CenterText(96, kWidth - 40, "左键右键都是下一帧，共 5 帧", &font_puhui_14_1);
    CenterText(132, kWidth - 40, "1 线宽 2 抖动 3 字体 4 残影", &font_puhui_14_1);
    CenterText(168, kWidth - 40, "每帧拍张照，我来判", &font_puhui_14_1);
}

void Render() {
    switch (g_frame) {
        case 0: DrawIntro(); break;
        case 1: DrawLines(); break;
        case 2: DrawDither(); break;
        case 3: DrawFonts(); break;
        default: DrawInvert(); break;
    }
}

}  // namespace

void StyleProbe::Show() {
    RlcdDisplay* display = RlcdDisplay::GetInstance();
    display->Lock();
    g_root = display->root();
    lv_obj_clean(g_root);
    Render();
    lv_obj_invalidate(g_root);
    display->Unlock();
}

void StyleProbe::Next() {
    RlcdDisplay* display = RlcdDisplay::GetInstance();
    display->Lock();
    g_root = display->root();
    lv_obj_clean(g_root);
    g_frame = (g_frame + 1) % kFrameCount;
    Render();
    lv_obj_invalidate(g_root);
    display->Unlock();
}
