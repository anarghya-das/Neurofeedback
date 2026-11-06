import 'dart:io';

import 'package:flutter/material.dart';

import '../test_runs.dart';

const _ink = Color(0xFF111216);
const _muted = Color(0xFF69707D);
const _line = Color(0xFFD9DCE3);

/// Who the next test runs are recorded for. Every test reads it when a run
/// starts, saves it in the run and its folder name, and shows it in the run
/// list; a run keeps the label it started with.
class ParticipantField extends StatefulWidget {
  const ParticipantField({super.key, required this.store, this.width = 190});

  final TestRunStore store;
  final double width;

  @override
  State<ParticipantField> createState() => _ParticipantFieldState();
}

class _ParticipantFieldState extends State<ParticipantField> {
  late final _controller = TextEditingController(text: widget.store.participant.value);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Saved with each test run from now on, and shown in the run lists',
    child: SizedBox(
      width: widget.width,
      height: 36,
      child: TextField(
        controller: _controller,
        onChanged: (v) => widget.store.participant.value = v,
        style: const TextStyle(fontSize: 12.5, color: _ink),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          prefixIcon: const Icon(Icons.person_outline_rounded, size: 16, color: _muted),
          prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          hintText: 'Participant, e.g. P01',
          hintStyle: const TextStyle(fontSize: 12.5, color: _muted),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _line)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _line),
          ),
        ),
      ),
    ),
  );
}

/// One run in a [RunChecklist].
class RunItem {
  const RunItem({
    required this.started,
    required this.detail,
    required this.included,
    this.onChanged,
    this.live = false,
    this.participant,
  });

  final DateTime started;

  /// Who the run was recorded for, shown before the time.
  final String? participant;
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
                            [
                              if (item.participant != null) item.participant!,
                              when(item.started),
                              if (item.live) 'in progress',
                            ].join(' · '),
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
