import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordcard_app/core/protocol.dart';
import 'package:wordcard_app/core/word_prompt.dart';
import 'package:wordcard_app/data/wordbook_store.dart';

void main() {
  test('crc32 和设备/Python zlib 一致', () {
    expect(crc32(utf8.encode('123456789')), 0xCBF43926);
    expect(crc32(<int>[]), 0);
  });

  test('音频帧头：A5 5A 01 | flags | offset u32 LE | len u16 LE', () {
    final frame = buildAudioFrame(
      offset: 0x01020304,
      payload: <int>[1, 2, 3],
      first: true,
      last: false,
    );
    expect(frame.length, kFrameHeaderLen + 3);
    expect(frame.sublist(0, 4), <int>[0xA5, 0x5A, 0x01, 1]);
    expect(ByteData.sublistView(frame).getUint32(4, Endian.little), 0x01020304);
    expect(ByteData.sublistView(frame).getUint16(8, Endian.little), 3);
    expect(frame.sublist(kFrameHeaderLen), <int>[1, 2, 3]);
    expect(
      buildAudioFrame(offset: 0, payload: <int>[9], first: true, last: true)[3],
      3,
    );
  });

  test('容器靠魔数判，不信 Content-Type', () {
    expect(detectAudioFormat(utf8.encode('RIFF....WAVE')), 'wav');
    expect(detectAudioFormat(<int>[0x49, 0x44, 0x33, 0x04]), 'mp3');
    expect(detectAudioFormat(<int>[0xFF, 0xFB, 0x90, 0x00]), 'mp3');
    expect(detectAudioFormat(<int>[0, 1, 2, 3]), isNull);
  });

  test('TSV：# 行和空行跳过，缺字段补空', () {
    final rows = parseTsv('# 注释\n\ncold\tkəʊld\t感冒\t\njump rope\n');
    expect(rows.length, 2);
    expect(rows[0].example, '');
    expect(rows[1].word, 'jump rope');
    expect(rows[1].phonetic, '');
    expect(rows[1].meaning, '');
  });

  test('slug 和设备侧文件名规则一致', () {
    expect(WordEntry(word: 'be good at').slug, 'be_good_at');
    expect(WordEntry(word: "it's").slug, 'it_s');
  });

  test('字段超过设备缓冲区要能查出来', () {
    final short = WordEntry(word: 'cold', example: 'Lily has got a cold.');
    expect(short.overlong(), isEmpty);
    final long = WordEntry(word: 'cold', example: 'x' * FieldCap.example + 'y');
    expect(long.overlong(), [
      '例句 ${FieldCap.example + 1}B>${FieldCap.example}B',
    ]);
  });

  test('音节拆分搭音标段送出去，设备按第一个 | 切', () {
    final e = WordEntry(
      word: 'umbrella',
      phonetic: '/ʌmˈbrelə/',
      syllable: 'um·bre·lla',
    );
    expect(e.wirePhonetic, '/ʌmˈbrelə/|um·bre·lla');
    expect(WordEntry.unpackPhonetic(e.wirePhonetic), (
      '/ʌmˈbrelə/',
      'um·bre·lla',
    ));
    // 没填音节的词，音标段一个字都不该变，老词表和 ble_push.py 都照旧。
    expect(
      WordEntry(word: 'cold', phonetic: '/kəʊld/').wirePhonetic,
      '/kəʊld/',
    );
    expect(WordEntry.unpackPhonetic('/kəʊld/'), ('/kəʊld/', ''));
  });

  test('音节算进音标那 95 字节，超了要在推送前拦住', () {
    final pad = 'a' * (FieldCap.phonetic - 5);
    final fits = WordEntry(word: 'cold', phonetic: pad, syllable: 'cold');
    expect(fits.overlong(), isEmpty);
    final over = WordEntry(word: 'cold', phonetic: pad, syllable: 'cold-x');
    expect(over.overlong(), [
      '音标+音节 ${FieldCap.phonetic + 2}B>${FieldCap.phonetic}B',
    ]);
  });

  test('周表 JSON 和 TSV 都要能把音节带回来', () {
    final e = WordEntry(
      word: 'umbrella',
      phonetic: '/ʌmˈbrelə/',
      syllable: 'um·bre·lla',
    );
    final back = WordEntry.fromJson(
      jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>,
    );
    expect(back.syllable, 'um·bre·lla');
    expect(back.phonetic, '/ʌmˈbrelə/');
    // 没单独存 'y'、而是从设备上倒回来的打包写法
    final packed = WordEntry.fromJson({
      'w': 'umbrella',
      'p': '/ʌmˈbrelə/|um·bre·lla',
      'm': '',
      's': '',
    });
    expect([packed.phonetic, packed.syllable], ['/ʌmˈbrelə/', 'um·bre·lla']);
    // 四列是设备格式，第五列是 app 自己导词表用的
    expect(
      WordEntry.fromTsvLine('umbrella\t/ʌmˈbrelə/\tn.伞\t\tum-bre-lla').syllable,
      'um-bre-lla',
    );
    expect(
      parseTsv('umbrella\t/ʌmˈbrelə/|um·bre·lla\tn.伞\n').single.syllable,
      'um·bre·lla',
    );
    expect(e.toTsvLine(), 'umbrella\t/ʌmˈbrelə/|um·bre·lla\t\t');
  });

  test('手填音节：手机上敲得出什么分隔符都收', () {
    expect(normalizeSyllable(' um - bre - lla '), 'um·bre·lla');
    expect(normalizeSyllable('um..bre..lla'), 'um·bre·lla');
    expect(normalizeSyllable('um|bre|lla'), 'um·bre·lla');
    expect(normalizeSyllable('cold'), 'cold');
    expect(normalizeSyllable('  '), '');
    // 词组里的空格是词界，不能当成音节界
    expect(normalizeSyllable('jump rope'), 'jump rope');
  });

  test('粘进来的行里有中文就以它为准，不查有道', () {
    // 提示词让 AI 吐的就是这个格式，原样粘进来
    final rows = parsePastedRows(
      'umbrella|/ʌmˈbrelə/|n. 雨伞|I take an umbrella when it rains.|um-brel-la\n'
      'cold|/kəʊld/|adj. 寒冷的|It is cold outside today.|cold\n',
    );
    expect(rows.length, 2);
    expect(rows.every((r) => !r.needsLookup), isTrue);
    expect(rows[0].entry.syllable, 'um·brel·la');
    expect(rows[0].entry.wirePhonetic, '/ʌmˈbrelə/|um·brel·la');
    expect(rows[0].entry.example, 'I take an umbrella when it rains.');
    expect(rows[1].entry.syllable, 'cold');
  });

  test('提示词里的示例行必须能被录入页原样吃下', () {
    // 提示词和解析器是一根绳上的，改一边就得把另一边也改 —— 这段拿提示词自带的
    // 示例当输入，格式一跑偏测试直接红。
    final sample = kAiWordPrompt
        .split('\n')
        .where((l) => l.contains('|') && !l.startsWith('单词|'))
        .join('\n');
    final rows = parsePastedRows(sample);
    expect(rows.length, 2);
    expect(rows.every((r) => !r.needsLookup), isTrue);
    expect(rows.map((r) => r.entry.syllable).toList(), ['um·brel·la', 'cold']);
    expect(rows.map((r) => r.entry.overlong()).toList(), [isEmpty, isEmpty]);
  });

  test('纯单词才去查表；没中文的释义、缺的字段都算没填好', () {
    final rows = parsePastedRows('cold, warm\numbrella||gloss in english||\n');
    expect(rows.length, 3);
    expect(rows.every((r) => r.needsLookup), isTrue);
    expect(rows[0].entry.word, 'cold');
    expect(rows[2].entry.phonetic, '');
    expect(rows[2].entry.meaning, 'gloss in english');
  });

  test('课本那种「单词 音标 中文」直接粘，也能救回来且不联网', () {
    final rows = parsePastedRows('cold /kəʊld/ 感冒\n2. umbrella 雨伞\n');
    expect(rows.length, 2);
    expect(rows.every((r) => !r.needsLookup), isTrue);
    expect(
      [rows[0].entry.word, rows[0].entry.phonetic, rows[0].entry.meaning],
      ['cold', '/kəʊld/', '感冒'],
    );
    expect([rows[1].entry.word, rows[1].entry.meaning], ['umbrella', '雨伞']);
  });

  test('同一个词只留第一条，先到的那份算数', () {
    final rows = parsePastedRows('cold|/kəʊld/|n. 感冒|It is cold.|cold\ncold\n');
    expect(rows.length, 1);
    expect(rows.single.needsLookup, isFalse);
    expect(rows.single.entry.meaning, 'n. 感冒');
  });

  test('ISO 周号：跨年那几周要落到正确的年份', () {
    expect(WeekBook.weekLabel(DateTime(2026, 10, 12)), '2026W42');
    expect(WeekBook.weekLabel(DateTime(2026, 1, 1)), '2026W01');
    expect(WeekBook.weekLabel(DateTime(2026, 12, 31)), '2026W53');
    expect(WeekBook.weekLabel(DateTime(2021, 1, 1)), '2020W53');
    expect(WeekBook.weekLabel(DateTime(2021, 1, 4)), '2021W01');
  });

  test('发音指纹要能存进周表再读出来', () {
    final book = WeekBook(
      label: '2026W42',
      version: '20261012-120000',
      updatedAt: DateTime(2026, 10, 12, 12),
      words: const [WordEntry(word: 'cold')],
    );
    expect(book.audioMark, isEmpty);
    book.audioMark['cold'] = WeekBook.markOf('mp3', 0xCBF43926);

    final json = book.toJson();
    final back = WeekBook.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
    );
    expect(back.audioMark['cold'], 'mp3:3421780262');

    // 已经存在的周表文件里没有这一项，要当成"什么都没推过"而不是崩掉。
    json.remove('audioMark');
    final legacy = WeekBook.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
    );
    expect(legacy.audioMark, isEmpty);
  });

  test('来源存得回去；加这列之前存的老文件算课本', () {
    final book = WeekBook(
      label: '10-11 那节课',
      source: '新东方',
      version: '20261012-120000',
      updatedAt: DateTime(2026, 10, 12, 12),
      words: const [WordEntry(word: 'cold')],
    );
    expect(book.title, '新东方 10-11 那节课（1 词）');

    final json = book.toJson();
    final back = WeekBook.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
    );
    expect(back.source, '新东方');

    json.remove('source');
    final legacy = WeekBook.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
    );
    expect(legacy.source, kDefaultSource);
  });

  test('批次名进文件名，洗掉不能进路径的字符', () {
    expect(WordbookStore.fileSafe('Unit 3'), 'Unit_3');
    expect(WordbookStore.fileSafe(r'10/11:那节课'), '10_11_那节课');
    expect(WordbookStore.fileSafe('   '), '未命名');
  });
}
