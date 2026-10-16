# WORDCARD 单词机

基于 **Waveshare ESP32-S3-RLCD-4.2**（反射式液晶屏）做的实体背单词机：孩子每周从课堂拿回一批单词，家长在手机上录成词库、排好艾宾浩斯当天该复习的那一张表，用 BLE 推进设备；设备离线翻卡、播发音，自己记住哪一轮哪个词被按了「想不起来」。

设备**不联网**（固件里没有 Wi-Fi 栈）。手机是词库的唯一源头，设备是练习结果的唯一记录者 —— 孩子练的时候蓝牙是断开的，一轮轮结果先攒在设备的 `rounds.tsv` 里，等下次连上手机再回传入账。整条链路只有蓝牙 GATT 和发音音频那一次抓取。

## 仓库结构

| 目录 | 内容 |
|---|---|
| [`firmware/`](firmware/) | ESP-IDF 固件（C++ + LVGL 9.4），闪卡 UI、BLE 收词、发音播放、轮次结果落盘、电池保护 |
| [`app/`](app/) | Flutter 手机侧（仅 Android）：录词、排期、BLE 推送、把设备攒的轮次取回来入账 |
| [`firmware/tools/ble_push.py`](firmware/tools/ble_push.py) | PC 侧推词/推发音脚本，是固件的验收工具，也是协议的参照实现 |

协议在两处各有一份实现，改一边必须同步另一边：`app/lib/core/protocol.dart` ↔ `firmware/main/comm/ble_ingest.cc`。

## 硬件

- 屏：4.2 寸 1-bit 反射式液晶，400×300，SPI（`RLCD_*` 引脚见 [`firmware/main/board/config.h`](firmware/main/board/config.h)）
- 音频：ES8311 播放，24kHz 输出；ES7210 录音相关定义保留但当前没接
- 按键：全板只有两个可读 —— 右侧 BOOT（GPIO0）、左侧 KEY（GPIO18）；中间那颗是 PWR，固件读不到；板子没有 RESET
- Flash 16MB，分区表 [`firmware/partitions/wordcard-16m.csv`](firmware/partitions/wordcard-16m.csv)：两个 3.5MB app 分区 + 一个 8MB `storage`（FAT + 磨损均衡，偏移 `0x800000`），存 `words.tsv` 和抓下来的发音音频
- 供电与 ADC 相关实测结论写在 [`firmware/main/board/battery.cc`](firmware/main/board/battery.cc) 和 README 提交记录里

## 固件

要求 ESP-IDF **≥ 5.5**（实测用 5.5.4），目标芯片 esp32s3。依赖由 `main/idf_component.yml` 拉取（LVGL、esp_lvgl_port、espressif/button、esp_codec_dev、esp_audio_codec）。

```powershell
cd firmware
.\build.ps1 set-target esp32s3   # 转给 idf.py，构建 / 烧录 / monitor 同理
.\build.ps1 build
.\build.ps1 flash monitor
```

`build.ps1` / `flash-all.ps1` / `flash-wordbook.ps1` / `pull-battery-log.ps1` 里写死了这台开发机上 eim 装的那份激活脚本路径（`C:\Espressif\tools\Microsoft.v5.5.4.PowerShell_profile.ps1`），换机器改成你自己的 profile 路径，或直接绕过脚本用 `idf.py`。Git Bash 里调 PowerShell 跑这些脚本要先滤掉 PATH 里的 mingw，脚本里那两行 `$Env:Path = ...` 就是干这个的。

词表也可以不进 BLE、直接烧进数据分区：

```powershell
.\flash-wordbook.ps1              # data/words.tsv -> WL-FAT 镜像 -> storage 分区
.\flash-wordbook.ps1 -Action gen  # 只生成镜像
```

## App

Flutter（Dart SDK ≥ 3.12），只出 Android 包：

```bash
cd app
flutter pub get
dart analyze lib test && flutter test
flutter build apk --release --target-platform android-arm64
```

日常操作只有一条路径：**复习计划页**逐词打勾 → 推「今天这张表」。这一趟的开头会先把设备上攒下的轮次取回来入账，再推新表；「整本重推」那个维护入口不收结果、也不记排期账。首页是只读概览。页面职责、词库模型（来源 + 批次）、排期算法都写在 [`app/README.md`](app/README.md) 里。

## BLE 协议

设备名 `WORDCARD`，GATT service `0xFFE0`，特征：`0xFFE1` 命令、`0xFFE2` 通知、`0xFFE3` 数据。

- 命令是 JSON（带 `crc32` 字段），数据通道按帧传，帧头 10 字节 + payload
- 词表是 TSV：`单词	音标	中文释义	例句`，`#` 开头是注释行
- 设备侧字段是定长缓冲区（`snprintf`，超了静默截断）：word 63 / phonetic 95 / meaning 191 / example 319 字节（UTF-8），**手机侧必须先拦**
- 发音音频推之前要按文件头魔数判容器 —— 有道的 `Content-Type` 对 RIFF/WAVE 也报 `audio/mpeg`
- 结果是**反方向**回的：`stat` 里报 `pending_rounds` / `oldest_round`，手机按 `result_get` 取，一轮 `result_rows` 切成若干条通知（每条一个 ATT 包，上限 509 字节），数满才 `result_ack`，设备收到 ack 才把那轮从 `rounds.tsv` 删掉。设备没有墙钟，归账日期、档位、去重全在手机侧

`tools/ble_push.py` 是一份能跑的最小实现，接协议时比读 C++ 快。

## 字体

设备中文字体是 **Fusion Pixel** 点阵 24px（英文 IPA 用另一套小字号）。仓库里入库的是 LVGL 转换后的产物 `main/board/fonts/font_pixel_24_1.c`（约 3MB），源 ttf（每个 7MB）不进仓库。要改字号或换字符集，用 [`firmware/tools/fonts/gen_font.js`](firmware/tools/fonts/gen_font.js) 自己生成。

Fusion Pixel 和 Alibaba PuHuiTi 都是 **SIL Open Font License 1.1**，许可原文随字体文件放在 [`firmware/main/board/fonts/`](firmware/main/board/fonts/)。

## 第三方

LVGL (MIT)、`esp_lvgl_port`、`espressif/button`、`esp_codec_dev`、`esp_audio_codec` (Apache-2.0)；Flutter 侧 `flutter_blue_plus` 特意钉在 1.36.8（2.0 起换成了收费的自定义授权，1.x 还是 BSD-3）、`permission_handler` 钉 11.x（13.x 的 android 子包把 compileSdk 钉在 37，本机 SDK 认不出）。原因写在 `app/pubspec.yaml` 注释里，别顺手 `pub upgrade`。

发音音频取自有道公开接口 `dict.youdao.com/dictvoice`（不是官方 API，没有文档承诺）。自己用请判断清楚使用条款。

## 许可

MIT，见 [LICENSE](LICENSE)。字体另受 OFL 1.1 约束。
