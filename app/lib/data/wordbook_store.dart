import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/protocol.dart';

/// 词库来源。课本按单元录、新东方一周一次课，两种节奏套不进同一个"周"，
/// 所以来源只用来分组和显示，**不参与排日子** —— 每天从哪一批抽新词由人手选。
/// 这两个只是**默认值**：他自己起的名字存在 `documents/sources.json`，设定页能加能改能删。
const List<String> kWordSources = ['课本', '新东方'];
const String kDefaultSource = '课本';

/// 来源名显示在批次前面（`课本 Unit 3`），太长一行就挤没了。
const int kSourceMaxLen = 12;

class WeekBook {
  WeekBook({
    required this.label,
    required this.version,
    required this.updatedAt,
    required this.words,
    this.source = kDefaultSource,
    Map<String, String>? audioMark,
  }) : audioMark = audioMark ?? {};

  /// 批次名，他自己起（`Unit 3`、`10-11 那节课`、`2026W42`）。跨来源唯一，
  /// 因为文件名和记忆档案的归属都按它找。
  final String label;
  final String source;
  final String version;
  final DateTime updatedAt;
  final List<WordEntry> words;

  /// 已经确认躺在设备上的那份发音：slug → "容器:crc32"。整批重推时按它跳过，
  /// 一个词省 5-7 秒。跑了 flash-all 把 storage 格掉之后这份记录会失真，
  /// 所以推送页留了"强制重推"开关。
  final Map<String, String> audioMark;

  /// 和某个词的当前发音内容一一对应的指纹。
  static String markOf(String fmt, int crc) => '$fmt:$crc';

  String get title => '$source $label（${words.length} 词）';

  /// 只换来源，其余原样 —— 批次管理里改分组用这个。
  WeekBook withSource(String source) => WeekBook(
    label: label,
    source: source,
    version: version,
    updatedAt: updatedAt,
    words: words,
    audioMark: audioMark,
  );

  /// 有多少个词的字段会被设备静默截断。
  int get overlongCount => words.where((w) => w.overlong().isNotEmpty).length;

  Map<String, dynamic> toJson() => {
    'label': label,
    'source': source,
    'version': version,
    'updatedAt': updatedAt.toIso8601String(),
    'words': words.map((w) => w.toJson()).toList(),
    'audioMark': audioMark,
  };

  factory WeekBook.fromJson(Map<String, dynamic> json) => WeekBook(
    label: (json['label'] ?? '') as String,
    // 加 source 之前存的那几本没有这一项，按课本算，不用他回去补。
    source: ((json['source'] ?? '') as String).isEmpty
        ? kDefaultSource
        : json['source'] as String,
    version: (json['version'] ?? '') as String,
    updatedAt:
        DateTime.tryParse((json['updatedAt'] ?? '') as String) ??
        DateTime.now(),
    words: ((json['words'] ?? []) as List)
        .map((e) => WordEntry.fromJson(e as Map<String, dynamic>))
        .toList(),
    // 老周表文件里没这一项，`?? {}` 给的是 _Map<dynamic,dynamic>，
    // 直接 cast 成 Map<String,dynamic> 会当场炸，所以按 Map? 接再映射。
    audioMark: (json['audioMark'] as Map? ?? {}).map(
      (k, v) => MapEntry('$k', '$v'),
    ),
  );

  static String nextVersion() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  static String weekLabel([DateTime? when]) {
    final day = when ?? DateTime.now();
    final ordinal = day.difference(DateTime(day.year, 1, 1)).inDays + 1;
    var week = ((ordinal - day.weekday + 10) / 7).floor();
    var year = day.year;
    if (week < 1) {
      year -= 1;
      week = _weeksIn(year);
    } else if (week > _weeksIn(year)) {
      year += 1;
      week = 1;
    }
    return '${year}W${week.toString().padLeft(2, '0')}';
  }

  /// ISO-8601：看该年 12 月 28 日落在第几周，它一定在本年的最后一周里。
  static int _weeksIn(int year) {
    final dec28 = DateTime(year, 12, 28);
    final ordinal = dec28.difference(DateTime(year, 1, 1)).inDays + 1;
    return ((ordinal - dec28.weekday + 10) / 7).floor();
  }
}

/// 历史记录就在手机上：documents/weeks/<批次名>.json，一批一个文件。
/// 目录名还叫 weeks 是历史包袱 —— 里面早就不止按周分的了。
class WordbookStore extends ChangeNotifier {
  WordbookStore();

  Directory? _root;
  final List<WeekBook> _weeks = [];

  List<WeekBook> get weeks => List.unmodifiable(_weeks);

  /// 来源列表。没 init 之前就是那两个默认值，单测只走内存、不落盘。
  final List<String> _sources = List.of(kWordSources);
  List<String> get sources => List.unmodifiable(_sources);

  /// documents/sources.json。null 表示还没 init，改了也不写文件。
  String? _sourcesPath;

  Directory? get audioDir => _audioDir;
  Directory? _audioDir;

  String statusLine = '';

  bool _ready = false;
  bool get ready => _ready;

  Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    _root = Directory('${docs.path}/weeks');
    _audioDir = Directory('${docs.path}/audio');
    await _root!.create(recursive: true);
    await _audioDir!.create(recursive: true);
    _sourcesPath = '${docs.path}/sources.json';
    await _loadSources();
    await reload();
    if (_weeks.isEmpty) {
      await seedFromAsset();
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> reload() async {
    final dir = _root;
    if (dir == null) return;
    _weeks.clear();
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        _weeks.add(WeekBook.fromJson(json));
      } catch (e) {
        debugPrint('WordbookStore: 读不动 ${entity.path}: $e');
        statusLine = '有个词库文件读不了：${entity.path}';
      }
    }
    // 批次名是他自己起的，"Unit 9" 和 "Unit 10" 按字面排会倒挂，所以按改动时间排，
    // 同一秒内建的（测试里常见）再按名字兜底，保证顺序可重现。
    _weeks.sort(
      (a, b) => b.updatedAt != a.updatedAt
          ? b.updatedAt.compareTo(a.updatedAt)
          : b.label.compareTo(a.label),
    );
    notifyListeners();
  }

  /// 第一次跑没有历史，就把固件那份样例词表导进来，推送链路立刻可测。
  Future<void> seedFromAsset() async {
    String text;
    try {
      text = await rootBundle.loadString('assets/words.tsv');
    } catch (e) {
      statusLine = '内置样例词表读不到：$e';
      notifyListeners();
      return;
    }
    final words = parseTsv(text);
    if (words.isEmpty) return;
    await save(
      WeekBook(
        label: WeekBook.weekLabel(),
        version: WeekBook.nextVersion(),
        updatedAt: DateTime.now(),
        words: words,
      ),
    );
  }

  /// 批次名进文件名，得防着斜杠冒号这类不能进路径的字符。
  /// 注意：`Unit 3` 和 `Unit_3` 会洗成同一个文件 —— 后存的顶掉先存的。
  /// 录入页本来就按名字判重（覆盖/追加那个对话框），所以真撞上的时候他会看到提示。
  static String fileSafe(String label) {
    final s = label.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    return s.replaceAll(RegExp(r'^_+|_+$'), '').isEmpty ? '未命名' : s;
  }

  File _fileFor(String label) => File('${_root!.path}/${fileSafe(label)}.json');

  WeekBook? byLabel(String label) {
    for (final b in _weeks) {
      if (b.label == label) return b;
    }
    return null;
  }

  Future<void> save(WeekBook book) async {
    await _write(book);
    await reload();
  }

  /// 落一个文件但不重读整目录 —— 改名那种要连着写好几个批次的地方用它，
  /// 不然每写一本都 reload 一次。
  Future<void> _write(WeekBook book) async {
    final root = _root;
    if (root == null) return;
    final file = _fileFor(book.label);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(book.toJson()), flush: true);
    await tmp.rename(file.path);
  }

  Future<void> delete(String label) async {
    final file = _fileFor(label);
    if (await file.exists()) {
      await file.delete();
    }
    await reload();
  }

  // ---- 来源：设定页管的就是这一列 ----

  /// 录入页的兜底 —— 列表里一个都没有时用第一个，别拿内置常量去比。
  String get defaultSource =>
      _sources.isEmpty ? kDefaultSource : _sources.first;

  /// 某个来源现在挂了几批、几词。
  ({int books, int words}) usageOf(String source) {
    var books = 0;
    var words = 0;
    for (final b in _weeks) {
      if (b.source != source) continue;
      books++;
      words += b.words.length;
    }
    return (books: books, words: words);
  }

  /// 加一个来源。返回 null 是成了，否则是把原因还给他显示。
  Future<String?> addSource(String raw) async {
    final name = raw.trim();
    if (name.isEmpty) return '先给这个来源起个名字';
    if (name.length > kSourceMaxLen) return '名字别超过 $kSourceMaxLen 个字';
    if (_sources.contains(name)) return '已经有「$name」了';
    _sources.add(name);
    await _saveSources();
    notifyListeners();
    return null;
  }

  /// 改名。来源既不是文件名也不是记忆档案的外键，所以敢连带改：
  /// 用它的那几批跟着换姓，词、发音标记和排期都不动。
  Future<String?> renameSource(String from, String to) async {
    final name = to.trim();
    if (name == from) return null;
    if (name.isEmpty) return '先给这个来源起个名字';
    if (name.length > kSourceMaxLen) return '名字别超过 $kSourceMaxLen 个字';
    if (_sources.contains(name)) return '已经有「$name」了';
    final i = _sources.indexOf(from);
    if (i < 0) return '没找到「$from」';
    _sources[i] = name;
    await _saveSources();
    for (var k = 0; k < _weeks.length; k++) {
      if (_weeks[k].source != from) continue;
      final book = _weeks[k].withSource(name);
      _weeks[k] = book;
      await _write(book);
    }
    notifyListeners();
    return null;
  }

  /// 删来源**不动批次**：那几批只是顶着一个不在列表里的名字继续显示，
  /// 想归到别处去批次管理里改，或者把这个名字再加回来。
  Future<String?> removeSource(String name) async {
    if (_sources.length <= 1) return '至少留一个来源，录入时总得有个地方放';
    _sources.remove(name);
    await _saveSources();
    notifyListeners();
    return null;
  }

  /// 读不到、读出来是空的，都退回内置那两个默认值 —— 录入页不能没得选。
  Future<void> _loadSources() async {
    final path = _sourcesPath;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    List<String> read;
    try {
      read =
          ((jsonDecode(await file.readAsString()) as List)
                  .map((e) => '$e')
                  .toList())
              .where((e) => e.trim().isNotEmpty)
              .map((e) => e.trim())
              .toList();
    } catch (e) {
      debugPrint('WordbookStore: 来源列表读不动 $path: $e');
      statusLine = '来源列表读不了，先用默认的课本/新东方';
      return;
    }
    if (read.isEmpty) return;
    _sources
      ..clear()
      ..addAll(read);
  }

  Future<void> _saveSources() async {
    final path = _sourcesPath;
    if (path == null) return;
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(_sources), flush: true);
    await tmp.rename(path);
  }

  Future<WeekBook> importTsv(String text, {String? label}) async {
    final book = WeekBook(
      label: label ?? WeekBook.weekLabel(),
      version: WeekBook.nextVersion(),
      updatedAt: DateTime.now(),
      words: parseTsv(text),
    );
    await save(book);
    return book;
  }
}
