#!/usr/bin/env bash
# Kopiuje źródła Nim (<root>/src, <root>/include) do
# <root>/fasttree-sys/vendor/{src,include}, żeby `cargo package`/
# `cargo publish` mogło zapakować crate `fasttree-sys` razem ze źródłami
# Nim, od których zależy jego build.rs (Cargo pakuje tylko zawartość
# katalogu crate'a, więc ../src i ../include normalnie nie trafiają do
# tarballa).
#
# Użycie:
#   ./scripts/vendor-nim-src.sh
#   cargo publish --dry-run -p fasttree-sys
#
# build.rs w fasttree-sys automatycznie wykrywa katalog vendor/ i
# preferuje go nad ../src, ../include, jeśli istnieje.

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sys_dir="$root_dir/fasttree-sys"
vendor_dir="$sys_dir/vendor"

echo "==> Czyszczę $vendor_dir"
rm -rf "$vendor_dir"
mkdir -p "$vendor_dir"

echo "==> Kopiuję $root_dir/src -> $vendor_dir/src"
cp -R "$root_dir/src" "$vendor_dir/src"

echo "==> Kopiuję $root_dir/include -> $vendor_dir/include"
cp -R "$root_dir/include" "$vendor_dir/include"

echo "==> Gotowe. Zawartość $vendor_dir:"
find "$vendor_dir" -maxdepth 2 -mindepth 1 | sort
