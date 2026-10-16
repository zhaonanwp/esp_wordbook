import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/protocol.dart';

class LinkException implements Exception {
  LinkException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Notification {
  _Notification(this.seq, this.msg);
  final int seq;
  final Map<String, dynamic> msg;
}

/// 一条 FFE0 连接的持有者：MTU 协商、特征查找、通知解码、写命令/数据帧。
class BleLink extends ChangeNotifier {
  BleLink();

  final StreamController<Map<String, dynamic>> _notifications =
      StreamController<Map<String, dynamic>>.broadcast();

  /// 设备回报，已按 JSON 解好。字段是 "t"：wb_begin_ok / wb_done / au_done / stat / error。
  Stream<Map<String, dynamic>> get notifications => _notifications.stream;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmd;
  BluetoothCharacteristic? _data;
  StreamSubscription<List<int>>? _ntfSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  /// 设备是「先发通知、后回 ATT write response」的，write() 完成时通知可能已经过去了。
  /// 所以通知先进这个小环形缓冲，waitFor 再从里面取，晚订阅也不会丢。
  final Queue<_Notification> _recent = Queue<_Notification>();
  int _seq = 0;
  int _consumed = 0;

  bool _connected = false;
  bool get connected => _connected;

  BluetoothDevice? get device => _device;

  int _mtu = 23;
  int get mtu => _mtu;

  /// 单条 ATT 写的净负载上限。设备侧 kMaxFrame 是 512。
  int get chunk => math.min(_mtu - 3, 500);

  String get peerId => _device == null ? '-' : _device!.remoteId.str;

  String lastError = '';

  Future<void> connect(BluetoothDevice device) async {
    try {
      await device.connect(timeout: const Duration(seconds: 15));
    } catch (e) {
      if (!device.isConnected) {
        throw LinkException('连接失败：$e');
      }
    }
    _device = device;
    _resetNotifications();

    final negotiated = await device.requestMtu(512);
    // 设备收到 prepared write 只会打一条警告就丢弃，MTU 没谈够就必须在这里停下。
    if (negotiated < 512) {
      throw LinkException('MTU 只协商到 $negotiated，设备不接受分片写，请断开重连');
    }
    _mtu = negotiated;
    debugPrint('BleLink: MTU=$_mtu chunk=$chunk');

    final services = await device.discoverServices();
    BluetoothService? service;
    for (final s in services) {
      if (s.uuid.str128 == WcUuid.service) {
        service = s;
        break;
      }
    }
    if (service == null) {
      throw LinkException('没找到 FFE0 服务，可能连到了别的设备');
    }

    BluetoothCharacteristic? cmd;
    BluetoothCharacteristic? ntf;
    BluetoothCharacteristic? data;
    for (final c in service.characteristics) {
      switch (c.uuid.str128) {
        case WcUuid.cmd:
          cmd = c;
          break;
        case WcUuid.ntf:
          ntf = c;
          break;
        case WcUuid.data:
          data = c;
          break;
      }
    }
    if (cmd == null || ntf == null || data == null) {
      throw LinkException(
        'FFE1/FFE2/FFE3 没凑齐（'
        'cmd=${cmd != null} ntf=${ntf != null} data=${data != null}）',
      );
    }
    _cmd = cmd;
    _data = data;

    await ntf.setNotifyValue(true);
    _ntfSub = ntf.lastValueStream.listen(_onNotify);
    _connSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _connected = false;
        notifyListeners();
      }
    });

    _connected = true;
    notifyListeners();
  }

  void _resetNotifications() {
    _recent.clear();
    _consumed = _seq;
  }

  void _onNotify(List<int> bytes) {
    if (bytes.isEmpty) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (e) {
      // 通知超过 MTU 时 flutter_blue_plus 会给出被切断的字节，这里不猜内容。
      debugPrint('BleLink: 通知解不开 ${bytes.length}B: $e');
      return;
    }
    if (msg['t'] == 'error') {
      lastError = _errorOf(msg);
    }
    _recent.add(_Notification(++_seq, msg));
    while (_recent.length > 64) {
      _recent.removeFirst();
    }
    _notifications.add(msg);
  }

  Future<void> writeCommand(Map<String, dynamic> command) async {
    final c = _cmd;
    if (c == null) throw LinkException('还没连接');
    final raw = utf8.encode(jsonEncode(command));
    if (raw.length > chunk) {
      throw LinkException(
        '命令 ${raw.length}B 超过单条上限 ${chunk}B：'
        '${command['t']} ${command['w'] ?? ''}',
      );
    }
    await c.write(raw, timeout: 10);
  }

  Future<void> writeFrame(List<int> frame) async {
    final c = _data;
    if (c == null) throw LinkException('还没连接');
    if (frame.length > chunk) {
      throw LinkException('音频帧 ${frame.length}B 超过单条上限 ${chunk}B');
    }
    await c.write(frame, timeout: 10);
  }

  /// 等一条指定 "t" 的回报。命中之前的 error 回报也算失败，
  /// 因为 wb_word 这种没有回执的命令，它的错误会一直飘到下一次等待才撞上。
  Future<Map<String, dynamic>> waitFor(String type, Duration timeout) async {
    for (final item in _recent.toList()) {
      if (item.seq <= _consumed) continue;
      _consumed = item.seq;
      final t = item.msg['t'];
      if (t == type) return item.msg;
      if (t == 'error') {
        throw LinkException('设备报错：${_errorOf(item.msg)}');
      }
    }

    final completer = Completer<Map<String, dynamic>>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = _notifications.stream.listen((msg) {
      if (completer.isCompleted) return;
      final t = msg['t'];
      if (t == type) {
        _consumed = _seq;
        completer.complete(msg);
      } else if (t == 'error') {
        _consumed = _seq;
        completer.completeError(LinkException('设备报错：${_errorOf(msg)}'));
      }
    });
    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          throw LinkException('等设备回 $type 超时（${timeout.inSeconds}s）');
        },
      );
    } finally {
      await sub.cancel();
    }
  }

  /// 固件的 error 回报用的是 "m"（`ble_ingest.cc:171`），别写成 "msg"，
  /// 写成 msg 会把原因吞成空串，只剩一句"没给原因"。
  static String _errorOf(Map<String, dynamic> msg) =>
      (msg['m'] ?? '（没给原因）') as String;

  /// 发音频帧这一段没有任何回执可等，只能主动翻缓冲：
  /// 设备一旦废弃了这个文件，后面的帧每帧都会再撞一个错，白灌几十条。
  String? takeError() {
    for (final item in _recent.toList()) {
      if (item.seq <= _consumed) continue;
      _consumed = item.seq;
      if (item.msg['t'] == 'error') return _errorOf(item.msg);
    }
    return null;
  }

  Future<void> disconnect() async {
    await _ntfSub?.cancel();
    await _connSub?.cancel();
    _ntfSub = null;
    _connSub = null;
    final d = _device;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    _connected = false;
    _cmd = null;
    _data = null;
    _device = null;
    _resetNotifications();
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    _notifications.close();
    super.dispose();
  }
}
