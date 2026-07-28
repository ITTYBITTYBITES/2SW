"""Static sanity pass over GDScript: balanced blocks, tabs-only indent,
signal/const/func duplication, and obvious call-site typos."""
import re, sys, pathlib

errs, warns = [], []
files = sorted((f for f in pathlib.Path('.').rglob('*.gd') if 'legacy_reference' not in f.parts))

for f in files:
    src = f.read_text()
    lines = src.split('\n')

    # 1. Indentation must be tabs (Godot rejects mixed).
    for i, ln in enumerate(lines, 1):
        if ln.startswith(' ') and ln.strip() and not ln.lstrip().startswith('#'):
            stripped = ln.lstrip(' ')
            if stripped and not ln.startswith('\t'):
                errs.append(f"{f}:{i}: leading SPACE indent (Godot wants tabs)")
        if '\t' in ln and ln.index('\t') > 0 and ln[:ln.index('\t')].strip()=='' and ' ' in ln[:ln.index('\t')]:
            errs.append(f"{f}:{i}: mixed space+tab indent")

    # 2. Block openers must be followed by deeper indent.
    #    Skip CONTINUATION lines: a multi-line func signature or a wrapped
    #    expression ends in ':' only on its final physical line, and its
    #    continuation is indented deeper than the body. Detect by checking
    #    whether parens are still open when the ':' appears.
    for i, ln in enumerate(lines):
        s = ln.rstrip()
        if not s or s.lstrip().startswith('#'): continue
        # A line that continues an unclosed bracket is not a block opener.
        probe = re.sub(r'"[^"]*"', '""', re.sub(r'#.*$', '', s))
        if probe.count('(') < probe.count(')'):
            continue
        # Nor is one continued from the PREVIOUS line via a trailing backslash:
        # `if a \` / `        and b:` puts the colon on the continuation, whose
        # indent is deeper than the body that follows.
        if i > 0 and lines[i - 1].rstrip().endswith('\\'):
            continue
        if s.endswith(':') and not s.lstrip().startswith(('#','"')):
            depth = len(s) - len(s.lstrip('\t'))
            nxt = None
            for j in range(i+1, len(lines)):
                if lines[j].strip() and not lines[j].lstrip().startswith('#'):
                    nxt = lines[j]; break
            if nxt is not None:
                ndepth = len(nxt) - len(nxt.lstrip('\t'))
                if ndepth <= depth:
                    errs.append(f"{f}:{i+1}: block opens but next line not indented -> {s.strip()[:60]}")

    # 2b. Locals shadowing common Node/Control members.
    #     `var rotation` inside a Control shadows Control.rotation, so a
    #     stray assignment spins the node instead of the value. Caught three
    #     separate times by the engine warning sweep, each time after the code
    #     had already been committed once — cheaper to fail here in a second.
    SHADOW_NAMES = {"rotation", "scale", "position", "size", "name", "owner",
                    "visible", "modulate", "ready", "theme", "tooltip"}
    for i, ln in enumerate(lines, 1):
        m = re.match(r"^\s*var\s+(\w+)\s*[:=]", ln)
        if m and m.group(1) in SHADOW_NAMES:
            errs.append(
                f"{f}:{i}: local 'var {m.group(1)}' shadows a Node/Control "
                f"member; rename it")

    # 3. Duplicate func / const / signal names.
    for kind, pat in (('func', r'^\s*(?:static\s+)?func\s+(\w+)'),
                      ('const', r'^\s*const\s+(\w+)'),
                      ('signal', r'^\s*signal\s+(\w+)')):
        names = re.findall(pat, src, re.M)
        seen = set()
        for n in names:
            if n in seen:
                errs.append(f"{f}: duplicate {kind} '{n}'")
            seen.add(n)

    # 4. Unbalanced brackets per logical line.
    for i, ln in enumerate(lines, 1):
        code = re.sub(r'#.*$', '', ln)
        code = re.sub(r'"[^"]*"', '""', code)
        nxt_raw = lines[i].strip() if i < len(lines) else ''
        continues = nxt_raw.startswith(('and ', 'or ', ')', '.', ',', ']', '}', '+ ', '- '))
        # An inline lambda -- tween_callback(func() -> void:  -- legitimately
        # leaves a paren open across lines.
        if 'func(' in code and code.rstrip().endswith(':'):
            continues = True
        if (code.count('(') != code.count(')')
                and not continues
                and not code.rstrip().endswith(('\\', ',', '(', '[', '{'))):
            nxt = lines[i] if i < len(lines) else ''
            if code.count('(') > code.count(')') and not nxt.strip().startswith((')', '.')):
                warns.append(f"{f}:{i}: paren imbalance? {ln.strip()[:70]}")

print(f"scanned {len(files)} .gd files")
for e in errs: print("ERROR  ", e)
for w in warns[:15]: print("warn   ", w)
print(f"\n{len(errs)} errors, {len(warns)} warnings")
sys.exit(1 if errs else 0)
