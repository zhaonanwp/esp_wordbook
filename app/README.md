# wordcard_app

WORDCARD 单词机（ESP32-S3 + 反射式液晶屏）的手机侧配套 App：**录词库、经 BLE 把一整本词和发音推进设备**。
只跑 Android，不配网、不联网同步 —— 手机是词库的唯一源头，设备上永远只装一本。

用的节奏是「**推一批 → 孩子在设备上自己练 → 练完换下一批整本替换**」。

## 目录

- `lib/core/` —— 与固件对齐的纯逻辑：`protocol.dart`（帧 / crc32 / TSV / 字段长度上限）、`word_prompt.dart`（发给 AI 的录词提示词）
- `lib/data/` —— `device_link.dart`（GATT 读写 + 通知环形缓冲）、`sync_runner.dart`（推送状态机）、`wordbook_store.dart`（词库 + "设备上现在这批"那个指针）、`lexicon.dart` / `youdao.dart`
- `lib/features/` —— 五个页面：首页（批次播放器）、推到设备、录入、扫描、设定
- `lib/ui/hard_style.dart` —— 全站唯一的皮肤

手机本地数据（没有数据库）：`documents/weeks/<批次名>.json` 一批一本（目录名还叫 weeks 是历史包袱），`documents/device_sheet.json` 设备上现在是哪一批 + 推的日期，`documents/sources.json` 来源那一列。

## 页面职责

- **首页 = 批次播放器**：连接状态、「设备上现在这批」（批次名 / 词数 / 哪天推的 / 发音已存几个）、词库列表。点一批就进推送页把它推上去。
- **推到设备页 = 唯一的推送动作**：选中的那一整本原样替换设备上的词表；进度条、阶段数字、日志都在这页。推成功才写"设备上现在这批"那个指针。
- **录入页**：粘 AI 出的成品行 → 抠词 → 缺释义的查有道 → 逐行核对 → 存成一批。
- **找设备页 = 纯连接**：连上就退回调用方，不当导航中枢。
- **设定页**：只有词库来源那一列。

### 「设备上现在这批」是手机记的账，不是从设备读回来的

`WordbookStore.onDevice` 只在推送成功后写。所以这几种情况下它会失真：跑过 `flash-all` 把 storage 格了、设备被别的手机推过、设备自己掉了电（词表在盘上，指针还是在的，这条没事）。
界面上这句话写成了「上次推于 …」而不是「设备上是 …」。真要核对点推送页 AppBar 那个「读设备状态」—— `stat` 会回 `stored_words`，对不上就是指针失真，重推一次即可。
删批次时如果删的正是这批，指针跟着清空（`delete()` 里那句 `markOnDevice('')`），首页改口说"不知道设备上装的是谁"—— 留一个已经不存在的名字比留空更难查。

## 词库模型

一个批次 = **来源 + 批次名**。来源内置 `课本` / `新东方` 两个当默认值，**设定页里能加能改能删**（存在 `documents/sources.json`）；它只当分组和显示，不决定推哪一本 —— 那永远是他在首页挑的。
批次名他自己起（`Unit 3`、`10-11 那节课`），跨来源唯一，因为**一本书就是一个文件**；列表按"最近改动"排，不按名字的字面顺序（`Unit 10` 会排在 `Unit 9` 前面）。

**批次名不能改** —— 它就是文件名，改名等于换一本书。首页每行右边的编辑按钮里只做两件事：改来源、删掉这批。删掉只拿走手机上的这一本，发音缓存留着（重录同名批次还能接上），设备上那张表不受影响。

**来源反过来随便改** —— 它只是个显示用的字符串，不是文件名也不是指针。改名会带着用它的那几批一起换姓（词和发音标记都不动）；删掉不动批次，那几本只是顶着一个不在列表里的名字继续显示，录入页和批次管理那两排 chip 会把它带回去，免得当前归属点不出来。最后一个不许删。

批次名进文件名要洗（`fileSafe`：`\/:*?"<>|` 和空白 → `_`）。**已知代价：`Unit 3` 和 `Unit_3` 会撞成同一个文件**，靠录入页按名字判重的覆盖/追加对话框拦。

## 为什么把日更排期砍了（别顺手加回来）

v0.1.16–v0.1.23 那套是艾宾浩斯日更：手机每天抽「到期复习 + 当前批次新词 N 个」拼一张临时表推上去，孩子在设备上练完回来打勾，六档（1/2/4/7/15/30 天）走完毕业。

**它成立的前提是每天碰一次手机。** 实际节奏是一批练几天到一周才换，于是每天不推的那天，到期数就开始涨假账、首页一片红字逾期，"今天这张表"和课本也脱钩。他 2026-10-22 定的：**先换成批次播放器，掌握度那些一律不管。**

所以 `plan_page.dart` / `plan_rows.dart` / `schedule.dart` / `round_sync.dart`（设备轮次回传）整个删掉了，`documents/schedule.json` **留在手机上不读也不删** —— 里面那半年的档位是真攒出来的，哪天想回日更那条路还有得接。设备端 `rounds.tsv` 还在写，只是 app 不再取了。

## 和固件的契约

BLE 契约冻结在固件 `main/comm/ble_ingest.h`，app 侧不动固件。
**JSON 键名只能从 `ble_ingest.cc` 里的 `cJSON_Add*ToObject` 现场核**，别照头文件注释或 `ble_push.py` 猜 —— 上行错误的字段是 `m`，不是 `msg`。
通知字段是 `t`，值 `wb_begin_ok / wb_done / au_done / stat / error`。
单条 `wb_word` 的 UTF-8 长度受 MTU 限制，`requestMtu(512)` 失败必须报错不能咽。

**发音这一半：`au_end` 是设备离开「接收发音」那页的唯一出口**（另一个是断开连接）。
固件在 offset 对不上时会自己废弃这个文件、只回一条 error、屏幕上什么都不换，所以手机半途而废（按停止、链路断了、`takeError` 撞上）必须补发一条 `au_end` 收尾，并且把它的回执读掉 —— 那个 error 留在环形缓冲里，下一次推送的第一个 `waitFor` 会撞上它，把好的那一次也顶成失败。见 `sync_runner.dart` 的 `_abandonAudio`，`test/sync_audio_test.dart` 用假链路盯着这条。

**换批为什么快**：发音文件按 slug 存在设备上、不随词表替换，`WeekBook.audioMark[slug]`（"容器:crc32"）记着设备上已经是哪一份，默认跳过（一个词省 5-7 秒）。所以不勾「同时抓有道发音」时换一批就是一两千字节、两三秒。
指针失真时（格过 storage、设备侧文件被删）设备上其实没有这个文件、app 却记成"已经有了"，点着没声音 —— 推送页留了「强制重推」兜底。**平时别勾**：勾了就是每个词重传一遍发音。

## UI 约定

- 全站只有 `hardTheme()` 一个主题，页面里不写死颜色；语义色两个：`Hard.blue` 正常动作、`Hard.coral` 会出事（截断 / 失败 / 设备上是谁说不清）。
- **中文标签不吃 `letterSpacing`**，这套风格原稿靠"全大写 + 字距"撑门面，汉字一拉字距就散。
- 卡片左右间距用 `Hard.gutter()`（左 12 / 右 16，多出的 4px 是硬阴影的偏移量），别在页面里自己写 `fromLTRB(12, …, 16, …)`。
- 阴影只给最外层卡片（`Hard.box`），卡片内部的小格子用 `Hard.frame`，阴影叠阴影会糊。
- 只读计数用 `HardTag`，能点的选项（选批次、选来源）用 `HardChip` —— 别拿 `HardTag` 套 `InkWell`，也别引第三方 chip 包，它们带不来这套皮。
- **进度条只在推送中渲染**，空闲时整块不占位：一根永远满格的灰线看着像卡住了。
- 一行里要塞下"必须完整的那个"和"可以截断的那个"时：必须完整的用普通 `Text`，可截断的给 `Flexible`。Flex 先量非弹性孩子，两个都给 `flex` 的话各按 `n/Σflex` 封顶，明明有空也截。
- 首页那几屏的宽度是量出来的不是看着定的：临时写个 `testWidgets` 打印 `tester.getSize(find.text(...))`（要包在 `tester.runAsync` 里），比猜靠谱。

## 代码约定

`analysis_options.yaml` 在 flutter_lints 之外开了 `prefer_single_quotes` 和 `avoid_print`：界面文案和日志全是中文，单引号统一下来才好全局搜；调试输出一律 `debugPrint`，release 包里会被剥掉。

## 改完之后怎么验

```bash
dart analyze lib test          # 应当 No issues found
flutter test                   # 协议层 + 推送进度 + 录入解析 + 词库/指针落盘的单测
LOOK=1 flutter test --update-goldens test/look_pages_test.dart
```

最后那条**不出 APK 就能看界面**：往 `test/goldens/` 输出首页 / 推送 / 录入 / 设定（含五个弹窗）的截图，共十一张（根目录 `皮肤-1首页` … `皮肤-11删来源` 一一对应）。
读截图时记住边界 —— **版式、配色、溢出可信，中文和图标会画成方块**（借的是 Windows 等线字体，MaterialIcons 在测试里不加载）；扫描页依赖 flutter_blue_plus 和 permission_handler，没有 mock，出不来。

## 出包

这台机器上不插线调试，改完直接出包给他侧装：

```bash
flutter build apk --release --target-platform android-arm64
```

只出 arm64：不写 `--target-platform` 的胖包会把引擎 + AOT 各打三份（arm64 / armv7 / x86_64），49MB 里 97% 是重复的原生库，手机只用其中一份；限定 ABI 后 17.2MB。
插件自带的 `libdartjni.so` 还是三个 ABI 各一份、共 230KB，够不着也不值得管。

产物拷一份到工程根目录，命名 `单词机同步-vX.Y.Z-release.apk`，**版本号与 `pubspec.yaml` 的 `version` 保持一致**。
release 用 Flutter 默认 debug keystore 签名，同签名可以覆盖安装，不用先卸载。
**从胖包（三 ABI）换到单 ABI 包的那一次覆盖安装已经真机走过**（2026-10-14，v0.1.16 胖包 → v0.1.17 单 ABI）：词库、发音标记都在 app 私有目录里，覆盖安装不丢。
装失败也别卸载重装 —— 词库一没就找不回来了。

依赖钉版本的两条原因写在 `pubspec.yaml` 注释里（flutter_blue_plus 的授权、permission_handler 的 compileSdk 37），别顺手 `pub upgrade`。
`android/gradle/wrapper/gradle-wrapper.properties` 指向腾讯镜像，不是 services.gradle.org。
