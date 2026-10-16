#include "audio_out.h"

#include "driver/i2c_master.h"
#include "driver/i2s_std.h"
#include "esp_log.h"

#include "esp_codec_dev.h"
#include "esp_codec_dev_defaults.h"

#include "config.h"

namespace {

constexpr char TAG[] = "AudioOut";

// 默认档位只有一个来源：audio_out.h 里的 audio::kDefaultVolume。
constexpr int kDefaultVolume = audio::kDefaultVolume;
constexpr uint32_t kBootSampleRate = 48000;

i2c_master_bus_handle_t g_i2c = nullptr;
i2s_chan_handle_t g_tx = nullptr;
const audio_codec_data_if_t* g_data_if = nullptr;
const audio_codec_ctrl_if_t* g_ctrl_if = nullptr;
const audio_codec_gpio_if_t* g_gpio_if = nullptr;
const audio_codec_if_t* g_codec_if = nullptr;
esp_codec_dev_handle_t g_dev = nullptr;
bool g_open = false;
int g_volume = kDefaultVolume;

}  // namespace

namespace audio {

bool Init() {
    i2c_master_bus_config_t bus_cfg = {};
    bus_cfg.i2c_port = I2C_NUM_0;
    bus_cfg.sda_io_num = AUDIO_CODEC_I2C_SDA_PIN;
    bus_cfg.scl_io_num = AUDIO_CODEC_I2C_SCL_PIN;
    bus_cfg.clk_source = I2C_CLK_SRC_DEFAULT;
    bus_cfg.glitch_ignore_cnt = 7;
    // 板上这两个脚没有外部上拉，不开内部上拉就读不到 codec
    bus_cfg.flags.enable_internal_pullup = true;
    if (i2c_new_master_bus(&bus_cfg, &g_i2c) != ESP_OK) {
        ESP_LOGE(TAG, "I2C0 起不来");
        return false;
    }

    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
    chan_cfg.dma_desc_num = 6;
    chan_cfg.dma_frame_num = 256;
    if (i2s_new_channel(&chan_cfg, &g_tx, nullptr) != ESP_OK) {
        ESP_LOGE(TAG, "I2S0 通道起不来");
        return false;
    }

    i2s_std_config_t std_cfg = {};
    std_cfg.clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(kBootSampleRate);
    std_cfg.slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT,
                                                           I2S_SLOT_MODE_MONO);
    std_cfg.gpio_cfg = {
        .mclk = AUDIO_I2S_GPIO_MCLK,
        .bclk = AUDIO_I2S_GPIO_BCLK,
        .ws = AUDIO_I2S_GPIO_WS,
        .dout = AUDIO_I2S_GPIO_DOUT,
        .din = I2S_GPIO_UNUSED,
    };
    if (i2s_channel_init_std_mode(g_tx, &std_cfg) != ESP_OK) {
        ESP_LOGE(TAG, "I2S0 STD 配置失败");
        return false;
    }

    audio_codec_i2s_cfg_t i2s_cfg = {
        .port = I2S_NUM_0,
        .rx_handle = nullptr,
        .tx_handle = g_tx,
    };
    g_data_if = audio_codec_new_i2s_data(&i2s_cfg);

    audio_codec_i2c_cfg_t i2c_cfg = {
        .port = I2C_NUM_0,
        .addr = AUDIO_CODEC_ES8311_ADDR,
        .bus_handle = g_i2c,
    };
    g_ctrl_if = audio_codec_new_i2c_ctrl(&i2c_cfg);
    g_gpio_if = audio_codec_new_gpio();

    es8311_codec_cfg_t es_cfg = {};
    es_cfg.ctrl_if = g_ctrl_if;
    es_cfg.gpio_if = g_gpio_if;
    es_cfg.codec_mode = ESP_CODEC_DEV_WORK_MODE_DAC;
    es_cfg.pa_pin = AUDIO_CODEC_PA_PIN;
    es_cfg.master_mode = false;  // 时钟由 ESP32 出，codec 是从机
    es_cfg.use_mclk = true;
    es_cfg.hw_gain.pa_voltage = 5.0;
    es_cfg.hw_gain.codec_dac_voltage = 3.3;
    g_codec_if = es8311_codec_new(&es_cfg);

    esp_codec_dev_cfg_t dev_cfg = {};
    dev_cfg.dev_type = ESP_CODEC_DEV_TYPE_OUT;
    dev_cfg.codec_if = g_codec_if;
    dev_cfg.data_if = g_data_if;
    g_dev = esp_codec_dev_new(&dev_cfg);

    if (g_data_if == nullptr || g_ctrl_if == nullptr || g_gpio_if == nullptr ||
        g_codec_if == nullptr || g_dev == nullptr) {
        ESP_LOGE(TAG, "ES8311 通路没搭起来");
        g_dev = nullptr;
        return false;
    }

    ESP_LOGI(TAG, "音频输出就绪（ES8311 @0x%02x，PA GPIO%d）", AUDIO_CODEC_ES8311_ADDR,
             static_cast<int>(AUDIO_CODEC_PA_PIN));
    return true;
}

bool Ready() {
    return g_dev != nullptr;
}

bool Begin(uint32_t sample_rate, uint8_t channels) {
    if (g_dev == nullptr || sample_rate == 0 || channels == 0 || channels > 2) {
        return false;
    }
    esp_codec_dev_sample_info_t fs = {};
    fs.sample_rate = sample_rate;
    fs.bits_per_sample = 16;
    fs.channel = channels;
    fs.mclk_multiple = 0;  // 0 → 驱动按 256×采样率出 MCLK

    const int ret = esp_codec_dev_open(g_dev, &fs);
    if (ret != ESP_CODEC_DEV_OK) {
        ESP_LOGE(TAG, "codec 打开失败（%uHz %u声道）ret=%d", static_cast<unsigned>(sample_rate),
                 static_cast<unsigned>(channels), ret);
        return false;
    }
    g_open = true;
    esp_codec_dev_set_out_vol(g_dev, g_volume);
    return true;
}

void SetVolume(int percent) {
    if (percent < 0) {
        percent = 0;
    } else if (percent > 100) {
        percent = 100;
    }
    // 只记账，不碰寄存器：codec 走 I2C，而 open/write/close 全在播放任务手里，
    // 按键任务这时候插一脚是跟它抢总线。真正下发在 Begin，每次播放都带上当前的档位。
    g_volume = percent;
}

int Volume() {
    return g_volume;
}

bool Write(const void* pcm, size_t bytes) {
    if (!g_open || bytes == 0) {
        return false;
    }
    return esp_codec_dev_write(g_dev, const_cast<void*>(pcm), static_cast<int>(bytes)) ==
           ESP_CODEC_DEV_OK;
}

void End() {
    if (!g_open) {
        return;
    }
    g_open = false;
    esp_codec_dev_close(g_dev);
}

}  // namespace audio
