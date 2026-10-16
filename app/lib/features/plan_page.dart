import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/device_link.dart';
import '../data/schedule.dart';
import '../data/sync_runner.dart';
import '../data/wordbook_store.dart';
import '../data/youdao.dart';
import '../ui/hard_style.dart';
import 'plan_rows.dart';
import 'settings_page.dart';

/// 艾宾浩斯计划表。日期、历史、记忆档案全在手机这一头：设备既没有钟也不掉电存状态，
/// 所以它只负责"今天这一张"，节奏由 app 算、由 app 一天推一次。
class PlanPage extends StatefulWidget {
  const PlanPage({super.key});

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  final Set<String> _off = {};
  bool _withAudio = true;
  bool _forceAudio = false;
  String _message = '';
  SyncRunner? _runner;
  Youdao? _youdao;
  late final MarkRouter _router;

  @override
  void initState() {
    super.initState();
    final store = context.read<WordbookStore>();
    _router = MarkRouter(weeks: () => store.weeks, save: store.save)..reindex();
    final audioDir = store.audioDir;
    if (audioDir != null) {
      _youdao = Youdao(audioDir);
      _runner = SyncRunner(context.read<BleLink>(), _youdao!);
      _runner!.addListener(_onRunner);
    }
  }

  void _onRunner() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _runner?.removeListener(_onRunner);
    _runner?.cancel();
    _runner?.dispose();
    _youdao?.close();
    super.dispose();
  }

  /// 列表和推送都以"今天这张表"为准：推成功之后 [DayPlan] 会缩水（新词建档就退出待学），
  /// 要是按它推，下午再点一次就把早上那批新词从设备上抹掉了。
  List<PlanWord> _today(List<PlanWord> sheet) => _off.isEmpty
      ? sheet
      : sheet.where((p) => !_off.contains(p.word.toLowerCase())).toList();

  /// [rows] 是今天这张表的行；里面那个 `sheet` 是发给设备的临时 WeekBook，两个不是一回事。
  Future<void> _push(DayPlan plan, List<PlanWord> rows) async {
    final runner = _runner;
    final sched = context.read<ScheduleStore>();
    if (runner == null || runner.busy || !context.read<BleLink>().connected) {
      return;
    }
    final picked = _today(rows);
    if (picked.isEmpty) {
      setState(() => _message = '今天一个词都没勾上');
      return;
    }
    // 这张临时表不落盘（persist 走 MarkRouter 写回各自周表），label 只是给人看的。
    final sheet = WeekBook(
      label: '今日 ${plan.day.month}-${plan.day.day}',
      version: WeekBook.nextVersion(),
      updatedAt: DateTime.now(),
      words: [for (final p in picked) p.entry],
      audioMark: Map.of(_router.merged),
    );
    try {
      await runner.push(
        sheet,
        withAudio: _withAudio,
        forceAudio: _forceAudio,
        persist: (book) => _router.writeBack(book),
      );
      // 推成功才开始算日子；半途失败的话明天还是同一张表。
      await sched.introduce(picked, DateTime.now());
      await sched.recordPush([for (final p in picked) p.word], DateTime.now());
      _router.reindex();
      if (!mounted) return;
      setState(() => _message = '已推 ${picked.length} 词，设备上现在就是今天这张表');
    } on LinkException catch (e) {
      if (mounted) setState(() => _message = '推送失败：${e.message}');
    } on YoudaoException catch (e) {
      if (mounted) setState(() => _message = '抓发音失败：${e.message}');
    }
  }

  Future<void> _mark(PlanWord p, bool remembered) async {
    await context.read<ScheduleStore>().report(
      p.word,
      p.label,
      DateTime.now(),
      remembered: remembered,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final link = context.watch<BleLink>();
    final store = context.watch<WordbookStore>();
    final sched = context.watch<ScheduleStore>();
    final pool = ScheduleStore.poolOf(store.weeks);
    final now = DateTime.now();
    final plan = sched.planFor(now, pool, intake: sched.activeSheet);
    final stat = sched.statFor(now);
    final sheet = sched.sheetOf(pool, plan, stat);
    final busy = _runner?.busy ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('复习计划'),
        actions: [
          HardIconButton(
            icon: Icons.filter_alt_off_outlined,
            tooltip: '把剔除的词都放回今天',
            onPressed: _off.isEmpty
                ? null
                : () => setState(() {
                    _off.clear();
                    _message = '';
                  }),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _header(sched, store, plan, sheet, stat),
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Text(_message, style: Hard.flag(context)),
            ),
          Expanded(
            child: sheet.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        store.weeks.isEmpty
                            ? '还没有词库，先去「录入单词」粘一批'
                            : plan.intakeLeft == 0 && plan.otherLeft > 0
                            ? '当前词库「${plan.intakeLabel}」的新词都学完了\n切一批或等复习到期'
                            : '今天没有要练的\n新词都学完、复习也都还没到期',
                        textAlign: TextAlign.center,
                        style: Hard.body(context),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    itemCount: sheet.length,
                    itemBuilder: (context, index) => _row(plan, sheet[index]),
                  ),
          ),
          if (_runner != null)
            _pushBar(
              context,
              plan,
              sheet,
              busy: busy,
              connected: link.connected,
            )
          else
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('发音目录没准备好', style: Hard.flag(context)),
            ),
        ],
      ),
    );
  }

  /// 底部那一坨：进度、当前阶段、勾选、推送按钮。原来散在四个 Padding 里，
  /// 收进一张卡片，省得推送中页面上下都在动。
  Widget _pushBar(
    BuildContext context,
    DayPlan plan,
    List<PlanWord> sheet, {
    required bool busy,
    required bool connected,
  }) {
    final picked = _today(sheet);
    return HardCard(
      margin: Hard.gutter(top: 6, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 进度条和阶段文字只在推送那一刻有意义，空闲时别在底部常驻占两行。
          if (busy) ...[
            HardBar(fraction: _runner!.progress),
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Text(
                '${_runner!.stage}'
                '${_runner!.wordsTotal == 0 ? '' : '   词 ${_runner!.wordsDone}/${_runner!.wordsTotal}'}'
                '${_runner!.audioTotal == 0 ? '' : '   发音 ${_runner!.audioDone}/${_runner!.audioTotal}'
                          '${_runner!.audioFailed == 0 ? '' : ' 失败 ${_runner!.audioFailed}'}'}'
                '${_runner!.currentWord.isEmpty ? '' : '   ▸ ${_runner!.currentWord}'}',
                style: Hard.body(context),
              ),
            ),
          ],
          Row(
            children: [
              _tick(
                label: '补发音',
                value: _withAudio,
                hint: '新词约 4 秒/词，设备上已有的自动跳过',
                enabled: !busy,
                onTap: () => setState(() {
                  _withAudio = !_withAudio;
                  if (!_withAudio) _forceAudio = false;
                }),
              ),
              const SizedBox(width: 14),
              if (_withAudio)
                _tick(
                  label: '强制重推',
                  value: _forceAudio,
                  hint: '设备上点着没声音、这边却记成「已经有了」时勾这个（每个词都重传，慢）',
                  enabled: !busy,
                  onTap: () => setState(() => _forceAudio = !_forceAudio),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: HardButton(
              expand: true,
              label: busy
                  ? '推送中…'
                  : (connected ? '推今天这 ${picked.length} 个词' : '先连设备再推'),
              fill: Hard.blue,
              onColor: Colors.white,
              onPressed: busy || !connected || picked.isEmpty
                  ? null
                  : () => _push(plan, sheet),
            ),
          ),
        ],
      ),
    );
  }

  /// 勾选只留两个字，长说明进 Tooltip（安卓上是长按）。这两条原来各占三行，
  /// 是这页最挤的地方 —— 而它们一天顶多点一次。
  Widget _tick({
    required String label,
    required bool value,
    required String hint,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IgnorePointer(
            child: Checkbox(
              value: value,
              onChanged: enabled ? (_) => onTap() : null,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Hard.ink,
            ),
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: hint,
            preferBelow: false,
            child: const Icon(Icons.info_outline, size: 15, color: Hard.muted),
          ),
        ],
      ),
    );
  }

  Widget _header(
    ScheduleStore sched,
    WordbookStore store,
    DayPlan plan,
    List<PlanWord> sheet,
    DayStat stat,
  ) {
    final names = const ['一', '二', '三', '四', '五', '六', '日'];
    final freshCount = sheet.where((w) => w.isNew).length;
    final pushed = stat.pushed.length;
    return HardCard(
      margin: Hard.gutter(top: 8, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  // '10 月 16 日 周五' 加上右边那个标签就要折成两行，日期写成紧凑式。
                  '${plan.day.month}-${plan.day.day} 周${names[plan.day.weekday - 1]}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              // 「今天已推 N」和「今天这张表 N 词」说的是同一张表，合成一个标签少一行。
              // 日期那一行只有 312 逻辑像素，标签再长一点就把日期挤成三行了，所以省掉「今天」。
              HardTag(
                text: pushed == 0
                    ? '这张表 ${sheet.length} 词'
                    : '这张表 ${sheet.length} 词 · 已推'
                          '${pushed == sheet.length ? '' : ' $pushed'}',
                fill: pushed == 0 ? null : Hard.amber,
                on: pushed == 0 ? null : Colors.white,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                HardTag(text: '复习 ${sheet.length - freshCount}'),
                if (plan.overdueCount > 0)
                  HardTag(
                    text: '逾期 ${plan.overdueCount}',
                    fill: Hard.coral,
                    on: Colors.white,
                  ),
                HardTag(text: '新词 $freshCount'),
                if (plan.intakeLeft > 0)
                  HardTag(text: '这批还剩 ${plan.intakeLeft} 没学'),
                if (plan.otherLeft > 0) HardTag(text: '别批还有 ${plan.otherLeft}'),
                if (plan.masteredCount > 0)
                  HardTag(text: '已毕业 ${plan.masteredCount}', fill: Hard.amber),
              ],
            ),
          ),
          _intake(context, sched, store, plan),
          Padding(
            // 额度不是每天看的，加减全到设定页去；这里只留当前值和一条路。
            padding: const EdgeInsets.only(top: 8),
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              ),
              child: Row(
                children: [
                  Text('每天引入新词 ${sched.newPerDay} 个', style: Hard.label(context)),
                  const SizedBox(width: 6),
                  Text('去设定改', style: Hard.body(context)),
                  const Icon(Icons.chevron_right, size: 16, color: Hard.muted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool busy() => _runner?.busy ?? false;

  /// 新词只从手选的这一批抽。课本按单元、新东方一周一课，两种节奏套不进同一个"周"，
  /// 见底了也只提醒，不自动往下跳 —— 学校进度到哪儿只有他知道。
  Widget _intake(
    BuildContext context,
    ScheduleStore sched,
    WordbookStore store,
    DayPlan plan,
  ) {
    if (store.weeks.isEmpty) return const SizedBox.shrink();
    final pushing = busy();
    // 切之前得先看得见哪批学过了、哪批还是全新的，不然一排名字只能靠记。
    final tally = sched.batchProgress(ScheduleStore.poolOf(store.weeks));
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 标签和那排 chip 挤同一行：一天就点一次，不值得各占一行。
              Text('当前词库', style: Hard.label(context)),
              const SizedBox(width: 8),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final b in store.weeks)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: HardChip(
                            text:
                                '${b.source} ${b.label}'
                                '  ${tally[b.label]?.learned ?? 0}/${tally[b.label]?.total ?? 0}',
                            on: b.label == plan.intakeLabel,
                            onTap: pushing
                                ? null
                                : () => sched.setActiveSheet(b.label),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (plan.intakeLeft == 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                plan.otherLeft == 0 ? '词库见底，去录入下一批' : '这批见底，切下一批',
                style: Hard.flag(context),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(DayPlan plan, PlanWord p) {
    final key = p.word.toLowerCase();
    return PlanRow(
      word: p,
      today: plan.day,
      enabled: !busy(),
      selected: !_off.contains(key),
      onToggle: () => setState(() {
        if (_off.contains(key)) {
          _off.remove(key);
        } else {
          _off.add(key);
        }
      }),
      onMark: _mark,
    );
  }
}
