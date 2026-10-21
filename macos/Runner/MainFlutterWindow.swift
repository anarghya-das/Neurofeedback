import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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

    super.awakeFromNib()
  }
}
