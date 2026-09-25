import 'package:eeg_viewer_lsl/models/eeg_app_settings.dart';
import 'package:eeg_viewer_lsl/utils/configured_band_power.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('changing a configured range changes its calculated power', () {
    // One bin per Hz: bins 1–3 have amplitude 2, bins 4–7 amplitude 4.
    final bins = [0.0, 2.0, 2.0, 2.0, 4.0, 4.0, 4.0, 4.0, 1.0];

    final lowBand = configuredBandPower(
      amplitudeBins: bins,
      binsPerHz: 1,
      bands: [EegBandDefinition(name: 'Test', lowHz: 1, highHz: 4)],
    );
    final highBand = configuredBandPower(
      amplitudeBins: bins,
      binsPerHz: 1,
      bands: [EegBandDefinition(name: 'Test', lowHz: 4, highHz: 8)],
    );

    expect(lowBand.single, closeTo(4, 1e-9));
    expect(highBand.single, closeTo(16, 1e-9));
  });
}
