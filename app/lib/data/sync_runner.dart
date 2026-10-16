import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/protocol.dart';
import 'device_link.dart';
import 'round_sync.dart';
import 'wordbook_store.dart';
import 'youdao.dart';

/// 推送状态机，顺序照 tools/ble_push.py：整表替换 → 逐个发音 → 读一次 stat 对账。
class SyncRunner extends ChangeNotifier {
  SyncRunner(this._link, this._youdao);

  final BleLink _link;
  final Youdao _youdao;

  bool _busy = false;
  bool get busy => _busy;
  bool _cancelled = false;
  bool _disposed = false;

  /// 推送中途退出页面，runner 已经 dispose 了但循环还在 await —— 这时候不能再广播了。
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  String stage = '';
  String currentWord = '';
  int wordsDone = 0;
  int wordsTotal = 0;
  int audioDone = 0;
  int audioTotal = 0;
  int audioFailed = 0;
  int audioSkipped = 0;
  int _fileFrames = 0;
  int _fileFramesTotal = 0;

  final List<String> _log = [];
  List<String> get log => List.unmodifiable(_log);

  Map<String, dynamic>? lastStat;

  /// 一个发音文件要发几十帧、四五秒才动一格，光按"第几个词"算进度看着像卡死。
  ///
  /// 抓不到、slug 是空的这些词只加 `audioFailed` 就 continue，所以进度按"处理过几个"
  /// 算而不是按"成功几个"算 —— 否则只要有一个失败，这条永远到不了头，看着就是卡住。
  double get audioFraction {
    if (audioTotal == 0) return 1.0;
    final inFlight = _fileFramesTotal == 0
        ? 0.0
        : _fileFrames / _fileFramesTotal;
    final done = math.min(
      audioDone + audioFailed + inFlight,
      audioTotal.toDouble(),
    );
    return done / audioTotal;
  }

  double get progress {
    if (wordsTotal == 0) return 0;
    final weight = audioTotal == 0 ? 0.15 : 0.6;
    return (wordsDone / wordsTotal) * (1 - weight) + audioFraction * weight;
  }

  void _say(String line) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    _log.add('$ts $line');
    if (_log.length > 400) _log.removeRange(0, _log.length - 400);
    debugPrint('Sync: $line');
    notifyListeners();
  }

  void cancel() {
    if (!_busy) return;
    _cancelled = true;
    _say('已请求停止，当前这条发完就收');
  }

  Future<void> push(
    WeekBook book, {
    required bool withAudio,
    bool forceAudio = false,
    Future<void> Function(WeekBook)? persist,
    /// 先把设备上练完的轮次收回来入账，再推今天这张表。取不成都继续推：
    /// 结果还留在设备的 rounds.tsv 里，下次连接接着取。
    Future<ImportSummary> Function()? collect,
  }) async {
    if (_busy) return;
    _busy = true;
    _cancelled = false;
    wordsDone = 0;
    wordsTotal = book.words.length;
    audioDone = 0;
    audioFailed = 0;
    audioSkipped = 0;
    audioTotal = withAudio ? book.words.length : 0;
    // 上一趟如果死在某个文件的半截，这两个会留着非零值，漏进这一趟的进度里。
    _fileFrames = 0;
    _fileFramesTotal = 0;
    stage = '准备';
    notifyListeners();

    try {
      final tooLong = <String>[];
      for (final entry in book.words) {
        final bad = entry.overlong();
        if (bad.isNotEmpty) tooLong.add('${entry.word}: ${bad.join(', ')}');
      }
      if (tooLong.isNotEmpty) {
        throw LinkException(
          '有 ${tooLong.length} 个词超过设备字段长度，会被截断：\n'
          '${tooLong.take(5).join('\n')}',
        );
      }

      stage = '收结果';
      notifyListeners();
      if (collect != null) {
        _say((await collect()).line);
      }

      stage = '推词表';
      await _link.writeCommand({
        't': 'wb_begin',
        'n': book.words.length,
        'v': book.version,
      });
      await _link.waitFor('wb_begin_ok', const Duration(seconds: 8));
      _say('wb_begin ok，${book.words.length} 词');

      for (final entry in book.words) {
        if (_cancelled) throw LinkException('已停止');
        await _link.writeCommand({
          't': 'wb_word',
          'w': entry.word,
          'p': entry.wirePhonetic,
          'm': entry.meaning,
          's': entry.example,
        });
        wordsDone += 1;
        if (wordsDone == 1 || wordsDone == wordsTotal || wordsDone % 5 == 0) {
          notifyListeners();
        }
      }

      await _link.writeCommand({'t': 'wb_end'});
      final done = await _link.waitFor('wb_done', const Duration(seconds: 20));
      _say('词表已换：设备收到 ${done['n']} 条');
      wordsDone = wordsTotal;

      if (withAudio) {
        stage = '推发音';
        for (final entry in book.words) {
          if (_cancelled) throw LinkException('已停止');
          currentWord = entry.word;
          notifyListeners();
          final slug = entry.slug;
          if (slug.isEmpty) {
            audioFailed += 1;
            _say('跳过 ${entry.word}：slug 是空的');
            continue;
          }
          AudioBlob? blob;
          try {
            blob = await _youdao.fetch(entry.word);
          } catch (e) {
            audioFailed += 1;
            _say('抓不到 ${entry.word}：$e');
            continue;
          }
          if (blob == null) {
            audioFailed += 1;
            _say('抓不到 ${entry.word}');
            continue;
          }
          final crc = crc32(blob.bytes);
          final mark = WeekBook.markOf(blob.format, crc);
          if (!forceAudio && book.audioMark[slug] == mark) {
            // 设备上已经是这一份内容了，整段 BLE 传输省掉（一个词 5-7 秒）。
            audioDone += 1;
            audioSkipped += 1;
            _say('${entry.word} 跳过：设备上就是这份');
            notifyListeners();
            continue;
          }
          await _pushAudio(entry, blob, crc);
          audioDone += 1;
          book.audioMark[slug] = mark;
          // 一个词记一次账：中途失败或掉电，下次重推只补没成的那几个。
          await persist?.call(book);
          notifyListeners();
        }
        _say('发音完成 $audioDone/$audioTotal，失败 $audioFailed，跳过 $audioSkipped');
        currentWord = '';
      }

      stage = '对账';
      await readStat();
      stage = _cancelled ? '已停止' : '好了';
    } on LinkException catch (e) {
      stage = '失败';
      _say('失败：${e.message}');
      rethrow;
    } on YoudaoException catch (e) {
      stage = '失败';
      _say('失败：${e.message}');
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _pushAudio(WordEntry entry, AudioBlob blob, int crc) async {
    final payload = blob.bytes;
    final frameBody = _link.chunk - kFrameHeaderLen;
    if (frameBody <= 0) {
      throw LinkException('单条上限 ${_link.chunk}B 减掉头之后没法装数据');
    }
    await _link.writeCommand({
      't': 'au_begin',
      'w': entry.word,
      'fmt': blob.format,
      'len': payload.length,
      // 已经烧进去的固件把 crc32 经有符号 long 取值，>=0x80000000 会被转坏
      // （字节数对得上、校验不过）。按 int32 的补码发过去，两边都解析得对。
      'crc32': crc > 0x7FFFFFFF ? crc - 0x100000000 : crc,
    });
    _fileFrames = 0;
    _fileFramesTotal = (payload.length + frameBody - 1) ~/ frameBody;
    var auEndSent = false;
    try {
      for (var offset = 0; offset < payload.length; offset += frameBody) {
        if (_cancelled) throw LinkException('已停止');
        final pending = _link.takeError();
        if (pending != null) {
          // 死在第几帧能直接分辨"设备中途废弃了文件"和"链路断了"。
          throw LinkException(
            '${entry.word} 发到第 ${_fileFrames + 1} 帧'
            '（$offset/${payload.length}B）时设备报：$pending',
          );
        }
        final end = (offset + frameBody) > payload.length
            ? payload.length
            : offset + frameBody;
        await _link.writeFrame(
          buildAudioFrame(
            offset: offset,
            payload: payload.sublist(offset, end),
            first: offset == 0,
            last: end >= payload.length,
          ),
        );
        _fileFrames += 1;
        notifyListeners();
      }
      _fileFramesTotal = 0;
      _fileFrames = 0;
      await _link.writeCommand({'t': 'au_end'});
      auEndSent = true;
      try {
        await _link.waitFor('au_done', const Duration(seconds: 30));
      } on LinkException catch (e) {
        // 带上 crc 才能分清"设备算出来的和发过去的不一样"和链路断了。
        throw LinkException(
          '${entry.word} ${payload.length}B crc=0x${crc.toRadixString(16)} → ${e.message}',
        );
      }
    } finally {
      if (!auEndSent) await _abandonAudio();
    }
    _say(
      '${entry.word} ${blob.format} ${(payload.length / 1024).toStringAsFixed(1)}KB',
    );
  }

  /// 半途而废也要收尾：设备只在收到 au_end（或断开连接）时才离开「接收发音」那页，
  /// 固件的 offset 对不上那条路连屏幕提示都不给，于是手机停了、画面一直停在那儿。
  /// 补发的 au_end 大概率换一个 error 回来（这一份本来就短，校验必不过），
  /// 那个 error 必须吃掉 —— 不然它会飘到下一次推送的第一个 waitFor 上，把下一次也顶成失败。
  Future<void> _abandonAudio() async {
    _fileFrames = 0;
    _fileFramesTotal = 0;
    try {
      await _link.writeCommand({'t': 'au_end'});
      await _link.waitFor('au_done', const Duration(seconds: 5));
    } catch (_) {
      // 这个文件本来就不要了，设备怎么说是收尾，不是新错误。
    }
  }

  Future<void> readStat() async {
    await _link.writeCommand({'t': 'stat'});
    lastStat = await _link.waitFor('stat', const Duration(seconds: 8));
    _say(
      '设备：存了 ${lastStat!['stored_words']} 词，'
      '发音 ${lastStat!['audio_ok']} 个（失败 ${lastStat!['audio_failed']}），'
      '剩余 ${lastStat!['free_kb']}KB',
    );
  }
}
