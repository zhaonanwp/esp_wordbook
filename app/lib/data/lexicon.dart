import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/protocol.dart';

/// 一个词的有道查询结果。error 非空表示没查到或查失败，界面上标红让他手填。
class LexiconHit {
  LexiconHit(
    this.word, {
    this.phonetic = '',
    this.meaning = '',
    this.example = '',
    this.error = '',
  });

  final String word;
  final String phonetic;
  final String meaning;
  final String example;
  final String error;

  bool get filled =>
      error.isEmpty && (phonetic.isNotEmpty || meaning.isNotEmpty);

  WordEntry toEntry() => WordEntry(
    word: word,
    phonetic: phonetic,
    meaning: meaning,
    example: example,
  );
}

/// 有道 jsonapi 查表：音标 + 中文释义 + 例句，一次请求全给。
/// 键路径是 2026-10-12 实测钉下来的，结构全靠防御式取值 ——
/// 短语没有 expand_ec、有的词连 usphone 都没有，不能崩。
class Lexicon {
  Lexicon({http.Client? client}) : _client = client ?? http.Client();

  static const String _ua = 'Mozilla/5.0 (wordcard-sync)';
  static const String _endpoint = 'https://dict.youdao.com/jsonapi';

  /// 卡片一行放得下多少中文没实测过，所以宁少勿多：凑不满就让他自己补，
  /// 总好过推一张 191 字节被设备静默截断的卡。
  static const int _meaningBudget = 80;
  static const int _meaningMaxParts = 3;

  final http.Client _client;

  void close() => _client.close();

  Future<LexiconHit> lookup(String word) async {
    try {
      final uri = Uri.parse('$_endpoint?q=${Uri.encodeComponent(word)}');
      final response = await _client
          .get(uri, headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        return LexiconHit(word, error: 'HTTP ${response.statusCode}');
      }
      final json =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return parse(word, json);
    } on FormatException catch (e) {
      return LexiconHit(word, error: '返回的不是 json：$e');
    } catch (e) {
      return LexiconHit(word, error: '$e');
    }
  }

  /// 小并发跑一批：一个词 94KB，十几个词并发拉开容易被限流。
  Future<List<LexiconHit>> lookupAll(
    List<String> words, {
    int concurrency = 3,
    void Function(LexiconHit hit)? onHit,
  }) async {
    final results = <String, LexiconHit>{};
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= words.length) return;
        final hit = await lookup(words[i]);
        results[words[i]] = hit;
        onHit?.call(hit);
      }
    }

    await Future.wait(
      List.generate(concurrency < 1 ? 1 : concurrency, (_) => worker()),
    );
    return [for (final w in words) results[w]!];
  }

  static LexiconHit parse(String word, Map<String, dynamic> json) {
    final simple = _firstMap(_asMap(json['simple'])?['word']);
    // 短语常常只有一个音标（sore throat 两个都没有），美音缺就退英音：
    // 卡片上留空不如留一个近似口音，他自己会改。
    final us = _asString(simple?['usphone']);
    final phonetic = normalizePhonetic(
      us.isNotEmpty ? us : _asString(simple?['ukphone']),
    );

    final senses = <String>[];
    final examples = <String>[];
    final ec = _firstMap(_asMap(json['ec'])?['word']);
    for (final group in _maps(ec?['trs'])) {
      for (final tr in _maps(group['tr'])) {
        final leaf = _asMap(tr['l']);
        for (final s in _strings(leaf?['i'])) {
          senses.add(s);
        }
        for (final sent in _maps(leaf?['sentence'])) {
          final en = _cleanSentence(_asString(sent['en']));
          if (en.isNotEmpty) examples.add(en);
        }
      }
    }

    // expand_ec 只有单词有，短语走不到这条路。它给的例句更短更口语，排在前面，
    // 但要保持原顺序 —— 逐条 insert(0) 会把整批倒过来。
    final expand = _firstMap(_asMap(json['expand_ec'])?['word']);
    final better = <String>[];
    for (final entry in _maps(expand?['transList'])) {
      final content = _asMap(entry['content']);
      for (final sent in _maps(content?['sents'])) {
        final orig = _cleanSentence(_asString(sent['sentOrig']));
        if (orig.isNotEmpty) better.add(orig);
      }
    }
    examples.insertAll(0, better);

    return LexiconHit(
      word,
      phonetic: phonetic,
      meaning: buildMeaning(senses),
      example: _firstFitting(examples),
    );
  }

  static String _firstFitting(List<String> candidates) {
    for (final c in candidates) {
      if (_bytes(c) <= FieldCap.example) return c;
    }
    return '';
  }

  /// 义项原文是 "adj. 冷的，凉的；冷淡的，冷漠的；…：详细说明"，一串挤在一个字段里。
  /// 按分号拆开挑前几条；单条本身就超预算的（sore throat 那种带冒号长解释）先取
  /// 冒号前的头，凑不下也不能整条空着 —— 设备 191B 装得下，卡片长一点比空白强，
  /// 真超了 overlong() 会标红。
  static String buildMeaning(List<String> senses) {
    final parts = <String>[];
    var used = 0;
    for (final sense in senses) {
      for (final piece in sense.split(RegExp('[；;]'))) {
        var text = piece.trim();
        if (text.isEmpty) continue;
        if (_bytes(text) > _meaningBudget) {
          final head = text.split(RegExp('[：:]')).first.trim();
          if (head.isNotEmpty && _bytes(head) <= _meaningBudget) text = head;
        }
        final cost = _bytes(text) + (parts.isEmpty ? 0 : 1);
        if (used + cost > _meaningBudget || parts.length >= _meaningMaxParts) {
          return parts.isEmpty ? text : parts.join('；');
        }
        parts.add(text);
        used += cost;
      }
    }
    return parts.join('；');
  }

  static String _cleanSentence(String raw) {
    if (raw.isEmpty) return '';
    return raw
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static int _bytes(String s) => utf8.encode(s).length;

  static Map<String, dynamic>? _asMap(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : null;

  /// 有道这几个节点在数组和 {"0": …} 数字键对象之间不统一，两种都接住。
  static List<Map<String, dynamic>> _maps(Object? v) {
    if (v is List) {
      return [
        for (final e in v)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    }
    if (v is Map) {
      final keys =
          v.keys
              .map((k) => '$k')
              .where((k) => RegExp(r'^\d+$').hasMatch(k))
              .toList()
            ..sort((a, b) => int.parse(a).compareTo(int.parse(b)));
      return [
        for (final k in keys)
          if (v[k] is Map) (v[k] as Map).cast<String, dynamic>(),
      ];
    }
    return const [];
  }

  static Map<String, dynamic>? _firstMap(Object? v) {
    final rows = _maps(v);
    return rows.isEmpty ? null : rows.first;
  }

  static List<String> _strings(Object? v) {
    if (v is List) {
      return [
        for (final e in v)
          if (e is String && e.isNotEmpty) e,
      ];
    }
    if (v is String && v.isNotEmpty) return [v];
    return const [];
  }

  static String _asString(Object? v) => v is String ? v : '';
}
