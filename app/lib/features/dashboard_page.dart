import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/device_link.dart';
import '../data/schedule.dart';
import '../data/wordbook_store.dart';
import '../ui/hard_style.dart';
import 'entry_page.dart';
import 'plan_page.dart';
import 'plan_rows.dart';
import 'push_page.dart';
import 'scan_page.dart';
import 'settings_page.dart';

/// 首页总览。"今天"这一栏给的是**设备上今天那份表**，不是"还剩几个没学"：
/// 推成功之后排期会立刻缩水（新词一建档就退出待学），拿排期当今天这张表会看着像
/// 少了一半。诚实边界照旧 —— 孩子实际练了几个这边拿不到（对错只在设备内存里、
/// 掉电清零，上行只有 notify），所以打勾数只算手机侧的动作。
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<WordbookStore>();
    final sched = context.watch<ScheduleStore>();
    final link = context.watch<BleLink>();
    final now = DateTime.now();
    final pool = ScheduleStore.poolOf(store.weeks);
    final plan = sched.planFor(now, pool, intake: sched.activeSheet);
    final stat = sched.statFor(now);
    final sheet = sched.sheetOf(pool, plan, stat);
    final days = sched.recentDays(14, now);
    final hist = sched.boxHistogram(pool);
    final worst = sched.struggling(5, pool);

    return Scaffold(
      appBar: AppBar(
        title: const Text('单词机'),
        actions: [
          HardIconButton(
            icon: Icons.edit_note,
            tooltip: '录入单词',
            onPressed: () => _open(context, const EntryPage()),
          ),
          HardIconButton(
            icon: Icons.calendar_month,
            tooltip: '复习计划',
            onPressed: () => _open(context, const PlanPage()),
          ),
          HardIconButton(
            icon: Icons.tune,
            tooltip: '设定',
            onPressed: () => _open(context, const SettingsPage()),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _connBar(context, link),
          _todayCard(
            context,
            plan,
            sheet,
            stat,
            store.weeks.isEmpty ? '还没有词库，先去「录入」粘一批' : '今天没有到期的复习，当前词库也没新词可上了',
          ),
          _section(
            context,
            '档位分布（共 ${sched.trackedIn(pool)} 词）',
            _histogram(context, hist),
          ),
          _section(context, '最近两周每天上设备的词数', DayGrid(stats: days, today: now)),
          if (worst.isNotEmpty)
            _section(context, '反复记不住', _lapses(context, worst)),
          _section(
            context,
            '词库 ${store.weeks.length} 批 / ${store.weeks.fold<int>(0, (n, b) => n + b.words.length)} 词',
            _weeks(context, store, sched, plan, pool),
          ),
        ],
      ),
    );
  }

  Widget _connBar(BuildContext context, BleLink link) {
    final on = link.connected;
    return HardCard(
      fill: on ? Hard.blue : Hard.sheet,
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          Icon(
            on ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            size: 20,
            color: on ? Colors.white : Hard.muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              on
                  ? '已连接   MTU ${link.mtu}   ${link.peerId}'
                  : (link.lastError.isEmpty ? '没连设备' : link.lastError),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Hard.body(
                context,
              ).copyWith(color: on ? Colors.white : Hard.muted),
            ),
          ),
          HardButton(
            label: on ? '设备页' : '去连接',
            fill: on ? Hard.sheet : Hard.blue,
            onColor: on ? Hard.ink : Colors.white,
            onPressed: () => _open(context, const ScanPage()),
          ),
        ],
      ),
    );
  }

  Widget _todayCard(
    BuildContext context,
    DayPlan plan,
    List<PlanWord> sheet,
    DayStat stat,
    String emptyText,
  ) {
    final theme = Theme.of(context);
    final names = const ['一', '二', '三', '四', '五', '六', '日'];
    final freshCount = sheet.where((w) => w.isNew).length;
    // 新词当天不复习（第一次打勾在次日），所以进度只算该打勾的那几个，
    // 不然推完 30 词、能勾的只有 12 个，条子永远填不满。
    final toMark = sheet.length - freshCount;
    final done = stat.touched;
    final pushed = stat.pushed.length;
    return HardCard(
      margin: Hard.gutter(top: 8, bottom: 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${plan.day.month} 月 ${plan.day.day} 日 周${names[plan.day.weekday - 1]}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              // 逾期是家长最该先看到的那个数字，所以给它实心红块，不给它一行小字。
              HardTag(
                text: '今天这张表 ${sheet.length} 词',
                fill: plan.overdueCount == 0 ? Hard.blue : Hard.coral,
                on: Colors.white,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                HardTag(text: '复习 $toMark', fill: Hard.sheet),
                if (plan.overdueCount > 0)
                  HardTag(
                    text: '逾期 ${plan.overdueCount}',
                    fill: Hard.coral,
                    on: Colors.white,
                  ),
                HardTag(text: '新词 $freshCount', fill: Hard.sheet),
                // 只报当前词库的库存：别的批次不补上就没法算"几天能见底"。
                if (plan.intakeLeft > 0)
                  HardTag(
                    text: '「${plan.intakeLabel}」还剩 ${plan.intakeLeft}',
                    fill: Hard.sheet,
                  ),
                if (plan.masteredCount > 0)
                  HardTag(text: '已毕业 ${plan.masteredCount}', fill: Hard.amber),
                if (pushed == 0)
                  HardTag(text: '还没推上设备', fill: Hard.sheet)
                else
                  HardTag(text: '已推上设备 $pushed 词', fill: Hard.amber),
              ],
            ),
          ),
          if (toMark > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 10, 0, 2),
              child: Row(
                children: [
                  Expanded(
                    child: HardBar(fraction: done / toMark, color: Hard.blue),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '勾 $done / $toMark',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 6),
            child: Text(
              toMark == 0
                  ? '今天全是新词，当天不用打勾，明天才开始复习。'
                  : '打完勾排期才会往前走。孩子在设备上练了几个这边看不到。',
              style: Hard.body(context),
            ),
          ),
          if (sheet.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(emptyText, style: Hard.body(context)),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '设备上今天这 ${sheet.length} 个词：'
                '${sheet.map((w) => w.word).take(14).join(' ')}'
                '${sheet.length > 14 ? ' …' : ''}',
                style: Hard.body(context),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerRight,
              child: HardButton(
                label: '去计划页打勾 / 推今天这张表',
                fill: Hard.blue,
                onColor: Colors.white,
                onPressed: () => _open(context, const PlanPage()),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
          child: Text(title, style: Hard.label(context)),
        ),
        HardCard(
          margin: Hard.gutter(top: 6, bottom: 6),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: child,
        ),
      ],
    );
  }

  Widget _histogram(BuildContext context, Map<int, int> hist) {
    var total = 0;
    for (final n in hist.values) {
      total += n;
    }
    return Column(
      children: [
        for (final e in hist.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              children: [
                SizedBox(
                  width: 56,
                  child: Text(
                    e.key == kGapDays.length ? '已毕业' : '第 ${e.key + 1} 档',
                    style: Hard.body(context),
                  ),
                ),
                Expanded(
                  child: HardBar(
                    fraction: total == 0 ? 0 : e.value / total,
                    color: e.key == kGapDays.length ? Hard.amber : Hard.blue,
                  ),
                ),
                SizedBox(
                  width: 32,
                  child: Text('${e.value}', textAlign: TextAlign.right),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _lapses(BuildContext context, List<MemoryRecord> worst) {
    return Column(
      children: [
        for (final r in worst)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 2),
            leading: const Icon(
              Icons.report_problem_outlined,
              size: 20,
              color: Hard.coral,
            ),
            title: Text(
              r.word,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              '忘过 ${r.lapses} 次   '
              '${r.mastered ? '后来毕业了' : '现在第 ${r.box + 1}/${kGapDays.length} 档'}'
              '   来自 ${r.label}',
              style: Hard.body(context),
            ),
          ),
      ],
    );
  }

  Widget _weeks(
    BuildContext context,
    WordbookStore store,
    ScheduleStore sched,
    DayPlan plan,
    List<PoolItem> pool,
  ) {
    if (store.weeks.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('手机上还没有词库'),
      );
    }
    // 分数按计划页 chip 同一个口径（词池去重后），两处对不上会被当成 bug。
    final tally = sched.batchProgress(pool);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '点一批 → 整本重推（维护，不记排期账）；日常推今天这张表在复习计划页。',
            style: Hard.body(context),
          ),
        ),
        if (plan.intakeLeft == 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              plan.otherLeft == 0
                  ? '词库里 ${pool.length} 个词全排上了，明天开始复习 —— '
                        '要上新词得再录一批'
                  : '「${plan.intakeLabel}」这批全排上了，明天开始复习 —— '
                        '要上新词得去复习计划页切下一批',
              style: Hard.flag(context),
            ),
          ),
        for (final b in store.weeks)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 2),
            leading: Icon(
              b.overlongCount == 0
                  ? Icons.check_circle_outline
                  : Icons.error_outline,
              size: 20,
              color: b.overlongCount == 0 ? Hard.blue : Hard.coral,
            ),
            title: Text(
              '${b.source} ${b.label}'
              '${b.label == plan.intakeLabel ? '  ← 新词从这批发' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              '已排上 ${tally[b.label]?.learned ?? 0}/${tally[b.label]?.total ?? 0}'
              '   发音已存 ${b.audioMark.length} 个   '
              '改于 ${_stamp(b.updatedAt)}'
              '${b.overlongCount == 0 ? '' : '   ${b.overlongCount} 词会被设备截断'}',
              style: Hard.body(context),
            ),
            onTap: () => _open(context, const PushPage()),
            trailing: HardMiniButton(
              icon: Icons.edit_outlined,
              color: Hard.ink,
              tooltip: '改来源 / 删掉',
              onPressed: () => _manage(context, store, sched, b),
            ),
          ),
      ],
    );
  }

  /// 批次名不能改 —— 它是文件名，也是每条记忆档案的归属外键，改名要连着搬档案。
  /// 所以这里只给来源和删除两件事。
  Future<void> _manage(
    BuildContext context,
    WordbookStore store,
    ScheduleStore sched,
    WeekBook book,
  ) async {
    // 设定里删掉一个来源，挂着这个名字的批次不会被动到 —— 这一排得把它带上，
    // 否则当前归属在 chip 上没处显示。
    final choices = store.sources.contains(book.source)
        ? store.sources
        : [...store.sources, book.source];
    final gone = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(book.label),
        content: HardPanel(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('来源', style: Hard.label(context)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final s in choices)
                    HardChip(
                      text: s,
                      on: s == book.source,
                      onTap: s == book.source
                          ? null
                          : () async {
                              Navigator.of(context).pop();
                              await store.save(book.withSource(s));
                            },
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  '改来源只动这一本的分组，词、发音标记和排期都不受影响。',
                  style: Hard.body(context),
                ),
              ),
            ],
          ),
        ),
        actions: [
          HardButton(label: '关掉', onPressed: () => Navigator.of(context).pop()),
          HardButton(
            label: '删掉这批',
            fill: Hard.coral,
            onColor: Colors.white,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (gone != true || !context.mounted) return;
    await _confirmDelete(context, store, sched, book);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WordbookStore store,
    ScheduleStore sched,
    WeekBook book,
  ) async {
    final n = book.words.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删掉 ${book.source} ${book.label}？'),
        content: HardPanel(
          child: Text(
            '这批 $n 词从词库里拿走，明天起不会再排它们。\n'
            '已经学过的词，记忆档案留着 —— 回头录同名批次会接上进度，'
            '但删掉的这段时间它们不会再复习。\n'
            '设备上现在那张表不受影响，要换得去推送页重推。',
            style: Hard.body(context).copyWith(height: 1.5),
          ),
        ),
        actions: [
          HardButton(
            label: '不删了',
            onPressed: () => Navigator.of(context).pop(false),
          ),
          HardButton(
            label: '删',
            fill: Hard.coral,
            onColor: Colors.white,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await store.delete(book.label);
    // 删的正是当前词库的话把选择清空，退到"最新改动那批"，别在档案里留个不存在的名字。
    if (sched.activeSheet == book.label) await sched.setActiveSheet('');
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
