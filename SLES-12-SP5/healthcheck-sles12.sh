#!/usr/bin/env bash
#===============================================================================
# healthcheck-sles12.sh - Evaluateur de sante & outil de diagnostic de lenteur
#                         pour SUSE Linux Enterprise Server 12 SP5.
#
# Version  : voir la constante VERSION plus bas (source unique de verite).
#            Le CHANGELOG ci-dessous retrace l'historique des versions.
# Licence  : MIT (a adapter a votre contexte)
#
# OBJET
#   Deux usages complementaires, 100% en lecture seule :
#   1) ETAT DE SANTE : applique des seuils par sous-systeme et rend un verdict
#      global OK / WARN / CRIT (utilisable en cron, code de sortie type Nagios).
#   2) DIAGNOSTIC DE LENTEUR : quand "ca rame", identifie le COUPABLE (top
#      processus CPU/MEM/IO, D-state, thrashing, retrans TCP...) et rend un
#      "Diagnostic redige" : cause probable + commande concrete pour confirmer.
#
# GARANTIE READ-ONLY
#   Strictement NON DESTRUCTIF. Le script ne fait que LIRE l'etat du systeme.
#   Aucun service demarre/arrete, aucun parametre noyau modifie, aucun fichier
#   systeme touche. La SEULE ecriture possible est le rapport demande via -o.
#   (Les commandes du "Diagnostic redige" sont SUGGEREES, jamais executees.)
#
# CODES DE SORTIE  (convention Nagios)
#   0 = SAIN          (aucun WARN ni CRIT)
#   1 = AVERTISSEMENT (au moins un WARN, aucun CRIT)
#   2 = CRITIQUE      (au moins un CRIT)
#   3 = ERREUR D'USAGE / d'environnement (argument invalide, cible -o refusee)
#
# DEPENDANCES
#   Requis    : bash 4+, coreutils, util-linux, procps (vmstat), systemd.
#   Optionnels: sysstat (iostat/pidstat/sar), smartmontools (smartctl), zypper,
#               lsblk, btrfs-progs, snapper, ssacli/hpssacli (RAID HP), mdadm.
#               Tout outil absent => check marque [----], jamais d'echec.
#
# USAGE (resume ; '-h' affiche l'aide complete et a jour)
#   ./healthcheck-sles12.sh [-w SEC] [-o FICHIER] [-n] [-v|-vv] [-W DUREE] [-i SEC]
#     -w SEC     fenetre d'echantillonnage CPU/IO (defaut 10 ; 0 = instantane)
#     -o FICHIER ecrit aussi le rapport dans FICHIER (umask 077, sans couleur)
#     -n         desactive la couleur
#     -v         verbeux : valeur mesuree + seuil de chaque check (-vv : + sources)
#     -W DUREE   surveillance : boucle DUREE s, n'affiche que les passes WARN/CRIT
#     -i SEC     intervalle entre passes en mode -W (defaut 30)
#     -h / -V    aide / version
#   A lancer en root pour la couverture complete (SMART, RAID, journal noyau).
#   NOTE : avec -w 10, le script dure ~10 s (echantillonnage soutenu, voulu).
#   Doc detaillee + exemples : voir le README.md fourni a cote du script.
#
# ----------------------------------------------------------------------------
# TABLE DES MATIERES (rechercher "=== N." pour sauter a une section)
#   Pre.  Seuils, parsing des arguments, mode -W, helpers (emit/ok/warn/metric)
#   Pre.  Detection virtualisation + lecture unique du journal noyau (KLOG)
#   Pre.  Echantillonnage CPU/IO (vmstat : iowait, steal, si/so)
#    1. Charge & CPU            7. Reseau (+ latence/debit)  13. Top consommateurs
#    2. Memoire & swap          8. Services & paquets        14. Detection avancee
#    3. Disque espace/inodes    9. Horloge (NTP)             15. Diagnostic redige
#    4. Disque I/O             10. Noyau & materiel          Synthese + verdict
#    5. Integrite FS (RO)      11. Limites & processus
#    5b. Btrfs (SLES)          12. Maintenance / reboot
#    6. RAID
#
# POUR REPRENDRE / ETENDRE CE SCRIPT (l'essentiel en 6 points)
#   a) FLUX DU VERDICT : chaque check appelle ok()/warn()/crit() qui incrementent
#      N_OK/N_WARN/N_CRIT. La Synthese finale en deduit le verdict + code de sortie.
#      info()/skip()/diag() sont PUREMENT informatifs (n'affectent pas le verdict).
#   b) AJOUTER UN CHECK : ouvrir une section avec hdr "Titre", puis appeler
#      ok/warn/crit selon des seuils declares en tete (section "Seuils"). En option
#      metric "nom" "valeur" "$SEUIL_W" "$SEUIL_C" pour l'affichage verbeux (-v).
#   c) SEUILS : tout est centralise dans la section "Seuils (modifiables)" en tete
#      -> c'est LA zone a ajuster par machine (un serveur DB != un serveur web).
#   d) ROBUSTESSE : 'have cmd' teste la presence d'un outil ; 'TO N cmd...' lui
#      met un timeout. Outil absent => skip "[----]", jamais une erreur fatale.
#   e) BOUCLES & COMPTEURS : toujours 'while ...; done < <(cmd)' (process
#      substitution), JAMAIS 'cmd | while' (sous-shell -> compteurs perdus, cf.
#      changelog 2.6.0). Piege bash classique.
#   f) LENTEUR -> CAUSE : un symptome (load/iowait/swap...) appelle add_hint()
#      (pistes) et add_reco() (diagnostic redige). Les deux relisent les memes
#      variables globales (WA, ST, PA, DCOUNT...) calculees dans les sections.
#
# LIMITES CONNUES (assumees)
#   - Sortie texte uniquement (pas de JSON/perfdata natif Nagios/Zabbix). Le code
#     de sortie suit la convention Nagios, exploitable tel quel en supervision.
#   - SNAPSHOT ponctuel : une passe unique rate les lenteurs intermittentes/passees.
#     Parades fournies : -W (live) et collecte sar + cron de rapports datés (README).
#   - PSI (/proc/pressure), l'indicateur ideal de pression CPU/mem/IO, est ABSENT
#     du noyau 4.12 de SLES 12 (necessite >= 4.20). Non utilisable ici.
#   - %util disque peu fiable sur RAID/SSD (parallelisme) -> on privilegie la
#     latence (await, ou max(r_await,w_await) selon la version de sysstat).
#
# CHANGELOG
#   2.11.0 - DOCUMENTATION / REPRISE : en-tete remis a jour (version, usage, et
#           limites etaient obsoletes) ; ajout d'une TABLE DES MATIERES et d'un
#           guide "POUR REPRENDRE / ETENDRE CE SCRIPT" (flux du verdict, ajout
#           d'un check, seuils, pieges bash). Fourniture d'un README.md a cote du
#           script. Aucun changement de comportement (doc uniquement).
#   2.10.0 - VERBOSITE & DIAGNOSTIC REDIGE (aide a la comprehension) :
#           * -v : pour chaque check, affiche la valeur mesuree ET le seuil (meme
#             OK) -> on voit ce qui APPROCHE d'une alerte. -vv : ajoute les
#             sources de donnees (commande/fichier) pour tracer/deboguer.
#           * Nouvelle section "Diagnostic - causes probables & verifications" :
#             pour chaque symptome, une phrase en langage clair + la COMMANDE
#             concrete pour confirmer/creuser (interactive, jamais lancee ici).
#           Verbosite et diagnostic n'affectent ni compteurs ni verdict ; le mode
#           normal reste concis. 100% read-only.
#   2.9.0 - SANS SUPERVISION : mode SURVEILLANCE pour capturer les lenteurs
#           INTERMITTENTES sans serveur externe.
#           * -W DUREE : relance le script en boucle pendant DUREE secondes et
#             n'affiche QUE les passes avec WARN/CRIT (capture le pic en direct).
#           * -i SECONDES : intervalle entre passes (defaut 30).
#           Le code de sortie reflete le pire etat rencontre. Reste read-only
#           (le mode ne fait que relancer l'outil lui-meme).
#           Cf. aussi la doc d'usage cron (rapports horodatants -o) dans -h.
#   2.8.0 - DETECTION AVANCEE DE LENTEUR (section 14), signaux fins souvent
#           invisibles d'un simple "top" :
#           * D-state : processus bloques en I/O (uninterruptible sleep) + motifs
#             'task blocked >Ns' / soft lockup / rcu stall du journal noyau.
#           * Thrashing memoire : taux de defauts de page MAJEURS (delta
#             pgmajfault /proc/vmstat) = lecture disque forcee, cause de lenteur.
#           * Retransmissions TCP (/proc/net/snmp) : pertes reseau reelles,
#             invisibles au ping (lenteur des appli distantes).
#           * Historique sar : repond a "c'etait lent il y a 2h" ; si la collecte
#             sysstat est inactive, l'indique (sans l'activer : hors read-only).
#           Tout reste READ-ONLY. PSI (/proc/pressure) non utilise : absent du
#           noyau 4.12 de SLES 12 (>=4.20 requis).
#   2.7.0 - DIAGNOSTIC DE LENTEUR (nouvel usage : "un utilisateur se plaint que
#           ca rame, je lance le script"). Les sections 1-12 disent S'IL Y A un
#           probleme ; la nouvelle section 13 dit QUI le cause :
#           * Top N processus par CPU et par memoire (ps).
#           * Top N processus par I/O disque (pidstat).
#           * Correlation symptome->cause : chaque signe de lenteur (charge,
#             iowait, steal, RAM faible, swap actif) est relie au processus
#             suspect dans une rubrique "Pistes probables" en synthese.
#           * Reseau : latence vers la passerelle + debit instantane par
#             interface (lenteurs percues qui sont en fait du reseau).
#           Tout reste READ-ONLY (ps, /proc, pidstat, ping). Les lignes [DIAG]
#           n'affectent NI les compteurs NI le verdict (pilote par les seuils).
#   2.6.1 - Durcissement securite : flush_report() re-verifie juste avant
#           d'ecrire que la cible -o n'est pas devenue un lien symbolique / un
#           non-fichier-regulier depuis la validation initiale (fermeture d'une
#           fenetre TOCTOU). ShellCheck 0.11 : propre (0 avertissement).
#   2.6.0 - CORRECTIF IMPORTANT : les sections disque/inodes/I/O utilisaient
#           'commande | while', placant la boucle dans un SOUS-SHELL -> les
#           compteurs N_OK/N_WARN/N_CRIT y etaient PERDUS et un disque plein
#           pouvait s'afficher [CRIT] sans faire basculer le verdict global.
#           Remplace par 'while ...; done < <(commande)' (process substitution).
#         - Nouvelle section Btrfs (specifique SLES) : risque ENOSPC metadonnees
#           (croise metadata% ET espace non-alloue, pas de faux positif), erreurs
#           'btrfs device stats' (corruption -> CRIT), nb de snapshots snapper.
#         - Rapport -o : ecriture unique en fin (buffer memoire) au lieu d'un fork
#           sed + ouverture de fichier par ligne. Plus rapide.
#         - Message horloge actionnable : indique le service NTP actif et
#           distingue 'aucun service' de 'actif mais pas encore cale'.
#   2.5.0 - Section I/O : abandon de 'iostat -dxz' (-z masquait les devices au
#           repos -> section VIDE sur machine peu active, faux-negatif) au profit
#           de 'iostat -dx' avec un [INFO] explicite si aucune activite mesurable.
#         - Le rapport ecrit via -o est desormais SANS couleur (les codes ANSI
#           polluaient le fichier, le rendant inexploitable en parsing/mail).
#           Colonnes vmstat resolues par en-tete (wa/st/si/so) au lieu d'indices
#           figes (robuste face a la colonne 'gu' des procps recents). Journal
#           noyau : fallback ameliore (journalctl -k sans --since si la fenetre
#           --since echoue, avant de basculer sur dmesg). zypper needs-rebooting :
#           on distingue le code 102 (reboot requis) d'une vraie erreur/timeout
#           (plus de faux "Reboot requis").
#   2.4.0 - Liste SERVICES_TOLERES (en tete) : un service non bloquant en echec
#           (kdump par defaut) genere un WARN au lieu d'un CRIT et ne fait plus
#           basculer le verdict global en CRITIQUE. Politique modifiable sans
#           toucher a la logique.
#   2.3.0 - Corrige des faux positifs vus en test sur VM SLES 12 SP5 fraiche :
#           motif MCE resserre (n'attrape plus les messages d'init type "mce: CPU
#           supports N banks") ; deduplication des sous-volumes btrfs par device
#           (20+ lignes identiques -> 1 par volume). Sortie 'exit' blindee contre
#           une corruption de transfert (concatenation parasite en fin de fichier).
#   2.2.0 - Prise en charge VM et conteneur (detection systemd-detect-virt). En
#           CONTENEUR, les checks refletant l'hote (journal noyau, RAID, SMART,
#           conntrack, file-nr, reboot) sont neutralises et load/mem signalees
#           host-wide. En VM, messages RAID/SMART adaptes (pas de materiel
#           physique) et steal CPU mis en avant comme indicateur de contention.
#   2.1.0 - Echantillonnage CPU/IO soutenu sur fenetre -w (au lieu d'1 s) ; check
#           swap base sur l'ACTIVITE si/so (et non l'occupation statique, signal
#           faible) ; checks OOM/MCE/I-O bornes dans le temps (--since) ;
#           ajout sante RAID (md via /proc/mdstat + HP Smart Array ssacli) ;
#           timeouts sur les appels susceptibles de pendre (zypper, smartctl,
#           journalctl, ssacli) ; iostat gere await ET r_await/w_await.
#   2.0.0 - Durcissement securite (PATH fige, LC_ALL=C, umask 077, validation
#           cible -o), bascule dmesg->journalctl, ShellCheck propre, getopts.
#   1.0.0 - Version initiale (evaluateur a seuils).
#===============================================================================

# 'set -u' : variable non definie = erreur (filet de securite).
# 'set -e' VOLONTAIREMENT ABSENT : un check qui echoue ne doit pas interrompre
# le diagnostic ; chaque section gere ses erreurs et continue.
set -u

#------------------------------------------------------------------------------
# Durcissement de l'environnement
#------------------------------------------------------------------------------
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"   # anti-detournement de binaire (root)
export LC_ALL=C LANG=C                         # parsing deterministe (libelles EN)
umask 077                                       # rapport lisible par le seul proprietaire

readonly VERSION="2.11.0"
readonly PROGNAME="${0##*/}"

#============================ Seuils (modifiables) ============================
LOAD_WARN_PER_CORE=1.0      # load5 / nb coeurs (1.0 = saturation)
LOAD_CRIT_PER_CORE=2.0
IOWAIT_WARN=20             # % iowait MOYEN sur la fenetre -w
IOWAIT_CRIT=40
STEAL_WARN=5               # % steal MOYEN sur la fenetre -w (VM)
STEAL_CRIT=15
MEM_AVAIL_WARN=15          # % memoire disponible (sous le seuil = WARN)
MEM_AVAIL_CRIT=5
SWAP_ACT_WARN=512          # activite swap si+so soutenue, en KiB/s
SWAP_ACT_CRIT=4096
DISK_WARN=85               # % remplissage FS
DISK_CRIT=95
INODE_WARN=85             # % inodes
INODE_CRIT=95
BTRFS_META_WARN=80        # % metadonnees btrfs utilisees (Used/Size du bloc Metadata)
BTRFS_META_CRIT=95        # CRIT seulement si l'espace NON-alloue est aussi epuise
BTRFS_UNALLOC_WARN=10     # % d'espace device non-alloue SOUS lequel on s'inquiete
BTRFS_SNAP_WARN=50        # nb de snapshots snapper (au-dela = menage a prevoir)
UTIL_WARN=90              # % util device (cf. limite RAID/SSD ci-dessus)
AWAIT_WARN=100            # latence I/O en ms (await ou max(r_await,w_await))
FD_WARN=80                # % descripteurs de fichiers
FD_CRIT=90
CONNTRACK_WARN=80         # % table conntrack
ZOMBIE_WARN=20            # nb de zombies
TOPN=5                    # nb de processus listes dans le diagnostic (top CPU/MEM/IO)
NET_LAT_WARN=100          # latence WARN vers la passerelle, en ms (LAN : qq ms normal)
DSTATE_WARN=3             # nb de processus en D-state (I/O bloque) au-dela duquel on alerte
MAJFLT_WARN=200           # defauts de page MAJEURS/s (thrashing) sur la fenetre -> WARN
TCP_RETRANS_WARN=2        # % de segments TCP retransmis (RetransSegs/OutSegs) -> WARN reseau
SAMPLE_WINDOW=10          # fenetre d'echantillonnage CPU/IO (s) ; -w pour ajuster
SAMPLE_INTERVAL=2         # pas d'echantillonnage (s)
LOOKBACK="24 hours ago"   # fenetre temporelle des checks bases sur le journal

# Services dont l'echec est NON BLOQUANT pour le fonctionnement : ils generent un
# WARN au lieu d'un CRIT (et ne font donc pas basculer le verdict global en
# CRITIQUE). kdump capture un vidage memoire post-crash : utile au diagnostic,
# mais son absence n'empeche pas la machine de tourner ; souvent desactive en VM.
# Lister soit le nom court ("kdump"), soit complet ("kdump.service"), espaces.
SERVICES_TOLERES="kdump kdump-early"

#============================ Parsing des arguments ==========================
OUTFILE=""; USE_COLOR="auto"; WATCH=0; WATCH_INTERVAL=30; VERBOSE=0

usage() {
    cat <<USAGE
$PROGNAME v$VERSION - health-check read-only pour SLES 12 SP5

Usage : $PROGNAME [-w SECONDES] [-o FICHIER] [-n] [-v|-vv] [-W DUREE] [-i SECONDES] [-h] [-V]
  -w SECONDES  fenetre d'echantillonnage CPU/IO (defaut $SAMPLE_WINDOW ; 0 = instantane)
  -o FICHIER   ecrit aussi le rapport dans FICHIER (umask 077)
  -n           desactive la couleur
  -v           VERBEUX : affiche pour chaque check la valeur mesuree + le seuil
               (meme quand c'est OK) ; utile pour voir ce qui APPROCHE d'un seuil.
  -vv          DEBUG : en plus, montre les commandes lancees et leurs sources de
               donnees. Pour creuser un cas tordu ou deboguer le script.
  -W DUREE     mode SURVEILLANCE : boucle pendant DUREE secondes et n'affiche QUE
               les passes ou un WARN/CRIT apparait (capture une lenteur en direct).
  -i SECONDES  intervalle entre 2 passes en mode -W (defaut $WATCH_INTERVAL)
  -h           cette aide
  -V           version

Exemples :
  $PROGNAME                 # diagnostic ponctuel (snapshot)
  $PROGNAME -v              # idem, en montrant valeurs + seuils de chaque check
  $PROGNAME -W 600 -i 30    # surveille 10 min, alerte des qu'un seuil est franchi
  $PROGNAME -o /var/log/healthcheck/\$(date +%F_%H%M).txt   # rapport date (cron)

Codes de sortie : 0=sain  1=avertissement  2=critique  3=erreur d'usage
USAGE
}

# Niveau de verbosite cumulable : -v => 1 (valeurs+seuils), -vv => 2 (debug :
# commandes + sources de donnees). 0 = sortie concise par defaut.
while getopts ":w:o:nvW:i:hV" opt; do
    case "$opt" in
        w) SAMPLE_WINDOW="$OPTARG" ;;
        o) OUTFILE="$OPTARG" ;;
        n) USE_COLOR="never" ;;
        v) VERBOSE=$((VERBOSE+1)) ;;
        W) WATCH="$OPTARG" ;;
        i) WATCH_INTERVAL="$OPTARG" ;;
        h) usage; exit 0 ;;
        V) printf '%s %s\n' "$PROGNAME" "$VERSION"; exit 0 ;;
        :) printf 'Erreur : l option -%s attend un argument.\n' "$OPTARG" >&2; exit 3 ;;
        \?) printf 'Erreur : option inconnue -%s\n' "$OPTARG" >&2; usage >&2; exit 3 ;;
    esac
done
case "$SAMPLE_WINDOW"   in ''|*[!0-9]*) printf 'Erreur : -w attend un entier.\n' >&2; exit 3;; esac
case "$WATCH"           in ''|*[!0-9]*) printf 'Erreur : -W attend un entier (secondes).\n' >&2; exit 3;; esac
case "$WATCH_INTERVAL"  in ''|*[!0-9]*|0) printf 'Erreur : -i attend un entier > 0.\n' >&2; exit 3;; esac

#------------------------------------------------------------------------------
# Mode SURVEILLANCE (-W DUREE) : sans supervision externe, c'est la facon de
# capturer une lenteur INTERMITTENTE ("ca rame par moments"). On relance CE MEME
# script a intervalle regulier pendant DUREE secondes, et on n'affiche QUE les
# passes ou un WARN/CRIT est detecte (code de sortie >=1). Une passe saine reste
# silencieuse (juste un point de progression sur stderr). Le code de sortie final
# reflete le pire etat rencontre. 100% read-only : on ne fait que relancer l'outil.
#------------------------------------------------------------------------------
if [ "$WATCH" -gt 0 ]; then
    # Bornes de bon sens : intervalle au moins egal a la fenetre d'echantillonnage
    # (sinon les passes se chevauchent) ; on n'altere pas la valeur, on avertit.
    printf 'Mode surveillance : %ss au total, une passe toutes les %ss.\n' "$WATCH" "$WATCH_INTERVAL" >&2
    printf 'Seules les passes avec WARN/CRIT seront affichees (Ctrl-C pour arreter).\n\n' >&2
    _watch_worst=0
    _watch_deadline=$(( $(date +%s) + WATCH ))
    _pass=0
    while [ "$(date +%s)" -lt "$_watch_deadline" ]; do
        _pass=$((_pass+1))
        # Sous-execution : meme binaire, SANS -W (sinon recursion infinie), couleur
        # desactivee pour un log propre, fenetre courte. On capture la sortie.
        _out=$("$0" -w "$SAMPLE_WINDOW" -n 2>/dev/null); _rc=$?
        if [ "$_rc" -ge 1 ]; then
            # '%s' en 1er argument : evite que printf interprete les tirets de
            # separation comme des options (cas "printf -- : invalid option").
            printf '%s\n' "----- Passe ${_pass} a $(date '+%H:%M:%S') : ANOMALIE (code ${_rc}) -----"
            # On ne montre que l'essentiel : les lignes WARN/CRIT et les pistes.
            printf '%s\n' "$_out" | grep -E '\[WARN\]|\[CRIT\]|Pistes|suspect|Verdict global' || true
            printf '\n'
            [ "$_rc" -gt "$_watch_worst" ] && _watch_worst="$_rc"
        else
            printf '.' >&2   # passe saine : progression discrete
        fi
        sleep "$WATCH_INTERVAL"
    done
    printf '\nSurveillance terminee (%s passes). Pire etat : %s.\n' "$_pass" \
        "$( case "$_watch_worst" in 0) echo SAIN;; 1) echo AVERTISSEMENT;; *) echo CRITIQUE;; esac )" >&2
    exit "$(( _watch_worst ))"
fi

# Validation de la cible -o : refus de tout ce qui n'est pas un fichier regulier
# creable (jamais ecraser un peripherique, un FIFO, ou via symlink un /etc/...).
if [ -n "$OUTFILE" ]; then
    if [ -L "$OUTFILE" ]; then
        printf 'Erreur : %s est un lien symbolique, ecriture refusee.\n' "$OUTFILE" >&2; exit 3; fi
    if [ -e "$OUTFILE" ] && [ ! -f "$OUTFILE" ]; then
        printf 'Erreur : %s n est pas un fichier regulier, ecriture refusee.\n' "$OUTFILE" >&2; exit 3; fi
    if ! : >"$OUTFILE" 2>/dev/null; then
        printf 'Erreur : impossible d ecrire dans %s.\n' "$OUTFILE" >&2; exit 3; fi
fi

#============================ Sortie / couleurs ==============================
if [ "$USE_COLOR" = "never" ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    RED=''; YEL=''; GRN=''; BLU=''; BLD=''; RST=''
else
    RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; BLU=$'\033[36m'; BLD=$'\033[1m'; RST=$'\033[0m'
fi
N_OK=0; N_WARN=0; N_CRIT=0

have()  { command -v "$1" >/dev/null 2>&1; }
# TO SECONDES CMD... : execute CMD avec un timeout si 'timeout' existe, sinon brut.
TO()    { if have timeout; then timeout "$1" "${@:2}"; else shift; "$@"; fi; }
# Le terminal recoit la ligne coloree ; le fichier rapport (-o) la recoit SANS
# couleur (codes ANSI retires via sed, sur un ESC litteral pour la portabilite).
# Sans cela, le rapport contient des sequences "^[[1m..." illisibles.
_ESC=$(printf '\033')
REPORT_BUF=""
emit()  {
    printf '%s\n' "$1"
    # Pour le fichier (-o) : on ACCUMULE en memoire et on ecrit UNE seule fois en
    # fin (flush_report), au lieu d'un fork sed + une ouverture de fichier par
    # ligne. Plus rapide et plus propre. Les codes ANSI sont retires au flush.
    [ -n "$OUTFILE" ] && REPORT_BUF="${REPORT_BUF}${1}"$'\n'
}
flush_report() {
    [ -n "$OUTFILE" ] || return 0
    # Durcissement TOCTOU : la cible a ete validee au demarrage, mais le fichier
    # n'est ecrit qu'ici (en fin d'execution). On RE-verifie juste avant d'ecrire
    # qu'aucun lien symbolique n'a ete substitue entre-temps (un attaquant local
    # pourrait pointer vers /etc/... ). On refuse aussi tout non-fichier-regulier.
    if [ -L "$OUTFILE" ] || { [ -e "$OUTFILE" ] && [ ! -f "$OUTFILE" ]; }; then
        printf 'Erreur : %s n est plus un fichier regulier sur, ecriture annulee.\n' "$OUTFILE" >&2
        return 1
    fi
    printf '%s' "$REPORT_BUF" | sed "s/${_ESC}\\[[0-9;]*m//g" >"$OUTFILE"
}
hdr()   { emit ""; emit "${BLD}=== $* ===${RST}"; }
ok()    { N_OK=$((N_OK+1));     emit "  ${GRN}[ OK ]${RST} $*"; }
warn()  { N_WARN=$((N_WARN+1)); emit "  ${YEL}[WARN]${RST} $*"; }
crit()  { N_CRIT=$((N_CRIT+1)); emit "  ${RED}[CRIT]${RST} $*"; }
info()  { emit "  ${BLU}[INFO]${RST} $*"; }
skip()  { emit "  ${BLU}[----]${RST} $*"; }
# diag() : ligne de DIAGNOSTIC (contexte), n'affecte PAS le verdict ni les
# compteurs. Sert au pointage des coupables d'une lenteur (top processus, pistes).
diag()  { emit "  ${BLU}[DIAG]${RST} $*"; }

#------------------------------------------------------------------------------
# Verbosite (flag -v / -vv). Ces fonctions n'affichent RIEN au niveau normal :
# elles n'incrementent aucun compteur et ne changent jamais le verdict. Elles ne
# servent qu'a EXPLIQUER ce que le script mesure.
#   metric NOM VALEUR SEUIL_WARN [SEUIL_CRIT] : en -v, montre "NOM = VALEUR
#       [WARN>=.. CRIT>=..]". A appeler a cote d'un check pour rendre visible la
#       marge avant l'alerte (ex. "iowait = 3% [WARN>=20 CRIT>=40]").
#   vinfo MESSAGE  : note explicative affichee seulement en -v et plus.
#   vdebug CMD...  : en -vv, montre la commande/source AVANT de l'executer (trace).
#------------------------------------------------------------------------------
metric() {
    [ "$VERBOSE" -ge 1 ] || return 0
    _m_name="$1"; _m_val="$2"; _m_w="${3:-}"; _m_c="${4:-}"
    # Seuil "normal" => alerte si la valeur DEPASSE (prefixe ">="). Si le seuil
    # passe commence deja par un operateur (ex "<=15" pour les seuils inverses
    # type memoire dispo), on l'affiche tel quel sans prefixe.
    _fmt_th() { case "$1" in [\<\>]*) printf '%s' "$1";; *) printf '>=%s' "$1";; esac; }
    _m_th=""
    [ -n "$_m_w" ] && _m_th=" [WARN $(_fmt_th "$_m_w")"
    [ -n "$_m_c" ] && _m_th="${_m_th} CRIT $(_fmt_th "$_m_c")"
    [ -n "$_m_th" ] && _m_th="${_m_th}]"
    emit "         ${BLU}.${RST} ${_m_name} = ${_m_val}${_m_th}"
}
vinfo()  { [ "$VERBOSE" -ge 1 ] && emit "         ${BLU}.${RST} $*"; return 0; }
vdebug() { [ "$VERBOSE" -ge 2 ] && emit "         ${BLU}# source:${RST} $*"; return 0; }

# HINTS : pistes probables accumulees pendant le run, affichees en synthese. Sert
# a relier un SYMPTOME (iowait/charge/swap eleves) a sa CAUSE probable (processus).
HINTS=""
add_hint() { HINTS="${HINTS} - $*"$'\n'; }

fcmp() { awk -v a="$1" -v b="$3" -v op="$2" 'BEGIN{
    if(op==">")  exit !(a>b);  if(op=="<")  exit !(a<b);
    if(op==">=") exit !(a>=b); if(op=="<=") exit !(a<=b); exit 1 }'; }
is_int() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

#------------------------------------------------------------------------------
# Detection de la virtualisation (VM / conteneur / bare-metal).
# systemd-detect-virt est l'outil de reference (present sur SLES 12 SP5) ;
# repli heuristique sinon. En CONTENEUR, beaucoup de metriques refletent l'HOTE
# (load, journal noyau, RAID, SMART, conntrack, file-nr, reboot) : on les
# neutralise pour ne pas rendre de verdict trompeur. En VM, le steal CPU devient
# l'indicateur cle et le materiel physique (RAID/SMART) n'est pas attendu.
#------------------------------------------------------------------------------
IS_CONTAINER=0; IS_VM=0; VIRT="inconnu"
if have systemd-detect-virt; then
    VIRT=$(systemd-detect-virt 2>/dev/null || echo none)
    if systemd-detect-virt -c >/dev/null 2>&1; then IS_CONTAINER=1
    elif [ "$VIRT" != "none" ]; then IS_VM=1; fi
else
    if [ -f /.dockerenv ] || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
        IS_CONTAINER=1; VIRT="conteneur"
    elif grep -qa '^flags.* hypervisor' /proc/cpuinfo 2>/dev/null; then
        IS_VM=1; VIRT="vm (flag hypervisor)"
    else VIRT="none"; fi
fi
if   [ "$IS_CONTAINER" -eq 1 ]; then VCLASS="conteneur"
elif [ "$IS_VM" -eq 1 ];        then VCLASS="VM"
else                                 VCLASS="bare-metal"; fi

#------------------------------------------------------------------------------
# Journal noyau, lu UNE fois et borne dans le temps.
# Priorite a journalctl -k --since (fenetre LOOKBACK) ; repli sur dmesg (anneau,
# NON borne) avec mention. Si rien n'est lisible (dmesg restreint + pas d'acces
# journal), les checks derives sont [----] et non faussement [OK].
#------------------------------------------------------------------------------
KLOG=""; KLOG_OK=0; KLOG_BOUNDED=0
if [ "$IS_CONTAINER" -eq 0 ]; then
    if have journalctl; then
        # 1) fenetre bornee LOOKBACK. On exige une sortie NON VIDE : un rc=0 avec
        #    journal vide ne doit pas faire croire a un journal exploitable.
        if KLOG=$(TO 15 journalctl -k --since "$LOOKBACK" --no-pager 2>/dev/null) && [ -n "$KLOG" ]; then
            KLOG_OK=1; KLOG_BOUNDED=1
        # 2) repli : tout le ring noyau (non borne). Utile quand --since echoue
        #    (ex. pas de journal persistant -> journalctl -k --since rc=1).
        elif KLOG=$(TO 15 journalctl -k --no-pager 2>/dev/null) && [ -n "$KLOG" ]; then
            KLOG_OK=1; KLOG_BOUNDED=0
        fi
    fi
    if [ "$KLOG_OK" -eq 0 ]; then
        if KLOG=$(dmesg -T 2>/dev/null) && [ -n "$KLOG" ]; then KLOG_OK=1; KLOG_BOUNDED=0; fi
    fi
fi
klog_count() { printf '%s' "$KLOG" | grep -icE "$1"; }
# klog_count_excl MOTIF EXCLU -> compte les lignes correspondant a MOTIF mais PAS
# a EXCLU (insensible casse). Sert a ne pas confondre erreurs et messages d'init.
klog_count_excl() { printf '%s' "$KLOG" | grep -iE "$1" | grep -ivcE "$2"; }

#============================ En-tete du rapport =============================
emit "${BLD}Health-check SLES 12 SP5  (v$VERSION)${RST}"
emit "Hote   : $(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null)"
emit "Date   : $(date '+%F %T %Z')"
emit "Uptime :$(uptime | sed 's/.*up/ up/')"
emit "Echant.: fenetre ${SAMPLE_WINDOW}s ; journal borne a '${LOOKBACK}'"
emit "Virt.  : ${VIRT} (${VCLASS})"
[ "$(id -u)" -ne 0 ] && emit "${YEL}Note   : non-root, couverture partielle (SMART, RAID, journal, sockets).${RST}"
[ "$IS_CONTAINER" -eq 1 ] && emit "${YEL}Note   : CONTENEUR -> load/mem refletent l'HOTE ; checks noyau/RAID/SMART/conntrack/reboot neutralises.${RST}"
[ "$IS_VM" -eq 1 ] && emit "${BLU}Note   : VM -> le steal CPU est l'indicateur cle de contention hyperviseur ; pas de RAID/SMART physiques attendus.${RST}"
[ "$KLOG_OK" -eq 1 ] && [ "$KLOG_BOUNDED" -eq 0 ] && emit "${YEL}Note   : journal via dmesg (anneau non borne dans le temps).${RST}"
[ "$KLOG_OK" -eq 0 ] && [ "$IS_CONTAINER" -eq 0 ] && emit "${YEL}Note   : journal noyau illisible ; checks OOM/MCE/I-O limites.${RST}"

#============================ Echantillonnage CPU/IO ========================
# Une seule passe vmstat fournit iowait, steal ET l'activite swap (si/so),
# moyennes sur la fenetre. La 1ere ligne de donnees (moyenne depuis le boot)
# est ignoree : seules les mesures de l'intervalle comptent.
VMSTAT_OK=0; WA=0; ST=0; SI=0; SO=0
if have vmstat && [ "$SAMPLE_WINDOW" -gt 0 ]; then
    N=$(( SAMPLE_WINDOW / SAMPLE_INTERVAL + 1 )); [ "$N" -lt 2 ] && N=2
    # Colonnes resolues depuis l'en-tete (ligne 2 : "r b swpd ... wa st [gu]").
    # Les procps recents ajoutent une colonne 'gu' apres 'st' : des indices figes
    # restent justes par chance ici, mais la resolution par nom est sans surprise.
    read -r WA ST SI SO < <(vmstat "$SAMPLE_INTERVAL" "$N" 2>/dev/null | awk '
        NR==1 {next}                      # ligne 1 : titres de groupes (procs/memory/...)
        NR==2 {                            # ligne 2 : noms de colonnes
            for(i=1;i<=NF;i++){ if($i=="wa")cwa=i; if($i=="st")cst=i; if($i=="si")csi=i; if($i=="so")cso=i }
            next }
        { d++; if(d==1) next }            # 1ere ligne de donnees = moyenne boot, ignoree
        cwa&&cst&&csi&&cso { wa+=$cwa; st+=$cst; si+=$csi; so+=$cso; c++ }
        END{ if(c>0) printf "%.0f %.0f %.0f %.0f", wa/c, st/c, si/c, so/c; else printf "0 0 0 0" }')
    is_int "${WA:-}" && is_int "${ST:-}" && is_int "${SI:-}" && is_int "${SO:-}" && VMSTAT_OK=1
fi

#============================ 1. Charge / CPU ===============================
hdr "Charge & CPU"
[ "$IS_CONTAINER" -eq 1 ] && info "Conteneur : load/iowait/steal refletent l'HOTE, pas le conteneur"
CORES=$(nproc 2>/dev/null || echo 1)
vdebug "/proc/loadavg + nproc"
read -r _ L5 _ </proc/loadavg
RATIO=$(awk -v l="$L5" -v c="$CORES" 'BEGIN{printf "%.2f", l/c}')
if   fcmp "$RATIO" ">" "$LOAD_CRIT_PER_CORE"; then crit "Load5 $L5 sur $CORES coeurs (ratio $RATIO/coeur)"
elif fcmp "$RATIO" ">" "$LOAD_WARN_PER_CORE"; then warn "Load5 $L5 sur $CORES coeurs (ratio $RATIO/coeur)"
else ok "Load5 $L5 sur $CORES coeurs (ratio $RATIO/coeur)"; fi
metric "ratio load5/coeur" "$RATIO" "$LOAD_WARN_PER_CORE" "$LOAD_CRIT_PER_CORE"
if [ "$VMSTAT_OK" -eq 1 ]; then
    vdebug "vmstat $SAMPLE_INTERVAL (moyenne sur ${SAMPLE_WINDOW}s)"
    if   [ "$WA" -ge "$IOWAIT_CRIT" ]; then crit "iowait moyen ${WA}% sur ${SAMPLE_WINDOW}s (attente disque)"
    elif [ "$WA" -ge "$IOWAIT_WARN" ]; then warn "iowait moyen ${WA}% sur ${SAMPLE_WINDOW}s"
    else ok "iowait moyen ${WA}%"; fi
    metric "iowait" "${WA}%" "$IOWAIT_WARN" "$IOWAIT_CRIT"
    if   [ "$ST" -ge "$STEAL_CRIT" ]; then crit "steal moyen ${ST}% (hyperviseur surcharge / vCPU brides)"
    elif [ "$ST" -ge "$STEAL_WARN" ]; then warn "steal moyen ${ST}% (contention hyperviseur)"
    else ok "steal moyen ${ST}%"; fi
    metric "steal" "${ST}%" "$STEAL_WARN" "$STEAL_CRIT"
else skip "iowait/steal : vmstat absent ou -w 0"; fi

#============================ 2. Memoire / swap =============================
hdr "Memoire & swap"
MT=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
MA=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
SWT=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
SWF=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
if is_int "${MA:-}" && is_int "${MT:-}" && [ "${MT:-0}" -gt 0 ]; then
    PA=$(awk -v a="$MA" -v t="$MT" 'BEGIN{printf "%.0f", a*100/t}')
    GB=$(awk -v a="$MA" 'BEGIN{printf "%.1f", a/1048576}')
    vdebug "/proc/meminfo (MemAvailable/MemTotal)"
    if   [ "$PA" -le "$MEM_AVAIL_CRIT" ]; then crit "Memoire dispo ${PA}% (${GB} Go)"
    elif [ "$PA" -le "$MEM_AVAIL_WARN" ]; then warn "Memoire dispo ${PA}% (${GB} Go)"
    else ok "Memoire dispo ${PA}% (${GB} Go)"; fi
    # Seuils inverses (alerte quand SOUS le seuil) : on l'indique explicitement.
    metric "memoire dispo" "${PA}%" "<=${MEM_AVAIL_WARN}" "<=${MEM_AVAIL_CRIT}"
else skip "MemAvailable indisponible"; fi
if is_int "${SWT:-}" && [ "${SWT:-0}" -gt 0 ]; then
    SU=$(awk -v t="$SWT" -v f="$SWF" 'BEGIN{printf "%.0f", (t-f)*100/t}')
    # L'occupation statique est un signal FAIBLE (pages froides) -> informatif.
    info "Swap occupe ${SU}% (occupation seule = signal faible)"
    if [ "$VMSTAT_OK" -eq 1 ]; then
        ACT=$((SI+SO))
        if   [ "$ACT" -ge "$SWAP_ACT_CRIT" ]; then crit "Activite swap ${ACT} KiB/s soutenue (si=${SI} so=${SO})"
        elif [ "$ACT" -ge "$SWAP_ACT_WARN" ]; then warn "Activite swap ${ACT} KiB/s (si=${SI} so=${SO})"
        else ok "Activite swap faible (${ACT} KiB/s)"; fi
    else skip "Activite swap : vmstat absent ou -w 0"; fi
else info "Pas de swap configure"; fi
if [ "$KLOG_OK" -eq 1 ]; then
    OOM=$(klog_count "killed process|out of memory")
    if [ "$OOM" -gt 0 ]; then crit "OOM killer declenche ${OOM} fois (fenetre ${LOOKBACK})"; else ok "Aucune trace OOM (fenetre ${LOOKBACK})"; fi
else skip "Trace OOM : journal noyau illisible"; fi

#============================ 3. Disque : espace & inodes ===================
hdr "Disque - espace & inodes"
EXCL='tmpfs|devtmpfs|squashfs|overlay|iso9660|nfs|nfs4|cifs|fuse'
# Deduplication par DEVICE source : les sous-volumes btrfs (cas SLES par defaut)
# partagent le meme peripherique et donneraient 20+ lignes identiques. On ne
# garde qu'une entree par source ; le point de montage affiche est le 1er vu
# (souvent '/'). awk '!seen[$1]++' = garde la 1ere occurrence de chaque source.
# NB : on utilise 'while ...; done < <(...)' (process substitution) et NON
# '... | while', car un pipe place la boucle dans un SOUS-SHELL : les compteurs
# N_OK/N_WARN/N_CRIT incrementes dedans seraient PERDUS au retour, et un disque
# plein s'afficherait [CRIT] sans faire basculer le verdict global. Bug subtil
# mais critique pour un outil de supervision.
while read -r src typ _ _ _ cap mnt; do
    p=${cap%\%}; is_int "$p" || continue
    if   [ "$p" -ge "$DISK_CRIT" ]; then crit "FS $mnt rempli a ${cap} ($typ, $src)"
    elif [ "$p" -ge "$DISK_WARN" ]; then warn "FS $mnt rempli a ${cap} ($typ, $src)"
    else ok "FS $mnt : ${cap} ($typ)"; fi
done < <(df -PT 2>/dev/null | awk 'NR>1' \
    | grep -Ev "^[^[:space:]]+[[:space:]]+($EXCL)(\.[^[:space:]]+)?([[:space:]]|$)" \
    | awk '!seen[$1]++')
while read -r _ _ _ _ _ cap mnt; do
    p=${cap%\%}; is_int "$p" || continue
    if   [ "$p" -ge "$INODE_CRIT" ]; then crit "Inodes $mnt a ${cap}"
    elif [ "$p" -ge "$INODE_WARN" ]; then warn "Inodes $mnt a ${cap}"; fi
done < <(df -PiT 2>/dev/null | awk 'NR>1' \
    | grep -Ev "^[^[:space:]]+[[:space:]]+($EXCL)(\.[^[:space:]]+)?([[:space:]]|$)" \
    | awk '!seen[$1]++')

#============================ 4. Disque : I/O ===============================
hdr "Disque - I/O"
if have iostat; then
    # Colonnes resolues depuis l'en-tete. Latence : 'await' (sysstat <=11) ou
    # max(r_await, w_await) (sysstat >=12). %util peu fiable sur RAID/SSD : il
    # n'est ici qu'un signal d'appoint, la latence prime.
    #
    # IMPORTANT : on n'utilise PAS '-z' (qui masque les devices inactifs) : sur une
    # VM/machine au repos, l'intervalle de mesure serait vide et la section
    # n'afficherait RIEN. On garde donc tous les devices, on ignore la 1ere passe
    # (moyenne depuis le boot) et on analyse la DERNIERE passe (la plus recente).
    # Si aucune ligne n'est exploitable, on rend un [INFO] explicite plutot que rien.
    # NB : 'iostat -dx 1 2' peut produire PLUS de 2 blocs selon la version de
    # sysstat (observe : 3 blocs = boot + 2 intervalles). On ne se fie donc pas a
    # un numero de bloc fige : on memorise la DERNIERE mesure vue pour chaque
    # device (la plus recente) et on l'evalue en END. La 1ere passe (moyenne boot)
    # est ecartee via blk>=2. Lecteurs optiques (sr*/scd*) ignores.
    IO_OUT=$(iostat -dx 1 2 2>/dev/null | awk -v uw="$UTIL_WARN" -v aw="$AWAIT_WARN" '
        /^Device/ { blk++; u=a=ra=wr=0;
            for(i=1;i<=NF;i++){ if($i=="%util")u=i; if($i=="await")a=i; if($i=="r_await")ra=i; if($i=="w_await")wr=i }
            next }
        blk>=2 && NF>2 && $1 !~ /^(sr|scd)[0-9]+$/ {
            dev=$1;
            util[dev]=(u? $u+0 : -1);
            if(a) lat[dev]=$a+0; else if(ra||wr){ r=(ra?$ra+0:0); w=(wr?$wr+0:0); lat[dev]=(r>w?r:w) } else lat[dev]=-1;
            if(!(dev in order)) order[dev]=++n;   # conserve l ordre d apparition
        }
        END{
            for(dev in order) idx[order[dev]]=dev;  # reindex par ordre
            for(i=1;i<=n;i++){ dev=idx[i]; ut=util[dev]; la=lat[dev];
                tag=((ut>=uw)||(la>=0 && la>=aw)) ? "FLAG" : "OK";
                printf "%s %s util=%.0f%% lat=%.0fms\n", tag, dev, ut, la;
            }
        }')
    if [ -n "$IO_OUT" ]; then
        # process substitution (et non pipe) : sinon les compteurs warn/ok seraient
        # perdus dans le sous-shell (cf. note de la section disque).
        while read -r tag dev rest; do
            if [ "$tag" = "FLAG" ]; then warn "$dev $rest"; else ok "$dev $rest"; fi
        done < <(printf '%s\n' "$IO_OUT")
    else
        info "Aucune activite I/O mesurable sur la fenetre (devices au repos)"
    fi
else skip "I/O par device : iostat absent (paquet sysstat)"; fi

#============================ 5. Integrite FS (lecture seule) ===============
hdr "Integrite systeme de fichiers"
ROFOUND=0
# Alerte UNIQUEMENT sur un FS normalement inscriptible bascule en RO (erreur).
while read -r _ mnt typ opts _; do
    case "$typ" in btrfs|xfs|ext2|ext3|ext4|reiserfs|jfs|f2fs) ;; *) continue;; esac
    case "$mnt" in /sys*|/proc*|/dev*|/run*) continue;; esac
    case ",$opts," in *,ro,*) crit "FS $mnt ($typ) bascule en lecture seule (corruption / I-O ?)"; ROFOUND=1;; esac
done </proc/mounts
if [ "$KLOG_OK" -eq 1 ]; then
    RODMESG=$(klog_count "remounting filesystem read-only|ext4-fs error|xfs.*corruption")
    if [ "$RODMESG" -gt 0 ]; then crit "Journal : remontage RO / erreur FS (${RODMESG}x)"; ROFOUND=1; fi
fi
[ "$ROFOUND" -eq 0 ] && ok "Aucun FS inscriptible en lecture seule"

#============================ 5b. Btrfs (specifique SLES) ===================
# SLES 12 installe '/' en Btrfs avec sous-volumes + snapshots snapper. Trois
# risques propres a Btrfs que 'df' ne montre PAS :
#  1) ENOSPC metadonnees : le bloc Metadata se remplit alors que 'df' affiche de
#     l'espace libre. Tant qu'il reste de l'espace NON-ALLOUE sur le device, Btrfs
#     peut allouer un nouveau chunk de metadonnees -> pas de danger immediat. Le
#     risque reel = metadonnees pleines ET plus d'espace non-alloue. On croise
#     donc les deux signaux (sinon faux positif sur tout FS Btrfs un peu rempli).
#  2) Erreurs device (corruption/IO) remontees par 'btrfs device stats'.
#  3) Accumulation de snapshots snapper (consomme de l'espace silencieusement).
hdr "Btrfs (allocation, erreurs, snapshots)"
if have btrfs; then
    # Mountpoints Btrfs, dedupliques par device (un seul check par FS reel).
    BTRFS_MNTS=$(awk '$3=="btrfs"{print $1"\t"$2}' /proc/mounts 2>/dev/null | awk '!s[$1]++{print $2}')
    if [ -z "$BTRFS_MNTS" ]; then
        info "Aucun systeme de fichiers Btrfs monte"
    else
        for mnt in $BTRFS_MNTS; do
            # --- Allocation (root requis pour 'btrfs filesystem usage') ---
            if [ "$(id -u)" -eq 0 ]; then
                # awk renvoie : <meta%> <unalloc%> <data%>  (entiers), ou rien si echec.
                read -r MPCT UPCT DPCT < <(TO 10 btrfs filesystem usage -b "$mnt" 2>/dev/null | awk '
                    /Device size:/        { dsize=$3 }
                    /Device unallocated:/ { unalloc=$3 }
                    /^[[:space:]]*Data,/     { for(i=1;i<=NF;i++){ if($i~/^Size:/){s=$i;sub(/Size:/,"",s);sub(/,/,"",s);ds=s} if($i~/^Used:/){u=$i;sub(/Used:/,"",u);du=u} } }
                    /^[[:space:]]*Metadata,/ { for(i=1;i<=NF;i++){ if($i~/^Size:/){s=$i;sub(/Size:/,"",s);sub(/,/,"",s);ms=s} if($i~/^Used:/){u=$i;sub(/Used:/,"",u);mu=u} } }
                    END{
                        if(ms>0 && dsize>0){
                            printf "%.0f %.0f %.0f", mu*100/ms, unalloc*100/dsize, (ds>0? du*100/ds : 0)
                        }
                    }')
                if is_int "${MPCT:-}" && is_int "${UPCT:-}"; then
                    if   [ "$MPCT" -ge "$BTRFS_META_CRIT" ] && [ "$UPCT" -lt "$BTRFS_UNALLOC_WARN" ]; then
                        crit "$mnt : metadonnees Btrfs a ${MPCT}% ET device non-alloue a ${UPCT}% (risque ENOSPC imminent)"
                    elif [ "$MPCT" -ge "$BTRFS_META_WARN" ] && [ "$UPCT" -lt "$BTRFS_UNALLOC_WARN" ]; then
                        warn "$mnt : metadonnees Btrfs a ${MPCT}%, peu d'espace non-alloue (${UPCT}%) -> surveiller (btrfs balance ?)"
                    else
                        ok "$mnt : Btrfs data ${DPCT}% / metadata ${MPCT}% / non-alloue ${UPCT}%"
                    fi
                else
                    skip "$mnt : allocation Btrfs illisible (btrfs filesystem usage)"
                fi
            else
                skip "$mnt : allocation Btrfs (root requis)"
            fi
            # --- Erreurs device (lecture seule, root requis) ---
            if [ "$(id -u)" -eq 0 ]; then
                DEVERR=$(TO 10 btrfs device stats "$mnt" 2>/dev/null | awk '{n=$NF+0; if(n>0) s+=n} END{print s+0}')
                CORR=$(TO 10 btrfs device stats "$mnt" 2>/dev/null | awk '/corruption_errs/{c+=$NF+0} END{print c+0}')
                if   is_int "${CORR:-}" && [ "${CORR:-0}" -gt 0 ]; then crit "$mnt : ${CORR} erreur(s) de corruption Btrfs (btrfs device stats)"
                elif is_int "${DEVERR:-}" && [ "${DEVERR:-0}" -gt 0 ]; then warn "$mnt : ${DEVERR} erreur(s) device Btrfs (IO/flush/generation)"
                else ok "$mnt : aucun compteur d'erreur Btrfs"; fi
            fi
        done
    fi
    # --- Snapshots snapper (accumulation silencieuse) ---
    if have snapper && [ "$(id -u)" -eq 0 ]; then
        NSNAP=$(TO 15 snapper list 2>/dev/null | grep -cE '^[[:space:]]*[0-9]')
        if is_int "${NSNAP:-}"; then
            if [ "$NSNAP" -ge "$BTRFS_SNAP_WARN" ]; then warn "${NSNAP} snapshots snapper (menage a prevoir : snapper cleanup)"
            else ok "${NSNAP} snapshot(s) snapper"; fi
        fi
    fi
else
    info "btrfs-progs absent (pas de checks Btrfs specifiques)"
fi

#============================ 6. RAID =====================================
hdr "RAID (materiel & logiciel)"
if [ "$IS_CONTAINER" -eq 1 ]; then
    skip "RAID : non pertinent en conteneur (vue hote)"
else
RAID_SEEN=0
# --- RAID logiciel (md) via /proc/mdstat : sans privilege ---
if [ -f /proc/mdstat ] && grep -q '^md' /proc/mdstat 2>/dev/null; then
    RAID_SEEN=1
    if grep -oE '\[[U_]+\]' /proc/mdstat | grep -q '_'; then
        crit "Array md DEGRADE (disque manquant, voir /proc/mdstat)"
    elif grep -qiE 'recovery|resync|reshape|check' /proc/mdstat; then
        warn "Array md en reconstruction/verification (voir /proc/mdstat)"
    else
        ok "Arrays md sains"
    fi
fi
# --- RAID materiel HP Smart Array via ssacli/hpssacli : root requis ---
SSA=""; have ssacli && SSA=ssacli; { [ -z "$SSA" ] && have hpssacli; } && SSA=hpssacli
if [ -n "$SSA" ]; then
    RAID_SEEN=1
    if [ "$(id -u)" -eq 0 ]; then
        OUT=$(TO 20 "$SSA" ctrl all show config 2>/dev/null)
        if [ -n "$OUT" ]; then
            if printf '%s' "$OUT" | grep -qiE 'Failed|Degraded'; then
                crit "Smart Array : disque/volume en defaut ($SSA ctrl all show config)"
            elif printf '%s' "$OUT" | grep -qiE 'Recovering|Rebuild|Expanding|Predictive'; then
                warn "Smart Array : reconstruction ou alerte predictive en cours"
            else
                ok "Smart Array : configuration saine"
            fi
        else skip "Smart Array : aucune sortie ($SSA)"; fi
    else skip "Smart Array : root requis ($SSA detecte)"; fi
fi
if [ "$RAID_SEEN" -eq 0 ]; then
    if [ "$IS_VM" -eq 1 ]; then info "VM : pas de RAID physique (attendu) ; redondance geree cote hyperviseur/SAN"
    else info "Aucun RAID md ni controleur HP Smart Array detecte"; fi
fi
fi

#============================ 7. Reseau ====================================
hdr "Reseau"
NETERR=0
for path in /sys/class/net/*; do
    [ -e "$path" ] || continue
    IF=${path##*/}; [ "$IF" = "lo" ] && continue
    OP=$(cat "$path/operstate" 2>/dev/null)
    RXE=$(cat "$path/statistics/rx_errors" 2>/dev/null || echo 0)
    TXE=$(cat "$path/statistics/tx_errors" 2>/dev/null || echo 0)
    RXD=$(cat "$path/statistics/rx_dropped" 2>/dev/null || echo 0)
    is_int "$RXE" || RXE=0; is_int "$TXE" || TXE=0; is_int "$RXD" || RXD=0
    if [ "$OP" = "down" ]; then info "Interface $IF down"
    elif [ "$((RXE+TXE))" -gt 0 ]; then warn "Interface $IF : ${RXE} err RX / ${TXE} err TX / ${RXD} drop"; NETERR=1; fi
done
[ "$NETERR" -eq 0 ] && ok "Interfaces actives sans erreur"
if [ "$IS_CONTAINER" -eq 0 ] && [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
    CC=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
    CM=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
    if is_int "$CC" && is_int "$CM" && [ "$CM" -gt 0 ]; then
        CP=$(awk -v c="$CC" -v m="$CM" 'BEGIN{printf "%.0f", c*100/m}')
        if [ "$CP" -ge "$CONNTRACK_WARN" ]; then warn "Table conntrack a ${CP}% (${CC}/${CM})"; else ok "conntrack ${CP}%"; fi
    fi
fi
# --- Latence vers la passerelle : une lenteur "reseau" (NFS lent, appli distante)
#     se voit souvent ici. On ne teste QUE la passerelle (pas internet) : c'est le
#     1er saut, fiable et non intrusif. ping non bloquant (timeout), 3 paquets.
if [ "$IS_CONTAINER" -eq 0 ] && have ping; then
    GW=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
    if [ -n "${GW:-}" ]; then
        # avg rtt extrait de la ligne "rtt min/avg/max/..." de ping.
        RTT=$(TO 6 ping -n -c 3 -w 4 "$GW" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%.0f", $5}')
        if is_int "${RTT:-}"; then
            if [ "$RTT" -ge "$NET_LAT_WARN" ]; then warn "Latence passerelle ($GW) elevee : ${RTT} ms"
            else ok "Latence passerelle ($GW) : ${RTT} ms"; fi
        else info "Passerelle $GW injoignable en ICMP (peut etre filtre, pas forcement un probleme)"; fi
    fi
fi
# --- Debit instantane par interface active (lecture de /proc/net/dev a 1 s
#     d'intervalle). Purement informatif : aide a voir si une interface est tres
#     sollicitee. Gate sur -w>0 pour ne pas ajouter de delai en mode instantane.
if [ "$SAMPLE_WINDOW" -gt 0 ] && [ -r /proc/net/dev ]; then
    declare -A RX1 TX1
    while read -r iface rx tx; do RX1[$iface]=$rx; TX1[$iface]=$tx; done < <(
        awk -F'[: ]+' 'NR>2 && $2!="lo"{print $2, $3, $11}' /proc/net/dev 2>/dev/null)
    sleep 1
    while read -r iface rx tx; do
        [ -z "${RX1[$iface]:-}" ] && continue
        drx=$(( (rx - RX1[$iface]) / 1024 )); dtx=$(( (tx - TX1[$iface]) / 1024 ))
        [ "$drx" -lt 0 ] && drx=0; [ "$dtx" -lt 0 ] && dtx=0
        # On n'affiche que les interfaces avec un minimum de trafic (>0 KiB/s).
        [ "$((drx+dtx))" -gt 0 ] && info "Debit $iface : RX ${drx} KiB/s / TX ${dtx} KiB/s"
    done < <(awk -F'[: ]+' 'NR>2 && $2!="lo"{print $2, $3, $11}' /proc/net/dev 2>/dev/null)
fi

#============================ 8. Services / paquets =========================
hdr "Services & paquets"
if have systemctl; then
    FAILED=$(systemctl --failed --no-legend --plain 2>/dev/null | awk 'NF{print $1}')
    if [ -n "$FAILED" ]; then
        # On separe les services TOLERES (non bloquants pour le fonctionnement,
        # cf. SERVICES_TOLERES en tete) des autres. Toleres => WARN ; autres => CRIT.
        CRIT_SVC=""; WARN_SVC=""
        for svc in $FAILED; do
            base=${svc%.service}                     # normalise "x.service" -> "x"
            case " $SERVICES_TOLERES " in
                *" $base "*|*" $svc "*) WARN_SVC="$WARN_SVC $svc" ;;
                *)                      CRIT_SVC="$CRIT_SVC $svc" ;;
            esac
        done
        WARN_SVC=${WARN_SVC# }; CRIT_SVC=${CRIT_SVC# }
        if [ -n "$CRIT_SVC" ]; then
            NC=$(printf '%s' "$CRIT_SVC" | wc -w)
            crit "$NC service(s) en echec : $CRIT_SVC"
        fi
        if [ -n "$WARN_SVC" ]; then
            NW=$(printf '%s' "$WARN_SVC" | wc -w)
            warn "$NW service(s) tolere(s) en echec (non bloquant) : $WARN_SVC"
        fi
        [ -z "$CRIT_SVC" ] && [ -z "$WARN_SVC" ] && ok "Aucun service systemd en echec"
    else ok "Aucun service systemd en echec"; fi
else skip "Etat des services : systemctl absent"; fi
if have zypper; then
    ZPS=$(TO 30 zypper ps -sss 2>/dev/null | grep -c .)
    if [ "${ZPS:-0}" -gt 0 ]; then
        warn "$ZPS service(s) utilisent des libs supprimees (zypper ps -s : a redemarrer)"
    else ok "Aucun service a redemarrer (zypper ps)"; fi
fi

#============================ 9. Horloge ===================================
hdr "Synchronisation horloge"
if have timedatectl; then
    SY=$(timedatectl 2>/dev/null | awk -F: '/synchronized/{gsub(/ /,"",$2);print $2}')
    # Service de synchro reellement actif, pour un message ACTIONNABLE (savoir
    # quoi regarder : service absent vs actif-mais-pas-encore-cale).
    TSVC="aucun"
    for s in chronyd ntpd systemd-timesyncd; do
        if systemctl is-active "$s" >/dev/null 2>&1; then TSVC="$s"; break; fi
    done
    case "$SY" in
        yes) ok "Horloge synchronisee (NTP via ${TSVC})";;
        no)  if [ "$TSVC" = "aucun" ]; then
                 warn "Horloge NON synchronisee : aucun service NTP actif (activer chronyd)"
             else
                 warn "Horloge NON synchronisee : ${TSVC} actif mais pas cale (joignabilite des serveurs NTP ?)"
             fi;;
        *)   info "Etat de synchro indetermine";;
    esac
else skip "Synchro horloge : timedatectl absent"; fi

#============================ 10. Noyau / materiel =========================
hdr "Noyau & materiel"
if [ "$KLOG_OK" -eq 1 ]; then
    # Motif resserre : on cible les SIGNATURES d'erreur, pas les messages d'init
    # (ex. "mce: CPU supports N MCE banks", "CPU0: Thermal monitoring enabled").
    # On exclut les lignes de capacite/configuration via klog_count_excl.
    MCE=$(klog_count_excl "hardware error|machine check exception|mce:.*(error|corrected|uncorrected|fatal)" \
                          "supports|banks|enabled|disabled|scan|configured|version|using")
    if [ "$MCE" -gt 0 ]; then crit "Erreurs machine-check / hardware (${MCE}x, ${LOOKBACK})"; else ok "Aucune MCE/erreur materielle"; fi
    ECC=$(klog_count "edac.*(error|corrected)")
    [ "$ECC" -gt 0 ] && warn "Evenements ECC memoire (EDAC) (${ECC}x)"
    IOE=$(klog_count "i/o error|medium error|ata[0-9]+.*error|exception emask")
    if [ "$IOE" -gt 0 ]; then crit "Erreurs I/O / disque dans le journal (${IOE}x, ${LOOKBACK})"; else ok "Aucune erreur I/O disque"; fi
    SEG=$(klog_count "segfault")
    [ "$SEG" -gt 0 ] && warn "${SEG} segfault(s) dans le journal"
else
    skip "MCE / erreurs I/O / segfault : journal noyau illisible"
fi
# SMART : etat de sante synthetique uniquement (-H), commande non agressive.
if [ "$IS_CONTAINER" -eq 1 ]; then
    skip "SMART : non pertinent en conteneur"
elif have smartctl && [ "$(id -u)" -eq 0 ]; then
    SMERR=0; SMSEEN=0
    if have lsblk; then DISKS=$(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); else DISKS=""; fi
    for d in $DISKS; do
        # Disques virtuels (virtio/Xen) : SMART non disponible, on n'alarme pas.
        case "$d" in vd*|xvd*) info "SMART /dev/$d : disque virtuel (SMART non disponible)"; continue;; esac
        SMSEEN=1
        H=$(TO 10 smartctl -H "/dev/$d" 2>/dev/null | grep -iE "overall-health|SMART Health" | grep -ioE "PASSED|FAILED|OK")
        case "$H" in
            PASSED|OK) ;;
            FAILED) crit "SMART /dev/$d : FAILED"; SMERR=1;;
            *) info "SMART /dev/$d : etat indetermine";;
        esac
    done
    [ "$SMSEEN" -eq 1 ] && [ "$SMERR" -eq 0 ] && ok "SMART : disques OK"
    [ "$SMSEEN" -eq 0 ] && skip "SMART : aucun disque physique liste"
else skip "SMART : root + smartmontools requis"; fi

#============================ 11. Limites / processus ======================
hdr "Limites & processus"
if [ "$IS_CONTAINER" -eq 1 ]; then
    skip "Descripteurs de fichiers : valeur hote en conteneur"
elif [ -r /proc/sys/fs/file-nr ]; then
    read -r FNR _ FMAX </proc/sys/fs/file-nr
    if is_int "$FNR" && is_int "$FMAX" && [ "$FMAX" -gt 0 ]; then
        FP=$(awk -v n="$FNR" -v m="$FMAX" 'BEGIN{printf "%.0f", n*100/m}')
        if   [ "$FP" -ge "$FD_CRIT" ]; then crit "Descripteurs de fichiers a ${FP}% (${FNR}/${FMAX})"
        elif [ "$FP" -ge "$FD_WARN" ]; then warn "Descripteurs de fichiers a ${FP}% (${FNR}/${FMAX})"
        else ok "Descripteurs de fichiers ${FP}%"; fi
    fi
fi
# shellcheck disable=SC2009  # ps|grep est ici la methode la plus robuste pour
# filtrer sur l'etat 'Z' (le champ comm de /proc/pid/stat peut contenir des espaces).
ZB=$(ps -eo stat= 2>/dev/null | grep -c '^Z')
if [ "${ZB:-0}" -ge "$ZOMBIE_WARN" ]; then warn "${ZB} processus zombies"; else ok "${ZB:-0} processus zombie(s)"; fi

#============================ 12. Maintenance =============================
hdr "Maintenance"
if [ "$IS_CONTAINER" -eq 1 ]; then
    skip "Reboot : non pertinent en conteneur"
elif have zypper; then
    # zypper needs-rebooting : 0 = pas besoin, 102 = reboot requis. Tout autre
    # code (lock, erreur, timeout) ne doit PAS etre interprete comme "reboot requis".
    TO 30 zypper needs-rebooting >/dev/null 2>&1; rc=$?
    case "$rc" in
        0)   ok   "Pas de reboot signale (zypper needs-rebooting)" ;;
        102) warn "Reboot requis (zypper needs-rebooting)" ;;
        *)   skip "Reboot : zypper needs-rebooting indisponible (rc=$rc)" ;;
    esac
else
    RUN=$(uname -r)
    LAST=$(rpm -q --last kernel-default 2>/dev/null | head -1 | awk '{print $1}' | sed 's/kernel-default-//')
    if [ -n "$LAST" ] && ! printf '%s' "$RUN" | grep -q "${LAST%%-*}"; then
        warn "Noyau courant ($RUN) != dernier installe ($LAST) -> reboot probable"
    else ok "Noyau a jour / pas de reboot signale"; fi
fi

#============================ 13. Diagnostic lenteur =======================
# Cette section est le COEUR de l'usage "un utilisateur se plaint de lenteur".
# Les sections precedentes disent S'IL Y A un probleme (seuils) ; celle-ci dit
# QUI le cause (processus). 100% read-only (ps + /proc + pidstat). Elle n'emet
# que des [DIAG] : elle n'incremente PAS les compteurs et ne change pas le verdict
# (le verdict reste pilote par les seuils objectifs des sections 1-12).
hdr "Diagnostic lenteur - top consommateurs"

# --- Top CPU (ps trie par %CPU). En multi-coeurs, un processus peut depasser
#     100% (somme sur plusieurs coeurs) : c'est normal, pas un bug.
TOP_CPU_DESC=""
if have ps; then
    diag "Top ${TOPN} processus par CPU :"
    first=1
    while read -r pid pcpu pmem comm; do
        [ -z "${pid:-}" ] && continue
        emit "         CPU ${pcpu}%  MEM ${pmem}%  PID ${pid}  ${comm}"
        [ "$first" -eq 1 ] && { TOP_CPU_DESC="${comm} (PID ${pid}, ${pcpu}% CPU)"; first=0; }
    done < <(ps -eo pid=,pcpu=,pmem=,comm= --sort=-pcpu 2>/dev/null | head -n "$TOPN")

    # --- Top memoire (ps trie par %MEM) ---
    diag "Top ${TOPN} processus par memoire :"
    first=1
    while read -r pid pcpu pmem comm; do
        [ -z "${pid:-}" ] && continue
        emit "         MEM ${pmem}%  CPU ${pcpu}%  PID ${pid}  ${comm}"
        [ "$first" -eq 1 ] && { TOP_MEM_DESC="${comm} (PID ${pid}, ${pmem}% MEM)"; first=0; }
    done < <(ps -eo pid=,pcpu=,pmem=,comm= --sort=-pmem 2>/dev/null | head -n "$TOPN")
else
    skip "Top CPU/memoire : ps absent"
fi

# --- Top I/O disque par processus (pidstat -d, 1 echantillon d'1 s). Colonnes
#     resolues par en-tete (robuste aux versions de sysstat). Seules les lignes
#     'Average:' sont prises (valeur stabilisee de l'intervalle).
TOP_IO_DESC=""
if [ "$IS_CONTAINER" -eq 0 ] && have pidstat; then
    IO_TOP=$(TO 8 pidstat -d 1 1 2>/dev/null | awk '
        /kB_rd\/s/ { for(i=1;i<=NF;i++){ if($i=="kB_rd/s")rd=i; if($i=="kB_wr/s")wr=i; if($i=="PID")p=i; if($i=="Command")c=i } next }
        $1=="Average:" && rd && c && NF>=c { t=$rd+$wr; if(t>0) printf "%.0f %s %s\n", t, $p, $c }
    ' | sort -rn | head -n "$TOPN")
    if [ -n "$IO_TOP" ]; then
        diag "Top processus par I/O disque (KiB/s lus+ecrits) :"
        first=1
        while read -r tot pid comm; do
            [ -z "${tot:-}" ] && continue
            emit "         I/O ${tot} KiB/s  PID ${pid}  ${comm}"
            [ "$first" -eq 1 ] && { TOP_IO_DESC="${comm} (PID ${pid}, ${tot} KiB/s)"; first=0; }
        done < <(printf '%s\n' "$IO_TOP")
    else
        diag "Aucune activite I/O par processus mesurable sur 1 s (disque au repos)"
    fi
elif [ "$IS_CONTAINER" -eq 0 ]; then
    skip "Top I/O par processus : pidstat absent (paquet sysstat)"
fi

# --- Correlation SYMPTOME -> CAUSE : on relie chaque signe de lenteur detecte
#     plus haut au coupable probable identifie ci-dessus. C'est ce qui transforme
#     l'outil en aide a la decision ("la lenteur vient de X").
if [ "$VMSTAT_OK" -eq 1 ] && fcmp "$RATIO" ">" "$LOAD_WARN_PER_CORE"; then
    add_hint "Charge CPU elevee (ratio ${RATIO}/coeur)${TOP_CPU_DESC:+ -> suspect : $TOP_CPU_DESC}"
fi
if [ "$VMSTAT_OK" -eq 1 ] && [ "$WA" -ge "$IOWAIT_WARN" ]; then
    add_hint "Attente disque elevee (iowait ${WA}%)${TOP_IO_DESC:+ -> suspect : $TOP_IO_DESC}"
fi
if [ "$VMSTAT_OK" -eq 1 ] && [ "$ST" -ge "$STEAL_WARN" ]; then
    add_hint "Steal CPU ${ST}% : la lenteur vient de l'HYPERVISEUR (vCPU non servis), pas de cette VM"
fi
if is_int "${PA:-}" && [ "${PA:-100}" -le "$MEM_AVAIL_WARN" ]; then
    add_hint "Memoire disponible faible (${PA}%)${TOP_MEM_DESC:+ -> suspect : $TOP_MEM_DESC}"
fi
if [ "$VMSTAT_OK" -eq 1 ] && [ "$((SI+SO))" -ge "$SWAP_ACT_WARN" ]; then
    add_hint "Swap actif ($((SI+SO)) KiB/s) : RAM insuffisante, pagination en cours (cause frequente de lenteur globale)"
fi

#============================ 14. Detection avancee de lenteur =============
# Signaux fins, souvent invisibles d'un simple "top", qui expliquent une lenteur :
#   a) processus bloques en I/O (D-state) + 'task hung' du noyau ;
#   b) thrashing memoire (defauts de page MAJEURS = lecture disque forcee) ;
#   c) retransmissions TCP (lenteur reseau reelle, pas juste latence ICMP) ;
#   d) historique sar : "qu'est-ce qui s'est passe QUAND ca ramait" (le snapshot
#      ponctuel rate les pics passes ; sar comble ce trou).
# NB : PSI (/proc/pressure) serait l'ideal mais ABSENT sur ce noyau 4.12 (>=4.20
# requis). 100% read-only.
hdr "Detection avancee de lenteur"

# --- a) Processus en D-state (uninterruptible sleep = bloque sur I/O noyau).
#     Quelques-uns sont normaux ponctuellement ; un nombre soutenu = I/O qui coince
#     (disque/NFS/SAN lent). On liste les coupables (read-only, /proc via ps).
if have ps; then
    DPROCS=$(ps -eo stat=,pid=,comm= 2>/dev/null | awk '$1 ~ /^D/{printf "%s(%s) ", $3, $2}')
    DCOUNT=$(printf '%s' "$DPROCS" | wc -w)
    if [ "${DCOUNT:-0}" -ge "$DSTATE_WARN" ]; then
        warn "${DCOUNT} processus bloques en I/O (D-state) : $DPROCS"
        add_hint "Processus bloques sur I/O (D-state x${DCOUNT}) : $DPROCS -> disque/NFS/SAN lent ?"
    elif [ "${DCOUNT:-0}" -gt 0 ]; then
        diag "${DCOUNT} processus en D-state (ponctuel, surveiller) : $DPROCS"
    else
        ok "Aucun processus bloque en I/O (D-state)"
    fi
fi

# --- a bis) 'task blocked for more than Ns' / soft lockup dans le journal noyau :
#     symptome d'un I/O ou d'un verrou noyau qui a fige des taches (=lenteur dure).
if [ "$KLOG_OK" -eq 1 ]; then
    HUNG=$(klog_count "blocked for more than|hung_task|soft lockup|rcu_sched.*stall")
    if [ "${HUNG:-0}" -gt 0 ]; then
        crit "Taches figees / lockup dans le journal noyau (${HUNG}x, ${LOOKBACK})"
        add_hint "Le noyau a signale des taches figees (hung_task/lockup, ${HUNG}x) : I/O ou verrou noyau"
    else
        ok "Aucune tache figee / lockup dans le journal noyau"
    fi
fi

# --- b) Thrashing memoire : taux de defauts de page MAJEURS (chaque major fault =
#     une page lue depuis le disque/swap -> tres couteux). Mesure par delta de
#     pgmajfault dans /proc/vmstat sur la fenetre. Gate sur -w>0 (besoin d'un delta).
if [ "$SAMPLE_WINDOW" -gt 0 ] && [ -r /proc/vmstat ]; then
    MJ1=$(awk '/^pgmajfault /{print $2}' /proc/vmstat)
    sleep 1
    MJ2=$(awk '/^pgmajfault /{print $2}' /proc/vmstat)
    if is_int "${MJ1:-}" && is_int "${MJ2:-}"; then
        MJRATE=$(( MJ2 - MJ1 )); [ "$MJRATE" -lt 0 ] && MJRATE=0
        if [ "$MJRATE" -ge "$MAJFLT_WARN" ]; then
            warn "Thrashing memoire : ${MJRATE} defauts de page MAJEURS/s (lecture disque forcee)"
            add_hint "Thrashing memoire (${MJRATE} major faults/s)${TOP_MEM_DESC:+ -> suspect : $TOP_MEM_DESC}"
        else
            ok "Defauts de page majeurs faibles (${MJRATE}/s)"
        fi
    fi
fi

# --- c) Retransmissions TCP : un % eleve de segments retransmis = pertes reseau
#     (cable, congestion, lien sature) -> lenteur des appli reseau, invisible au
#     ping. Ratio cumulatif depuis le boot (RetransSegs/OutSegs de /proc/net/snmp).
if [ "$IS_CONTAINER" -eq 0 ] && [ -r /proc/net/snmp ]; then
    # Ligne "Tcp: <valeurs>" : OutSegs=col 12, RetransSegs=col 13 (1=label "Tcp:").
    OUTSEG=$(awk '/^Tcp: [0-9]/{print $12}' /proc/net/snmp 2>/dev/null)
    RETSEG=$(awk '/^Tcp: [0-9]/{print $13}' /proc/net/snmp 2>/dev/null)
    if is_int "${OUTSEG:-}" && is_int "${RETSEG:-}" && [ "${OUTSEG:-0}" -gt 1000 ]; then
        RPCT=$(awk -v r="$RETSEG" -v o="$OUTSEG" 'BEGIN{printf "%.1f", r*100/o}')
        # comparaison flottante via fcmp (RPCT a une decimale)
        if fcmp "$RPCT" ">=" "$TCP_RETRANS_WARN"; then
            warn "Retransmissions TCP a ${RPCT}% (${RETSEG}/${OUTSEG} segments) : pertes reseau"
            add_hint "Retransmissions TCP elevees (${RPCT}%) : reseau peu fiable / sature (lenteur appli distantes)"
        else
            ok "Retransmissions TCP faibles (${RPCT}%, depuis le boot)"
        fi
    else
        diag "Retransmissions TCP : trafic insuffisant pour un ratio fiable"
    fi
fi

# --- d) Historique sar : repond a "c'etait lent il y a 2h". sar lit les donnees
#     collectees par sysstat. Si la collecte est inactive, on l'indique (sans
#     l'activer : ce serait une modif systeme, hors perimetre read-only).
if have sar; then
    if sar -u 1 1 >/dev/null 2>&1 && ls /var/log/sa/sa[0-9]* >/dev/null 2>&1; then
        # Pic d'utilisation CPU du jour : 100 - min(%idle). Lecture seule de l'historique.
        CPUPEAK=$(TO 10 sar -u 2>/dev/null | awk '
            /%idle/{for(i=1;i<=NF;i++)if($i=="%idle")c=i; next}
            c && $1 ~ /[0-9]/ && $c ~ /^[0-9.]+$/ { busy=100-$c; if(busy>max){max=busy; t=$1} }
            END{ if(max>0) printf "%.0f %s", max, t }')
        if [ -n "${CPUPEAK:-}" ]; then
            # CPUPEAK = "<busy%> <heure>" : on separe pour un affichage lisible.
            CPUPEAK_VAL=${CPUPEAK%% *}; CPUPEAK_AT=${CPUPEAK##* }
            info "Historique sar : pic d'occupation CPU ${CPUPEAK_VAL}% a ${CPUPEAK_AT} aujourd'hui (contexte des lenteurs passees)"
        else
            diag "Historique sar disponible mais aucun pic CPU notable aujourd'hui"
        fi
    else
        info "Historique sar inactif : pour tracer les lenteurs PASSEES, activer la collecte"
        info "  (commande, A LANCER MANUELLEMENT) : systemctl enable --now sysstat"
    fi
fi

#============================ 15. Diagnostic redige ========================
# Conclusion en langage humain : pour CHAQUE symptome detecte, une phrase qui
# explique la cause probable ET donne la commande concrete pour CONFIRMER /
# creuser (interactive, non lancee par ce script qui reste read-only). C'est ce
# qui rend le rapport exploitable par quelqu'un qui n'est pas expert du systeme.
# Les conditions sont les memes que celles des "Pistes" : variables globales
# deja calculees plus haut (WA, ST, PA, SI/SO, DCOUNT, MJRATE, RPCT...).
RECO=""
add_reco() { RECO="${RECO}${1}"$'\n'"${2}"$'\n'$'\n'; }

if [ "$VMSTAT_OK" -eq 1 ] && fcmp "$RATIO" ">" "$LOAD_WARN_PER_CORE"; then
    add_reco "* CPU sature (load ${RATIO}/coeur)${TOP_CPU_DESC:+, suspect : $TOP_CPU_DESC}." \
             "    Confirmer : top -b -n1 -o %CPU | head -15   (ou : pidstat -u 1 5)"
fi
if [ "$VMSTAT_OK" -eq 1 ] && [ "$WA" -ge "$IOWAIT_WARN" ]; then
    add_reco "* Disque lent / sature (iowait ${WA}%)${TOP_IO_DESC:+, suspect : $TOP_IO_DESC}." \
             "    Confirmer : iostat -dxz 2 3   et   pidstat -d 1 5   (qui ecrit/lit le plus)"
fi
if [ "$VMSTAT_OK" -eq 1 ] && [ "$ST" -ge "$STEAL_WARN" ]; then
    add_reco "* Contention hyperviseur (steal ${ST}%) : le probleme est sur l'HOTE, pas cette VM." \
             "    A verifier cote hyperviseur (surengagement vCPU). Rien a corriger dans la VM."
fi
if is_int "${PA:-}" && [ "${PA:-100}" -le "$MEM_AVAIL_WARN" ]; then
    add_reco "* Memoire faible (${PA}% dispo)${TOP_MEM_DESC:+, suspect : $TOP_MEM_DESC}." \
             "    Confirmer : free -h   et   ps -eo pid,pmem,rss,comm --sort=-rss | head"
fi
if [ "$VMSTAT_OK" -eq 1 ] && [ "$((SI+SO))" -ge "$SWAP_ACT_WARN" ]; then
    add_reco "* Pagination active (swap si+so $((SI+SO)) KiB/s) : RAM insuffisante -> lenteur globale." \
             "    Confirmer : vmstat 2 5 (colonnes si/so)   ; envisager + de RAM ou moins de services."
fi
if [ "${DCOUNT:-0}" -ge "${DSTATE_WARN:-3}" ]; then
    add_reco "* Processus bloques sur I/O (D-state x${DCOUNT}) : un stockage ne repond pas (disque/NFS/SAN)." \
             "    Confirmer : ps -eo pid,stat,wchan,comm | awk '\$2 ~ /D/'   (wchan = ou ca bloque)"
fi
if [ "${MJRATE:-0}" -ge "${MAJFLT_WARN:-200}" ] 2>/dev/null; then
    add_reco "* Thrashing memoire (${MJRATE} major faults/s) : le systeme lit le disque faute de RAM." \
             "    Confirmer : sar -B 1 5 (majflt/s)   ; meme remede que pagination (RAM)."
fi
if [ -n "${RPCT:-}" ] && fcmp "${RPCT:-0}" ">=" "${TCP_RETRANS_WARN:-2}"; then
    add_reco "* Reseau peu fiable (retransmissions TCP ${RPCT}%) : lenteur des appli distantes." \
             "    Confirmer : ss -ti | grep -i retrans   ; tester le lien (mtr/ping vers la cible)."
fi

if [ -n "$RECO" ]; then
    hdr "Diagnostic - causes probables & verifications"
    diag "Pour chaque symptome : la cause probable, puis la commande pour confirmer."
    emit ""
    while IFS= read -r _r; do emit "  $_r"; done < <(printf '%s' "$RECO")
elif [ "$N_WARN" -eq 0 ] && [ "$N_CRIT" -eq 0 ]; then
    hdr "Diagnostic - causes probables & verifications"
    diag "Aucun symptome de lenteur : CPU, disque, memoire, swap et reseau dans les normes."
    [ "$VERBOSE" -ge 1 ] && vinfo "Si une lenteur est ressentie malgre tout : la cause est probablement applicative (lancer le diagnostic PENDANT la lenteur, ou via -W) ou hors de cette machine."
fi

#============================ Synthese =====================================
emit ""
emit "${BLD}============================================================${RST}"
if   [ "$N_CRIT" -gt 0 ]; then VERDICT="${RED}${BLD}CRITIQUE${RST}";      CODE=2
elif [ "$N_WARN" -gt 0 ]; then VERDICT="${YEL}${BLD}AVERTISSEMENT${RST}"; CODE=1
else                           VERDICT="${GRN}${BLD}SAIN${RST}";          CODE=0; fi
emit " Verdict global : $VERDICT"
emit " Bilan : ${GRN}${N_OK} OK${RST} / ${YEL}${N_WARN} WARN${RST} / ${RED}${N_CRIT} CRIT${RST}"
# Pistes de lenteur : reliees aux symptomes detectes (cf. section 13). Affichees
# seulement si au moins une piste a ete trouvee, pour ne pas noyer un systeme sain.
if [ -n "$HINTS" ]; then
    emit ""
    emit " ${BLD}Pistes probables (lenteur)${RST} :"
    # HINTS contient deja une ligne par piste (terminee par \n) ; printf -> emit.
    while IFS= read -r _h; do [ -n "$_h" ] && emit "$_h"; done < <(printf '%s' "$HINTS")
elif [ "$N_WARN" -eq 0 ] && [ "$N_CRIT" -eq 0 ]; then
    emit ""
    emit " Aucun symptome de lenteur detecte (CPU/IO/memoire/swap dans les normes)."
fi
[ -n "$OUTFILE" ] && emit " Rapport ecrit dans : $OUTFILE"
emit "${BLD}============================================================${RST}"

# Ecriture unique du rapport accumule (voir emit/flush_report).
flush_report

# Sortie protegee : la substitution garantit un argument numerique propre meme si
# le transfert du fichier a colle un caractere parasite en fin de ligne.
exit "$(( CODE ))"
# --- FIN DU SCRIPT ---
