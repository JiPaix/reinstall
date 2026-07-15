#!/usr/bin/env bash
# toggle-display.sh — Bascule entre le mode "monitor" (DP-1 + DP-2) et le mode "tv" (HDMI-1)

set -euo pipefail

# ────────────────────────────────────────────────
# Configuration des profils d'affichage (généré par swapscreen-setup)
# ────────────────────────────────────────────────
# Profils générés à partir de la grille interactive. Chaque moniteur est décrit
# en tokens « clé=valeur » séparés par des espaces. Clés :
#   connector  (requis)  ex. DP-1, HDMI-1
#   mode       (requis)  ex. 2560x1440@164.958
#   vrr        true|false           (défaut: false → ajoute +vrr au mode si true)
#   scale      ex. 1.0, 2           (défaut: 1.0)
#   color      bt2100|sdr-native|default  (défaut: default)
#   x, y       position logique     (défaut: 0, 0)
#   primary    true|false           (défaut: false)
#__PROFILES__

# ────────────────────────────────────────────────
# Aide & manuel
# ────────────────────────────────────────────────
show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTION] [--json]

Bascule automatiquement entre le mode "monitor" (DP-1 + DP-2) et le mode
"tv" (HDMI-1) en lisant l'état courant via gdctl.

OPTIONS
  (aucune)       Détecte le mode actif et bascule vers l'autre mode.
                 Si le mode est inconnu, passe en mode tv.

  -s, --show     Affiche le mode actuel (monitor | tv | unknown) et quitte.

  --tv           Force le mode tv  (HDMI-1, 3840×2160@60 ×2).

  --monitor      Force le mode monitor (DP-1 2560×1440@165 + DP-2 1920×1080@60).

  --taiko        Force le mode taiko : profil monitor + DP-3 (1920×1080@144, scale 1)
                 empilé au-dessus de DP-1. Activable UNIQUEMENT via cette option ;
                 jamais atteint en bascule automatique. Rapporté comme « tv » par --show.

  -j, --json     Modifie la sortie en JSON. Combinable avec toute autre option.
                   --show --json    → { "mode": "monitor" }
                   --tv --json      → { "previous": "monitor", "mode": "tv" }
                   (erreur) --json  → { "error": "…" }

  -h, --help     Affiche ce message d'aide et quitte.

  --man          Affiche le manuel complet (format man-page) et quitte.

EXEMPLES
  $(basename "$0")                   # bascule automatique
  $(basename "$0") --show            # → Mode actuel : monitor
  $(basename "$0") --show --json     # → { "mode": "monitor" }
  $(basename "$0") --tv              # force le mode tv
  $(basename "$0") --tv --json       # → { "previous": "monitor", "mode": "tv" }
  $(basename "$0") --json            # bascule + sortie JSON

DÉPENDANCES
  gdctl          — GNOME Display Config (backend gnome)
  kscreen-doctor — KScreen (backend kde)

EOF
}

show_man() {
    man --pager=cat /dev/stdin <<'MANPAGE' 2>/dev/null || show_help
.TH TOGGLE-DISPLAY 1 "$(date +%Y-%m-%d)" "1.0" "Utilitaires d'affichage"
.SH NOM
toggle-display \- bascule entre le mode moniteur et le mode télévision
.SH SYNOPSIS
.B toggle-display
[\fIOPTION\fR] [\fB\-\-json\fR]
.SH DESCRIPTION
.B toggle-display
interroge \fBgdctl\fR pour déterminer quel écran dispose d'un mode actif,
puis applique la configuration opposée (ou forcée) via \fBgdctl set\fR.
.PP
Trois profils sont définis :
.TP
.B monitor
DP-1 en 2560×1440@165 Hz (VRR, BT.2100, primaire) + DP-2 en 1920×1080@60 Hz.
.TP
.B tv
HDMI-1 en 3840×2160@60 Hz, échelle ×2, BT.2100, primaire.
.TP
.B taiko
Profil monitor + DP-3 en 1920×1080@144 Hz (VRR, BT.2100, échelle 1), empilé
au-dessus de DP-1. Activable uniquement via \fB\-\-taiko\fR.
.SH OPTIONS
.TP
.B (aucune)
Détecte le mode courant et bascule automatiquement.
Si le mode est \fIunknown\fR, active le mode tv.
.TP
.BR \-s ", " \-\-show
Affiche le mode actuel sur stdout et quitte.
.TP
.B \-\-tv
Force le profil tv sans tenir compte de l'état courant.
.TP
.B \-\-monitor
Force le profil monitor sans tenir compte de l'état courant.
.TP
.B \-\-taiko
Force le profil taiko (monitor + DP\-3 empilé au\-dessus de DP\-1).
Activable uniquement de façon explicite ; jamais atteint en bascule
automatique. Rapporté comme \fItv\fR par \fB\-\-show\fR.
.TP
.BR \-j ", " \-\-json
Formate toutes les sorties (succès et erreurs) en JSON.
Combinable avec n'importe quelle autre option.
.TP
.BR \-h ", " \-\-help
Affiche un résumé d'aide et quitte.
.TP
.B \-\-man
Affiche cette page de manuel et quitte.
.SH CODES DE RETOUR
.TP
.B 0
Succès.
.TP
.B 1
Argument inconnu ou erreur d'exécution de gdctl.
.SH DÉPENDANCES
.BR gdctl (1)
(backend gnome) ou
.BR kscreen-doctor (1)
(backend kde)
.SH AUTEUR
Configuration personnelle — usage interne.
MANPAGE
}

# ────────────────────────────────────────────────
# Sorties (texte ou JSON selon $JSON_MODE)
# ────────────────────────────────────────────────
JSON_MODE=false

# Positionné par reconcile_profile : true s'il a dû réappliquer le profil (un
# écran hors-profil avait été réactivé par GNOME). Sert à la boucle Sunshine pour
# détecter qu'un restart a perturbé la topologie pendant l'énumération.
_RECONCILE_DIRTY=false

out_show() {       # $1 = mode
    if $JSON_MODE; then
        echo "{ \"mode\": \"$1\" }"
    else
        echo "Mode actuel : $1"
    fi
}

out_switch() {     # $1 = previous, $2 = new mode
    if $JSON_MODE; then
        echo "{ \"previous\": \"$1\", \"mode\": \"$2\" }"
    fi
    # les messages texte sont déjà émis par set_*_mode()
}

out_error() {      # $1 = message
    if $JSON_MODE; then
        echo "{ \"error\": \"$1\" }" >&2
    else
        echo "Erreur : $1" >&2
    fi
}

# ────────────────────────────────────────────────
# Backend (gnome=gdctl, kde=kscreen-doctor)
# ────────────────────────────────────────────────
# BACKEND est injecté par swapscreen-setup en tête du bloc de profils ci-dessus.
# Les fonctions de détection/application ci-dessous aiguillent dessus.
is_kde() { [[ "${BACKEND:-gnome}" == kde ]]; }

# Vrai si $1 figure dans la liste $2… (comparaison exacte).
_in_list() {  # $1 = aiguille, $2.. = meule
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

# ── Contournement de la boucle de détection TV sous KDE ──────────────────────
# Quand une TV est éteinte mais son câble HDMI branché, KWin boucle
# détection→retrait→détection. Le correctif force le statut DRM du connecteur
# (/sys/class/drm/card*-<conn>/status) autour de l'activation kscreen-doctor.
# L'écriture dans /sys exige root ; screen.sh installe (KDE only) un helper root
# + une règle sudoers NOPASSWD pour qu'il marche même hors terminal (service de
# login, bascule déclenchée par Sunshine).
# Le helper émet aussi un uevent hotplug synthétique après chaque écriture :
# une écriture sysfs seule ne génère AUCUN événement, or KWin est purement
# événementiel — un connecteur qu'il a retiré (TV power-cyclée pendant que son
# statut était forcé off) resterait invisible jusqu'au redémarrage de session.
DRM_HELPER=/usr/local/bin/swapscreen-drm

drm_status() {  # $1 = connecteur, $2 = detect|off|on
    if ! sudo -n "$DRM_HELPER" "$1" "$2" 2>/dev/null; then
        $JSON_MODE || echo "⚠ $DRM_HELPER indisponible (sudoers ?) — statut DRM '$2' non appliqué pour $1" >&2
    fi
    return 0
}

# Vrai si kscreen liste le connecteur, quel que soit son état enabled/disabled.
# (KWin peut avoir retiré la sortie de sa liste : dans ce cas kscreen-doctor
# répond « Output ... not found » à toute commande la visant.)
# PAS de `grep -q` en bout de pipe ici : -q quitte au premier match et ferme le
# tube, kscreen-doctor/sed meurent en SIGPIPE (141) et, sous `pipefail`, ce 141
# l'emporte sur le 0 de grep — la fonction renvoyait TOUJOURS faux. grep sans
# -q consomme tout le flux, pas de SIGPIPE.
kde_connector_known() {  # $1 = connecteur
    kscreen_show | grep -E "^Output: [0-9]+ ${1}( |$)" >/dev/null
}

# Vrai si le connecteur est stable côté kernel : statut « connected » ET EDID
# effectivement lisible. (Le fichier sysfs `edid` affiche une taille nulle en
# stat même plein — il faut le lire pour savoir.)
kde_connector_stable() {  # $1 = connecteur
    local d
    for d in /sys/class/drm/card*-"$1"; do
        [[ "$(cat "$d/status" 2>/dev/null)" == connected ]] || continue
        (( $(wc -c < "$d/edid" 2>/dev/null || echo 0) > 0 )) && return 0
    done
    return 1
}

# Vrai si le kernel pilote RÉELLEMENT le connecteur (CRTC actif, sysfs
# `enabled`). Seul signal fiable qu'un écran est allumé : kscreen-doctor
# répond « succès » dès que KWin accepte la config, même si le commit DRM
# échoue ensuite en silence.
kde_connector_lit() {  # $1 = connecteur
    local f
    for f in /sys/class/drm/card*-"$1"/enabled; do
        [[ "$(cat "$f" 2>/dev/null)" == enabled ]] && return 0
    done
    return 1
}

# Réveille la TV si nécessaire et attend qu'elle soit STABLE. Retourne 1 si le
# connecteur n'apparaît pas ou reste instable — il ne faut alors PAS basculer.
#
# Deux phases :
#   1. apparition : si KWin ne liste pas le connecteur (forcé off, ou retiré
#      après un power-cycle), forcer la redétection DRM (uevent inclus via le
#      helper) et attendre. Re-poke toutes les ~6 s seulement : chaque poke
#      force un re-probe qui peut interrompre une négociation EDID en cours.
#   2. stabilité : exiger 3 contrôles consécutifs (1 s d'écart) avec statut
#      kernel « connected » + EDID lisible + connecteur listé par kscreen.
#      Une TV qui vient d'être allumée fait clignoter HPD/EDID pendant
#      plusieurs secondes, et activer la sortie PENDANT ce clignotement fait
#      sombrer KWin dans un état « zéro sortie » (placeholder screen) dont
#      seule une nouvelle session sort — vu en pratique, d'où ce garde-fou.
tv_wake_kde() {  # $1 = connecteur primaire TV → 0 prêt, 1 pas prêt
    local tv="$1"
    [[ -z "$tv" ]] && return 0
    # 45 s : certaines TV (Vestel…) mettent 20-30 s après power-on avant de
    # servir un EDID stable ; il faut encore 3 s de stabilité derrière.
    local start; start=$(date +%s)
    local deadline=$(( start + 45 )) sub stable=0 ready=false
    if ! kde_connector_known "$tv"; then
        while :; do
            drm_status "$tv" detect
            sub=$(( $(date +%s) + 6 ))
            while (( $(date +%s) < sub )); do
                sleep 1
                if kde_connector_known "$tv"; then break 2; fi
            done
            if (( $(date +%s) >= deadline )); then
                $JSON_MODE || echo "⚠ $tv toujours absent de kscreen après redétection — TV éteinte ?" >&2
                return 1
            fi
        done
    fi
    while (( $(date +%s) < deadline )); do
        if kde_connector_stable "$tv" && kde_connector_known "$tv"; then
            if (( ++stable >= 3 )); then
                ready=true
                break
            fi
        else
            stable=0
        fi
        sleep 1
    done
    if ! $ready; then
        $JSON_MODE || echo "⚠ $tv détecté mais instable (HPD/EDID clignotant) — bascule refusée" >&2
        return 1
    fi
    # Détection éclair (≤ 8 s) = la TV était déjà chaude : rien à attendre.
    # Sinon elle vient d'être allumée, et son étage HDMI sert un EDID stable
    # BIEN AVANT de savoir verrouiller un lien 4K@60 : un commit à ~20 s du
    # power-on part dans le vide — kernel OK, chemin audio actif, mais panneau
    # « no signal » définitif, la TV ne réessaie jamais d'elle-même (vérifié).
    # Tous les commits réussis observés avaient la TV allumée depuis ≥ 40 s :
    # on laisse donc la TV finir de démarrer avant de lui envoyer le signal.
    if (( $(date +%s) - start > 8 )); then
        $JSON_MODE || echo "… TV fraîchement allumée — attente de fin de démarrage (20 s)" >&2
        sleep 20
    fi
    return 0
}

# Endort la TV : désactive la sortie puis coupe son statut DRM pour stopper la
# boucle tant qu'on n'est pas en mode tv.
tv_sleep_kde() {  # $1 = connecteur primaire TV
    local tv="$1"
    [[ -z "$tv" ]] && return 0
    kscreen-doctor "output.${tv}.disable" 2>/dev/null || true
    drm_status "$tv" off
}

# Endort la TV UNIQUEMENT si son connecteur primaire n'appartient pas au profil
# cible (jamais couper un écran effectivement utilisé par le profil).
tv_sleep_if_absent() {  # $1 = nom du profil cible
    local tv c; tv="$(profile_primary TV_PROFILE)"
    [[ -z "$tv" ]] && return 0
    while IFS= read -r c; do
        [[ "$c" == "$tv" ]] && return 0
    done < <(profile_connectors "$1")
    tv_sleep_kde "$tv"
}

# ────────────────────────────────────────────────
# Sunshine
# ────────────────────────────────────────────────
# Problème : output_name = N est un index KMS, et cet index dépend de l'ENSEMBLE
# des écrans actifs au moment où Sunshine énumère. Or le restart de Sunshine
# (il prend le DRM master) déclenche un uevent hotplug qui pousse GNOME à
# réactiver un écran hors-profil (typiquement DP-3) APRÈS que reconcile_profile
# a cessé de surveiller. D'où deux symptômes : (1) un écran parasite reste
# allumé, (2) l'index lu pendant cette topologie transitoire est faux et
# Sunshine streame le mauvais écran.
#
# Stratégie convergente (boucle bornée en temps ; reconcile final garanti) :
#   - bootstrap : forcer output_name=0 (toujours valide) pour qu'un éventuel
#     restart avec un ancien index hors-bornes n'échoue pas au démarrage.
#   À chaque tour :
#   1. reconcile_profile : stabiliser la topologie (écran parasite éteint)
#   2. mémoriser l'ensemble actif « settled » + restart de Sunshine
#   3. reconcile_profile À NOUVEAU : si le restart a réveillé un écran, on le
#      rééteint ; _RECONCILE_DIRTY=true signale que l'énumération vient d'une
#      topologie transitoire → on jette ce tour et on recommence
#   4. sinon (topologie stable de bout en bout) : lire l'index du connecteur
#      dans le journal (fallback cache topologie-conscient si invisible)
#   5. si output_name == index → convergé ET vérifié (l'index a été relu sous un
#      restart propre). Sinon écrire l'index ; le tour suivant redémarre pour
#      l'appliquer puis le revérifie.
#
# Le cache n'est utilisé QUE si Sunshine ne voit pas le connecteur dans le
# journal (écran physiquement éteint, ex : TV). Il est indexé par l'ensemble
# actif pour ne jamais rendre un index valable pour une autre topologie.

SUNSHINE_CONFIG="$HOME/.config/sunshine/sunshine.conf"
SUNSHINE_KMS_CACHE="$HOME/.config/sunshine/kms_index_cache"

sunshine_installed() {
    systemctl --user cat sunshine.service &>/dev/null \
        || systemctl --user cat app-dev.lizardbyte.app.Sunshine.service &>/dev/null
}

sunshine_service_name() {
    if systemctl --user cat sunshine.service &>/dev/null; then
        echo "sunshine.service"
    else
        echo "app-dev.lizardbyte.app.Sunshine.service"
    fi
}

# Cache topologie-conscient : l'index KMS d'un connecteur dépend de l'ENSEMBLE des
# écrans actifs (ex. DP-1 = 1 en {DP-1,DP-2} mais 3 en {HDMI-1,DP-1,DP-2,DP-3}).
# La clé est donc « connecteur@ensemble-trié », ex. « DP-1@DP-1,DP-2 ».
sunshine_cache_get() {  # $1 = connector, $2 = set (ex. "DP-1,DP-2") → echo index ou rien
    [[ -f "$SUNSHINE_KMS_CACHE" ]] || return 0
    grep -oP "(?<=^${1}@${2}=)[0-9]+" "$SUNSHINE_KMS_CACHE" 2>/dev/null | tail -1 || true
}

sunshine_cache_set() {  # $1 = connector, $2 = set, $3 = index
    mkdir -p "$(dirname "$SUNSHINE_KMS_CACHE")"
    touch "$SUNSHINE_KMS_CACHE"
    local key="${1}@${2}"
    if grep -q "^${key}=" "$SUNSHINE_KMS_CACHE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${3}|" "$SUNSHINE_KMS_CACHE"
    else
        echo "${key}=${3}" >> "$SUNSHINE_KMS_CACHE"
    fi
}

sunshine_log_index_since() {  # $1 = connector, $2 = since-timestamp → echo index ou rien
    journalctl --user -u "$(sunshine_service_name)" --since "$2" --no-pager 2>/dev/null \
        | grep -oP "Monitor \K[0-9]+(?= is ${1}:)" \
        | tail -1 || true
}

sunshine_config_current_index() {
    grep -oP '^[[:space:]]*output_name[[:space:]]*=[[:space:]]*\K[0-9]+' \
        "$SUNSHINE_CONFIG" 2>/dev/null | tail -1 || true
}

sunshine_config_write_index() {  # $1 = index
    mkdir -p "$(dirname "$SUNSHINE_CONFIG")"
    touch "$SUNSHINE_CONFIG"
    if grep -qE "^[[:space:]]*output_name[[:space:]]*=" "$SUNSHINE_CONFIG" 2>/dev/null; then
        sed -i -E "s|^[[:space:]]*output_name[[:space:]]*=.*|output_name = $1|" "$SUNSHINE_CONFIG"
    else
        echo "output_name = $1" >> "$SUNSHINE_CONFIG"
    fi
}

sunshine_update_output() {  # $1 = nom du profil (MONITOR_PROFILE, TV_PROFILE, …)
    if ! sunshine_installed; then
        return 0  # Sunshine non installé : le caller a déjà réconcilié l'affichage
    fi

    local profile="$1" connector
    connector="$(profile_primary "$profile")"
    local settled since kms_index src cur
    # Budget temps global : la boucle peut enchaîner plusieurs restarts si chacun
    # réveille un écran. On le borne pour rester bien sous le timeout du serveur,
    # et CHAQUE sortie se termine par un reconcile → l'affichage n'est jamais
    # laissé avec un écran parasite, même si Sunshine ne converge pas.
    local overall_deadline=$(( $(date +%s) + 45 ))

    # Laisser DRM se stabiliser après gdctl
    sleep 1

    # Bootstrap : forcer un index TOUJOURS valide (0) avant tout restart. L'ancien
    # output_name correspond au mode PRÉCÉDENT et peut être hors-bornes pour la
    # nouvelle topologie → Sunshine échouerait au démarrage (« Couldn't find
    # monitor [N] » → Fatal) sans jamais loguer « Monitor N is <connector> ».
    if [[ "$(sunshine_config_current_index)" != "0" ]]; then
        sunshine_config_write_index 0
    fi

    while (( $(date +%s) < overall_deadline )); do
        # 1. Stabiliser la topologie avant l'énumération
        reconcile_profile "$profile"
        settled="$(active_set)"

        # 2. Restart : force Sunshine à énumérer la topologie ACTUELLE.
        # Des bascules rapprochées enchaînent les restarts et peuvent déclencher
        # le start-limit systemd — le purger d'abord, sinon le restart échoue.
        since="$(date '+%Y-%m-%d %H:%M:%S')"
        systemctl --user reset-failed "$(sunshine_service_name)" 2>/dev/null || true
        if ! systemctl --user restart "$(sunshine_service_name)"; then
            $JSON_MODE || echo "⚠ Échec du restart de Sunshine — config non mise à jour" >&2
            reconcile_profile "$profile"   # laisser l'affichage propre
            return 1
        fi

        # 3. Le restart a-t-il réveillé un écran hors-profil ? Si oui reconcile
        #    l'a rééteint, mais l'énumération s'est faite sous une topologie
        #    transitoire → l'index lu serait faux, on recommence.
        reconcile_profile "$profile"
        if $_RECONCILE_DIRTY; then
            $JSON_MODE || echo "↻ Le restart de Sunshine a perturbé la topologie — nouvel essai…" >&2
            continue
        fi

        # 4. Topologie stable de bout en bout : lire l'index du connecteur dans
        #    le journal (poll court), sinon fallback cache topologie-conscient.
        kms_index=""
        local poll_deadline=$(( $(date +%s) + 6 ))
        while (( $(date +%s) < poll_deadline )); do
            kms_index="$(sunshine_log_index_since "$connector" "$since")"
            [[ -n "$kms_index" ]] && break
            sleep 0.3
        done

        if [[ -z "$kms_index" ]]; then
            kms_index="$(sunshine_cache_get "$connector" "$settled")"
            if [[ -z "$kms_index" ]]; then
                $JSON_MODE || echo "⚠ KMS index introuvable pour $connector ($settled) — Sunshine conserve son ancienne valeur" >&2
                reconcile_profile "$profile"
                return 0
            fi
            src="cache"
            $JSON_MODE || echo "⚠ $connector pas détecté dans les logs — cache ($settled, index = $kms_index)" >&2
        else
            src="logs"
            sunshine_cache_set "$connector" "$settled" "$kms_index"
        fi

        # 5. Convergence : si output_name vaut déjà l'index lu sous ce restart
        #    propre, c'est correct ET vérifié. Sinon on écrit, et le tour suivant
        #    redémarre pour l'appliquer puis le revérifie.
        cur="$(sunshine_config_current_index)"
        if [[ "$cur" == "$kms_index" ]]; then
            reconcile_profile "$profile"   # filet : un écran a pu se réactiver pendant le poll
            $JSON_MODE || echo "✓ Sunshine sur output_name = $kms_index ($connector, source: $src)"
            return 0
        fi
        sunshine_config_write_index "$kms_index"
    done

    $JSON_MODE || echo "⚠ Sunshine non stabilisé dans le temps imparti (output_name = $(sunshine_config_current_index))" >&2
    reconcile_profile "$profile"   # garantir un affichage propre même sans convergence
}

# ────────────────────────────────────────────────
# Détection du mode actif
# ────────────────────────────────────────────────
# Liste les connecteurs actuellement actifs (ayant un « Current mode »).
active_monitors() {
    if is_kde; then active_monitors_kde; else active_monitors_gnome; fi
}

active_monitors_gnome() {
    local gdctl_output cur=""
    gdctl_output=$(gdctl show 2>/dev/null) || {
        out_error "impossible d'exécuter gdctl show"
        exit 1
    }
    while IFS= read -r line; do
        if [[ "$line" =~ Monitor\ (DP-[0-9]+|HDMI-[0-9]+) ]]; then
            cur="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ "Current mode" && -n "$cur" ]]; then
            echo "$cur"
            cur=""
        fi
    done <<< "$gdctl_output"
}

# `kscreen-doctor -o` en texte, dépouillé d'éventuels codes ANSI (au cas où la
# couleur ne serait pas désactivée quand la sortie n'est pas un terminal).
kscreen_show() { kscreen-doctor -o 2>/dev/null | sed -r 's/\x1b\[[0-9;]*[mK]//g'; }

# Connecteurs actifs sous KDE : chaque bloc « Output: <id> <name> » suivi d'une
# ligne « enabled ». Accepte tout nom DRM (HDMI-A-1, eDP-1, DP-1-1, …).
active_monitors_kde() {
    local out
    out=$(kscreen_show) || { out_error "impossible d'exécuter kscreen-doctor -o"; exit 1; }
    awk '
        /^Output:/ { name=$3; next }
        /^[[:space:]]*enabled[[:space:]]*$/ { if (name != "") { print name; name="" } }
    ' <<< "$out"
}

# Modes disponibles pour un connecteur donné (un par ligne, ex. "2560x1440@164.958",
# "2560x1440@164.958+vrr", …).
connector_modes() {  # $1 = connecteur (ex. DP-1)
    if is_kde; then connector_modes_kde "$1"; else connector_modes_gnome "$1"; fi
}

connector_modes_gnome() {  # $1 = connecteur (ex. DP-1)
    local gdctl_output cur="" want="$1"
    gdctl_output=$(gdctl show -v 2>/dev/null) || return 1
    while IFS= read -r line; do
        if [[ "$line" =~ Monitor\ (DP-[0-9]+|HDMI-[0-9]+) ]]; then
            cur="${BASH_REMATCH[1]}"
            continue
        fi
        [[ "$cur" == "$want" ]] || continue
        [[ "$line" =~ ([0-9]+x[0-9]+@[0-9.]+(\+vrr)?)[[:space:]]*$ ]] && echo "${BASH_REMATCH[1]}"
    done <<< "$gdctl_output"
}

# Modes d'un connecteur sous KDE, extraits de la ligne « Modes: » (tokens
# « id:LxH@RR[*!] ») dépouillés de l'id et des marqueurs courant/préféré.
#
# `-o` imprime la fréquence à 2 décimales (164.96) alors que le mode stocké dans
# le profil est le NOM kscreen, dont la fréquence est arrondie à l'entier (165,
# cf. `-j`). On arrondit donc ici pour que validate_profile puisse comparer les
# deux à l'identique. Plusieurs modes peuvent retomber sur le même nom (60.00 et
# 59.94 → « @60 ») : kscreen fait exactement pareil, les doublons sont sans effet.
connector_modes_kde() {  # $1 = connecteur
    local out; out=$(kscreen_show) || return 1
    awk -v want="$1" '
        /^Output:/ { cur=$3; next }
        cur == want && /Modes:/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /[0-9]+x[0-9]+@[0-9.]+/) {
                    s = $i
                    sub(/^[0-9]+:/, "", s)   # retire "id:"
                    sub(/[*!]+$/, "", s)     # retire les marqueurs courant/préféré
                    if (split(s, p, "@") == 2) printf "%s@%d\n", p[1], (p[2] + 0.5)
                }
            }
        }
    ' <<< "$out"
}

# Garde-fou : vérifie qu'un profil est applicable au matériel actuellement
# détecté (chaque connecteur existe et propose exactement le mode demandé).
# Sans ça, un profil obsolète (câblage changé, script restauré d'une ancienne
# machine) échoue avec le message cryptique de gdctl ("Failed to create
# configuration") au lieu de dire clairement quoi régénérer.
validate_profile() {  # $1 = nom du tableau de profil
    local -n SPECS="$1"
    local rec
    for rec in "${SPECS[@]}"; do
        local -A f; parse_spec "$rec" f
        local conn="${f[connector]}" mode="${f[mode]}"
        # Sous GNOME, VRR est une variante du mode (+vrr) ; sous KDE c'est une
        # propriété à part (vrrpolicy), le nom du mode reste nu.
        ! is_kde && [[ "${f[vrr]}" == true ]] && mode="${mode}+vrr"
        local modes; modes="$(connector_modes "$conn")"
        if [[ -z "$modes" ]]; then
            out_error "connecteur '$conn' introuvable — profil obsolète (câblage changé ?). Relancez ./screen.sh pour régénérer."
            return 1
        fi
        if ! grep -qxF "$mode" <<< "$modes"; then
            out_error "'$conn' ne propose pas le mode '$mode' — profil obsolète (câblage changé ?). Relancez ./screen.sh pour régénérer."
            return 1
        fi
    done
}

# Connecteurs propres au profil taiko : présents dans TAIKO_PROFILE mais pas
# dans MONITOR_PROFILE. Sert de marqueur pour rapporter taiko comme « tv ».
taiko_extra() {
    comm -23 \
        <(profile_connectors TAIKO_PROFILE | sort -u) \
        <(profile_connectors MONITOR_PROFILE | sort -u)
}

get_current_mode() {
    local active tv_primary mon_primary
    active=$(active_monitors)
    tv_primary=$(profile_primary TV_PROFILE)
    mon_primary=$(profile_primary MONITOR_PROFILE)

    # Ordre important : la TV puis les écrans propres à taiko sont rapportés « tv ».
    if grep -qxF "$tv_primary" <<< "$active"; then
        echo "tv"
    elif [[ -n "$(comm -12 <(sort -u <<< "$active") <(taiko_extra))" ]]; then
        echo "tv"
    elif grep -qxF "$mon_primary" <<< "$active"; then
        echo "monitor"
    else
        echo "unknown"
    fi
}

# ────────────────────────────────────────────────
# Profils → arguments gdctl (génériques, pilotés par la config)
# ────────────────────────────────────────────────
# Parse un enregistrement « clé=valeur … » dans le tableau associatif nommé $2,
# en appliquant les valeurs par défaut.
parse_spec() {  # $1=record, $2=nom du tableau associatif (nameref)
    local -n F="$2"
    F=( [vrr]=false [scale]=1.0 [color]=default [x]=0 [y]=0 [primary]=false )
    local tok
    for tok in $1; do
        F["${tok%%=*}"]="${tok#*=}"
    done
}

# Ajoute les flags --logical-monitor … d'un moniteur au tableau nommé $2.
spec_to_args() {  # $1=record, $2=nom du tableau GDCTL (nameref)
    local -A _spec; parse_spec "$1" _spec
    local -n OUT="$2"
    local mode="${_spec[mode]}"
    [[ "${_spec[vrr]}" == true ]] && mode="${mode}+vrr"
    OUT+=( --logical-monitor --monitor "${_spec[connector]}" --mode "$mode" --scale "${_spec[scale]}" )
    [[ "${_spec[primary]}" == true ]] && OUT+=( --primary )
    OUT+=( --color-mode "${_spec[color]}" --x "${_spec[x]}" --y "${_spec[y]}" )
}

# Applique un profil complet (aiguillage backend).
apply_profile() {  # $1 = nom du tableau de profil
    if is_kde; then apply_profile_kde "$1"; else apply_profile_gnome "$1"; fi
}

apply_profile_gnome() {  # $1 = nom du tableau de profil
    local -n SPECS="$1"
    local args=( set --layout-mode physical ) rec
    for rec in "${SPECS[@]}"; do
        spec_to_args "$rec" args
    done
    gdctl "${args[@]}"
}

# Applique un profil sous KDE via kscreen-doctor, en DEUX temps :
#   1. activer + configurer les écrans du profil (les anciens restent allumés) ;
#   2. désactiver les écrans hors profil, dans un appel séparé.
# L'ordre est crucial : la config atomique « activer X + désactiver le reste »
# échoue silencieusement dans KWin quand X vient d'être ré-ajouté (TV
# ressuscitée par la redétection DRM) — KWin éteint les anciens écrans sans
# jamais piloter le nouveau, laissant la session sans AUCUNE sortie active
# (« There are no outputs - creating placeholder screen » en boucle, kscreen ne
# répond plus que des listes vides). Activer d'abord garantit ≥ 1 sortie
# réellement allumée à chaque instant. Le chevauchement transitoire de
# positions entre phases (TV et moniteur tous deux en 0,0) est toléré par KWin
# (vérifié empiriquement). VRR/HDR/WCG sont différés ~10 s après la géométrie
# (étape 3) : « SDR d'abord, HDR une fois le lien verrouillé » — le seul
# enchaînement qui allume une TV fraîchement sortie de veille.
apply_profile_kde() {  # $1 = nom du tableau de profil
    local -n SPECS="$1"
    local -A s
    local ops=() rec conn c allowed=()
    mapfile -t allowed < <(profile_connectors "$1")

    # 1. Activer + géométrie des écrans du profil, en SDR — les propriétés
    # (VRR/HDR/WCG) suivent à l'étape 3, ~10 s après. Séquence « SDR d'abord,
    # HDR une fois le lien verrouillé » : une TV fraîchement allumée synchronise
    # un signal SDR simple (vérifié à froid), et un commit HDR sur lien déjà
    # verrouillé survit (vérifié à 10 s d'écart) — alors que le commit combiné
    # mode+HDR n'a jamais produit d'image sur TV froide (sync HDMI coincée,
    # seule une coupure secteur de la TV la débloque).
    for rec in "${SPECS[@]}"; do
        parse_spec "$rec" s
        c="${s[connector]}"
        ops+=( "output.${c}.enable" \
               "output.${c}.mode.${s[mode]}" \
               "output.${c}.scale.${s[scale]}" \
               "output.${c}.position.${s[x]},${s[y]}" )
        # KDE (Plasma 6) : la sortie de plus haute priorité (1) est la primaire.
        [[ "${s[primary]}" == true ]] && ops+=( "output.${c}.priority.1" )
    done
    kscreen-doctor "${ops[@]}"

    # Garde-fou double avant la phase 2 :
    #  a) le kernel pilote réellement chaque écran du profil (sysfs `enabled`) ;
    #  b) la config KWin a PROPAGÉ : `kscreen-doctor -o` (client frais) liste
    #     ces écrans comme actifs. Indispensable : chaque invocation
    #     kscreen-doctor récupère un instantané de la config, y applique ses
    #     ops et soumet le TOUT (état complet, pas un delta). Si la phase 2
    #     part avant propagation, son instantané PÉRIMÉ (écrans du profil
    #     encore « disabled ») est resoumis tel quel : la phase 1 est annulée
    #     → zéro sortie (placeholder screen) ou rejet « désactivation de
    #     toutes les sorties non autorisée ». Vu en pratique dans les deux
    #     variantes.
    # Si un écran ne s'allume/propage pas dans les 15 s, on abandonne en
    # laissant l'affichage actuel intact — mieux vaut une bascule ratée et
    # signalée qu'une session sans aucune sortie active.
    local gate=$(( $(date +%s) + 15 )) lit act
    while :; do
        lit=true
        mapfile -t act < <(active_monitors_kde)
        for c in "${allowed[@]}"; do
            if ! kde_connector_lit "$c" || ! _in_list "$c" "${act[@]}"; then
                lit=false
                break
            fi
        done
        $lit && break
        if (( $(date +%s) >= gate )); then
            out_error "écran(s) du profil non allumé(s)/propagé(s) après 15 s — bascule abandonnée, affichage actuel conservé"
            return 1
        fi
        sleep 0.5
    done

    # 2. Désactiver les connecteurs actifs absents du profil. (Un `(( )) &&`
    # nu ferait sortir le script via set -e quand la liste est vide — cas
    # normal quand le profil est déjà appliqué, ex. le service de login.)
    ops=()
    while IFS= read -r conn; do
        [[ -z "$conn" ]] && continue
        _in_list "$conn" "${allowed[@]}" || ops+=( "output.${conn}.disable" )
    done < <(active_monitors_kde)
    if (( ${#ops[@]} )); then
        kscreen-doctor "${ops[@]}"
    fi

    # 3. Propriétés différées (VRR/HDR/WCG), par écran, en best-effort.
    # 10 s de settle d'abord — le lock d'un lien 4K@60 peut prendre plusieurs
    # secondes et un commit HDR pendant le lock laisse la TV en « no signal ».
    sleep 10
    for rec in "${SPECS[@]}"; do
        parse_spec "$rec" s
        c="${s[connector]}"
        local extra=()
        [[ "${s[vrr]}" == true ]] && extra+=( "output.${c}.vrrpolicy.automatic" )
        case "${s[color]}" in
            bt2100) extra+=( "output.${c}.hdr.enable" "output.${c}.wcg.enable" ) ;;
            *)      extra+=( "output.${c}.hdr.disable" ) ;;
        esac
        (( ${#extra[@]} )) && { kscreen-doctor "${extra[@]}" 2>/dev/null || true; }
    done
}

# Énumère les connecteurs d'un profil.
profile_connectors() {  # $1 = nom du tableau de profil
    local -n S="$1"; local r t
    for r in "${S[@]}"; do
        for t in $r; do
            [[ $t == connector=* ]] && echo "${t#connector=}"
        done
    done
}

# Connecteur primaire d'un profil (le premier marqué primary=true, sinon le 1er).
profile_primary() {  # $1 = nom du tableau de profil
    local -n S="$1"; local r t conn prim
    for r in "${S[@]}"; do
        conn=""; prim=false
        for t in $r; do
            [[ $t == connector=* ]] && conn="${t#connector=}"
            [[ $t == primary=true ]] && prim=true
        done
        $prim && { echo "$conn"; return; }
    done
    profile_connectors "$1" | head -1
}

# Liste les connecteurs actifs qui ne font PAS partie de l'ensemble autorisé ($@).
active_unexpected_monitors() {  # $@ = connecteurs autorisés
    local desired=" $* " conn
    while IFS= read -r conn; do
        [[ -z "$conn" ]] && continue
        [[ "$desired" == *" $conn "* ]] || echo "$conn"
    done < <(active_monitors)
}

# Boucle de réconciliation : après application d'un profil, GNOME peut ré-activer
# tout seul un moniteur fraîchement (re)branché (typiquement DP-3 au retour du
# mode tv, à cause d'une course au hotplug). On ré-applique le profil tant qu'un
# moniteur hors-profil est actif, en exigeant 2 sondages propres consécutifs.
reconcile_profile() {  # $1 = nom du tableau de profil ; positionne _RECONCILE_DIRTY
    # Sous KDE, drm_status règle la boucle de détection propre à la TV, mais pas
    # les effets de bord d'un uevent DRM global (forcer le statut d'un connecteur
    # peut faire clignoter le bus DDC d'un AUTRE écran, que KWin réactive alors
    # tout seul — vu en pratique avec un DP inutilisé rallumé pendant une
    # bascule --tv → --monitor). Ce garde-fou tourne donc aussi sous KDE.
    _RECONCILE_DIRTY=false
    local allowed
    mapfile -t allowed < <(profile_connectors "$1")
    local deadline=$(( $(date +%s) + 8 ))
    local clean=0 extras
    while (( $(date +%s) < deadline )); do
        extras=$(active_unexpected_monitors "${allowed[@]}")
        if [[ -n "$extras" ]]; then
            $JSON_MODE || echo "↻ $(echo "$extras" | tr '\n' ' ')— réactivé(s) de façon inattendue, réapplication du profil…" >&2
            # || true : un échec du garde-fou d'apply_profile_kde ne doit pas
            # tuer le script via set -e — on retentera au tour suivant.
            apply_profile "$1" || true
            _RECONCILE_DIRTY=true
            clean=0
        else
            (( ++clean >= 2 )) && return 0
        fi
        sleep 0.5
    done
}

# Ensemble trié des connecteurs actuellement actifs, ex. « DP-1,DP-2 ». Sert de
# clé de topologie pour le cache KMS (l'index d'un connecteur en dépend).
active_set() {
    active_monitors | sort -u | paste -sd, -
}

# ────────────────────────────────────────────────
# Application des modes
# ────────────────────────────────────────────────
set_monitor_mode() {
    local previous="$1"
    validate_profile MONITOR_PROFILE || exit 1
    $JSON_MODE || echo "→ Passage en mode monitor ($(profile_connectors MONITOR_PROFILE | tr '\n' ' '))…"
    apply_profile MONITOR_PROFILE
    # KDE : endormir la TV (statut DRM off) si elle ne sert pas dans ce profil.
    is_kde && tv_sleep_if_absent MONITOR_PROFILE
    $JSON_MODE || echo "✓ Mode monitor activé."
    reconcile_profile MONITOR_PROFILE
    # || true : l'affichage a déjà basculé — un souci Sunshine (restart refusé,
    # start-limit…) ne doit pas faire sortir le script en erreur via set -e.
    sunshine_update_output MONITOR_PROFILE || true
    out_switch "$previous" "monitor"
}

set_tv_mode() {
    local previous="$1"
    # KDE : réveiller la TV (redétection DRM) AVANT de valider le profil.
    # Après un passage en mode monitor, le connecteur TV est forcé à l'état
    # "off" (tv_sleep_kde) ; sans ce réveil préalable, validate_profile ne le
    # trouve pas dans `kscreen-doctor -o` et échoue à tort avec « profil
    # obsolète » — alors que le câblage n'a pas bougé, il fallait juste réveiller
    # le connecteur.
    if is_kde && ! tv_wake_kde "$(profile_primary TV_PROFILE)"; then
        out_error "la TV n'est pas prête (connecteur absent ou instable) — bascule annulée, réessayez dans quelques secondes"
        exit 1
    fi
    validate_profile TV_PROFILE || exit 1
    $JSON_MODE || echo "→ Passage en mode tv ($(profile_connectors TV_PROFILE | tr '\n' ' '))…"
    apply_profile TV_PROFILE
    $JSON_MODE || echo "✓ Mode tv activé."
    reconcile_profile TV_PROFILE
    sunshine_update_output TV_PROFILE || true
    out_switch "$previous" "tv"
}

set_taiko_mode() {
    local previous="$1"
    validate_profile TAIKO_PROFILE || exit 1
    $JSON_MODE || echo "→ Passage en mode taiko ($(profile_connectors TAIKO_PROFILE | tr '\n' ' '))…"
    apply_profile TAIKO_PROFILE
    # KDE : endormir la TV (statut DRM off) si elle ne sert pas dans ce profil.
    is_kde && tv_sleep_if_absent TAIKO_PROFILE
    $JSON_MODE || echo "✓ Mode taiko activé."
    reconcile_profile TAIKO_PROFILE
    sunshine_update_output TAIKO_PROFILE || true
    # taiko est rapporté comme « tv » par get_current_mode : on reste cohérent.
    out_switch "$previous" "tv"
}

# ────────────────────────────────────────────────
# Point d'entrée
# ────────────────────────────────────────────────
main() {
    local action=""

    # Passe 1 : extraire les flags
    for arg in "$@"; do
        case "$arg" in
            -j|--json) JSON_MODE=true ;;
            -h|--help|--man|-s|--show|--tv|--monitor|--taiko) action="$arg" ;;
            *)
                out_error "option inconnue : '$arg'"
                $JSON_MODE || echo "Lancez '$(basename "$0") --help' pour la liste des options." >&2
                exit 1
                ;;
        esac
    done

    # Passe 2 : exécuter l'action
    case "$action" in
        -h|--help)
            show_help
            ;;
        --man)
            show_man
            ;;
        -s|--show)
            out_show "$(get_current_mode)"
            ;;
        --tv)
            set_tv_mode "$(get_current_mode)"
            ;;
        --monitor)
            set_monitor_mode "$(get_current_mode)"
            ;;
        --taiko)
            set_taiko_mode "$(get_current_mode)"
            ;;
        "")
            local current
            current=$(get_current_mode)
            case "$current" in
                monitor) set_tv_mode      "$current" ;;
                tv)      set_monitor_mode "$current" ;;
                unknown)
                    $JSON_MODE || echo "Mode inconnu — passage en mode tv." >&2
                    set_tv_mode "$current"
                    ;;
            esac
            ;;
    esac
}

main "$@"
