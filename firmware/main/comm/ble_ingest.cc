#include "comm/ble_ingest.h"

#include <cstdio>
#include <cstring>

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "cJSON.h"
#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gatts_api.h"
#include "esp_log.h"
#include "esp_timer.h"

#include "app/wordstore.h"

static const char* TAG = "BleIngest";

namespace {

constexpr int kMaxFrame = 512;
constexpr int kQueueDepth = 8;
constexpr int64_t kNoticeIntervalUs = 400 * 1000;

constexpr char kDeviceName[] = "WORDCARD";

enum FrameKind : uint8_t {
    kKindJson = 1,        // 0xFFE1 里的 JSON 命令
    kKindData = 2,        // 0xFFE3 里的音频帧
    kKindClosed = 3,      // GATT 断开，让 ingest 任务收尾半截传输
};

struct Frame {
    uint8_t kind;
    uint16_t len;
    uint8_t data[kMaxFrame];
};

static const uint16_t kServiceUuid16 = 0xFFE0;
static const uint16_t kCmdUuid16 = 0xFFE1;
static const uint16_t kNtfUuid16 = 0xFFE2;
static const uint16_t kDataUuid16 = 0xFFE3;

// 广播里的 service UUID 长度必须是 16 的倍数（ESP-IDF 校验 service_uuid_len & 0xf），
// 所以放 0xFFE0 的 128-bit base UUID 展开形式，手机端会认成 16-bit UUID。
static uint8_t kAdvServiceUuid128[16] = {
    0xfb, 0x34, 0x9b, 0x5f, 0x80, 0x00, 0x00, 0x80,
    0x00, 0x10, 0x00, 0x00, 0xe0, 0xff, 0x00, 0x00,
};

static const uint16_t kCharDeclUuid16 = ESP_GATT_UUID_CHAR_DECLARE;
static const uint16_t kCccdUuid16 = ESP_GATT_UUID_CHAR_CLIENT_CONFIG;
static const uint8_t kPropWrite = ESP_GATT_CHAR_PROP_BIT_WRITE;
static const uint8_t kPropReadNotify = ESP_GATT_CHAR_PROP_BIT_READ |
                                        ESP_GATT_CHAR_PROP_BIT_NOTIFY;
static uint16_t kCccdInitValue = 0x0000;

enum {
    IDX_SERVICE,
    IDX_CMD_DECL,
    IDX_CMD_VAL,
    IDX_NTF_DECL,
    IDX_NTF_VAL,
    IDX_NTF_CCCD,
    IDX_DATA_DECL,
    IDX_DATA_VAL,
    IDX_COUNT,
};

// 特征值用 RSP_BY_APP：BLE 协议栈线程只负责收字节和回 ATT 响应，
// 落 FAT、刷屏都在 ingest 任务里，不占 btu_task 的栈。
static esp_gatts_attr_db_t* BuildAttrDb() {
    static esp_gatts_attr_db_t db[IDX_COUNT];
    static const uint16_t kPrimarySvcUuid = 0x2800;

    db[IDX_SERVICE] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t*)&kPrimarySvcUuid, ESP_GATT_PERM_READ,
         sizeof(uint16_t), sizeof(uint16_t), (uint8_t*)&kServiceUuid16}
    };
    db[IDX_CMD_DECL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t*)&kCharDeclUuid16, ESP_GATT_PERM_READ,
         sizeof(uint8_t), sizeof(uint8_t), (uint8_t*)&kPropWrite}
    };
    db[IDX_CMD_VAL] = {
        {ESP_GATT_RSP_BY_APP},
        {ESP_UUID_LEN_16, (uint8_t*)&kCmdUuid16, ESP_GATT_PERM_WRITE,
         kMaxFrame, 0, nullptr}
    };
    db[IDX_NTF_DECL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t*)&kCharDeclUuid16, ESP_GATT_PERM_READ,
         sizeof(uint8_t), sizeof(uint8_t), (uint8_t*)&kPropReadNotify}
    };
    db[IDX_NTF_VAL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t*)&kNtfUuid16, ESP_GATT_PERM_READ,
         kMaxFrame, 0, nullptr}
    };
    db[IDX_NTF_CCCD] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t*)&kCccdUuid16,
         ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE,
         sizeof(uint16_t), sizeof(uint16_t), (uint8_t*)&kCccdInitValue}
    };
    db[IDX_DATA_DECL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t*)&kCharDeclUuid16, ESP_GATT_PERM_READ,
         sizeof(uint8_t), sizeof(uint8_t), (uint8_t*)&kPropWrite}
    };
    db[IDX_DATA_VAL] = {
        {ESP_GATT_RSP_BY_APP},
        {ESP_UUID_LEN_16, (uint8_t*)&kDataUuid16, ESP_GATT_PERM_WRITE,
         kMaxFrame, 0, nullptr}
    };

    return db;
}

Wordstore* g_store = nullptr;
ble::Callbacks g_cb;
QueueHandle_t g_queue = nullptr;

uint16_t g_gatts_if = 0xff;
uint16_t g_conn_id = 0xffff;
bool g_connected = false;
bool g_subscribed = false;
uint16_t g_cmd_value_handle = 0;
uint16_t g_ntf_value_handle = 0;
uint16_t g_cccd_handle = 0;
uint16_t g_data_value_handle = 0;

int g_declared_words = 0;
std::string g_last_word;
int64_t g_last_notice_us = 0;

esp_ble_adv_params_t g_adv_params;

// ---------------------------------------------------------------- 上行回报

void NotifyJson(cJSON* root) {
    if (!g_subscribed || g_conn_id == 0xffff || root == nullptr) {
        if (root != nullptr) {
            cJSON_Delete(root);
        }
        return;
    }
    char* text = cJSON_PrintUnformatted(root);
    if (text != nullptr) {
        esp_ble_gatts_send_indicate(g_gatts_if, g_conn_id, g_ntf_value_handle,
                                    strlen(text), reinterpret_cast<uint8_t*>(text), false);
        cJSON_free(text);
    }
    cJSON_Delete(root);
}

void NotifyType(const char* type) {
    cJSON* root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "t", type);
    NotifyJson(root);
}

void NotifyError(const std::string& msg) {
    ESP_LOGW(TAG, "回报错误: %s", msg.c_str());
    cJSON* root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "t", "error");
    cJSON_AddStringToObject(root, "m", msg.c_str());
    NotifyJson(root);
}

void Notice(const std::string& title, const std::string& detail, bool force = false) {
    int64_t now = esp_timer_get_time();
    if (!force && now - g_last_notice_us < kNoticeIntervalUs) {
        return;
    }
    g_last_notice_us = now;
    if (g_cb.notice) {
        g_cb.notice(title, detail);
    }
}

std::string WordProgress() {
    int received = g_store->words_received();
    std::string text = std::to_string(received);
    if (g_declared_words > 0) {
        text += "/" + std::to_string(g_declared_words);
    }
    if (!g_last_word.empty()) {
        text += "  " + g_last_word;
    }
    return text;
}

// 停在进度页上分不清"传完了"还是"最后一步挂了"，所以把这轮收到多少、失败几个
// 直接写进屏上那行字。发音总数协议里没有声明，因此不写成 5/5 那种带分母的形式。
std::string AudioProgress() {
    return std::to_string(g_store->words_received()) + " 词 · 发音 " +
           std::to_string(g_store->audio_ok()) + " · 失败 " +
           std::to_string(g_store->audio_failed());
}

// ---------------------------------------------------------------- JSON 命令

const char* GetString(cJSON* root, const char* key, char* buf, size_t cap) {
    cJSON* node = cJSON_GetObjectItemCaseSensitive(root, key);
    if (node == nullptr || !cJSON_IsString(node) || node->valuestring == nullptr) {
        buf[0] = '\0';
    } else {
        snprintf(buf, cap, "%s", node->valuestring);
    }
    return buf;
}

long GetNumber(cJSON* root, const char* key, long fallback) {
    cJSON* node = cJSON_GetObjectItemCaseSensitive(root, key);
    if (node == nullptr || !cJSON_IsNumber(node)) {
        return fallback;
    }
    return static_cast<long>(node->valuedouble);
}

// 不能走 GetNumber：crc32 有一半概率大于 LONG_MAX，double 直接转 long 是未定义行为，
// xtensa 的 libgcc 会饱和掉，于是整份音频传完、字节数对得上，最后死在 crc 比对上。
// 经 int64 中转对整个 uint32 区间都是精确的。
uint32_t GetU32(cJSON* root, const char* key, uint32_t fallback) {
    cJSON* node = cJSON_GetObjectItemCaseSensitive(root, key);
    if (node == nullptr || !cJSON_IsNumber(node)) {
        return fallback;
    }
    return static_cast<uint32_t>(static_cast<int64_t>(node->valuedouble));
}

void HandleStat() {
    uint64_t free_bytes = 0, total_bytes = 0;
    g_store->FreeBytes(&free_bytes, &total_bytes);

    cJSON* root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "t", "stat");
    cJSON_AddNumberToObject(root, "stored_words", g_store->stored_words());
    cJSON_AddNumberToObject(root, "received", g_store->words_received());
    cJSON_AddNumberToObject(root, "audio_ok", g_store->audio_ok());
    cJSON_AddNumberToObject(root, "audio_failed", g_store->audio_failed());
    cJSON_AddNumberToObject(root, "free_kb", static_cast<double>(free_bytes / 1024));
    NotifyJson(root);
}

void HandleJson(const uint8_t* payload, size_t len) {
    std::string text(reinterpret_cast<const char*>(payload), len);
    cJSON* root = cJSON_Parse(text.c_str());
    if (root == nullptr) {
        NotifyError("json 解析失败");
        return;
    }

    char type[16];
    GetString(root, "t", type, sizeof(type));
    std::string err;

    if (strcmp(type, "wb_begin") == 0) {
        g_declared_words = static_cast<int>(GetNumber(root, "n", 0));
        g_last_word.clear();
        if (g_store->BeginWordbook(&err)) {
            Notice("接收词表", WordProgress(), true);
            NotifyType("wb_begin_ok");
        } else {
            NotifyError(err);
        }
    } else if (strcmp(type, "wb_word") == 0) {
        char word[64], phonetic[96], meaning[192], example[320];
        GetString(root, "w", word, sizeof(word));
        GetString(root, "p", phonetic, sizeof(phonetic));
        GetString(root, "m", meaning, sizeof(meaning));
        GetString(root, "s", example, sizeof(example));
        if (g_store->AddWord(word, phonetic, meaning, example, &err)) {
            g_last_word = word;
            Notice("接收词表", WordProgress());
        } else {
            NotifyError(err);
        }
    } else if (strcmp(type, "wb_end") == 0) {
        if (g_store->EndWordbook(&err)) {
            cJSON* reply = cJSON_CreateObject();
            cJSON_AddStringToObject(reply, "t", "wb_done");
            cJSON_AddNumberToObject(reply, "n", g_store->words_received());
            NotifyJson(reply);
            Notice("接收词表", WordProgress(), true);
            if (g_cb.wordbook_replaced) {
                g_cb.wordbook_replaced();
            }
        } else {
            NotifyError(err);
            Notice("词表没换成", err, true);
        }
    } else if (strcmp(type, "au_begin") == 0) {
        char word[64], fmt[8];
        GetString(root, "w", word, sizeof(word));
        GetString(root, "fmt", fmt, sizeof(fmt));
        uint32_t len = GetU32(root, "len", 0);
        uint32_t crc = GetU32(root, "crc32", 0);
        g_last_word = word;  // 失败那一步在 au_end，屏幕上要叫得出是哪个词
        if (g_store->BeginAudio(word, fmt, len, crc, &err)) {
            Notice("接收发音", AudioProgress() + "  " + word, true);
        } else {
            NotifyError(err);
            Notice("发音没存下", g_last_word + "  " + err, true);
        }
    } else if (strcmp(type, "au_end") == 0) {
        if (g_store->EndAudio(&err)) {
            Notice("接收发音", AudioProgress(), true);
            NotifyType("au_done");
        } else {
            NotifyError(err);
            // 以前只回 app：屏幕上还留着上一次的进度页，失败在设备侧完全看不出来。
            Notice("发音没存下", g_last_word + "  " + err, true);
        }
    } else if (strcmp(type, "stat") == 0) {
        HandleStat();
    } else {
        NotifyError(std::string("未知命令: ") + type);
    }

    cJSON_Delete(root);
}

// ---------------------------------------------------------------- 音频帧

constexpr size_t kFrameHeaderLen = 10;

void HandleData(const uint8_t* payload, size_t len) {
    if (len < kFrameHeaderLen) {
        NotifyError("音频帧太短");
        return;
    }
    if (payload[0] != 0xA5 || payload[1] != 0x5A || payload[2] != 1) {
        NotifyError("音频帧头不对");
        return;
    }
    uint32_t offset = static_cast<uint32_t>(payload[4]) | (static_cast<uint32_t>(payload[5]) << 8) |
                      (static_cast<uint32_t>(payload[6]) << 16) |
                      (static_cast<uint32_t>(payload[7]) << 24);
    uint16_t payload_len = static_cast<uint16_t>(payload[8] | (payload[9] << 8));
    if (len != kFrameHeaderLen + payload_len) {
        NotifyError("音频帧长度和头部不一致");
        return;
    }

    std::string err;
    // 同一个连接里 ATT 写是串行的，队列又只有一个消费者，所以 offset
    // 对不上只可能是 app 丢帧或漏帧；继续写会得到一个坏文件，直接废弃。
    if (offset != g_store->audio_written()) {
        err = "offset 对不上（期望 " + std::to_string(g_store->audio_written()) + "，收到 "
              + std::to_string(offset) + "）";
        g_store->AbortAudio();
        NotifyError(err);
        return;
    }
    g_store->AddAudioData(payload + kFrameHeaderLen, payload_len, &err);
    if (!err.empty()) {
        NotifyError(err);
        Notice("发音没存下", err, true);
    }
}

// ---------------------------------------------------------------- ingest 任务

void IngestTask(void*) {
    Frame frame;
    while (true) {
        if (xQueueReceive(g_queue, &frame, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        switch (frame.kind) {
        case kKindJson:
            HandleJson(frame.data, frame.len);
            break;
        case kKindData:
            HandleData(frame.data, frame.len);
            break;
        case kKindClosed:
            g_store->AbortWordbook();
            g_store->AbortAudio();
            g_declared_words = 0;
            g_last_word.clear();
            Notice("已断开", "手机重新连接后再推", true);
            break;
        default:
            break;
        }
    }
}

bool Enqueue(FrameKind kind, const uint8_t* data, size_t len) {
    if (len > kMaxFrame) {
        return false;
    }
    // 拷贝到队列而不是引用协议栈缓冲区：回调返回后那块内存就还给了 btu_task。
    Frame frame;
    frame.kind = static_cast<uint8_t>(kind);
    frame.len = static_cast<uint16_t>(len);
    if (len > 0) {
        memcpy(frame.data, data, len);
    }
    return xQueueSend(g_queue, &frame, pdMS_TO_TICKS(100)) == pdTRUE;
}

// ---------------------------------------------------------------- GAP / GATTS

void StartAdvertising() {
    esp_ble_adv_data_t adv_data = {};
    adv_data.set_scan_rsp = false;
    adv_data.include_name = true;
    adv_data.include_txpower = false;
    adv_data.service_uuid_len = sizeof(kAdvServiceUuid128);
    adv_data.p_service_uuid = kAdvServiceUuid128;
    adv_data.flag = (ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT);

    // adv_params 必须是静态的：config_adv_data 是异步的，真正启动广播发生在
    // GAP 回调里的 ADV_DATA_SET_COMPLETE 事件。
    g_adv_params = {};
    g_adv_params.adv_int_min = 0x100;   // 160 * 0.625ms = 100ms
    g_adv_params.adv_int_max = 0x100;
    g_adv_params.adv_type = ADV_TYPE_IND;
    g_adv_params.own_addr_type = BLE_ADDR_TYPE_PUBLIC;
    g_adv_params.channel_map = ADV_CHNL_ALL;
    g_adv_params.adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY;

    esp_err_t err = esp_ble_gap_config_adv_data(&adv_data);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "config_adv_data: %s", esp_err_to_name(err));
    }
}

void GapCallback(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t* param) {
    switch (event) {
    case ESP_GAP_BLE_ADV_DATA_SET_COMPLETE_EVT: {
        if (param->adv_data_cmpl.status != ESP_BT_STATUS_SUCCESS) {
            ESP_LOGE(TAG, "广播数据设置失败 status=%d", param->adv_data_cmpl.status);
            return;
        }
        esp_err_t err = esp_ble_gap_start_advertising(&g_adv_params);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "start_advertising: %s", esp_err_to_name(err));
        }
        break;
    }
    case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
        if (param->adv_start_cmpl.status != ESP_BT_STATUS_SUCCESS) {
            ESP_LOGE(TAG, "广播启动失败 status=%d", param->adv_start_cmpl.status);
        } else {
            ESP_LOGI(TAG, "广播中，设备名 %s", kDeviceName);
        }
        break;
    default:
        break;
    }
}

void GattsCallback(esp_gatts_cb_event_t event, esp_gatt_if_t gatts_if,
                   esp_ble_gatts_cb_param_t* param) {
    switch (event) {
    case ESP_GATTS_REG_EVT: {
        if (param->reg.status != ESP_GATT_OK) {
            ESP_LOGE(TAG, "app 注册失败 status=%d", param->reg.status);
            return;
        }
        g_gatts_if = gatts_if;
        esp_err_t err = esp_ble_gatts_create_attr_tab(BuildAttrDb(), gatts_if, IDX_COUNT, 0);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "create_attr_tab: %s", esp_err_to_name(err));
        }
        break;
    }

    case ESP_GATTS_CREAT_ATTR_TAB_EVT: {
        if (param->add_attr_tab.status != ESP_GATT_OK ||
            param->add_attr_tab.num_handle != IDX_COUNT) {
            ESP_LOGE(TAG, "属性表创建失败 status=%d handles=%d",
                     param->add_attr_tab.status, param->add_attr_tab.num_handle);
            return;
        }
        uint16_t service_handle = param->add_attr_tab.handles[IDX_SERVICE];
        g_cmd_value_handle = param->add_attr_tab.handles[IDX_CMD_VAL];
        g_ntf_value_handle = param->add_attr_tab.handles[IDX_NTF_VAL];
        g_cccd_handle = param->add_attr_tab.handles[IDX_NTF_CCCD];
        g_data_value_handle = param->add_attr_tab.handles[IDX_DATA_VAL];

        esp_ble_gatts_start_service(service_handle);
        esp_ble_gap_set_device_name(kDeviceName);
        StartAdvertising();
        ESP_LOGI(TAG, "服务已起 cmd=%d ntf=%d data=%d cccd=%d", g_cmd_value_handle,
                 g_ntf_value_handle, g_data_value_handle, g_cccd_handle);
        break;
    }

    case ESP_GATTS_CONNECT_EVT:
        g_conn_id = param->connect.conn_id;
        g_connected = true;
        g_subscribed = false;
        ESP_LOGI(TAG, "已连接 conn_id=%d", g_conn_id);
        break;

    case ESP_GATTS_DISCONNECT_EVT:
        ESP_LOGI(TAG, "已断开 conn_id=%d reason=0x%02x", param->disconnect.conn_id,
                 param->disconnect.reason);
        g_connected = false;
        g_subscribed = false;
        g_conn_id = 0xffff;
        Enqueue(kKindClosed, nullptr, 0);
        // Bluedroid 断开后不会自己恢复广播，不重启手机下次扫不到。
        esp_ble_gap_start_advertising(&g_adv_params);
        break;

    case ESP_GATTS_WRITE_EVT: {
        if (param->write.is_prep) {
            // 分片写（MTU 只有 23 时才会走到这里）不支持，让 app 先把 MTU 谈到 512。
            ESP_LOGW(TAG, "收到 prepared write，需要 MTU>=512");
            if (param->write.need_rsp) {
                esp_ble_gatts_send_response(gatts_if, param->write.conn_id,
                                            param->write.trans_id, ESP_GATT_ERROR, nullptr);
            }
            break;
        }

        if (param->write.handle == g_cccd_handle) {
            uint16_t cccd = (param->write.value != nullptr && param->write.len >= 2)
                                ? static_cast<uint16_t>(param->write.value[0] |
                                                        (param->write.value[1] << 8))
                                : 0;
            g_subscribed = (cccd & 0x0001) != 0;
            ESP_LOGI(TAG, "订阅状态 %d", g_subscribed);
        } else if (param->write.handle == g_cmd_value_handle) {
            bool ok = Enqueue(kKindJson, param->write.value, param->write.len);
            if (param->write.need_rsp) {
                esp_ble_gatts_send_response(gatts_if, param->write.conn_id,
                                            param->write.trans_id,
                                            ok ? ESP_GATT_OK : ESP_GATT_ERROR, nullptr);
            }
        } else if (param->write.handle == g_data_value_handle) {
            bool ok = Enqueue(kKindData, param->write.value, param->write.len);
            if (param->write.need_rsp) {
                esp_ble_gatts_send_response(gatts_if, param->write.conn_id,
                                            param->write.trans_id,
                                            ok ? ESP_GATT_OK : ESP_GATT_ERROR, nullptr);
            }
        } else if (param->write.need_rsp) {
            esp_ble_gatts_send_response(gatts_if, param->write.conn_id,
                                        param->write.trans_id, ESP_GATT_OK, nullptr);
        }
        break;
    }

    case ESP_GATTS_MTU_EVT:
        ESP_LOGI(TAG, "MTU=%d（单条命令上限 %d 字节）", param->mtu.mtu, param->mtu.mtu - 3);
        break;

    default:
        break;
    }
}

}  // namespace

namespace ble {

bool Init(Wordstore* store, Callbacks callbacks) {
    g_store = store;
    g_cb = std::move(callbacks);

    g_queue = xQueueCreate(kQueueDepth, sizeof(Frame));
    if (g_queue == nullptr) {
        ESP_LOGE(TAG, "建队列失败");
        return false;
    }
    if (xTaskCreate(IngestTask, "ingest", 8192, nullptr, 5, nullptr) != pdPASS) {
        ESP_LOGE(TAG, "建 ingest 任务失败");
        return false;
    }

    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    esp_err_t err = esp_bt_controller_init(&bt_cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "bt_controller_init: %s", esp_err_to_name(err));
        return false;
    }
    err = esp_bt_controller_enable(ESP_BT_MODE_BLE);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "bt_controller_enable: %s", esp_err_to_name(err));
        return false;
    }
    err = esp_bluedroid_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "bluedroid_init: %s", esp_err_to_name(err));
        return false;
    }
    err = esp_bluedroid_enable();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "bluedroid_enable: %s", esp_err_to_name(err));
        return false;
    }
    err = esp_ble_gap_register_callback(GapCallback);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "gap_register_callback: %s", esp_err_to_name(err));
        return false;
    }
    err = esp_ble_gatts_register_callback(GattsCallback);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "gatts_register_callback: %s", esp_err_to_name(err));
        return false;
    }
    err = esp_ble_gatts_app_register(0);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "gatts_app_register: %s", esp_err_to_name(err));
        return false;
    }

    ESP_LOGI(TAG, "BLE 已就绪，等手机推词表");
    return true;
}

bool Connected() {
    return g_connected;
}

}  // namespace ble
