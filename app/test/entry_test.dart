import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordcard_app/core/protocol.dart';
import 'package:wordcard_app/data/lexicon.dart';

/// 2026-10-12 实测的 jsonapi 形状：simple.word / ec.word / expand_ec.word 都是数组，
/// 短语没有 expand_ec，sore throat 连 usphone 都没有。
Map<String, dynamic> youdao({
  String? usphone,
  String? ukphone,
  List<String> senses = const [],
  List<String> ecSentences = const [],
  List<String> expandSentences = const [],
}) => {
  'simple': {
    'word': [
      {'usphone': ?usphone, 'ukphone': ?ukphone},
    ],
  },
  'ec': {
    'word': [
      {
        'trs': [
          {
            'tr': [
              {
                'l': {
                  'i': senses,
                  'sentence': [
                    for (final s in ecSentences) {'en': s, 'zh': '中文'},
                  ],
                },
              },
            ],
          },
        ],
      },
    ],
  },
  if (expandSentences.isNotEmpty)
    'expand_ec': {
      'word': [
        {
          'transList': [
            {
              'content': {
                'sents': [
                  for (final s in expandSentences) {'sentOrig': s},
                ],
              },
            },
          ],
        },
      ],
    },
};

void main() {
  group('抠词', () {
    test('一行一词、逗号顿号、带序号、词后粘中文都能切开', () {
      expect(parseWordTokens('1. cold\n2、hot，sore throat\n3) jump rope 跳绳\n'), [
        'cold',
        'hot',
        'sore throat',
        'jump rope',
      ]);
    });

    test('短语里的空格保住，只按换行和标点切', () {
      expect(parseWordTokens('be good at\tturn down'), [
        'be good at',
        'turn down',
      ]);
    });

    test('大小写不同的重复词只留第一次出现的那个写法', () {
      expect(parseWordTokens('Cold\ncold\napple'), ['Cold', 'apple']);
    });

    test('词尾的点号去掉：a.m. 和 a.m 在设备上是同一个 slug', () {
      final rows = parseWordTokens('a.m. 上午\netc');
      expect(rows, ['a.m', 'etc']);
      expect(WordEntry(word: rows.first).slug, 'a_m');
    });

    test('纯中文行、空行抠不出东西也不崩', () {
      expect(parseWordTokens('\n第五单元\n\n'), isEmpty);
    });
  });

  group('音标清洗', () {
    test('裸音标补斜杠，已有的不动', () {
      expect(normalizePhonetic('koʊld'), '/koʊld/');
      expect(normalizePhonetic('/kəʊld/'), '/kəʊld/');
      expect(normalizePhonetic('[aɪ]'), '[aɪ]');
      expect(normalizePhonetic('   '), '');
    });

    test('西里尔 ә、ASCII 撇号和冒号换成设备字库认的码点', () {
      expect(normalizePhonetic('ә'), '/ə/');
      expect(normalizePhonetic("'ə"), '/ˈə/');
      expect(normalizePhonetic('ha:rt'), '/haːrt/');
    });
  });
  group('jsonapi 解析', () {
    test('美音优先，没有才退英音', () {
      final us = Lexicon.parse(
        'cold',
        youdao(usphone: 'koʊld', ukphone: 'kəʊld', senses: ['adj. 冷的']),
      );
      expect(us.phonetic, '/koʊld/');
      final ukOnly = Lexicon.parse(
        'be good at',
        youdao(ukphone: 'biː ɡʊd æt', senses: ['擅长于']),
      );
      expect(ukOnly.phonetic, '/biː ɡʊd æt/');
    });

    test('一个音标都没有就是空串，界面上让他自己填', () {
      final hit = Lexicon.parse('sore throat', youdao(senses: ['n. 喉咙痛']));
      expect(hit.phonetic, '');
      expect(hit.filled, isTrue);
    });

    test('释义按分号凑，最多三条且不超预算', () {
      final hit = Lexicon.parse(
        'cold',
        youdao(usphone: 'koʊld', senses: ['adj. 冷的，凉的；冷淡的，冷漠的；冷色调的；第四个义项']),
      );
      expect(hit.meaning, 'adj. 冷的，凉的；冷淡的，冷漠的；冷色调的');
    });

    test('单条义项超预算时取冒号前的头，绝不返回空', () {
      final hit = Lexicon.parse(
        'sore throat',
        youdao(senses: ['n. 喉咙痛，咽喉痛，嗓子疼：咽喉发红、疼痛不适，尤其在吞咽时加重。']),
      );
      expect(hit.meaning, 'n. 喉咙痛，咽喉痛，嗓子疼');
    });
    test('头也超预算就把整条留着，交给 overlong 标红', () {
      final long = 'n. ${'痛' * 40}';
      expect(utf8.encode(long).length, lessThan(FieldCap.meaning));
      final hit = Lexicon.parse('throat', youdao(senses: [long]));
      expect(hit.meaning, long);
      expect(hit.toEntry().overlong(), isEmpty);
    });

    test('例句去标签，expand_ec 的排在前面且保持原顺序', () {
      final hit = Lexicon.parse(
        'cold',
        youdao(
          usphone: 'koʊld',
          senses: ['adj. 冷的'],
          ecSentences: ['Lily has got a <b>cold</b>.'],
          expandSentences: [
            'It was &quot;cold&quot; outside.',
            'She had a cold.',
          ],
        ),
      );
      expect(hit.example, 'It was "cold" outside.');
    });

    test('超长的例句整条丢掉，换下一条，都不合就留空', () {
      final tooLong = 'x' * (FieldCap.example + 1);
      final hit = Lexicon.parse(
        'cold',
        youdao(
          usphone: 'koʊld',
          senses: ['adj. 冷的'],
          ecSentences: [tooLong, 'She had a cold.'],
        ),
      );
      expect(hit.example, 'She had a cold.');
      final none = Lexicon.parse(
        'cold',
        youdao(usphone: 'koʊld', ecSentences: [tooLong]),
      );
      expect(none.example, '');
    });

    test('查不到词的返回不能把解析崩掉', () {
      final hit = Lexicon.parse('zzz', <String, dynamic>{});
      expect(hit.phonetic, '');
      expect(hit.meaning, '');
      expect(hit.example, '');
      expect(hit.toEntry().word, 'zzz');
    });

    test('word 是数字键对象而不是数组时也接得住', () {
      final hit = Lexicon.parse('cold', <String, dynamic>{
        'simple': {
          'word': {
            '0': <String, dynamic>{'usphone': 'koʊld'},
            '1': <String, dynamic>{'usphone': '不该被取到'},
          },
        },
      });
      expect(hit.phonetic, '/koʊld/');
    });
  });
}
