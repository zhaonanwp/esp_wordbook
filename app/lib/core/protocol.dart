import 'dart:convert';
import 'dart:typed_data';

class WcUuid {
  static const String service = '0000ffe0-0000-1000-8000-00805f9b34fb';
  static const String cmd = '0000ffe1-0000-1000-8000-00805f9b34fb';
  static const String ntf = '0000ffe2-0000-1000-8000-00805f9b34fb';
  static const String data = '0000ffe3-0000-1000-8000-00805f9b34fb';
  static const String deviceName = 'WORDCARD';
}

/// 设备侧 word[64] / phonetic[96] / meaning[192] / example[320] 是 snprintf 进定长
/// 缓冲区的，超了直接截断，不会报错。app 端必须自己拦，否则推上去的词和手机上看的不一样。
class FieldCap {
  static const int word = 63;
  static const int phonetic = 95;
  static const int meaning = 191;
  static const int example = 319;
}

int _utf8Len(String s) => utf8.encode(s).length;

/// 从粘进来的一坨文本里抠词条。课本列表常见三种排版：一行一词、逗号/顿号分隔、
/// 前面带 "1." "2、" 序号，词后面还可能直接跟着中文释义。
/// 短语里的空格必须保住，所以只按换行和标点切，不按空格切。
List<String> parseWordTokens(String text) {
  final out = <String>[];
  final seen = <String>{};
  for (final rawLine in text.split(RegExp(r'[\n\r]+'))) {
    final line = rawLine.replaceFirst(
      RegExp(r'^\s*[（(]?\d+\s*[）)、.．:：\-]\s*'),
      '',
    );
    for (final piece in line.split(RegExp(r'[,，、;；\t]+'))) {
      final word = cleanWordToken(piece);
      if (word.isEmpty) continue;
      if (seen.add(word.toLowerCase())) out.add(word);
    }
  }
  return out;
}

/// 取开头的拉丁词组，丢掉后面粘着的中文；结尾的点号去掉（"a.m." 会成 "a.m"，
/// 设备按 slug 存文件，两者算同一个词）。
String cleanWordToken(String raw) {
  final m = RegExp(r"[A-Za-z][A-Za-z0-9 .'’\-]*").firstMatch(raw.trim());
  if (m == null) return '';
  return m.group(0)!.replaceFirst(RegExp(r'[\s.\-,:;]+$'), '').trim();
}

/// 手敲或从表格粘的音标常见三种脏：西里尔 ә 冒充 schwa、ASCII 撇号冒充重音、
/// ASCII 冒号冒充长音符。设备字库是按 IPA 码点收的，替身字符会显示成空白。
/// 斜杠保留 —— 现有周表里就是 `/kəʊld/` 这种写法。
String normalizePhonetic(String raw) {
  var s = raw.trim();
  s = s.replaceAll('\u04d9', '\u0259');
  s = s.replaceAll("'", '\u02c8');
  s = s.replaceAll(':', '\u02d0');
  if (s.isEmpty) return '';
  if (s.startsWith('/') || s.startsWith('[')) return s;
  return '/$s/';
}

/// 音节拆分手填时的分隔符。手机上敲"·"很别扭，所以 `-` `.` `|` 都当分隔符收，
/// 统一换成 U+00B7 —— IPA 字库收了它（`-r 0x20-0xFF`），设备上画得出来。
/// 词组里的空格不动："jump rope" 拆成 "jump rope" 还是两个词。
String normalizeSyllable(String raw) {
  final parts = raw
      .split(RegExp(r'[-–—.|·]+'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  return parts.join('·');
}

class WordEntry {
  const WordEntry({
    required this.word,
    this.phonetic = '',
    this.meaning = '',
    this.example = '',
    this.syllable = '',
  });

  final String word;
  final String phonetic;
  final String meaning;
  final String example;

  /// 音节拆分，像 `um·bre·lla`。设备一条词条只有四个定长字段、BLE 协议冻着，
  /// 所以它搭音标段一起送（见 [wirePhonetic]），固件按分隔符切开自己画。
  final String syllable;

  /// 音标段里的分隔符。'|' 既不在 IPA 里也不在中文里，老词表没有它就一切照旧。
  static const String kSplitMark = '|';

  /// 推给设备的 `p`，也就是设备上那张 TSV 的第二列。
  String get wirePhonetic =>
      syllable.isEmpty ? phonetic : '$phonetic$kSplitMark$syllable';

  /// 拆回（音标, 音节）。从设备上倒回来的 TSV、和手填成打包形式的，都认。
  static (String, String) unpackPhonetic(String packed) {
    final i = packed.indexOf(kSplitMark);
    if (i < 0) return (packed, '');
    return (packed.substring(0, i), packed.substring(i + 1));
  }

  Map<String, dynamic> toJson() => {
    'w': word,
    'p': phonetic,
    'm': meaning,
    's': example,
    if (syllable.isNotEmpty) 'y': syllable,
  };

  factory WordEntry.fromJson(Map<String, dynamic> json) {
    final (phonetic, packed) = unpackPhonetic((json['p'] ?? '') as String);
    final stored = (json['y'] ?? '') as String;
    return WordEntry(
      word: (json['w'] ?? '') as String,
      phonetic: phonetic,
      meaning: (json['m'] ?? '') as String,
      example: (json['s'] ?? '') as String,
      syllable: stored.isNotEmpty ? stored : packed,
    );
  }

  /// 和设备侧pronouncer 找文件的规则保持一致：非字母数字压成下划线。
  String get slug {
    var s = word.toLowerCase();
    s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    s = s.replaceAll(RegExp(r'^_+|_+$'), '');
    return s;
  }

  String toTsvLine() => [word, wirePhonetic, meaning, example].join('\t');

  /// 返回超长字段的说明，空列表表示都放得下。
  List<String> overlong() {
    final out = <String>[];
    void check(String name, String value, int cap) {
      if (value.isEmpty) return;
      final n = _utf8Len(value);
      if (n > cap) out.add('$name ${n}B>${cap}B');
    }

    check('单词', word, FieldCap.word);
    check('音标+音节', wirePhonetic, FieldCap.phonetic);
    check('释义', meaning, FieldCap.meaning);
    check('例句', example, FieldCap.example);
    return out;
  }

  static WordEntry fromTsvLine(String line) {
    final fields = line.split('\t');
    while (fields.length < 4) {
      fields.add('');
    }
    final (phonetic, packed) = unpackPhonetic(fields[1]);
    return WordEntry(
      word: fields[0],
      phonetic: phonetic,
      meaning: fields[2],
      example: fields[3],
      // 第 5 列是 app 自己导词表用的写法，设备上不存在这一列。
      syllable: fields.length > 4 && fields[4].isNotEmpty ? fields[4] : packed,
    );
  }
}

List<WordEntry> parseTsv(String text) {
  final out = <WordEntry>[];
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trimRight();
    if (line.isEmpty || line.startsWith('#')) continue;
    final entry = WordEntry.fromTsvLine(line);
    if (entry.word.isNotEmpty) out.add(entry);
  }
  return out;
}

final RegExp _chinese = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]');

bool hasChinese(String s) => _chinese.hasMatch(s);

/// 一行粘贴内容解析出来的草稿。[needsLookup] 为真表示这行里没有中文，
/// 也就是只给了单词本身，音标释义还得去查有道。
class PastedRow {
  PastedRow(this.entry, {required this.needsLookup});

  final WordEntry entry;
  final bool needsLookup;
}

/// 录入页那个粘贴框吃两种东西：
/// 1. 课本上抠下来的一坨纯单词（一行一词、逗号分隔、带序号）→ 只给单词，去查表；
/// 2. 拍照丢给 AI 之后吐回来的成品行 `单词|音标|释义|例句|音节拆分` → 行里带中文就照用，
///    不再走网络。他定的规则：粘贴里已经有中文了，就以这份为准。
List<PastedRow> parsePastedRows(String text) {
  final out = <PastedRow>[];
  final seen = <String>{};
  void add(WordEntry e, {required bool lookup}) {
    if (e.word.isEmpty) return;
    if (!seen.add(e.word.toLowerCase())) return;
    out.add(PastedRow(e, needsLookup: lookup));
  }

  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.contains('|')) {
      final f = [for (final p in line.split('|')) p.trim()];
      while (f.length < 5) {
        f.add('');
      }
      add(
        WordEntry(
          word: cleanWordToken(f[0]),
          phonetic: normalizePhonetic(f[1]),
          meaning: f[2],
          example: f[3],
          syllable: normalizeSyllable(f[4]),
        ),
        lookup: !hasChinese(f[2]),
      );
      continue;
    }
    if (hasChinese(line)) {
      // 没按格式来、但行里已经带着中文（课本词表常这样）：抠出单词和音标，
      // 剩下那截整段当释义，同样不再查表。
      final body = line.replaceFirst(
        RegExp(r'^\s*[（(]?\d+\s*[）)、.．:：\-]\s*'),
        '',
      );
      final word = cleanWordToken(body);
      if (word.isEmpty) continue;
      final phonetic = normalizePhonetic(
        RegExp(r'[/\[［]([^\]/］]*)[\]/］]').firstMatch(body)?.group(1) ?? '',
      );
      final tail = body
          .replaceFirst(RegExp(r"^[^A-Za-z]*[A-Za-z][A-Za-z0-9 .'\-]*"), '')
          .replaceFirst(RegExp(r'[/\[［][^\]/］]*[\]/］]'), '')
          .replaceFirst(RegExp(r'^[\s,，、:：;；\-—]+'), '')
          .trim();
      add(
        WordEntry(word: word, phonetic: phonetic, meaning: tail),
        lookup: false,
      );
      continue;
    }
    for (final w in parseWordTokens(line)) {
      add(WordEntry(word: w), lookup: true);
    }
  }
  return out;
}

const int kFrameHeaderLen = 10;

Uint8List buildAudioFrame({
  required int offset,
  required List<int> payload,
  required bool first,
  required bool last,
}) {
  final buf = Uint8List(kFrameHeaderLen + payload.length);
  buf[0] = 0xA5;
  buf[1] = 0x5A;
  buf[2] = 1;
  buf[3] = (first ? 1 : 0) | (last ? 2 : 0);
  final view = ByteData.sublistView(buf);
  view.setUint32(4, offset, Endian.little);
  view.setUint16(8, payload.length, Endian.little);
  buf.setRange(kFrameHeaderLen, buf.length, payload);
  return buf;
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[i] = c;
  }
  return table;
}();

/// 标准 CRC-32，和设备的 ESP 端以及 Python zlib.crc32 一致。
int crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 有道的 Content-Type 对 RIFF/WAVE 也报 audio/mpeg，只能看文件头。
String? detectAudioFormat(List<int> bytes) {
  if (bytes.length < 4) return null;
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46) {
    return 'wav';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0x49 &&
      bytes[1] == 0x44 &&
      bytes[2] == 0x33) {
    return 'mp3';
  }
  if (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) return 'mp3';
  return null;
}
