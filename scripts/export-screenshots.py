#!/usr/bin/env python3
"""Copy original XCTest PNG attachments into a deterministic screenshot gallery."""
import argparse
import json
import pathlib
import re
import shutil
import struct
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('result', type=pathlib.Path)
parser.add_argument('destination', type=pathlib.Path)
args = parser.parse_args()


def display_size(path):
    """Account for XCTest's PNG EXIF orientation without changing image data."""
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'Not a PNG: {path}')
    width, height = struct.unpack('>II', data[16:24])
    offset = 8
    orientation = 1
    while offset < len(data):
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        if data[offset + 4:offset + 8] == b'eXIf':
            exif = data[offset + 8:offset + 8 + size]
            endian = '<' if exif[:2] == b'II' else '>'
            directory = struct.unpack_from(endian + 'I', exif, 4)[0]
            count = struct.unpack_from(endian + 'H', exif, directory)[0]
            for index in range(count):
                entry = directory + 2 + index * 12
                if struct.unpack_from(endian + 'H', exif, entry)[0] == 0x112:
                    orientation = struct.unpack_from(endian + 'H', exif, entry + 8)[0]
        offset += size + 12
    return (height, width) if orientation in (5, 6, 7, 8) else (width, height)


with tempfile.TemporaryDirectory(prefix='pocahontas-screenshots-') as temporary:
    exported = pathlib.Path(temporary)
    subprocess.run([
        'xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(args.result),
        '--output-path', str(exported),
    ], check=True)
    manifest = json.loads((exported / 'manifest.json').read_text())
    screenshots = {}
    for test in manifest:
        for attachment in test['attachments']:
            name = attachment['suggestedHumanReadableName']
            match = re.match(r'^(\d{2}-[a-z-]+)_', name)
            if match:
                screenshots[match.group(1)] = exported / attachment['exportedFileName']
    if len(screenshots) != 23:
        raise SystemExit(f'Expected 23 screenshots, found {len(screenshots)}; destination unchanged.')
    for name, source in screenshots.items():
        width, height = display_size(source)
        if ('landscape' in name) != (width > height):
            raise SystemExit(f'Incorrect screenshot orientation: {name} ({width}x{height}); destination unchanged.')
    args.destination.mkdir(parents=True, exist_ok=True)
    for name, source in sorted(screenshots.items()):
        shutil.copyfile(source, args.destination / f'{name}.png')
    print(f'Exported {len(screenshots)} original screenshots to {args.destination}')
