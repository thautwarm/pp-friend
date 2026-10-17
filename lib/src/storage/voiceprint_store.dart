import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// 声纹文件：192 个 little-endian float32，正好 768 字节，已 L2 归一化。
///
/// 格式只有这一种，不做 JSON / base64 之类的变体 —— 导入这条路最容易
/// 出的错就是"文件选错了但看起来成功了"，字节数一卡就能当场挡住。
class Voiceprint {
  const Voiceprint(this.bytes);

  static const int dimension = 192;
  static const int byteLength = dimension * 4;

  final Uint8List bytes;

  /// 校验并读入。非法就抛 [FormatException]。
  factory Voiceprint.parse(Uint8List bytes) {
    if (bytes.length != byteLength) {
      throw FormatException(
        '声纹文件应该是 $byteLength 字节（192 个 float32），实际 ${bytes.length}',
      );
    }
    var sum = 0.0;
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < dimension; i++) {
      final v = view.getFloat32(i * 4, Endian.little);
      if (!v.isFinite) throw const FormatException('声纹文件里有 NaN 或无穷大');
      sum += v * v;
    }
    if (math.sqrt(sum) <= 1e-6) {
      throw const FormatException('声纹向量是零向量');
    }
    return Voiceprint(bytes);
  }

  /// 前几个值，界面拿来显示"确实读到了东西"。
  List<double> get head {
    final view = ByteData.sublistView(bytes);
    return [for (var i = 0; i < 4; i++) view.getFloat32(i * 4, Endian.little)];
  }
}

/// 声纹在应用目录里的读写。
///
/// 声纹是生物特征，只放在应用私有目录（Android 上是 `filesDir`），
/// 不写外部存储、不上传。删除就是删文件。
class VoiceprintStore {
  VoiceprintStore(this.root);

  /// 应用私有目录（和历史、头像同一个根）。
  final Directory root;

  File get _file => File('${root.path}/voiceprint/spkemb.f32');

  /// 读不到或者文件坏了都返回 null —— "没有声纹"是一个正常状态。
  Future<Voiceprint?> load() async {
    try {
      final file = _file;
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return Voiceprint.parse(bytes);
    } catch (_) {
      return null;
    }
  }

  /// 导入之前已经在界面上校验过一次；这里再校验一次是最后一道闸。
  Future<void> save(Voiceprint voiceprint) async {
    await _file.parent.create(recursive: true);
    // 先写临时文件再 rename：写到一半断电不会留下一个长度不对的文件。
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsBytes(voiceprint.bytes, flush: true);
    await tmp.rename(_file.path);
  }

  Future<bool> exists() => _file.exists();

  Future<void> clear() async {
    final file = _file;
    if (await file.exists()) await file.delete();
    final tmp = File('${_file.path}.tmp');
    if (await tmp.exists()) await tmp.delete();
  }
}
