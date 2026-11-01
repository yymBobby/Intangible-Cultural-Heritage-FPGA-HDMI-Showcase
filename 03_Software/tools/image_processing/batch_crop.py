"""Reproduce the 16 published crops using the unchanged GitHub converter."""
import argparse
import hashlib
import json
from pathlib import Path
from PIL import Image
from convert_images_to_bmp import prepare_image

PACKAGE=Path(__file__).resolve().parents[3]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recipe',type=Path,default=PACKAGE/'04_Media/crop_recipe.json')
    parser.add_argument('--output-dir',type=Path,default=PACKAGE/'03_Software/output/cropped_images')
    args=parser.parse_args()
    entries=json.loads(args.recipe.read_text('utf8'))
    args.output_dir.mkdir(parents=True,exist_ok=False)
    checks=[]
    for entry in entries:
        source=args.recipe.parent/entry['source']
        if hashlib.sha256(source.read_bytes()).hexdigest()!=entry['source_sha256']:
            raise ValueError('Source differs from recorded crop input: '+source.name)
        with Image.open(source) as im:
            cropped=prepare_image(im,640,480,'crop',tuple(entry['crop_box']))
        target=args.output_dir/entry['output'];cropped.save(target,'BMP')
        digest=hashlib.sha256(target.read_bytes()).hexdigest()
        if digest!=entry['expected_sha256']:
            raise ValueError('Crop differs from published BMP: '+target.name)
        checks.append({'file':target.name,'bytes':target.stat().st_size,'sha256':digest,'matches_github':True})
    report={'status':'PASS','count':len(checks),'method':'EXIF orientation, recorded exact 4:3 crop, uniform LANCZOS resize','checks':checks}
    (args.output_dir/'crop_verification.json').write_text(json.dumps(report,indent=2),encoding='utf8')
    print(f'PASS: {len(checks)} crops match the published GitHub BMP files byte-for-byte.')

if __name__=='__main__':main()
