# Stream Selection Feature

## Overview
The EEG Viewer LSL application now includes an enhanced stream selection interface that allows users to choose specific LSL streams instead of automatically connecting to the first discovered stream.

## Features

### Interactive Stream Selection
- **Stream Discovery**: The app automatically discovers all available LSL streams on the network
- **Radio Button Selection**: Each discovered stream is displayed with a radio button for selection
- **Stream Information**: Shows stream name and channel count for easy identification
- **User Control**: Users can select any available stream before connecting

### UI Components
1. **Stream List**: Scrollable list of all discovered LSL streams
2. **Selection Interface**: Radio buttons for stream selection
3. **Connect Button**: Initiates connection to the selected stream
4. **Status Display**: Shows connection status and stream information

## How to Use

1. **Launch the Application**: Run the app and navigate to the "Data" tab
2. **Discover Streams**: The app will automatically scan for available LSL streams
3. **Select Stream**: Choose your desired stream from the list using the radio buttons
4. **Connect**: Click the "Connect to Selected Stream" button
5. **View Data**: Switch to the "Graph" tab to see real-time visualization

## Technical Implementation

### Key Components
- `_selectedStreamIndex`: Tracks the currently selected stream index
- `_connectToSelectedStream()`: Handles connection to the user-selected stream
- Interactive `ListView` with radio button selection
- Stream validation and error handling

### Code Structure
```dart
// Stream selection state
int _selectedStreamIndex = -1;

// UI for stream selection
ListView.builder(
  itemBuilder: (context, index) {
    return RadioListTile<int>(
      title: Text('${streams[index].name}'),
      subtitle: Text('Channels: ${streams[index].channelCount}'),
      value: index,
      groupValue: _selectedStreamIndex,
      onChanged: (value) {
        setState(() {
          _selectedStreamIndex = value!;
        });
      },
    );
  },
)
```

## Testing

### Using the Python Generator
To test the stream selection feature:

1. **Run the LSL Generator**:
   ```bash
   python lsl_eeg_generator.py
   ```

2. **Run Multiple Generators**: Start multiple instances with different names to test multi-stream selection

3. **Verify Selection**: Ensure you can select and connect to different streams

### Expected Behavior
- Multiple streams appear in the selection list
- Radio buttons allow single stream selection
- Connection establishes successfully to the selected stream
- Data displays correctly in both tabs

## Troubleshooting

### No Streams Found
- Ensure LSL streams are running on the network
- Check network connectivity
- Verify LSL generator is broadcasting properly

### Connection Issues
- Make sure a stream is selected before connecting
- Check that the selected stream is still available
- Review console logs for detailed error messages

### UI Issues
- Ensure proper stream selection before connection attempts
- Check that the selected index is valid
- Verify UI updates correctly after stream selection

## Future Enhancements
- Stream metadata display (when available from LSL API)
- Stream filtering and search capabilities
- Connection status indicators
- Automatic reconnection on stream loss
