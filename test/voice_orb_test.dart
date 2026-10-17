import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pp_friend/src/ui/widgets/voice_orb.dart';
import 'package:pp_friend/src/voice/voice_engine.dart';

import 'support/test_app.dart';

/// 1x1 的透明 PNG。内容无所谓 —— 这几条用例关心的是它**被怎么画**，
/// 不是它画出来长什么样。
final ImageProvider _png = MemoryImage(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQAB'
    'DQottAAAAABJRU5ErkJggg==',
  ),
);

const double _scale = 0.62;

Future<void> _pump(
  WidgetTester tester, {
  ImageProvider? avatar,
  OrbState state = OrbState.listening,
}) async {
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: Center(
          child: VoiceOrb(
            levels: ValueNotifier(
              const AudioLevels(micDb: -60, playbackDb: -70),
            ),
            state: state,
            onTap: () {},
            scale: _scale,
            avatar: avatar,
          ),
        ),
      ),
    ),
  );
  // 呼吸环是无限循环的动画，pumpAndSettle 永远等不到头。
  await tester.pump();
}

/// 头像当前的明暗。
///
/// `AnimatedOpacity` 内部是 `FadeTransition`（不是 `Opacity`），所以按
/// `FadeTransition` 找。从 `ClipOval` 里往下找 —— 圆里那一条链上只有这一层，
/// 不会跟路由自带的那层撞上。
double _avatarOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.descendant(
        of: find.byType(ClipOval),
        matching: find.byType(FadeTransition),
      ),
    )
    .opacity
    .value;

void main() {
  testWidgets('头像被裁在圆里，不会以方形越过说话按钮', (tester) async {
    await _pump(tester, avatar: _png);

    // 遮罩必须在**图**上。给外面那个圆加 clipBehavior 也能裁住，但会顺手
    // 把圈外那层呼吸光晕一起剪掉 —— 所以这里只认图外面这一层。
    expect(
      find.ancestor(of: find.byType(Image), matching: find.byType(ClipOval)),
      findsOneWidget,
      reason: '没有遮罩的话，方形头像的四个角会印在按钮外面',
    );

    // 遮罩的尺寸就是"头像最多能画多大"：它必须落在按钮那个圆的里面，
    // 而且圆心对得上。
    final orbCenter = tester.getCenter(find.byType(VoiceOrb));
    final clipSize = tester.getSize(find.byType(ClipOval));
    final coreSize = VoiceOrb.baseCoreSize * _scale;
    final expected = coreSize - 8 * _scale; // 四周各让出 4 * scale

    expect(clipSize.width, moreOrLessEquals(expected, epsilon: 0.01));
    expect(clipSize.width, lessThan(coreSize));
    expect(
      tester.getCenter(find.byType(ClipOval)),
      offsetMoreOrLessEquals(orbCenter, epsilon: 0.01),
      reason: '遮罩偏了的话，头像会从另一侧露出去',
    );
  });

  testWidgets('头像是半透明压上去的，透得出底下的主题色', (tester) async {
    await _pump(tester, avatar: _png);

    expect(_avatarOpacity(tester), lessThan(1.0), reason: '全不透明就是一张贴上去的贴纸');
    expect(
      _avatarOpacity(tester),
      greaterThan(0.5),
      reason: '太透就看不清脸了，那还不如不要头像',
    );
  });

  testWidgets('开着还是关着，带着头像也分得出来', (tester) async {
    // 头像占了圆里大半面积，底下那点状态色被挡住 —— 只看底色是对比不出来的。
    // 所以"关着"必须在头像自己身上看得出来。
    final greyscale = find.ancestor(
      of: find.byType(Image),
      matching: find.byType(ColorFiltered),
    );

    await _pump(tester, avatar: _png, state: OrbState.idle);
    final dimmed = _avatarOpacity(tester);
    expect(greyscale, findsOneWidget, reason: '关着的时候头像该是黑白的');
    expect(dimmed, lessThan(0.5), reason: '关着的时候头像该是暗的');

    await _pump(tester, avatar: _png, state: OrbState.listening);
    // 明暗是渐变的，得等它走完
    await tester.pump(const Duration(milliseconds: 250));
    final bright = _avatarOpacity(tester);

    expect(bright, greaterThan(dimmed * 2), reason: '开了还这么暗的话，用户看不出对话起没起来');
    expect(greyscale, findsNothing, reason: '开着的时候头像得是有颜色的');
  });

  testWidgets('启动中会转圈，按下去之后立刻有反应', (tester) async {
    // 起前台服务、开音频链路、加载断句模型这几步加起来是能感觉到的，
    // 这期间按钮要是跟没按之前长得一样，用户就会再按第二下。
    final spinner = find.byType(CircularProgressIndicator);

    await _pump(tester, avatar: _png, state: OrbState.starting);
    await tester.pump();
    expect(spinner, findsOneWidget);
    expect(_avatarOpacity(tester), lessThan(0.5), reason: '还没跑起来，不该是亮的');

    await _pump(tester, avatar: _png, state: OrbState.idle);
    expect(spinner, findsNothing, reason: '没开的时候不该转圈');

    await _pump(tester, avatar: _png, state: OrbState.listening);
    await tester.pump(const Duration(milliseconds: 250));
    expect(spinner, findsNothing, reason: '起来了就不用再转了');
    expect(_avatarOpacity(tester), greaterThan(0.5));
  });

  testWidgets('没有头像时照旧画图标，并且不套遮罩', (tester) async {
    await _pump(tester);

    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    expect(find.byType(ClipOval), findsNothing);
    expect(find.byType(Image), findsNothing);
  });
}
