import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:wordcard_app/core/protocol.dart';
import 'package:wordcard_app/data/wordbook_store.dart';

/// 「设备上现在这批」那个指针的账：推成功写、删掉那批时清、文件读不动时不炸。
class _TmpDocs extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _TmpDocs(this.dir);
  final String dir;
  @override
  Future<String> getApplicationDocumentsPath() async => dir;
}

WordEntry _word(String w) =>
    WordEntry(word: w, phonetic: '', meaning: '释义', example: '', syllable: '');

Future<WordbookStore> _storeIn(String dir) async {
  PathProviderPlatform.instance = _TmpDocs(dir);
  final store = WordbookStore();
  await store.init();
  return store;
}

Future<WordbookStore> _storeWithBooks(String dir, List<String> labels) async {
  final store = await _storeIn(dir);
  for (final label in labels) {
    await store.save(
      WeekBook(
        label: label,
        version: 'v1',
        updatedAt: DateTime.now(),
        words: [_word('cold')],
      ),
    );
  }
  return store;
}

void main() {
  test('推上去那一批存下来，重开 app 还知道设备上是谁', () async {
    final dir = (await Directory.systemTemp.createTemp('wcdev')).path;
    final store = await _storeWithBooks(dir, ['Unit 3', 'Unit 4']);
    expect(store.onDevice, '');
    expect(store.onDeviceAt, isNull);

    await store.markOnDevice('Unit 4');
    expect(store.onDevice, 'Unit 4');
    expect(store.onDeviceAt, isNotNull);

    final reopened = await _storeIn(dir);
    expect(reopened.onDevice, 'Unit 4');
    expect(reopened.onDeviceAt, isNotNull);
  });

  test('删掉的正是设备上那批 → 指针清空，不留一个不存在的名字', () async {
    final dir = (await Directory.systemTemp.createTemp('wcdev')).path;
    final store = await _storeWithBooks(dir, ['Unit 3']);
    await store.markOnDevice('Unit 3');
    await store.delete('Unit 3');

    expect(store.onDevice, '');
    expect(store.onDeviceAt, isNull);
    expect((await _storeIn(dir)).onDevice, '');
  });

  test('指针文件读不动就当不知道，别把首页弄崩', () async {
    final dir = (await Directory.systemTemp.createTemp('wcdev')).path;
    await _storeWithBooks(dir, ['Unit 3']);
    File('$dir/device_sheet.json').writeAsStringSync('{这文件坏了');

    final store = await _storeIn(dir);
    expect(store.onDevice, '');
    expect(store.onDeviceAt, isNull);
    expect(store.statusLine, isNotEmpty);
  });
}
