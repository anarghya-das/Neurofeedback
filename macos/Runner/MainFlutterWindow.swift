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
        result(window.requestFullScreen(wanted))
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
  /// Returns what it did, for the log on the Dart side.
  @discardableResult
  func requestFullScreen(_ wanted: Bool) -> String {
    let isFull = styleMask.contains(.fullScreen)
    if fullScreenTransition {
      pendingFullScreen = wanted
      return "wanted \(wanted), in transition (full: \(isFull)): queued"
    }
    pendingFullScreen = nil
    if isFull != wanted {
      toggleFullScreen(nil)
      return "wanted \(wanted), full: \(isFull): toggled"
    }
    return "wanted \(wanted), full: \(isFull): nothing to do"
  }

  /// Esc belongs to the test screen, which closes itself and leaves the window
  /// full screen. Swallowing AppKit's own cancel action keeps it from dropping the
  /// window out of full screen behind the app's back.
  override func cancelOperation(_ sender: Any?) {}

  private func observeFullScreenTransitions() {
    let center = NotificationCenter.default
    for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
      center.addObserver(forName: name, object: self, queue: .main) { [weak self] note in
        self?.fullScreenTransition = true
        self?.windowChannel?.invokeMethod("log", arguments: note.name.rawValue)
      }
    }
    for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      center.addObserver(forName: name, object: self, queue: .main) { [weak self] note in
        guard let window = self else { return }
        window.fullScreenTransition = false
        var line = note.name.rawValue
        if let wanted = window.pendingFullScreen {
          line += " -> queued request: " + window.requestFullScreen(wanted)
        }
        window.windowChannel?.invokeMethod("log", arguments: line)
      }
    }
  }
}
