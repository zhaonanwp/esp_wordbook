#include "batterylog.h"

#include <cstdio>
#include <cstring>

#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"

#include "storage.h"

namespace {

constexpr char TAG[] = "BatteryLog";
constexpr char kFileName[] = "batlog.bin";
constexpr size_t kRecordSize = 32;

// 定长、自描述的小记录，故意不依赖文件系统能被 PC 侧读出来：
// storage 分区挂的是 wear-levelling 的 FAT（CONFIG_WL_SECTOR_SIZE=512），
// esptool 整块 read_flash 拿到的是重排过的扇区，不是普通 FAT16 镜像。
// 所以每条记录带 magic + seq + checksum，PC 脚本直接在 8MB 字节流里扫出来即可；
// 32 整除 512，记录不会跨 wl 扇区被拆开。改这个结构必须同步改 parse-battery-log.py。
#pragma pack(push, 1)
struct Record {
    uint8_t magic[4];    // "WCB1"
    uint32_t seq;        // 文件里的第几条，由文件长度推出来
    uint32_t boot;       // 每次开机一个随机数，用来分段
    uint32_t uptime_sec; // 本次开机以来的秒数
    uint16_t millivolts;
    uint8_t percent;
    uint8_t flags;       // batterylog::kFlag*
    uint32_t reserved[2];
    uint32_t checksum;   // 前 28 字节按 7 个小端 u32 相加
};
#pragma pack()

static_assert(sizeof(Record) == kRecordSize, "记录格式必须和 parse-battery-log.py 对上");

uint32_t BootNonce() {
    static const uint32_t nonce = esp_random();
    return nonce;
}

uint32_t Checksum(const Record& rec) {
    const uint32_t* words = reinterpret_cast<const uint32_t*>(&rec);
    uint32_t sum = 0;
    for (int i = 0; i < 7; i++) {
        sum += words[i];
    }
    return sum;
}

}  // namespace

namespace batterylog {

void Append(int millivolts, int percent, uint8_t flags) {
    if (!storage::IsMounted()) {
        return;
    }

    std::string path = storage::Path(kFileName);
    FILE* file = fopen(path.c_str(), "ab");
    if (file == nullptr) {
        static bool warned = false;
        if (!warned) {
            warned = true;
            ESP_LOGW(TAG, "打不开 %s，放电日志不再尝试（不影响背单词）", path.c_str());
        }
        return;
    }

    fseek(file, 0, SEEK_END);
    Record rec = {};
    memcpy(rec.magic, "WCB1", sizeof(rec.magic));
    rec.seq = static_cast<uint32_t>(ftell(file) / kRecordSize);
    rec.boot = BootNonce();
    rec.uptime_sec = static_cast<uint32_t>(esp_timer_get_time() / 1000000LL);
    rec.millivolts = static_cast<uint16_t>(millivolts);
    rec.percent = static_cast<uint8_t>(percent < 0 ? 0 : (percent > 100 ? 100 : percent));
    rec.flags = flags;
    rec.checksum = Checksum(rec);

    if (fwrite(&rec, sizeof(rec), 1, file) != 1) {
        ESP_LOGW(TAG, "第 %u 条日志没写进去", static_cast<unsigned>(rec.seq));
    }
    fclose(file);
}

}  // namespace batterylog
