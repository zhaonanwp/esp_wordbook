import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/device_link.dart';
import '../data/sync_runner.dart';
import '../data/wordbook_store.dart';
import '../data/youdao.dart';
import '../ui/hard_style.dart';

/// 整本重推（维护页）。把选中的**一整本周表**原样推上设备，用来兜底：
/// 跑过 flash-all 把 storage 格了、或想把某一批整个灌回设备时用。
///
/// 它**不记排期账**（不调 `introduce`/`recordPush`）—— 推完设备上是这一本，
/// 但明天该推什么仍按计划页走。日常"推今天这张表"在计划页，不在这里。
class PushPage extends StatefulWidget {
  const PushPage({super.key});

  @override
  State<PushPage> createState() => _PushPageState();
}

class _PushPageState extends State<PushPage> {
  String _selected = '';
  bool _withAudio = false;
  bool _forceAudio = false;
  SyncRunner? _runner;
  Youdao? _youdao;

  @override
  void initState() {
    super.initState();
    final store = context.read<WordbookStore>();
    final audioDir = store.audioDir;
    if (audioDir != null) {
      _youdao = Youdao(audioDir);
      _runner = SyncRunner(context.read<BleLink>(), _youdao!);
    }
    if (store.weeks.isNotEmpty) _selected = store.weeks.first.label;
    // SyncRunner 不在 Provider 里，不自己挂监听的话推送期间界面整个冻住：
    // 进度条不动、日志不刷、按钮也不置灰。
    _runner?.addListener(_onRunner);
  }

  void _onRunner() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _runner?.cancel();
    _runner?.removeListener(_onRunner);
    _youdao?.close();
    _runner?.dispose();
    super.dispose();
  }

  Future<void> _push(WeekBook book) async {
    final runner = _runner;
    if (runner == null) return;
    try {
      await runner.push(
        book,
        withAudio: _withAudio,
        forceAudio: _forceAudio,
        persist: context.read<WordbookStore>().save,
      );
    } on LinkException catch (_) {
      // 已经写进日志了
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = context.watch<BleLink>();
    final store = context.watch<WordbookStore>();
    final runner = _runner;
    final book = store.weeks.where((b) => b.label == _selected).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('整本重推'),
        actions: [
          HardIconButton(
            icon: Icons.info_outline,
            tooltip: '读设备状态',
            onPressed: runner == null || !link.connected || runner.busy
                ? null
                : () async {
                    try {
                      await runner.readStat();
                    } on LinkException catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(e.message)));
                      }
                    }
                  },
          ),
          const SizedBox(width: 4),
          HardIconButton(
            icon: Icons.link_off,
            tooltip: '断开',
            onPressed: () async {
              await link.disconnect();
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '把选中的整本词表原样推上设备（维护用）。这一页不记排期账，'
                '日常「推今天这张表」在复习计划页。',
                style: Hard.body(context),
              ),
            ),
          ),
          Padding(
            padding: Hard.gutter(bottom: 0),
            child: Row(
              children: [
                Icon(
                  link.connected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  size: 18,
                  color: link.connected ? Hard.blue : Hard.muted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    link.connected ? link.peerId : '连接已断，回上一页重新连',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Hard.body(context),
                  ),
                ),
                if (link.connected) ...[
                  HardTag(text: 'MTU ${link.mtu}'),
                  const SizedBox(width: 6),
                  HardTag(text: '单条 ${link.chunk}B'),
                ],
              ],
            ),
          ),
          if (store.statusLine.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(store.statusLine, style: Hard.flag(context)),
            ),
          Expanded(
            flex: 3,
            child: store.weeks.isEmpty
                ? Center(child: Text('手机上还没有词库', style: Hard.body(context)))
                : IgnorePointer(
                    ignoring: _runner?.busy ?? false,
                    // 自己画选中块，不用 RadioListTile：推送中途换表只是看着换了，
                    // 真正在推的还是启动那一趟抓住的那张表，所以忙碌时整块要按不动。
                    child: ListView.builder(
                      padding: Hard.gutter(top: 10, bottom: 6),
                      itemCount: store.weeks.length,
                      itemBuilder: (context, index) {
                        final entry = store.weeks[index];
                        final bad = entry.words
                            .where((w) => w.overlong().isNotEmpty)
                            .length;
                        final on = entry.label == _selected;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: DecoratedBox(
                            decoration: Hard.frame(on ? Hard.blue : Hard.bg),
                            child: Row(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Icon(
                                    on
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_off,
                                    size: 20,
                                    color: on ? Colors.white : Hard.muted,
                                  ),
                                ),
                                Expanded(
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: _runner?.busy ?? false
                                        ? null
                                        : () => setState(
                                            () => _selected = entry.label,
                                          ),
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        8,
                                        8,
                                        8,
                                        8,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            entry.title,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w800,
                                              color: on
                                                  ? Colors.white
                                                  : Hard.ink,
                                            ),
                                          ),
                                          Text(
                                            '${entry.words.map((w) => w.word).take(8).join(' ')}'
                                            '${entry.words.length > 8 ? ' …' : ''}'
                                            '${bad > 0 ? '\n有 $bad 个词超长度上限，会被截断' : ''}',
                                            style: Hard.body(context).copyWith(
                                              color: on
                                                  ? Colors.white
                                                  : Hard.muted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          if (book.isNotEmpty && book.first.overlongCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Text('这张表有字段会被设备截断，先改短再推', style: Hard.flag(context)),
            ),
          HardCard(
            margin: Hard.gutter(bottom: 0),
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
            child: Column(
              children: [
                CheckboxListTile(
                  value: _withAudio,
                  onChanged: runner != null && !runner.busy
                      ? (v) => setState(() => _withAudio = v ?? false)
                      : null,
                  title: const Text('同时抓有道发音（约 3 秒/词）'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                if (_withAudio)
                  CheckboxListTile(
                    value: _forceAudio,
                    onChanged: runner != null && !runner.busy
                        ? (v) => setState(() => _forceAudio = v ?? false)
                        : null,
                    title: const Text('强制重推（默认跳过设备上已经是这一份的）'),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
              ],
            ),
          ),
          if (runner != null) ...[
            Padding(
              padding: Hard.gutter(bottom: 0),
              child: HardBar(fraction: runner.progress),
            ),
            if (runner.busy || runner.log.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Text(
                  '${runner.stage}   词 ${runner.wordsDone}/${runner.wordsTotal}'
                  '   发音 ${runner.audioDone}/${runner.audioTotal}'
                  '${runner.audioFailed > 0 ? ' 失败 ${runner.audioFailed}' : ''}'
                  '${runner.audioSkipped > 0 ? ' 跳过 ${runner.audioSkipped}' : ''}'
                  '${runner.currentWord.isEmpty ? '' : '   ▸ ${runner.currentWord}'}',
                  style: Hard.body(context),
                ),
              ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: Hard.gutter(top: 8, bottom: 4),
                child: DecoratedBox(
                  decoration: Hard.frame(Hard.bg),
                  child: runner.log.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              '日志是空的。选一张表按推送，这里才会一行行写。',
                              textAlign: TextAlign.center,
                              style: Hard.body(context),
                            ),
                          ),
                        )
                      : ListView(
                          reverse: true,
                          padding: const EdgeInsets.all(8),
                          children: runner.log
                              .map(
                                (line) => Text(
                                  line,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: Hard.ink,
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                ),
              ),
            ),
            Padding(
              padding: Hard.gutter(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: HardButton(
                      expand: true,
                      label: runner.busy
                          ? '推送中…'
                          : (_withAudio ? '推送词表 + 发音' : '只推词表'),
                      fill: Hard.blue,
                      onColor: Colors.white,
                      onPressed: runner.busy || book.isEmpty || !link.connected
                          ? null
                          : () => _push(book.first),
                    ),
                  ),
                  if (runner.busy) ...[
                    const SizedBox(width: 6),
                    HardButton(label: '停止', onPressed: runner.cancel),
                  ],
                ],
              ),
            ),
          ],
          if (runner == null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('发音目录没准备好', style: Hard.flag(context)),
            ),
        ],
      ),
    );
  }
}
