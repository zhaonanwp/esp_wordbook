#ifndef _WORDCARD_BOARD_CONFIG_H_
#define _WORDCARD_BOARD_CONFIG_H_

#include <driver/gpio.h>

#define ESP32_LCD_HOST      SPI3_HOST

// ===== RLCD 4.2 屏（400x300 1-bit 反射式液晶，SPI）=====
#define RLCD_DC_PIN    GPIO_NUM_5
#define RLCD_CS_PIN    GPIO_NUM_40
#define RLCD_SCK_PIN   GPIO_NUM_11
#define RLCD_MOSI_PIN  GPIO_NUM_12
#define RLCD_RST_PIN   GPIO_NUM_41
#define RLCD_TE_PIN    GPIO_NUM_6

#define RLCD_WIDTH   400
#define RLCD_HEIGHT  300

// ===== 按键（全板只有这两个，无触摸；中间那个是 PWR，固件读不到）=====
// 2026-10-10 实机确认：BOOT 在屏幕右侧，KEY 在左侧。
#define BOOT_BUTTON_GPIO        GPIO_NUM_0   // 右侧
#define USER_BUTTON_GPIO        GPIO_NUM_18  // 左侧 KEY 按钮

// ===== 音频（ES8311 播放 / ES7210 录音）=====
// 当前只接播放；ES7210 与 PA 之外的录音相关定义保留，日后要做跟读不用改硬件层。
#define AUDIO_OUTPUT_SAMPLE_RATE  24000
#define AUDIO_I2S_GPIO_MCLK       GPIO_NUM_16
#define AUDIO_I2S_GPIO_WS         GPIO_NUM_45
#define AUDIO_I2S_GPIO_BCLK       GPIO_NUM_9
#define AUDIO_I2S_GPIO_DOUT       GPIO_NUM_8
#define AUDIO_I2S_GPIO_DIN        GPIO_NUM_10
#define AUDIO_CODEC_PA_PIN        GPIO_NUM_46
#define AUDIO_CODEC_I2C_SDA_PIN   GPIO_NUM_13
#define AUDIO_CODEC_I2C_SCL_PIN   GPIO_NUM_14
#define AUDIO_CODEC_ES8311_ADDR   ES8311_CODEC_DEFAULT_ADDR
#define AUDIO_CODEC_ES7210_ADDR   ES7210_CODEC_DEFAULT_ADDR

#endif
