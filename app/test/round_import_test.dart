import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordcard_app/core/protocol.dart';
import 'package:wordcard_app/data/device_link.dart';
import 'package:wordcard_app/data/round_sync.dart';
import 'package:wordcard_app/data/schedule.dart';
import 'package:wordcard_app/data/sync_runner.dart';
import 'package:wordcard_app/data/wordbook_store.dart';
import 'package:wordcard_app/data/youdao.dart';

final DateTime d10 = DateTime(2026, 10, 12);

List<PoolItem> poolOf(List<String> words) => ScheduleStore.poolOf([
  WeekBook(
    label: '2026W42',
    version: '20261012-000000',
    updatedAt: d10,
    words: [for (final w in words) WordEntry(word: w, meaning: w)],
  ),
]);

/// 按设备那套切片规则发一轮：每片带总数、错数、片号和最后一片标记。
List<Map<String, dynamic>> slicesFor(
  int uid,
  List<(String, bool)> rows, {
  int perSlice = 2,
  int? skipPart,
  int? wrongTotal,
  int? wrongForgotten,
}) {
  final out = <Map<String, dynamic>>[];
  final forgotten = rows.where((r) => r.$2).length;
  for (var from = 0; from < rows.length; from += perSlice) {
    final part = from ~/ perSlice;
    if (skipPart == part) continue;
    final chunk = rows.skip(from).take(perSlice).toList();
    out.add({
      't': 'result_rows',
      'u': uid,
      'n': wrongTotal ?? rows.length,
      'f': wrongForgotten ?? forgotten,
      'd': 0,
      'i': part,
      'L': (from + perSlice >= rows.length) ? 1 : 0,
      'r': [
        for (final r in chunk) [r.$1, r.$2 ? 1 : 0],
      ],
    });
  }
  return out;
}

/// 假链路：脚本喂 stat 和 result_rows，记下发出的命令和 ack 过的轮号。
class ScriptLink extends BleLink {
  ScriptLink({List<Map<String, dynamic>>? stats, this.slices = const []})
    : stats = stats ?? const [];

  final List<Map<String, dynamic>> stats;
  final List<Map<String, dynamic>> slices;

  final List<String> commands = [];
  final List<int> acked = [];
  int drained = 0;
  int _statAt = 0;
  int _sliceAt = 0;

  @override
  Future<void> writeCommand(Map<String, dynamic> command) async {
    final t = '${command['t']}';
    commands.add(t);
    if (t == 'result_ack') acked.add((command['u'] as num).toInt());
  }

  @override
  void drain() {
    drained += 1;
  }

  @override
  Future<Map<String, dynamic>> waitFor(String type, Duration timeout) async {
    switch (type) {
      case 'stat':
        if (_statAt >= stats.length) {
          throw LinkException('没备第 ${_statAt + 1} 次 stat 的返回值');
        }
        return stats[_statAt++];
      case 'result_rows':
        if (_sliceAt >= slices.length) throw LinkException('result_rows 发完了');
        return slices[_sliceAt++];
      case 'result_ack_ok':
        return {'t': 'result_ack_ok', 'left': 0};
      case 'wb_begin_ok':
      case 'wb_done':
        return {'t': type, 'n': 1};
    }
    throw LinkException('假链路不会回 $type');
  }
}

class FakeYoudao extends Youdao {
  FakeYoudao() : super(Directory.systemTemp);
}

void main() {
  test('一轮结果直接进档：想不起来回炉，记住的进档，池外的词只数不给档', () async {
    final store = ScheduleStore();
    final pool = poolOf(['cold', 'hot', 'felt']);
    final link = ScriptLink(
      stats: [
        {'pending_rounds': 1, 'oldest_round': 11},
        {'pending_rounds': 0},
      ],
      slices: slicesFor(11, [
        ('cold', true),
        ('hot', false),
        ('felt', false),
        ('ghost', false),
      ]),
    );

    final got = await importDeviceRounds(
      link: link,
      store: store,
      pool: pool,
      today: d10,
    );

    expect(got.problem, isNull);
    expect(got.rounds, 1);
    expect(got.credited, 3);
    expect(got.orphan, 1);
    expect(link.acked, [11]);
    expect(link.commands, ['stat', 'result_get', 'result_ack', 'stat']);

    final cold = store.recordOf('cold')!;
    expect(cold.box, 0);
    expect(cold.lapses, 1);
    expect(cold.dueDay, d10.add(const Duration(days: 1)));
    expect(store.recordOf('hot')!.box, 1);
    expect(store.recordOf('ghost'), isNull);
    expect(store.statFor(d10).forgotten, {'cold'});
    expect(store.statFor(d10).marked, {'hot', 'felt'});
  });

  test('同一轮取回第二次只补 ack，不再进第二次档', () async {
    final store = ScheduleStore();
    final pool = poolOf(['cold', 'hot']);
    final first = ScriptLink(
      stats: [
        {'pending_rounds': 1, 'oldest_round': 21},
        {'pending_rounds': 0},
      ],
      slices: slicesFor(21, [('cold', false), ('hot', false)]),
    );
    await importDeviceRounds(link: first, store: store, pool: pool, today: d10);
    expect(store.recordOf('cold')!.box, 1);

    // ack 没送达就断开重连：设备还留着那一轮，再取一次。
    final again = ScriptLink(
      stats: [
        {'pending_rounds': 1, 'oldest_round': 21},
        {'pending_rounds': 0},
      ],
      slices: slicesFor(21, [('cold', false), ('hot', false)]),
    );
    final got = await importDeviceRounds(
      link: again,
      store: store,
      pool: pool,
      today: d10.add(const Duration(days: 1)),
    );

    expect(got.credited, 0);
    expect(got.repeated, 0);
    expect(store.recordOf('cold')!.box, 1);
    expect(store.recordOf('cold')!.dueDay, d10.add(const Duration(days: 1)));
    // 补完 ack 设备才清得掉，这一句不能省。
    expect(again.acked, [21]);
  });

  test('缺一片就整轮不 ack：半轮的账比不记更糟', () async {
    final store = ScheduleStore();
    final pool = poolOf(['cold', 'hot', 'felt', 'throat', 'side', 'wide']);
    final link = ScriptLink(
      stats: [
        {'pending_rounds': 1, 'oldest_round': 31},
      ],
      // 三片里中间那片没发出来：第 0 片之后直接来第 2 片。
      slices: slicesFor(31, [
        ('cold', false),
        ('hot', false),
        ('felt', false),
        ('throat', false),
        ('side', false),
        ('wide', false),
      ], perSlice: 2, skipPart: 1),
    );

    final got = await importDeviceRounds(link: link, store: store, pool: pool, today: d10);

    expect(got.rounds, 0);
    expect(got.problem, contains('第 1 片'));
    expect(link.acked, isEmpty);
    expect(link.drained, 1);
    expect(store.recordOf('cold'), isNull);
    expect(store.archivedCount, 0);
  });

  test('行数和设备说的对不上也不 ack', () async {
    final store = ScheduleStore();
    final pool = poolOf(['cold', 'hot', 'felt']);
    final link = ScriptLink(
      stats: [
        {'pending_rounds': 1, 'oldest_round': 41},
      ],
      slices: slicesFor(41, [
        ('cold', false),
        ('hot', false),
        ('felt', true),
      ], wrongTotal: 9),
    );

    final got = await importDeviceRounds(link: link, store: store, pool: pool, today: d10);

    expect(got.problem, contains('3 行，设备说 9 行'));
    expect(link.acked, isEmpty);
    expect(store.recordOf('cold'), isNull);
  });

  test('错数对不上也不入账，宁可留着下次重取', () async {
    final store = ScheduleStore();
    final pool = poolOf(['cold', 'hot']);
    final link = ScriptLink(
      stats: [
        {'pending_rounds': 1, 'oldest_round': 51},
      ],
      slices: slicesFor(51, [('cold', true), ('hot', false)], wrongForgotten: 0),
    );

    final got = await importDeviceRounds(link: link, store: store, pool: pool, today: d10);

    expect(got.problem, contains('想不起来」对不上'));
    expect(link.acked, isEmpty);
    expect(store.recordOf('cold'), isNull);
  });

  test('老固件没报 pending_rounds，就当没有结果，不发 result_get', () async {
    final store = ScheduleStore();
    final link = ScriptLink(stats: [
      {'stored_words': 12, 'audio_ok': 12},
    ]);

    final got = await importDeviceRounds(
      link: link,
      store: store,
      pool: poolOf(['cold']),
      today: d10,
    );

    expect(got.line, '设备上没有待回传的练习结果');
    expect(link.commands, ['stat']);
  });

  test('攒了几轮就一轮一轮取，每轮各 ack 一次', () async {
    final store = ScheduleStore();
    final pool = poolOf(['cold', 'hot', 'felt', 'throat']);
    final link = ScriptLink(
      stats: [
        {'pending_rounds': 2, 'oldest_round': 61},
        {'pending_rounds': 1, 'oldest_round': 62},
        {'pending_rounds': 0},
      ],
      slices: [
        ...slicesFor(61, [('cold', true), ('hot', false)]),
        ...slicesFor(62, [('felt', false), ('throat', false)]),
      ],
    );

    final got = await importDeviceRounds(link: link, store: store, pool: pool, today: d10);

    expect(got.rounds, 2);
    expect(got.credited, 4);
    expect(link.acked, [61, 62]);
    // 第一轮想过一遍、第二轮又练一次：同一个词一天只进一档（[report] 的老口径）。
    expect(store.recordOf('cold')!.lapses, 1);
  });

  test('推送先收结果再换词表，收不成也不挡住推送', () async {
    final store = ScheduleStore();
    final pool = poolOf(['cold', 'hot']);
    final link = ScriptLink(
      stats: [
        {'pending_rounds': 1, 'oldest_round': 71},
        {'pending_rounds': 0},
        {},
      ],
      slices: slicesFor(71, [('cold', false), ('hot', false)]),
    );
    final runner = SyncRunner(link, FakeYoudao());

    await runner.push(
      WeekBook(
        label: '今日 10-12',
        version: '20261012-000001',
        updatedAt: d10,
        words: [for (final p in pool) p.entry],
      ),
      withAudio: false,
      collect: () => importDeviceRounds(
        link: link,
        store: store,
        pool: pool,
        today: d10,
      ),
    );

    // stat / result_get / result_ack / stat（问一次还有没有）都排在换词表之前。
    expect(link.commands.take(5), [
      'stat',
      'result_get',
      'result_ack',
      'stat',
      'wb_begin',
    ]);
    expect(store.recordOf('cold')!.box, 1);
  });
}
