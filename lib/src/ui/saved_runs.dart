import 'dart:io';

import 'package:flutter/material.dart';

const _ink = Color(0xFF111216);
const _muted = Color(0xFF69707D);
const _line = Color(0xFFD9DCE3);

/// One run in a [RunChecklist].
class RunItem {
  const RunItem({required this.started, required this.detail, required this.included, this.onChanged, this.live = false});

  final DateTime started;
  final String detail;
  final bool included;

  /// Null while the run cannot be toggled (for example, while it is running).
  final ValueChanged<bool>? onChanged;
  final bool live;
}

/// The runs a test's results pool, each with a tick box, newest first, and a
/// button to open the folder they are saved in.
class RunChecklist extends StatelessWidget {
  const RunChecklist({super.key, required this.items, this.folder, this.onClearAll});

  final List<RunItem> items;

  /// Where runs are saved; shows "Show in Finder" ("Open folder" on Windows) when set.
  final String? folder;
  final VoidCallback? onClearAll;

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static String when(DateTime t) {
    final now = DateTime.now();
    final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (t.year == now.year && t.month == now.month && t.day == now.day) return 'Today $time';
    return '${_months[t.month - 1]} ${t.day}, $time';
  }

  @override
  Widget build(BuildContext context) {
    final folder = this.folder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Runs in the results',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _ink),
              ),
            ),
            if (onClearAll != null && items.any((i) => i.included))
              _SmallButton(label: 'Untick all', onPressed: onClearAll!),
            if (folder != null)
              _SmallButton(
                label: Platform.isWindows ? 'Open folder' : 'Show in Finder',
                onPressed: () async {
                  await Directory(folder).create(recursive: true);
                  if (Platform.isWindows) {
                    await Process.run('explorer.exe', [folder.replaceAll('/', r'\')]);
                  } else {
                    await Process.run('open', [folder]);
                  }
                },
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (items.isEmpty)
          const Text('No runs yet. Finished runs are saved and listed here.', style: TextStyle(fontSize: 11, color: _muted))
        else
          for (final item in items.take(12))
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: item.onChanged == null ? null : () => item.onChanged!(!item.included),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 28,
                      height: 24,
                      child: Checkbox(
                        value: item.included,
                        onChanged: item.onChanged == null ? null : (v) => item.onChanged!(v ?? false),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: const BorderSide(color: _line, width: 1.5),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.live ? '${when(item.started)} · in progress' : when(item.started),
                            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _ink),
                          ),
                          Text(item.detail, style: const TextStyle(fontSize: 10.5, color: _muted, height: 1.3)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        if (items.length > 12)
          Text('${items.length - 12} older runs are in the folder.', style: const TextStyle(fontSize: 10.5, color: _muted)),
      ],
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      minimumSize: const Size(0, 28),
    ),
    child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
  );
}
