#!/usr/bin/env bash
# Bash tab completion for the arr CLI
#
# To enable, add one of the following to your ~/.bashrc:
#
#   source /volume1/docker/arr-barr/.cli/completions.bash
#
# Or if arr is installed and ARR_HOME is set:
#
#   source "$ARR_HOME/.cli/completions.bash"

_arr_complete() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Top-level commands
    local commands="setup status start stop restart update doctor downloads dashboard vpn logs backup health request help"
    local aliases="st up doc dl db log bk hp req"

    # Service names
    local services="gluetun transmission sabnzbd prowlarr flaresolverr radarr sonarr lidarr bazarr jellyfin seerr lazylibrarian kavita audiobookshelf questarr"

    # Service groups (for restart)
    local groups="vpn downloads"

    case "${COMP_WORDS[1]:-}" in
        logs|log)
            # Complete service names, then flags
            if [ "$COMP_CWORD" -eq 2 ]; then
                COMPREPLY=( $(compgen -W "$services" -- "$cur") )
            elif [ "$COMP_CWORD" -eq 3 ]; then
                COMPREPLY=( $(compgen -W "-f --follow -n --tail" -- "$cur") )
            fi
            return
            ;;
        start)
            if [ "$COMP_CWORD" -eq 2 ]; then
                COMPREPLY=( $(compgen -W "$services" -- "$cur") )
            fi
            return
            ;;
        stop)
            if [ "$COMP_CWORD" -eq 2 ]; then
                COMPREPLY=( $(compgen -W "$services" -- "$cur") )
            fi
            return
            ;;
        restart)
            if [ "$COMP_CWORD" -eq 2 ]; then
                COMPREPLY=( $(compgen -W "$services $groups" -- "$cur") )
            fi
            return
            ;;
        downloads|dl)
            COMPREPLY=( $(compgen -W "--once --live" -- "$cur") )
            return
            ;;
        backup|bk)
            if [ "$COMP_CWORD" -eq 2 ]; then
                COMPREPLY=( $(compgen -W "--list --prune --help" -- "$cur") )
            fi
            return
            ;;
        request|req)
            if [ "$COMP_CWORD" -eq 2 ]; then
                COMPREPLY=( $(compgen -W "movie tv music book audiobook author game" -- "$cur") )
            fi
            return
            ;;
        dashboard|db)
            # dashboard takes no arguments
            return
            ;;
        health|hp)
            # health takes no arguments
            return
            ;;
        status|st|setup|update|up|doctor|doc|vpn|help)
            # These commands take no arguments
            return
            ;;
    esac

    # Complete top-level commands
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "$commands $aliases" -- "$cur") )
    fi
}

complete -F _arr_complete arr
