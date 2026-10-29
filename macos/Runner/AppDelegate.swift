import Cocoa
import Darwin
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 在 Flutter engine 起来之前把两个动态库的查找路径定好：
  ///
  /// - `ORT_DYLIB_PATH`：ort 用 load-dynamic，构建期不链接，运行期靠它找
  ///   ONNX Runtime；不设的话只会去可执行文件旁边找。
  /// - `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR`：flutter_rust_bridge
  ///   的默认加载器会先看这个目录，这样 Dart 侧不用为 macOS 写平台分支。
  ///
  /// Windows/Linux 以后在各自的 runner 里设同样的两个变量即可。
  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)
    guard let frameworks = Bundle.main.privateFrameworksPath else { return }
    setenv("ORT_DYLIB_PATH", "\(frameworks)/libonnxruntime.dylib", 1)
    setenv("FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR", frameworks, 1)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
