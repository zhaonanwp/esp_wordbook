import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/protocol.dart';
import 'wordbook_store.dart';

/// 艾宾浩斯在"一天只练一次"的设备上只剩天级精度：当天学，之后第 1/2/4/7/15/30 天
/// 各复习一次，全对就毕业。20 分钟、1 小时那几档要设备自己按分钟走，而设备连
/// "今天是几号"都不知道（固件无墙钟、无对时），所以做不了也不该假装做得了。
const List<int> kGapDays = [1, 2, 4, 7, 15, 30];

DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

int daysBetween(DateTime from, DateTime to) =>
    dayOf(to).difference(dayOf(from)).inDays;

/// 手机侧那天干了什么。注意这不是"孩子练了几个"：设备不会主动汇报，
/// 掉电就把对错清了。这里只能记 app 自己的动作。
class DayStat {
  DayStat(this.day);

  final DateTime day;
  final Set<String> pushed = {};
  final Set<String> marked = {};
  final Set<String> forgotten = {};

  int get touched => marked.length + forgotten.length;

  Map<String, dynamic> toJson() => {
    'd': _stamp(day),
    'p': pushed.toList(),
    'm': marked.toList(),
    'f': forgotten.toList(),
  };

  factory DayStat.fromJson(Map<String, dynamic> json) {
    final s = DayStat(_dayOf(json['d']));
    s.pushed.addAll(_words(json['p']));
    s.marked.addAll(_words(json['m']));
    s.forgotten.addAll(_words(json['f']));
    return s;
  }

  static String _stamp(DateTime d) => d.toIso8601String().substring(0, 10);

  static DateTime _dayOf(Object? v) =>
      DateTime.tryParse('$v') ?? DateTime.now();

  static Set<String> _words(Object? v) =>
      v is List ? {for (final e in v) '$e'.toLowerCase()} : <String>{};
}

class MemoryRecord {
  MemoryRecord({
    required this.word,
    required this.label,
    required this.learnedDay,
    required this.dueDay,
    this.box = 0,
    this.lastReview,
    this.lapses = 0,
  });

  final String word;

  /// 这个词来自哪张周表。设备上早就不在了，发音标记得写回这张表才对得上。
  final String label;

  final DateTime learnedDay;

  /// 下一次该练的日子。逾期（dueDay < 今天）不会被忽略，会一直排到练过为止。
  DateTime dueDay;

  /// 已经连着对了几档。等于 kGapDays.length 就是毕业。
  int box;

  DateTime? lastReview;
  int lapses;

  bool get mastered => box >= kGapDays.length;

  /// 逾期几天。0 = 今天到期，负数 = 还早。
  int overdue(DateTime today) => daysBetween(dueDay, today);

  Map<String, dynamic> toJson() => {
    'w': word,
    'l': label,
    'b': box,
    'n': learnedDay.toIso8601String().substring(0, 10),
    'd': dueDay.toIso8601String().substring(0, 10),
    if (lastReview != null) 'r': lastReview!.toIso8601String().substring(0, 10),
    'f': lapses,
  };

  factory MemoryRecord.fromJson(Map<String, dynamic> json) => MemoryRecord(
    word: (json['w'] ?? '') as String,
    label: (json['l'] ?? '') as String,
    box: (json['b'] ?? 0) as int,
    learnedDay: _day(json['n']),
    dueDay: _day(json['d']),
    lastReview: json['r'] == null ? null : _day(json['r']),
    lapses: (json['f'] ?? 0) as int,
  );

  static DateTime _day(Object? v) => DateTime.tryParse('$v') ?? DateTime.now();
}

class PoolItem {
  PoolItem(this.entry, this.label);

  final WordEntry entry;

  /// 这个词来自哪张周表，发音标记和记忆档案都要写回它。
  final String label;
}

class PlanWord {
  PlanWord(this.entry, {required this.label, this.record, this.isNew = false});

  final WordEntry entry;
  final String label;
  final MemoryRecord? record;
  final bool isNew;

  String get word => entry.word;
}

class DayPlan {
  DayPlan({
    required this.day,
    required this.review,
    required this.fresh,
    required this.intakeLabel,
    required this.intakeLeft,
    required this.otherLeft,
    required this.masteredCount,
  });

  final DateTime day;

  /// 到期复习（含逾期），按该练的日子排，逾期最久的在最前面。
  final List<PlanWord> review;

  /// 今天第一次出现的词，受 newPerDay 限制，**只从当前词库那一批里抽**。
  final List<PlanWord> fresh;

  /// 今天实际用来上新词的那一批（当前词库被删了就是最新那一批）。
  final String intakeLabel;

  /// 当前词库里还没上新的词数；0 = 这批见底，该切下一批了。
  final int intakeLeft;

  /// 别的批次里还没上新的词数。和 intakeLeft 一起才分得清"没词了"和"忘了切批次"。
  final int otherLeft;

  final int masteredCount;

  /// 设备是一天翻一遍的顺序：先把到期的过一遍，再上新词。
  List<PlanWord> get words => [...review, ...fresh];

  int get overdueCount =>
      review.where((w) => w.record!.overdue(day) > 0).length;
}

/// 一轮设备结果入账的计数，只用来给推送页回一句话。
class RoundTally {
  /// 真的动了档案的词数。
  int credited = 0;

  /// 今天已经有过同样结论（一天练两遍、或者重复取回同一轮）。
  int repeated = 0;

  /// 词池里没有，对不上档，只数了个数。
  int orphan = 0;

  /// uid 早就记过账了，这次只是补 ack。
  bool alreadyImported = false;
}

/// 记忆档案存在手机上（documents/schedule.json）：设备没有日期概念，也不掉电保存状态，
/// 调度只能在有钟有历史的那一头算。
class ScheduleStore extends ChangeNotifier {
  ScheduleStore();

  File? _file;
  final Map<String, MemoryRecord> _records = {};
  final Map<String, DayStat> _history = {};

  /// 已经从设备取过账的轮次 uid。设备没有钟，一轮练完到 app 手里可能已经隔了一天，
  /// 「哪一天」只能按取回来的那天算 —— 隔天再取同一轮，靠 (日期, 单词) 去重是挡不住的，
  /// 只有 uid 认得出它是同一轮。ack 失败重取时也靠它避免二次记账。
  final Set<int> _imported = {};

  bool _ready = false;
  bool get ready => _ready;

  int newPerDay = 6;

  /// 新词从哪一批抽。app 不自动往下跳 —— 课本按单元、新东方一周一次，
  /// 只有他知道学校进度到哪儿了。空 = 没设过，用最新改动的那一批。
  String activeSheet = '';

  Future<void> setActiveSheet(String label) async {
    if (activeSheet == label) return;
    activeSheet = label;
    await _flush();
    notifyListeners();
  }

  /// 档案条数，含已经不在词池里的那些。汇总数字别用它，用 [trackedIn]。
  int get archivedCount => _records.length;
  int trackedIn(List<PoolItem> pool) => liveRecords(pool).length;
  int masteredIn(List<PoolItem> pool) =>
      liveRecords(pool).where((r) => r.mastered).length;

  /// 还在词池里的档案。口径和 [planFor] 一致：周表删过、拼写改过的词不占今天的名额，
  /// 也就不该出现在首页那几个数上 —— 不然推得越久，"共 N 词"和孩子手上那份差得越远。
  /// 档案本身一条都不删：把拼法改回去，进度本来就该还在。
  List<MemoryRecord> liveRecords(List<PoolItem> pool) {
    final inPool = {for (final p in pool) p.entry.word.toLowerCase()};
    return [
      for (final r in _records.values)
        if (inPool.contains(r.word.toLowerCase())) r,
    ];
  }

  MemoryRecord? recordOf(String word) => _records[word.toLowerCase()];

  DayStat statFor(DateTime day) =>
      _history.putIfAbsent(_key(day), () => DayStat(dayOf(day)));

  static String _key(DateTime day) =>
      dayOf(day).toIso8601String().substring(0, 10);

  /// 最近 n 天，没记录的那天补一个空的，画柱状图不用再看 null。
  List<DayStat> recentDays(int n, DateTime today) {
    final out = <DayStat>[];
    for (var i = n - 1; i >= 0; i--) {
      final day = dayOf(today).subtract(Duration(days: i));
      out.add(_history[_key(day)] ?? DayStat(day));
    }
    return out;
  }

  /// 各档有多少词：0 = 刚上还没复习过，kGapDays.length = 毕业。只数在词池里的。
  Map<int, int> boxHistogram(List<PoolItem> pool) {
    final out = <int, int>{for (var b = 0; b <= kGapDays.length; b++) b: 0};
    for (final r in liveRecords(pool)) {
      final b = r.box.clamp(0, kGapDays.length);
      out[b] = (out[b] ?? 0) + 1;
    }
    return out;
  }

  List<MemoryRecord> struggling(int n, List<PoolItem> pool) {
    final rows = liveRecords(pool).where((r) => r.lapses > 0).toList()
      ..sort((a, b) {
        final byLapse = b.lapses.compareTo(a.lapses);
        return byLapse != 0 ? byLapse : a.word.compareTo(b.word);
      });
    return rows.take(n).toList();
  }

  Future<void> setNewPerDay(int n) async {
    final v = n < 1 ? 1 : (n > 30 ? 30 : n);
    if (v == newPerDay) return;
    newPerDay = v;
    await _flush();
    notifyListeners();
  }

  Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    _file = File('${docs.path}/schedule.json');
    if (await _file!.exists()) {
      try {
        final json =
            jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        final loaded = <String, MemoryRecord>{};
        for (final raw in (json['words'] ?? []) as List) {
          final r = MemoryRecord.fromJson(raw as Map<String, dynamic>);
          if (r.word.isEmpty) continue;
          loaded[r.word.toLowerCase()] = r;
        }
        // 先解到临时表再换进去：文件读到一半炸了不能把内存里的档案一起带空，
        // 否则紧接着那次写盘就会把空档案盖回原文件。
        _records
          ..clear()
          ..addAll(loaded);
        final hist = <String, DayStat>{};
        for (final raw in (json['history'] ?? []) as List) {
          final s = DayStat.fromJson(raw as Map<String, dynamic>);
          hist[_key(s.day)] = s;
        }
        // 账本只留最近 90 天：天天推的话两年就攒出几千行，而仪表盘只看两周。
        final cutoff = dayOf(DateTime.now()).subtract(const Duration(days: 90));
        hist.removeWhere((_, v) => v.day.isBefore(cutoff));
        _history
          ..clear()
          ..addAll(hist);
        newPerDay = (json['newPerDay'] as num?)?.toInt() ?? newPerDay;
        activeSheet = (json['active'] ?? '') as String;
        final taken = <int>{};
        for (final v in (json['imported'] ?? []) as List) {
          final n = v is num ? v.toInt() : int.tryParse('$v');
          if (n != null && n != 0) taken.add(n);
        }
        _imported
          ..clear()
          ..addAll(taken);
      } catch (e) {
        debugPrint('ScheduleStore: 读不动 $_file: $e');
      }
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> _flush() async {
    final file = _file;
    if (file == null) return;
    final tmp = File('${file.path}.tmp');
    final body = {
      'v': 1,
      'newPerDay': newPerDay,
      'active': activeSheet,
      'words': [for (final r in _records.values) r.toJson()],
      'history': [for (final s in _history.values) s.toJson()],
      'imported': (_imported.toList()..sort()),
    };
    await tmp.writeAsString(jsonEncode(body), flush: true);
    await tmp.rename(file.path);
  }

  /// 全量词池：批次按"最近改动"排，重复词只算一次并归到排在前面的那一批。
  /// 和 [WordbookStore.reload] 的排序规则保持一致，不然列表顺序和抽词顺序会打架。
  static List<PoolItem> poolOf(List<WeekBook> weeks) {
    final sorted = [...weeks]
      ..sort(
        (a, b) => a.updatedAt != b.updatedAt
            ? b.updatedAt.compareTo(a.updatedAt)
            : b.label.compareTo(a.label),
      );
    final out = <PoolItem>[];
    final seen = <String>{};
    for (final book in sorted) {
      for (final entry in book.words) {
        if (entry.word.isEmpty) continue;
        if (seen.add(entry.word.toLowerCase())) {
          out.add(PoolItem(entry, book.label));
        }
      }
    }
    return out;
  }

  /// 每批的进度：已经开过几个（含毕业的）/ 该批落在词池里的词数。
  /// 按词池的归属去重，所以重复词只算在最靠前那批头上 —— 和 [planFor] 抽新词同一口径，
  /// 不然计划页 chip 上的分数和"这批还剩几个"会对不上。
  Map<String, ({int learned, int total})> batchProgress(List<PoolItem> pool) {
    final learned = <String, int>{};
    final total = <String, int>{};
    for (final p in pool) {
      total[p.label] = (total[p.label] ?? 0) + 1;
      if (_records.containsKey(p.entry.word.toLowerCase())) {
        learned[p.label] = (learned[p.label] ?? 0) + 1;
      }
    }
    return {
      for (final e in total.entries)
        e.key: (learned: learned[e.key] ?? 0, total: e.value),
    };
  }

  /// [intake] 是新词从哪一批抽（计划页那个选择器选的）。这批不存在或没给，
  /// 就退到词池里的第一批；复习词不受它影响，仍然是全局按到期排。
  DayPlan planFor(DateTime today, List<PoolItem> pool, {String intake = ''}) {
    final day = dayOf(today);
    final byWord = {for (final p in pool) p.entry.word.toLowerCase(): p};
    final review =
        <PlanWord>[
          // 只排还在周表里的词：某张周表被删了，它的档案留着但不占用今天的额度。
          for (final r in _records.values)
            if (!r.mastered &&
                byWord.containsKey(r.word.toLowerCase()) &&
                !r.dueDay.isAfter(day))
              PlanWord(
                byWord[r.word.toLowerCase()]!.entry,
                label: r.label,
                record: r,
              ),
        ]..sort((a, b) {
          final byDue = a.record!.dueDay.compareTo(b.record!.dueDay);
          return byDue != 0 ? byDue : a.word.compareTo(b.word);
        });

    final scheduled = {for (final p in review) p.word.toLowerCase()};
    final label = pool.any((p) => p.label == intake)
        ? intake
        : (pool.isEmpty ? '' : pool.first.label);

    final unlearned = pool
        .where((p) => !_records.containsKey(p.entry.word.toLowerCase()))
        .toList();
    final mine = unlearned.where((p) => p.label == label).toList();
    final fresh = <PlanWord>[];
    for (final item in mine) {
      if (fresh.length >= newPerDay) break;
      final key = item.entry.word.toLowerCase();
      if (_records.containsKey(key) || scheduled.contains(key)) continue;
      fresh.add(PlanWord(item.entry, label: item.label, isNew: true));
    }

    return DayPlan(
      day: day,
      review: review,
      fresh: fresh,
      intakeLabel: label,
      intakeLeft: mine.length - fresh.length,
      otherLeft: unlearned.length - mine.length,
      masteredCount: masteredIn(pool),
    );
  }

  /// 今天这张表 = 设备上今天那份，推没推过都按它算。
  /// [planFor] 答的是"现在该推什么"，推成功之后它立刻缩水：新词一建档就退出待学，
  /// 30 词的表刷地变成 12 个，而那 12 个还是昨天推上去的。首页要给人看的是孩子手上
  /// 这份，所以把当天的到期词和当天推上设备的词并起来 —— 不然刚推完那 18 个新词
  /// 今天在列表里连个位置都没有。
  List<PlanWord> sheetOf(List<PoolItem> pool, DayPlan plan, DayStat stat) {
    if (stat.pushed.isEmpty) return plan.words;
    final out = <PlanWord>[];
    final seen = <String>{};
    for (final p in plan.words) {
      if (seen.add(p.word.toLowerCase())) out.add(p);
    }
    // 补进来的按词池顺序排，和它们当初作为新词被抽出来的顺序一致。
    for (final item in pool) {
      final key = item.entry.word.toLowerCase();
      if (!stat.pushed.contains(key) || !seen.add(key)) continue;
      final r = _records[key];
      // 没档案 = 这批后来被删过或那次推送根本没建档，勾不动也不该充数。
      if (r == null) continue;
      out.add(
        PlanWord(
          item.entry,
          label: item.label,
          record: r,
          isNew: daysBetween(r.learnedDay, stat.day) == 0,
        ),
      );
    }
    return out;
  }

  /// 推出去 = 今天开始了。新词从这天起算，学完当天不复习（第一次复习在次日）。
  Future<void> introduce(List<PlanWord> words, DateTime today) async {
    final day = dayOf(today);
    var changed = false;
    for (final p in words) {
      final key = p.word.toLowerCase();
      if (_records.containsKey(key)) continue;
      _records[key] = MemoryRecord(
        word: p.word,
        label: p.label,
        learnedDay: day,
        dueDay: day.add(const Duration(days: 1)),
      );
      changed = true;
    }
    if (changed) {
      await _flush();
      notifyListeners();
    }
  }

  /// 推送成功后记一笔"今天上过设备的是哪些词"。重推同一张表不会重复计。
  Future<void> recordPush(List<String> words, DateTime today) async {
    final s = statFor(dayOf(today));
    final before = s.pushed.length;
    s.pushed.addAll([for (final w in words) w.toLowerCase()]);
    if (s.pushed.length != before) {
      await _flush();
      notifyListeners();
    }
  }

  /// 设备上右键=想不起来、长按=记起来了，回来在这儿对账。
  Future<void> report(
    String word,
    String label,
    DateTime today, {
    required bool remembered,
  }) async {
    if (!_settle(word, label, dayOf(today), remembered: remembered)) return;
    await _flush();
    notifyListeners();
  }

  /// 一个词的一次结论。[report] 和设备轮次入账都走这里，档位算法只有一份。
  /// 返回 false = 今天这个词已经有过同样的结论，不动账。
  bool _settle(
    String word,
    String label,
    DateTime day, {
    required bool remembered,
  }) {
    final key = word.toLowerCase();
    final stat = statFor(day);
    // 打完勾那一行不会从今天这张表里消失（表是按推送记录算的），所以手滑点第二次
    // 完全可能。同一个结论一天只算一次，不然档位会被同一场练习往前推两格。
    if ((remembered ? stat.marked : stat.forgotten).contains(key)) return false;
    final r =
        _records[key] ??
        MemoryRecord(word: word, label: label, learnedDay: day, dueDay: day);
    if (remembered) {
      // box 是"下一次该隔几天"，所以先按当前档定日子，再进档。
      final gap = kGapDays[r.box.clamp(0, kGapDays.length - 1)];
      r.dueDay = day.add(Duration(days: gap));
      r.box += 1;
    } else {
      r.box = 0;
      r.lapses += 1;
      r.dueDay = day.add(const Duration(days: 1));
    }
    r.lastReview = day;
    _records[key] = r;
    // 同一个词今天改主意（先点记住又点忘了）不该在账本里算两笔。
    if (remembered) {
      stat.marked.add(key);
      stat.forgotten.remove(key);
    } else {
      stat.forgotten.add(key);
      stat.marked.remove(key);
    }
    return true;
  }

  /// 设备过完的一轮直接入账，家长不用再对着屏幕勾一遍。
  ///
  /// 归到 [day]，也就是取回来的那天：设备没有墙钟，判不出这轮到底是哪天练的。
  /// 词池里没有的词只数个数、不建档 —— 那是别的批次或改过拼法的残留，
  /// 给它建档案只会把汇总数字做脏。
  /// 只写盘一次：uid 和改动的档案、账本落在同一个 schedule.json 里。
  /// ack 必须等这里返回之后再发，不然设备把轮次删了、这边却没记上。
  Future<RoundTally> applyDeviceRound({
    required int uid,
    required DateTime day,
    required List<String> words,
    required Set<String> forgotten,
    required List<PoolItem> pool,
  }) async {
    final tally = RoundTally();
    if (_imported.contains(uid)) {
      // 早就记过账，只是那次的 ack 没送达。档案一个字都不改，调用方补发 ack 就行。
      tally.alreadyImported = true;
      return tally;
    }
    final byWord = {for (final p in pool) p.entry.word.toLowerCase(): p};
    final date = dayOf(day);
    for (final word in words) {
      final key = word.toLowerCase();
      final p = byWord[key];
      if (p == null) {
        tally.orphan += 1;
        continue;
      }
      if (
        !_settle(
          p.entry.word,
          p.label,
          date,
          remembered: !forgotten.contains(key),
        )
      ) {
        tally.repeated += 1;
        continue;
      }
      tally.credited += 1;
    }
    _imported.add(uid);
    await _flush();
    notifyListeners();
    return tally;
  }

  /// 覆盖重录一批时，旧表里消失的词如果和这次新进表的某个词只差一个拼法，
  /// 把档案搬到新拼法上 —— 拼写记错了改回来，不该把练到第 5 档清零。
  /// 认法故意留得窄（见 [_oneEditApart]），认不出来的一条都不动，原样留着，
  /// 由 [liveRecords] 把它们挡在汇总数字外面。返回搬动了哪几对，给录入页回话用。
  Future<List<String>> rehomeOrphans(
    List<String> dropped,
    List<String> appeared,
  ) async {
    final moved = <String>[];
    final free = [
      for (final w in appeared)
        if (!_records.containsKey(w.toLowerCase())) w,
    ];
    final gone = <String, MemoryRecord>{};
    for (final w in dropped) {
      final r = _records[w.toLowerCase()];
      if (r != null) gone[w.toLowerCase()] = r;
    }
    if (gone.isEmpty || free.isEmpty) return moved;

    for (final entry in gone.entries.toList()) {
      final r = entry.value;
      final hits = free.where((t) => _oneEditApart(r.word, t)).toList();
      // 两个拼法都接得上就走不通：猜错一次，进度就跟着别的词走，比清零更难查。
      if (hits.length != 1) continue;
      final pick = hits.single;
      _rehome(r, pick);
      moved.add('${r.word} → $pick');
      free.remove(pick);
    }
    if (moved.isNotEmpty) {
      await _flush();
      notifyListeners();
    }
    return moved;
  }

  /// 换 key 保进度。当天账本里那几个集合也一起换，不然这个词今天已经打过勾了，
  /// 换个拼法又能再进一次档（[report] 的去重按词文本认）。
  void _rehome(MemoryRecord old, String to) {
    final from = old.word.toLowerCase();
    final key = to.toLowerCase();
    _records
      ..remove(from)
      ..[key] = MemoryRecord(
        word: to,
        label: old.label,
        learnedDay: old.learnedDay,
        dueDay: old.dueDay,
        box: old.box,
        lastReview: old.lastReview,
        lapses: old.lapses,
      );
    for (final s in _history.values) {
      if (s.pushed.remove(from)) s.pushed.add(key);
      if (s.marked.remove(from)) s.marked.add(key);
      if (s.forgotten.remove(from)) s.forgotten.add(key);
    }
  }

  /// 改动一个字母才算：换字母、加字母、删字母各算一次。比的是字母袋子不是编辑
  /// 距离，改拼写常见的是丢双写（recieve→receive）。太短的词不认 —— `a` 和 `an`、
  /// `in` 和 `it` 差一个字母，但它们是词组里另一个词，不是拼错。
  static bool _oneEditApart(String a, String b) {
    if (a.toLowerCase() == b.toLowerCase()) return false;
    final x = _letterBag(a), y = _letterBag(b);
    if (x.fold<int>(0, (s, v) => s + v) < 3 || y.fold<int>(0, (s, v) => s + v) < 3) {
      return false;
    }
    var add = 0, del = 0;
    for (var i = 0; i < 26; i++) {
      if (x[i] > y[i]) del += x[i] - y[i];
      if (y[i] > x[i]) add += y[i] - x[i];
    }
    return (add > del ? add : del) <= 1;
  }

  /// 只数 a-z：词组里的空格、连字符不算字母，`jump rope` 和 `jumprope` 视作同一个袋子。
  static List<int> _letterBag(String w) {
    final bag = List<int>.filled(26, 0);
    for (final c in w.toLowerCase().codeUnits) {
      if (c >= 97 && c <= 122) bag[c - 97] += 1;
    }
    return bag;
  }
}

/// 今天这张表是跨周拼出来的，而"设备上已经是这份发音"的记账（audioMark）存在各张
/// 周表里。推送前合并、推成功一个再按归属写回对应那本，不然标记会丢掉、下次重推
/// 就要白跑一遍 BLE。
class MarkRouter {
  MarkRouter({
    required List<WeekBook> Function() weeks,
    required Future<void> Function(WeekBook) save,
  }) : _weeks = weeks,
       _save = save;

  final List<WeekBook> Function() _weeks;
  final Future<void> Function(WeekBook) _save;
  final Map<String, String> _seen = {};

  /// 周表按"最近改动"倒序排，putIfAbsent 让最靠前那本的同 slug 说了算。
  void reindex() {
    _seen.clear();
    for (final book in _weeks()) {
      for (final e in book.audioMark.entries) {
        _seen.putIfAbsent(e.key, () => e.value);
      }
    }
  }

  Map<String, String> get merged => Map.unmodifiable(_seen);

  WeekBook? _ownerOf(String slug) {
    for (final book in _weeks()) {
      if (book.words.any((e) => e.slug == slug)) return book;
    }
    return null;
  }

  Future<void> writeBack(WeekBook sheet) async {
    for (final e in sheet.audioMark.entries) {
      if (_seen[e.key] == e.value) continue;
      _seen[e.key] = e.value;
      final owner = _ownerOf(e.key);
      if (owner == null) continue;
      owner.audioMark[e.key] = e.value;
      await _save(owner);
    }
  }
}
