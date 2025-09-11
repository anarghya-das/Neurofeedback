# EEG Viewer LSL - UI Design Specification

## Overview

Desktop application for real-time EEG data visualization inspired by OpenBCI GUI, built with Flutter for cross-platform compatibility.

## Layout Structure

### Main Window (1200x800px minimum)

- **Left Control Panel**: 300px width
- **Visualization Grid**: Remaining space (2x2 grid)

## Component Specifications

### 1. Left Control Panel

#### Device Connection Section

- **Start/Stop Streaming Button**: Large prominent button (120x40px)
- **Device Selection Dropdown**: List of available LSL streams
- **Sample Rate Indicator**: Display current sample rate (e.g., "250 Hz")
- **Connection Status**: Green/Red indicator with text

#### Channel Controls Section

- **Channel Enable/Disable**: 8-16 toggles with channel labels (Fp1, Fp2, F3, F4, etc.)
- **Global Channel Controls**: Select All/None buttons
- **Per-Channel Gain**: Sliders or input fields

#### Filter Settings Section

- **Bandpass Filter**: Low/High frequency inputs
- **Notch Filter**: 50/60Hz toggle
- **Filter Enable/Disable**: Toggle switch

#### LSL Networking Section

- **LSL Stream Enable**: Toggle switch
- **Stream Name**: Text input field
- **Stream Type**: Dropdown (EEG, markers, etc.)
- **Send Markers**: Button for event markers

### 2. Visualization Grid (2x2 Layout)

#### Top-Left: Time Series Panel

- **Multi-channel waveform display**
- **Scrolling time window**: 5-10 seconds visible
- **Channel legend**: Color-coded channel names
- **Scale controls**: Amplitude scaling (±50μV, ±100μV, etc.)
- **Time scale**: X-axis time markers

#### Top-Right: FFT Panel

- **Frequency spectrum plot**: 0-60Hz default
- **Log/Linear scale toggle**
- **Channel selection**: Individual or averaged
- **Peak frequency indicator**
- **Frequency bands overlay**: Alpha, Beta, Theta, Delta

#### Bottom-Left: Band Power Panel

- **5 band power tiles**: Delta, Theta, Alpha, Beta, Gamma
- **Per-channel or averaged view toggle**
- **Numerical values**: Power in dB or μV²
- **Color-coded intensity bars**
- **Relative/Absolute power toggle**

#### Bottom-Right: Spectrogram Panel

- **Dual spectrogram**: Left/Right hemisphere or custom grouping
- **Time on X-axis**: Scrolling window
- **Frequency on Y-axis**: 0-60Hz default
- **Color gradient**: Blue (low) to Red (high) power
- **Max frequency control**: Slider or input

## States and Interactions

### Application States

1. **Idle**: No data streaming, controls available
2. **Connecting**: Attempting to connect to LSL stream
3. **Streaming**: Real-time data display, limited control changes
4. **Recording**: Data streaming + saving to file
5. **Error**: Connection failed or data stream interrupted

### Interactions

- **Panel Resize**: Draggable panel borders
- **Channel Toggle**: Click channel in legend to show/hide
- **Scale Adjustment**: Mouse wheel over plots for zoom
- **Time Navigation**: Scrub through recorded data
- **Export**: Save current view as image
- **Settings**: Modal dialog for advanced configuration

## Visual Design Guidelines

### Color Scheme

- **Background**: Dark theme (#0b0e14)
- **Panels**: Slightly lighter (#131722)
- **Accent**: Blue (#4da3ff)
- **Success**: Green (#39d353)
- **Warning**: Orange (#ffb454)
- **Error**: Red (#ff6b6b)
- **Text Primary**: White (#ffffff)
- **Text Secondary**: Light gray (#8b949e)

### Typography

- **Headers**: 16px, Bold
- **Body**: 14px, Regular
- **Small Text**: 12px, Regular
- **Monospace**: 12px for numerical values

### Spacing

- **Small**: 8px
- **Medium**: 16px
- **Large**: 24px
- **XLarge**: 32px

## Responsive Behavior

- **Minimum Window Size**: 1000x700px
- **Panel Collapse**: Control panel can collapse to icons only
- **Grid Reflow**: 2x2 can become 1x4 on narrow screens
- **Text Scaling**: Support system font scaling

## Accessibility

- **High Contrast**: Support high contrast mode
- **Keyboard Navigation**: Full keyboard control
- **Screen Reader**: Proper ARIA labels
- **Color Blind**: Use patterns in addition to colors

## Technical Considerations

- **Flutter Widgets**: Custom painters for real-time plots
- **Performance**: 60fps rendering for smooth data display
- **Memory**: Efficient circular buffers for data storage
- **Threading**: Background data processing
