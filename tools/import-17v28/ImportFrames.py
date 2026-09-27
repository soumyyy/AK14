#!/usr/bin/env python3
"""Import licensed 17V28 frame assets from extracted PNGs and frames.json.

Run after ExtractAssetCatalog.swift, for example:
  python3 tools/import-17v28/ImportFrames.py
  python3 tools/import-17v28/ImportFrames.py --include-valentine
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path('/Applications/app17v28.app/Wrapper/app17v28.app/frames.json')
EXTRACTED = Path('/tmp/17extract/frames')
DEST = ROOT / 'Sources/Render/Resources/Assets/frames'
MANIFEST = ROOT / 'Sources/Render/Resources/Assets/manifest.json'
NORMALIZED = ROOT / 'Sources/Render/Resources/Assets/frames.json'

def rect(x, y, w, h, image_w, image_h):
    return {'x': x / image_w, 'y': y / image_h, 'width': w / image_w, 'height': h / image_h}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--include-valentine', action='store_true', help='include Valentine-category frames')
    args = parser.parse_args()
    raw = re.sub(r',\s*([}\]])', r'\1', SOURCE.read_text())
    definitions = json.loads(raw)
    DEST.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(MANIFEST.read_text())
    assets = manifest if isinstance(manifest, list) else manifest['assets']
    assets[:] = [a for a in assets if a.get('assetType') != 'frame']
    normalized = []
    before = sum(p.stat().st_size for p in DEST.glob('*.png'))
    for item in definitions:
        if item.get('category') == 'valentine' and not args.include_valentine:
            continue
        fd = item['frameData']
        typ = fd['type']
        if typ == 'plain':
            image = fd['image']; name = image['name']; point_size = image['size']
            placeholder = fd['placeholders'][0]
            size = placeholder['size']; center = placeholder['center']
            px, py = center['x'] - size['width'] / 2, center['y'] - size['height'] / 2
            image_x = image_y = 0
        else:
            image = fd[typ]; name = image['imageName']
            ir, pr = image['imageRect'], image['placeholderRect']
            point_size = ir['size']; image_x, image_y = ir['origin']['x'], ir['origin']['y']
            px, py = pr['origin']['x'] - image_x, pr['origin']['y'] - image_y
            size = pr['size']
        source = EXTRACTED / f'{name}.png'
        if not source.exists():
            continue
        dims = subprocess.check_output(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(source)], text=True)
        vals = re.findall(r'pixel(?:Width|Height): (\d+)', dims)
        image_w, image_h = map(int, vals)
        # CoreUI renders at 10 pixels per source point; use actual image dimensions as the denominator.
        sx, sy = image_w / point_size['width'], image_h / point_size['height']
        # sips rewrites a PNG losslessly and normalizes its encoding for distribution.
        dest_name = re.sub(r'[^a-z0-9-]+', '-', item['id'].lower()).strip('-') + '.png'
        dest = DEST / dest_name
        subprocess.run(['sips', '-s', 'format', 'png', str(source), '--out', str(dest)], check=True, stdout=subprocess.DEVNULL)
        asset_id = 'frame-' + dest.stem
        window = rect(px * sx, py * sy, size['width'] * sx, size['height'] * sy, image_w, image_h)
        entry = {'id': item['id'], 'category': item['category'], 'imageAssetID': asset_id,
                 'imageWidth': image_w, 'imageHeight': image_h, 'photoWindow': window}
        normalized.append(entry)
        assets.append({'assetID': asset_id, 'relativePath': f'frames/{dest_name}', 'assetType': 'frame',
                        'sha256': hashlib.sha256(dest.read_bytes()).hexdigest(),
                        'licenseName': '17V28 team — permitted for AK14',
                        'author': '17V28 team', 'sourceURL': f"17v28:frames.json:{item['id']}"})
    NORMALIZED.write_text(json.dumps(sorted(normalized, key=lambda x: x['id']), indent=2) + '\n')
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    after = sum(p.stat().st_size for p in DEST.glob('*.png'))
    print(f'Imported {len(normalized)} frames; added {after - before:,} bytes of PNG data.')

if __name__ == '__main__': main()
