import 'device_link.dart';
import 'schedule.dart';

/// 设备 rounds.tsv 里的一轮：本轮按顺序过了哪些词、哪些被按了「想不起来」。
typedef RoundRow = ({String word, bool forgotten});

class DeviceRound {
  DeviceRound({required this.uid, required this.rows});

  /// 设备给的轮号（开机随机数拼开机内序号），跨重启不重号，app 靠它认重复。
  final int uid;
  final List<RoundRow> rows;

  List<String> get words => [for (final r in rows) r.word];

  Set<String> get forgottenWords => {
    for (final r in rows)
      if (r.forgotten) r.word.toLowerCase(),
  };
}

/// 一次「收结果」的汇总，用来给计划页回一句话。
class ImportSummary {
  int rounds = 0;
  int credited = 0;
  int repeated = 0;
  int orphan = 0;

  /// 没取完的原因。取完就是 null。中途失败不影响后面的推送 —— 结果这一趟不要了，
  /// 设备上还留着，下次连接接着取。
  String? problem;

  String get line {
    final note = problem;
    if (note != null) {
      return rounds > 0 ? '结果没取完：$note（已取 $rounds 轮）' : '结果没取完：$note';
    }
    if (rounds == 0) return '设备上没有待回传的练习结果';
    final extra = <String>[
      '设备结果已入账：$rounds 轮 · 记了 $credited 词',
      if (repeated > 0) '重复 $repeated 词没再记',
      if (orphan > 0) '词池里没有 $orphan 词',
    ];
    return extra.join(' · ');
  }
}

/// 一次连接最多取这么多轮，防止哪天攒了几十轮把推送页卡在那儿不动。
const int kMaxPullRounds = 20;

/// 把设备上练完的轮次取回来，直接记进记忆档案。
///
/// 设备是断开蓝牙练的，练完只有本地一份 rounds.tsv；归账日期、档位、去重都在这边
/// （设备连「今天是几号」都不知道）。每轮取回来先落盘再 ack，顺序不能倒：
/// ack 一发设备就把那轮删了。
/// 只认设备报的 pending_rounds/oldest_round，老固件没这两个字段 = 一台还没存结果的
/// 设备，一句「没有待回传」带过，不会当成错误。
Future<ImportSummary> importDeviceRounds({
  required BleLink link,
  required ScheduleStore store,
  required List<PoolItem> pool,
  DateTime? today,
  void Function(String line)? onLog,
}) async {
  final day = dayOf(today ?? DateTime.now());
  final out = ImportSummary();
  try {
    for (var guard = 0; guard < kMaxPullRounds; guard++) {
      final uid = await _nextPendingUid(link);
      if (uid == null) return out;
      final round = await _fetchRound(link, uid);
      final tally = await store.applyDeviceRound(
        uid: round.uid,
        day: day,
        words: round.words,
        forgotten: round.forgottenWords,
        pool: pool,
      );
      out.rounds += 1;
      out.credited += tally.credited;
      out.repeated += tally.repeated;
      out.orphan += tally.orphan;
      onLog?.call(
        tally.alreadyImported
            ? '第 $uid 轮早就记过账，补 ack'
            : '第 $uid 轮：入账 ${tally.credited} 词'
                  '（想不起来 ${round.forgottenWords.length}）',
      );
      await _ackRound(link, uid);
    }
    out.problem = '一次没取完 $kMaxPullRounds 轮，剩下的下次连接再取';
  } on LinkException catch (e) {
    link.drain();
    out.problem = e.message;
  }
  return out;
}

/// 问设备还有几轮没交，返回该取的那一轮 uid；没有就返回 null。
Future<int?> _nextPendingUid(BleLink link) async {
  await link.writeCommand({'t': 'stat'});
  final stat = await link.waitFor('stat', const Duration(seconds: 8));
  final pending = (stat['pending_rounds'] as num?)?.toInt() ?? 0;
  if (pending <= 0) return null;
  final uid = (stat['oldest_round'] as num?)?.toInt() ?? 0;
  if (uid <= 0) {
    throw LinkException('设备说有 $pending 轮结果，却没给出轮号');
  }
  return uid;
}

/// 一轮切成好几条通知发过来。片号必须连着，缺一片就整轮不要（不 ack，下次重取）——
/// 记半轮比不记更糟：那批词看着练过了，其实只进了一半的账。
Future<DeviceRound> _fetchRound(BleLink link, int uid) async {
  await link.writeCommand({'t': 'result_get', 'u': uid});
  final rows = <RoundRow>[];
  int? total;
  int? declaredForgotten;
  var expect = 0;
  var gotLast = false;

  while (!gotLast) {
    final msg = await link.waitFor('result_rows', const Duration(seconds: 25));
    if ((msg['u'] as num?)?.toInt() != uid) continue;
    final part = (msg['i'] as num?)?.toInt() ?? -1;
    // 比 expect 小的是上次连接留在环形缓冲里的残片（连接时先重放了一帧最后一个值）。
    if (part < expect) continue;
    if (part > expect) {
      throw LinkException('第 $expect 片没等到，直接来了第 $part 片');
    }
    total = (msg['n'] as num?)?.toInt();
    declaredForgotten = (msg['f'] as num?)?.toInt();
    for (final raw in (msg['r'] ?? const []) as List) {
      final pair = raw as List;
      rows.add((word: '${pair[0]}', forgotten: (pair[1] as num).toInt() != 0));
    }
    expect += 1;
    gotLast = (msg['L'] as num?)?.toInt() == 1;
  }

  if (total == null || rows.length != total) {
    throw LinkException('第 $uid 轮收到 ${rows.length} 行，设备说 $total 行');
  }
  var forgotten = 0;
  for (final r in rows) {
    if (r.forgotten) forgotten++;
  }
  if (declaredForgotten != null && declaredForgotten != forgotten) {
    throw LinkException('第 $uid 轮行数对得上，「想不起来」对不上（$forgotten/$declaredForgotten）');
  }
  return DeviceRound(uid: uid, rows: rows);
}

Future<void> _ackRound(BleLink link, int uid) async {
  await link.writeCommand({'t': 'result_ack', 'u': uid});
  await link.waitFor('result_ack_ok', const Duration(seconds: 15));
}
