from pathlib import Path
from PIL import Image,ImageDraw
import json, subprocess, tempfile
root=Path(__file__).resolve().parent.parent
DAY='Design/BrandIcons/投屏-折屏-day-20261109.png'
NIGHT='Design/BrandIcons/投屏-折屏-night-20261109.png'
CATALOG=None
PATTERN=None

def render(path):
    art=Image.open(root/path).convert('RGBA').resize((864,864),Image.Resampling.LANCZOS)
    mask=Image.new('L',(864,864));ImageDraw.Draw(mask).rounded_rectangle((0,0,863,863),radius=190,fill=255)
    art.putalpha(mask);out=Image.new('RGBA',(1024,1024));out.paste(art,(80,80));return out
images={'Day':render(DAY),'Night':render(NIGHT)}
for mode,image in images.items():
    path=root/(PATTERN.format(mode=mode) if PATTERN else ('MacCaster/MacCaster/MacIcon-Night-1024.png' if mode=='Night' else 'MacCaster/MacCaster/MacIcon-1024.png'))
    image.save(path)
if CATALOG:
    folder=root/CATALOG;data=json.loads((folder/'Contents.json').read_text())
    for slot in data['images']:
        if slot.get('idiom')!='mac' or not slot.get('filename'):continue
        n=round(float(slot['size'].split('x')[0])*float(slot.get('scale','1x')[:-1]))
        images['Day'].resize((n,n),Image.Resampling.LANCZOS).save(folder/slot['filename'])
else:
    folder=Path(tempfile.mkdtemp())/'AppIcon.iconset';folder.mkdir()
    for n in (16,32,128,256,512):
        for scale in (1,2):
            images['Day'].resize((n*scale,n*scale),Image.Resampling.LANCZOS).save(folder/('icon_%sx%s%s.png'%(n,n,'@2x' if scale==2 else '')))
    subprocess.run(['iconutil','-c','icns',str(folder),'-o',str(root/'MacCaster/MacCaster/AppIcon-Fold.icns')],check=True)
print('Mac icons normalized: 864px tile on 1024px canvas')
