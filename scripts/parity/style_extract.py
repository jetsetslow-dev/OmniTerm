"""Per-label text style extraction for Kotlin Compose and Flutter, used by parity-audit.py."""
import re

def _call_args(text, start):
    """Return the argument text of the call whose '(' is at text[start]."""
    depth, i, q = 0, start, None
    while i < len(text):
        c = text[i]
        if q:
            if c == '\\': i += 2; continue
            if c == q: q = None
        elif c in '"\'': q = c
        elif c == '(': depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0: return text[start + 1:i]
        i += 1
    return text[start + 1:]

KT_WEIGHT = {'Bold': 'bold', 'SemiBold': 'semibold', 'Medium': 'medium', 'Normal': 'normal', 'Light': 'light', 'Black': 'black', 'ExtraBold': 'extrabold'}
FL_WEIGHT = {'bold': 'bold', 'w700': 'bold', 'w600': 'semibold', 'w500': 'medium', 'normal': 'normal', 'w400': 'normal', 'w300': 'light', 'w900': 'black', 'w800': 'extrabold'}

def kotlin_styles(text, resources):
    out = {}
    for m in re.finditer(r'\bText\(', text):
        args = _call_args(text, m.end() - 1)
        s = None
        lm = re.match(r'\s*"((?:[^"\\$]|\\.){3,})"', args)
        if lm: s = lm.group(1)
        else:
            rm = re.match(r'\s*(?:text\s*=\s*)?stringResource\(R\.string\.([a-z0-9_]+)', args)
            if rm and rm.group(1) in resources: s = resources[rm.group(1)]
        if not s: continue
        st = {}
        if (fs := re.search(r'fontSize\s*=\s*([\d.]+)\.sp', args)): st['size'] = float(fs.group(1))
        if (fw := re.search(r'fontWeight\s*=\s*FontWeight\.(\w+)', args)): st['weight'] = KT_WEIGHT.get(fw.group(1), fw.group(1).lower())
        if (ta := re.search(r'textAlign\s*=\s*TextAlign\.(\w+)', args)): st['align'] = ta.group(1).lower()
        if re.search(r'fontFamily\s*=\s*OmniFonts\.mono|FontFamily\.Monospace', args): st['family'] = 'mono'
        if re.search(r'fontFamily\s*=\s*OmniFonts\.display', args): st['family'] = 'display'
        out.setdefault(s, st)
    return out

def flutter_styles(text):
    out = {}
    for m in re.finditer(r'\bText\(', text):
        args = _call_args(text, m.end() - 1)
        lm = re.match(r"\s*'((?:[^'\\]|\\.){3,})'", args)
        if not lm: continue
        s = lm.group(1).replace("\\'", "'")
        st = {}
        if (fs := re.search(r'fontSize:\s*([\d.]+)', args)): st['size'] = float(fs.group(1))
        elif re.search(r'composeBody\(\s*\)|composeBody\(\s*(?:color|fontWeight|fontFamily)', args): st['size'] = 16.0
        if (fw := re.search(r'fontWeight:\s*FontWeight\.(\w+)', args)): st['weight'] = FL_WEIGHT.get(fw.group(1), fw.group(1))
        if (ta := re.search(r'textAlign:\s*TextAlign\.(\w+)', args)): st['align'] = ta.group(1).lower()
        if re.search(r'fontFamily:\s*OmniFonts\.mono', args): st['family'] = 'mono'
        if re.search(r'fontFamily:\s*OmniFonts\.display', args): st['family'] = 'display'
        out.setdefault(s, st)
    return out
