import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordcard_app/core/protocol.dart';
import 'package:wordcard_app/data/schedule.dart';
import 'package:wordcard_app/data/wordbook_store.dart';

final DateTime d10 = DateTime(2026, 10, 12);
final DateTime d9 = DateTime(2026, 10, 11);

WeekBook book(
  String label,
  List<String> words, {
  String source = kDefaultSource,
  DateTime? updatedAt,
}) => WeekBook(
  label: label,
  source: source,
  version: '20261012-000000',
  updatedAt: updatedAt ?? d10,
  words: [for (final w in words) WordEntry(word: w, meaning: w)],
);

List<PlanWord> pw(List<PoolItem> items) => [
  for (final p in items) PlanWord(p.entry, label: p.label, isNew: true),
];

void main() {
  test('新词一天只引入 newPerDay 个，剩下的排队', () async {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([
      book('2026W42', [
        'cold',
        'hot',
        'felt',
        'throat',
        'jump rope',
        'side',
        'wide',
        'bear',
      ]),
    ]);
    final plan = store.planFor(d10.add(const Duration(hours: 21)), pool);
    expect(plan.day, d10);
    expect(plan.fresh.length, 6);
    expect(plan.review, isEmpty);
    expect(plan.intakeLabel, '2026W42');
    expect(plan.intakeLeft, 2);
    expect(plan.otherLeft, 0);

    await store.introduce(plan.words, d10);
    expect(store.trackedIn(pool), 6);
    // 学完当天不复习，明天才第一次到期。
    expect(store.recordOf('cold')!.dueDay, d10.add(const Duration(days: 1)));
  });

  test('第二天的表 = 昨天那批复习 + 补新的', () async {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([
      book('2026W42', [
        'cold',
        'hot',
        'felt',
        'throat',
        'jump rope',
        'side',
        'wide',
        'bear',
      ]),
    ]);
    await store.introduce(store.planFor(d10, pool).words, d10);
    final next = store.planFor(d10.add(const Duration(days: 1)), pool);
    expect(next.review.length, 6);
    expect(next.fresh.length, 2);
    expect(next.words.length, 8);
  });

  test('记住就按 1/2/4/7/15/30 往后推，走完六档毕业', () async {
    final store = ScheduleStore();
    final cold = PlanWord(
      WordEntry(word: 'cold'),
      label: '2026W42',
      isNew: true,
    );
    await store.introduce([cold], d10);

    var day = d10;
    for (var i = 0; i < kGapDays.length; i++) {
      day = day.add(Duration(days: kGapDays[i]));
      await store.report('cold', '2026W42', day, remembered: true);
      expect(store.recordOf('cold')!.box, i + 1);
    }
    expect(store.recordOf('cold')!.mastered, isTrue);
    expect(store.masteredIn([PoolItem(cold.entry, '2026W42')]), 1);
    // 毕业的词不再出现在任何一天的计划里，设备上也就不会再有它。
    final far = store.planFor(day.add(const Duration(days: 365)), [
      PoolItem(WordEntry(word: 'cold'), '2026W42'),
    ]);
    expect(far.words, isEmpty);
  });

  test('没想起来退回第一档、明天再见、记一次流失', () async {
    final store = ScheduleStore();
    await store.introduce([
      PlanWord(WordEntry(word: 'felt'), label: 'W42', isNew: true),
    ], d10);
    await store.report(
      'felt',
      'W42',
      d10.add(const Duration(days: 1)),
      remembered: true,
    );
    await store.report(
      'felt',
      'W42',
      d10.add(const Duration(days: 3)),
      remembered: true,
    );
    expect(store.recordOf('felt')!.box, 2);

    final day = d10.add(const Duration(days: 7));
    await store.report('felt', 'W42', day, remembered: false);
    final r = store.recordOf('felt')!;
    expect(r.box, 0);
    expect(r.lapses, 1);
    expect(r.dueDay, day.add(const Duration(days: 1)));
  });

  test('逾期不会消失，逾期最久的排最前', () async {
    final store = ScheduleStore();
    final pool = [
      for (final w in ['cold', 'hot', 'felt'])
        PoolItem(WordEntry(word: w), 'W42'),
    ];
    // 三个词分别在不同日子开始学，到今天 cold 已经拖了 4 天、hot 拖了 2 天、felt 正好今天。
    await store.introduce(pw([pool[0]]), DateTime(2026, 10, 8));
    await store.introduce(pw([pool[1]]), DateTime(2026, 10, 10));
    await store.introduce(pw([pool[2]]), DateTime(2026, 10, 12));
    final day = DateTime(2026, 10, 13);

    final plan = store.planFor(day, pool);
    expect(plan.review.length, 3);
    expect([for (final p in plan.review) p.word], ['cold', 'hot', 'felt']);
    expect(plan.overdueCount, 2);
    expect(plan.review.first.record!.overdue(plan.day), 4);
    expect(plan.review.last.record!.overdue(plan.day), 0);
  });

  test('周表被删掉的词不占今天的名额，但档案留着', () async {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([
      book('2026W42', ['cold', 'hot']),
    ]);
    await store.introduce(store.planFor(d10, pool).words, d10);
    expect(store.trackedIn(pool), 2);

    final empty = store.planFor(d10.add(const Duration(days: 1)), const []);
    expect(empty.review, isEmpty);
    expect(empty.fresh, isEmpty);
    // 档案一条都没少，可词池空了就不该再出现在任何汇总数字里。
    expect(store.archivedCount, 2);
    expect(store.trackedIn(const []), 0);
    expect(store.struggling(5, const []), isEmpty);
    expect(
      store.boxHistogram(const []).values.fold<int>(0, (a, b) => a + b),
      0,
    );
  });

  test('覆盖重录改了拼法：档案跟着搬到新拼法，不从第一档重来', () async {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([
      book('2026W42', ['recieve', 'hot']),
    ]);
    await store.introduce(store.planFor(d10, pool).words, d10);
    await store.report(
      'recieve',
      '2026W42',
      d10.add(const Duration(days: 1)),
      remembered: true,
    );
    await store.report(
      'recieve',
      '2026W42',
      d10.add(const Duration(days: 2)),
      remembered: true,
    );

    final moved = await store.rehomeOrphans(['recieve'], ['receive', 'hot']);
    expect(moved, ['recieve → receive']);
    expect(store.recordOf('receive')!.box, 2);
    expect(store.recordOf('recieve'), isNull);
    // 归属还是原来那一批，档位和到期日子原样带过去。
    expect(store.recordOf('receive')!.label, '2026W42');
    expect(store.archivedCount, 2);
  });

  test('搬完档案，新拼法当天不能再进一次档', () async {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([book('2026W42', ['recieve'])]);
    await store.introduce(store.planFor(d10, pool).words, d10);
    final d11 = d10.add(const Duration(days: 1));
    await store.report('recieve', '2026W42', d11, remembered: true);

    await store.rehomeOrphans(['recieve'], ['receive']);
    await store.report('receive', '2026W42', d11, remembered: true);
    expect(store.recordOf('receive')!.box, 1);
  });

  test('认不出的不搬：两个拼法都接得上、或者短到两三个字母', () async {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([book('2026W42', ['cold', 'an'])]);
    await store.introduce(store.planFor(d10, pool).words, d10);
    // cold 既像 cord 又像 bold，猜不动；an→and 差一个字母，那是另一个词不是拼错。
    final moved = await store.rehomeOrphans(
      ['cold', 'an'],
      ['cord', 'bold', 'and'],
    );
    expect(moved, isEmpty);
    expect(store.recordOf('cold')!.box, 0);
    expect(store.archivedCount, 2);
  });

  test('poolOf：最新一周先学，重复词只留一次并归到最新那本', () {
    final pool = ScheduleStore.poolOf([
      book('2026W42', ['cold', 'hot']),
      book('2026W41', ['cold', 'bear']),
    ]);
    expect([for (final p in pool) p.entry.word], ['cold', 'hot', 'bear']);
    expect(pool.first.label, '2026W42');
  });

  test('新词只从当前词库那一批抽，别批的一个都不动', () async {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([
      book('Unit 3', [
        'cold',
        'hot',
        'felt',
        'throat',
        'jump rope',
        'side',
        'wide',
        'bear',
      ]),
      book('10-11 那节课', ['planet', 'ocean']),
    ]);
    final plan = store.planFor(d10, pool, intake: 'Unit 3');
    expect(plan.fresh.length, 6);
    expect(plan.fresh.every((p) => p.label == 'Unit 3'), isTrue);
    expect(plan.intakeLeft, 2);
    expect(plan.otherLeft, 2);
  });

  test('当前词库见底就停着，不自动去抽下一批', () async {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([
      book('Unit 4', ['planet', 'ocean']),
      book('Unit 3', ['cold', 'hot']),
    ]);
    await store.setNewPerDay(4);
    await store.introduce(
      store.planFor(d10, pool, intake: 'Unit 4').words,
      d10,
    );

    final dry = store.planFor(
      d10.add(const Duration(days: 1)),
      pool,
      intake: 'Unit 4',
    );
    expect(dry.fresh, isEmpty);
    expect(dry.intakeLeft, 0);
    expect(dry.otherLeft, 2);
    // 复习照旧：到期那两个字还是从 Unit 4 来，切批次只管新词。
    expect(dry.review.length, 2);

    // 切成 Unit 3 才开始上新词 —— 这一下得人来按。
    final switched = store.planFor(
      d10.add(const Duration(days: 1)),
      pool,
      intake: 'Unit 3',
    );
    expect([for (final p in switched.fresh) p.word], ['cold', 'hot']);
    expect(switched.intakeLeft, 0);
  });

  test('当前词库那批被删了，退到词池第一批而不是整张计划空掉', () {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([
      book('Unit 4', ['planet', 'ocean']),
      book('Unit 3', ['cold']),
    ]);
    final plan = store.planFor(d10, pool, intake: 'Unit 9');
    expect(plan.intakeLabel, 'Unit 4');
    expect(plan.fresh.length, 2);
  });

  test('每批的分数按词池口径算，重复词只算在最靠前那批头上', () async {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([
      book('Unit 4', ['planet', 'ocean']),
      book('Unit 3', ['cold', 'planet']),
    ]);
    await store.introduce(
      store.planFor(d10, pool, intake: 'Unit 4').words,
      d10,
    );

    final tally = store.batchProgress(pool);
    expect([tally['Unit 4']!.learned, tally['Unit 4']!.total], [2, 2]);
    // planet 归 Unit 4（它排在前面），所以 Unit 3 在词池里只剩 cold 一个词。
    expect([tally['Unit 3']!.learned, tally['Unit 3']!.total], [0, 1]);
  });

  test('每天新词额度能调，且不会调到零或负数', () async {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([
      book('2026W42', ['a', 'b', 'c', 'd']),
    ]);
    await store.setNewPerDay(2);
    expect(store.planFor(d10, pool).fresh.length, 2);
    await store.setNewPerDay(-5);
    expect(store.newPerDay, 1);
  });

  test('记忆档案序列化得回去', () {
    final r = MemoryRecord(
      word: 'jump rope',
      label: '2026W42',
      learnedDay: d10,
      dueDay: d10.add(const Duration(days: 4)),
      box: 3,
      lastReview: d10.add(const Duration(days: 1)),
      lapses: 2,
    );
    final back = MemoryRecord.fromJson(
      jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
    );
    expect(back.word, 'jump rope');
    expect(back.label, '2026W42');
    expect(back.box, 3);
    expect(back.learnedDay, d10);
    expect(back.dueDay, d10.add(const Duration(days: 4)));
    expect(back.lastReview, d10.add(const Duration(days: 1)));
    expect(back.lapses, 2);
    expect(back.mastered, isFalse);
  });
  test('MarkRouter 把发音标记写回拥有这个词的那本周表', () async {
    final w42 = book('2026W42', ['cold', 'hot']);
    final w41 = book('2026W41', ['bear', 'cold']);
    final weeks = [w42, w41];
    final saved = <String>[];
    final router = MarkRouter(
      weeks: () => weeks,
      save: (b) async {
        saved.add(b.label);
      },
    );
    w42.audioMark['cold'] = WeekBook.markOf('mp3', 11);
    router.reindex();
    // 同一 slug 在两本里都有时，排在前面那本（最近改动的）说了算。
    expect(router.merged['cold'], 'mp3:11');

    final sheet = WeekBook(
      label: '今日',
      version: 'v',
      updatedAt: d10,
      words: [
        WordEntry(word: 'cold'),
        WordEntry(word: 'bear'),
      ],
      audioMark: Map.of(router.merged),
    );
    sheet.audioMark['cold'] = WeekBook.markOf('mp3', 22);
    sheet.audioMark['bear'] = WeekBook.markOf('mp3', 33);
    await router.writeBack(sheet);

    expect(w42.audioMark['cold'], 'mp3:22');
    expect(w41.audioMark['bear'], 'mp3:33');
    expect(saved, ['2026W42', '2026W41']);

    // 标记没再变就不该重复写盘。
    await router.writeBack(sheet);
    expect(saved.length, 2);
  });

  test('仪表盘的账本：重推不重复计，改主意不双记', () async {
    final store = ScheduleStore();
    await store.recordPush(['cold', 'Cold', 'jump rope'], d10);
    expect(store.statFor(d10).pushed.length, 2);
    await store.recordPush(['cold'], d10.add(const Duration(hours: 5)));
    expect(store.statFor(d10).pushed.length, 2);

    await store.introduce([
      PlanWord(WordEntry(word: 'cold'), label: 'W42', isNew: true),
    ], d10);
    await store.report('cold', 'W42', d10, remembered: true);
    final stat = store.statFor(d10);
    expect(
      [stat.marked.length, stat.forgotten.length, stat.touched],
      [1, 0, 1],
    );
    // 手滑点错了改回来：这一天只算一笔。
    await store.report('cold', 'W42', d10, remembered: false);
    expect(
      [stat.marked.length, stat.forgotten.length, stat.touched],
      [0, 1, 1],
    );
  });

  test('两周柱状图补空格子，档位直方图把毕业单独算一列', () async {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([
      book('2026W42', ['cold', 'hot', 'felt']),
    ]);
    await store.introduce(store.planFor(d10, pool).words, d10);
    await store.report(
      'cold',
      '2026W42',
      d10.add(const Duration(days: 1)),
      remembered: true,
    );
    await store.report(
      'hot',
      '2026W42',
      d10.add(const Duration(days: 1)),
      remembered: false,
    );
    await store.report(
      'felt',
      '2026W42',
      d10.add(const Duration(days: 1)),
      remembered: false,
    );

    final days = store.recentDays(14, d10.add(const Duration(days: 1)));
    expect(days.length, 14);
    expect(days.first.touched, 0);
    expect(days.first.pushed, isEmpty);
    expect(days.last.touched, 3);

    final hist = store.boxHistogram(pool);
    expect(hist.length, kGapDays.length + 1);
    // 毕业占独立一列；忘了两次的词退回第 1 档，而不是从档案里抹掉。
    expect(hist[0], 2);
    expect(hist[1], 1);
    expect(hist.values.fold<int>(0, (a, b) => a + b), 3);
    expect([for (final r in store.struggling(5, pool)) r.word], ['felt', 'hot']);
  });

  test('推完今天这张表不缩水：新词当天还在名单里', () async {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([book('2026W42', ['cold', 'hot'])]);
    final plan = store.planFor(d10, pool);
    final sheet = store.sheetOf(pool, plan, store.statFor(d10));
    // 没推过时就是排期预览，一个不多一个不少。
    expect([for (final w in sheet) w.word], ['cold', 'hot']);

    await store.introduce(plan.words, d10);
    await store.recordPush([for (final w in plan.words) w.word], d10);
    final after = store.planFor(d10, pool);
    // 排期自己认为今天没东西了（新词一建档就退出待学）—— 这正是卡片以前缩成 0 的原因。
    expect(after.words, isEmpty);
    final pushed = store.sheetOf(pool, after, store.statFor(d10));
    expect([for (final w in pushed) w.word], ['cold', 'hot']);
    // 当天上的还是新词：不带打勾，明天才第一次到期。
    expect(pushed.every((w) => w.isNew), isTrue);
    expect(pushed.first.record!.dueDay, d10.add(const Duration(days: 1)));
  });

  test('打过勾的词今天不会从表上消失，也没法重复进档', () async {
    final store = ScheduleStore();
    final pool = ScheduleStore.poolOf([book('2026W42', ['cold', 'hot'])]);
    await store.introduce(store.planFor(d9, pool).words, d9);
    await store.recordPush(['cold', 'hot'], d9);

    final plan = store.planFor(d10, pool);
    expect(plan.review.length, 2);
    await store.recordPush(['cold', 'hot'], d10);
    await store.report('cold', '2026W42', d10, remembered: true);

    // cold 到期日子被推走了，但它是今天推上设备的词，所以还在这张表里。
    final after = store.planFor(d10, pool);
    expect([for (final w in after.review) w.word], ['hot']);
    final sheet = store.sheetOf(pool, after, store.statFor(d10));
    expect([for (final w in sheet) w.word], ['hot', 'cold']);
    expect(sheet.last.isNew, isFalse);

    // 那一行不会打完勾就消失，所以手滑点第二次是真的会发生。
    await store.report('cold', '2026W42', d10, remembered: true);
    expect(store.recordOf('cold')!.box, 1);
    expect(store.recordOf('cold')!.dueDay, d10.add(const Duration(days: 1)));
    expect(store.statFor(d10).touched, 1);
    // 换结论仍然算：先记住又改成忘了。
    await store.report('cold', '2026W42', d10, remembered: false);
    expect(
      [store.recordOf('cold')!.box, store.recordOf('cold')!.lapses],
      [0, 1],
    );
    expect(store.statFor(d10).touched, 1);
  });
}
