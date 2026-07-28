"""Verify cross-file references: autoload methods/consts called from elsewhere exist."""
import re, pathlib, sys

AUTOLOADS = {'Log':'core/log.gd','Cfg':'core/cfg.gd','Save':'core/save.gd',
             'Bus':'core/bus.gd','Router':'core/router.gd',
             'Palette':'design/palette.gd'}
STATICS   = {}

def members(path):
    src = pathlib.Path(path).read_text()
    return {
      'func': set(re.findall(r'^\s*(?:static\s+)?func\s+(\w+)', src, re.M)),
      'const': set(re.findall(r'^\s*const\s+(\w+)', src, re.M)),
      'signal': set(re.findall(r'^\s*signal\s+(\w+)', src, re.M)),
      'var': set(re.findall(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:static\s+)?var\s+(\w+)', src, re.M)),
    }

tables = {n: members(p) for n,p in {**AUTOLOADS, **STATICS}.items()}
errs=[]
for f in sorted((f for f in pathlib.Path('.').rglob('*.gd') if 'legacy_reference' not in f.parts)):
    src=f.read_text()
    for name, tbl in tables.items():
        for m in re.finditer(rf'\b{name}\.(\w+)', src):
            attr=m.group(1)
            line=src[:m.start()].count('\n')+1
            if str(f).endswith(AUTOLOADS.get(name,'\x00')) or str(f).endswith(STATICS.get(name,'\x00')):
                continue
            allm = tbl['func']|tbl['const']|tbl['signal']|tbl['var']
            if attr not in allm:
                errs.append(f"{f}:{line}: {name}.{attr} NOT FOUND")

# Signal emissions must match declared signals in Bus
bus = tables['Bus']['signal']
for f in sorted((f for f in pathlib.Path('.').rglob('*.gd') if 'legacy_reference' not in f.parts)):
    src=f.read_text()
    for m in re.finditer(r'\bBus\.(\w+)\.(emit|connect)\b', src):
        if m.group(1) not in bus:
            errs.append(f"{f}: Bus.{m.group(1)} not a declared signal")

for e in errs: print("ERROR ", e)
print(f"\n{len(errs)} cross-reference errors")
sys.exit(1 if errs else 0)
