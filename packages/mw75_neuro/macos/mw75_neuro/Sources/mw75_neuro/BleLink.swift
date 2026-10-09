import CoreBluetooth
import FlutterMacOS

/// Bluetooth Low Energy link used by the headset's metrics session (Focus and
/// per-cup contact), which Research Kit runs over BLE rather than the classic
/// RFCOMM channels used for raw EEG.
///
/// Like the RFCOMM transport it only moves bytes: it finds the headset, subscribes
/// to the requested characteristics and forwards every notification to Dart with a
/// host timestamp. Callbacks arrive on the main queue, where Flutter channels live.
final class BleLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  typealias Emit = ([String: Any]) -> Void

  private let emit: Emit
  private lazy var central = CBCentralManager(delegate: self, queue: .main)
  private var peripheral: CBPeripheral?
  private var serviceUuid: CBUUID?
  private var notifyUuids: [CBUUID] = []
  private var nameFilter = "MW75"
  private var characteristics: [CBUUID: CBCharacteristic] = [:]
  private var awaitingSubscription = Set<CBUUID>()
  private var servicesToExplore = 0
  private var pending: FlutterResult?
  private var timeout: DispatchWorkItem?

  init(emit: @escaping Emit) {
    self.emit = emit
    super.init()
  }

  // MARK: API

  func connect(nameContains: String, service: String, notify: [String], timeoutSeconds: Double, result: @escaping FlutterResult) {
    if pending != nil {
      result(FlutterError(code: "busy", message: "A BLE connection is already being opened", details: nil))
      return
    }
    disconnect()
    nameFilter = nameContains
    serviceUuid = CBUUID(string: service)
    notifyUuids = notify.map { CBUUID(string: $0) }
    pending = result
    let work = DispatchWorkItem { [weak self] in
      self?.fail("timeout", "No MW75 found over Bluetooth Low Energy. Make sure the headset is on and close to this Mac.")
    }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
    if central.state == .poweredOn { discover() }
    // Otherwise centralManagerDidUpdateState starts discovery once Bluetooth is ready.
  }

  func write(characteristic: String, bytes: Data, withResponse: Bool, result: FlutterResult) {
    guard let p = peripheral, let c = characteristics[CBUUID(string: characteristic)] else {
      result(FlutterError(code: "not_connected", message: "The BLE link to the headset is not open", details: nil))
      return
    }
    p.writeValue(bytes, for: c, type: withResponse ? .withResponse : .withoutResponse)
    result(true)
  }

  func disconnect() {
    timeout?.cancel()
    timeout = nil
    if central.isScanning { central.stopScan() }
    if let p = peripheral {
      for c in characteristics.values where c.isNotifying {
        p.setNotifyValue(false, for: c)
      }
      central.cancelPeripheralConnection(p)
    }
    peripheral = nil
    characteristics = [:]
    awaitingSubscription = []
  }

  // MARK: Discovery

  private func discover() {
    guard let service = serviceUuid else { return }
    // A headset already connected to this Mac (for audio) may not advertise; ask the
    // system for peripherals it already has a link to first.
    let known = central.retrieveConnectedPeripherals(withServices: [service])
    if let p = known.first(where: { ($0.name ?? "").contains(nameFilter) }) ?? known.first {
      attach(p)
      return
    }
    central.scanForPeripherals(withServices: nil, options: nil)
  }

  private func attach(_ p: CBPeripheral) {
    if central.isScanning { central.stopScan() }
    peripheral = p
    p.delegate = self
    central.connect(p, options: nil)
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      if pending != nil && peripheral == nil { discover() }
    case .unauthorized:
      fail("unauthorized", "This app is not allowed to use Bluetooth. Allow it in System Settings › Privacy & Security › Bluetooth.")
    case .poweredOff:
      fail("powered_off", "Bluetooth is turned off.")
    case .unsupported:
      fail("unsupported", "This Mac does not support Bluetooth Low Energy.")
    default:
      break
    }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
    guard pending != nil, self.peripheral == nil, name.contains(nameFilter) else { return }
    attach(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    // The EEG data characteristic sits under a different base UUID, so explore every
    // service rather than only the command service.
    peripheral.discoverServices(nil)
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    fail("connect_failed", "Could not connect over BLE: \(error?.localizedDescription ?? "unknown error")")
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    guard peripheral == self.peripheral else { return }
    self.peripheral = nil
    characteristics = [:]
    if pending != nil {
      fail("disconnected", "The headset dropped the BLE connection while it was being set up.")
    } else {
      emit(["event": "bleDisconnected"])
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    let services = peripheral.services ?? []
    guard error == nil, !services.isEmpty else {
      fail("no_services", "The headset exposed no BLE services: \(error?.localizedDescription ?? "none found")")
      return
    }
    servicesToExplore = services.count
    for s in services {
      peripheral.discoverCharacteristics(nil, for: s)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    for c in service.characteristics ?? [] {
      characteristics[c.uuid] = c
    }
    servicesToExplore -= 1
    guard servicesToExplore == 0 else { return }
    for uuid in notifyUuids {
      guard let c = characteristics[uuid] else { continue }
      awaitingSubscription.insert(uuid)
      peripheral.setNotifyValue(true, for: c)
    }
    if awaitingSubscription.isEmpty { succeed() }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    if let error = error {
      emit(["event": "bleLog", "message": "Could not subscribe to \(characteristic.uuid.uuidString): \(error.localizedDescription)"])
    }
    awaitingSubscription.remove(characteristic.uuid)
    if pending != nil && awaitingSubscription.isEmpty { succeed() }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard error == nil, let value = characteristic.value else { return }
    emit([
      "event": "ble",
      "characteristic": characteristic.uuid.uuidString,
      "bytes": FlutterStandardTypedData(bytes: value),
      "time": Mw75NeuroPlugin.hostClock(),
    ])
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    if let error = error {
      emit(["event": "bleLog", "message": "Write to \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)"])
    }
  }

  // MARK: Completion

  private func succeed() {
    guard let result = pending, let p = peripheral else { return }
    pending = nil
    timeout?.cancel()
    result([
      "name": p.name ?? "",
      "identifier": p.identifier.uuidString,
      "characteristics": characteristics.values.map { c -> [String: Any] in
        ["uuid": c.uuid.uuidString, "notifying": c.isNotifying, "properties": Int(c.properties.rawValue)]
      },
      "maxWriteWithoutResponse": p.maximumWriteValueLength(for: .withoutResponse),
    ])
  }

  private func fail(_ code: String, _ message: String) {
    guard let result = pending else { return }
    pending = nil
    disconnect()
    result(FlutterError(code: code, message: message, details: nil))
  }
}
