import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// "mw75_bench/window": full screen for the participant's test screens.
  private var windowChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Room for the headset panel beside live EEG, band power and the command log.
    self.setContentSize(NSSize(width: 1280, height: 880))
    self.contentMinSize = NSSize(width: 1100, height: 760)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    // Native MW75 code (Bluetooth + tones) lives in this target now, not in a plugin package.
    Mw75NeuroPlugin.register(with: flutterViewController.registrar(forPlugin: "Mw75NeuroPlugin"))

    self.collectionBehavior.insert(.fullScreenPrimary)
    let channel = FlutterMethodChannel(
      name: "mw75_bench/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let window = self else {
        result(nil)
        return
      }
      switch call.method {
      case "setFullScreen":
        let wanted = ((call.arguments as? [String: Any])?["value"] as? Bool) ?? false
        if window.styleMask.contains(.fullScreen) != wanted {
          window.toggleFullScreen(nil)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    windowChannel = channel

    super.awakeFromNib()
  }
}
