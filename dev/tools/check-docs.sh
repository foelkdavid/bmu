#!/bin/sh
# Compiles the code in the docs, so the documentation can't drift from the API:
#  - docs/COOKBOOK.md: all ```c3 blocks together as one module (+ a main that calls cookbook_example_main)
#  - every other docs/*.md block that starts with "module " (complete programs); blocks of one doc that declare the
#    same module are compiled together. Blocks starting with "// sketch" are fragments and are skipped.
#  - the examples and the template (template via a throwaway copy with a real module name)
# Run from anywhere: dev/tools/check-docs.sh       Exit code 0 = all good.
set -eu
cd "$(dirname "$0")/../.."
out=dev/output/docs-check
rm -rf "$out"; mkdir -p "$out"
fail=0
build() {   # build NAME FILE...
    name=$1; shift
    if c3c compile --libdir lib --lib raylib6 --lib bmu -o "$out/$name" "$@" > "$out/$name.log" 2>&1; then
        echo "ok    $name"
    else
        echo "FAIL  $name   (see $out/$name.log)"; grep -m 5 -B3 "error:" "$out/$name.log" | sed 's/^/        /'; fail=1
    fi
}
python3 - "$out" <<'PY'
import re, sys, glob, os
out = sys.argv[1]
blocks = lambda f: re.findall(r'```c3\n(.*?)```', open(f).read(), re.S)
cook = blocks('docs/COOKBOOK.md')
open(f'{out}/cookbook.c3', 'w').write('\n'.join(cook) + '\nfn void main(String[] args) { cookbook_example_main(args); }\n')
for f in sorted(glob.glob('docs/*.md')):
    if f.endswith('COOKBOOK.md'): continue
    groups = {}
    for b in blocks(f):
        if not b.lstrip().startswith('module '): continue
        groups.setdefault(b.lstrip().split(';')[0].split()[1], []).append(b)
    for mod, bs in groups.items():
        base = f'{out}/{os.path.basename(f)[:-3].lower()}-{mod}'
        for i, b in enumerate(bs): open(f'{base}.{i}.part', 'w').write(b)
s = open('template/src/main.c3').read().replace('APP_MODULE', 'template_check').replace('APP_NAME', 'Template check')
open(f'{out}/template.c3', 'w').write(s)
PY
build cookbook "$out/cookbook.c3"
build template "$out/template.c3"
for g in $(ls "$out"/*.part 2>/dev/null | sed 's/\.[0-9]*\.part$//' | sort -u); do
    i=0; for p in "$g".*.part; do cp "$p" "$g.$i.c3"; i=$((i+1)); done
    build "$(basename "$g")" "$g".*.c3
done
for d in examples/*/; do n=$(basename "$d"); build "example-$n" "$d"main.c3; done
[ "$fail" = 0 ] && echo "ALL DOC CODE BUILDS" || { echo "SOME DOC CODE FAILS"; exit 1; }
