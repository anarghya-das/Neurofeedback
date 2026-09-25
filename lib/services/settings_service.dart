import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/eeg_app_settings.dart';

class SettingsService {
  static const String _settingsKey = 'eeg_app_settings_v1';

  Future<EegAppSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_settingsKey);

    if (raw == null || raw.isEmpty) {
      return EegAppSettings.defaults();
    }

    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final settings = EegAppSettings.fromJson(decoded);

      if (settings.bands.isEmpty) {
        return EegAppSettings.defaults();
      }

      return settings;
    } catch (_) {
      return EegAppSettings.defaults();
    }
  }

  Future<void> saveSettings(EegAppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
  }

  Future<void> resetSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_settingsKey);
  }
}