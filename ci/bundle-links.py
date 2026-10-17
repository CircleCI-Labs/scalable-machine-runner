#!/usr/bin/env python3
"""bundle-links.py: keep the relative links of the release bundle alive (docs/releasing.md, "What a release contains").

    ci/bundle-links.py --repo OWNER/NAME --tag vX.Y.Z --out DIR [--extra FILE ...] -- PATHSPEC...

PATHSPEC... is what `git archive` puts in the bundle (the same arguments, with their :(exclude) magic). The bundle leaves out the pages and the
directories that are for maintainers (docs/ci.md, docs/releasing.md, the tests, ci/, ...), but the pages that it ships link to them. For every Markdown
file of the bundle, a relative link to a tracked file that is NOT in the bundle becomes a link to that file at the tag on GitHub:

    ](ci.md#pinned-versions)  ->  ](https://github.com/OWNER/NAME/blob/vX.Y.Z/docs/ci.md#pinned-versions)

Only the files that change are written, under DIR, with their path from the repository root, and their paths are printed, one per line, for the caller
to add to the archive in place of the originals. --extra names files that the bundle gets from elsewhere (VERSION, the generated CHANGELOG.md): a link
to them is kept. A relative link to a path that is neither in the bundle nor tracked is dead in the source too: the script prints it and exits 1.
Links in fenced code blocks, absolute links, mailto: and #anchors are left alone.
"""
import argparse
import os
import posixpath
import re
import subprocess
import sys

INLINE = re.compile(r'(\]\()(<?)([^)\s>]+)(>?)((?:\s+"[^"]*")?\))')
REFERENCE = re.compile(r'^(\s{0,3}\[[^\]]+\]:\s*)(<?)(\S+?)(>?)(\s.*)?$')
SCHEME = re.compile(r'^([a-zA-Z][a-zA-Z0-9+.-]*:|//)')


def git_files(*args):
    out = subprocess.run(['git', 'ls-files', '-z', *args], check=True, capture_output=True).stdout
    return [p for p in out.decode().split('\0') if p]


def ancestors(paths):
    """Every directory above the paths, as a path from the root ('' is the root and not a link target)."""
    out = set()
    for p in paths:
        d = posixpath.dirname(p)
        while d and d not in out:
            out.add(d)
            d = posixpath.dirname(d)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--repo', required=True)
    ap.add_argument('--tag', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--extra', action='append', default=[])
    ap.add_argument('pathspec', nargs='+')
    a = ap.parse_args()

    tracked = set(git_files())
    shipped = set(git_files('--', *a.pathspec))   # the tracked files that the bundle holds, as they are in the repository
    bundle = shipped | set(a.extra)
    dirs_tracked = ancestors(tracked)
    dirs_bundle = ancestors(bundle)
    problems = []
    changed = []

    def fix(src, target):
        """The target, rewritten when it names a tracked file that the bundle leaves out; None when it stays."""
        if not target or target.startswith('#') or SCHEME.match(target):
            return None
        path, frag = re.match(r'^([^#?]*)([#?].*)?$', target).groups()
        frag = frag or ''
        if not path:
            return None
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(src), path))
        is_dir = path.endswith('/') or resolved in dirs_tracked or resolved == '.'
        if resolved in bundle or (is_dir and (resolved in dirs_bundle or resolved == '.')):
            return None
        if resolved in tracked:
            return 'https://github.com/%s/blob/%s/%s%s' % (a.repo, a.tag, resolved, frag)
        if is_dir and resolved in dirs_tracked:
            return 'https://github.com/%s/tree/%s/%s%s%s' % (a.repo, a.tag, resolved, '/' if path.endswith('/') else '', frag)
        problems.append('%s: the link %s names %s, which is neither in the bundle nor tracked' % (src, target, resolved))
        return None

    for src in sorted(p for p in shipped if p.endswith('.md')):
        text = subprocess.run(['git', 'show', 'HEAD:' + src], check=True, capture_output=True).stdout.decode()
        lines = text.split('\n')
        fenced = False
        for i, line in enumerate(lines):
            if re.match(r'^\s*(```|~~~)', line):
                fenced = not fenced
                continue
            if fenced:
                continue

            def inline(m):
                new = fix(src, m.group(3))
                return m.group(0) if new is None else m.group(1) + m.group(2) + new + m.group(4) + m.group(5)

            line = INLINE.sub(inline, line)
            m = REFERENCE.match(line)
            if m:
                new = fix(src, m.group(3))
                if new is not None:
                    line = m.group(1) + m.group(2) + new + m.group(4) + (m.group(5) or '')
            lines[i] = line
        result = '\n'.join(lines)
        if result != text:
            dest = os.path.join(a.out, src)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, 'w', newline='') as f:
                f.write(result)
            changed.append(src)

    for p in problems:
        print('bundle-links: ' + p, file=sys.stderr)
    for p in changed:
        print(p)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
