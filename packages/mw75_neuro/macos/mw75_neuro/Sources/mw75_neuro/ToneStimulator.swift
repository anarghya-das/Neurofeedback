import AVFoundation
import AudioToolbox
import CoreAudio

/// Plays the oddball test's tones with onsets known in advance on LSL's clock.
///
/// Each tone is scheduled on an AVAudioPlayerNode at a host time slightly in the future, so
/// when it sounds does not depend on when the main thread gets around to it. The onset
/// reported back is that host time converted to LSL's clock plus the output's presentation
/// latency, which macOS reports per device (for Bluetooth headphones it includes the radio
/// link). The engine keeps running between tones, so a Bluetooth output stays awake and
/// tones are not clipped by the link starting up.
final class ToneStimulator {
  /// Earliest a tone can be scheduled from now: comfortably beyond one IO cycle.
  private static let minimumLead = 0.05
  /// Raised-cosine onset and offset, so tones start without a click.
  private static let ramp = 0.01

  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var format: AVAudioFormat?
  private var buffers: [String: AVAudioPCMBuffer] = [:]
  private var latency = 0.0

  static func outputDevices() -> [[String: Any]] {
    let defaultId = defaultOutputDevice()
    return allDevices().filter(hasOutput).map { id in
      [
        "id": Int(id),
        "name": deviceName(id),
        "isDefault": id == defaultId,
        "bluetooth": isBluetooth(id),
      ]
    }
  }

  /// Starts the engine on `deviceId`, or the system default output when nil.
  func start(deviceId: Int?) throws -> [String: Any] {
    stop()
    let engine = AVAudioEngine()
    let output = engine.outputNode
    guard let unit = output.audioUnit else { throw ToneError("The audio output is not available.") }
    if let deviceId = deviceId {
      var device = AudioDeviceID(deviceId)
      let status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
        UInt32(MemoryLayout<AudioDeviceID>.size))
      if status != noErr { throw ToneError("Could not switch to that audio output (OSStatus \(status)).") }
    }
    let hardware = output.outputFormat(forBus: 0)
    guard hardware.sampleRate > 0, hardware.channelCount > 0,
      let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 2)
    else { throw ToneError("No audio output device is available.") }

    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    engine.prepare()
    try engine.start()
    player.play()
    self.engine = engine
    self.player = player
    self.format = format

    var device: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
    latency = output.presentationLatency
    if latency <= 0 { latency = ToneStimulator.reportedLatency(device, sampleRate: hardware.sampleRate) }
    return [
      "device": ToneStimulator.deviceName(device),
      "bluetooth": ToneStimulator.isBluetooth(device),
      "sampleRate": hardware.sampleRate,
      "latency": latency,
    ]
  }

  /// Schedules a tone to be heard at `onset` (LSL clock seconds), or as soon as possible
  /// when that is nil or too soon. Returns when it will be heard, on LSL's clock.
  func play(frequency: Double, duration: Double, amplitude: Double, at onset: Double?) throws -> Double {
    guard let engine = engine, engine.isRunning, let player = player, let format = format else {
      throw ToneError("Audio output stopped. Was the output device changed or disconnected?")
    }
    let buffer = try tone(frequency: frequency, duration: duration, amplitude: amplitude, format: format)
    // Host time is mach_absolute_time, i.e. CLOCK_UPTIME_RAW. LSL reads CLOCK_MONOTONIC_RAW,
    // which also counts time asleep; the difference is constant while the Mac is awake.
    let uptimeToLsl =
      Double(Int64(bitPattern: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) &- clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
      / 1e9
    let earliest = AVAudioTime.seconds(forHostTime: mach_absolute_time()) + ToneStimulator.minimumLead
    var start = earliest
    if let onset = onset { start = max(earliest, onset - latency - uptimeToLsl) }
    player.scheduleBuffer(buffer, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start)), options: [])
    return start + uptimeToLsl + latency
  }

  func stop() {
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    format = nil
    buffers = [:]
  }

  private func tone(frequency: Double, duration: Double, amplitude: Double, format: AVAudioFormat) throws
    -> AVAudioPCMBuffer
  {
    let key = "\(frequency)/\(duration)/\(amplitude)"
    if let cached = buffers[key] { return cached }
    let rate = format.sampleRate
    let frames = Int((duration * rate).rounded())
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
      let channels = buffer.floatChannelData
    else { throw ToneError("Could not create the tone.") }
    buffer.frameLength = AVAudioFrameCount(frames)
    let rampFrames = max(1, min(Int(ToneStimulator.ramp * rate), frames / 2))
    for i in 0..<frames {
      var gain = amplitude
      let edge = min(i, frames - 1 - i)
      if edge < rampFrames { gain *= 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(rampFrames)) }
      let value = Float(gain * sin(2 * Double.pi * frequency * Double(i) / rate))
      for c in 0..<Int(format.channelCount) { channels[c][i] = value }
    }
    buffers[key] = buffer
    return buffer
  }

  // MARK: Core Audio devices

  /// Element 0 is the main element (`kAudioObjectPropertyElementMain` needs macOS 12).
  private static func address(
    _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
  }

  private static func allDevices() -> [AudioDeviceID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
  }

  private static func hasOutput(_ id: AudioDeviceID) -> Bool {
    var address = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
  }

  private static func uint32(
    _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> UInt32? {
    var address = address(selector, scope)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
  }

  private static func defaultOutputDevice() -> AudioDeviceID {
    uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0
  }

  private static func deviceName(_ id: AudioDeviceID) -> String {
    var address = address(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
    guard status == noErr, let name = name else { return "Unknown output" }
    return name.takeRetainedValue() as String
  }

  private static func isBluetooth(_ id: AudioDeviceID) -> Bool {
    let transport = uint32(id, kAudioDevicePropertyTransportType)
    return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
  }

  /// Device plus stream latency in seconds, for when the engine reports none.
  private static func reportedLatency(_ id: AudioDeviceID, sampleRate: Double) -> Double {
    var frames = uint32(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) ?? 0
    var address = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
    var size = UInt32(MemoryLayout<AudioStreamID>.size)
    var stream: AudioStreamID = 0
    if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &stream) == noErr {
      frames += uint32(stream, kAudioStreamPropertyLatency) ?? 0
    }
    return Double(frames) / sampleRate
  }
}

/// Spoken instructions ("Close your eyes") on the system output, for tests run with
/// the eyes closed. Timing is not critical: analyses skip the first seconds after a cue.
final class CueSpeaker {
  /// Held for the app's lifetime: the system does not retain a synthesizer while it speaks.
  private let synthesizer = AVSpeechSynthesizer()

  func speak(_ text: String) {
    synthesizer.stopSpeaking(at: .immediate)
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    synthesizer.speak(utterance)
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
  }
}

struct ToneError: LocalizedError {
  init(_ message: String) { self.message = message }
  let message: String
  var errorDescription: String? { message }
}
