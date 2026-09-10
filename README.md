<div align="center">

# SysAdmin-Tools

**Comprendre l'état d'un serveur Linux et remonter les pistes d'une lenteur.**

Des outils d'administration organisés par plateforme, avec des rapports
texte à lire dans un terminal ou à comparer entre machines.

[Démarrer](#premier-diagnostic) · [Guide SLES](SLES-12-SP5/README.md) · [Sécurité](SECURITY.md) · [Historique](CHANGELOG.md)

[![ShellCheck](https://github.com/AdrienAvalon/SysAdmin-Tools/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/AdrienAvalon/SysAdmin-Tools/actions/workflows/shellcheck.yml)
[![Bash](https://img.shields.io/badge/Bash-outils-4eaa25)](SLES-12-SP5/healthcheck-sles12.sh)
[![Licence MIT](https://img.shields.io/badge/licence-MIT-8b7cf6)](LICENSE)

</div>

## En bref

Le dépôt fournit actuellement
[`healthcheck-sles12.sh`](SLES-12-SP5/healthcheck-sles12.sh), destiné à
**SUSE Linux Enterprise Server 12 SP5**.

| Besoin | Ce que l'outil apporte |
|---|---|
| **Faire un état des lieux** | CPU, mémoire, swap, espace disque, inodes, services et synchronisation de l'horloge |
| **Comprendre une lenteur** | processus consommateurs, attente disque, pression de swap, retransmissions TCP et pistes de vérification |
| **Examiner le stockage** | I/O, Btrfs, RAID logiciel et Smart Array HP selon les outils disponibles |
| **Capturer un incident intermittent** | mode de surveillance borné, avec affichage des passes en avertissement ou critiques |
| **Comparer deux machines** | inventaire trié du matériel, de la configuration, des services et des versions de paquets |
| **Conserver un constat** | rapport texte sans couleur avec l'option `-o` et code de sortie exploitable par un autre outil |

Le diagnostic consulte le système et suggère des commandes pour approfondir.
Il ne corrige pas automatiquement les problèmes. L'option `-o` écrit
explicitement un rapport ; le script n'installe ni service ni tâche planifiée.

## Premier diagnostic

Sur la machine SLES concernée, avec Git disponible :

```bash
git clone https://github.com/AdrienAvalon/SysAdmin-Tools.git
cd SysAdmin-Tools/SLES-12-SP5
sha256sum -c healthcheck-sles12.sh.sha256
bash healthcheck-sles12.sh -h
sudo bash healthcheck-sles12.sh -v
```

L'empreinte contrôle l'intégrité du fichier par rapport au manifeste fourni.
Elle ne prouve pas à elle seule l'identité de son auteur. La procédure de
vérification et de signalement figure dans [SECURITY.md](SECURITY.md).

Le script attend Bash 4 ou supérieur et les outils usuels de SLES : coreutils,
util-linux, procps et systemd. Les privilèges root donnent accès à davantage
de données, notamment SMART, RAID et journal noyau.

Les outils complémentaires sont détectés : `sysstat` fournit `iostat`,
`pidstat` et `sar` ; les utilitaires SMART, RAID et Btrfs enrichissent les
contrôles correspondants. Leur absence est indiquée dans le rapport. Les
prérequis détaillés sont dans le [guide SLES](SLES-12-SP5/README.md).

## Au quotidien

Depuis le répertoire `SLES-12-SP5` :

```bash
# Voir les valeurs mesurées et les seuils
sudo bash healthcheck-sles12.sh -v

# Surveiller pendant 10 minutes, avec un intervalle de 30 secondes
sudo bash healthcheck-sles12.sh -W 600 -i 30

# Écrire un rapport dans un répertoire privé
mkdir -m 700 rapports
sudo bash healthcheck-sles12.sh -n -o rapports/diagnostic.txt

# Produire un inventaire incluant les versions de tous les paquets
sudo bash healthcheck-sles12.sh -I -p -n -o rapports/inventaire.txt
```

Le mode `-I` produit un inventaire comparable avec `diff`, sans verdict de
santé. Il ne se combine pas avec le mode de surveillance `-W`. Pour étudier un
incident passé, il faut que des rapports ou la collecte `sar` aient déjà été
mis en place : un premier lancement ne recrée pas l'historique manquant.

| Code de sortie | Sens en mode diagnostic |
|---|---|
| `0` | aucun avertissement ni état critique détecté |
| `1` | au moins un avertissement, aucun état critique |
| `2` | au moins un état critique |
| `3` | erreur d'usage ou d'environnement |

## Portée et qualité

Les seuils sont regroupés en tête du script pour être adaptés au rôle de la
machine. Un diagnostic ponctuel peut manquer une lenteur intermittente, et
les outils absents limitent la couverture. Les rapports sont textuels : il
n'existe pas de sortie JSON ou de métriques de performance au format Nagios.

Le [workflow ShellCheck](.github/workflows/shellcheck.yml) analyse les scripts
sur les push et pull requests vers `main`. Pour reproduire ce contrôle local,
sans lancer les vérifications système :

```bash
shellcheck -s bash SLES-12-SP5/healthcheck-sles12.sh
```

Cette analyse statique complète la lecture et les essais sur la plateforme
cible ; elle ne constitue pas une garantie d'absence de défaut.

## Documentation et contributions

- [Guide SLES 12 SP5](SLES-12-SP5/README.md) : options, interprétation des
  rapports, dépendances et pistes d'exploitation.
- [CHANGELOG.md](CHANGELOG.md) : évolutions du diagnostic et de l'inventaire.
- [SECURITY.md](SECURITY.md) : vérification des fichiers et signalement privé.
- [Issues](https://github.com/AdrienAvalon/SysAdmin-Tools/issues) : retours avec
  version, plateforme et rapport expurgé des données propres à votre système.

Pour ajouter un contrôle, conservez les seuils centralisés, les outils
optionnels détectés et la distinction entre mesure, avertissement et piste
de diagnostic. La table des matières et le guide de reprise sont dans
l'en-tête du script.

## Licence

[MIT](LICENSE) — utilisation, modification et redistribution selon les
conditions de la licence, sans garantie.
