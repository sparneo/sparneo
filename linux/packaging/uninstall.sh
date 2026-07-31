#!/usr/bin/env bash
# Retire l'entrée de menu et les icônes posées par install.sh.
#
# NE TOUCHE NI au dossier de l'application, NI à vos données
# (~/.local/share/fr.sparneo.app/ — base SQLite et préférences), qui se
# suppriment à la main si vous le souhaitez vraiment.
set -euo pipefail

app_id='fr.sparneo.app'
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"

rm -f "$data_home/applications/$app_id.desktop"
for size in 48x48 128x128 256x256 512x512; do
  rm -f "$data_home/icons/hicolor/$size/apps/$app_id.png"
done

command -v update-desktop-database >/dev/null 2>&1 &&
  update-desktop-database "$data_home/applications" >/dev/null 2>&1 || true
command -v gtk-update-icon-cache >/dev/null 2>&1 &&
  gtk-update-icon-cache -qtf "$data_home/icons/hicolor" >/dev/null 2>&1 || true

echo "Entrée de menu et icônes retirées."
echo "Vos données restent dans $data_home/$app_id/ — à supprimer à la main si voulu."
