# EEG Viewer LSL

A consolidated README for the EEG Viewer LSL project. This document combines the main project README with architecture notes, stream-selection details, enhanced StreamInfo documentation, and a short note about launch screen assets.

## Table of contents

- Project overview
- Features
- Getting started
- Usage
- Architecture (refactor summary)
- Stream selection
- Enhanced StreamInfo
- Platform-specific notes & launch assets
- Testing
- Troubleshooting
- License

## Project overview

A Flutter application for discovering, connecting to, and visualizing EEG data streams using the Lab Streaming Layer (LSL) protocol.

Cross-platform: macOS, Windows, iOS, Android (and Linux/web where supported).

## Features

- LSL stream discovery and resolution
- Stream selection UI (choose which discovered stream to connect)
- Inlet worker runs in an isolate for non-blocking data reception
- Real-time sample display and time-series graphing
- Modular code structure for maintainability and testing

## Getting started

### Prerequisites

- Flutter SDK (recommended 3.10.0 or higher)
- An LSL outlet/source (device, simulator, or generator)

### Installation

1. Clone the repository:
    ```bash
    git clone <repository-url>
    cd eeg_viewer_lsl
    ```

2. Install dependencies:
    ```bash
    flutter pub get
    ```

3. Run the application on your platform of choice:
    ```bash
    flutter run -d macos
    flutter run -d windows
    flutter run -d android
    flutter run -d ios
    ```

## Usage

1. Open the app and navigate to the Data tab
2. Discover available LSL streams (the app can also auto-discover on startup)
3. Use the Stream Selection UI to pick a stream if you prefer a specific outlet
4. Connect and start streaming to view samples and live graphs

## Architecture (refactor summary)

The app has been refactored into a modular structure for clarity and testability.

Key folders under `lib/`:

- `models/` — data models like `stream_info.dart` and `eeg_data_manager.dart`
- `services/` — LSL integration (`lsl_service.dart`) and related logic
- `screens/` — UI pages (`eeg_viewer_screen.dart`, `data_view_screen.dart`, `graph_view_screen.dart`)
- `widgets/` — reusable widgets (`eeg_chart.dart`, `stream_selector.dart`, `chart_controls.dart`, `status_display.dart`)
- `utils/` — utilities such as `chart_utils.dart`

Benefits: separation of concerns, easier testing, improved reusability, and scalability.

## Stream selection

The app supports interactive stream selection rather than auto-connecting to the first discovered stream. Main points:

- Stream discovery populates a list of `ResolvedStreamHandle` objects
- A `RadioListTile`-based selector shows stream name, channel count and basic metadata
- The selected stream index is tracked (e.g. `_selectedStreamIndex`) and user-initiated connect uses the selected stream
- UI includes validation and clear error/status messages

Example UI snippet:

```dart
ListView.builder(
   itemCount: streams.length,
   itemBuilder: (context, index) {
      return RadioListTile<int>(
         title: Text('${streams[index].name}'),
         subtitle: Text('Channels: ${streams[index].channelCount}'),
         value: index,
         groupValue: _selectedStreamIndex,
         onChanged: (value) => setState(() => _selectedStreamIndex = value!),
      );
   },
);
```

## Enhanced StreamInfo

The `StreamInfo` model has been improved to read real metadata from `ResolvedStreamHandle.info` instead of placeholders. Available LSL properties typically include:

- `name`, `channelCount`, `nominalSRate`, `type`, `sourceId`, `hostname`, `uid`, `sessionId`, `createdAt`

Factory example:

```dart
factory StreamInfo.fromHandle(ResolvedStreamHandle handle, {int index = 0}) {
   final lslInfo = handle.info;
   return StreamInfo(
      handle: handle,
      name: lslInfo.name.isNotEmpty ? lslInfo.name : 'LSL Stream ${index + 1}',
      channelCount: lslInfo.channelCount,
      nominalSampleRate: lslInfo.nominalSRate,
      type: lslInfo.type.isNotEmpty ? lslInfo.type : 'Unknown',
   );
}
```

Benefits: accurate sampling rates, correct buffer sizing, meaningful UI labels, and safer processing.

## Platform-specific notes & launch assets

macOS
- Network permissions generally handled automatically; production apps may need multicast entitlements.

iOS
- Add `NSLocalNetworkUsageDescription` to `Info.plist` and ensure multicast entitlement if distributing via the App Store.

Android
- Minimum SDK 26; internet and network state permissions required. Multicast lock used for discovery.

Launch screen assets

You can customize the iOS launch screen images in `ios/Runner/Assets.xcassets` by replacing the images in the `LaunchImage.imageset` directory. Open Xcode with `open ios/Runner.xcworkspace` and update assets visually if preferred.

## Testing

To test without hardware, run an LSL generator/outlet. Example Python generator:

```python
from pylsl import StreamInfo, StreamOutlet
import time, random

info = StreamInfo('TestEEG', 'EEG', 8, 250, 'float32', 'myuid34234')
outlet = StreamOutlet(info)

while True:
      sample = [random.random() for _ in range(8)]
      outlet.push_sample(sample)
      time.sleep(1.0/250)
```

## Troubleshooting

- No streams found: ensure generators are on the same network and broadcasting
- Connection failed: check firewall and platform network permissions
- Build errors (macOS/iOS): verify entitlements and signing
- Performance: isolate workers are used but very high-rate streams may still affect performance
