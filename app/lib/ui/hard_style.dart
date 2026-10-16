import 'package:flutter/material.dart';

/// 「硬边」皮肤：奶油底 + 2px 黑框 + 右下实心偏移阴影 + 蓝/红实心块。
/// 全站只有 hardTheme() 一个主题，页面里不要再写死颜色。
/// 语义色就三个：blue = 正常动作，coral = 会出事（逾期/截断/失败），amber = 已毕业/攒够了。
class Hard {
  static const Color bg = Color(0xFFF4EDE0);
  static const Color sheet = Color(0xFFFFFDF6);
  static const Color ink = Color(0xFF141414);
  static const Color blue = Color(0xFF3247CE);
  static const Color coral = Color(0xFFEF5340);
  static const Color amber = Color(0xFFE39B12);
  static const Color muted = Color(0xFF6E665A);

  static BoxDecoration box(Color fill, {double lift = 4}) => BoxDecoration(
    color: fill,
    border: Border.all(width: 2, color: ink),
    borderRadius: BorderRadius.circular(6),
    boxShadow: [
      BoxShadow(color: ink, offset: Offset(lift, lift), blurRadius: 0),
    ],
  );

  /// 只有框没有阴影：卡片内部再套小格子时用，阴影叠阴影会糊成一片。
  static BoxDecoration frame(Color fill) => BoxDecoration(
    color: fill,
    border: Border.all(width: 2, color: ink),
    borderRadius: BorderRadius.circular(6),
  );

  /// 正文流里左右间距：左 12，右 16 = 12 + 4 —— 多出来那 4px 是硬阴影往右偏移的量，
  /// 两边都写 12 整列会看着往左歪。卡片用它当 margin，整行用它当 padding，含义一样。
  static EdgeInsets gutter({double top = 8, double bottom = 12}) =>
      EdgeInsets.fromLTRB(12, top, 16, bottom);

  /// 小标题。**故意不拉 letterSpacing**：这套风格原稿靠"全大写 + 字距"撑门面，
  /// 汉字没有大小写，一拉字距"掌握度"就散成三个字。只留字重。
  static TextStyle label(BuildContext context) =>
      (Theme.of(context).textTheme.labelSmall ?? const TextStyle()).copyWith(
        color: ink,
        fontWeight: FontWeight.w800,
      );

  static TextStyle body(BuildContext context) =>
      (Theme.of(context).textTheme.bodySmall ?? const TextStyle()).copyWith(
        color: muted,
      );

  /// 提醒一句（「会被设备截断」「推送失败」）。比 body 粗，直接给 coral。
  static TextStyle flag(BuildContext context) =>
      body(context).copyWith(color: coral, fontWeight: FontWeight.w700);
}

/// app 唯一的主题。对话框、勾选框、输入框、列表行、进度条这些默认组件
/// 全靠这里染色，不然每页都得手写一遍。
ThemeData hardTheme({String? fontFamily}) {
  final scheme = ColorScheme.light(
    primary: Hard.blue,
    onPrimary: Colors.white,
    secondary: Hard.coral,
    onSecondary: Colors.white,
    surface: Hard.sheet,
    onSurface: Hard.ink,
    error: Hard.coral,
    onError: Colors.white,
    outline: Hard.muted,
    outlineVariant: Hard.muted,
  );
  final base = Typography.material2021(colorScheme: scheme).black;
  final text = base
      .apply(bodyColor: Hard.ink, displayColor: Hard.ink)
      .copyWith(
        bodySmall: (base.bodySmall ?? const TextStyle()).copyWith(
          color: Hard.muted,
        ),
      );

  final edge = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(6),
    side: const BorderSide(width: 2, color: Hard.ink),
  );
  final inputEdge = OutlineInputBorder(
    borderRadius: BorderRadius.circular(6),
    borderSide: const BorderSide(width: 2, color: Hard.ink),
  );

  return ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    colorScheme: scheme,
    scaffoldBackgroundColor: Hard.bg,
    dividerColor: Hard.ink.withValues(alpha: 0.14),
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: Hard.bg,
      foregroundColor: Hard.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: Hard.ink,
        fontSize: 20,
        fontWeight: FontWeight.w900,
        fontFamily: fontFamily,
      ),
      iconTheme: const IconThemeData(color: Hard.ink),
    ),
    cardTheme: CardThemeData(
      color: Hard.sheet,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: edge,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Hard.sheet,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(width: 2, color: Hard.ink),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Hard.ink,
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w700,
      ),
      behavior: SnackBarBehavior.floating,
      shape: edge,
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0x24141414),
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: Hard.sheet,
      labelStyle: const TextStyle(
        color: Hard.muted,
        fontWeight: FontWeight.w700,
      ),
      hintStyle: TextStyle(color: Hard.muted.withValues(alpha: 0.75)),
      helperStyle: const TextStyle(color: Hard.muted),
      errorStyle: const TextStyle(
        color: Hard.coral,
        fontWeight: FontWeight.w700,
      ),
      iconColor: Hard.muted,
      prefixIconColor: Hard.muted,
      suffixIconColor: Hard.muted,
      border: inputEdge,
      enabledBorder: inputEdge,
      focusedBorder: inputEdge.copyWith(
        borderSide: const BorderSide(width: 2, color: Hard.blue),
      ),
      errorBorder: inputEdge.copyWith(
        borderSide: const BorderSide(width: 2, color: Hard.coral),
      ),
      focusedErrorBorder: inputEdge.copyWith(
        borderSide: const BorderSide(width: 2, color: Hard.coral),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(3),
        side: const BorderSide(width: 2, color: Hard.ink),
      ),
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? Hard.blue : Hard.sheet,
      ),
      checkColor: const WidgetStatePropertyAll(Colors.white),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? Hard.blue : Hard.muted,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Hard.blue,
      linearTrackColor: Color(0x24141414),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Hard.blue,
        foregroundColor: Colors.white,
        disabledBackgroundColor: Hard.sheet,
        disabledForegroundColor: Hard.muted,
        elevation: 0,
        shadowColor: Colors.transparent,
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
        shape: edge,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: Hard.sheet,
        foregroundColor: Hard.ink,
        elevation: 0,
        shadowColor: Colors.transparent,
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
        shape: edge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Hard.ink,
        side: const BorderSide(width: 2, color: Hard.ink),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
        shape: edge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Hard.ink,
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: Hard.ink),
    ),
    // 列表行的字色不用手写：title 走 onSurface（ink）、subtitle 走 bodySmall（muted）。
    listTileTheme: const ListTileThemeData(iconColor: Hard.ink),
  );
}

class HardCard extends StatelessWidget {
  const HardCard({
    super.key,
    required this.child,
    this.fill,
    this.padding = const EdgeInsets.fromLTRB(12, 10, 12, 10),
    this.margin,
    this.onTap,
  });

  final Widget child;
  final Color? fill;
  final EdgeInsetsGeometry padding;

  /// 不给就用 Hard.gutter()：上下能调，左右那对 12/16 不许页面自己写。
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin ?? Hard.gutter(bottom: 12),
      child: DecoratedBox(
        decoration: Hard.box(fill ?? Hard.sheet),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

class HardButton extends StatelessWidget {
  const HardButton({
    super.key,
    required this.label,
    this.onPressed,
    this.fill,
    this.onColor,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color? fill;
  final Color? onColor;

  /// 主操作（保存、推今天这张表）拉满整行，不给它一个缩在角上的小按钮。
  final bool expand;

  @override
  Widget build(BuildContext context) {
    // 灰底 + 灰字。不这么做的话禁用态的实心蓝按钮上顶着白字，看着还能点。
    final off = onPressed == null;
    final text = Text(
      label,
      // 按钮文案全是中文，和 label() 同理：不吃 letterSpacing。
      style: TextStyle(
        color: off ? Hard.muted : (onColor ?? Hard.ink),
        fontWeight: FontWeight.w800,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(right: 4, bottom: 4),
      child: DecoratedBox(
        decoration: Hard.box(off ? Hard.sheet : (fill ?? Hard.sheet)),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: expand
                  ? SizedBox(
                      width: double.infinity,
                      child: Center(child: text),
                    )
                  : text,
            ),
          ),
        ),
      ),
    );
  }
}

class HardIconButton extends StatelessWidget {
  const HardIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final box = Padding(
      padding: const EdgeInsets.only(right: 3, bottom: 3),
      child: SizedBox(
        width: 38,
        height: 38,
        child: DecoratedBox(
          decoration: Hard.box(Hard.sheet, lift: 3),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onPressed,
              borderRadius: BorderRadius.circular(6),
              child: Icon(icon, size: 20, color: Hard.ink),
            ),
          ),
        ),
      ),
    );
    if (tooltip == null) return box;
    return Tooltip(message: tooltip!, preferBelow: false, child: box);
  }
}

/// 行内的小方按钮（标记记住/忘了、重查有道）。比 IconButton 小一圈，
/// 不然一排标记按钮会把单词挤没。
class HardMiniButton extends StatelessWidget {
  const HardMiniButton({
    super.key,
    required this.icon,
    required this.color,
    this.onPressed,
    this.tooltip,
    this.size = 32,
  });

  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final off = onPressed == null;
    final box = SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: Hard.frame(Hard.sheet),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(6),
            child: Icon(icon, size: 18, color: off ? Hard.muted : color),
          ),
        ),
      ),
    );
    if (tooltip == null) return box;
    return Tooltip(message: tooltip!, preferBelow: false, child: box);
  }
}

/// 黑框 + 实心填充条，替掉 LinearProgressIndicator。
class HardBar extends StatelessWidget {
  const HardBar({
    super.key,
    required this.fraction,
    this.color,
    this.height = 14,
  });

  final double fraction;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => DecoratedBox(
        decoration: Hard.frame(Hard.bg),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: height,
            child: Stack(
              children: [
                if (fraction > 0)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: c.maxWidth * fraction.clamp(0.0, 1.0),
                    child: ColoredBox(color: color ?? Hard.blue),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 只读的小色块（计数、徽标）。不是按钮 —— 没有阴影，点了也没反应。
class HardTag extends StatelessWidget {
  const HardTag({super.key, required this.text, this.fill, this.on});

  final String text;
  final Color? fill;
  final Color? on;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: Hard.frame(fill ?? Hard.sheet),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          text,
          style: TextStyle(
            color: on ?? Hard.ink,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

/// 能点的标签：[HardTag] 那张皮 + InkWell。选批次、选来源这种"一排里挑一个"用它，
/// 因为 HardTag 没有 onTap，DropdownButton 又带不来这套硬边皮。
class HardChip extends StatelessWidget {
  const HardChip({
    super.key,
    required this.text,
    required this.on,
    this.onTap,
    this.fill,
  });

  final String text;
  final bool on;

  /// null 表示当前不能改（推送进行中、或本来就是选中的那个）。
  final VoidCallback? onTap;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: Hard.frame(on ? (fill ?? Hard.blue) : Hard.bg),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            text,
            style: TextStyle(
              color: on ? Colors.white : Hard.ink,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// 「只看不点」的内格：推送日志、连接参数这类成段的小字。
class HardPanel extends StatelessWidget {
  const HardPanel({
    super.key,
    required this.child,
    this.fill,
    this.padding = const EdgeInsets.fromLTRB(10, 8, 10, 8),
  });

  final Widget child;
  final Color? fill;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: Hard.frame(fill ?? Hard.bg),
      child: Padding(padding: padding, child: child),
    );
  }
}
