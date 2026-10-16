import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordcard_app/core/protocol.dart';
import 'package:wordcard_app/data/device_link.dart';
import 'package:wordcard_app/data/sync_runner.dart';
import 'package:wordcard_app/data/wordbook_store.dart';
import 'package:wordcard_app/data/youdao.dart';

/// 假链路：只记手机发出去过什么命令、等过什么回执，不碰 flutter_blue_plus。
class FakeLink extends BleLink {
  FakeLink({this.auDoneErrors = false});

  final bool auDoneErrors;

  final List<String> commands = [];
  final List<String> waited = [];
  int frames = 0;
  int? breakAtFrame;
  int? cancelAtFrame;
  SyncRunner? runner;

  @override
  int get chunk => 60;

  @override
  Future<void> writeCommand(Map<String, dynamic> command) async {
    commands.add('${command['t']}');
  }

  @override
  Future<void> writeFrame(List<int> frame) async {
    frames += 1;
    if (cancelAtFrame == frames) runner?.cancel();
  }

  @override
  String? takeError() {
    final at = breakAtFrame;
    if (at == null || frames != at) return null;
    breakAtFrame = null;
    return 'offset 对不上（期望 120，收到 60）';
  }

  @override
  Future<Map<String, dynamic>> waitFor(String type, Duration timeout) async {
    waited.add(type);
    if (type == 'au_done' && auDoneErrors) {
      throw LinkException('设备报错：没有正在传输的音频');
    }
    if (type == 'wb_done') return {'n': 1};
    if (type == 'stat') return {'stored_words': 1, 'audio_ok': 0};
    return <String, dynamic>{};
  }
}

class FakeYoudao extends Youdao {
  FakeYoudao() : super(Directory.systemTemp);

  @override
  Future<AudioBlob?> fetch(String word, {bool cache = true}) async =>
      AudioBlob('mp3', Uint8List.fromList(List.generate(200, (i) => i % 251)));
}

WeekBook oneWord() => WeekBook(
  label: '测试',
  version: 'v1',
  updatedAt: DateTime(2026, 10, 15),
  words: const [WordEntry(word: 'apple', meaning: 'n. 苹果')],
);

const sent = ['wb_begin', 'wb_word', 'wb_end', 'au_begin', 'au_end'];

Future<Object?> failure(SyncRunner runner) async {
  try {
    await runner.push(oneWord(), withAudio: true);
  } catch (e) {
    return e;
  }
  return null;
}

void main() {
  test('发音顺利传完：一条 au_begin 一条 au_end，最后读一次 stat', () async {
    final link = FakeLink();
    final runner = SyncRunner(link, FakeYoudao());

    await runner.push(oneWord(), withAudio: true);

    expect(link.frames, 4);
    expect(link.commands, [...sent, 'stat']);
    expect(runner.stage, '好了');
  });

  test('设备中途废弃了文件，手机补一条 au_end 把画面放出去', () async {
    final link = FakeLink()..breakAtFrame = 2;
    final err = await failure(SyncRunner(link, FakeYoudao()));

    expect((err as LinkException).message, contains('offset'));
    expect(link.commands, sent);
    expect(link.waited.last, 'au_done');
  });

  test('按停止停在半截，也一样补 au_end', () async {
    final link = FakeLink()..cancelAtFrame = 2;
    final runner = SyncRunner(link, FakeYoudao());
    link.runner = runner;

    final err = await failure(runner);

    expect((err as LinkException).message, contains('已停止'));
    expect(link.commands, sent);
  });

  test('补发的 au_end 换回 error，不顶掉真正的失败原因', () async {
    final link = FakeLink(auDoneErrors: true)..breakAtFrame = 1;

    final err = await failure(SyncRunner(link, FakeYoudao()));

    expect((err as LinkException).message, contains('offset'));
    expect(link.commands.last, 'au_end');
  });
}
