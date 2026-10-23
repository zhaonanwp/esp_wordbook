import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/device_link.dart';
import 'data/wordbook_store.dart';
import 'features/dashboard_page.dart';
import 'ui/hard_style.dart';

void main() {
  runApp(const WordcardApp());
}

class WordcardApp extends StatelessWidget {
  const WordcardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BleLink()),
        ChangeNotifierProvider(create: (_) => WordbookStore()..init()),
      ],
      child: MaterialApp(
        title: '单词机同步',
        theme: hardTheme(),
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<WordbookStore>();
    // 词库是异步读盘的：没读完就进首页，列表是空的，「设备上现在这批」也会显示成
    // 「还没推过」—— 那是假话，文件明明在。
    if (!store.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return const DashboardPage();
  }
}
