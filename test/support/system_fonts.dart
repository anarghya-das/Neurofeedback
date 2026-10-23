import 'dart:io';

/// Path of a system font that widget tests load as "Roboto" so renders use real
/// glyph metrics instead of the test font's boxes.
///
/// Callers pass the macOS file name ("Arial.ttf" or "Arial Bold.ttf"); on
/// Windows the same fonts live in the Windows font folder under other names.
String systemFontPath(String macFile) {
  if (Platform.isWindows) {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final file = switch (macFile) {
      'Arial.ttf' => 'arial.ttf',
      'Arial Bold.ttf' => 'arialbd.ttf',
      _ => macFile,
    };
    return '$root\\Fonts\\$file';
  }
  return '/System/Library/Fonts/Supplemental/$macFile';
}
