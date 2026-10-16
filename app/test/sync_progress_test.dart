import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordcard_app/data/device_link.dart';
import 'package:wordcard_app/data/sync_runner.dart';
import 'package:wordcard_app/data/youdao.dart';

/// 只测进度记账，不碰 BLE：`push()` 需要真链路，这里直接把计数字段摆成推送过程中
/// 会出现的样子。构造 BleLink/Youdao 都只建对象不动插件（`Directory.systemTemp`
/// 只是存起来当缓存路径）。
SyncRunner runner() => SyncRunner(BleLink(), Youdao(Directory.systemTemp));

void main() {
  test('抓不到的词也算处理过，进度条能走满', () {
    final r = runner()
      ..wordsTotal = 14
      ..wordsDone = 14
      ..audioTotal = 14
      ..audioDone = 12
      ..audioFailed = 2;
    expect(r.audioFraction, 1.0);
    expect(r.progress, 1.0);
  });

  test('一个都没推成，条子照样到头（数字那行会写失败几个）', () {
    final r = runner()
      ..wordsTotal = 5
      ..wordsDone = 5
      ..audioTotal = 5
      ..audioFailed = 5;
    expect(r.audioFraction, 1.0);
  });

  test('进度封顶在 1，不会算出 120%', () {
    final r = runner()
      ..wordsTotal = 3
      ..wordsDone = 3
      ..audioTotal = 3
      ..audioDone = 5
      ..audioFailed = 1;
    expect(r.audioFraction, 1.0);
    expect(r.progress, 1.0);
  });

  test('只推词表不推发音时，进度按词表那一半走', () {
    final r = runner()
      ..wordsTotal = 4
      ..wordsDone = 2
      ..audioTotal = 0;
    expect(r.audioFraction, 1.0);
    expect(r.progress, closeTo(0.5 * 0.85 + 0.15, 1e-9));
  });
}
