#ifndef _WORDCARD_CARD_UI_H_
#define _WORDCARD_CARD_UI_H_

#include "lvgl.h"
#include "wordbook.h"

// 词卡界面：一块屏只放一个词。
// 这块屏是 1-bit 的。中文走 20px 像素字库（Fusion Pixel 10px 设计稿整数 2 倍放大，每个设计
// 像素是一个干净的 2×2 黑块）；音节和小结页那串错词留在 14px 那一档，卡面上不放例句。
//
// 版面是"8-bit 骨架"那套：识别度全部由硬边承担——0 圆角、四边等宽的双线卡框、
// 顶部反白带、分段进度条，没有任何灰阶或阴影 API。
//
// 卡面是一条固定的竖排，位置从不因模式而变：单词 → 音标（+音节）→ 中文释义。
// 两个方向只是藏掉其中一段：拼词藏答案（音标、音节），认词藏中文。kQuestion/kAnswer
// 切换的就是"哪一段空着"，不画遮罩。低刷新率的 RLCD 上没挪动的像素不翻色，残影最小。
class CardUi {
public:
    static constexpr size_t kRowCount = 3;  // 菜单行数：拼词 / 认词 / 音量

    // 菜单行序。按键分支也按这个走，所以放在这里而不是两边各写一遍。
    static constexpr size_t kRowCnToEn = 0;
    static constexpr size_t kRowEnToCn = 1;
    static constexpr size_t kRowVolume = 2;

    enum class State {
        kQuestion,  // 答案那几行空着，只给题目
        kAnswer,    // 揭开答案
    };

    // 闪卡方向。两种都保留：拼词（中→英）和听写同方向、是主模式；
    // 认词（英→中）题目就是英文本身，藏的是中文释义那一格。
    enum class Direction {
        kCnToEn,
        kEnToCn,
    };

    // 显示一张词卡。index 从 0 开始，total 为本轮队列条数。
    void ShowCard(const WordEntry& entry, size_t index, size_t total, State state, Direction dir);

    // 空态 / 错误态：居中标题 + 说明文字
    void ShowNotice(const char* title, const char* detail);

    // 一轮过完的小结页。total / unknown 是本轮队列的长度和"想不起来"的条数，
    // unknown_words 是它们拼在一起的单词（可以为空串）。
    // drilling 表示本轮已经是错词重练，左键的提示要换成"回到整表"。
    void ShowSummary(size_t total, size_t unknown, const char* unknown_words, bool drilling);

    // 模式菜单（左键长按进出）。item 是光标行；total_words / unknown 拼成顶部白带的右侧。
    // volume 显示在"音量"那一行上。
    void ShowMenu(size_t item, size_t total_words, size_t unknown, int volume);

    // 音量调节页（从菜单的"音量"行进）。test_word 是改动后拿来试听的那个词，
    // 空串表示它没有发音文件，那就只剩数字变化。level 是第几档（1~7），分段条涂黑这么多格。
    void ShowVolume(int percent, int level, const char* test_word);

    // 底部提示条左端的电池图标。负数表示还没测出来，整个图标隐藏。
    void SetBattery(int percent);

    // 低电预警：开着的时候，提示条那一行固定写"电量低 请充电"，盖掉按键提示。
    // 词卡/菜单/小结/音量页都走同一个提示条，所以开关一次就全生效；
    // ShowBarHint 的即时反馈（比如"这个词没有发音"）不受这个开关影响。
    void SetLowBatteryWarning(bool on);

    // 只改底部提示条的一行字（发音有没有之类的即时反馈），不动卡片内容。
    // 下一次 ShowCard / ShowMenu 会把它覆盖掉。
    void ShowBarHint(const char* text);

    // 题目里那排下划线：一个字母一条，不给任何字母提示（"cup" → "___"）。
    // 词超过屏幕能放下的长度时按上限截断，词为空才返回空串。
    static void BuildLetterSlots(const char* word, char* out, size_t out_size);

private:
    // 分段进度条的格子池大小。现在只有音量页的七档在用（小结页那条已经删了）。
    static constexpr int kMaxSegments = 8;

    void EnsureWidgets();
    void EnsureMenu();
    void SetCardWidgetsHidden(bool hidden);
    void SetBarText(const char* text);
    // 顶部反白带 = 状态区：左边写这一屏是什么，右边写计数。
    void SetBand(const char* left, const char* right);
    // 分段进度条。count 格，on[i] 非 0 的那格整块涂黑、其余只留边框——离散量就该一格一格。
    // on 为 nullptr、count 为 0 或超过格子池就整条藏掉。
    void ShowSegments(int y, const uint8_t* on, int count);
    void HideSegments();

    lv_obj_t* layer_ = nullptr;

    // 8-bit 骨架那圈硬边装饰：外 3px + 2px 白缝 + 内 2px 的双线框，四边等宽。
    // 上一版的 8px 硬偏移黑块只压住右边和下边，实拍读成左右边框不等宽，已经去掉。
    lv_obj_t* frame_ = nullptr;
    lv_obj_t* inner_frame_ = nullptr;
    lv_obj_t* band_ = nullptr;
    lv_obj_t* band_left_ = nullptr;
    lv_obj_t* band_right_ = nullptr;

    lv_obj_t* word_label_ = nullptr;
    lv_obj_t* meaning_label_ = nullptr;
    lv_obj_t* phonetic_label_ = nullptr;
    lv_obj_t* wordlist_label_ = nullptr;
    // 音节拆分（um·bre·lla），从音标段里切出来的那半，只在揭开答案后画
    lv_obj_t* syllable_label_ = nullptr;

    // 分段进度条：音量的七档、小结的对错格，共用这一池对象（同一时刻只有一屏在用）
    lv_obj_t* seg_cell_[kMaxSegments] = {};

    // ShowNotice 会整屏清掉对象，这些指针必须一起置空，否则下次用到悬垂。
    lv_obj_t* menu_ = nullptr;
    lv_obj_t* menu_row_box_[kRowCount] = {};
    lv_obj_t* menu_row_label_[kRowCount] = {};
    // 每行左边那个标记盒：选中行填黑，其余留空心
    lv_obj_t* menu_marker_[kRowCount] = {};

    lv_obj_t* bar_ = nullptr;
    lv_obj_t* bar_label_ = nullptr;
    lv_obj_t* battery_shell_ = nullptr;
    lv_obj_t* battery_hollow_ = nullptr;
    lv_obj_t* battery_fill_ = nullptr;
    lv_obj_t* battery_cap_ = nullptr;
    int battery_percent_ = -1;

    // 低电预警开关 + 提示条上"本来该写什么"。预警关掉时要能原样还回去，
    // 所以 SetBarText 每次把收到的文字留一份。
    bool low_battery_warning_ = false;
    char bar_text_[128] = "";
};

#endif
