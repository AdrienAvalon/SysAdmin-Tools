# Politique de sécurité

## Garanties du projet

Les scripts de ce dépôt sont conçus pour être **sûrs par défaut** :

- **Lecture seule** — `healthcheck-sles12.sh` ne modifie jamais le système :
  aucune commande destructive (`rm`, `kill`, `mkfs`, modification de service,
  écriture de `sysctl`, etc.). La seule écriture possible est le rapport demandé
  explicitement via l'option `-o`, dont la cible est validée (refus des liens
  symboliques et des non-fichiers-réguliers, y compris juste avant l'écriture —
  protection anti-TOCTOU).
- **Environnement durci** — `PATH` figé, `LC_ALL=C`, `umask 077`, `set -u`.
- **Aucun fichier temporaire** — pas de surface d'attaque via `/tmp`.
- **Validé par [ShellCheck](https://www.shellcheck.net/)** sans avertissement
  (vérifié automatiquement à chaque push, voir le badge du README).

## Vérifier ce que vous exécutez

Avant d'exécuter un script — **surtout en root** :

1. **Intégrité** (le fichier n'a pas été corrompu) :
   ```bash
   sha256sum -c healthcheck-sles12.sh.sha256
   ```
2. **Authenticité** (le code vient bien du mainteneur) : les commits de ce dépôt
   sont signés. Sur GitHub, vérifiez la mention **« Verified »** à côté des
   commits. Un commit non signé ou « Unverified » doit être considéré avec
   prudence.
3. **Lisez le script** : il est volontairement commenté (~33 %) et structuré
   (table des matières en tête) pour être auditable.

> ⚠️ Le SHA256 garantit l'**intégrité** (transfert non corrompu), pas
> l'**authenticité**. Pour cette dernière, fiez-vous à la signature des commits.

## Versions supportées

Seule la dernière version publiée (voir le `CHANGELOG` en tête de chaque script)
reçoit des corrections. Le numéro de version est exposé par `-V`.

## Signaler une vulnérabilité

Si vous pensez avoir trouvé un problème de sécurité :

- **Ne créez pas d'issue publique** décrivant l'exploit.
- Ouvrez un **GitHub Security Advisory** (onglet *Security* du dépôt) ou
  contactez le mainteneur en privé.
- Merci d'inclure : la version concernée (`-V`), la plateforme, et les étapes de
  reproduction.

Réponse visée sous quelques jours.
