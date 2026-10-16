#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <numeric>
#include <string>
#include <vector>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "nvs_flash.h"

#include "button_gpio.h"
#include "iot_button.h"
#include "nvs.h"

#include "app/batterylog.h"
#include "app/card_ui.h"
#include "app/pronouncer.h"
#include "app/storage.h"
#include "app/style_probe.h"
#include "app/wordbook.h"
#include "app/wordstore.h"
#include "board/audio_out.h"
#include "board/battery.h"
#include "board/config.h"
#include "board/rlcd_display.h"
#include "comm/ble_ingest.h"

static const char* TAG = "WordCard";

namespace {

// 量屏用的临时开关：true 时整机只跑 StyleProbe，闪卡/BLE/发音都不起。
// 探针要单独烧一次，量完改回 false 再正常构建，所以默认关。
constexpr bool kStyleProbe = false;

struct Viewer {
    CardUi* ui = nullptr;
    Wordbook* book = nullptr;
    Wordstore* store = nullptr;

    // 本轮要过的词（词表下标）。闪卡是单向队列，过完进小结，小结再决定下一轮的队列。
    std::vector<size_t> queue;
    size_t pos = 0;
    // 本轮按了"想不起来"的词。只活在内存里：关机清零，统计以后由手机 app 取。
    std::vector<size_t> unknown;
    bool drilling = false;  // 本轮是不是错词重练
    bool at_summary = false;
    bool in_menu = false;
    bool at_volume = false;
    size_t menu_item = 0;
    bool revealed = false;
    // 方向只在内存里，默认拼词（中→英）—— 和听写同方向，是主模式。
    CardUi::Direction direction = CardUi::Direction::kCnToEn;
    // 音量 0-100（0 是静音），唯一一个落 NVS 的设置：这是要给小孩自己按的。
    int volume = audio::kDefaultVolume;
    // 电芯到过放线。真位由 BatteryTask 维护，按键入口读到它就什么都不做，
    // 直到电压回到恢复线（插充电）才自动解冻。
    bool battery_dead = false;

    // 按键任务和 BLE ingest 任务都会碰 book：重载会清空内部缓冲区，
    // 翻页正在读同一批指针，必须挡住。
    std::mutex mutex;
};

Viewer viewer;

// 音量就七档，够用又不用一直按。0 档是静音，小孩在别人旁边时用得上。
constexpr int kVolumeSteps[] = {0, 25, 45, 60, 75, 90, 100};
constexpr int kVolumeStepCount = static_cast<int>(sizeof(kVolumeSteps) / sizeof(kVolumeSteps[0]));

// 当前百分比离哪档最近就是哪档（NVS 里存的可能是老版本留下的任意值）。
int VolumeLevel(int percent) {
    int nearest = 0;
    for (int i = 1; i < kVolumeStepCount; i++) {
        if (abs(kVolumeSteps[i] - percent) < abs(kVolumeSteps[nearest] - percent)) {
            nearest = i;
        }
    }
    return nearest;
}

int StepVolume(int current, int direction) {
    int next = VolumeLevel(current) + direction;
    if (next < 0) {
        next = 0;
    } else if (next > kVolumeStepCount - 1) {
        next = kVolumeStepCount - 1;
    }
    return kVolumeSteps[next];
}

int LoadVolume() {
    nvs_handle_t handle = 0;
    if (nvs_open("wordcard", NVS_READONLY, &handle) != ESP_OK) {
        return audio::kDefaultVolume;
    }
    uint8_t saved = 0;
    const esp_err_t err = nvs_get_u8(handle, "vol", &saved);
    nvs_close(handle);
    if (err != ESP_OK || saved > 100) {
        return audio::kDefaultVolume;
    }
    return saved;
}

void SaveVolume(int percent) {
    nvs_handle_t handle = 0;
    if (nvs_open("wordcard", NVS_READWRITE, &handle) != ESP_OK) {
        return;
    }
    nvs_set_u8(handle, "vol", static_cast<uint8_t>(percent));
    nvs_commit(handle);
    nvs_close(handle);
}

TaskHandle_t g_volume_save_task = nullptr;

// 攒着写：等的时候又来几次就只落最后那一个，省 flash 寿命也省时间。
void VolumeSaveTask(void*) {
    while (true) {
        uint32_t percent = 0;
        xTaskNotifyWait(0, UINT32_MAX, &percent, portMAX_DELAY);
        SaveVolume(static_cast<int>(percent));
    }
}

// esp_button 的回调跑在 esp_timer 任务里，栈只有 CONFIG_ESP_TIMER_TASK_STACK_SIZE=3584，
// NVS + flash 写塞不下，而且 commit 会把整个 esp_timer 卡住 —— 实测就是一按音量就复位。
// 所以按键那边只递个数过来，写盘在这个有自己的栈的任务里做。
void RequestVolumeSave(int percent) {
    if (g_volume_save_task != nullptr) {
        xTaskNotify(g_volume_save_task, static_cast<uint32_t>(percent), eSetValueWithOverwrite);
    }
}

std::vector<size_t> AllIndices() {
    std::vector<size_t> indices(viewer.book->Count());
    std::iota(indices.begin(), indices.end(), 0);
    return indices;
}

// 一轮过完的小结：错词列表拼成一串交给 UI，装不下就截断，别溢到提示条上。
void ShowSummaryPage() {
    char words[256];
    size_t used = 0;
    words[0] = '\0';
    for (size_t i = 0; i < viewer.unknown.size(); i++) {
        const char* word = viewer.book->At(viewer.unknown[i]).word;
        int wrote = snprintf(words + used, sizeof(words) - used, i ? "  %s" : "%s", word);
        if (wrote < 0 || static_cast<size_t>(wrote) >= sizeof(words) - used) {
            break;
        }
        used += static_cast<size_t>(wrote);
    }

    viewer.ui->ShowSummary(viewer.queue.size(), viewer.unknown.size(), words, viewer.drilling);
}

const char* CurrentWord() {
    if (viewer.queue.empty() || viewer.pos >= viewer.queue.size()) {
        return nullptr;
    }
    return viewer.book->At(viewer.queue[viewer.pos]).word;
}

// 一屏四态：音量页 > 菜单 > 小结 > 词卡。按键只改标志位，画面统一从这里出去。
void ShowCurrent() {
    if (viewer.at_volume) {
        // 分段条要的是"第几档"（1~7），不是百分比
        viewer.ui->ShowVolume(viewer.volume, VolumeLevel(viewer.volume) + 1, CurrentWord());
        return;
    }
    if (viewer.in_menu) {
        viewer.ui->ShowMenu(viewer.menu_item, viewer.book->Count(), viewer.unknown.size(),
                            viewer.volume);
        return;
    }
    if (viewer.at_summary) {
        ShowSummaryPage();
        return;
    }
    viewer.ui->ShowCard(viewer.book->At(viewer.queue[viewer.pos]), viewer.pos, viewer.queue.size(),
                        viewer.revealed ? CardUi::State::kAnswer : CardUi::State::kQuestion,
                        viewer.direction);
}

void StartRound(std::vector<size_t> queue, bool drilling) {
    pron::Stop();
    viewer.queue = std::move(queue);
    viewer.drilling = drilling;
    viewer.pos = 0;
    viewer.unknown.clear();
    viewer.at_summary = false;
    viewer.in_menu = false;
    viewer.at_volume = false;
    viewer.menu_item = 0;
    viewer.revealed = false;
    ShowCurrent();
}

// 闪卡是单向流：揭开答案之后才轮到下一个词，所以没有"上一张"。
void RevealOrNext() {
    if (!viewer.revealed) {
        viewer.revealed = true;
        ShowCurrent();
        return;
    }
    // 离开当前这个词了就别继续播它的发音
    pron::Stop();
    if (viewer.pos + 1 >= viewer.queue.size()) {
        viewer.at_summary = true;
        ShowSummaryPage();
        return;
    }
    ++viewer.pos;
    viewer.revealed = false;
    ShowCurrent();
}

// 菜单行序由 CardUi::kRow* 定义，card_ui.cc 里的 kRowLabels 跟它一一对应。

// 左键长按 = 进出模式菜单，全机唯一入口。光标停在当前模式上，一眼看得出在哪个模式。
// 从音量页长按是"回菜单"而不是"退到卡片"，否则调一半就掉回词卡。
void ToggleMenu(void*, void*) {
    std::lock_guard<std::mutex> lock(viewer.mutex);
    if (viewer.battery_dead || viewer.book->Count() == 0) {
        return;
    }
    if (viewer.at_volume) {
        viewer.at_volume = false;
        viewer.in_menu = true;
        viewer.menu_item = CardUi::kRowVolume;
        ShowCurrent();
        return;
    }
    viewer.in_menu = !viewer.in_menu;
    viewer.menu_item = viewer.direction == CardUi::Direction::kCnToEn ? CardUi::kRowCnToEn
                                                                      : CardUi::kRowEnToCn;
    ShowCurrent();
}

// 音量页的加减。调完立刻试听当前这个词，边听边调才不用猜档位够不够响。
// 这里只改内存 + 投递，任何会阻塞的事（写 flash、写 codec 寄存器）都不在按键任务里做。
void ChangeVolume(int direction) {
    viewer.volume = StepVolume(viewer.volume, direction);
    RequestVolumeSave(viewer.volume);
    audio::SetVolume(viewer.volume);
    ShowCurrent();

    const char* word = CurrentWord();
    if (word != nullptr && pron::HasAudio(word)) {
        pron::Play(word);
    } else {
        pron::Stop();
    }
}

void PressLeft(void*, void*) {
    std::lock_guard<std::mutex> lock(viewer.mutex);
    if (viewer.battery_dead || viewer.book->Count() == 0) {
        return;
    }
    if (viewer.at_volume) {
        ChangeVolume(-1);
        return;
    }
    if (viewer.in_menu) {
        viewer.menu_item = (viewer.menu_item + 1) % CardUi::kRowCount;
        ShowCurrent();
        return;
    }
    if (!viewer.at_summary) {
        RevealOrNext();
        return;
    }
    // 整表轮过完 → 只练那批错词；错词轮过完 → 回整表。一个错词都没有就没什么可练的。
    if (!viewer.drilling && !viewer.unknown.empty()) {
        StartRound(viewer.unknown, true);
    } else {
        StartRound(AllIndices(), false);
    }
}

void PressRight(void*, void*) {
    std::lock_guard<std::mutex> lock(viewer.mutex);
    if (viewer.battery_dead || viewer.book->Count() == 0) {
        return;
    }
    if (viewer.at_volume) {
        ChangeVolume(1);
        return;
    }
    if (viewer.in_menu) {
        if (viewer.menu_item == CardUi::kRowVolume) {
            // 音量页是菜单里"音量"那一行的详情页，长按左键原路退回
            viewer.in_menu = false;
            viewer.at_volume = true;
            ShowCurrent();
            return;
        }
        // 换方向不动本轮进度，但必须回到题目态，否则新方向一上来就是答案
        viewer.direction = viewer.menu_item == CardUi::kRowCnToEn
                               ? CardUi::Direction::kCnToEn
                               : CardUi::Direction::kEnToCn;
        viewer.in_menu = false;
        viewer.revealed = false;
        ShowCurrent();
        return;
    }
    if (viewer.at_summary) {
        // 小结页右键 = 这批错词再来一遍；不在错词轮里就是整表重来。
        if (viewer.drilling && !viewer.unknown.empty()) {
            StartRound(viewer.unknown, true);
        } else {
            StartRound(AllIndices(), false);
        }
        return;
    }
    if (!viewer.revealed) {
        // 队列里的下标天然不重复，一个词一轮里最多被标一次，不用去重。
        viewer.unknown.push_back(viewer.queue[viewer.pos]);
    }
    RevealOrNext();
}

// 右键长按 = 听当前这个词的发音。播放丢给独立任务，回调里只做判断和投递，
// 不然按键状态机要等一整段音频放完。
// 题目态不给听：拼词模式读出来的就是答案本身，提示条上也只在揭开后才提这条。
void HoldRight(void*, void*) {
    std::lock_guard<std::mutex> lock(viewer.mutex);
    if (viewer.battery_dead || viewer.book->Count() == 0 || viewer.in_menu || viewer.at_volume ||
        viewer.at_summary || !viewer.revealed) {
        return;
    }
    const char* word = CurrentWord();
    if (word == nullptr || !pron::HasAudio(word)) {
        viewer.ui->ShowBarHint("这个词没有发音");
        return;
    }
    pron::Play(word);
}

void AddButton(gpio_num_t gpio, button_cb_t single_click, button_cb_t long_press,
               uint16_t long_press_ms) {
    button_config_t button_cfg = {};
    button_cfg.long_press_time = long_press_ms;
    button_gpio_config_t gpio_cfg = {};
    gpio_cfg.gpio_num = static_cast<int32_t>(gpio);
    gpio_cfg.active_level = 0;

    button_handle_t handle = nullptr;
    ESP_ERROR_CHECK(iot_button_new_gpio_device(&button_cfg, &gpio_cfg, &handle));
    if (single_click != nullptr) {
        ESP_ERROR_CHECK(
            iot_button_register_cb(handle, BUTTON_SINGLE_CLICK, nullptr, single_click, nullptr));
    }
    if (long_press != nullptr) {
        ESP_ERROR_CHECK(
            iot_button_register_cb(handle, BUTTON_LONG_PRESS_START, nullptr, long_press, nullptr));
    }
}

// 词表整表替换成功后重新载入，从第一张卡重开一轮。
void ReloadWordbook() {
    std::lock_guard<std::mutex> lock(viewer.mutex);
    std::string err;
    std::string path = storage::Path("words.tsv");
    if (viewer.book->Load(path.c_str(), &err)) {
        viewer.store->SetStoredWords(static_cast<int>(viewer.book->Count()));
        StartRound(AllIndices(), false);
        ESP_LOGI(TAG, "词表已重载 %u 条", static_cast<unsigned>(viewer.book->Count()));
    } else {
        viewer.ui->ShowNotice("词表读不到", err.c_str());
    }
}

void ShowNotice(const std::string& title, const std::string& detail) {
    viewer.ui->ShowNotice(title.c_str(), detail.c_str());
}

// 低压门限按 mV 判，不按百分比：百分比是通用放电曲线插出来的，每颗电芯不一样，
// 而"过放"是电芯化学定的硬线，跨过去容量就永久掉。两道都带回差，
// 因为插着充电时端电压被充电器抬着走，恢复线必须明显高于触发线，不然会在门槛上反复进出。
constexpr int kWarnEnterMv = 3400;
constexpr int kWarnExitMv = 3460;
constexpr int kStopEnterMv = 3200;
constexpr int kStopExitMv = 3300;

// 放电日志一分钟落一条（10 秒一轮，攒满六轮写一次），低压档位一跳就立刻多写一条。
// 攒的是"这颗电芯 + 这个负载"的实测曲线，回头替掉 battery.cc 里那张通用表。
constexpr int kLogEveryTicks = 6;

// 电量本身变得很慢，而这块 RLCD 每刷一次都会闪一下，所以差值不足 3% 就不动屏幕。
void BatteryTask(void*) {
    int shown = -1;
    bool warning = false;
    int log_ticks = 0;
    while (true) {
        int percent = 0;
        int millivolts = 0;
        if (battery::Read(&percent, &millivolts)) {
            ESP_LOGI(TAG, "电池 %d mV → %d%%", millivolts, percent);
            std::lock_guard<std::mutex> lock(viewer.mutex);

            const bool was_dead = viewer.battery_dead;
            const bool was_warning = warning;
            viewer.battery_dead = millivolts < (was_dead ? kStopExitMv : kStopEnterMv);

            if (viewer.battery_dead) {
                if (!was_dead) {
                    pron::Stop();  // 功放是最大的一块负载，别再拉它
                    ShowNotice("电量过低", "请充电，充一会儿按键自动恢复");
                }
            } else {
                if (was_dead) {
                    // notice 屏上电池图标已经不在了，回到卡片必须重画一次
                    shown = -1;
                    ShowCurrent();
                }
                warning = millivolts < (warning ? kWarnExitMv : kWarnEnterMv);
                viewer.ui->SetLowBatteryWarning(warning);
                int delta = percent - shown;
                if (shown < 0 || (delta < 0 ? -delta : delta) >= 3) {
                    shown = percent;
                    viewer.ui->SetBattery(percent);
                }
            }

            // 一分钟一条，或者一跨低压门限立刻一条。日志失败不影响按键和发音。
            const bool jumped = viewer.battery_dead != was_dead || warning != was_warning;
            if (jumped || ++log_ticks >= kLogEveryTicks) {
                log_ticks = 0;
                const uint8_t flags = static_cast<uint8_t>(
                    (warning ? batterylog::kFlagWarn : 0) |
                    (viewer.battery_dead ? batterylog::kFlagDead : 0));
                batterylog::Append(millivolts, percent, flags);
            }
        }
        vTaskDelay(pdMS_TO_TICKS(10000));
    }
}

// 探针只认一个动作：任何按键（短按/长按）都翻下一帧。
void PressProbe(void*, void*) { StyleProbe::Next(); }

}  // namespace

extern "C" void app_main() {
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    ESP_LOGI(TAG, "单词机启动，目标 %dx%d 单色 RLCD", RLCD_WIDTH, RLCD_HEIGHT);

    CardUi ui;
    Wordbook book;
    Wordstore store;
    std::string message;

    RlcdDisplay::GetInstance()->ShowTestCard("WORD CARD", "loading...");

    // 探针不碰词表、BLE、发音、电池，只要屏和按键。挂在这之前起的 CardUi 会被 lv_obj_clean 清掉。
    if (kStyleProbe) {
        AddButton(USER_BUTTON_GPIO, PressProbe, PressProbe, 800);
        AddButton(BOOT_BUTTON_GPIO, PressProbe, PressProbe, 600);
        StyleProbe::Show();
        while (true) {
            vTaskDelay(pdMS_TO_TICKS(1000));
        }
    }

    if (!storage::Mount()) {
        ui.ShowNotice("词库分区挂载失败",
                      "storage 分区还没有 FAT 镜像。\n在电脑上跑 flash-wordbook.ps1 烧一次词表。");
        return;
    }
    store.Recover();

    viewer.ui = &ui;
    viewer.book = &book;
    viewer.store = &store;

    // 音量落盘另有任务：按键回调的栈太小（见 RequestVolumeSave 的注释）。
    if (xTaskCreate(VolumeSaveTask, "volsave", 6144, nullptr, 3, &g_volume_save_task) != pdPASS) {
        ESP_LOGW(TAG, "音量存不了盘：保存任务没起来，重启后回到默认档");
    }

    // 开声音之前就把存好的档位取出来，首屏显示的音量和实际响度对得上。
    viewer.volume = LoadVolume();
    audio::SetVolume(viewer.volume);

    std::string path = storage::Path("words.tsv");
    if (book.Load(path.c_str(), &message)) {
        store.SetStoredWords(static_cast<int>(book.Count()));
        StartRound(AllIndices(), false);
        ESP_LOGI(TAG, "词表载入 %u 条", static_cast<unsigned>(book.Count()));
    } else {
        ui.ShowNotice("还没有词表", "手机 app 连上 WORDCARD\n推送一次就能用。");
    }

    AddButton(USER_BUTTON_GPIO, PressLeft, ToggleMenu, 800);
    AddButton(BOOT_BUTTON_GPIO, PressRight, HoldRight, 600);

    if (!pron::Init()) {
        ESP_LOGW(TAG, "发音通路不可用，其余功能照常");
    }

    ble::Callbacks callbacks;
    callbacks.wordbook_replaced = ReloadWordbook;
    callbacks.notice = ShowNotice;
    if (!ble::Init(&store, std::move(callbacks))) {
        ui.ShowNotice("BLE 起不来", "看串口日志");
    }

    if (battery::Init()) {
        // 过放那一档要在里面整屏重画 notice，LVGL 的建树/清树比只改电池图标吃栈得多；
        // 后面还要往 FAT 追加放电日志，按写文件的另外两个任务的量给。
        xTaskCreate(BatteryTask, "battery", 8192, nullptr, 3, nullptr);
    }

    while (true) {
        vTaskDelay(pdMS_TO_TICKS(5000));
    }
}
