import cairosvg
exec(open('make.py').read().split('from PIL import')[0])
DARK={
 'classic': dict(bg='#0B1626', globe='#EDE8DA', band='#16263F', stripe='#C2443A', text='#EDE8DA'),
 'ukraine': dict(bg='#002B5C', globe='#FFD500', band='#FFD500', stripe=None, text='#002B5C', extra='petals', petalbg='#002B5C'),
 'midnight': dict(O['midnight']),
 'oxblood': dict(bg='#3A1010', globe='#EDE8DA', band='#0B1626', stripe='#C9C2B0', text='#EDE8DA'),
 'field': dict(bg='#0F2119', globe='#ECE6D2', band='#0A1711', stripe='#B8923E', text='#ECE6D2'),
 'mono': dict(bg='#000000', globe='#FFFFFF', band='#FFFFFF', stripe=None, text='#000000'),
}
def icon2(c, petal='#FFD500', disc=None):
    s=f'<rect width="100" height="100" fill="{c["bg"]}"/>'
    if c.get('extra')=='petals':
        s+=petals(50,44,24,36,16,petal,0.95)+f'<circle cx="50" cy="44" r="26" fill="{disc or c["bg"]}"/>'
    s+=f'<rect x="0" y="80" width="100" height="20" fill="{c["band"]}"/>'
    if c['stripe']: s+=f'<rect x="0" y="77" width="100" height="2" fill="{c["stripe"]}"/>'
    small=c.get('extra')=='petals'
    s+=globe(50,44,21 if small else 25,c['globe'],2.0 if small else 2.2)+text_path('FERRET',50,93.6,7.2,c['text'])
    return s
def tinted(k):
    base=O[k]; c=dict(bg='#000000', globe='#FFFFFF', band='#3A3A3A', stripe=None if not base['stripe'] else '#8A8A8A', text='#FFFFFF', extra=base.get('extra'))
    return icon2(c, petal='#BDBDBD', disc='#000000')
def png(svgbody, path):
    cairosvg.svg2png(bytestring=f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="1024" height="1024">{svgbody}</svg>'.encode(), write_to=path, output_width=1024, output_height=1024)
import os; os.makedirs('out', exist_ok=True)
for k in O:
    png(icon2(O[k]), f'out/{k}-light.png'); png(icon2(DARK[k]), f'out/{k}-dark.png'); png(tinted(k), f'out/{k}-tinted.png')
print('ok')
