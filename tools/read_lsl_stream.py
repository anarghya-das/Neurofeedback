#!/usr/bin/env python3
"""
Simple LSL stream reader that prints the packet/data structure.

Usage examples:
  python tools/read_lsl_stream.py --list
  python tools/read_lsl_stream.py --name EEG --count 5
  python tools/read_lsl_stream.py --index 0 --count 10

The script tries to use pylsl. Install with: pip install pylsl
"""

import argparse
import sys
import time
import xml.etree.ElementTree as ET

try:
    from pylsl import resolve_streams, StreamInlet
except Exception:
    print("pylsl is not installed. Install it with: pip install pylsl")
    sys.exit(1)

try:
    import numpy as np
except Exception:
    np = None


def list_streams():
    streams = resolve_streams()
    if not streams:
        print("No LSL streams found.")
        return
    for i, s in enumerate(streams):
        try:
            name = s.name()
            stype = s.type()
            chan = s.channel_count()
            rate = s.nominal_srate()
            src = s.source_id()
        except Exception:
            # defensive
            name = stype = src = None
            chan = rate = None
        print(
            f"[{i}] name={name!r} type={stype!r} channels={chan} srate={rate} source_id={src}")


def resolve_stream_by_index(idx):
    streams = resolve_streams()
    if not streams:
        raise RuntimeError("No streams available to resolve")
    if idx < 0 or idx >= len(streams):
        raise IndexError(f"Index {idx} out of range (0..{len(streams)-1})")
    return streams[idx]


def resolve_stream_by_name(name):
    streams = resolve_streams()
    for s in streams:
        try:
            if s.name() == name:
                return s
        except Exception:
            continue
    raise RuntimeError(f"No stream with name={name!r} found")


def print_stream_info(si):
    print('\n--- Stream info ---')
    try:
        print('Name:', si.name())
        print('Type:', si.type())
        print('Source id:', si.source_id())
        print('Channels:', si.channel_count())
        print('Nominal srate:', si.nominal_srate())
        print('Channel format:', si.channel_format())
        print('\nXML description:\n')
        try:
            print(si.as_xml())
        except Exception:
            print('<unable to render xml>')
    except Exception as e:
        print('Error reading stream info:', e)


def parse_stream_metadata(si):
    """Parse useful metadata from StreamInfo.as_xml() and return a dict.

    Returns a dict with basic fields and a `channel_info` list of per-channel dicts
    (label, unit, type) when available.
    """
    meta = {
        "name": si.name(),
        "type": si.type(),
        "channels": si.channel_count(),
        "srate": si.nominal_srate(),
        "format": si.channel_format(),
        "source_id": si.source_id(),
        "channel_info": [],
    }

    try:
        xml = si.as_xml()
        root = ET.fromstring(xml)
        # channel descriptors usually live under desc/channels/channel
        for ch in root.findall('.//channels/channel'):
            # some publishers use <label>, some <name>
            label = ch.findtext('label') or ch.findtext('name') or None
            unit = ch.findtext('unit') or None
            ch_type = ch.findtext('type') or None
            meta['channel_info'].append(
                {'label': label, 'unit': unit, 'type': ch_type})
    except Exception:
        # as_xml may be missing or malformed for some streams; ignore safely
        pass

    return meta


def main():
    p = argparse.ArgumentParser(
        description='Read an LSL stream and print samples/structure')
    p.add_argument('--list', action='store_true',
                   help='List available streams and exit')
    p.add_argument('--name', type=str, help='Select stream by name')
    p.add_argument('--index', type=int,
                   help='Select stream by index from --list (0-based)')
    p.add_argument('--count', type=int, default=1,
                   help='How many samples/chunks to read (0 = infinite)')
    p.add_argument('--chunk', action='store_true',
                   help='Use pull_chunk to receive chunks (may return multiple samples)')
    p.add_argument('--timeout', type=float, default=5.0,
                   help='Timeout in seconds for pull_sample/pull_chunk')
    args = p.parse_args()

    if args.list:
        list_streams()
        return

    try:
        if args.index is not None:
            si = resolve_stream_by_index(args.index)
        elif args.name is not None:
            si = resolve_stream_by_name(args.name)
        else:
            # auto-select first stream if only one exists
            streams = resolve_streams()
            if not streams:
                print('No LSL streams available.')
                return
            if len(streams) == 1:
                si = streams[0]
            else:
                print(
                    'Multiple streams found. Use --list to inspect and --index or --name to select.')
                list_streams()
                return

        print_stream_info(si)

        # print parsed metadata (channel labels/units etc.) when available
        meta = parse_stream_metadata(si)
        if meta.get('channel_info'):
            print('\n--- parsed channel info ---')
            for i, ch in enumerate(meta['channel_info']):
                print(
                    f"[{i}] label={ch.get('label')!r} unit={ch.get('unit')!r} type={ch.get('type')!r}")

        inlet = StreamInlet(si)

        seen = 0
        while True:
            if args.chunk:
                chunk, timestamps = inlet.pull_chunk(timeout=args.timeout)
                if not chunk:
                    print('(no chunk received)')
                else:
                    print('\n--- chunk received ---')
                    print('chunk type:', type(chunk))
                    print('len(chunk)=', len(chunk))
                    # print small preview
                    for i, sample in enumerate(chunk[:5]):
                        print(f'  sample[{i}] ({len(sample)} channels):')
                seen += 1
            else:
                sample, ts = inlet.pull_sample(timeout=args.timeout)
                if sample is None:
                    print('(no sample received)')
                else:
                    print('\n--- sample received ---')
                    print('timestamp:', ts)
                    try:
                        print('sample type:', type(sample))
                        # sample may be list or single value
                        if hasattr(sample, '__len__'):
                            print('len(sample)=', len(sample))
                            # preview first up to 8 values
                            preview = sample[:8] if len(sample) > 8 else sample
                            print('preview:', preview)
                        else:
                            print('value:', sample)
                    except Exception:
                        print('sample (raw):', sample)
                seen += 1

            if args.count > 0 and seen >= args.count:
                break

    except KeyboardInterrupt:
        print('\nInterrupted by user')
    except Exception as e:
        print('Error:', e)


if __name__ == '__main__':
    main()
