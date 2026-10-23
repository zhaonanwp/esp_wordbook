@Tags(['look'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:wordcard_app/core/protocol.dart';
import 'package:wordcard_app/data/device_link.dart';
import 'package:wordcard_app/data/wordbook_store.dart';
import 'package:wordcard_app/features/dashboard_page.dart';
import 'package:wordcard_app/features/entry_page.dart';
import 'package:wordcard_app/features/push_page.dart';
import 'package:wordcard_app/features/settings_page.dart';
import 'package:wordcard_app/ui/hard_style.dart';

/// 各页都只认盘，所以截图得给它一个真临时目录。
class _TmpDocs extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _TmpDocs(this.dir);
  final String dir;
  @override
  Future<String> getApplicationDocumentsPath() async => dir;
}

/// 这不是回归测试，是"改完皮肤先自己看一眼"的口子，默认跳过：
///   LOOK=1 flutter test --update-goldens test/look_pages_test.dart
/// 字体在 flutter test 里默认是 Ahem（什么字都画成黑方块），所以借系统的等线。
/// 版式能看，字形和手机上的 Roboto / 思源不是一回事。
///
/// 扫描页（ScanPage）不在这里：它 initState 就订阅 flutter_blue_plus 和
/// permission_handler，测试里没有那两个插件的 mock，只会拿到 MissingPluginException。
void main() {
  testWidgets(
    '首页',
    (t) => _look(t, const DashboardPage(), 'hard_1_home', scroll: 1000),
  );

  testWidgets('推送页', (t) => _look(t, const PushPage(), 'hard_2_push'));

  testWidgets('录入页：粘进去 + 抠词 + 冲突对话框', _lookEntry);

  testWidgets('首页：批次管理（改来源 / 删掉）', _lookManage);

  testWidgets('设定页：来源自定义（改名 / 删掉）', _lookSettings);
}

class _Ctx {
  _Ctx(this.link, this.store);
  final BleLink link;
  final WordbookStore store;
}

Future<_Ctx> _seed(WidgetTester tester) async {
  late _Ctx ctx;
  // testWidgets 跑在 fake-async 里，真文件 IO 的 Future 永远回不来。
  // 读盘写盘这段必须整个搬出这个区域，否则就是十分钟超时。
  await tester.runAsync(() async {
    final dir = await Directory.systemTemp.createTemp('wclook');
    PathProviderPlatform.instance = _TmpDocs(dir.path);
    final bytes = File('C:/Windows/Fonts/Deng.ttf').readAsBytesSync();
    await (FontLoader('Look')..addFont(
          Future.value(ByteData.sublistView(Uint8List.fromList(bytes))),
        ))
        .load();

    final store = WordbookStore();
    await store.init();

    final now = DateTime.now();
    const a = ['umbrella', 'cold', 'sore throat', 'jump rope', 'fever', 'rest'];
    const b = ['doctor', 'water', 'cough', 'illness', 'raincoat', 'medicine'];
    await store.save(
      WeekBook(
        label: '2026W41',
        version: 'x1',
        updatedAt: now.subtract(const Duration(days: 6)),
        words: [
          for (final w in a)
            WordEntry(
              word: w,
              phonetic: '/ˈʌm.brel.ə/',
              meaning: 'n. 雨伞；伞状物',
              syllable: 'um-brel-la',
            ),
        ],
      ),
    );
    await store.save(
      WeekBook(
        label: '2026W42',
        version: 'x2',
        updatedAt: now.subtract(const Duration(days: 1)),
        words: [
          for (final w in b)
            WordEntry(
              word: w,
              meaning: 'n. 一个挺长的中文释义，用来把行挤到两行看看溢出',
              example: 'Take the medicine twice a day after meals.',
            ),
        ],
      ),
    );
    // 让首页那行「发音已在设备 N 个」和「← 设备上就是这批」都不是空的。
    final first = store.byLabel('2026W41')!;
    for (final w in first.words.take(3)) {
      first.audioMark[w.slug] = WeekBook.markOf('mp3', 1234567);
    }
    await store.save(first);
    await store.markOnDevice('2026W41');
    // 来源是设定页里加的，词库得跟着有真用法，截图才看得出这一列不是死的。
    await store.addSource('绘本');
    await store.save(store.byLabel('2026W42')!.withSource('新东方'));
    ctx = _Ctx(BleLink(), store);
  });
  return ctx;
}

Widget _shell(Widget page, _Ctx ctx) {
  return MultiProvider(
    providers: [
      // .value 不让 provider 回收它们：BleLink 断开是异步的，dispose 之后
      // 再 notifyListeners 就是这条 "used after being disposed" 断言。
      ChangeNotifierProvider.value(value: ctx.link),
      ChangeNotifierProvider.value(value: ctx.store),
    ],
    child: MaterialApp(
      theme: hardTheme(fontFamily: 'Look'),
      home: page,
    ),
  );
}

Future<void> _settle(WidgetTester t) async {
  // 不用 pumpAndSettle：它要等所有动画停，页面里只要有一个循环动画就永远不返回。
  await t.pump();
  await t.pump(const Duration(milliseconds: 500));
}

Future<void> _look(
  WidgetTester t,
  Widget page,
  String name, {
  double? scroll,
}) async {
  if (Platform.environment['LOOK'] != '1') return;
  final ctx = await _seed(t);
  t.view.devicePixelRatio = 3;
  t.view.physicalSize = const Size(1080, 2280);
  addTearDown(t.view.reset);

  await t.pumpWidget(_shell(page, ctx));
  await _settle(t);
  expect(t.takeException(), isNull);
  await expectLater(
    find.byType(page.runtimeType),
    matchesGoldenFile('goldens/$name.png'),
  );
  if (scroll != null) {
    await t.drag(find.byType(ListView), Offset(0, -scroll));
    await _settle(t);
    await expectLater(
      find.byType(page.runtimeType),
      matchesGoldenFile('goldens/${name}_scrolled.png'),
    );
  }
}

Future<void> _lookEntry(WidgetTester t) async {
  if (Platform.environment['LOOK'] != '1') return;
  final ctx = await _seed(t);
  t.view.devicePixelRatio = 3;
  t.view.physicalSize = const Size(1080, 2280);
  addTearDown(t.view.reset);

  await t.pumpWidget(_shell(const EntryPage(), ctx));
  await _settle(t);

  // 带中文的行不会走有道，测试里也不会有网络。
  await t.enterText(
    find.byType(TextField).first,
    'umbrella|/ʌmˈbrelə/|n. 雨伞|I take an umbrella when it rains.|um-brel-la\n'
    '2. raincoat 雨衣 /ˈreɪnkəʊt/\n'
    'fever|/ˈfiːvə/|n. 发烧|The fever lasted two nights.|fe-ver\n'
    'chilly|/ˈtʃɪli/|adj. 有点冷的|It feels chilly this morning.',
  );
  await t.tap(find.text('抠词并补全'));
  await _settle(t);
  expect(t.takeException(), isNull);
  await expectLater(
    find.byType(EntryPage),
    matchesGoldenFile('goldens/hard_3_entry.png'),
  );

  // 存到已经存在的 2026W41 上 → 冲突对话框（覆盖是红块）。
  // 批次名不再预填周号，所以这里得自己敲一个已存在的名字。
  await t.enterText(find.byType(TextField).last, '2026W41');
  await t.tap(find.text('保存 4 词'));
  await _settle(t);
  await expectLater(
    find.byType(AlertDialog),
    matchesGoldenFile('goldens/hard_4_entry_conflict.png'),
  );
  await t.tap(find.text('取消'));
  await _settle(t);

  // 单行的编辑框：五个字段 + 音节那条 helper
  await t.tap(find.text('raincoat'));
  await _settle(t);
  await expectLater(
    find.byType(AlertDialog),
    matchesGoldenFile('goldens/hard_5_entry_edit.png'),
  );
  await t.tap(find.text('取消'));
}

/// 删掉那一步只截确认框，**不真的按"删"** —— 那是真文件 IO，fake-async 里等不回来。
Future<void> _lookManage(WidgetTester t) async {
  if (Platform.environment['LOOK'] != '1') return;
  final ctx = await _seed(t);
  t.view.devicePixelRatio = 3;
  t.view.physicalSize = const Size(1080, 2280);
  addTearDown(t.view.reset);

  await t.pumpWidget(_shell(const DashboardPage(), ctx));
  await _settle(t);
  // 词库列表在页面底下，滚过去之前 ListView 的 children 是 offstage 的，
  // find.byIcon(...).first 直接抛 "No element"，所以只能一段段硬拖到看得见。
  for (var i = 0;
      i < 8 && find.byIcon(Icons.edit_outlined).evaluate().isEmpty;
      i++) {
    await t.drag(find.byType(ListView), const Offset(0, -400));
    await _settle(t);
  }
  await t.tap(find.byIcon(Icons.edit_outlined).first);
  await _settle(t);
  expect(t.takeException(), isNull);
  await expectLater(
    find.byType(AlertDialog),
    matchesGoldenFile('goldens/hard_6_book_manage.png'),
  );

  await t.tap(find.text('删掉这批'));
  await _settle(t);
  expect(t.takeException(), isNull);
  await expectLater(
    find.byType(AlertDialog),
    matchesGoldenFile('goldens/hard_7_book_delete.png'),
  );
  await t.tap(find.text('不删了'));
  await _settle(t);
}

/// 改名和删掉都只截框、不真的提交 —— 提交了就是 sources.json 的真写盘，
/// fake-async 里等不回来。
Future<void> _lookSettings(WidgetTester t) async {
  if (Platform.environment['LOOK'] != '1') return;
  final ctx = await _seed(t);
  t.view.devicePixelRatio = 3;
  t.view.physicalSize = const Size(1080, 2280);
  addTearDown(t.view.reset);

  await t.pumpWidget(_shell(const SettingsPage(), ctx));
  await _settle(t);
  expect(t.takeException(), isNull);
  await expectLater(
    find.byType(SettingsPage),
    matchesGoldenFile('goldens/hard_8_settings.png'),
  );

  // 最后一行是设定页里加的「绘本」，前面两行是内置那两个。
  await t.tap(find.byIcon(Icons.edit_outlined).last);
  await _settle(t);
  await expectLater(
    find.byType(AlertDialog),
    matchesGoldenFile('goldens/hard_9_source_rename.png'),
  );
  await t.tap(find.text('取消'));
  await _settle(t);

  // 第一行是「课本」，seed 里那两批有一批挂在它下面，所以删的提示要带在用的批数。
  await t.tap(find.byIcon(Icons.delete_outline).first);
  await _settle(t);
  expect(t.takeException(), isNull);
  await expectLater(
    find.byType(AlertDialog),
    matchesGoldenFile('goldens/hard_10_source_delete.png'),
  );
  await t.tap(find.text('不删'));
}
