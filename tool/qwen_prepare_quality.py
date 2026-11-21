"""Build a reproducible, annotated VLM test set from the existing cached ROD test split."""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageOps

NAMES = ['Bike', 'Building', 'Car', 'Person', 'Stairs', 'Traffic sign', 'Electrical Pole', 'Road',
         'Motorcycle', 'Dustbin', 'Dog', 'Manhole', 'Tree', 'Guard rail', 'Pedestrian crosswalk',
         'Truck', 'Bus', 'Bench', 'Traffic Cone', 'Fire hydrant', 'Traffic Barrel', 'Plant Pot',
         'Electrical Box', 'Chair', 'Bicycle Rack']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dataset', type=Path, default=Path.home() / '.cache/kagglehub/datasets/abtinzandi/obstacle-detection-dataset/versions/4/ROD-Dataset/dataset/test')
    parser.add_argument('--output', type=Path, default=Path('.codex-tmp/qwen8/quality'))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    images = []
    paths = {p.stem: p for p in (args.dataset / 'images').iterdir() if p.is_file()}
    for label in sorted((args.dataset / 'labels').glob('*.txt')):
        image = paths.get(label.stem)
        if image is None:
            continue
        boxes = [list(map(float, line.split())) for line in label.read_text().splitlines() if line.strip()]
        images.append((image, boxes))
    selected = []
    for class_id, count in [(4, 4), (23, 2), (3, 2), (2, 2), (14, 2), (12, 1), (21, 1), (1, 2)]:
        matches = [(p, boxes) for p, boxes in images if any(int(b[0]) == class_id for b in boxes) and p not in [x[0] for x in selected]]
        selected.extend(matches[:count])
    assert len(selected) == 16, 'Need sixteen distinct annotated originals'
    cases = [(p, boxes, 'original') for p, boxes in selected]
    cases += [(selected[i][0], selected[i][1], variant) for i, variant in [(0, 'dark'), (6, 'blur'), (8, 'dark'), (10, 'blur')]]
    manifest = []
    sheet = Image.new('RGB', (1250, 1000), 'white')
    draw = ImageDraw.Draw(sheet)
    for i, (source, boxes, variant) in enumerate(cases):
        with Image.open(source) as original:
            image = ImageOps.exif_transpose(original).convert('RGB')
            image.thumbnail((640, 640))
        if variant == 'dark':
            image = ImageEnhance.Brightness(image).enhance(.12)
        elif variant == 'blur':
            image = image.filter(ImageFilter.GaussianBlur(9))
        target = args.output / f'{i+1:02d}-{variant}.jpg'
        image.save(target, 'JPEG', quality=85)
        annotations = [{'object': NAMES[int(box[0])], 'bbox_normalized_xywh': box[1:],
                        'horizontal': 'left' if box[1] < .4 else 'right' if box[1] > .6 else 'center'} for box in boxes]
        manifest.append({'id': i+1, 'path': target.as_posix(), 'source': source.name,
                         'dataset': 'abtinzandi/obstacle-detection-dataset version 4; ROD test split',
                         'variant': variant, 'sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                         'annotations': annotations, 'annotation_note': 'Dataset labels are not exhaustive; dark/blur variants require limitations, not confident object inventories.'})
        x, y = (i % 5)*250, (i // 5)*250
        sheet.paste(ImageOps.contain(image, (245, 210)), (x, y+30))
        draw.text((x+3, y+5), f'{i+1}: {variant} {source.name}', fill='black')
    sheet.save(args.output / 'contact.jpg')
    Path('docs/qwen3_vl_quality_manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'Prepared {len(manifest)} annotated images')


if __name__ == '__main__':
    main()
