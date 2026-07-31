#!/usr/bin/env bash
# Intègre Sparneo au menu d'applications du bureau, pour l'utilisateur courant.
#
# L'archive est portable : elle s'extrait où l'on veut. L'entrée de menu doit donc
# pointer vers le binaire par son chemin ABSOLU, calculé ici — le fichier
# `fr.sparneo.app.desktop` du dépôt porte un `Exec=` relatif, valable pour un
# paquet système où le binaire est sur le PATH, pas pour une archive déplaçable.
#
# Rien n'est écrit hors de ~/.local/share. Désinstallation : ./uninstall.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
binary="$here/portfolio_tracker"
app_id='fr.sparneo.app'
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"

if [[ ! -x "$binary" ]]; then
  echo "Binaire introuvable : $binary" >&2
  echo "Lancez ce script depuis le dossier extrait de l'archive." >&2
  exit 1
fi

install -d "$data_home/applications"
# `Exec=` reçoit le chemin absolu ; le binaire est échappé pour survivre à un
# dossier d'extraction contenant des espaces.
sed "s|^Exec=.*|Exec=\"$binary\"|" "$here/share/applications/$app_id.desktop" \
  > "$data_home/applications/$app_id.desktop"

for size in 48x48 128x128 256x256 512x512; do
  icon="$here/share/icons/hicolor/$size/apps/$app_id.png"
  [[ -f "$icon" ]] || continue
  install -Dm644 "$icon" "$data_home/icons/hicolor/$size/apps/$app_id.png"
done

# Caches facultatifs : leur absence n'empêche rien, le bureau finit par relire.
command -v update-desktop-database >/dev/null 2>&1 &&
  update-desktop-database "$data_home/applications" >/dev/null 2>&1 || true
command -v gtk-update-icon-cache >/dev/null 2>&1 &&
  gtk-update-icon-cache -qtf "$data_home/icons/hicolor" >/dev/null 2>&1 || true

echo "Sparneo est installé dans votre menu d'applications."
echo "Le binaire reste ici : $binary — ne déplacez pas ce dossier sans relancer ce script."
