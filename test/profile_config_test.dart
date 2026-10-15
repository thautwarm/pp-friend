import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:pp_friend/src/config/assistant_config.dart';

void main() {
  group('从老配置迁移', () {
    test('只有 brain 字段的老 JSON 会变成一个 default 档案，配置逐字不丢', () {
      const legacy = '''
      {
        "brain": {
          "baseUrl": "http://192.168.0.100:8000",
          "brainId": "员工3",
          "token": "abc"
        },
        "vadSilenceMs": 1200
      }
      ''';

      final config = AssistantConfig.fromJson(
        (jsonDecode(legacy) as Map).cast<String, dynamic>(),
      );

      expect(config.profiles, hasLength(1));
      final profile = config.focusedProfile!;
      expect(profile.id, AssistantConfig.defaultProfileId);
      expect(profile.brain.baseUrl, 'http://192.168.0.100:8000');
      expect(profile.brain.brainId, '员工3');
      expect(profile.brain.token, 'abc');
      // 迁移出来的档案默认是开着的，否则用户升级完发现"什么都没了"
      expect(profile.enabled, isTrue);
      // 名字取 brainId，用户进去能看到一个具体的名字
      expect(profile.name, '员工3');
      // VAD 参数仍然是全局的，留在原地
      expect(config.vadMinSilenceMs, 1200);
    });

    test('反复存读是稳定的，不会每次迁移出不同的东西', () {
      const legacy = '''
      {"brain": {"baseUrl": "u", "brainId": "b", "token": "t"}}
      ''';

      Map<String, dynamic> roundTrip(Map<String, dynamic> json) =>
          (jsonDecode(jsonEncode(AssistantConfig.fromJson(json).toJson()))
                  as Map)
              .cast<String, dynamic>();

      final once = roundTrip(
        (jsonDecode(legacy) as Map).cast<String, dynamic>(),
      );
      final twice = roundTrip(once);

      expect(jsonEncode(twice), jsonEncode(once));
      expect(AssistantConfig.fromJson(twice).focusedProfile!.id,
          AssistantConfig.defaultProfileId);
    });

    test('新版本照样写出 brain 键，回退到旧 APK 不会清空配置', () {
      const config = AssistantConfig(
        profiles: [
          Profile(
            id: 'p_1',
            brain: BrainConfig(baseUrl: 'http://新地址', brainId: '新名字'),
          ),
          Profile(id: 'p_2', brain: BrainConfig(baseUrl: 'http://别的')),
        ],
        focusedProfileId: 'p_2',
      );

      final json = config.toJson();
      final legacyBrain =
          (json['brain'] as Map).cast<String, dynamic>();

      // 旧代码只读 json['brain']，拿到的必须是当前聚焦那个档案的配置
      expect(legacyBrain['baseUrl'], 'http://别的');
      expect(legacyBrain['brainId'], '');
    });
  });

  group('解析容错', () {
    test('profiles 全是垃圾数据时合成一个 default', () {
      final config = AssistantConfig.fromJson(const {
        'profiles': ['不是对象', 42],
        'focusedProfileId': 'nope',
      });
      expect(config.profiles, hasLength(1));
      expect(config.focusedProfile!.id, AssistantConfig.defaultProfileId);
      expect(config.brain.isUsable, isFalse);
    });

    test('id 非法的档案整项丢掉', () {
      final config = AssistantConfig.fromJson(const {
        'profiles': [
          {'id': '../跑出去', 'name': '坏蛋'},
          {'id': 'p_ok', 'name': '好的'},
        ],
      });
      expect(config.profiles.map((p) => p.id), ['p_ok']);
    });

    test('重复 id 后面的丢掉，不让两个档案抢同一份历史', () {
      final config = AssistantConfig.fromJson(const {
        'profiles': [
          {'id': 'p_1', 'name': '先来的'},
          {'id': 'p_1', 'name': '后来的'},
        ],
      });
      expect(config.profiles, hasLength(1));
      expect(config.focusedProfile!.name, '先来的');
    });

    test('focusedProfileId 指向已经删掉的档案时回退到第一个', () {
      final config = AssistantConfig.fromJson(const {
        'profiles': [
          {'id': 'p_1'},
          {'id': 'p_2'},
        ],
        'focusedProfileId': 'p_已经删了',
      });
      expect(config.focusedProfile!.id, 'p_1');
    });

    test('const 造出来的空配置先归一化再落盘', () {
      const empty = AssistantConfig();
      expect(empty.focusedProfile, isNull);

      final normalized = empty.normalized();
      expect(normalized.profiles, hasLength(1));
      expect(normalized.brain.isUsable, isFalse);
      // 归一化之后是幂等的：再归一次还是同一个档案，不会又换一个 id
      expect(normalized.normalized().focusedProfile!.id,
          normalized.focusedProfile!.id);
    });
  });

  group('档案增删改', () {
    const twoProfiles = AssistantConfig(
      profiles: [
        Profile(id: 'p_1', name: '一号', brain: BrainConfig(brainId: 'a')),
        Profile(id: 'p_2', name: '二号', brain: BrainConfig(brainId: 'b')),
        Profile(id: 'p_3', name: '三号', brain: BrainConfig(brainId: 'c')),
      ],
      focusedProfileId: 'p_2',
    );

    test('withProfile 改已有的那一项，不动别人', () {
      final updated = twoProfiles
          .withProfile(const Profile(id: 'p_2', name: '改过的'));
      expect(updated.profiles.map((p) => p.name), ['一号', '改过的', '三号']);
      expect(updated.profiles.map((p) => p.id), ['p_1', 'p_2', 'p_3']);
    });

    test('withProfile 带新 id 时追加到末尾', () {
      final updated = twoProfiles.withProfile(const Profile(id: 'p_4'));
      expect(updated.profiles, hasLength(4));
      expect(updated.profiles.last.id, 'p_4');
    });

    test('删掉没聚焦的档案，焦点不动', () {
      final updated = twoProfiles.withoutProfile('p_3');
      expect(updated.profiles.map((p) => p.id), ['p_1', 'p_2']);
      expect(updated.focusedProfile!.id, 'p_2');
    });

    test('删掉正在聚焦的档案，焦点挪到下一个还开着的', () {
      const withClosed = AssistantConfig(
        profiles: [
          Profile(id: 'p_1', name: '一号'),
          Profile(id: 'p_2', name: '二号'),
          Profile(id: 'p_3', name: '三号', enabled: false),
        ],
        focusedProfileId: 'p_1',
      );

      final updated = withClosed.withoutProfile('p_1');
      // p_3 是关着的，跳过它
      expect(updated.focusedProfile!.id, 'p_2');
    });

    test('全删光之后没有聚焦档案，不崩', () {
      final updated = twoProfiles
          .withoutProfile('p_1')
          .withoutProfile('p_2')
          .withoutProfile('p_3');
      expect(updated.focusedProfile, isNull);
      expect(updated.brain.isUsable, isFalse);
      // 空列表再归一化能自己长出一个空档案来，不用特殊处理
      expect(updated.normalized().focusedProfile, isNotNull);
    });

    test('删光之后补回来的空档案，不会把被删掉的历史接回来', () {
      // 从老配置迁移出来的那个档案，id 就是固定的 `default`，它的历史躺在
      // `history/default/` 里。补回来的空档案要是还叫 `default`，刚删掉的
      // 历史会原样挂上去 —— 用户看到的是"删不掉"，而 brain 配置已经被清空了。
      const migrated = AssistantConfig(
        profiles: [
          Profile(
            id: AssistantConfig.defaultProfileId,
            brain: BrainConfig(brainId: '员工3'),
          ),
        ],
        focusedProfileId: AssistantConfig.defaultProfileId,
      );

      final afterDelete =
          migrated.withoutProfile(AssistantConfig.defaultProfileId);
      expect(afterDelete.profiles, isEmpty);

      final revived = afterDelete.normalized().focusedProfile!;
      expect(revived.id, isNot(AssistantConfig.defaultProfileId),
          reason: 'history/default/ 还在盘上，同 id 就等于把删除撤销了');
      expect(revived.brain.isUsable, isFalse);
    });

    test('归一化会把焦点从关掉的档案上挪开', () {
      const disabledFocus = AssistantConfig(
        profiles: [
          Profile(id: 'p_1', enabled: false),
          Profile(id: 'p_2'),
        ],
        focusedProfileId: 'p_1',
      );

      expect(disabledFocus.normalized().focusedProfile!.id, 'p_2');
    });

    test('所有档案都关着时焦点留在原地，不崩', () {
      const allClosed = AssistantConfig(
        profiles: [Profile(id: 'p_1', enabled: false)],
        focusedProfileId: 'p_1',
      );

      final normalized = allClosed.normalized();
      expect(normalized.focusedProfile!.id, 'p_1');
      expect(normalized.focusedProfile!.stateIn(normalized.focusedProfileId),
          ProfileState.closed);
    });

    test('copyWith(brain:) 写到聚焦的那个档案上', () {
      final updated = twoProfiles.copyWith(
        brain: const BrainConfig(baseUrl: 'http://新地址', brainId: 'x'),
      );
      expect(updated.focusedProfile!.brain.baseUrl, 'http://新地址');
      // 别人不动
      expect(updated.profiles[0].brain.baseUrl, '');
    });

    test('聚焦档案还不存在时 copyWith(brain:) 就地造一个', () {
      final updated = const AssistantConfig().copyWith(
        brain: const BrainConfig(baseUrl: 'http://a', brainId: 'b'),
      );
      expect(updated.profiles, hasLength(1));
      expect(updated.brain.isUsable, isTrue);
    });
  });

  group('Profile', () {
    test('新造的 id 合法且不重复', () {
      final ids = {for (var i = 0; i < 200; i++) Profile.newId()};
      expect(ids, hasLength(200));
      for (final id in ids) {
        expect(Profile.isValidId(id), isTrue, reason: '$id 不能当目录名');
      }
    });

    test('显示名三级回退', () {
      expect(
        const Profile(id: 'p', name: '起过名字', brain: BrainConfig(brainId: 'b'))
            .displayName,
        '起过名字',
      );
      expect(
        const Profile(id: 'p', brain: BrainConfig(brainId: 'b')).displayName,
        'b',
      );
      expect(const Profile(id: 'p').displayName, '未命名');
    });

    test('三种状态是从 focusedId 和 enabled 推出来的', () {
      const focused = Profile(id: 'p_1');
      const other = Profile(id: 'p_2');
      const closed = Profile(id: 'p_3', enabled: false);

      expect(focused.stateIn('p_1'), ProfileState.focused);
      expect(other.stateIn('p_1'), ProfileState.active);
      // 关着的档案就算 id 对得上也是关闭态
      expect(closed.stateIn('p_3'), ProfileState.closed);
    });

    test('往返之后字段不变，头像没有时不写这个键', () {
      const profile = Profile(
        id: 'p_1',
        name: '名字',
        brain: BrainConfig(baseUrl: 'u', brainId: 'b', token: 't'),
        accentColor: 0xFF00FF00,
        avatarFile: 'p_1.png',
        enabled: false,
      );

      final back = Profile.fromJson(
        (jsonDecode(jsonEncode(profile.toJson())) as Map)
            .cast<String, dynamic>(),
      )!;
      expect(back.id, 'p_1');
      expect(back.name, '名字');
      expect(back.brain.token, 't');
      expect(back.accentColor, 0xFF00FF00);
      expect(back.avatarFile, 'p_1.png');
      expect(back.enabled, isFalse);

      expect(const Profile(id: 'p').toJson().containsKey('avatarFile'), isFalse);
    });

    test('clearAvatar 能把头像摘掉', () {
      const profile = Profile(id: 'p', avatarFile: 'a.png');
      expect(profile.copyWith(clearAvatar: true).avatarFile, isNull);
      // 不给新值又不 clear 时保持不变
      expect(profile.copyWith(name: 'x').avatarFile, 'a.png');
    });
  });
}
