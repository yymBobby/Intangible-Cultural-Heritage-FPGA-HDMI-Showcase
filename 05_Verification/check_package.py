"""Read-only package checksum, project-reference and English-path validation."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]

def semantic_sha(path):
    root=ET.fromstring(path.read_bytes().replace(b'UsedInP&R',b'UsedInP&amp;R'))
    root.attrib.pop('Path',None)
    for node in root.iter('Attr'):
        if node.get('Name')=='CompileOrder':node.set('Val','NORMALIZED')
    canonical=ET.canonicalize(ET.tostring(root,encoding='unicode'),strip_text=True)
    return hashlib.sha256(canonical.encode('utf8')).hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--with-media',action='store_true',help='Also require and verify the media release attachments.')
    args=parser.parse_args()
    manifest=json.loads((ROOT/'05_Verification/package_file_manifest.json').read_text('utf8'))
    failures=[]
    items=manifest['files']+(manifest.get('optional_media',[]) if args.with_media else [])
    for item in items:
        p=ROOT/item['path']
        if not p.is_file():failures.append('Missing: '+item['path']);continue
        digest=semantic_sha(p) if item.get('project_semantic_sha256') else hashlib.sha256(p.read_bytes()).hexdigest()
        expected=item.get('project_semantic_sha256') or item['sha256']
        if digest!=expected:failures.append('Changed: '+item['path'])
    project=ROOT/'01_FPGA_Project/src/td_project/Media_AV_Visualizer_Ultimate.al'
    doc=ET.fromstring(project.read_bytes().replace(b'UsedInP&R',b'UsedInP&amp;R'))
    refs=doc.findall('.//Source_Files//File')
    for item in refs:
        if 'Path' not in item.attrib:continue
        p=(project.parent/item.get('Path')).resolve()
        if not p.is_relative_to((ROOT/'01_FPGA_Project').resolve()) or not p.is_file():failures.append('Invalid project reference: '+item.get('Path'))
    for p in ROOT.rglob('*'):
        if '.git' in p.relative_to(ROOT).parts:continue
        if not p.relative_to(ROOT).as_posix().isascii():failures.append('Non-English path: '+str(p))
    route=(ROOT/'01_FPGA_Project/src/user_source/hdl_source/control/board_menu_input.v').read_text('utf8')
    if not re.search(r'assign\s+theme_next\s*=\s*!menu_open\s*&&\s*encoder_click',route):failures.append('Rotary theme selection differs from the release')
    if failures:raise SystemExit('\n'.join(failures))
    print(f'PASS: {len(items)} file checks, {len(refs)} project references, ASCII paths, original rotary-click theme control.')
    if not args.with_media:print('Media release attachment checks omitted; use --with-media after installing the media assets and IMG.')

if __name__=='__main__':main()
