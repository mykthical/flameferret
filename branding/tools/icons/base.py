import cairosvg, math
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
FONT=TTFont('/usr/share/texmf/fonts/opentype/public/tex-gyre/texgyrepagella-bold.otf')
def text_path(txt, cx, baseline, cap, color, track=0.18):
    gs=FONT.getGlyphSet(); cmap=FONT.getBestCmap(); upm=FONT['head'].unitsPerEm
    capH=getattr(FONT['OS/2'],'sCapHeight',0) or upm*0.69
    sc=cap/capH; names=[cmap[ord(ch)] for ch in txt]
    adv=[gs[n].width*sc for n in names]; tr=cap*track
    total=sum(adv)+tr*(len(txt)-1); x=cx-total/2; out=''
    for n,a in zip(names,adv):
        pen=SVGPathPen(gs); gs[n].draw(TransformPen(pen,(sc,0,0,-sc,x,baseline)))
        out+=f'<path d="{pen.getCommands()}" fill="{color}"/>'; x+=a+tr
    return out
from PIL import Image
def globe(cx, cy, r, color, w):
    s=f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{color}" stroke-width="{w}"/>'
    for k in (0.38, 0.75):
        s+=f'<ellipse cx="{cx}" cy="{cy}" rx="{r*k}" ry="{r}" fill="none" stroke="{color}" stroke-width="{w*0.8}"/>'
    s+=f'<line x1="{cx}" y1="{cy-r}" x2="{cx}" y2="{cy+r}" stroke="{color}" stroke-width="{w*0.8}"/>'
    for dy in (-0.5, 0, 0.5):
        half=r*math.sqrt(1-dy*dy)
        s+=f'<line x1="{cx-half:.2f}" y1="{cy+dy*r:.2f}" x2="{cx+half:.2f}" y2="{cy+dy*r:.2f}" stroke="{color}" stroke-width="{w*0.8}"/>'
    return s
def keyhole(cx, cy, s, color):
    return (f'<circle cx="{cx}" cy="{cy-s*0.35}" r="{s*0.32}" fill="{color}"/>'
            f'<path d="M{cx-s*0.18} {cy-s*0.2} L{cx+s*0.18} {cy-s*0.2} L{cx+s*0.3} {cy+s*0.55} L{cx-s*0.3} {cy+s*0.55} Z" fill="{color}"/>')
THEMES={
 'light':dict(bg='#F4F1E8',globe='#0E2340',text='#F4F1E8',band='#0E2340',stripe='#9E2B2B'),
 'dark': dict(bg='#0B1626',globe='#EDE8DA',text='#EDE8DA',band='#16263F',stripe='#C2443A'),
}
def icon(t):
    c=THEMES[t]
    return (f'<rect width="100" height="100" fill="{c["bg"]}"/>'
            f'<rect x="0" y="80" width="100" height="20" fill="{c["band"]}"/><rect x="0" y="77" width="100" height="2" fill="{c["stripe"]}"/>'
            + globe(50,44,25,c['globe'],2.2) + text_path('FERRET',50,93.6,7.2,c['text']))
def logo(t):
    c=THEMES[t]
    return globe(50,50,46,c['globe'],4)
