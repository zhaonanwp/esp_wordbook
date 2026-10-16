#ifndef _WORDCARD_AUDIO_OUT_H_
#define _WORDCARD_AUDIO_OUT_H_

#include <cstddef>
#include <cstdint>

// 喇叭通路：I2C 配 ES8311，I2S 送 16bit PCM，功放使能脚由 codec 驱动自己管。
// 只做播放；ES7210 录音等做跟读时再加。
namespace audio {

// 板子上 ES8311 后面还有一级固定增益的 D 类功放，所以默认不用拉满。
constexpr int kDefaultVolume = 60;

// 建立 I2C / I2S / codec 三层。失败不影响别的模块，只是发音不可用。
bool Init();
bool Ready();

// 0-100，ES8311 硬件音量（0 = 静音）。这里只是存着，
// codec 只有在通路开着的时候才接受音量寄存器，所以真正下发在 Begin 里。
void SetVolume(int percent);
int Volume();

// 一次播放的边界。采样率跟着文件走（有道给的 MP3 是 48k，WAV 可能是别的），
// 所以 Begin 里重配 I2S 和 codec，End 关功放免得一直嘶嘶响。
bool Begin(uint32_t sample_rate, uint8_t channels);
bool Write(const void* pcm, size_t bytes);
void End();

}  // namespace audio

#endif
