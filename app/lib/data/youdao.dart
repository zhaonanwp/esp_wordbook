import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/protocol.dart';

class AudioBlob {
  AudioBlob(this.format, this.bytes);
  final String format;
  final Uint8List bytes;
  int get length => bytes.length;
}

/// 发音来源：有道 dictvoice。非官方、无维护承诺，所以抓到的都落本地缓存，
/// 而且失败要能跳过——不能因为一个词抓不到就整周推不上去。
class Youdao {
  Youdao(this._cacheDir, {http.Client? client})
    : _client = client ?? http.Client();

  static const String _ua = 'Mozilla/5.0 (wordcard-sync)';

  /// 美音。英音（type=1）实测 32 词里有 8 个回 100KB+ 的 WAV，美音（type=2）32/32 全是
  /// 9-13KB 的 MP3。换口音必须连缓存文件名一起换，否则会一直命中旧的英音那份、crc 都不变。
  static const String _voice = 'us';
  static const String _voiceType = '2';

  final Directory _cacheDir;
  final http.Client _client;

  File _cacheFile(String slug, String fmt) =>
      File('${_cacheDir.path}/$slug.$_voice.$fmt');

  Future<AudioBlob?> cached(String word) async {
    final slug = WordEntry(word: word).slug;
    if (slug.isEmpty) return null;
    for (final fmt in ['mp3', 'wav']) {
      final file = _cacheFile(slug, fmt);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final detected = detectAudioFormat(bytes);
        if (detected != null) {
          return AudioBlob(detected, Uint8List.fromList(bytes));
        }
      }
    }
    return null;
  }

  Future<AudioBlob> _download(String word) async {
    final uri = Uri.parse(
      'https://dict.youdao.com/dictvoice?type=$_voiceType&audio=${Uri.encodeComponent(word)}',
    );
    final response = await _client
        .get(uri, headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw YoudaoException('$word HTTP ${response.statusCode}');
    }
    final format = detectAudioFormat(response.bodyBytes);
    if (format == null) {
      throw YoudaoException('$word 认不出容器格式');
    }
    return AudioBlob(format, response.bodyBytes);
  }

  Future<AudioBlob?> fetch(String word, {bool cache = true}) async {
    final hit = await cached(word);
    if (hit != null) return hit;
    try {
      final blob = await _download(word);
      if (cache) {
        final slug = WordEntry(word: word).slug;
        final file = _cacheFile(slug, blob.format);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsBytes(blob.bytes, flush: true);
        await tmp.rename(file.path);
      }
      return blob;
    } catch (e) {
      throw e is YoudaoException ? e : YoudaoException('$word 抓取失败：$e');
    }
  }

  void close() => _client.close();
}

class YoudaoException implements Exception {
  YoudaoException(this.message);
  final String message;
  @override
  String toString() => message;
}
