#!/bin/sh
# New bmu app: tools/new-app.sh <folder> ["App Name"]
# Copies template/, adds bmu as a git submodule at <folder>/bmu, builds, commits.
# BMU_URL overrides the submodule source (default: this repo's `origin`, else its local path).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 1 ] || { echo "usage: $0 <folder> [\"App Name\"]"; exit 2; }
dest=$1
name=${2:-$(basename "$dest")}
module=$(basename "$dest" | tr 'A-Z-' 'a-z_' | tr -cd 'a-z0-9_')
case $module in [a-z]*) ;; *) module="app_$module" ;; esac
[ -e "$dest" ] && { echo "$dest already exists"; exit 1; }
url=${BMU_URL:-$(git -C "$here" remote get-url origin 2>/dev/null || echo "$here")}
mkdir -p "$dest"
cp -r "$here/template/." "$dest/"
for f in "$dest/src/main.c3" "$dest/project.json" "$dest/README.md" "$dest/AGENTS.md"; do
    sed -i "s/APP_MODULE/$module/g; s/APP_NAME/$name/g" "$f"
done
cd "$dest"
git init -q
printf 'build/\n*.tmp\n' > .gitignore
git -c protocol.file.allow=always submodule add -q "$url" bmu
c3c build
git add -A
git commit -qm "New bmu app: $name"
echo "created $dest  ->  cd $dest && ./build/$module"
