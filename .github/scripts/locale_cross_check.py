#!/usr/bin/env python3
"""
.github/scripts/locale_cross_check.py

Cross-checks qbx_k9unit/locales/en.json against every locale('...') call
site in qbx_k9unit/client/, qbx_k9unit/server/, and qbx_k9unit/html/, in
both directions:

  * MISSING: a locale() call site references a key with no entry in
    en.json. This is the dangerous direction -- ox_lib's locale() does NOT
    error at runtime on a miss, it silently returns the raw key string, so
    a player just sees literal text like "admin.usage_auditdept" instead
    of a real message. Nothing about that fails loudly: no exception, no
    log line, no red screen. This exact near-miss happened twice in one
    session and was only caught by a human manually diffing en.json
    against call sites -- this script automates that diff.

  * UNUSED: an en.json key that no call site anywhere references. Usually
    harmless (dead weight from a renamed/removed feature) but can also
    mean a call site elsewhere has a typo'd key that LOOKS unrelated to
    this one -- worth checking the MISSING list above it for a likely
    match before deleting.

Run from the repo root:  python3 .github/scripts/locale_cross_check.py
Exits 0 if both directions are clean, 1 if either direction has findings,
2 on a setup problem (en.json missing/unparseable, or it flattens to zero
keys -- refuses to run rather than flag everything as unused).

WHY COMMENTS ARE STRIPPED FIRST, PROPERLY (not `grep`, not a `--` split):
this codebase's own comments are dense prose that document past bugs and
naming decisions, and that prose routinely quotes real-looking
locale('some.key') examples for illustration -- e.g.
client/movement.lua's history of a removed
locale('movement.leash_request_sent') call, still described in a comment
long after the call itself was deleted. A naive scan (or one that only
strips `--[[ ]]` block comments but not `--` line comments, or vice versa)
either misses that example entirely or, worse, reports it as a MISSING key
that doesn't actually affect any player -- and a check that cries wolf
gets ignored. strip_lua_comments()/strip_js_comments()/strip_html() below
are small character-by-character scanners (not regexes) that track Lua/JS
string literals and Lua long-bracket strings `[[ ]]`/`[=[ ]=]` so a `--`,
`//`, or bracket INSIDE a real string is never misread as a comment
delimiter, and so a comment's content is fully removed regardless of
whether it's a `--[[ ]]` block, a run of consecutive `--` lines, a JS
`/* */` block, a JS `//` line, or an HTML `<!-- -->` block.
"""
import json
import re
import sys
from pathlib import Path

RESOURCE = Path("qbx_k9unit")
LOCALE_FILE = RESOURCE / "locales" / "en.json"
SCAN_DIRS = ["client", "server", "html"]
SCAN_EXTS = {".lua", ".js", ".html"}

LOCALE_CALL_RE = re.compile(r"""locale\(\s*['"]([A-Za-z0-9_.]+)['"]""")


def flatten_locale_keys(obj, prefix=""):
    keys = set()
    for k, v in obj.items():
        path = f"{prefix}.{k}" if prefix else k
        if isinstance(v, dict):
            keys |= flatten_locale_keys(v, path)
        else:
            keys.add(path)
    return keys


def strip_lua_comments(text):
    """Remove `--[[ ]]`/`--[=[ ]=]` long comments and `-- ...` line
    comments from Lua source, while scanning OVER (not through) single-
    and double-quoted strings and `[[ ]]`/`[=[ ]=]` long strings so a
    comment delimiter inside a real string literal is never misread as
    starting/ending a comment. Preserves line breaks so reported line
    numbers match the original source exactly."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '-' and text[i + 1:i + 2] == '-':
            j = i + 2
            if j < n and text[j] == '[':
                k = j + 1
                eqs = 0
                while k < n and text[k] == '=':
                    eqs += 1
                    k += 1
                if k < n and text[k] == '[':
                    close = ']' + ('=' * eqs) + ']'
                    end = text.find(close, k + 1)
                    body = text[i:end + len(close)] if end != -1 else text[i:]
                    out.append('\n' * body.count('\n'))
                    i = end + len(close) if end != -1 else n
                    continue
            end = text.find('\n', i)
            if end == -1:
                i = n
            else:
                out.append('\n')
                i = end + 1
            continue
        if c in ("'", '"'):
            quote = c
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == quote or text[j] == '\n':
                    j += 1
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue
        if c == '[':
            j = i + 1
            eqs = 0
            while j < n and text[j] == '=':
                eqs += 1
                j += 1
            if j < n and text[j] == '[':
                close = ']' + ('=' * eqs) + ']'
                end = text.find(close, j + 1)
                if end != -1:
                    out.append(text[i:end + len(close)])
                    i = end + len(close)
                    continue
        out.append(c)
        i += 1
    return ''.join(out)


def strip_js_comments(text):
    """Same idea as strip_lua_comments(), for JS: `//` line comments,
    `/* */` block comments, scanning over '...'/"..."/`...` strings."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '/' and text[i + 1:i + 2] == '/':
            end = text.find('\n', i)
            if end == -1:
                i = n
            else:
                out.append('\n')
                i = end + 1
            continue
        if c == '/' and text[i + 1:i + 2] == '*':
            end = text.find('*/', i + 2)
            if end == -1:
                out.append('\n' * text[i:].count('\n'))
                i = n
            else:
                out.append('\n' * text[i:end + 2].count('\n'))
                i = end + 2
            continue
        if c in ("'", '"', '`'):
            quote = c
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == quote:
                    j += 1
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def strip_html(text):
    """Strip `<!-- -->` comments, then strip JS comments inside any
    inline `<script>...</script>` body (a `src=` script tag has no
    inline body to scan). qbx_k9unit/html/index.html currently has no
    inline script (only `<script src="app.js">`), but this keeps the
    check correct if one is ever added."""
    text = re.sub(r'<!--.*?-->', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.DOTALL)

    def repl(m):
        return m.group(1) + strip_js_comments(m.group(2)) + m.group(3)

    return re.sub(
        r'(<script(?:\s[^>]*)?>)(.*?)(</script>)',
        repl,
        text,
        flags=re.DOTALL | re.IGNORECASE,
    )


def gather_call_sites():
    findings = []
    for sub in SCAN_DIRS:
        base = RESOURCE / sub
        if not base.is_dir():
            continue
        for fpath in sorted(base.rglob('*')):
            if not fpath.is_file() or fpath.suffix not in SCAN_EXTS:
                continue
            raw = fpath.read_text(encoding='utf-8')
            if fpath.suffix == '.lua':
                stripped = strip_lua_comments(raw)
            elif fpath.suffix == '.js':
                stripped = strip_js_comments(raw)
            else:
                stripped = strip_html(raw)
            for m in LOCALE_CALL_RE.finditer(stripped):
                lineno = stripped.count('\n', 0, m.start()) + 1
                findings.append((m.group(1), str(fpath), lineno))
    return findings


def main():
    if not LOCALE_FILE.is_file():
        print(f"::error::{LOCALE_FILE} not found")
        sys.exit(2)
    locale_keys = flatten_locale_keys(json.loads(LOCALE_FILE.read_text()))
    if not locale_keys:
        print("::error::locales/en.json produced zero keys -- ground truth is empty, refusing to run this check (would flag every call site as missing)")
        sys.exit(2)

    call_sites = gather_call_sites()
    used_keys = {k for k, _, _ in call_sites}

    missing = sorted(k for k in used_keys if k not in locale_keys)
    unused = sorted(locale_keys - used_keys)

    status = 0
    if missing:
        status = 1
        print("Locale cross-check FAILED -- these locale() call sites reference a key with no entry in locales/en.json:")
        for k in missing:
            sites = ", ".join(f"{f}:{l}" for kk, f, l in call_sites if kk == k)
            print(f"::error::'{k}' called at {sites} has no matching key in locales/en.json. This is silent at runtime -- ox_lib's locale() returns the raw key string on a miss instead of erroring, so a player would see the literal text \"{k}\" rather than a real message.")
    if unused:
        status = 1
        print("Locale cross-check FAILED -- these locales/en.json keys are never referenced by any locale() call in client/, server/, or html/:")
        for k in unused:
            print(f"::error::'{k}' is defined in locales/en.json but no locale('{k}') call site exists. Either it is dead and safe to remove, or the real call site uses a different/typo'd key -- check the missing-keys list above for a likely match.")

    if status:
        print()
        print("Reproduce locally, one line, from the repo root: python3 .github/scripts/locale_cross_check.py")
        sys.exit(1)

    print(
        f"Locale cross-check passed: {len(locale_keys)} keys in locales/en.json, all {len(used_keys)} referenced by "
        f"at least one of {len(call_sites)} total locale() call site(s) across client/server/html, 0 missing, 0 unused."
    )


if __name__ == "__main__":
    main()
