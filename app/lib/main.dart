import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/device_link.dart';
import 'data/schedule.dart';
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
        ChangeNotifierProvider(create: (_) => ScheduleStore()..init()),
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
    final sched = context.watch<ScheduleStore>();
    // 两份档案都是异步读盘的。没读完就推送的话，introduce 会先写出一份缺词的记忆档案，
    // 随后 init 读盘把内存覆盖掉 —— 白丢的那几个词再也不会出现在复习里。
    if (!store.ready || !sched.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return const DashboardPage();
  }
}
