import colorsys
def hx(c): c=c.lstrip('#'); return tuple(int(c[i:i+2],16)/255 for i in (0,2,4))
def tohex(rgb): return '%02x%02x%02x' % tuple(max(0,min(255,round(v*255))) for v in rgb)
def hls(c): r,g,b=hx(c); return colorsys.rgb_to_hls(r,g,b)
CL=dict(
 navy=['edf1f7','d6dfec','b3c3da','93aeda','6582b1','23436f','1a365c','132a4a','0e2340','0a1628'],
 slate=['f2f1ec','dee2e8','c4cbd6','a6b0c0','8691a4','677387','4c576b','354052','212b3b','0f1a2a'],
 brass=['faf4e4','f1e3ba','e5cd8a','d4b160','be943e','a07a2c','7e5f21','5c4518','3c2d10','221a09'],
 gray=['fdfcf8','f6f3ea','eeeadf','e3ded1','d6d1c3','c7c2b5','b7b3a7','a6a397','949186','817f75','67665e','51514c','3e4049','2e333d','242a35','1b212c','161b25','12171f','0f141b'])
def ramp(ref, h, s, pin=None):
    out=[]
    for i,c in enumerate(ref):
        _,l,_=hls(c); out.append(tohex(colorsys.hls_to_rgb(h/360,l,s)))
    if pin:
        for i,c in pin.items(): out[i]=c.lstrip('#').lower()
    return out
def gray(hl, sl, hd, sd):
    out=[]
    for i,c in enumerate(CL['gray']):
        _,l,_=hls(c); h,s=(hl,sl) if i<=11 else (hd,sd)
        out.append(tohex(colorsys.hls_to_rgb(h/360,l,s)))
    return out
T={}
T['classic']=dict(CL, style=dict(paperLight='f4f1e8',paperDark='0b1626',inkLight='0e2340',inkDark='ede8da',bandLight='0e2340',bandDark='16263f',stripeLight='9e2b2b',stripeDark='c2443a',accentLight='1a365c',accentDark='93aeda',cardDark='16263f'))
T['sunflower']=dict(navy=ramp(CL['navy'],212,0.85,{5:'0057b7',3:'7db3f5'}), slate=ramp(CL['slate'],214,0.28), brass=ramp(CL['brass'],50,1.0,{3:'ffd500'}),
  gray=gray(50,0.45,214,0.42), style=dict(paperLight='fbf7e6',paperDark='071a33',inkLight='003a7a',inkDark='fff4c2',bandLight='0057b7',bandDark='0b2a52',stripeLight='ffd500',stripeDark='ffd500',accentLight='0057b7',accentDark='7db3f5',cardDark='0d2747'))
T['midnightGold']=dict(navy=ramp(CL['navy'],42,0.55,{5:'7f6119',3:'d4af5a'}), slate=ramp(CL['slate'],222,0.18), brass=ramp(CL['brass'],42,0.6),
  gray=gray(45,0.35,222,0.30), style=dict(paperLight='f6f2e7',paperDark='0a0f1c',inkLight='1b1a17',inkDark='e9d9a8',bandLight='141b2c',bandDark='141b2c',stripeLight='b8923e',stripeDark='d4af5a',accentLight='7f6119',accentDark='d4af5a',cardDark='141b2c'))
T['oxblood']=dict(navy=ramp(CL['navy'],0,0.60,{5:'8e2424',3:'e58c84'}), slate=ramp(CL['slate'],355,0.14), brass=CL['brass'],
  gray=gray(40,0.35,355,0.22), style=dict(paperLight='f4f1e8',paperDark='1a0d0d',inkLight='4a1414',inkDark='ede8da',bandLight='7e2222',bandDark='2e1212',stripeLight='0e2340',stripeDark='c9c2b0',accentLight='8e2424',accentDark='e58c84',cardDark='2a1515'))
T['fieldGreen']=dict(navy=ramp(CL['navy'],155,0.45,{5:'1f5a43',3:'8cc7a8'}), slate=ramp(CL['slate'],150,0.12), brass=CL['brass'],
  gray=gray(70,0.25,150,0.25), style=dict(paperLight='f1efe4',paperDark='0c1a14',inkLight='13261d',inkDark='ece6d2',bandLight='1f3a2e',bandDark='13261d',stripeLight='b8923e',stripeDark='b8923e',accentLight='1f5a43',accentDark='8cc7a8',cardDark='15281f'))
T['monochrome']=dict(navy=ramp(CL['navy'],0,0.0,{5:'1a1a1a',3:'d0d0d0'}), slate=ramp(CL['slate'],0,0.0), brass=ramp(CL['brass'],0,0.0),
  gray=gray(0,0.0,0,0.0), style=dict(paperLight='ffffff',paperDark='000000',inkLight='111111',inkDark='f2f2f2',bandLight='111111',bandDark='1c1c1c',stripeLight='111111',stripeDark='f2f2f2',accentLight='1a1a1a',accentDark='d0d0d0',cardDark='1c1c1e'))
def arr(xs):
    items=['0x'+x for x in xs]
    if len(items)<=10: return '[' + ', '.join(items) + ']'
    rows=[', '.join(items[i:i+10]) for i in range(0,len(items),10)]
    return '[\n            ' + ',\n            '.join(rows) + '\n        ]'
out=[]
for k,t in T.items():
    s=t['style']
    out.append(f'''    static let {k} = FerretPalette(
        accent: {arr(t['navy'])},
        ink: {arr(t['slate'])},
        secondary: {arr(t['brass'])},
        neutral: {arr(t['gray'])},
        style: .init(paperLight: 0x{s['paperLight']}, paperDark: 0x{s['paperDark']},
                     inkLight: 0x{s['inkLight']}, inkDark: 0x{s['inkDark']},
                     bandLight: 0x{s['bandLight']}, bandDark: 0x{s['bandDark']},
                     stripeLight: 0x{s['stripeLight']}, stripeDark: 0x{s['stripeDark']},
                     accentLight: 0x{s['accentLight']}, accentDark: 0x{s['accentDark']},
                     cardDark: 0x{s['cardDark']})
    )''')
open('palettes.swift.txt','w').write('\n\n'.join(out))
import json; json.dump(T, open('palettes.json','w'))
print(max(len(l) for l in '\n'.join(out).split('\n')))
