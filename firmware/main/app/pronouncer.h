#ifndef _WORDCARD_PRONOUNCER_H_
#define _WORDCARD_PRONOUNCER_H_

// 单个词的发音：storage 分区 audio/ 下的 MP3 或 WAV，由播放任务解码后喂 I2S。
namespace pron {

// 建功放通路并起播放任务。失败返回 false，发音整体不可用，其余功能不受影响。
bool Init();

// 这个词有没有发音文件（决定提示条写什么）。
bool HasAudio(const char* word);

// 投递一次播放，立即返回。正在播的先收尾，排队中的旧请求丢掉。
void Play(const char* word);

void Stop();

}  // namespace pron

#endif
