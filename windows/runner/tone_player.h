#ifndef RUNNER_TONE_PLAYER_H_
#define RUNNER_TONE_PLAYER_H_

#include <flutter/binary_messenger.h>

// Answers the "audio…" calls of the mw75_neuro method channel on Windows, the
// way the macOS app's ToneStimulator does: output devices, a WASAPI stream kept
// running, tones scheduled to be heard at a time on LSL's clock, a steady tone
// for sound level calibration, and the output volume. Other calls on the
// channel are answered "not implemented" (the Windows app does Bluetooth and
// speech from Dart).
void RegisterToneChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_TONE_PLAYER_H_
