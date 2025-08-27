# EEG Viewer LSL

A Flutter application for viewing EEG data streams using the Lab Streaming Layer (LSL) protocol.

## Features

- **LSL Stream Discovery**: Search for available LSL streams on the local network
- **Stream Connection**: Connect to the first discovered stream
- **Real-time Data Display**: View streaming sample data and timestamps
- **Cross-platform**: Works on macOS, Windows, iOS, and Android

## Getting Started

### Prerequisites

- Flutter SDK (3.10.0 or higher)
- An LSL stream source (e.g., OpenBCI, EEG device, or LSL simulator)

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

3. Run the application:
   ```bash
   flutter run -d macos  # For macOS
   flutter run -d windows  # For Windows
   flutter run -d android  # For Android
   flutter run -d ios  # For iOS
   ```

## Using the Application

1. **Initialize**: The app will automatically initialize the LSL inlet worker on startup
2. **Search for Streams**: Click "Search for Streams" to discover available LSL streams on the network
3. **Connect**: Click "Connect to First Stream" to connect to the first discovered stream
4. **Start Streaming**: Click "Start Streaming" to begin receiving and displaying data
5. **View Data**: The latest sample data and timestamp will be displayed in real-time
6. **Stop Streaming**: Click "Stop Streaming" to pause data reception

## LSL Integration Details

This application uses the `lsl_flutter` package which provides:

- **InletWorker**: Handles LSL inlet operations in an isolate to prevent blocking the UI
- **Stream Resolution**: Discovers LSL streams available on the local network
- **Sample Streaming**: Receives real-time data samples with timestamps
- **Cross-platform Support**: Works on all major platforms supported by Flutter

### Code Structure

- `main.dart`: Contains the main Flutter application with LSL integration
- Uses `InletWorker.spawn()` to create an isolate worker for LSL operations
- Implements stream discovery, connection, and data reception
- Displays stream status and real-time sample data

## Platform-Specific Setup

### macOS
- Network permissions are handled automatically
- For production apps, you may need to add multicast entitlements

### iOS
- Requires `NSLocalNetworkUsageDescription` in Info.plist
- Needs multicast entitlement from Apple for App Store distribution

### Android
- Minimum SDK version must be 26
- Requires internet and network state permissions
- Uses multicast lock for network discovery

### Windows
- No special setup required

## Testing

To test the application, you'll need an LSL stream source. You can:

1. Use an actual EEG device that supports LSL
2. Use the LSL test applications available from the [LSL repository](https://github.com/sccn/labstreaminglayer)
3. Create a simple LSL outlet using Python or other programming languages

Example Python LSL outlet for testing:
```python
from pylsl import StreamInfo, StreamOutlet
import time
import random

# Create stream info
info = StreamInfo('TestEEG', 'EEG', 8, 250, 'float32', 'myuid34234')
outlet = StreamOutlet(info)

# Send data
while True:
    sample = [random.random() for _ in range(8)]
    outlet.push_sample(sample)
    time.sleep(1.0/250)  # 250 Hz
```

## Dependencies

- `flutter`: SDK
- `lsl_flutter`: ^0.0.6 - LSL integration for Flutter
- `cupertino_icons`: ^1.0.8 - iOS-style icons

## Development

This project uses the LSL Flutter package to integrate with the Lab Streaming Layer. The package provides high-level APIs for discovering streams, connecting to inlets, and receiving real-time data.

For more information about LSL, visit: https://labstreaminglayer.readthedocs.io/

## Troubleshooting

- **No streams found**: Ensure your LSL source is running and broadcasting on the same network
- **Connection failed**: Check network permissions and firewall settings
- **Build errors on macOS**: Ensure entitlements are properly configured for your signing certificate
- **Performance issues**: The app uses isolate workers to prevent UI blocking, but very high-frequency streams may still impact performance

## License

This project is open source. Please check the LICENSE file for details.
