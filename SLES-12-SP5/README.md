# healthcheck-sles12.sh

Évaluateur de santé **et** outil de diagnostic de lenteur pour **SUSE Linux
Enterprise Server 12 SP5**. Script Bash unique, **100 % en lecture seule**
(strictement non destructif), pensé pour être lancé à la main par un
administrateur — ou en tâche planifiée.

> Emplacement sur la machine : `/usr/local/sbin/healthcheck-sles12.sh`

---

## 1. À quoi ça sert

Deux usages complémentaires :

1. **État de santé** — passe en revue ~15 sous-systèmes (CPU, mémoire, disque,
   réseau, services, noyau, RAID, Btrfs…) et rend un **verdict global**
   `SAIN / AVERTISSEMENT / CRITIQUE`.
2. **Diagnostic de lenteur** — quand « ça rame », identifie le **coupable**
   (processus, I/O, mémoire…) et produit un **diagnostic rédigé** : cause
   probable + **commande concrète** pour confirmer.

---

## 2. Démarrage rapide

```bash
# 1. Vérifier l'intégrité du fichier téléchargé (recommandé) :
sha256sum -c healthcheck-sles12.sh.sha256
#    -> doit afficher : healthcheck-sles12.sh: Réussi (OK)

# 2. Installer sur la machine SLES 12 SP5 :
install -m 0755 healthcheck-sles12.sh /usr/local/sbin/healthcheck-sles12.sh

# 3. Diagnostic immédiat (en root pour la couverture complète) :
healthcheck-sles12.sh
```

### Vérification d'intégrité (SHA-256)
Le fichier `healthcheck-sles12.sh.sha256` contient l'empreinte du script. Avant
de l'exécuter — surtout en root — vérifie qu'il n'a pas été altéré :
```bash
sha256sum -c healthcheck-sles12.sh.sha256
```
Si la sortie indique `Réussi` / `OK`, le script est intact. Sinon, **ne pas
l'exécuter** et le retélécharger depuis la source officielle.

À lancer **en root** pour une couverture complète (SMART, RAID, journal noyau).

---

## Dépendances

> **TL;DR** — le script fonctionne **sans rien installer** sur un SLES 12 SP5
> standard. Tout ce qui est requis est livré de base. Les outils optionnels
> améliorent la couverture ; s'ils manquent, le check concerné affiche `[----]`
> (jamais d'erreur), et la synthèse **suggère** quoi installer.

### Requis (présents par défaut sur SLES 12 SP5)
`bash 4+`, **coreutils** (awk\*, sed\*, grep\*, cat, printf, date, sort, head,
tail, tr, wc, cut, stat, readlink, find, nproc, uname, sleep), **util-linux**
(lsblk, dmesg), **procps** (`vmstat`, `ps`, `free`, `uptime`), **systemd**
(`systemctl`, `journalctl`, `timedatectl`, `systemd-detect-virt`).
*(\* awk/sed/grep = paquets `gawk`/`sed`/`grep`, toujours présents.)*

Aucune action nécessaire : ces composants font partie de toute installation,
même minimale.

### Optionnels (recommandés pour le diagnostic de lenteur)

| Paquet | Apporte | Installer |
|--------|---------|-----------|
| **`sysstat`** | I/O disque par périphérique + par processus, et historique `sar` | `zypper install sysstat` |
| `smartmontools` | santé SMART des disques **physiques** | `zypper install smartmontools` |
| `mdadm` | état du RAID **logiciel** (md) | `zypper install mdadm` |

> `btrfsprogs`, `snapper`, `zypper`, `iproute2` (ip/ss/nstat), `iputils` (ping)
> sont **déjà présents par défaut** sur SLES 12 SP5 — rien à faire.
> `ssacli`/`hpssacli` ne concernent que les serveurs **HP physiques** (RAID Smart
> Array) et viennent du dépôt HP, pas de SUSE.

### Le plus utile : `sysstat`
C'est la seule dépendance qui vaut vraiment l'installation, car elle débloque
**3 fonctions** (I/O par périphérique, top I/O par processus, historique `sar`).
Sans elle, le script tourne et le signale ainsi :
```
  [----] I/O par device : iostat absent (paquet sysstat)
  ...
  Pour un diagnostic plus complet (optionnel) :
    - sysstat : I/O disque par peripherique + par processus, et historique sar
    Installer : zypper install sysstat
```
Pour activer **en plus** l'historique (lenteurs passées) :
```bash
zypper install sysstat
systemctl enable --now sysstat   # démarre la collecte (toutes les 10 min)
```

---

## 3. Les 3 situations typiques

| Situation | Commande |
|-----------|----------|
| « ça rame **maintenant** » | `/usr/local/sbin/healthcheck-sles12.sh` |
| « ça rame **par moments** » | `/usr/local/sbin/healthcheck-sles12.sh -W 600 -i 30` |
| « c'était lent **ce matin** » | lire `/var/log/healthcheck/AAAA-MM-JJ_HHMM.txt` |

### « Maintenant » — photo instantanée
Le verdict tombe en ~10 s. Si problème, la section **« Diagnostic — causes
probables & vérifications »** te donne le coupable et la commande pour creuser.

### « Par moments » — surveillance live
```bash
/usr/local/sbin/healthcheck-sles12.sh -W 600 -i 30
```
Surveille 600 s (une passe toutes les 30 s) et **n'affiche que** les moments où
un seuil est franchi. Idéal pour capturer une lenteur intermittente : on le
lance, on demande à l'utilisateur de reproduire, il capture le pic. `Ctrl-C`
pour arrêter avant la fin.

### « C'était dans le passé » — historique
Un cron écrit un rapport horodaté toutes les 15 min :
```bash
ls -lt /var/log/healthcheck/                       # lister
cat /var/log/healthcheck/2026-05-31_0900.txt       # lire l'heure concernée
```
La collecte `sar` (sysstat) enregistre en plus l'historique CPU/RAM/disque : le
script affiche le « pic CPU » passé dans sa section *Détection avancée*.

---

## 4. Options

```
-w SEC      fenêtre d'échantillonnage CPU/IO (défaut 10 ; 0 = instantané)
-o FICHIER  écrit aussi le rapport dans FICHIER (sans couleur, droits 600)
-n          désactive la couleur (utile pour copier-coller / rediriger)
-v          VERBEUX : valeur mesurée + seuil de chaque check (même OK)
-vv         DEBUG : en plus, montre la source de chaque donnée (commande/fichier)
-W DURÉE    SURVEILLANCE : boucle DURÉE s, n'affiche que les passes WARN/CRIT
-i SEC      intervalle entre passes en mode -W (défaut 30)
-h          aide complète
-V          version
```

### Exemples
```bash
/usr/local/sbin/healthcheck-sles12.sh               # diagnostic ponctuel
/usr/local/sbin/healthcheck-sles12.sh -v            # avec valeurs + seuils
/usr/local/sbin/healthcheck-sles12.sh -w 0          # instantané (pas d'attente de 10 s)
/usr/local/sbin/healthcheck-sles12.sh -o /tmp/rapport.txt   # sauvegarde dans un fichier
```

---

## 5. Lire la sortie

| Étiquette | Sens |
|-----------|------|
| `[ OK ]` | rien à signaler |
| `[WARN]` | à surveiller (n'empêche pas de fonctionner) |
| `[CRIT]` | problème sérieux |
| `[INFO]` | information de contexte |
| `[DIAG]` | élément de diagnostic (coupable, pistes) |
| `[----]` | check non applicable (outil absent / non pertinent en VM) |

**Code de sortie** (`echo $?` juste après) : `0`=sain, `1`=warn, `2`=critique,
`3`=erreur d'usage. Pratique pour chaîner dans un autre script.

---

## 6. Infrastructure « sans supervision » (déjà en place)

### Collecte historique (sysstat / sar)
```bash
systemctl status sysstat        # doit être "active (exited)" / enabled
```
Active la collecte locale toutes les 10 min. Pour la désactiver :
```bash
systemctl disable --now sysstat
```

### Rapports datés automatiques (cron)
Fichier : `/etc/cron.d/healthcheck` — lance le script toutes les 15 min vers
`/var/log/healthcheck/`, avec purge automatique au-delà de 7 jours.
Pour tout retirer :
```bash
rm /etc/cron.d/healthcheck
rm -rf /var/log/healthcheck
```

---

## 7. Reprendre / étendre le script

L'en-tête du script contient une **table des matières** et une section
**« POUR REPRENDRE / ÉTENDRE CE SCRIPT »**. L'essentiel :

- **Verdict** : chaque check appelle `ok()` / `warn()` / `crit()` →
  incrémentent les compteurs → la *Synthèse* en déduit le verdict.
  `info()` / `skip()` / `diag()` sont purement informatifs.
- **Ajouter un check** : ouvrir une section `hdr "Titre"`, puis `ok/warn/crit`
  selon des seuils déclarés en tête (section *Seuils*).
- **Seuils** : tout est centralisé en tête (section « Seuils (modifiables) »).
  **C'est la zone à ajuster par type de machine** (un serveur de base de données
  n'a pas les mêmes normes qu'un serveur web).
- **Robustesse** : `have cmd` teste la présence d'un outil, `TO N cmd…` lui met
  un timeout. Outil absent ⇒ `[----]`, jamais d'erreur fatale.
- **Piège bash** : toujours `while …; done < <(cmd)`, jamais `cmd | while`
  (sous-shell ⇒ compteurs perdus — cf. changelog 2.6.0).

### Qualité
Le script passe **ShellCheck sans aucun avertissement** (`shellcheck -s bash`).
À vérifier après toute modification :
```bash
shellcheck -s bash /usr/local/sbin/healthcheck-sles12.sh && echo OK
```

---

## 8. Limites connues (honnêtes)

- **Snapshot ponctuel** : une passe unique rate les lenteurs intermittentes
  → utiliser `-W` (live) ou les rapports cron / sar (passé).
- **PSI** (`/proc/pressure`), l'indicateur idéal de pression CPU/mém/IO, est
  **absent** du noyau 4.12 de SLES 12 (nécessite ≥ 4.20).
- **Seuils génériques** : ce sont des valeurs raisonnables par défaut, pas des
  vérités universelles. À calibrer sur tes machines après quelques semaines de
  rapports pour éliminer les faux positifs.
- Sortie texte uniquement (pas de JSON/perfdata natif), mais code de sortie
  Nagios exploitable en l'état.

---

## 9. Sécurité

- **Lecture seule** : aucune commande destructive (`rm`, `kill`, `mkfs`, modif
  de service…). Les commandes du diagnostic rédigé sont *suggérées*, jamais
  exécutées.
- **Cible `-o` validée** : refus d'écrire sur un lien symbolique ou un
  non-fichier-régulier (protection contre une substitution malveillante, y
  compris juste avant l'écriture — anti-TOCTOU).
- **Environnement durci** : `PATH` figé, `LC_ALL=C`, `umask 077`, `set -u`.
