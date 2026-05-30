#!/usr/bin/env python3
"""
Unwrap hard-wrapped prose paragraphs in .tex files.
Each prose paragraph (and each table row, and each \item) becomes one line.
Preserves: comments, blank lines, \section/\begin/\end/\toprule etc.,
           math display, and table-row \\ boundaries.
"""
import re, sys
from pathlib import Path

PURE_CMD_RE = re.compile(
    r'\\(begin|end|section|subsection|subsubsection|subparagraph|'
    r'caption|label|input|include|bibliographystyle|bibliography|'
    r'toprule|midrule|bottomrule|rowcolor|rowcolors|headrow|'
    r'usepackage|newcommand|renewcommand|definecolor|'
    r'hline|cmidrule|addlinespace|cline|multicolumn|'
    r'pagenumbering|tableofcontents|listoffigures|listoftables|'
    r'newpage|appendix|maketitle|noindent|fbox|parbox|centering|'
    r'PassOptionsToPackage|DeclareGraphics|setlist|usetikzlibrary|'
    r'AddToShipoutPictureBG|NorthwesternWatermark|includegraphics|'
    r'cfoot|lhead|fancyhf|pagestyle|setcounter|vfill|vspace|hspace|'
    r'\[|\])\b'
)

BOUNDARY_RE = re.compile(r'\\(item|paragraph)\b')
ROW_END_RE  = re.compile(r'\\\\(\[[^\]]*\])?\s*$')


def strip_eol_comment(line):
    """Strip trailing % comment from a line (unescaped %).
    A mid-line % swallows the newline + comment text in LaTeX, so once we
    join the line into a single source line, that comment text would eat
    everything after it on the joined line. Drop it before joining."""
    pos = 0
    while pos < len(line):
        idx = line.find('%', pos)
        if idx < 0:
            return line
        if idx > 0 and line[idx - 1] == '\\':
            pos = idx + 1
            continue
        return line[:idx].rstrip()
    return line


def is_pure_cmd(line):
    s = line.lstrip()
    if not s: return True
    if s.startswith('%'): return True
    if s in ('\\[', '\\]', '{', '}'): return True
    if PURE_CMD_RE.match(s): return True
    return False


def is_boundary(line):
    return BOUNDARY_RE.match(line.lstrip()) is not None


def brace_balance(s):
    """Net unmatched braces and brackets, ignoring \\\\ line breaks,
    \\\\[Xpt] spacers, and escaped \\{ \\} \\[ \\]"""
    # Strip \\ and \\[Xpt] sequences first so their brackets don't count
    t = re.sub(r'\\\\(\[[^\]]*\])?', '', s)
    # Strip escaped \{ \} \[ \]
    t = re.sub(r'\\[\{\}\[\]]', '', t)
    return (t.count('{') - t.count('}'),
            t.count('[') - t.count(']'))


def process(text):
    lines = text.split('\n')
    out, buf = [], []
    cont = None  # accumulating a multi-line LaTeX command

    def flush():
        if buf:
            out.append(' '.join(x.strip() for x in buf))
            buf.clear()

    for line in lines:
        s = line.rstrip()

        if cont is not None:
            cont += ' ' + s.strip()
            br, bk = brace_balance(cont)
            if br == 0 and bk == 0:
                out.append(cont)
                cont = None
            continue

        if s.strip() == '':
            flush(); out.append(''); continue

        if is_pure_cmd(s):
            flush()
            br, bk = brace_balance(s)
            if br != 0 or bk != 0:
                cont = s
            else:
                out.append(line)
            continue

        if is_boundary(s):
            flush()
            buf.append(strip_eol_comment(line))
            continue

        if ROW_END_RE.search(s):
            buf.append(line)
            flush()
        else:
            buf.append(strip_eol_comment(line))

    if cont is not None:
        out.append(cont)
    flush()
    # Collapse 3+ blank lines into 2
    text = '\n'.join(out)
    text = re.sub(r'\n{3,}', '\n\n', text)
    if not text.endswith('\n'):
        text += '\n'
    return text


def main():
    for path_str in sys.argv[1:]:
        p = Path(path_str)
        original = p.read_text()
        new = process(original)
        p.write_text(new)
        print(f"  {p.name}: {len(original.splitlines())} -> {len(new.splitlines())} lines")


if __name__ == '__main__':
    main()
