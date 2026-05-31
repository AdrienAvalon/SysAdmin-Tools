# SysAdmin-Tools

[![ShellCheck](https://github.com/AdrienAvalon/SysAdmin-Tools/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/AdrienAvalon/SysAdmin-Tools/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Collection d'outils d'administration système, organisés par plateforme.
Tous les scripts sont pensés pour être **sûrs** (lecture seule sauf mention
contraire), **portables**, **commentés** et validés par
[ShellCheck](https://www.shellcheck.net/).

> 🔒 Sécurité : voir [SECURITY.md](SECURITY.md). Avant d'exécuter un script,
> vérifier son intégrité (`sha256sum -c …`) et l'authenticité des commits
> (badge **Verified** sur GitHub).

## Contenu

| Dossier | Outil | Description |
|---------|-------|-------------|
| [`SLES-12-SP5/`](SLES-12-SP5/) | `healthcheck-sles12.sh` | Évaluateur de santé & diagnostic de lenteur pour SUSE Linux Enterprise Server 12 SP5 (100 % lecture seule). |

## Vérification d'intégrité

Chaque script est accompagné d'un fichier `.sha256`. Avant d'exécuter un script
(surtout en root), vérifie son empreinte :

```bash
sha256sum -c <script>.sha256   # doit afficher "Réussi" / "OK"
```

## Licence

[MIT](LICENSE) — utilisation libre, sans garantie.
