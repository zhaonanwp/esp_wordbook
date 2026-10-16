#include "rlcd_display.h"
#include "config.h"

#include <cstring>
#include "esp_log.h"
#include "esp_heap_caps.h"
#include "esp_lvgl_port.h"

static const char* TAG = "RlcdDisplay";

// 思源/普惠 7415 常用汉字，14px / 1bpp。屏是 1-bit，flush 时灰度会被阈值化，
// 4bpp 抗锯齿在这块屏上没有收益，所以用 1bpp 版本，体积约为 4bpp 的 1/4。
LV_FONT_DECLARE(font_puhui_14_1);

RlcdDisplay* RlcdDisplay::GetInstance() {
    static RlcdDisplay* instance = nullptr;
    if (instance == nullptr) {
        instance = new RlcdDisplay();
        instance->Init();
    }
    return instance;
}

void RlcdDisplay::FlushCb(lv_display_t* disp, const lv_area_t* area, uint8_t* color_p) {
    auto* self = static_cast<RlcdDisplay*>(lv_display_get_user_data(disp));
    auto* buffer = reinterpret_cast<uint16_t*>(color_p);
    for (int y = area->y1; y <= area->y2; y++) {
        for (int x = area->x1; x <= area->x2; x++) {
            self->rlcd_->RLCD_SetPixel(x, y, (*buffer < 0x7fff) ? ColorBlack : ColorWhite);
            buffer++;
        }
    }
    self->rlcd_->RLCD_Display();
    lv_disp_flush_ready(disp);
}

void RlcdDisplay::Init() {
    if (ready_) {
        return;
    }

    spi_display_config_t spi_config = {};
    spi_config.mosi = RLCD_MOSI_PIN;
    spi_config.scl = RLCD_SCK_PIN;
    spi_config.dc = RLCD_DC_PIN;
    spi_config.cs = RLCD_CS_PIN;
    spi_config.rst = RLCD_RST_PIN;

    rlcd_ = new RlcdDriver(spi_config, RLCD_WIDTH, RLCD_HEIGHT, ESP32_LCD_HOST);

    lv_init();
    lvgl_port_cfg_t port_cfg = ESP_LVGL_PORT_INIT_CONFIG();
    port_cfg.task_priority = 2;
    port_cfg.timer_period_ms = 50;
    ESP_ERROR_CHECK(lvgl_port_init(&port_cfg));

    lvgl_port_lock(0);

    display_ = lv_display_create(RLCD_WIDTH, RLCD_HEIGHT);
    lv_display_set_flush_cb(display_, FlushCb);
    lv_display_set_user_data(display_, this);

    size_t buffer_size = LV_COLOR_FORMAT_GET_SIZE(LV_COLOR_FORMAT_RGB565) * RLCD_WIDTH * RLCD_HEIGHT;
    auto* buffer = static_cast<uint8_t*>(heap_caps_malloc(buffer_size, MALLOC_CAP_SPIRAM));
    ESP_ERROR_CHECK(buffer == nullptr ? ESP_ERR_NO_MEM : ESP_OK);
    lv_display_set_buffers(display_, buffer, nullptr, buffer_size, LV_DISPLAY_RENDER_MODE_PARTIAL);
    ESP_LOGI(TAG, "LVGL 缓冲 %u 字节 @ PSRAM, internal free=%u",
             static_cast<unsigned>(buffer_size),
             static_cast<unsigned>(heap_caps_get_free_size(MALLOC_CAP_INTERNAL)));

    rlcd_->RLCD_Init();

    screen_ = lv_screen_active();
    lv_obj_set_style_bg_color(screen_, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(screen_, LV_OPA_COVER, 0);

    lvgl_port_unlock();

    ready_ = true;
    ESP_LOGI(TAG, "显示层就绪 %dx%d", RLCD_WIDTH, RLCD_HEIGHT);
}

void RlcdDisplay::Lock() {
    lvgl_port_lock(0);
}

void RlcdDisplay::Unlock() {
    lvgl_port_unlock();
}

void RlcdDisplay::ShowTestCard(const char* line1, const char* line2) {
    if (!ready_) {
        return;
    }

    Lock();
    if (line1_label_ == nullptr) {
        line1_label_ = lv_label_create(screen_);
        lv_obj_set_style_text_font(line1_label_, &lv_font_montserrat_48, 0);
        lv_obj_set_style_text_color(line1_label_, lv_color_black(), 0);
        lv_obj_align(line1_label_, LV_ALIGN_CENTER, 0, -40);

        line2_label_ = lv_label_create(screen_);
        lv_obj_set_style_text_font(line2_label_, &font_puhui_14_1, 0);
        lv_obj_set_style_text_color(line2_label_, lv_color_black(), 0);
        lv_obj_set_width(line2_label_, RLCD_WIDTH - 40);
        lv_label_set_long_mode(line2_label_, LV_LABEL_LONG_WRAP);
        lv_obj_set_style_text_align(line2_label_, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_align(line2_label_, LV_ALIGN_CENTER, 0, 30);
    }
    lv_label_set_text(line1_label_, line1);
    lv_label_set_text(line2_label_, line2);
    lv_obj_invalidate(screen_);
    Unlock();
}
