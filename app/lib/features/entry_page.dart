import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/protocol.dart';
import '../core/word_prompt.dart';
import '../data/lexicon.dart';
import '../data/schedule.dart';
import '../data/wordbook_store.dart';
import '../ui/hard_style.dart';

class EntryPage extends StatefulWidget {
  const EntryPage({super.key});

  @override
  State<EntryPage> createState() => _EntryPageState();
}

/// 待定词条。查到之前它是唯一能改的地方，所以先不转成不可变的 WordEntry，
/// 保存那一刻才转。
class _Draft {
  _Draft(
    this.word, {
    this.phonetic = '',
    this.meaning = '',
    this.example = '',
    this.syllable = '',
  });

  String word;
  String phonetic = '';
  String meaning = '';
  String example = '';
  String syllable = '';
  String error = '';
  bool including = true;

  WordEntry toEntry() => WordEntry(
    word: word,
    phonetic: phonetic,
    meaning: meaning,
    example: example,
    syllable: syllable,
  );

  List<String> overlong() => toEntry().overlong();

  /// 查到什么补什么，查不到的字段留着 —— 从粘贴或 AI 带来的内容
  /// 不能被一次失败的查询抹平。要清空就自己进编辑框改。
  void apply(LexiconHit hit) {
    error = hit.error;
    if (hit.error.isNotEmpty) return;
    if (hit.phonetic.isNotEmpty) phonetic = hit.phonetic;
    if (hit.meaning.isNotEmpty) meaning = hit.meaning;
    if (hit.example.isNotEmpty) example = hit.example;
  }
}

class _EntryPageState extends State<EntryPage> {
  final _paste = TextEditingController();
  late final TextEditingController _label;

  /// 这批词记在哪个来源下。课本按单元录、新东方一周一次课，来源只当分组和显示，
  /// 不参与排日子 —— 每天抽哪一批是计划页那个选择器的事。
  /// 列表本身在设定页里改，所以初值取 store 的第一个，不写死常量。
  String _source = kDefaultSource;
  final List<_Draft> _rows = [];
  Lexicon? _lexicon;
  bool _looking = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    // 批次名现在是主键（文件名 + 记忆档案归属），预填一个周号只会诱导他照单全收，
    // 所以留空，这名字得是他自己起的。
    _label = TextEditingController();
    _label.addListener(_syncSourceToLabel);
    _source = context.read<WordbookStore>().defaultSource;
  }

  /// 批次名是跨来源唯一的（文件名就按它找）。往一个已有的名字里补录时，
  /// 来源跟着那张表走，不然一次手滑就把整本"课本 Unit 3"改姓到新东方底下了。
  void _syncSourceToLabel() {
    final book = context.read<WordbookStore>().byLabel(_label.text.trim());
    if (book == null || book.source == _source) return;
    setState(() => _source = book.source);
  }

  @override
  void dispose() {
    _paste.dispose();
    _label.dispose();
    _lexicon?.close();
    super.dispose();
  }

  List<_Draft> get _picked =>
      _rows.where((r) => r.including && r.word.trim().isNotEmpty).toList();

  _Draft? _draftOf(String word) {
    final key = word.toLowerCase();
    for (final row in _rows) {
      if (row.word.toLowerCase() == key) return row;
    }
    return null;
  }

  Future<void> _extractAndFill() async {
    if (_looking) return;
    final rows = parsePastedRows(_paste.text);
    if (rows.isEmpty) {
      setState(() => _message = '没抠到单词，检查下粘进来的是不是英文词条');
      return;
    }
    final fresh = <PastedRow>[
      for (final r in rows)
        if (_draftOf(r.entry.word) == null) r,
    ];
    final todo = [
      for (final r in fresh)
        if (r.needsLookup) r.entry.word,
    ];
    final skipped = rows.length - fresh.length;
    final inline = fresh.length - todo.length;
    setState(() {
      _message = [
        if (skipped > 0) '$skipped 个词已经在列表里，这次跳过',
        if (inline > 0) '$inline 个词直接用粘进来的内容，没查有道',
      ].join('；');
      _rows.addAll([
        for (final r in fresh)
          _Draft(
            r.entry.word,
            phonetic: r.entry.phonetic,
            meaning: r.entry.meaning,
            example: r.entry.example,
            syllable: r.entry.syllable,
          ),
      ]);
      _looking = todo.isNotEmpty;
    });
    if (todo.isEmpty) return;
    // 查到一条刷一条：一批十几个词全等完要好几秒，先看到的就能先检查。
    await (_lexicon ??= Lexicon()).lookupAll(
      todo,
      onHit: (hit) {
        if (!mounted) return;
        setState(() => _draftOf(hit.word)?.apply(hit));
      },
    );
    if (mounted) setState(() => _looking = false);
  }

  Future<void> _retry(_Draft row) async {
    if (_looking) return;
    final hit = await (_lexicon ??= Lexicon()).lookup(row.word);
    if (!mounted) return;
    setState(() => row.apply(hit));
  }

  Future<void> _edit(_Draft row) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _EditDialog(draft: row),
    );
    if (mounted) setState(() {});
  }

  /// 他的录入口径：拍单词表 → 连同这段提示词发给豆包 → 结果粘回上面那个框。
  /// 提示词存在 app 里（`core/word_prompt.dart`），不用他去翻电脑上那个 txt。
  Future<void> _showPrompt() async {
    final copied = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('拍照发给 AI 的提示词'),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              kAiWordPrompt.trim(),
              style: Hard.body(context).copyWith(fontSize: 12.5, height: 1.5),
            ),
          ),
        ),
        actions: [
          HardButton(
            label: '关掉',
            onPressed: () => Navigator.of(context).pop(false),
          ),
          HardButton(
            label: '复制',
            fill: Hard.blue,
            onColor: Colors.white,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (copied != true || !mounted) return;
    await Clipboard.setData(ClipboardData(text: kAiWordPrompt.trim()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('复制好了。连同单词表照片发给豆包，把它的回答整段粘回上面那个框')),
    );
  }

  /// 同 label 时让他选：覆盖会丢掉旧词，追加会顶掉同名旧词但保留其余。
  Future<String?> _resolveConflict(String label, WeekBook existing) {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$label 已经存过了'),
        content: HardPanel(
          child: Text(
            '旧表 ${existing.words.length} 词，改于 ${_stamp(existing.updatedAt)}。\n'
            '覆盖：以这次录入的 ${_picked.length} 词为准；\n'
            '追加：旧的留着，同名的词用新的顶掉。',
            style: Hard.body(context).copyWith(height: 1.5),
          ),
        ),
        actions: [
          HardButton(label: '取消', onPressed: () => Navigator.of(context).pop()),
          HardButton(
            label: '追加',
            onPressed: () => Navigator.of(context).pop('append'),
          ),
          HardButton(
            label: '覆盖',
            fill: Hard.coral,
            onColor: Colors.white,
            onPressed: () => Navigator.of(context).pop('replace'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (_looking) return;
    final store = context.read<WordbookStore>();
    final label = _label.text.trim();
    final picked = _picked;
    if (label.isEmpty) {
      setState(() => _message = '先给这批起个名字');
      return;
    }
    if (picked.isEmpty) {
      setState(() => _message = '一个词都没勾上');
      return;
    }
    final existing = store.byLabel(label);
    String? mode = 'replace';
    if (existing != null) {
      mode = await _resolveConflict(label, existing);
      if (mode == null || !mounted) return;
    }

    final merged = <String, WordEntry>{};
    if (mode == 'append') {
      for (final e in existing!.words) {
        merged[e.word.toLowerCase()] = e;
      }
    }
    // 音节是他一条条手敲的，重查有道带不回来。同 label 再录一次时先按旧表补上，
    // 别让一次"覆盖"把上次敲的拆分悄悄冲掉。
    final prior = <String, WordEntry>{
      if (existing != null)
        for (final e in existing.words) e.word.toLowerCase(): e,
    };
    for (final r in picked) {
      final entry = r.toEntry();
      final before = prior[entry.word.toLowerCase()];
      merged[entry.word.toLowerCase()] =
          entry.syllable.isEmpty && before != null && before.syllable.isNotEmpty
          ? WordEntry(
              word: entry.word,
              phonetic: entry.phonetic,
              meaning: entry.meaning,
              example: entry.example,
              syllable: before.syllable,
            )
          : entry;
    }
    final words = merged.values.toList();

    // audioMark 记的是"设备上已经是这一份发音"。覆盖 = 表整个换了，旧标记不作数；
    // 追加保留旧词，标记只能跟着还活着的 slug 走，不然推送页会跳过一个设备上根本没有的词。
    final old = mode == 'append' ? existing!.audioMark : <String, String>{};
    final marks = <String, String>{
      for (final e in words)
        if (old.containsKey(e.slug)) e.slug: old[e.slug]!,
    };

    // 记忆档案按单词文本认人。覆盖时旧表整个作废，改了拼法的那个词在新表里是生面孔，
    // 档案就没人认领 —— 练到第 5 档会一夜清零。先让 store 认一遍（只认差一个字母的，
    // 认不出就不动），剩下的死档案由排期那边的词池口径挡在汇总数字外面。
    final rehomed = <String>[];
    if (existing != null && mode == 'replace') {
      final fresh = {for (final e in words) e.word.toLowerCase()};
      rehomed.addAll(
        await context.read<ScheduleStore>().rehomeOrphans(
          [
            for (final e in existing.words)
              if (!fresh.contains(e.word.toLowerCase())) e.word,
          ],
          [for (final e in words) e.word],
        ),
      );
    }

    await store.save(
      WeekBook(
        label: label,
        source: _source,
        version: WeekBook.nextVersion(),
        updatedAt: DateTime.now(),
        words: words,
        audioMark: marks,
      ),
    );
    if (!mounted) return;
    final moved = rehomed.isEmpty
        ? ''
        : '\n进度跟着新拼法搬过去：${rehomed.join('、')}';
    setState(
      () => _message = '已存 $label（${words.length} 词，${marks.length} 个发音已在设备上）$moved',
    );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label 已保存，${words.length} 词')));
  }

  static String _stamp(DateTime when) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${when.month}-${when.day} ${two(when.hour)}:${two(when.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<WordbookStore>();
    // 设定里删掉的来源，已有批次还顶着那个名字；补录时要看得见，也点得回去。
    final choices = store.sources.contains(_source)
        ? store.sources
        : [...store.sources, _source];
    final truncated = _picked.where((r) => r.overlong().isNotEmpty).length;
    final filled = _rows
        .where((r) => r.phonetic.isNotEmpty || r.meaning.isNotEmpty)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('录入单词'),
        actions: [
          HardIconButton(
            icon: Icons.delete_sweep_outlined,
            tooltip: '清空列表',
            onPressed: _rows.isEmpty || _looking
                ? null
                : () => setState(() {
                    _rows.clear();
                    _message = '';
                  }),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          HardCard(
            margin: Hard.gutter(bottom: 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _paste,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    fillColor: Hard.bg,
                    labelText: '粘进来：AI 按提示词整理的成品行，或课本上的一坨单词',
                    hintText:
                        'cold|/kəʊld/|adj. 寒冷的|It is cold outside today.|cold\n'
                        '只有一行的带中文也认；光秃秃的单词才去查有道',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: HardButton(
                      label: '拍照发给 AI 的提示词',
                      onPressed: _showPrompt,
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _label,
                        decoration: const InputDecoration(
                          fillColor: Hard.bg,
                          labelText: '这批叫什么',
                          hintText: '课本填 Unit 3，新东方填 10-11 那节课',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    HardButton(
                      label: _looking ? '查询中…' : '抠词并补全',
                      fill: Hard.blue,
                      onColor: Colors.white,
                      onPressed: _looking ? null : _extractAndFill,
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('来源', style: Hard.label(context)),
                      for (final s in choices)
                        HardChip(
                          text: s,
                          on: _source == s,
                          onTap: () => setState(() => _source = s),
                        ),
                    ],
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
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                HardTag(text: '${_rows.length} 条'),
                const SizedBox(width: 6),
                HardTag(text: '已补全 $filled 条'),
                const Spacer(),
                if (_looking)
                  const HardTag(
                    text: '查有道中…',
                    fill: Hard.blue,
                    on: Colors.white,
                  )
                else if (truncated > 0)
                  HardTag(
                    text: '$truncated 条会被设备截断',
                    fill: Hard.coral,
                    on: Colors.white,
                  ),
              ],
            ),
          ),
          Expanded(
            child: _rows.isEmpty
                ? Center(child: Text('列表是空的，粘一批词进来', style: Hard.body(context)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    itemCount: _rows.length,
                    itemBuilder: (context, index) => _row(_rows[index]),
                  ),
          ),
          Padding(
            padding: Hard.gutter(top: 4),
            child: HardButton(
              expand: true,
              label: _picked.isEmpty ? '保存' : '保存 ${_picked.length} 词',
              fill: Hard.blue,
              onColor: Colors.white,
              onPressed: _looking || _picked.isEmpty ? null : _save,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(_Draft row) {
    final bad = row.overlong();
    final line = [
      if (row.syllable.isNotEmpty) row.syllable,
      if (row.phonetic.isNotEmpty) row.phonetic,
      if (row.meaning.isNotEmpty) row.meaning,
    ].join('  ');
    return Opacity(
      // 没勾上的词整行压暗：保存时它不会进表，别让人以为会。
      opacity: row.including ? 1 : 0.45,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: DecoratedBox(
          decoration: Hard.frame(Hard.bg),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () => _edit(row),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 8, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: row.including,
                      onChanged: _looking
                          ? null
                          : (v) => setState(() => row.including = v ?? true),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.word,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Hard.ink,
                            ),
                          ),
                          if (line.isNotEmpty)
                            Text(
                              line,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Hard.ink,
                              ),
                            ),
                          if (row.example.isNotEmpty)
                            Text(
                              row.example,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Hard.body(context),
                            ),
                          if (row.error.isNotEmpty)
                            Text('查不到：${row.error}', style: Hard.flag(context)),
                          if (row.error.isEmpty && line.isEmpty)
                            Text(
                              '没查到内容，点开自己填',
                              style: Hard.body(
                                context,
                              ).copyWith(fontWeight: FontWeight.w700),
                            ),
                          if (bad.isNotEmpty)
                            Text(bad.join('  '), style: Hard.flag(context)),
                        ],
                      ),
                    ),
                    HardMiniButton(
                      icon: Icons.search,
                      color: Hard.blue,
                      tooltip: '重新查有道',
                      onPressed: _looking ? null : () => _retry(row),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EditDialog extends StatefulWidget {
  const _EditDialog({required this.draft});

  final _Draft draft;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final TextEditingController _word = TextEditingController(
    text: widget.draft.word,
  );
  late final TextEditingController _phonetic = TextEditingController(
    text: widget.draft.phonetic,
  );
  late final TextEditingController _meaning = TextEditingController(
    text: widget.draft.meaning,
  );
  late final TextEditingController _example = TextEditingController(
    text: widget.draft.example,
  );
  late final TextEditingController _syllable = TextEditingController(
    text: widget.draft.syllable,
  );

  @override
  void dispose() {
    _word.dispose();
    _phonetic.dispose();
    _meaning.dispose();
    _example.dispose();
    _syllable.dispose();
    super.dispose();
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    int maxLines = 1,
    String? helper,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: controller,
        minLines: 1,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 2,
          fillColor: Hard.bg,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('改 ${widget.draft.word}'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field('单词', _word),
              _field('音标', _phonetic),
              _field(
                '音节拆分',
                _syllable,
                helper:
                    '用 - 或 · 分开，例 um-bre-lla。留空设备上就不画这一行；'
                    '它和音标共用设备那 95 字节，超了会在列表里标红。',
              ),
              _field('中文释义', _meaning),
              _field('例句', _example, maxLines: 3),
            ],
          ),
        ),
      ),
      actions: [
        HardButton(label: '取消', onPressed: () => Navigator.of(context).pop()),
        HardButton(
          label: '好',
          fill: Hard.blue,
          onColor: Colors.white,
          onPressed: () {
            final draft = widget.draft;
            draft.word = _word.text.trim();
            draft.phonetic = _phonetic.text.trim();
            draft.syllable = normalizeSyllable(_syllable.text);
            draft.meaning = _meaning.text.trim();
            draft.example = _example.text.trim();
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}
