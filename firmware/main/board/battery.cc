#include "battery.h"

#include <driver/gpio.h>
#include <esp_adc/adc_cali.h>
#include <esp_adc/adc_cali_scheme.h>
#include <esp_adc/adc_oneshot.h>
#include <esp_log.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

namespace {

constexpr char TAG[] = "Battery";

// 板上 VBAT 经 3:1 分压接到 GPIO4，也就是 ADC1_CH3。
// 出处：厂商例程 01_Arduino/examples/03_ADC_Test/adc_bsp.cpp。
// 这块板没有把充电状态接进 GPIO，所以只测电压，"是否在充电"测不出来。
constexpr adc_unit_t kUnit = ADC_UNIT_1;
constexpr adc_channel_t kChannel = ADC_CHANNEL_3;
constexpr int kDivider = 3;
constexpr int kSamples = 10;
constexpr float kEmaAlpha = 0.3f;

// 18650 放电曲线（mV → %），~100mA 负载典型值
constexpr struct {
    int mv;
    int pct;
} kCurve[] = {
    {4200, 100}, {4100, 95}, {4050, 90}, {3980, 80}, {3920, 70}, {3850, 60},
    {3790, 50},  {3740, 40}, {3690, 30}, {3650, 20}, {3600, 10}, {3550, 5},
    {3400, 2},   {3300, 0},
};

adc_oneshot_unit_handle_t g_adc = nullptr;
adc_cali_handle_t g_cali = nullptr;
float g_ema_mv = 0.0f;
bool g_ema_ready = false;

bool Sample(int* millivolts) {
    int raw = 0;
    if (adc_oneshot_read(g_adc, kChannel, &raw) != ESP_OK) {
        return false;
    }
    int calibrated = 0;
    if (g_cali == nullptr || adc_cali_raw_to_voltage(g_cali, raw, &calibrated) != ESP_OK) {
        // 没有校准表就按 12dB 衰减的量程线性折（约 0-3100mV）
        calibrated = raw * 3100 / 4096;
    }
    *millivolts = calibrated * kDivider;
    return true;
}

int Percent(int millivolts) {
    constexpr int kCount = sizeof(kCurve) / sizeof(kCurve[0]);
    if (millivolts >= kCurve[0].mv) {
        return kCurve[0].pct;
    }
    if (millivolts <= kCurve[kCount - 1].mv) {
        return kCurve[kCount - 1].pct;
    }
    for (int i = 0; i < kCount - 1; i++) {
        if (millivolts <= kCurve[i].mv && millivolts >= kCurve[i + 1].mv) {
            int span_mv = kCurve[i].mv - kCurve[i + 1].mv;
            int span_pct = kCurve[i].pct - kCurve[i + 1].pct;
            return kCurve[i + 1].pct + (millivolts - kCurve[i + 1].mv) * span_pct / span_mv;
        }
    }
    return 0;
}

}  // namespace

namespace battery {

bool Init() {
    adc_oneshot_unit_init_cfg_t unit_cfg = {
        .unit_id = kUnit,
    };
    if (adc_oneshot_new_unit(&unit_cfg, &g_adc) != ESP_OK) {
        ESP_LOGE(TAG, "ADC1 打开失败");
        g_adc = nullptr;
        return false;
    }

    adc_oneshot_chan_cfg_t chan_cfg = {
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_12,
    };
    if (adc_oneshot_config_channel(g_adc, kChannel, &chan_cfg) != ESP_OK) {
        ESP_LOGE(TAG, "ADC1_CH3 配置失败");
        adc_oneshot_del_unit(g_adc);
        g_adc = nullptr;
        return false;
    }

    adc_cali_curve_fitting_config_t cali_cfg = {
        .unit_id = kUnit,
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_12,
    };
    if (adc_cali_create_scheme_curve_fitting(&cali_cfg, &g_cali) != ESP_OK) {
        g_cali = nullptr;
        ESP_LOGW(TAG, "无校准表，改用线性换算");
    }

    ESP_LOGI(TAG, "电量检测就绪（GPIO4 / ADC1_CH3，分压 %d:1）", kDivider);
    return true;
}

bool Read(int* percent, int* millivolts) {
    if (g_adc == nullptr) {
        return false;
    }

    int sum = 0;
    int taken = 0;
    for (int i = 0; i < kSamples; i++) {
        int mv = 0;
        if (Sample(&mv)) {
            sum += mv;
            taken++;
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }
    if (taken == 0) {
        return false;
    }

    float avg = static_cast<float>(sum) / taken;
    g_ema_mv = g_ema_ready ? kEmaAlpha * avg + (1.0f - kEmaAlpha) * g_ema_mv : avg;
    g_ema_ready = true;

    int smoothed = static_cast<int>(g_ema_mv + 0.5f);
    if (millivolts != nullptr) {
        *millivolts = smoothed;
    }
    if (percent != nullptr) {
        *percent = Percent(smoothed);
    }
    return true;
}

}  // namespace battery
