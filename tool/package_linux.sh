#!/usr/bin/env bash
# Assemble l'archive Linux x64 publiée avec chaque release.
#
#   ./tool/package_linux.sh            # utilise la version du pubspec
#   ./tool/package_linux.sh 0.2.0      # ou une version imposée
#
# Produit `build/sparneo-<version>-linux-x64.tar.gz` : le bundle de release, plus
# l'entrée de menu, les icônes hicolor et les scripts d'intégration au bureau.
# Le build lui-même n'est PAS lancé ici — faites `flutter build linux --release`
# avant, pour que ce script reste une simple mise en boîte.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="$root/build/linux/x64/release/bundle"
packaging="$root/linux/packaging"

version="${1:-}"
if [[ -z "$version" ]]; then
  version="$(sed -n 's/^version: *\([^+]*\).*/\1/p' "$root/pubspec.yaml")"
fi
[[ -n "$version" ]] || { echo "Version indéterminable." >&2; exit 1; }

if [[ ! -x "$bundle/portfolio_tracker" ]]; then
  echo "Bundle de release absent : $bundle" >&2
  echo "Lancez d'abord : flutter build linux --release" >&2
  exit 1
fi

name="sparneo-$version"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

cp -a "$bundle" "$staging/$name"
install -Dm644 "$packaging/fr.sparneo.app.desktop" \
  "$staging/$name/share/applications/fr.sparneo.app.desktop"
cp -a "$packaging/icons" "$staging/$name/share/"
install -Dm755 "$packaging/install.sh"   "$staging/$name/install.sh"
install -Dm755 "$packaging/uninstall.sh" "$staging/$name/uninstall.sh"

out="$root/build/$name-linux-x64.tar.gz"
tar czf "$out" -C "$staging" "$name"
echo "$out"
sha256sum "$out"
