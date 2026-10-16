#include "storage.h"

#include "esp_log.h"
#include "esp_vfs_fat.h"
#include "wear_levelling.h"

static const char* TAG = "Storage";

namespace storage {

static wl_handle_t s_wl_handle = WL_INVALID_HANDLE;
static bool s_mounted = false;

// storage 分区是 0x800000 (8MB)，见 partitions/wordcard-16m.csv
bool Mount() {
    if (s_mounted) {
        return true;
    }

    esp_vfs_fat_mount_config_t config = {};
    config.max_files = 4;
    config.format_if_mount_failed = false;
    config.allocation_unit_size = 4096;

    esp_err_t err = esp_vfs_fat_spiflash_mount_rw_wl(kMountPoint, "storage", &config, &s_wl_handle);
    if (err != ESP_OK) {
        if (err == ESP_ERR_NOT_FOUND) {
            ESP_LOGE(TAG, "分区表里没有名为 storage 的分区");
        } else {
            ESP_LOGE(TAG, "挂载 /wordbook 失败: %s（这个分区还没有 FAT 镜像，先跑 flash-wordbook.ps1）",
                     esp_err_to_name(err));
        }
        return false;
    }

    s_mounted = true;
    uint64_t total_bytes = 0, free_bytes = 0;
    if (esp_vfs_fat_info(kMountPoint, &total_bytes, &free_bytes) == ESP_OK) {
        ESP_LOGI(TAG, "/wordbook 已挂载: 共 %llu MB, 剩余 %llu KB",
                 static_cast<unsigned long long>(total_bytes / 1024 / 1024),
                 static_cast<unsigned long long>(free_bytes / 1024));
    }
    return true;
}

bool IsMounted() {
    return s_mounted;
}

std::string Path(const char* name) {
    return std::string(kMountPoint) + "/" + name;
}

}  // namespace storage
