import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    // 语音引擎不走 GeneratedPluginRegistrant（那是给 pub 包的），
    // 直接挂到同一个 binary messenger 上。
    VoiceEnginePlugin.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
