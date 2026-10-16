#include "card_ui.h"

#include <cstdio>
#include <cstring>

#include "board/rlcd_display.h"
#include "board/config.h"

LV_FONT_DECLARE(font_puhui_14_1);
// 普惠字库没有 ɜ（third /θɜːd/ 这周就要用），音标单独用只含拉丁+IPA 的小字库。
// 音标和音节走 18px 那一档（同一份源、同一批码位，只是 --size 换成 18）；
// 小结页那串错词留在 14px，一行放得下 50 来个字母，换到 18px 就少两行容量。
LV_FONT_DECLARE(font_ipa_14_1);
LV_FONT_DECLARE(font_ipa_18_1);
// 像素中文走 24px 那一档（Fusion Pixel 12px 设计档按整数 2× 栅格化，1bpp 下笔画是干净的
// 2×2 块）。20px（10px 设计 ×2）2026-10-14 实拍被"模"这个字否掉了：14 画塞进 18 像素宽，
// 笔画之间的缝只剩 2 格，字库里存的就是连成片的（墨量 59%，同屏的"式"只有 41%）。
// 24px 下同一个字 47%，缝拉开了。生成方法和字表来源见 tools/fonts/gen_font.js。
LV_FONT_DECLARE(font_pixel_24_1);

namespace {

// 底部提示条。全宽常驻，是唯一能替代触摸可发现性的东西，所以任何一屏都不能少它。
constexpr int kBarHeight = 28;
constexpr int kBarY = RLCD_HEIGHT - kBarHeight;

// 8-bit 骨架那圈硬边。卡框居中，这样内容继续沿用 TOP_MID 对齐就正好落在框内；
// 偏移黑块和阶梯缺口都是实心矩形，一个都不依赖 LVGL 的模糊阴影 API。
// 屏 400 宽，框左右各只让 8px：这套皮靠硬边线撑，内容宽度比留白值钱。
constexpr int kFrameWidth = 384;
constexpr int kFrameHeight = 248;
constexpr int kFrameX = (RLCD_WIDTH - kFrameWidth) / 2;
constexpr int kFrameY = 8;
// 双线框：外 3px + 2px 白缝 + 内 2px，四边等宽。
// 上一版是 8px 硬偏移黑块，它只压在右边和下边，实拍读出来是"右边框 11px、左边框 3px"的
// 不对称框；四角那圈 7px 白缺口又把左下角的边框啃断。两处都是 2026-10-14 实拍否掉的。
constexpr int kFrameBorder = 3;
constexpr int kFrameGap = 2;
constexpr int kInnerBorder = 2;
constexpr int kFrameInset = kFrameBorder + kFrameGap + kInnerBorder;

constexpr int kInnerX = kFrameX + kFrameInset;
constexpr int kInnerWidth = kFrameWidth - kFrameInset * 2;
constexpr int kInnerY = kFrameY + kFrameInset;
constexpr int kInnerBottom = kFrameY + kFrameHeight - kFrameInset;

// 顶部反白带 = 状态区。原来"这屏是什么"和"第几个词"都挤在底部提示条一句话里，
// 拆到带上以后底部只剩按键说明。
// 带上的字跟着中文走像素字库，带高 = 一个 line_height，所以中文换档这里跟着动。
constexpr int kBandHeight = 32;
constexpr int kBandTextInset = 8;

// 纵排的位置全部由行框高度推出来，不再各条手写数字：
// 24px 像素中文的 line_height 是 32（字身 22 + 行距），montserrat_48 是 52，
// IPA 那一档（18px）是 22。
constexpr int kBigLine = 32;
constexpr int kLatinLine = 52;
constexpr int kIpaLine = 22;

// 卡面是一条固定的竖排：单词 → 音标（+音节）→ 释义。模式只决定哪一段不画，
// 不再挪位置、也不再盖黑块。2026-10-14 撤掉例句和整块遮罩之后，这套才成立：
// 遮罩一撤，答案就得靠"空着"来表达，位置必须固定，否则揭开时整屏的东西都在跳。
// 同一批改动里分隔线也删了——它标的是"题目/答案"的边界，而那条边界现在由空不空决定，
// 一根横杠反而像个坏点。
//
// 24px 下一行放得下 15 个汉字（内框 370 宽），释义给三行 = 45 字，
// 词表里最长的释义（128 字节上限 ≈ 42 字）不用再截断。超出的仍然必须在 setText 前截掉
// （见 FitToLines）——LVGL 的 label 会按内容自己长高，第四行会直接压到框底以外。
constexpr int kMeaningLines = 3;

constexpr int kWordY = kInnerY + kBandHeight;                  // 47
constexpr int kPhoneticY = kWordY + kLatinLine + 8;            // 107
constexpr int kSyllableY = kPhoneticY + kIpaLine;              // 129
// 释义紧跟在音节那一格下面起排，整条竖排从上往下连成一块。
// 之前是贴底排（165..249），实拍（wolf 那张）证明不行：只有一行的释义会浮在中间，
// 上面空 40px、下面空 56px，看着像漏画了一块。现在空的都攒到框底。
// 三行 96px 正好排到 247，内框底沿 249 —— 中文这一档没有再大的余地了。
constexpr int kMeaningY = kSyllableY + kIpaLine;               // 151
// 小结页：标题借音标那一格，错词串从它下面一行起，排到内框底 249 能容 6 行。
constexpr int kSummaryCaptionY = kPhoneticY;                   // 107
constexpr int kSummaryListY = kSummaryCaptionY + kBigLine;     // 139
// 音量页：七档就七格，不用连续滑条。
constexpr int kVolumeSegY = kPhoneticY + kBigLine + 12;        // 151

// 分段进度条。格间靠各自 2px 边框分开，整条按 count 居中排。
constexpr int kSegWidth = 340;
constexpr int kSegHeight = 16;
constexpr int kSegBorder = 2;
constexpr int kVolumeLevels = 7;

// 音标段里 app 和固件之间的分隔符，见 SplitPhonetic。
constexpr char kPhoneticSplit = '|';

// 模式菜单：三行都是 2px 硬边框的空心盒，每行左边一个空心标记盒，选中行加粗到 3px 并填黑。
// 刻意不用整条翻黑——题目态那块大黑遮罩已经占掉「黑 = 遮住」这个语义，
// 再让「黑 = 选中」就两义冲突。
// 行高 48 / 间距 62，三行从 61 排到 233，在内框（15..249）里上下居中。
// 「整表 从头重来」那行 2026-10-14 删了：从第 7 个词倒回第 1 个重过一遍没有价值，
// 而小结页右键本来就是「全部重来」，重复入口。行宽铺满内框，不再自己让。
constexpr int kMenuRowY = 61;
constexpr int kMenuRowHeight = 48;
constexpr int kMenuRowPitch = 62;
constexpr int kMenuRowWidth = kInnerWidth;
constexpr int kMenuX = (RLCD_WIDTH - kMenuRowWidth) / 2;
constexpr int kMenuBorder = 2;
constexpr int kMenuBorderSelected = 3;
// 每行左边一个空心标记盒，选中那行把它填黑。
// 设计稿画的是实心三角，但 LVGL 9 没有填充多边形；上一版只在选中行画一块悬空的小黑块，
// 实拍（2026-10-14）认不出来是哪一行的。给每行一个固定位置的框，眼睛只需要找那个实心格。
// 刻意不把整行翻黑：那是每按一次键挪动 370×48 的实心黑，这块屏的残影还没量过。
constexpr int kMarkerWidth = 16;
constexpr int kMarkerHeight = 24;
constexpr int kMarkerBorder = 2;
constexpr int kMarkerInset = 6;

// montserrat_48 的下划线约 27px 宽，13 个字母连排 351px，卡框内宽 370 放得下、14 个放不下。
constexpr size_t kMaxSlotLetters = 13;

// 低电预警时占掉整条提示条的那行字。按键提示让位，因为这时候"该充电"比"怎么翻页"要紧。
constexpr char kLowBatteryBarText[] = "电量低 请充电";

// 电池图标：黑底提示条上"挖"出来的白框，靠内层黑块留出 2px 描边。
constexpr int kBatteryX = 10;
constexpr int kBatteryY = 8;
constexpr int kBatteryWidth = 24;
constexpr int kBatteryHeight = 12;
constexpr int kBatteryInset = 2;
constexpr int kBatteryCapWidth = 2;
// 按键提示从图标右边起排，留出凸点和一点呼吸
constexpr int kBarTextX = kBatteryX + kBatteryWidth + kBatteryCapWidth + 8;

void MakeInvertedRect(lv_obj_t* parent, lv_obj_t** obj, int x, int y, int width, int height) {
    *obj = lv_obj_create(parent);
    lv_obj_remove_style_all(*obj);
    lv_obj_set_size(*obj, width, height);
    lv_obj_set_style_bg_color(*obj, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(*obj, LV_OPA_COVER, 0);
    lv_obj_set_pos(*obj, x, y);
}

void MakeWhiteRect(lv_obj_t* parent, lv_obj_t** obj, int x, int y, int width, int height) {
    *obj = lv_obj_create(parent);
    lv_obj_remove_style_all(*obj);
    lv_obj_set_size(*obj, width, height);
    lv_obj_set_style_bg_color(*obj, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(*obj, LV_OPA_COVER, 0);
    lv_obj_set_pos(*obj, x, y);
}

// 硬边空心盒：0 圆角 + 指定宽度的黑边框，白底。整套骨架的描边都是它。
void MakeHardBox(lv_obj_t* parent, lv_obj_t** obj, int x, int y, int width, int height,
                 int border) {
    *obj = lv_obj_create(parent);
    lv_obj_remove_style_all(*obj);
    lv_obj_set_size(*obj, width, height);
    lv_obj_set_pos(*obj, x, y);
    lv_obj_set_style_bg_color(*obj, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(*obj, LV_OPA_COVER, 0);
    lv_obj_set_style_border_color(*obj, lv_color_black(), 0);
    lv_obj_set_style_border_width(*obj, border, 0);
    lv_obj_set_style_border_side(*obj, LV_BORDER_SIDE_FULL, 0);
    lv_obj_set_style_radius(*obj, 0, 0);
}

void ApplyBatteryFill(lv_obj_t* fill, int percent) {
    int inner = kBatteryWidth - kBatteryInset * 2;
    int height = kBatteryHeight - kBatteryInset * 2;
    if (percent < 0) {
        percent = 0;
    } else if (percent > 100) {
        percent = 100;
    }
    int width = inner * percent / 100;
    if (width > 0) {
        lv_obj_set_size(fill, width, height);
        lv_obj_clear_flag(fill, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(fill, LV_OBJ_FLAG_HIDDEN);
    }
}

lv_obj_t* MakeLabel(lv_obj_t* parent, const lv_font_t* font, int y, int width, bool white_text) {
    lv_obj_t* label = lv_label_create(parent);
    lv_obj_set_style_text_font(label, font, 0);
    lv_obj_set_style_text_color(label, white_text ? lv_color_white() : lv_color_black(), 0);
    lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_width(label, width);
    lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);
    lv_obj_align(label, LV_ALIGN_TOP_MID, 0, y);
    return label;
}

// 音节拆分是搭音标段送过来的：`ʌmˈbrelə|um·bre·lla`。一条词条只有四个定长字段
// （wordbook.h 的 WordEntry），BLE 协议冻着加不了第五个，所以在这儿切开还原。
// 没有 '|' 的就是老词表（包括 ble_push.py 推的那批），音节那串留空、一行都不画。
void SplitPhonetic(const char* packed, char* ipa, size_t ipa_size, char* syllables,
                   size_t syllable_size) {
    const char* mark = strchr(packed, kPhoneticSplit);
    if (mark == nullptr) {
        snprintf(ipa, ipa_size, "%s", packed);
        syllables[0] = '\0';
        return;
    }
    snprintf(ipa, ipa_size, "%.*s", static_cast<int>(mark - packed), packed);
    snprintf(syllables, syllable_size, "%s", mark + 1);
}

// 按行数上限截断，尾部补省略号。LVGL 的 label 会按内容自己长高，溢出的那一行直接压到
// 下一段上（2026-10-14 实拍：释义长过两行时把音标行都盖了）。
// 只在 UTF-8 字符边界上切。逐字前缀试排而不是手算字宽：一条释义最多 128 字节，
// 几百次 lv_text_get_size 的量级在这里根本不构成开销，但少一套和 LVGL 不一致的排版逻辑。
void FitToLines(const char* text, const lv_font_t* font, int max_width, int max_lines, char* out,
                size_t out_size) {
    lv_point_t size;
    lv_text_get_size(&size, text, font, 0, 0, max_width, LV_TEXT_FLAG_NONE);
    if (size.y <= font->line_height * max_lines) {
        snprintf(out, out_size, "%s", text);
        return;
    }

    int keep = 0;
    for (const char* p = text; *p != '\0';) {
        uint8_t head = static_cast<uint8_t>(*p);
        int step = head >= 0xF0 ? 4 : head >= 0xE0 ? 3 : head >= 0xC0 ? 2 : 1;
        snprintf(out, out_size, "%.*s…", keep + step, text);
        lv_text_get_size(&size, out, font, 0, 0, max_width, LV_TEXT_FLAG_NONE);
        if (size.y > font->line_height * max_lines) {
            break;
        }
        keep += step;
        p += step;
    }
    snprintf(out, out_size, "%.*s…", keep, text);
}

}  // namespace

void CardUi::BuildLetterSlots(const char* word, char* out, size_t out_size) {
    out[0] = '\0';
    if (word == nullptr || out_size < 2) {
        return;
    }

    size_t length = strnlen(word, kMaxSlotLetters + 1);
    if (length == 0) {
        return;
    }
    // 太长的词排不下，就按屏宽上限给空位。这里不能退回整词，题目态显示整词等于直接给答案。
    if (length > kMaxSlotLetters) {
        length = kMaxSlotLetters;
    }

    for (size_t i = 0; i < length; i++) {
        out[i] = '_';
    }
    out[length] = '\0';
}

void CardUi::EnsureWidgets() {
    if (layer_ != nullptr) {
        return;
    }

    lv_obj_t* root = RlcdDisplay::GetInstance()->root();

    // ShowTestCard 的标签直接挂在屏幕上，不清掉会和卡片文字叠在一起
    lv_obj_clean(root);

    layer_ = lv_obj_create(root);
    lv_obj_remove_style_all(layer_);
    lv_obj_set_size(layer_, RLCD_WIDTH, RLCD_HEIGHT);
    lv_obj_align(layer_, LV_ALIGN_CENTER, 0, 0);

    // 创建顺序 = 由下到上：外线框 → 内线框 → 顶部反白带。
    MakeHardBox(layer_, &frame_, kFrameX, kFrameY, kFrameWidth, kFrameHeight, kFrameBorder);
    MakeHardBox(layer_, &inner_frame_, kFrameX + kFrameBorder + kFrameGap,
                kFrameY + kFrameBorder + kFrameGap,
                kFrameWidth - (kFrameBorder + kFrameGap) * 2,
                kFrameHeight - (kFrameBorder + kFrameGap) * 2, kInnerBorder);

    MakeInvertedRect(layer_, &band_, kInnerX, kInnerY, kInnerWidth, kBandHeight);
    band_left_ = lv_label_create(band_);
    lv_obj_set_style_text_font(band_left_, &font_pixel_24_1, 0);
    lv_obj_set_style_text_color(band_left_, lv_color_white(), 0);
    lv_obj_align(band_left_, LV_ALIGN_LEFT_MID, kBandTextInset, 0);
    band_right_ = lv_label_create(band_);
    lv_obj_set_style_text_font(band_right_, &font_pixel_24_1, 0);
    lv_obj_set_style_text_color(band_right_, lv_color_white(), 0);
    lv_obj_align(band_right_, LV_ALIGN_RIGHT_MID, -kBandTextInset, 0);

    word_label_ = MakeLabel(layer_, &lv_font_montserrat_48, kWordY, kInnerWidth, false);

    meaning_label_ = MakeLabel(layer_, &font_pixel_24_1, kMeaningY, kInnerWidth, false);

    phonetic_label_ = MakeLabel(layer_, &font_ipa_18_1, kPhoneticY, kInnerWidth, false);
    // 音节里带 IPA 字符的话也画得出来，这一档字库收全了 0x20-0xFF
    syllable_label_ = MakeLabel(layer_, &font_ipa_18_1, kSyllableY, kInnerWidth, false);
    // 小结页那串错词，卡面上不用
    wordlist_label_ = MakeLabel(layer_, &font_ipa_14_1, kSummaryListY, kInnerWidth, false);

    // 分段条的格子池：每格自带 2px 硬边框，涂黑的格子和空格子的区别是整块实心 vs 空心，
    // 所以就算 2px 边框在这块屏上发虚，读出来的还是"实心 = 到这一档"。
    for (int i = 0; i < kMaxSegments; i++) {
        MakeHardBox(layer_, &seg_cell_[i], 0, 0, 1, 1, kSegBorder);
        lv_obj_add_flag(seg_cell_[i], LV_OBJ_FLAG_HIDDEN);
    }

    bar_ = lv_obj_create(layer_);
    lv_obj_remove_style_all(bar_);
    lv_obj_set_size(bar_, RLCD_WIDTH, kBarHeight);
    lv_obj_set_style_bg_color(bar_, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(bar_, LV_OPA_COVER, 0);
    lv_obj_set_pos(bar_, 0, kBarY);

    bar_label_ = lv_label_create(bar_);
    lv_obj_set_style_text_font(bar_label_, &font_puhui_14_1, 0);
    lv_obj_set_style_text_color(bar_label_, lv_color_white(), 0);
    lv_obj_align(bar_label_, LV_ALIGN_LEFT_MID, kBarTextX, 0);

    MakeWhiteRect(bar_, &battery_shell_, kBatteryX, kBatteryY, kBatteryWidth, kBatteryHeight);
    MakeInvertedRect(bar_, &battery_hollow_, kBatteryX + kBatteryInset, kBatteryY + kBatteryInset,
                     kBatteryWidth - kBatteryInset * 2, kBatteryHeight - kBatteryInset * 2);
    MakeWhiteRect(bar_, &battery_fill_, kBatteryX + kBatteryInset, kBatteryY + kBatteryInset, 0,
                  kBatteryHeight - kBatteryInset * 2);
    MakeWhiteRect(bar_, &battery_cap_, kBatteryX + kBatteryWidth, kBatteryY + 3, kBatteryCapWidth,
                  kBatteryHeight - 6);

    if (battery_percent_ < 0) {
        lv_obj_add_flag(battery_shell_, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(battery_hollow_, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(battery_fill_, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(battery_cap_, LV_OBJ_FLAG_HIDDEN);
    } else {
        ApplyBatteryFill(battery_fill_, battery_percent_);
    }
}

void CardUi::SetBarText(const char* text) {
    snprintf(bar_text_, sizeof(bar_text_), "%s", text);
    lv_label_set_text(bar_label_, low_battery_warning_ ? kLowBatteryBarText : text);
}

void CardUi::SetBand(const char* left, const char* right) {
    lv_label_set_text(band_left_, left);
    lv_label_set_text(band_right_, right);
}

void CardUi::ShowSegments(int y, const uint8_t* on, int count) {
    if (on == nullptr || count <= 0 || count > kMaxSegments) {
        HideSegments();
        return;
    }

    // 格子各带 2px 边框，再左右各让开 1px：实心格之间留得住一道白缝，
    // 不然相邻的实心格会连成一根黑条，"一格一档"就读不出来了。
    const int cell_width = kSegWidth / count;
    const int x0 = (RLCD_WIDTH - cell_width * count) / 2;
    for (int i = 0; i < kMaxSegments; i++) {
        if (i >= count) {
            lv_obj_add_flag(seg_cell_[i], LV_OBJ_FLAG_HIDDEN);
            continue;
        }
        lv_obj_set_size(seg_cell_[i], cell_width - 2, kSegHeight);
        lv_obj_set_pos(seg_cell_[i], x0 + i * cell_width + 1, y);
        lv_obj_set_style_bg_color(seg_cell_[i], on[i] ? lv_color_black() : lv_color_white(), 0);
        lv_obj_clear_flag(seg_cell_[i], LV_OBJ_FLAG_HIDDEN);
    }
}

void CardUi::HideSegments() {
    for (int i = 0; i < kMaxSegments; i++) {
        lv_obj_add_flag(seg_cell_[i], LV_OBJ_FLAG_HIDDEN);
    }
}

void CardUi::SetCardWidgetsHidden(bool hidden) {
    lv_obj_t* widgets[] = {word_label_, meaning_label_, phonetic_label_, wordlist_label_,
                           syllable_label_};
    for (lv_obj_t* widget : widgets) {
        if (hidden) {
            lv_obj_add_flag(widget, LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_clear_flag(widget, LV_OBJ_FLAG_HIDDEN);
        }
    }
}

void CardUi::EnsureMenu() {
    if (menu_ != nullptr) {
        return;
    }

    menu_ = lv_obj_create(layer_);
    lv_obj_remove_style_all(menu_);
    lv_obj_set_size(menu_, RLCD_WIDTH, RLCD_HEIGHT);
    lv_obj_align(menu_, LV_ALIGN_CENTER, 0, 0);

    for (size_t i = 0; i < kRowCount; i++) {
        MakeHardBox(menu_, &menu_row_box_[i], kMenuX, kMenuRowY + i * kMenuRowPitch, kMenuRowWidth,
                    kMenuRowHeight, kMenuBorder);
        // 标记盒压在行框之上，靠自己的白底和行框的白底连成一片
        MakeHardBox(menu_, &menu_marker_[i], kMenuX + kMenuBorder + kMarkerInset,
                    kMenuRowY + i * kMenuRowPitch + (kMenuRowHeight - kMarkerHeight) / 2,
                    kMarkerWidth, kMarkerHeight, kMarkerBorder);
        menu_row_label_[i] =
            MakeLabel(menu_, &font_pixel_24_1,
                      kMenuRowY + i * kMenuRowPitch + (kMenuRowHeight - kBigLine) / 2,
                      kMenuRowWidth, false);
    }
}

void CardUi::ShowMenu(size_t item, size_t total_words, size_t unknown, int volume) {
    RlcdDisplay* display = RlcdDisplay::GetInstance();

    display->Lock();
    EnsureWidgets();
    SetCardWidgetsHidden(true);
    HideSegments();
    EnsureMenu();
    // 离开菜单时整组是隐藏的，回来必须自己掀开，否则第二次进就是白屏
    lv_obj_clear_flag(menu_, LV_OBJ_FLAG_HIDDEN);

    // 白带一行只放得下 15 个汉字（内框 370，减去两侧 8px 缩进）：左"模式菜单"96px +
    // 右"共 30 词 · 想不起来 5"约 276px 就叠上了，所以缩成"忘 5"。20px 那档放得下长写法，
    // 换回 24 又放不下 —— 短写法是字号换来的，不是随手省字。
    char overview[48];
    if (unknown == 0) {
        snprintf(overview, sizeof(overview), "共 %u 词", static_cast<unsigned>(total_words));
    } else {
        snprintf(overview, sizeof(overview), "共 %u 词 · 忘 %u", static_cast<unsigned>(total_words),
                 static_cast<unsigned>(unknown));
    }
    SetBand("模式菜单", overview);

    static const char* kRowLabels[kRowCount] = {"拼词  中→英", "认词  英→中", "音量"};
    for (size_t i = 0; i < kRowCount; i++) {
        char text[24];
        if (i == kRowVolume) {
            snprintf(text, sizeof(text), "音量  %d", volume);
        } else {
            snprintf(text, sizeof(text), "%s", kRowLabels[i]);
        }
        const bool selected = i == item;
        // 选中 = 行框从 2px 加粗到 3px + 左边的标记盒填黑。文字一律黑字，不翻白。
        lv_obj_set_style_border_width(menu_row_box_[i],
                                      selected ? kMenuBorderSelected : kMenuBorder, 0);
        lv_obj_set_style_bg_color(menu_marker_[i], selected ? lv_color_black() : lv_color_white(),
                                  0);
        lv_label_set_text(menu_row_label_[i], text);
    }

    SetBarText("左键 换   右键 确认   长按左键 退出");
    lv_obj_invalidate(layer_);
    display->Unlock();
}

void CardUi::ShowCard(const WordEntry& entry, size_t index, size_t total, State state,
                      Direction dir) {
    RlcdDisplay* display = RlcdDisplay::GetInstance();

    display->Lock();
    EnsureWidgets();
    SetCardWidgetsHidden(false);
    HideSegments();
    if (menu_ != nullptr) {
        lv_obj_add_flag(menu_, LV_OBJ_FLAG_HIDDEN);
    }

    const bool cn_to_en = dir == Direction::kCnToEn;

    char count[16];
    snprintf(count, sizeof(count), "%u / %u", static_cast<unsigned>(index + 1),
             static_cast<unsigned>(total));
    SetBand(cn_to_en ? "拼词" : "认词", count);

    // 大字：拼词模式题目态只给一排下划线，一个字母一条，不透露任何字母；
    // 认词模式的题目本来就是英文整词。
    char slots[kMaxSlotLetters + 2];
    BuildLetterSlots(entry.word, slots, sizeof(slots));
    const bool show_slots = cn_to_en && state == State::kQuestion && slots[0] != '\0';
    lv_label_set_text(word_label_, show_slots ? slots : entry.word);

    // 音节拆分搭音标段送过来，这里切开还原（见 SplitPhonetic）
    char ipa[96];
    char syllables[96];
    SplitPhonetic(entry.phonetic, ipa, sizeof(ipa), syllables, sizeof(syllables));

    // 释义贴底三行，超出的截断。ShowSummary / ShowVolume 把这一格借去当别的用了，
    // 位置必须在这里挪回来。
    char meaning[192];
    FitToLines(entry.meaning, &font_pixel_24_1, kInnerWidth, kMeaningLines, meaning, sizeof(meaning));
    lv_label_set_text(meaning_label_, meaning);
    lv_obj_align(meaning_label_, LV_ALIGN_TOP_MID, 0, kMeaningY);

    // 拼词问"怎么写"：音标和音节是答案，题目态这两格空着。
    // 认词问"什么意思"：音标跟着题目走，音节不涉及拼写，两态都不显示；释义反过来空着。
    const bool revealed = state == State::kAnswer;
    const bool show_phonetic = *ipa != '\0' && (revealed || !cn_to_en);
    const bool show_syllable = *syllables != '\0' && revealed && cn_to_en;
    const bool show_meaning = revealed || cn_to_en;

    lv_obj_add_flag(wordlist_label_, LV_OBJ_FLAG_HIDDEN);
    if (show_phonetic) {
        lv_label_set_text(phonetic_label_, ipa);
        lv_obj_clear_flag(phonetic_label_, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(phonetic_label_, LV_OBJ_FLAG_HIDDEN);
    }
    if (show_syllable) {
        lv_label_set_text(syllable_label_, syllables);
        lv_obj_clear_flag(syllable_label_, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(syllable_label_, LV_OBJ_FLAG_HIDDEN);
    }
    if (show_meaning) {
        lv_obj_clear_flag(meaning_label_, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(meaning_label_, LV_OBJ_FLAG_HIDDEN);
    }

    // 模式和第几个词已经搬到顶部白带上了，底部这条只剩按键说明。
    char bar[96];
    if (state == State::kQuestion) {
        snprintf(bar, sizeof(bar), "左键揭开 右键想不起来");
    } else {
        snprintf(bar, sizeof(bar), "左键下一个 长按右键听发音");
    }
    SetBarText(bar);

    lv_obj_invalidate(layer_);
    display->Unlock();
}

void CardUi::ShowSummary(size_t total, size_t unknown, const char* unknown_words, bool drilling) {
    RlcdDisplay* display = RlcdDisplay::GetInstance();

    display->Lock();
    EnsureWidgets();
    SetCardWidgetsHidden(false);
    if (menu_ != nullptr) {
        lv_obj_add_flag(menu_, LV_OBJ_FLAG_HIDDEN);
    }

    lv_obj_add_flag(phonetic_label_, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(syllable_label_, LV_OBJ_FLAG_HIDDEN);

    // 和 ShowMenu 那条同源：短写法是 24px 时代留下的，理由见那边的注释。
    char head[48];
    snprintf(head, sizeof(head), "共 %u 词 · 忘 %u", static_cast<unsigned>(total),
             static_cast<unsigned>(unknown));
    SetBand("本轮结束", head);

    // 大字号那档只有拉丁字形，所以数字单独摆，中文另起一行
    char big[16];
    snprintf(big, sizeof(big), "%u / %u", static_cast<unsigned>(unknown), static_cast<unsigned>(total));
    lv_label_set_text(word_label_, big);
    // 标题占卡面上音标那一格，错词串从它下面起
    lv_label_set_text(meaning_label_, unknown == 0 ? "全部想起来了" : "想不起来的词");
    lv_obj_align(meaning_label_, LV_ALIGN_TOP_MID, 0, kSummaryCaptionY);

    if (unknown > 0 && unknown_words != nullptr && *unknown_words) {
        lv_label_set_text(wordlist_label_, unknown_words);
        lv_obj_align(wordlist_label_, LV_ALIGN_TOP_MID, 0, kSummaryListY);
        lv_obj_clear_flag(wordlist_label_, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(wordlist_label_, LV_OBJ_FLAG_HIDDEN);
    }

    // 错词列表从 140 一直排到内框底 249，能容 6 行（14px 一行 50 来个字母）。
    // 原来这里还有一条一轮一词的分段条，2026-10-14 去掉：一屏 30 格、一格 11px，
    // 数得过来但读不出信息，"哪几个没想起来"下面那串词已经说得更准。

    char bar[96];
    if (unknown == 0) {
        snprintf(bar, sizeof(bar), "左键 全部重来");
    } else if (drilling) {
        snprintf(bar, sizeof(bar), "左键 回整表   右键 再练这%u个", static_cast<unsigned>(unknown));
    } else {
        snprintf(bar, sizeof(bar), "左键 只练这%u个   右键 全部重来", static_cast<unsigned>(unknown));
    }
    SetBarText(bar);

    lv_obj_invalidate(layer_);
    display->Unlock();
}

void CardUi::ShowVolume(int percent, int level, const char* test_word) {
    RlcdDisplay* display = RlcdDisplay::GetInstance();

    display->Lock();
    EnsureWidgets();
    SetCardWidgetsHidden(false);
    if (menu_ != nullptr) {
        lv_obj_add_flag(menu_, LV_OBJ_FLAG_HIDDEN);
    }

    char step[24];
    snprintf(step, sizeof(step), "第 %d / %d 档", level, kVolumeLevels);
    SetBand("音量", step);

    char big[8];
    snprintf(big, sizeof(big), "%d", percent);
    lv_label_set_text(word_label_, big);
    // 试听词借音标那一格（像素字库的拉丁字形够用），没有试听词就把原来白带右侧那句
    // 提示挪下来，不留一行空白。ShowCard 把释义贴在框底，这里必须自己挪上来。
    lv_label_set_text(meaning_label_,
                      (test_word != nullptr && *test_word) ? test_word : "改完自动保存");
    lv_obj_align(meaning_label_, LV_ALIGN_TOP_MID, 0, kPhoneticY);

    lv_obj_add_flag(phonetic_label_, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(syllable_label_, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(wordlist_label_, LV_OBJ_FLAG_HIDDEN);
    // 档位是七个离散值，滑条在这种屏上反而读不出来，一格一档
    uint8_t on[kVolumeLevels];
    for (int i = 0; i < kVolumeLevels; i++) {
        on[i] = i < level ? 1 : 0;
    }
    ShowSegments(kVolumeSegY, on, kVolumeLevels);

    SetBarText("左键减小 右键增大 长按左键回菜单");
    lv_obj_invalidate(layer_);
    display->Unlock();
}

void CardUi::ShowNotice(const char* title, const char* detail) {
    RlcdDisplay* display = RlcdDisplay::GetInstance();

    display->Lock();
    lv_obj_clean(display->root());
    layer_ = nullptr;
    frame_ = nullptr;
    inner_frame_ = nullptr;
    band_ = nullptr;
    band_left_ = nullptr;
    band_right_ = nullptr;
    for (int i = 0; i < kMaxSegments; i++) {
        seg_cell_[i] = nullptr;
    }
    menu_ = nullptr;
    for (size_t i = 0; i < kRowCount; i++) {
        menu_row_box_[i] = nullptr;
        menu_marker_[i] = nullptr;
        menu_row_label_[i] = nullptr;
    }
    battery_shell_ = nullptr;
    battery_hollow_ = nullptr;
    battery_fill_ = nullptr;
    battery_cap_ = nullptr;
    bar_ = nullptr;
    bar_label_ = nullptr;

    lv_obj_t* label = lv_label_create(display->root());
    lv_obj_set_style_text_font(label, &font_pixel_24_1, 0);
    lv_obj_set_style_text_color(label, lv_color_black(), 0);
    lv_obj_set_width(label, RLCD_WIDTH - 32);
    lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_text_fmt(label, "%s\n\n%s", title, detail);
    lv_obj_align(label, LV_ALIGN_CENTER, 0, -kBarHeight / 2);
    lv_obj_invalidate(display->root());
    display->Unlock();
}

void CardUi::ShowBarHint(const char* text) {
    RlcdDisplay* display = RlcdDisplay::GetInstance();

    display->Lock();
    // ShowNotice 之后卡片层被整屏清掉了，这时不该硬造一层出来
    if (layer_ != nullptr && bar_label_ != nullptr) {
        // 直接写标签，不走 SetBarText：即时反馈（"这个词没有发音"）不该被预警文字顶掉，
        // 也不该混进整屏那行字的存档里。下一次整屏重绘会把它覆盖回去。
        lv_label_set_text(bar_label_, text);
        lv_obj_invalidate(bar_);
    }
    display->Unlock();
}

void CardUi::SetLowBatteryWarning(bool on) {
    if (low_battery_warning_ == on) {
        return;
    }
    RlcdDisplay* display = RlcdDisplay::GetInstance();

    display->Lock();
    low_battery_warning_ = on;
    // notice 屏没有提示条（整屏被清过），这里不能硬造一层，等下一次整屏重绘自然带上。
    // SetBarText 传存档的那行字：开预警时它被顶掉，关预警时原样还回去。
    if (layer_ != nullptr && bar_label_ != nullptr) {
        SetBarText(bar_text_);
        lv_obj_invalidate(bar_);
    }
    display->Unlock();
}

void CardUi::SetBattery(int percent) {
    RlcdDisplay* display = RlcdDisplay::GetInstance();

    display->Lock();
    battery_percent_ = percent;
    if (battery_shell_ != nullptr) {
        lv_obj_clear_flag(battery_shell_, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(battery_hollow_, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(battery_cap_, LV_OBJ_FLAG_HIDDEN);
        ApplyBatteryFill(battery_fill_, percent);
        lv_obj_invalidate(battery_shell_);
        lv_obj_invalidate(battery_hollow_);
        lv_obj_invalidate(battery_fill_);
        lv_obj_invalidate(battery_cap_);
    }
    display->Unlock();
}
