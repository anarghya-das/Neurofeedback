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
        window.requestFullScreen(wanted)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    windowChannel = channel
    observeFullScreenTransitions()

    super.awakeFromNib()
  }

  // MARK: Full screen

  /// True while macOS animates into or out of full screen.
  private var fullScreenTransition = false

  /// A request that arrived during a transition, applied when it ends.
  private var pendingFullScreen: Bool?

  /// Enters or leaves full screen without toggling against a transition already
  /// under way. Esc in a full-screen window makes AppKit start leaving full screen
  /// by itself; toggling then (because the style mask still says full screen)
  /// would send the window straight back in.
  func requestFullScreen(_ wanted: Bool) {
    if fullScreenTransition {
      pendingFullScreen = wanted
      return
    }
    pendingFullScreen = nil
    if styleMask.contains(.fullScreen) != wanted {
      toggleFullScreen(nil)
    }
  }

  private func observeFullScreenTransitions() {
    let center = NotificationCenter.default
    for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
      center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
        self?.fullScreenTransition = true
      }
    }
    for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
        guard let window = self else { return }
        window.fullScreenTransition = false
        if let wanted = window.pendingFullScreen {
          window.requestFullScreen(wanted)
        }
      }
    }
  }
}
