import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:wordcard_app/core/protocol.dart';
import 'package:wordcard_app/data/wordbook_store.dart';

/// store 的落盘路径来自 path_provider，单测里给它一个临时目录。
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

void main() {
  test('没落盘过时就是内置那两个，增删改的边界都在 store 里', () async {
    final store = WordbookStore();
    expect(store.sources, kWordSources);
    expect(store.defaultSource, '课本');

    expect(await store.addSource(' 绘本 '), isNull);
    expect(store.sources, ['课本', '新东方', '绘本']);
    expect(store.defaultSource, '课本');
    expect(await store.addSource('绘本'), '已经有「绘本」了');
    expect(await store.addSource('   '), '先给这个来源起个名字');
    expect(await store.addSource('这个来源名字长得太不像话了'), isNotNull);

    expect(await store.removeSource('绘本'), isNull);
    expect(await store.removeSource('新东方'), isNull);
    expect(await store.removeSource('课本'), '至少留一个来源，录入时总得有个地方放');
    expect(store.sources, ['课本']);
  });

  test('来源列表落在 documents/sources.json，重新开一份 store 读得回来', () async {
    final dir = (await Directory.systemTemp.createTemp('wcsrc1')).path;
    final store = await _storeIn(dir);
    await store.addSource('外研社');
    expect(File('$dir/sources.json').existsSync(), isTrue);

    final again = await _storeIn(dir);
    expect(again.sources, [...kWordSources, '外研社']);
  });

  test('读出来是空列表就退回内置默认值', () async {
    final dir = (await Directory.systemTemp.createTemp('wcsrc2')).path;
    File('$dir/sources.json').writeAsStringSync('[]');
    final store = await _storeIn(dir);
    expect(store.sources, kWordSources);
  });

  test('改名带着用它的那几批一起走，删掉不动词', () async {
    final dir = (await Directory.systemTemp.createTemp('wcsrc3')).path;
    final store = await _storeIn(dir);
    await store.save(
      WeekBook(
        label: 'Unit 1',
        source: '绘本',
        version: 'v1',
        updatedAt: DateTime.now(),
        words: [_word('cat'), _word('dog')],
        audioMark: const {'cat': 'mp3:123'},
      ),
    );
    await store.addSource('绘本');

    expect(await store.renameSource('绘本', '绘本课'), isNull);
    final book = store.byLabel('Unit 1');
    expect(book!.source, '绘本课');
    // 词、发音标记、改动时间都得原样，改的只有分组。
    expect(book.words.map((w) => w.word), containsAll(['cat', 'dog']));
    expect(book.audioMark, {'cat': 'mp3:123'});
    expect(store.sources, containsAllInOrder(['课本', '新东方', '绘本课']));
    expect(store.sources, isNot(contains('绘本')));

    // 换一份 store 从盘上读，改出来的名字得在。
    final again = await _storeIn(dir);
    expect(again.byLabel('Unit 1')!.source, '绘本课');

    expect(store.usageOf('绘本课').books, 1);
    expect(await store.removeSource('绘本课'), isNull);
    // 来源删了，批次一本没动，只是顶着一个不在列表里的名字继续显示。
    final after = await _storeIn(dir);
    expect(after.sources, isNot(contains('绘本课')));
    expect(after.byLabel('Unit 1')!.source, '绘本课');
    expect(
      after.byLabel('Unit 1')!.words.map((w) => w.word),
      containsAll(['cat', 'dog']),
    );
  });
}
