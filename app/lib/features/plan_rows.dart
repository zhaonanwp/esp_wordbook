import 'package:flutter/material.dart';

import '../data/schedule.dart';
import '../ui/hard_style.dart';

/// 计划页和首页共用这一行：两处都要"标记记住了/没想起来"，写两遍早晚调档逻辑不一致。
class PlanRow extends StatelessWidget {
  const PlanRow({
    super.key,
    required this.word,
    required this.today,
    required this.onMark,
    this.onToggle,
    this.selected = true,
    this.enabled = true,
  });

  final PlanWord word;
  final DateTime today;
  final void Function(PlanWord p, bool remembered) onMark;

  /// 传 null 就不给"今天先剔除"的勾选框（首页只读着看，剔除留在计划页做）。
  final VoidCallback? onToggle;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final rec = word.record;
    final late = rec == null ? 0 : rec.overdue(dayOf(today));
    final entry = word.entry;
    final line = [
      if (entry.syllable.isNotEmpty) entry.syllable,
      if (entry.phonetic.isNotEmpty) entry.phonetic,
      if (entry.meaning.isNotEmpty) entry.meaning,
    ].join('  ');
    // 一行只放最该看的那个状态：逾期天数是唯一会改变今天动作的数字，
    // 档数和忘过几次挪进 Tooltip（长按），完整那串原来 20 来个字把单词挤得没位置。
    final brief = word.isNew
        ? '新词'
        : (late > 0 ? '逾期 $late 天' : '第 ${rec!.box + 1}/${kGapDays.length} 档');
    final tag = word.isNew
        ? '新词，学完当天不复习'
        : '第 ${rec!.box + 1}/${kGapDays.length} 档'
              '${late > 0 ? '  逾期 $late 天' : ''}'
              '${rec.lapses > 0 ? '  忘过 ${rec.lapses} 次' : ''}';

    return Opacity(
      // 推送途中整列置灰：勾选和标记这时候点了也不会写进这次的表。
      opacity: enabled ? 1 : 0.45,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 6),
        child: DecoratedBox(
          decoration: Hard.frame(Hard.bg),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (onToggle != null)
                  Checkbox(
                    value: selected,
                    // 默认那个 48 宽的触摸区把这一行挤掉了两个字的位置；行本身够高够点。
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: enabled ? (_) => onToggle!() : null,
                  )
                else
                  const SizedBox(width: 2),
                Expanded(
                  child: Tooltip(
                    message: '${entry.word}  $tag',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            // 状态那串不给 flex：Flex 先量非弹性孩子，于是它永远整串显示，
                            // 挤不下的时候折的是词组（'sore thr…'），长按 Tooltip 看全名。
                            Flexible(
                              child: Text(
                                entry.word,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: Hard.ink,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              brief,
                              maxLines: 1,
                              style: late > 0
                                  ? Hard.body(context).copyWith(
                                    color: Hard.coral,
                                    fontWeight: FontWeight.w700,
                                  )
                                  : Hard.body(context),
                            ),
                          ],
                        ),
                        if (line.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              line,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Hard.ink,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (!word.isNew && enabled)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      HardMiniButton(
                        icon: Icons.check,
                        tooltip: '记住了',
                        color: Hard.blue,
                        onPressed: () => onMark(word, true),
                      ),
                      const SizedBox(width: 4),
                      HardMiniButton(
                        icon: Icons.close,
                        tooltip: '没想起来',
                        color: Hard.coral,
                        onPressed: () => onMark(word, false),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 最近两周每天上设备的词数。原来那根柱子画的是"打了几个勾"，可推 30 词和推 12 词
/// 在图上只是两根高低不同的柱子，看着不知道在说什么；而"推了几个"这件事设备不会
/// 主动汇报，只有推送成功时记下的那笔。所以格子按那个数当大字，打勾数降成辅助小字。
class DayGrid extends StatelessWidget {
  const DayGrid({super.key, required this.stats, this.today});

  final List<DayStat> stats;

  /// 只有落在这一天的格子会换蓝框，别的格子不区分。
  final DateTime? today;

  /// 推上设备了、但一个勾都没打。amber 的浅底版：amber 本身已经归"已毕业"用。
  static const Color _pushedOnly = Color(0xFFFBEFD6);

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    // 七个一行：两行正好两周，而且第二行开头和第一行开头是同一个星期几。
    for (var i = 0; i < stats.length; i += 7) {
      final week = stats.sublist(i, i + 7 > stats.length ? stats.length : i + 7);
      rows.add(
        Row(
          children: [
            for (var c = 0; c < 7; c++)
              Expanded(
                child: c < week.length
                    ? _cell(context, week[c], i + c)
                    : const SizedBox(height: 50),
              ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 4), child: r),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '大字 = 那天推上设备的词数   小字 = 手机上打的勾   '
            '空心 = 那天没推   蓝框 = 今天',
            style: Hard.body(context),
          ),
        ),
      ],
    );
  }

  Widget _cell(BuildContext context, DayStat s, int index) {
    final n = s.pushed.length;
    final touched = s.touched;
    final isToday = today != null && dayOf(s.day) == dayOf(today!);
    return Padding(
      // 第一列往左让 2px，整排才和卡片里的别的文字对齐。
      padding: EdgeInsets.fromLTRB(index % 7 == 0 ? 0 : 2, 0, 2, 0),
      child: Tooltip(
        message:
            '${s.day.month}-${s.day.day}  推 $n'
            '  记住 ${s.marked.length}  忘 ${s.forgotten.length}',
        child: DecoratedBox(
          decoration: BoxDecoration(
            // 三种底色就一个轴：那天到底有没有动静。
            color: n == 0 && touched == 0
                ? Hard.bg
                : (touched == 0 ? _pushedOnly : Hard.sheet),
            border: Border.all(width: 2, color: isToday ? Hard.blue : Hard.ink),
            borderRadius: BorderRadius.circular(5),
          ),
          child: SizedBox(
            height: 50,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${s.day.day}',
                  style: const TextStyle(
                    fontSize: 9,
                    color: Hard.muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  n == 0 ? '·' : '$n',
                  style: TextStyle(
                    fontSize: 17,
                    height: 1.05,
                    fontWeight: FontWeight.w900,
                    color: n == 0 ? Hard.muted : Hard.ink,
                  ),
                ),
                if (touched > 0)
                  Text(
                    '勾 $touched',
                    style: const TextStyle(
                      fontSize: 9,
                      color: Hard.muted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
