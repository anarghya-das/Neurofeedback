// Hardware probe for the Neurable MW75 Neuro, independent of the Flutter app.
//
//   tools/mw75_probe/build.sh
//   tools/mw75_probe/mw75_probe <bt-address> sdp                         # list RFCOMM services
//   tools/mw75_probe/mw75_probe <bt-address> query                       # read-only commands
//   tools/mw75_probe/mw75_probe <bt-address> startstop [cycles] [secs]   # verify start/stop
//
// `startstop` checks that raw EEG is off, starts it, confirms packets flow, stops it and
// confirms they stop, `cycles` times on one connection. It exits 0 only if every check
// passes. Commands are the bytes Neurable Research Kit 1.1.3 sends (see
// docs/neurable-mw75-protocol.md), so this tells whether a problem is in the headset
// link or in the app.

import Foundation
import IOBluetooth

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
func hostClock() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }
func spin(_ seconds: Double, until done: () -> Bool = { false }) {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end && !done() { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

struct Command {
  let name: String
  let bytes: [UInt8]
  var vendor: [UInt8] { Array(bytes[4...5]) }
  var id: UInt8 { bytes[7] }

  static func mw75(_ name: String, _ id: UInt8, _ arg: UInt8) -> Command {
    Command(name: name, bytes: [0xFF, 0x04, 0x00, 0x01, 0x09, 0x9A, 0x03, id, arg])
  }
  static let getConnectedCount = mw75("get_connected_devices_count", 0x1E, 0xFF)
  static let getBattery = mw75("get_battery_level", 0x14, 0xFF)
  static let getRawEegFeature = mw75("get_raw_eeg_feature_status", 0x6B, 0xFF)
  static let getEegMode = mw75("get_eeg_mode", 0x49, 0xFF)
  static let enableEeg = mw75("enable_eeg", 0x60, 0x01)
  static let enableRawMode = mw75("enable_raw_mode", 0x41, 0x01)
  static let disableRawMode = mw75("disable_raw_mode", 0x41, 0x00)
  static let getCurrentState = mw75("get_current_state", 0x79, 0xFF)
  // Speculative: the per-cup contact message (0xE1) is unsolicited in metrics mode;
  // this probes whether sending it as a "get" elicits a reply during raw mode.
  static let getContact = mw75("get_contact?", 0xE1, 0xFF)
  static let getVersion = Command(name: "get_application_version", bytes: [0xFF, 0x04, 0x00, 0x00, 0x00, 0x1D, 0x00, 0x05])
}

/// A GAIA frame: FF <version> <flags> <len> <vendor:2> <command:2> <payload[len]> [checksum].
struct Frame {
  let bytes: [UInt8]
  func answers(_ c: Command) -> Bool { Array(bytes[4...5]) == c.vendor && bytes[7] == c.id }
  var acknowledged: Bool { bytes.count > 8 && bytes[8] == 0xF1 }
  var value: UInt8? { bytes.count > 9 ? bytes[9] : nil }
}

final class Probe: NSObject, IOBluetoothRFCOMMChannelDelegate {
  let device: IOBluetoothDevice
  var commandChannel: IOBluetoothRFCOMMChannel?
  var dataChannel: IOBluetoothRFCOMMChannel?
  var openResults: [UInt8: IOReturn] = [:]
  var commandBuffer: [UInt8] = []
  var frames: [Frame] = []
  var dataBytes: [UInt8] = []
  var sdpDone = false
  var verbose = true

  init(device: IOBluetoothDevice) { self.device = device }

  // MARK: Delegate

  func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
    openResults[channel.getID()] = status
  }

  func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
    let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: length))
    if channel === commandChannel {
      commandBuffer += bytes
      parseFrames()
    } else {
      dataBytes += bytes
    }
  }

  func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
    if verbose { print("  channel \(channel.getID()) closed") }
  }

  @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { sdpDone = true }

  private func parseFrames() {
    while true {
      guard let start = commandBuffer.firstIndex(of: 0xFF) else { commandBuffer.removeAll(); return }
      if start > 0 { commandBuffer.removeFirst(start) }
      guard commandBuffer.count >= 8 else { return }
      let length = 8 + Int(commandBuffer[3]) + (commandBuffer[2] & 1 != 0 ? 1 : 0)
      guard commandBuffer.count >= length else { return }
      let frame = Frame(bytes: Array(commandBuffer[0..<length]))
      commandBuffer.removeFirst(length)
      frames.append(frame)
      if verbose { print(String(format: "  [%.3f] <- %@", hostClock(), hex(frame.bytes))) }
    }
  }

  // MARK: Channels

  func listServices() {
    sdpDone = false
    _ = device.performSDPQuery(self)
    spin(15) { sdpDone }
    for case let record as IOBluetoothSDPServiceRecord in device.services ?? [] {
      var channel: BluetoothRFCOMMChannelID = 0
      let hasRfcomm = record.getRFCOMMChannelID(&channel) == kIOReturnSuccess
      let spp = record.matchesUUID16(BluetoothSDPUUID16(0x1101))
      print("  service \"\(record.getServiceName() ?? "?")\" rfcomm=\(hasRfcomm ? String(channel) : "-") serialPort=\(spp)")
    }
  }

  func commandChannelId() -> BluetoothRFCOMMChannelID? {
    let uuid = IOBluetoothSDPUUID(uuid16: BluetoothSDPUUID16(0x1101))
    var channel: BluetoothRFCOMMChannelID = 0
    if let record = device.getServiceRecord(for: uuid), record.getRFCOMMChannelID(&channel) == kIOReturnSuccess {
      return channel
    }
    return nil
  }

  /// Same strategy as the Flutter plugin: the headset's first open after a fresh
  /// baseband session never completes, so give each attempt 3 s, then close and retry.
  func open(_ id: BluetoothRFCOMMChannelID, attempts: Int = 4) -> IOBluetoothRFCOMMChannel? {
    for attempt in 1...attempts {
      openResults[id] = nil
      var channel: IOBluetoothRFCOMMChannel?
      let t0 = hostClock()
      let status = device.openRFCOMMChannelAsync(&channel, withChannelID: id, delegate: self)
      guard status == kIOReturnSuccess else {
        print("  open(\(id)) attempt \(attempt) failed immediately: \(status)")
        continue
      }
      spin(3) { openResults[id] != nil }
      if openResults[id] == kIOReturnSuccess {
        print(String(format: "  channel %d open after %.2f s (attempt %d)", id, hostClock() - t0, attempt))
        return channel
      }
      print("  channel \(id) attempt \(attempt): \(openResults[id].map { "status \($0)" } ?? "no callback in 3 s"), retrying")
      _ = channel?.close()
      spin(0.5)
    }
    return nil
  }

  func close() {
    _ = dataChannel?.close()
    _ = commandChannel?.close()
    spin(0.5)
  }

  // MARK: Commands

  @discardableResult
  func send(_ command: Command, timeout: Double = 1.5) -> Frame? {
    guard let channel = commandChannel else { return nil }
    let seen = frames.count
    var copy = command.bytes
    let status = copy.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
    if verbose { print(String(format: "  [%.3f] -> %@  (%@)", hostClock(), hex(command.bytes), command.name)) }
    guard status == kIOReturnSuccess else {
      print("  write failed: \(status)")
      return nil
    }
    var reply: Frame?
    spin(timeout) {
      reply = frames[seen...].first { $0.answers(command) }
      return reply != nil
    }
    if reply == nil && verbose { print("  \(command.name): no reply") }
    return reply
  }

  // MARK: Data

  /// Collects data for `seconds` and returns (bytes, valid packets, counter span).
  func measure(_ seconds: Double) -> (bytes: Int, packets: Int, counterSpan: Int) {
    let start = dataBytes.count
    spin(seconds)
    let chunk = Array(dataBytes[start...])
    var packets = 0, span = 0, i = 0
    var last: Int?
    while chunk.count - i >= 63 {
      if chunk[i] == 0xAA && chunk[i + 1] == 0xEF && chunk[i + 2] == 60 {
        let sum = chunk[i...(i + 60)].reduce(0) { $0 + Int($1) } & 0xFFFF
        if sum == Int(chunk[i + 61]) | Int(chunk[i + 62]) << 8 {
          let counter = Int(chunk[i + 3])
          if let l = last { span += (counter - l) & 0xFF }
          last = counter
          packets += 1
          i += 63
          continue
        }
      }
      i += 1
    }
    return (chunk.count, packets, span)
  }
}

final class Checks {
  private(set) var failed = 0
  func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "PASS" : "FAIL")  \(what)")
    if !ok { failed += 1 }
  }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
  print("usage: mw75_probe <bt-address> sdp|query|reset|startstop [cycles] [secs]|contact [secs]")
  exit(2)
}
guard let device = IOBluetoothDevice(addressString: args[1]) else {
  print("no device \(args[1])")
  exit(1)
}
print("device \(device.name ?? "?") \(device.addressString ?? "") connected=\(device.isConnected())")
let probe = Probe(device: device)

func openChannels() -> Bool {
  if probe.commandChannelId() == nil { probe.listServices() }
  guard let commandId = probe.commandChannelId() else {
    print("no serial-port (GAIA) service record")
    return false
  }
  print("opening GAIA command channel \(commandId) and data channel 25")
  probe.commandChannel = probe.open(commandId)
  probe.dataChannel = probe.open(25)
  return probe.commandChannel != nil && probe.dataChannel != nil
}

switch args[2] {
case "sdp":
  probe.listServices()

case "reset":
  // Drop the baseband connection so the next run starts a fresh link; macOS
  // reconnects the headset for audio on its own.
  let status = device.closeConnection()
  print("closeConnection -> \(status)")
  spin(3)
  print("connected after reset: \(device.isConnected())")

case "query":
  guard openChannels() else { exit(1) }
  spin(0.5)
  for c in [Command.getConnectedCount, .getBattery, .getVersion, .getRawEegFeature, .getEegMode] { probe.send(c) }
  probe.close()

case "startstop":
  let cycles = args.count > 3 ? Int(args[3]) ?? 2 : 2
  let seconds = args.count > 4 ? Double(args[4]) ?? 5 : 5
  let checks = Checks()
  guard openChannels() else {
    checks.check(false, "open both RFCOMM channels")
    exit(1)
  }
  checks.check(true, "open both RFCOMM channels")
  spin(0.5)

  let battery = probe.send(.getBattery)
  print("battery: \(battery?.value.map { "\($0)%" } ?? "unknown")")
  let feature = probe.send(.getRawEegFeature)
  print("raw EEG feature status: \(feature?.value.map(String.init) ?? "no reply")")
  let mode = probe.send(.getEegMode)
  if mode?.value != 1 {
    print("EEG mode is off, enabling")
    checks.check(probe.send(.enableEeg)?.acknowledged == true, "enable_eeg acknowledged")
  }

  // The headset may have been left streaming by a crashed session; start from off.
  let before = probe.measure(1.5)
  if before.bytes > 0 {
    print("data was already flowing (\(before.bytes) bytes); stopping first")
    probe.send(.disableRawMode)
    spin(1.5)
  }
  let baseline = probe.measure(1.5)
  checks.check(baseline.bytes == 0, "no EEG data before start (\(baseline.bytes) bytes in 1.5 s)")

  for cycle in 1...cycles {
    print("--- cycle \(cycle)/\(cycles) ---")
    let startAck = probe.send(.enableRawMode)
    checks.check(startAck?.acknowledged == true, "start: enable_raw_mode acknowledged")
    spin(1.0)  // first packets arrive ~1 s after the ACK
    probe.verbose = false
    let streaming = probe.measure(seconds)
    probe.verbose = true
    let rate = Double(streaming.packets) / seconds
    let sent = Double(streaming.counterSpan) / seconds
    print(String(format: "  %d packets in %.0f s = %.0f/s received; headset counter advanced %.0f/s (%.1f%% lost)",
      streaming.packets, seconds, rate, sent, sent > 0 ? 100 * (1 - rate / sent) : 0))
    print(String(format: "  raw throughput %.0f bytes/s (500 Hz needs 31500); link RSSI %d dBm, raw RSSI %d",
      Double(streaming.bytes) / seconds, device.rssi(), device.rawRSSI()))
    checks.check(streaming.packets > Int(seconds * 100), "start: EEG packets flowing")

    let stopAck = probe.send(.disableRawMode)
    checks.check(stopAck?.acknowledged == true, "stop: disable_raw_mode acknowledged")
    spin(1.0)  // let bytes already in flight drain
    let after = probe.measure(2.0)
    checks.check(after.bytes == 0, "stop: no EEG data after stop (\(after.bytes) bytes in 2 s)")
  }

  probe.close()
  print(checks.failed == 0 ? "ALL CHECKS PASSED" : "\(checks.failed) CHECK(S) FAILED")
  exit(checks.failed == 0 ? 0 : 1)

case "contact":
  // Tests whether the headset will report its per-cup contact level
  // (09 9A 03 E1 <left> <right>, 0-5 each) during raw EEG streaming, by polling the
  // command channel while raw mode is on. Research Kit only gets contact in metrics
  // (BLE) mode; on hardware the headset otherwise emits E1 on RFCOMM only when the
  // command channel opens and once when raw mode ends (docs/neurable-mw75-protocol.md).
  let seconds = args.count > 3 ? Double(args[3]) ?? 20 : 20
  guard openChannels() else { exit(1) }
  spin(0.5)

  // E1 contact frames seen on the command channel from `index` onward.
  func contactFrames(from index: Int) -> [Frame] {
    probe.frames[index...].filter {
      $0.bytes.count >= 10 && $0.bytes[4] == 0x09 && $0.bytes[5] == 0x9A && $0.bytes[7] == 0xE1
    }
  }
  // E1 signatures muxed into the data channel (command replies share it, sync 0xF6),
  // found by raw pattern 09 9A 03 E1 <L> <R>.
  func contactInData(_ chunk: [UInt8]) -> [(UInt8, UInt8)] {
    var hits: [(UInt8, UInt8)] = []
    var i = 0
    while i + 5 < chunk.count {
      if chunk[i] == 0x09 && chunk[i + 1] == 0x9A && chunk[i + 2] == 0x03 && chunk[i + 3] == 0xE1 {
        hits.append((chunk[i + 4], chunk[i + 5])); i += 6
      } else { i += 1 }
    }
    return hits
  }
  func printContacts(_ fs: [Frame]) {
    for f in fs { print("    \(hex(f.bytes))  L=\(f.bytes[8]) R=\(f.bytes[9])") }
  }

  if probe.send(.getEegMode)?.value != 1 { probe.send(.enableEeg) }

  print("=== phase 0: 3 s idle (command channel open, raw mode off) ===")
  var idx = probe.frames.count
  spin(3)
  let idleContacts = contactFrames(from: idx)
  print("  E1 contact frames while idle: \(idleContacts.count)")
  printContacts(idleContacts)

  if probe.measure(1.0).bytes > 0 { probe.send(.disableRawMode); spin(1.0) }
  print("=== phase 1: enable raw mode ===")
  print("  enable_raw_mode acknowledged: \(probe.send(.enableRawMode)?.acknowledged == true)")
  spin(1.0)
  let warm = probe.measure(2.0)
  print("  EEG packets in 2 s: \(warm.packets) (streaming=\(warm.packets > 50))")

  print("=== phase 2: poll for contact during raw streaming (\(Int(seconds)) s) ===")
  idx = probe.frames.count
  let dataStart = probe.dataBytes.count
  let pollers: [Command] = [.getCurrentState, .getContact, .getBattery]
  let deadline = Date().addingTimeInterval(seconds)
  var tick = 0
  while Date() < deadline {
    probe.send(pollers[tick % pollers.count], timeout: 0.8)
    tick += 1
    spin(1.0)
  }
  let streamFrames = contactFrames(from: idx)
  let streamData = contactInData(Array(probe.dataBytes[dataStart...]))
  print("  E1 frames on command channel during streaming: \(streamFrames.count)")
  printContacts(streamFrames)
  print("  E1 signatures in raw data channel during streaming: \(streamData.count)")
  for (l, r) in streamData.prefix(10) { print("    data E1  L=\(l) R=\(r)") }

  idx = probe.frames.count
  probe.send(.disableRawMode)
  spin(1.5)
  let endContacts = contactFrames(from: idx)
  print("=== phase 3: \(endContacts.count) E1 frame(s) at raw-mode-end ===")
  printContacts(endContacts)

  probe.close()
  let viable = !streamFrames.isEmpty || !streamData.isEmpty
  print(viable
    ? "RESULT: contact (E1) IS reachable during raw streaming (\(streamFrames.count) cmd + \(streamData.count) data frames) — Option B viable: poll ~1/s."
    : "RESULT: no contact (E1) during raw streaming — Option B not viable; use host-side signal quality (Option A).")
  exit(viable ? 0 : 1)

default:
  print("unknown mode \(args[2])")
  exit(2)
}
