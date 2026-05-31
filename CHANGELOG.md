# Changelog

Historique des versions des outils du dépôt. Le détail par version figure aussi
en tête de chaque script (rubrique `CHANGELOG`).

## healthcheck-sles12.sh

### 2.15.0
- Réactivité charge (issu d'un stress-test) : lecture de `load1` (1 min) en plus
  de `load5`. Le verdict reste piloté par `load5` (anti-faux-positif), mais une
  surcharge récente (`load1` élevé, `load5` encore bas) est signalée + alimente
  les pistes. Comble l'angle mort « ça rame maintenant » sur une charge < 5 min.

### 2.14.1
- Audit complet (statique + dynamique + read-only + sécurité) : RAS majeur.
- Correctif : `-I` (inventaire) et `-W` (surveillance) refusés ensemble (exit 3).

### 2.14.0
- Inventaire : bloc « Versions des composants clés » (liste curée, paquets
  réellement installés) — comparaison de machines sans dumper tous les paquets.

### 2.13.0
- Mode inventaire `-I` : décrit la machine (matériel/système/config/services),
  sortie triée et stable, comparable via `diff`. Option `-p` : liste `rpm -qa`.

### 2.12.0
- Suggestion de paquets manquants (ex. `sysstat`) ; le script reste fonctionnel
  sans, et indique quoi installer pour plus d'infos.

### 2.11.0
- Documentation : en-tête, table des matières, guide de reprise, README.

### 2.10.0
- Verbosité `-v`/`-vv` et section « Diagnostic rédigé » (cause + commande).

### 2.9.0
- Mode surveillance `-W` (capture des lenteurs intermittentes, sans supervision).

### 2.8.0
- Détection avancée de lenteur : D-state, hung_task, thrashing, retrans TCP, sar.

### 2.7.0
- Diagnostic de lenteur : top consommateurs CPU/MEM/I/O + corrélation.

### 2.6.x
- Correctif majeur (compteurs sous-shell), section Btrfs, durcissement TOCTOU.

_(Versions antérieures : voir la rubrique CHANGELOG en tête du script.)_
