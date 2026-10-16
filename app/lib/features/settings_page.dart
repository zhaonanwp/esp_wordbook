import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/schedule.dart';
import '../data/wordbook_store.dart';
import '../ui/hard_style.dart';

/// 设定。两件事：每天上几个新词（从计划页挪过来的，那儿每天要看的东西已经够多了），
/// 以及词库来源那一列是内置的「课本 / 新东方」还是他自己加的。
///
/// 边界要说清楚：来源**只当分组和显示，不参与排日子**，所以改名敢带着那几批一起走；
/// 删掉也不碰词、不碰发音标记、不碰排期，那几批只是顶着一个不在列表里的名字继续显示。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _adding = TextEditingController();
  String _message = '';

  @override
  void dispose() {
    _adding.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final err = await context.read<WordbookStore>().addSource(_adding.text);
    if (!mounted) return;
    setState(() {
      _message = err ?? '';
      if (err == null) _adding.clear();
    });
  }

  Future<void> _rename(WordbookStore store, String from) async {
    final to = await showDialog<String>(
      context: context,
      builder: (context) => _NameDialog(title: '改来源名', initial: from),
    );
    if (to == null || !mounted) return;
    final err = await store.renameSource(from, to);
    if (err == null || !mounted) return;
    setState(() => _message = err);
  }

  Future<void> _remove(WordbookStore store, String name) async {
    final use = store.usageOf(name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删掉来源「$name」？'),
        content: HardPanel(
          child: Text(
            use.books == 0
                ? '这个名字没有批次在用，删了只是录入页那排 chip 里少一个。'
                : '还有 ${use.books} 批（${use.words} 词）挂着这个名字。\n'
                      '删掉不动那些词 —— 它们照样排、照样推，只是列表里不再有这个名字，'
                      '显示的还是「$name …」。\n'
                      '想把它们归到别处，去首页那行的「改来源 / 删掉」里逐批改；'
                      '或者把这个名字再加回来。',
            style: Hard.body(context).copyWith(height: 1.5),
          ),
        ),
        actions: [
          HardButton(
            label: '不删',
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
    final err = await store.removeSource(name);
    if (err == null || !mounted) return;
    setState(() => _message = err);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<WordbookStore>();
    final sched = context.watch<ScheduleStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('设定')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
            child: Text('新词节奏', style: Hard.label(context)),
          ),
          HardCard(
            margin: Hard.gutter(top: 6, bottom: 6),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '每天引入新词 ${sched.newPerDay} 个',
                        style: Hard.label(context),
                      ),
                    ),
                    HardIconButton(
                      icon: Icons.remove,
                      tooltip: '少一点',
                      onPressed: () => sched.setNewPerDay(sched.newPerDay - 1),
                    ),
                    const SizedBox(width: 4),
                    HardIconButton(
                      icon: Icons.add,
                      tooltip: '多一点（最多 30）',
                      onPressed: () => sched.setNewPerDay(sched.newPerDay + 1),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '只管每天上几个新词。到期的复习不受它管，那部分是全局按日子排的。'
                    '改完当天就生效：计划页那张表立刻按新数量重算。',
                    style: Hard.body(context),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
            child: Text('词库来源', style: Hard.label(context)),
          ),
          HardCard(
            margin: Hard.gutter(top: 6, bottom: 6),
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in store.sources)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.only(left: 2),
                    leading: Icon(
                      store.usageOf(s).books == 0
                          ? Icons.folder_open
                          : Icons.folder,
                      size: 20,
                      color: Hard.muted,
                    ),
                    title: Text(
                      s,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(_usage(store, s), style: Hard.body(context)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        HardMiniButton(
                          icon: Icons.edit_outlined,
                          color: Hard.ink,
                          tooltip: '改名',
                          onPressed: () => _rename(store, s),
                        ),
                        const SizedBox(width: 6),
                        HardMiniButton(
                          icon: Icons.delete_outline,
                          color: Hard.coral,
                          tooltip: '删掉',
                          onPressed: () => _remove(store, s),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 10, 2, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _adding,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _add(),
                          decoration: const InputDecoration(
                            fillColor: Hard.bg,
                            labelText: '加一个来源',
                            hintText: '绘本、外研社、学校发的讲义…',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      HardButton(
                        label: '添加',
                        fill: Hard.blue,
                        onColor: Colors.white,
                        onPressed: _add,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Text(
                    '来源只分组、不排日子：每天从哪一批抽新词，是复习计划页那个选择器的事。'
                    '改名会带着用它的那几批一起改；删掉不动词，也不动发音和排期。',
                    style: Hard.body(context),
                  ),
                ),
              ],
            ),
          ),
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(_message, style: Hard.flag(context)),
            ),
        ],
      ),
    );
  }

  String _usage(WordbookStore store, String source) {
    final u = store.usageOf(source);
    if (u.books == 0) return '没有批次在用';
    return '${u.books} 批 / ${u.words} 词';
  }
}

/// 加来源、改来源名共用这一个框。返回 trim 过的名字，取消就是 null。
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, this.initial = ''});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _ok() {
    final name = _text.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: HardPanel(
        child: SizedBox(
          width: 320,
          child: TextField(
            controller: _text,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _ok(),
            decoration: const InputDecoration(
              fillColor: Hard.bg,
              labelText: '名字',
              helperText: '最多 $kSourceMaxLen 个字，显示在批次前面',
            ),
          ),
        ),
      ),
      actions: [
        HardButton(label: '取消', onPressed: () => Navigator.of(context).pop()),
        HardButton(
          label: '好',
          fill: Hard.blue,
          onColor: Colors.white,
          onPressed: _ok,
        ),
      ],
    );
  }
}
