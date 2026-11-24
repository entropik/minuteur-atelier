# Minuteur Atelier

Panneau flottant macOS ultra-léger en AppKit natif (zéro dépendance externe) combinant **Minuteur**, **Chrono** et **Tomate** (méthode Pomodoro stricte), avec journalisation automatique des sessions en CSV.

Toujours au premier plan, sur tous les espaces, sans icône dans le Dock, compatible **Apple Silicon & Intel** (macOS 14+).

## Installation rapide

### Via Homebrew (1 commande, retire automatiquement la quarantaine macOS)

```sh
brew install --cask --no-quarantine entropik/minuteur-atelier/minuteur-atelier
```

### Ou par téléchargement direct (`.zip`)

1. Télécharger **`Minuteur-Atelier-v1.0.1-macOS-universal.zip`** depuis la [page des Releases](https://github.com/entropik/minuteur-atelier/releases/latest).
2. Double-cliquer sur **`Installer Minuteur Atelier.command`** (inclus dans le dossier décompressé) : il copie l'application dans `/Applications`, retire l'alerte Gatekeeper (`xattr -cr`) et lance le minuteur.

## Compiler depuis les sources

Aucun Xcode complet requis — les *Command Line Tools* (`swiftc`) suffisent :

```sh
./build.sh
```

Compile un binaire universel (`arm64` + `x86_64`), génère le bundle signé ad hoc avec son icône `AppIcon.icns` et l'installe dans `~/Applications/Minuteur Atelier.app`.

## Fonctionnalités

- **Affichage `H:MM:SS`** centré au pixel près, avec option **`ms`** (`.000` rafraîchi à 60 Hz) mémorisée.
- **3 compteurs indépendants et persistants en parallèle** : lancez une Tomate de 25 min, basculez sur Chrono ou Minuteur pour mesurer autre chose à côté — votre Tomate continue en arrière-plan et l'état des 3 modes survit même à la fermeture de l'app.
- **Mode Minuteur** :
  - Préréglages `1`, `5`, `10`, `25` min + réglage libre à la **molette / trackpad** directement sur les chiffres (`±1 min`, ou `±5 s` avec `Option ⌥`).
  - Clic sur les chiffres pour mettre en pause / reprendre.
- **Mode Chrono** :
  - Chronomètre montant avec clic sur les chiffres pour pause / reprise.
- **Mode Tomate (Pomodoro strict)** :
  - Cycle : **25 min de travail** (fond teinté rouge léger) → **pause 5 min** automatique (fond neutre) → retour à `00:25:00` à l'arrêt en attente de votre clic `▶︎`.
  - Après 4 Tomates (témoin visuel **`● ● ○ ○`** en bas) : **pause longue de 15 min**.
  - **Indivisible** : pas de pause possible pendant une Tomate (seul `↺` permet d'annuler la Tomate en cours et de repartir à `25:00`).
  - Champ éditable **`Séance…`** en bas à droite pour nommer la tâche en cours et la retrouver dans l'export CSV.
- **Barre de menus `⏱`** :
  - Affiche le temps en direct (`⏱ 18:42`) quand le panneau est masqué ou qu'une Tomate tourne en arrière-plan.
  - Affiche le bilan du jour en tête de menu (`Aujourd'hui : X tomates · YhZZ`) et un bouton **« Copier le résumé du jour »** (`⌘C`).
  - Carillon macOS (`Glass`) + notification native à chaque fin de compte à rebours ou transition Pomodoro.

## Relevés CSV

Chaque session terminée est inscrite dans `~/Library/Application Support/MinuteurAtelier/sessions.csv` :

```csv
fin,mode,duree_s,tache
2026-11-23T14:48:03Z,tomate,1500.0,Refonte grille tarifaire
```

Accessible à tout moment depuis l'icône `⏱` → **« Ouvrir les relevés »**.

## Licence

Copyright © 2026 **ooblik**. Distribué sous licence libre **[GNU GPLv3](./LICENSE)**.
