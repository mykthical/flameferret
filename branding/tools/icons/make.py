import math, cairosvg
exec(open('base.py').read())
def petals(cx, cy, r_in, r_out, n, color, opacity):
    s=''
    for i in range(n):
        a=2*math.pi*i/n
        tip=(cx+r_out*math.cos(a), cy+r_out*math.sin(a))
        l=(cx+r_in*math.cos(a-math.pi/n*0.9), cy+r_in*math.sin(a-math.pi/n*0.9))
        r=(cx+r_in*math.cos(a+math.pi/n*0.9), cy+r_in*math.sin(a+math.pi/n*0.9))
        s+=f'<path d="M{l[0]:.2f} {l[1]:.2f} Q{cx+(r_in+r_out)/2*math.cos(a-0.12):.2f} {cy+(r_in+r_out)/2*math.sin(a-0.12):.2f} {tip[0]:.2f} {tip[1]:.2f} Q{cx+(r_in+r_out)/2*math.cos(a+0.12):.2f} {cy+(r_in+r_out)/2*math.sin(a+0.12):.2f} {r[0]:.2f} {r[1]:.2f} Z" fill="{color}" opacity="{opacity}"/>'
    return s
O={
 'classic': dict(name='Classic', bg='#F4F1E8', globe='#0E2340', band='#0E2340', stripe='#9E2B2B', text='#F4F1E8'),
 'ukraine': dict(name='Sunflower (Ukraine)', bg='#0057B7', globe='#FFD500', band='#FFD500', stripe=None, text='#0057B7', extra='petals'),
 'midnight': dict(name='Midnight Gold', bg='#0A0F1C', globe='#D4AF5A', band='#141B2C', stripe='#D4AF5A', text='#D4AF5A'),
 'oxblood': dict(name='Oxblood', bg='#7E2222', globe='#F4F1E8', band='#0E2340', stripe='#F4F1E8', text='#F4F1E8'),
 'field': dict(name='Field Green', bg='#1F3A2E', globe='#ECE6D2', band='#13261D', stripe='#B8923E', text='#ECE6D2'),
 'mono': dict(name='Monochrome', bg='#FFFFFF', globe='#111111', band='#111111', stripe=None, text='#FFFFFF'),
}
def icon(c):
    s=f'<rect width="100" height="100" fill="{c["bg"]}"/>'
    if c.get('extra')=='petals':
        s+=petals(50,44,24,36,16,'#FFD500',0.95)
        s+=f'<circle cx="50" cy="44" r="26" fill="#0057B7"/>'
    s+=f'<rect x="0" y="80" width="100" height="20" fill="{c["band"]}"/>'
    if c['stripe']: s+=f'<rect x="0" y="77" width="100" height="2" fill="{c["stripe"]}"/>'
    s+=globe(50,44,25 if not c.get('extra') else 21,c['globe'],2.2 if not c.get('extra') else 2.0)+text_path('FERRET',50,93.6,7.2,c['text'])
    return s
from PIL import Image, ImageDraw, ImageFont
for k,c in O.items():
    svg=f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="1024" height="1024">{icon(c)}</svg>'
    open(f'{k}.svg','w').write(svg); cairosvg.svg2png(bytestring=svg.encode(), write_to=f'{k}.png', output_width=1024, output_height=1024)
print('ok')
