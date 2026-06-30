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
  gdctl  — outil de contrôle GNOME Display Config

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

        # 2. Restart : force Sunshine à énumérer la topologie ACTUELLE
        since="$(date '+%Y-%m-%d %H:%M:%S')"
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

# Applique un profil complet via gdctl set.
apply_profile() {  # $1 = nom du tableau de profil
    local -n SPECS="$1"
    local args=( set --layout-mode physical ) rec
    for rec in "${SPECS[@]}"; do
        spec_to_args "$rec" args
    done
    gdctl "${args[@]}"
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
    _RECONCILE_DIRTY=false
    local allowed
    mapfile -t allowed < <(profile_connectors "$1")
    local deadline=$(( $(date +%s) + 8 ))
    local clean=0 extras
    while (( $(date +%s) < deadline )); do
        extras=$(active_unexpected_monitors "${allowed[@]}")
        if [[ -n "$extras" ]]; then
            $JSON_MODE || echo "↻ $(echo "$extras" | tr '\n' ' ')— réactivé(s) par GNOME, réapplication du profil…" >&2
            apply_profile "$1"
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
    $JSON_MODE || echo "→ Passage en mode monitor ($(profile_connectors MONITOR_PROFILE | tr '\n' ' '))…"
    apply_profile MONITOR_PROFILE
    $JSON_MODE || echo "✓ Mode monitor activé."
    reconcile_profile MONITOR_PROFILE
    sunshine_update_output MONITOR_PROFILE
    out_switch "$previous" "monitor"
}

set_tv_mode() {
    local previous="$1"
    $JSON_MODE || echo "→ Passage en mode tv ($(profile_connectors TV_PROFILE | tr '\n' ' '))…"
    apply_profile TV_PROFILE
    $JSON_MODE || echo "✓ Mode tv activé."
    reconcile_profile TV_PROFILE
    sunshine_update_output TV_PROFILE
    out_switch "$previous" "tv"
}

set_taiko_mode() {
    local previous="$1"
    $JSON_MODE || echo "→ Passage en mode taiko ($(profile_connectors TAIKO_PROFILE | tr '\n' ' '))…"
    apply_profile TAIKO_PROFILE
    $JSON_MODE || echo "✓ Mode taiko activé."
    reconcile_profile TAIKO_PROFILE
    sunshine_update_output TAIKO_PROFILE
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
