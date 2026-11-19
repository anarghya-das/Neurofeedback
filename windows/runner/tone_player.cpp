#include "tone_player.h"

#include <windows.h>

#include <audioclient.h>
#include <avrt.h>
#include <devicetopology.h>
#include <endpointvolume.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <wrl/client.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cwctype>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

constexpr double kPi = 3.14159265358979323846;

// Raised-cosine onset and offset, so tones start without a click (as on macOS).
constexpr double kRamp = 0.01;

// Earliest a tone can be scheduled after the frames already handed to Windows.
constexpr double kMinimumLead = 0.02;

// Asked-for WASAPI buffer: 20 ms. Shared mode may round it up.
constexpr REFERENCE_TIME kBufferDuration = 200000;

// KSDATAFORMAT_SUBTYPE_IEEE_FLOAT, spelled out so no GUID library is needed.
const GUID kSubtypeFloat = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};

// PKEY_Device_FriendlyName.
const PROPERTYKEY kFriendlyName = {{0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};

std::string Utf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
  std::string out(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), out.data(), size, nullptr, nullptr);
  return out;
}

std::wstring Lower(std::wstring s) {
  std::transform(s.begin(), s.end(), s.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return s;
}

std::string HrText(const char* what, HRESULT hr) {
  char buffer[160];
  snprintf(buffer, sizeof(buffer), "%s (HRESULT 0x%08lX).", what, static_cast<unsigned long>(hr));
  return buffer;
}

ComPtr<IMMDeviceEnumerator> Enumerator() {
  ComPtr<IMMDeviceEnumerator> enumerator;
  CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
  return enumerator;
}

std::wstring DeviceId(IMMDevice* device) {
  LPWSTR id = nullptr;
  if (FAILED(device->GetId(&id)) || id == nullptr) return {};
  std::wstring out(id);
  CoTaskMemFree(id);
  return out;
}

std::wstring FriendlyName(IMMDevice* device) {
  ComPtr<IPropertyStore> store;
  if (FAILED(device->OpenPropertyStore(STGM_READ, &store))) return {};
  PROPVARIANT value;
  PropVariantInit(&value);
  std::wstring name;
  if (SUCCEEDED(store->GetValue(kFriendlyName, &value)) && value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
    name = value.pwszVal;
  }
  PropVariantClear(&value);
  return name;
}

// True for a Bluetooth output: the kernel-streaming device behind the endpoint
// comes from a Bluetooth enumerator (BTHENUM for A2DP, BTHHFENUM for hands-free).
// Falls back to the endpoint's name.
bool IsBluetooth(IMMDevice* device) {
  ComPtr<IDeviceTopology> topology;
  if (SUCCEEDED(device->Activate(__uuidof(IDeviceTopology), CLSCTX_ALL, nullptr, &topology))) {
    ComPtr<IConnector> connector;
    ComPtr<IConnector> other;
    ComPtr<IPart> part;
    ComPtr<IDeviceTopology> filter;
    LPWSTR filterId = nullptr;
    if (SUCCEEDED(topology->GetConnector(0, &connector)) && SUCCEEDED(connector->GetConnectedTo(&other)) &&
        SUCCEEDED(other.As(&part)) && SUCCEEDED(part->GetTopologyObject(&filter)) &&
        SUCCEEDED(filter->GetDeviceId(&filterId)) && filterId != nullptr) {
      std::wstring id = Lower(filterId);
      CoTaskMemFree(filterId);
      if (id.find(L"bthenum") != std::wstring::npos || id.find(L"bthhfenum") != std::wstring::npos ||
          id.find(L"bthleenum") != std::wstring::npos) {
        return true;
      }
    }
  }
  std::wstring name = Lower(FriendlyName(device));
  return name.find(L"bluetooth") != std::wstring::npos || name.find(L"hands-free") != std::wstring::npos;
}

// Endpoint ids of the last device list, so Dart can name a device by index.
std::vector<std::wstring> g_device_ids;

ComPtr<IMMDevice> DeviceFor(const std::optional<int>& index, std::string* error) {
  ComPtr<IMMDeviceEnumerator> enumerator = Enumerator();
  ComPtr<IMMDevice> device;
  if (!enumerator) {
    *error = "The Windows audio system is not available.";
    return nullptr;
  }
  if (!index) {
    HRESULT hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) *error = HrText("No audio output device is available", hr);
    return device;
  }
  if (*index < 0 || *index >= static_cast<int>(g_device_ids.size())) {
    *error = "That audio output is no longer available. Refresh the list of outputs.";
    return nullptr;
  }
  HRESULT hr = enumerator->GetDevice(g_device_ids[*index].c_str(), &device);
  if (FAILED(hr)) *error = HrText("That audio output is no longer available", hr);
  return device;
}

EncodableList OutputDevices() {
  EncodableList list;
  g_device_ids.clear();
  ComPtr<IMMDeviceEnumerator> enumerator = Enumerator();
  if (!enumerator) return list;
  std::wstring defaultId;
  ComPtr<IMMDevice> defaultDevice;
  if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &defaultDevice))) {
    defaultId = DeviceId(defaultDevice.Get());
  }
  ComPtr<IMMDeviceCollection> devices;
  if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &devices))) return list;
  UINT count = 0;
  devices->GetCount(&count);
  for (UINT i = 0; i < count; i++) {
    ComPtr<IMMDevice> device;
    if (FAILED(devices->Item(i, &device))) continue;
    std::wstring id = DeviceId(device.Get());
    int index = static_cast<int>(g_device_ids.size());
    g_device_ids.push_back(id);
    list.push_back(EncodableValue(EncodableMap{
        {EncodableValue("id"), EncodableValue(index)},
        {EncodableValue("name"), EncodableValue(Utf8(FriendlyName(device.Get())))},
        {EncodableValue("isDefault"), EncodableValue(!defaultId.empty() && id == defaultId)},
        {EncodableValue("bluetooth"), EncodableValue(IsBluetooth(device.Get()))},
    }));
  }
  return list;
}

ComPtr<IAudioEndpointVolume> EndpointVolume(const std::optional<int>& index) {
  std::string error;
  ComPtr<IMMDevice> device = DeviceFor(index, &error);
  ComPtr<IAudioEndpointVolume> volume;
  if (device) device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr, &volume);
  return volume;
}

// A tone waiting to be mixed in, from frame `start` of the stream.
struct Scheduled {
  uint64_t start;
  std::shared_ptr<const std::vector<float>> samples;
};

class TonePlayer {
 public:
  ~TonePlayer() { Stop(); }

  // Starts a WASAPI stream on the output (the default when none) that plays
  // silence between tones until Stop. Fills `info` like the macOS app.
  std::string Start(const std::optional<int>& index, EncodableMap* info) {
    Stop();
    std::string error;
    ComPtr<IMMDevice> device = DeviceFor(index, &error);
    if (!device) return error;
    deviceName_ = Utf8(FriendlyName(device.Get()));
    bluetooth_ = IsBluetooth(device.Get());
    std::wstring id = DeviceId(device.Get());

    {
      std::lock_guard<std::mutex> lock(mutex_);
      ready_ = false;
      startError_.clear();
      failed_ = false;
      haveClock_ = false;
      written_ = 0;
      scheduled_.clear();
      holding_ = false;
    }
    stopEvent_ = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    thread_ = std::thread([this, id] { Run(id); });

    std::unique_lock<std::mutex> lock(mutex_);
    if (!readyChanged_.wait_for(lock, std::chrono::seconds(5), [this] { return ready_; })) {
      lock.unlock();
      Stop();
      return "The audio output did not start within 5 s.";
    }
    if (!startError_.empty()) {
      std::string message = startError_;
      lock.unlock();
      Stop();
      return message;
    }
    *info = EncodableMap{
        {EncodableValue("device"), EncodableValue(deviceName_)},
        {EncodableValue("bluetooth"), EncodableValue(bluetooth_)},
        {EncodableValue("sampleRate"), EncodableValue(rate_)},
        {EncodableValue("latency"), EncodableValue(latency_)},
    };
    return {};
  }

  // Schedules a tone to be heard at `onset` (LSL seconds, which on Windows is
  // the performance counter), or as soon as possible; returns when it will be
  // heard. The stream position WASAPI reports is the frame playing at the
  // output at a known performance-counter time, so the frame heard at a given
  // time follows directly (for a Bluetooth output, the radio's own delay is not
  // in it).
  std::string Play(double frequency, double duration, double amplitude, const std::optional<double>& onset,
                   double* heard) {
    std::unique_lock<std::mutex> lock(mutex_);
    // Right after Start the first stream position may not be in yet.
    readyChanged_.wait_for(lock, std::chrono::milliseconds(300), [this] { return haveClock_ || failed_ || !running_; });
    if (!running_ || failed_ || !haveClock_) {
      return "Audio output stopped. Was the output device changed or disconnected?";
    }
    auto samples = Tone(frequency, duration, amplitude);
    if (!samples) return "Could not create the tone.";
    double earliest = static_cast<double>(written_) + kMinimumLead * rate_;
    double frame = earliest;
    if (onset) frame = std::max(earliest, clockFrames_ + (*onset - clockSeconds_) * rate_);
    uint64_t start = static_cast<uint64_t>(std::llround(frame));
    scheduled_.push_back({start, samples});
    *heard = clockSeconds_ + (static_cast<double>(start) - clockFrames_) / rate_;
    return {};
  }

  // A steady tone until Release, for a sound level meter; cancels scheduled tones.
  std::string Hold(double frequency, double amplitude) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_ || failed_) return "Audio output stopped. Was the output device changed or disconnected?";
    scheduled_.clear();
    holding_ = true;
    holdStart_ = written_;
    holdFrequency_ = std::max(1.0, std::round(frequency));
    holdAmplitude_ = amplitude;
    return {};
  }

  void Release() {
    std::lock_guard<std::mutex> lock(mutex_);
    holding_ = false;
    scheduled_.clear();
  }

  void Stop() {
    if (thread_.joinable()) {
      SetEvent(stopEvent_);
      thread_.join();
    }
    if (stopEvent_ != nullptr) {
      CloseHandle(stopEvent_);
      stopEvent_ = nullptr;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    running_ = false;
    scheduled_.clear();
    holding_ = false;
    tones_.clear();
  }

 private:
  void Ready(const std::string& error) {
    std::lock_guard<std::mutex> lock(mutex_);
    startError_ = error;
    ready_ = true;
    readyChanged_.notify_all();
  }

  // The render thread: opens the stream, then refills it each time WASAPI asks.
  void Run(std::wstring deviceId) {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool comStarted = SUCCEEDED(hr);
    DWORD taskIndex = 0;
    HANDLE task = AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);
    HANDLE bufferEvent = CreateEvent(nullptr, FALSE, FALSE, nullptr);

    ComPtr<IMMDeviceEnumerator> enumerator = Enumerator();
    ComPtr<IMMDevice> device;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioRenderClient> render;
    ComPtr<IAudioClock> clock;
    UINT32 bufferFrames = 0;
    UINT64 clockFrequency = 1;
    bool started = false;

    auto cleanup = [&] {
      if (started) client->Stop();
      render.Reset();
      clock.Reset();
      client.Reset();
      device.Reset();
      enumerator.Reset();
      if (bufferEvent != nullptr) CloseHandle(bufferEvent);
      if (task != nullptr) AvRevertMmThreadCharacteristics(task);
      if (comStarted) CoUninitialize();
    };

    if (!enumerator || FAILED(hr = enumerator->GetDevice(deviceId.c_str(), &device))) {
      Ready(HrText("That audio output is no longer available", hr));
      cleanup();
      return;
    }
    if (FAILED(hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client))) {
      Ready(HrText("Could not open the audio output", hr));
      cleanup();
      return;
    }
    WAVEFORMATEX* mix = nullptr;
    if (FAILED(hr = client->GetMixFormat(&mix))) {
      Ready(HrText("Could not read the audio output's format", hr));
      cleanup();
      return;
    }
    double rate = static_cast<double>(mix->nSamplesPerSec);
    CoTaskMemFree(mix);

    // Stereo 32-bit float at the output's own rate; Windows converts if needed.
    WAVEFORMATEXTENSIBLE format = {};
    format.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    format.Format.nChannels = 2;
    format.Format.nSamplesPerSec = static_cast<DWORD>(rate);
    format.Format.wBitsPerSample = 32;
    format.Format.nBlockAlign = 2 * 4;
    format.Format.nAvgBytesPerSec = format.Format.nSamplesPerSec * format.Format.nBlockAlign;
    format.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    format.Samples.wValidBitsPerSample = 32;
    format.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
    format.SubFormat = kSubtypeFloat;

    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                            AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                            kBufferDuration, 0, reinterpret_cast<WAVEFORMATEX*>(&format), nullptr);
    if (FAILED(hr)) {
      Ready(HrText("Could not start the audio output", hr));
      cleanup();
      return;
    }
    REFERENCE_TIME streamLatency = 0;
    client->GetStreamLatency(&streamLatency);
    if (FAILED(hr = client->SetEventHandle(bufferEvent)) || FAILED(hr = client->GetBufferSize(&bufferFrames)) ||
        FAILED(hr = client->GetService(IID_PPV_ARGS(&render))) ||
        FAILED(hr = client->GetService(IID_PPV_ARGS(&clock))) || FAILED(hr = clock->GetFrequency(&clockFrequency))) {
      Ready(HrText("Could not set up the audio output", hr));
      cleanup();
      return;
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      rate_ = rate;
      latency_ = static_cast<double>(streamLatency) / 1e7 + static_cast<double>(bufferFrames) / rate;
    }
    // Start with a full buffer of silence, as WASAPI recommends.
    if (!Refill(render.Get(), client.Get(), bufferFrames) || FAILED(hr = client->Start())) {
      Ready(HrText("Could not start the audio output", hr));
      cleanup();
      return;
    }
    started = true;
    UpdateClock(clock.Get(), clockFrequency);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      running_ = true;
    }
    Ready({});

    HANDLE waits[2] = {stopEvent_, bufferEvent};
    for (;;) {
      DWORD signalled = WaitForMultipleObjects(2, waits, FALSE, 2000);
      if (signalled == WAIT_OBJECT_0) break;
      if (signalled == WAIT_TIMEOUT) {
        // No buffer request for 2 s: the device stopped (unplugged, sleep).
        std::lock_guard<std::mutex> lock(mutex_);
        failed_ = true;
        continue;
      }
      if (!Refill(render.Get(), client.Get(), bufferFrames)) {
        std::lock_guard<std::mutex> lock(mutex_);
        failed_ = true;
        break;
      }
      UpdateClock(clock.Get(), clockFrequency);
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      running_ = false;
    }
    cleanup();
  }

  // Writes as many frames as the buffer has room for; false once the device is gone.
  bool Refill(IAudioRenderClient* render, IAudioClient* client, UINT32 bufferFrames) {
    UINT32 padding = 0;
    if (FAILED(client->GetCurrentPadding(&padding))) return false;
    UINT32 frames = bufferFrames - padding;
    if (frames == 0) return true;
    BYTE* data = nullptr;
    if (FAILED(render->GetBuffer(frames, &data))) return false;
    Mix(reinterpret_cast<float*>(data), frames);
    return SUCCEEDED(render->ReleaseBuffer(frames, 0));
  }

  void Mix(float* out, UINT32 frames) {
    std::lock_guard<std::mutex> lock(mutex_);
    int rampFrames = std::max(1, static_cast<int>(kRamp * rate_));
    for (UINT32 i = 0; i < frames; i++) {
      uint64_t frame = written_ + i;
      double value = 0;
      if (holding_) {
        double k = static_cast<double>(frame - holdStart_);
        double gain = holdAmplitude_;
        if (k < rampFrames) gain *= 0.5 - 0.5 * std::cos(kPi * k / rampFrames);
        value += gain * std::sin(2 * kPi * holdFrequency_ * k / rate_);
      }
      for (const auto& tone : scheduled_) {
        if (frame >= tone.start && frame - tone.start < tone.samples->size()) {
          value += (*tone.samples)[static_cast<size_t>(frame - tone.start)];
        }
      }
      float sample = static_cast<float>(value);
      out[2 * i] = sample;
      out[2 * i + 1] = sample;
    }
    written_ += frames;
    scheduled_.erase(std::remove_if(scheduled_.begin(), scheduled_.end(),
                                    [this](const Scheduled& tone) {
                                      return tone.start + tone.samples->size() <= written_;
                                    }),
                     scheduled_.end());
  }

  // The frame playing at the output now, and the performance-counter time of it.
  void UpdateClock(IAudioClock* clock, UINT64 frequency) {
    UINT64 position = 0;
    UINT64 qpcPosition = 0;
    if (FAILED(clock->GetPosition(&position, &qpcPosition)) || qpcPosition == 0) return;
    std::lock_guard<std::mutex> lock(mutex_);
    clockFrames_ = static_cast<double>(position) * rate_ / static_cast<double>(frequency);
    // GetPosition gives the counter in 100 ns units; LSL's clock is the counter in seconds.
    clockSeconds_ = static_cast<double>(qpcPosition) / 1e7;
    haveClock_ = true;
    readyChanged_.notify_all();
  }

  // The samples of one tone, ramped at both ends; cached by its settings.
  std::shared_ptr<const std::vector<float>> Tone(double frequency, double duration, double amplitude) {
    char key[96];
    snprintf(key, sizeof(key), "%.6f/%.6f/%.9f", frequency, duration, amplitude);
    auto found = tones_.find(key);
    if (found != tones_.end()) return found->second;
    int frames = static_cast<int>(std::llround(duration * rate_));
    if (frames <= 0) return nullptr;
    auto samples = std::make_shared<std::vector<float>>(frames);
    int rampFrames = std::max(1, std::min(static_cast<int>(kRamp * rate_), frames / 2));
    for (int i = 0; i < frames; i++) {
      double gain = amplitude;
      int edge = std::min(i, frames - 1 - i);
      if (edge < rampFrames) gain *= 0.5 - 0.5 * std::cos(kPi * edge / rampFrames);
      (*samples)[i] = static_cast<float>(gain * std::sin(2 * kPi * frequency * i / rate_));
    }
    tones_[key] = samples;
    return samples;
  }

  std::thread thread_;
  HANDLE stopEvent_ = nullptr;
  std::string deviceName_;
  bool bluetooth_ = false;

  std::mutex mutex_;
  std::condition_variable readyChanged_;
  bool ready_ = false;
  std::string startError_;
  bool running_ = false;
  bool failed_ = false;
  double rate_ = 48000;
  double latency_ = 0;
  uint64_t written_ = 0;
  bool haveClock_ = false;
  double clockFrames_ = 0;
  double clockSeconds_ = 0;
  std::vector<Scheduled> scheduled_;
  bool holding_ = false;
  uint64_t holdStart_ = 0;
  double holdFrequency_ = 1000;
  double holdAmplitude_ = 0;
  std::map<std::string, std::shared_ptr<const std::vector<float>>> tones_;
};

const EncodableValue* Argument(const EncodableValue* arguments, const char* key) {
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return nullptr;
  auto found = map->find(EncodableValue(key));
  return found == map->end() ? nullptr : &found->second;
}

std::optional<double> DoubleArgument(const EncodableValue* arguments, const char* key) {
  const EncodableValue* value = Argument(arguments, key);
  if (value == nullptr) return std::nullopt;
  if (const auto* d = std::get_if<double>(value)) return *d;
  if (const auto* i = std::get_if<int32_t>(value)) return static_cast<double>(*i);
  if (const auto* l = std::get_if<int64_t>(value)) return static_cast<double>(*l);
  return std::nullopt;
}

std::optional<int> IntArgument(const EncodableValue* arguments, const char* key) {
  const EncodableValue* value = Argument(arguments, key);
  if (value == nullptr) return std::nullopt;
  if (const auto* i = std::get_if<int32_t>(value)) return *i;
  if (const auto* l = std::get_if<int64_t>(value)) return static_cast<int>(*l);
  return std::nullopt;
}

// Never destroyed: joining the render thread while the process exits can hang.
TonePlayer& Player() {
  static TonePlayer* player = new TonePlayer();
  return *player;
}
std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;

void Handle(const flutter::MethodCall<EncodableValue>& call,
            std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  const EncodableValue* args = call.arguments();
  if (method == "audioOutputs") {
    result->Success(EncodableValue(OutputDevices()));
  } else if (method == "audioStart") {
    EncodableMap info;
    std::string error = Player().Start(IntArgument(args, "deviceId"), &info);
    if (error.empty()) {
      result->Success(EncodableValue(info));
    } else {
      result->Error("audio_failed", error);
    }
  } else if (method == "audioPlay") {
    auto frequency = DoubleArgument(args, "frequency");
    auto duration = DoubleArgument(args, "duration");
    auto amplitude = DoubleArgument(args, "amplitude");
    if (!frequency || !duration || !amplitude) {
      result->Error("bad_args", "audioPlay needs frequency, duration, amplitude");
      return;
    }
    double heard = 0;
    std::string error = Player().Play(*frequency, *duration, *amplitude, DoubleArgument(args, "at"), &heard);
    if (error.empty()) {
      result->Success(EncodableValue(heard));
    } else {
      result->Error("audio_failed", error);
    }
  } else if (method == "audioHold") {
    auto frequency = DoubleArgument(args, "frequency");
    auto amplitude = DoubleArgument(args, "amplitude");
    if (!frequency || !amplitude) {
      result->Error("bad_args", "audioHold needs frequency, amplitude");
      return;
    }
    std::string error = Player().Hold(*frequency, *amplitude);
    if (error.empty()) {
      result->Success();
    } else {
      result->Error("audio_failed", error);
    }
  } else if (method == "audioRelease") {
    Player().Release();
    result->Success();
  } else if (method == "audioVolume") {
    ComPtr<IAudioEndpointVolume> volume = EndpointVolume(IntArgument(args, "deviceId"));
    float level = 0;
    if (volume && SUCCEEDED(volume->GetMasterVolumeLevelScalar(&level))) {
      result->Success(EncodableValue(static_cast<double>(level)));
    } else {
      result->Success();
    }
  } else if (method == "audioSetVolume") {
    auto level = DoubleArgument(args, "volume");
    if (!level) {
      result->Error("bad_args", "audioSetVolume needs volume");
      return;
    }
    ComPtr<IAudioEndpointVolume> volume = EndpointVolume(IntArgument(args, "deviceId"));
    bool ok = volume && SUCCEEDED(volume->SetMasterVolumeLevelScalar(
                            static_cast<float>(std::clamp(*level, 0.0, 1.0)), nullptr));
    result->Success(EncodableValue(ok));
  } else if (method == "audioStop") {
    Player().Stop();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void RegisterToneChannel(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "mw75_neuro", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(Handle);
}
