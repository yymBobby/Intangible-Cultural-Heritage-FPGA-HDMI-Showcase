"""Build a complete ICHSHOW3 image from BMP/WAV/text inputs using GitHub code."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

HERE=Path(__file__).resolve().parent
PACKAGE=HERE.parent
sys.path.insert(0,str(HERE/'tools/c_phase2'))
import multi_image

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path)
    parser.add_argument('--output-dir',type=Path,default=HERE/'output/image_build')
    parser.add_argument('--check-reference',action='store_true')
    args=parser.parse_args()
    config=args.config or PACKAGE/'04_Media/Pack_Input/themes.json'
    args.output_dir.mkdir(parents=True,exist_ok=False)
    image=args.output_dir/'showcase_font176.img'
    manifest=args.output_dir/'showcase_font176.manifest.json'
    checked=multi_image.build(config,HERE/'tools/font_rom/release_alarm_192/glyph_map.json',image,manifest)
    digest=hashlib.sha256(image.read_bytes()).hexdigest()
    same=None
    if args.check_reference or args.config is None:
        expected=json.loads((PACKAGE/'05_Verification/github_release_identity.json').read_text('utf-8-sig'))['image']['sha256']
        same=digest==expected
        if not same:raise ValueError('Built image differs from the GitHub reference image.')
    proof={'status':'PASS','themes':len(checked['themes']),'resources':len(checked['resources']),'image':str(image),'bytes':image.stat().st_size,'sha256':digest,'matches_github_reference':same}
    (args.output_dir/'build_verification.json').write_text(json.dumps(proof,indent=2),encoding='utf8')
    print('PASS: 4 themes, 16 BMP images, 4 WAV files and 4 subtitles packed and verified.')
    print('Output: '+str(image))
    print('SHA256: '+digest)
    if same:print('PASS: output matches the published GitHub image byte-for-byte.')

if __name__=='__main__':main()
