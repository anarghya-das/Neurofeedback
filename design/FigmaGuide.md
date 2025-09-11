# Figma Implementation Guide

## Step-by-Step Figma Creation

### 1. Setup Figma File

1. Create new Figma file: "EEG Viewer LSL - UI Design"
2. Create 4 pages:
   - **01 - Wireframes**
   - **02 - Design System**
   - **03 - High Fidelity**
   - **04 - Prototypes**

### 2. Design System Setup (Page 2)

#### Color Palette

Create color styles with these values:

- Background: #0b0e14
- Panel: #131722
- Accent: #4da3ff
- Success: #39d353
- Warning: #ffb454
- Error: #ff6b6b
- Text Primary: #ffffff
- Text Secondary: #8b949e

#### Typography Styles

Create text styles:

- **H1 Header**: 16px Bold
- **Body**: 14px Regular
- **Small**: 12px Regular
- **Monospace**: 12px Monaco/Consolas

#### Component Library

Create these master components:

**Buttons:**

- Primary Button (120x40px)
- Secondary Button (100x36px)
- Icon Button (32x32px)

**Form Elements:**

- Text Input (200x36px)
- Dropdown (150x36px)
- Toggle Switch (40x20px)
- Slider (120x20px)

**Panels:**

- Control Panel Container (300x600px)
- Visualization Panel (400x300px)

### 3. Wireframes (Page 1)

#### Main Layout Frame (1200x800px)

1. **Left Panel**: Rectangle 300x800px (Control Panel)
2. **Right Grid**: 900x800px divided into 2x2 grid
   - Top-Left: Time Series (450x400px)
   - Top-Right: FFT (450x400px)
   - Bottom-Left: Band Power (450x400px)
   - Bottom-Right: Spectrogram (450x400px)

#### Control Panel Sections (Wireframe)

Create 5 sections vertically stacked:

1. **Device Connection** (300x120px)
2. **Channel Controls** (300x200px)
3. **Filter Settings** (300x100px)
4. **LSL Networking** (300x120px)
5. **Recording** (300x80px)

#### Visualization Panels (Wireframe)

For each panel, create placeholder rectangles with labels:

- Time Series: Wavy lines representing EEG channels
- FFT: Bar chart representing frequency spectrum
- Band Power: 5 tiles with band names
- Spectrogram: Heatmap grid representation

### 4. High Fidelity Design (Page 3)

#### Main Interface

1. **Apply Design System**: Use your color and typography styles
2. **Add Real Content**:
   - EEG channel names (Fp1, Fp2, F3, F4, etc.)
   - Realistic data visualizations
   - Proper button labels and icons

#### Time Series Panel Details

- Background: Panel color (#131722)
- Grid lines: Light gray
- Channel traces: Different colors from channelColors array
- Legend: Channel names with color indicators
- Scale indicator: "±100μV" text

#### FFT Panel Details

- X-axis: 0-60 Hz labels
- Y-axis: Power (dB) labels
- Frequency bands: Colored overlays for Delta, Theta, Alpha, Beta, Gamma
- Toggle buttons: "Log" vs "Linear"

#### Band Power Panel Details

- 5 tiles in grid layout
- Each tile: Band name + numerical value + intensity bar
- Color coding: Low (blue) to High (red) intensity

#### Spectrogram Panel Details

- Time axis: Recent to current time
- Frequency axis: 0-60 Hz
- Color gradient: Blue to red heatmap
- Channel grouping selector

#### Control Panel Details

- Section headers with divider lines
- Form elements using design system components
- Status indicators (connected/disconnected)
- Progress bars for signal quality

### 5. Interactive Prototype (Page 4)

#### Key Interactions to Implement

1. **Start/Stop Streaming**: Button state changes
2. **Channel Toggle**: Click channel in legend to hide/show
3. **Panel Settings**: Modal overlays for configuration
4. **Scale Adjustment**: Slider interactions
5. **Tab Navigation**: Between different views

#### Prototype Flow

1. Idle State → Connecting → Streaming
2. Channel configuration flow
3. Settings modal flow
4. Error state handling

### 6. Figma Best Practices

#### Organization

- Use clear layer names
- Group related elements
- Create component variants for different states
- Use auto-layout for responsive sections

#### Documentation

- Add comments explaining interactions
- Include measurement annotations
- Document component usage
- Add developer handoff notes

#### Sharing

- Set proper sharing permissions
- Create presentation mode for stakeholders
- Export assets in appropriate formats
- Generate developer specs

## Export Instructions

### For Development Handoff

1. **Design Specs**: Use Figma's developer handoff feature
2. **Assets**: Export icons as SVG, images as PNG
3. **Measurements**: Include spacing and sizing specs
4. **Colors**: Export color palette as CSS/JSON

### For Presentation

1. **Screenshots**: High-res PNG exports of main views
2. **Flow Diagrams**: Export interaction flows
3. **Style Guide**: Export design system overview

## Tips for AI-Assisted Development

1. **Structured Naming**: Use consistent naming for components
2. **Clear Annotations**: Add notes about behavior and states
3. **Component Hierarchy**: Organize components logically
4. **State Documentation**: Document all interactive states

This structure will make it easy for GitHub Copilot to understand the design intent and generate appropriate Flutter code.
