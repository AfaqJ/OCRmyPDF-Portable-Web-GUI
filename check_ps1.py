#!/usr/bin/env python3
"""Parser-aware structure check for the .ps1 files. Not a PowerShell parser --
it tracks block comments, here-strings, single/double quotes and the escape
rules well enough to catch an unterminated string or an unbalanced block, which
is what a macOS build machine can actually check. It cannot see runtime
semantics: the array-flattening bug was invisible to it."""
import sys

def check_bytes(src):
    bad = [i for i, b in enumerate(src) if b > 127]
    errs = []
    if bad:
        errs.append("non-ASCII byte at offset %d (.ps1 must stay pure ASCII)" % bad[0])
    if src[:3] == b'\xef\xbb\xbf':
        errs.append("file has a BOM")
    s = src.decode('ascii', 'replace')
    close = {'}': '{', ')': '(', ']': '['}
    stack = []
    i, line, n = 0, 1, len(s)
    here = None
    while i < n:
        c = s[i]
        if c == '\n':
            line += 1; i += 1; continue
        if here is not None:                      # inside a here-string
            if s[i - 1] == '\n' and s[i:i + 2] == here[0]:
                here = None; i += 2
            else:
                i += 1
            continue
        if s[i:i + 2] == '<#':                    # block comment
            j = s.find('#>', i + 2)
            if j < 0: errs.append("line %d: unterminated <# block comment" % line); break
            line += s.count('\n', i, j); i = j + 2; continue
        if c == '#':                              # line comment
            j = s.find('\n', i)
            i = n if j < 0 else j; continue
        if s[i:i + 2] in ('@"', "@'") and (i == 0 or s[i - 1] in '\n =,(') :
            here = (s[i + 1] + '@', line); i += 2; continue
        if c == '`':                              # escape
            i += 2; continue
        if c in '"\'':                            # quoted string
            q, i = c, i + 1
            while i < n:
                if s[i] == '\n': line += 1
                if q == '"' and s[i] == '`': i += 2; continue
                if s[i] == q:
                    if i + 1 < n and s[i + 1] == q: i += 2; continue
                    break
                i += 1
            else:
                errs.append("line %d: unterminated %s string" % (line, q)); break
            i += 1; continue
        if c in close.values(): stack.append((c, line))
        elif c in close:
            if not stack or stack[-1][0] != close[c]:
                errs.append("line %d: unexpected '%s'" % (line, c)); break
            stack.pop()
        i += 1
    if here is not None:
        errs.append("line %d: unterminated here-string" % here[1])
    for opener, start_line in stack:
        errs.append("line %d: unclosed '%s'" % (start_line, opener))
    return errs

def check(path):
    return check_bytes(open(path, 'rb').read())

def selftest():
    cases = [
        (b'$x = @{ value = (1 + 2) }\n', False),
        (b'$x = "unterminated\n', True),
        (b'$x = @"\nunterminated\n', True),
        (b'$x = ([)]\n', True),
        (b'$x = "\xff"\n', True),
    ]
    failed = [src for src, want_bad in cases if bool(check_bytes(src)) != want_bad]
    print("ok   check_ps1 self-test" if not failed else "FAIL check_ps1 self-test")
    return bool(failed)

if sys.argv[1:] == ['--selftest']:
    sys.exit(1 if selftest() else 0)
if len(sys.argv) == 1:
    print("usage: check_ps1.py [--selftest | FILE ...]", file=sys.stderr)
    sys.exit(2)

bad = False
for p in sys.argv[1:]:
    e = check(p)
    print(("FAIL " if e else "ok   ") + p)
    for x in e: print("      " + x); bad = True
sys.exit(1 if bad else 0)
