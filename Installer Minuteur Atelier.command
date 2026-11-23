#!/bin/bash
# Installateur 1-clic pour Minuteur Atelier (copie dans /Applications, retire la quarantaine Gatekeeper et lance l'app).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/Minuteur Atelier.app"
dst="/Applications/Minuteur Atelier.app"

if [ ! -d "$src" ]; then
  echo "Erreur : 'Minuteur Atelier.app' est introuvable à côté de cet installateur."
  exit 1
fi

pkill -f MinuteurAtelier 2>/dev/null || true
rm -rf "$dst"
cp -R "$src" "$dst"
xattr -cr "$dst" 2>/dev/null || true
open "$dst"

echo "✅ Minuteur Atelier est installé dans /Applications et lancé !"
sleep 2
