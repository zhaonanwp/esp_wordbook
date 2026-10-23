import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/device_link.dart';
import '../data/wordbook_store.dart';
import '../ui/hard_style.dart';
import 'entry_page.dart';
import 'push_page.dart';
import 'scan_page.dart';
import 'settings_page.dart';

/// 首页 = 批次播放器。用的节奏是「推一批 → 孩子在设备上自己练 → 练完换下一批」，
/// 所以这里只回答两件事：**设备上现在是哪一批**、**下一批推哪一本**。
///
/// 没有日更排期、没有到期/逾期、没有档位 —— 那套的前提是每天碰一次手机，
/// 而一天不碰它就会攒一堆假的红字逾期。老数据（`documents/schedule.json`）留在
/// 手机上不读也不删，哪天想回到日更那条路还有得接。
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<WordbookStore>();
    final link = context.watch<BleLink>();
    final onDevice = store.byLabel(store.onDevice);

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
          _deviceCard(context, store, onDevice),
          _section(
            context,
            '词库 ${store.weeks.length} 批 / ${store.weeks.fold<int>(0, (n, b) => n + b.words.length)} 词',
            _books(context, store),
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
            on ? Icons.bluetooth_connected
                : Icons.bluetooth_disabled,
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

  /// 「设备上现在这批」是手机记的账：推成功才写，所以格过 storage、或者设备被别的
  /// 手机推过之后它会失真。界面上不装成从设备读回来的 —— 真要核对去推送页那个
  /// 「读设备状态」（`stat` 会回 stored_words）。
  Widget _deviceCard(BuildContext context, WordbookStore store, WeekBook? book) {
    final theme = Theme.of(context);
    return HardCard(
      margin: Hard.gutter(top: 8, bottom: 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '设备上现在这批',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (book != null)
                HardTag(
                  text: '${book.words.length} 词',
                  fill: Hard.blue,
                  on: Colors.white,
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              book == null
                  ? store.onDevice.isEmpty
                        ? '还没推过 —— 从下面挑一本推上去'
                        : '「${store.onDevice}」这批已经不在词库里了（删掉了）'
                  : '${book.source} ${book.label}'
                        '${book.overlongCount == 0 ? '' : '　${book.overlongCount} 词会被设备截断'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Hard.flag(context).copyWith(
                color: book == null ? Hard.coral : Hard.ink,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
          if (book != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '上次推于 ${_stamp(store.onDeviceAt ?? book.updatedAt)}'
                '　发音已在设备 ${book.audioMark.length} 个',
                style: Hard.body(context),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: HardButton(
                    expand: true,
                    label: book == null ? '挑一本推上设备' : '重推这一批',
                    fill: Hard.blue,
                    onColor: Colors.white,
                    // 词库空的时候没有可推的目标，按下去会去抓列表第一本 —— 那是空的。
                    onPressed: store.weeks.isEmpty
                        ? null
                        : () => _open(
                            context,
                            PushPage(
                              label: book?.label ?? store.weeks.first.label,
                            ),
                          ),
                  ),
                ),
              ],
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

  Widget _books(BuildContext context, WordbookStore store) {
    if (store.weeks.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('手机上还没有词库，点右上角「录入」粘一批'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text('点一批 → 把它整个推上设备，换掉现在那张表。', style: Hard.body(context)),
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
              '${b.source} ${b.label}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              '${b.words.length} 词   发音已存 ${b.audioMark.length}   改于 ${_stamp(b.updatedAt)}'
              '${b.label == store.onDevice ? '\n← 设备上就是这批' : ''}'
              '${b.overlongCount == 0 ? '' : '\n${b.overlongCount} 词会被设备截断'}',
              style: Hard.body(
                context,
              ).copyWith(color: b.label == store.onDevice ? Hard.blue : null),
            ),
            onTap: () => _open(context, PushPage(label: b.label)),
            trailing: HardMiniButton(
              icon: Icons.edit_outlined,
              color: Hard.ink,
              tooltip: '改来源 / 删掉',
              onPressed: () => _manage(context, store, b),
            ),
          ),
      ],
    );
  }

  /// 批次名不能改 —— 它就是文件名，改名等于换一本书。所以这里只给来源和删除两件事。
  Future<void> _manage(
    BuildContext context,
    WordbookStore store,
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
                  '改来源只动这一本的分组，词和发音标记都不受影响。',
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
    await _confirmDelete(context, store, book);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WordbookStore store,
    WeekBook book,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删掉 ${book.source} ${book.label}？'),
        content: HardPanel(
          child: Text(
            '这批 ${book.words.length} 词从手机上拿走，'
            '发音缓存留着（重录同名批次还能接上）。\n'
            '${book.label == store.onDevice ? '删的正是设备上现在这批 —— 删完首页就不知道设备上装的是谁了，'
                  '那张表本身还在设备上，要换得推一本上去。\n' : ''}'
            '想整个灌回去，去推送页勾「强制重推」。',
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
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
