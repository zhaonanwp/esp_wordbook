import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../core/protocol.dart';
import '../data/device_link.dart';
import '../ui/hard_style.dart';
import 'plan_page.dart';

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  List<ScanResult> _results = [];
  StreamSubscription<List<ScanResult>>? _sub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  bool _scanning = false;
  bool _connecting = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _sub = FlutterBluePlus.scanResults.listen((rows) {
      final hits = rows.where(_isWordcard).toList();
      hits.sort((a, b) => b.rssi.compareTo(a.rssi));
      setState(() => _results = hits);
    });
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (state != BluetoothAdapterState.on) {
        setState(() => _message = '蓝牙没开（当前 $state）');
      } else if (_message.startsWith('蓝牙没开')) {
        setState(() => _message = '');
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  bool _isWordcard(ScanResult r) {
    if (r.device.platformName.toUpperCase() == WcUuid.deviceName) return true;
    for (final uuid in r.advertisementData.serviceUuids) {
      if (uuid.str128 == WcUuid.service) return true;
    }
    return false;
  }

  Future<void> _start() async {
    setState(() {
      _message = '';
      _scanning = true;
    });
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    final denied = statuses.entries
        .where((e) => !e.value.isGranted && !e.value.isLimited)
        .map((e) => e.key.toString())
        .toList();
    if (denied.isNotEmpty) {
      setState(() {
        _scanning = false;
        _message = '蓝牙权限没给：${denied.join(', ')}';
      });
      return;
    }
    try {
      // 不在协议栈层面按 UUID 过滤：一旦漏过滤，列表直接空掉，分不清是设备没开
      // 还是过滤没匹配上。广播里名字和 FFE0 都带着，在 Dart 侧过滤就够。
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    } catch (e) {
      setState(() {
        _scanning = false;
        _message = '扫描失败：$e';
      });
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    if (_connecting) return;
    setState(() => _connecting = true);
    final link = context.read<BleLink>();
    try {
      await FlutterBluePlus.stopScan();
      await link.connect(device);
      if (!mounted) return;
      // 连上就回日常操作台（计划页：打勾 + 推今天这张表）。
      // 以前这里跳推送页，把"连设备"和"整本重推"绑死了。
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const PlanPage()));
    } on LinkException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('连接失败：$e')));
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _adapterSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('找单词机'),
        actions: [
          HardIconButton(
            icon: Icons.refresh,
            tooltip: '重新扫描',
            onPressed: _scanning ? null : _start,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Text(_message, style: Hard.flag(context)),
            ),
          Padding(
            padding: Hard.gutter(top: 10, bottom: 4),
            child: Row(
              children: [
                if (_scanning)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                const SizedBox(width: 8),
                Text(_scanning ? '扫描中…' : '已停止扫描'),
                const Spacer(),
                HardTag(text: '${_results.length} 台'),
              ],
            ),
          ),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '扫不到 WORDCARD\n确认设备已开机（单击 PWR），且没被另一台手机连着',
                        textAlign: TextAlign.center,
                        style: Hard.body(context),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: Hard.gutter(top: 6),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final r = _results[index];
                      final name = r.device.platformName.isEmpty
                          ? '(没名字)'
                          : r.device.platformName;
                      return Opacity(
                        opacity: _connecting ? 0.45 : 1,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: DecoratedBox(
                            decoration: Hard.frame(Hard.bg),
                            child: Material(
                              type: MaterialType.transparency,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: _connecting
                                    ? null
                                    : () => _connect(r.device),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    8,
                                    8,
                                    8,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.router_outlined,
                                        size: 20,
                                        color: Hard.blue,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              name,
                                              style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w800,
                                                color: Hard.ink,
                                              ),
                                            ),
                                            Text(
                                              '${r.device.remoteId.str}  ${r.rssi} dBm',
                                              style: Hard.body(context),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (_connecting)
                                        const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      else
                                        const Icon(
                                          Icons.chevron_right,
                                          color: Hard.ink,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
