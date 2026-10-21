import Cocoa
import FlutterMacOS
import IOBluetooth

/// Classic-Bluetooth RFCOMM transport for the Neurable MW75 Neuro.
///
/// Deliberately thin: it opens the GAIA command channel (found via SDP, like Research
/// Kit) and the raw-EEG channel, writes bytes, and forwards received bytes with host
/// timestamps. Framing, commands and signal quality live in Dart so they can be tested
/// without hardware.
public class Mw75NeuroPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = Mw75NeuroPlugin()
    let methods = FlutterMethodChannel(name: "mw75_neuro", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(name: "mw75_neuro/events", binaryMessenger: registrar.messenger)
    events.setStreamHandler(instance)
  }

  /// The headset's first RFCOMM open after a fresh baseband session never completes;
  /// closing and reopening succeeds within ~50 ms. Research Kit works around the same
  /// behaviour with a ~5 s wait and a retry.
  private static let openAttemptTimeout = 3.0
  private static let openAttempts = 4

  private var eventSink: FlutterEventSink?
  /// Created on first use: making a CBCentralManager is what asks for Bluetooth access.
  private lazy var ble = BleLink(emit: { [weak self] event in self?.eventSink?(event) })
  private let tones = ToneStimulator()
  private lazy var speaker = CueSpeaker()
  private var commandLink: RfcommLink?
  private var dataLink: RfcommLink?
  private var pendingOpen: PendingOpen?

  // MARK: FlutterStreamHandler

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // MARK: Method calls

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pairedDevices":
      result(pairedDevices())
    case "open":
      guard let address = args["address"] as? String,
        let dataChannel = args["dataChannel"] as? Int,
        let serviceUuid16 = args["commandServiceUuid16"] as? Int
      else {
        result(FlutterError(code: "bad_args", message: "open needs address, dataChannel, commandServiceUuid16", details: nil))
        return
      }
      open(
        address: address, dataChannel: BluetoothRFCOMMChannelID(dataChannel),
        serviceUuid16: BluetoothSDPUUID16(serviceUuid16), result: result)
    case "write":
      guard let target = args["channel"] as? String,
        let bytes = args["bytes"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "bad_args", message: "write needs channel and bytes", details: nil))
        return
      }
      write(bytes.data, to: target == "data" ? dataLink : commandLink, result: result)
    case "close":
      close()
      result(nil)
    case "clock":
      result(Mw75NeuroPlugin.hostClock())
    case "bleConnect":
      guard let service = args["service"] as? String else {
        result(FlutterError(code: "bad_args", message: "bleConnect needs service", details: nil))
        return
      }
      ble.connect(
        nameContains: args["nameContains"] as? String ?? "MW75", service: service,
        notify: args["notify"] as? [String] ?? [], timeoutSeconds: args["timeoutSeconds"] as? Double ?? 20,
        result: result)
    case "bleWrite":
      guard let characteristic = args["characteristic"] as? String,
        let bytes = args["bytes"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "bad_args", message: "bleWrite needs characteristic and bytes", details: nil))
        return
      }
      ble.write(
        characteristic: characteristic, bytes: bytes.data, withResponse: args["withResponse"] as? Bool ?? true,
        result: result)
    case "bleDisconnect":
      ble.disconnect()
      result(nil)
    case "audioOutputs":
      result(ToneStimulator.outputDevices())
    case "audioStart":
      do {
        result(try tones.start(deviceId: args["deviceId"] as? Int))
      } catch {
        result(FlutterError(code: "audio_failed", message: error.localizedDescription, details: nil))
      }
    case "audioPlay":
      guard let frequency = args["frequency"] as? Double, let duration = args["duration"] as? Double,
        let amplitude = args["amplitude"] as? Double
      else {
        result(FlutterError(code: "bad_args", message: "audioPlay needs frequency, duration, amplitude", details: nil))
        return
      }
      do {
        result(try tones.play(frequency: frequency, duration: duration, amplitude: amplitude, at: args["at"] as? Double))
      } catch {
        result(FlutterError(code: "audio_failed", message: error.localizedDescription, details: nil))
      }
    case "audioHold":
      guard let frequency = args["frequency"] as? Double, let amplitude = args["amplitude"] as? Double else {
        result(FlutterError(code: "bad_args", message: "audioHold needs frequency, amplitude", details: nil))
        return
      }
      do {
        try tones.hold(frequency: frequency, amplitude: amplitude)
        result(nil)
      } catch {
        result(FlutterError(code: "audio_failed", message: error.localizedDescription, details: nil))
      }
    case "audioRelease":
      tones.release()
      result(nil)
    case "audioVolume":
      result(ToneStimulator.volume(deviceId: args["deviceId"] as? Int))
    case "audioSetVolume":
      guard let volume = args["volume"] as? Double else {
        result(FlutterError(code: "bad_args", message: "audioSetVolume needs volume", details: nil))
        return
      }
      result(ToneStimulator.setVolume(deviceId: args["deviceId"] as? Int, volume: volume))
    case "audioStop":
      tones.stop()
      result(nil)
    case "speak":
      if let text = args["text"] as? String { speaker.speak(text) } else { speaker.stop() }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func pairedDevices() -> [[String: Any]] {
    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    return paired.map { device in
      [
        "name": device.name ?? "",
        "address": device.addressString ?? "",
        "connected": device.isConnected(),
      ]
    }
  }

  // MARK: Opening the channels

  /// Opens the command channel first and the data channel second, the same order as
  /// Research Kit's `Listener::init`. Completes `result` once both are open.
  private func open(
    address: String, dataChannel: BluetoothRFCOMMChannelID, serviceUuid16: BluetoothSDPUUID16,
    result: @escaping FlutterResult
  ) {
    if pendingOpen != nil {
      result(FlutterError(code: "busy", message: "An open is already in progress", details: nil))
      return
    }
    close()
    guard let device = IOBluetoothDevice(addressString: address) else {
      result(FlutterError(code: "no_device", message: "No Bluetooth device with address \(address)", details: nil))
      return
    }
    let pending = PendingOpen(device: device, serviceUuid16: serviceUuid16, dataChannel: dataChannel, result: result)
    pendingOpen = pending
    openCommandChannel(pending, allowSdpQuery: true)
  }

  private func openCommandChannel(_ pending: PendingOpen, allowSdpQuery: Bool) {
    let uuid = IOBluetoothSDPUUID(uuid16: pending.serviceUuid16)
    var channelId: BluetoothRFCOMMChannelID = 0
    if let record = pending.device.getServiceRecord(for: uuid),
      record.getRFCOMMChannelID(&channelId) == kIOReturnSuccess
    {
      let link = makeLink(role: "command")
      commandLink = link
      openWithRetry(link, pending: pending, channelId: channelId, attemptsLeft: Mw75NeuroPlugin.openAttempts) {
        [weak self] in
        pending.commandChannelId = Int(channelId)
        self?.openDataChannel(pending)
      }
      return
    }
    // The cached SDP records may be stale or missing; refresh them once and retry.
    guard allowSdpQuery else {
      failOpen(code: "no_command_service", message: "The headset does not advertise a serial-port (GAIA) service")
      return
    }
    let status = pending.device.performSDPQuery(self)
    if status != kIOReturnSuccess {
      failOpen(code: "sdp_failed", message: "Bluetooth service lookup failed to start (IOReturn \(status))")
    }
  }

  @objc public func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
    guard let pending = pendingOpen, pending.device == device else { return }
    if status != kIOReturnSuccess {
      failOpen(code: "sdp_failed", message: "Bluetooth service lookup failed (IOReturn \(status))")
      return
    }
    openCommandChannel(pending, allowSdpQuery: false)
  }

  private func openDataChannel(_ pending: PendingOpen) {
    let link = makeLink(role: "data")
    dataLink = link
    openWithRetry(link, pending: pending, channelId: pending.dataChannel, attemptsLeft: Mw75NeuroPlugin.openAttempts) {
      [weak self] in
      self?.pendingOpen = nil
      pending.result([
        "commandChannel": pending.commandChannelId ?? -1,
        "dataChannel": Int(pending.dataChannel),
      ])
    }
  }

  private func openWithRetry(
    _ link: RfcommLink, pending: PendingOpen, channelId: BluetoothRFCOMMChannelID, attemptsLeft: Int,
    onOpen: @escaping () -> Void
  ) {
    let attempt = pending.nextAttemptToken()
    link.open(device: pending.device, channelId: channelId) { [weak self] status in
      guard let self = self, self.pendingOpen === pending, pending.isCurrent(attempt) else { return }
      if status == kIOReturnSuccess {
        onOpen()
      } else {
        self.failOpen(code: "open_failed", message: "RFCOMM channel \(channelId) failed to open (IOReturn \(status))")
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Mw75NeuroPlugin.openAttemptTimeout) { [weak self] in
      guard let self = self, self.pendingOpen === pending, pending.isCurrent(attempt), !link.isOpen else { return }
      link.close()
      if attemptsLeft > 1 {
        self.openWithRetry(link, pending: pending, channelId: channelId, attemptsLeft: attemptsLeft - 1, onOpen: onOpen)
      } else {
        self.failOpen(code: "timeout", message: "Timed out opening RFCOMM channel \(channelId). Is the headset on and in range?")
      }
    }
  }

  private func failOpen(code: String, message: String) {
    guard let pending = pendingOpen else { return }
    pendingOpen = nil
    close()
    pending.result(FlutterError(code: code, message: message, details: nil))
  }

  private func makeLink(role: String) -> RfcommLink {
    return RfcommLink(
      role: role,
      onData: { [weak self] role, bytes, offsets, times in
        self?.eventSink?([
          "event": "data",
          "channel": role,
          "bytes": FlutterStandardTypedData(bytes: bytes),
          "offsets": FlutterStandardTypedData(int32: offsets.withUnsafeBufferPointer { Data(buffer: $0) }),
          "times": FlutterStandardTypedData(float64: times.withUnsafeBufferPointer { Data(buffer: $0) }),
        ])
      },
      onClosed: { [weak self] role in
        self?.eventSink?(["event": "closed", "channel": role])
      })
  }

  // MARK: Writing and closing

  private func write(_ data: Data, to link: RfcommLink?, result: FlutterResult) {
    guard let link = link, let channel = link.channel, link.isOpen else {
      result(FlutterError(code: "not_open", message: "The headset channel is not open", details: nil))
      return
    }
    var bytes = [UInt8](data)
    let status = bytes.withUnsafeMutableBytes { buffer in
      channel.writeSync(buffer.baseAddress, length: UInt16(buffer.count))
    }
    if status == kIOReturnSuccess {
      result(true)
    } else {
      result(FlutterError(code: "write_failed", message: "Bluetooth write failed (IOReturn \(status))", details: nil))
    }
  }

  private func close() {
    commandLink?.close()
    dataLink?.close()
    commandLink = nil
    dataLink = nil
  }

  /// Seconds on CLOCK_MONOTONIC_RAW, which is what liblsl's lsl_local_clock() reads
  /// on macOS (measured: equal to within microseconds). CLOCK_UPTIME_RAW would be
  /// wrong: it pauses while the Mac sleeps, so it lags LSL time by every hour the
  /// machine has slept since boot.
  static func hostClock() -> Double {
    return Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
  }
}

private final class PendingOpen {
  let device: IOBluetoothDevice
  let serviceUuid16: BluetoothSDPUUID16
  let dataChannel: BluetoothRFCOMMChannelID
  let result: FlutterResult
  var commandChannelId: Int?
  private var attemptToken = 0

  init(
    device: IOBluetoothDevice, serviceUuid16: BluetoothSDPUUID16,
    dataChannel: BluetoothRFCOMMChannelID, result: @escaping FlutterResult
  ) {
    self.device = device
    self.serviceUuid16 = serviceUuid16
    self.dataChannel = dataChannel
    self.result = result
  }

  /// Late callbacks from an abandoned attempt must not complete a newer one.
  func nextAttemptToken() -> Int {
    attemptToken += 1
    return attemptToken
  }

  func isCurrent(_ token: Int) -> Bool { token == attemptToken }
}

/// One RFCOMM channel. Received bytes are coalesced for a few milliseconds before being
/// sent to Dart: at 500 Hz the headset can otherwise produce hundreds of platform-channel
/// messages per second. Each callback's arrival time is kept so Dart can timestamp
/// packets precisely.
private final class RfcommLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
  typealias DataHandler = (String, Data, [Int32], [Double]) -> Void

  let role: String
  private(set) var channel: IOBluetoothRFCOMMChannel?
  private let onData: DataHandler
  private let onClosed: (String) -> Void
  private var onOpen: ((IOReturn) -> Void)?

  private var pending = Data()
  private var pendingOffsets: [Int32] = []
  private var pendingTimes: [Double] = []
  private var flushScheduled = false
  private static let coalesceInterval = 0.008

  var isOpen: Bool { channel?.isOpen() ?? false }

  init(role: String, onData: @escaping DataHandler, onClosed: @escaping (String) -> Void) {
    self.role = role
    self.onData = onData
    self.onClosed = onClosed
  }

  func open(
    device: IOBluetoothDevice, channelId: BluetoothRFCOMMChannelID,
    completion: @escaping (IOReturn) -> Void
  ) {
    onOpen = completion
    var opened: IOBluetoothRFCOMMChannel?
    let status = device.openRFCOMMChannelAsync(&opened, withChannelID: channelId, delegate: self)
    channel = opened
    if status != kIOReturnSuccess {
      onOpen = nil
      completion(status)
    }
  }

  func close() {
    flush()
    onOpen = nil
    let closing = channel
    channel = nil
    closing?.setDelegate(nil)
    _ = closing?.close()
  }

  func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
    guard rfcommChannel === channel || channel == nil else { return }
    channel = rfcommChannel
    let completion = onOpen
    onOpen = nil
    completion?(error)
  }

  func rfcommChannelData(
    _ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!,
    length dataLength: Int
  ) {
    let now = Mw75NeuroPlugin.hostClock()
    pendingOffsets.append(Int32(pending.count))
    pendingTimes.append(now)
    pending.append(dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength)
    if role == "command" {
      flush()
    } else if !flushScheduled {
      flushScheduled = true
      DispatchQueue.main.asyncAfter(deadline: .now() + RfcommLink.coalesceInterval) { [weak self] in
        self?.flush()
      }
    }
  }

  func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
    guard rfcommChannel === channel else { return }
    flush()
    channel = nil
    onClosed(role)
  }

  private func flush() {
    flushScheduled = false
    guard !pending.isEmpty else { return }
    onData(role, pending, pendingOffsets, pendingTimes)
    pending = Data()
    pendingOffsets = []
    pendingTimes = []
  }
}
