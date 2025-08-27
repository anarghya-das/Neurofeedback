# EEG Viewer LSL - Refactored Architecture

## Overview
The EEG Viewer LSL application has been refactored from a single large `main.dart` file into a well-organized, modular architecture that follows Flutter best practices.

## Project Structure

```
lib/
├── main.dart                    # Application entry point
├── models/                      # Data models and business logic
│   ├── stream_info.dart        # LSL stream information model
│   └── eeg_data_manager.dart   # EEG data management and processing
├── services/                    # External service integrations
│   └── lsl_service.dart        # LSL (Lab Streaming Layer) service
├── screens/                     # Screen/page implementations
│   ├── eeg_viewer_screen.dart  # Main application screen
│   ├── data_view_screen.dart   # Data view tab screen
│   └── graph_view_screen.dart  # Graph visualization tab screen
├── widgets/                     # Reusable UI components
│   ├── eeg_chart.dart          # Individual EEG chart widget
│   ├── stream_selector.dart    # Stream selection widget
│   ├── chart_controls.dart     # Chart control sliders
│   └── status_display.dart     # Status information display
└── utils/                       # Utility functions and helpers
    └── chart_utils.dart        # Chart-related utility functions
```

## Architecture Benefits

### 1. **Separation of Concerns**
- **Models**: Handle data structures and business logic
- **Services**: Manage external integrations (LSL)
- **Screens**: Implement complete page/tab functionality
- **Widgets**: Provide reusable UI components
- **Utils**: Offer shared utility functions

### 2. **Improved Maintainability**
- Each file has a single, clear responsibility
- Changes to one component don't affect others
- Easier to locate and fix bugs
- Simplified testing and debugging

### 3. **Better Code Reusability**
- Widgets can be reused across different screens
- Services can be easily mocked for testing
- Models provide consistent data structures

### 4. **Enhanced Scalability**
- Easy to add new features or charts
- Simple to extend LSL functionality
- Straightforward to add new UI components

## Key Components

### Models

#### `StreamInfo`
- Encapsulates LSL stream metadata
- Provides clean interface to stream handle
- Includes equality and toString methods

#### `EEGDataManager`
- Manages real-time EEG data buffering
- Handles time-series data for multiple channels
- Provides configurable time windows and sampling rates

### Services

#### `LSLService`
- Abstracts all LSL operations
- Manages stream discovery, connection, and data streaming
- Provides clean async API with proper error handling

### Screens

#### `EEGViewerScreen`
- Main application coordinator
- Manages state between data and graph views
- Coordinates service calls and UI updates

#### `DataViewScreen`
- Displays connection status and controls
- Shows latest sample data
- Manages stream selection interface

#### `GraphViewScreen`
- Renders real-time EEG graphs
- Provides chart controls (time window, amplitude scaling)
- Displays multiple channel data simultaneously

### Widgets

#### `EEGChart`
- Self-contained chart component
- Configurable for different channels and display settings
- Handles chart rendering and styling

#### `StreamSelector`
- Interactive stream selection interface
- Radio button selection with visual feedback
- Displays stream metadata

## Usage Examples

### Adding a New Chart Type
```dart
// Create new widget in widgets/
class SpectrogramChart extends StatelessWidget {
  // Implementation
}

// Use in graph_view_screen.dart
SpectrogramChart(
  data: dataManager.getSpectrogramData(),
  // configuration
)
```

### Extending LSL Functionality
```dart
// Add method to LSLService
Future<StreamMetadata> getStreamMetadata(String streamId) async {
  // Implementation
}

// Use in any screen
final metadata = await _lslService.getStreamMetadata(streamId);
```

### Creating Custom Data Processing
```dart
// Extend EEGDataManager
class FilteredEEGDataManager extends EEGDataManager {
  @override
  void processSample(List<dynamic> sampleData, double timestamp) {
    // Apply filtering before processing
    final filtered = applyFilter(sampleData);
    super.processSample(filtered, timestamp);
  }
}
```

## Migration Benefits

### Before (Single File)
- 587 lines in main.dart
- Multiple responsibilities mixed together
- Difficult to test individual components
- Hard to reuse code
- Complex debugging

### After (Modular Structure)
- ~20 lines in main.dart
- Clear separation of concerns
- Each component easily testable
- Highly reusable widgets and services
- Simple debugging and maintenance

## Future Enhancements

The new architecture makes it easy to add:

1. **New Visualization Types**
   - Frequency domain plots
   - 3D brain mapping
   - Statistical analysis views

2. **Enhanced Data Processing**
   - Real-time filtering
   - Artifact detection
   - Signal quality monitoring

3. **Export Functionality**
   - Data export services
   - Chart export widgets
   - Configuration persistence

4. **Testing Infrastructure**
   - Unit tests for each component
   - Widget tests for UI components
   - Integration tests for services

## Best Practices Implemented

- **Single Responsibility Principle**: Each class has one clear purpose
- **Dependency Injection**: Services passed to components that need them
- **Immutable Data Models**: StreamInfo and related structures
- **Async/Await Patterns**: Proper handling of asynchronous operations
- **Error Handling**: Comprehensive try-catch blocks with user feedback
- **Resource Management**: Proper disposal of streams and subscriptions

This refactored architecture provides a solid foundation for future development while maintaining all existing functionality.
