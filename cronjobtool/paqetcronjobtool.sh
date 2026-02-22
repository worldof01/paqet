#!/bin/bash

# ============================================
# Paqet CronJob Manager
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

AUTORESTART_MARKER="PAQET_AUTORESTART"
INTERVAL_RESULT=""   # global — avoids $() stdin breakage

print_header() {
    echo -e "\n${CYAN}=====================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}=====================================${NC}\n"
}
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info()    { echo -e "${BLUE}[i]${NC} $1"; }

# ── Check root ───────────────────────────────────────────────
check_root() {
    [[ $EUID -ne 0 ]] && { print_error "Please run with sudo"; exit 1; }
}

# ── Get list of paqet services ───────────────────────────────
get_paqet_services() {
    local svcs=()
    for sf in /etc/systemd/system/paqet-*.service; do
        [ -f "$sf" ] || continue
        svcs+=("$(basename "$sf" .service)")
    done
    echo "${svcs[@]}"
}

# ── Get ALL cronjob lines for a service ──────────────────────
get_cron_for_service() {
    local svc="$1"
    crontab -l 2>/dev/null | grep -F "# $AUTORESTART_MARKER $svc" || true
}

# ── Count cronjob entries for a service ──────────────────────
count_cron_entries() {
    local svc="$1"
    local cnt
    cnt=$(crontab -l 2>/dev/null | grep -cF "# $AUTORESTART_MARKER $svc" 2>/dev/null || echo 0)
    echo "${cnt:-0}"
}

# ── Parse interval (minutes) from a cron line ────────────────
get_cron_interval() {
    local line="$1"
    local schedule
    schedule=$(echo "$line" | awk '{print $1}')
    if [[ "$schedule" == "*" ]]; then
        echo "1"
    else
        echo "${schedule#*/}"
    fi
}

# ── Remove ALL cronjob entries for a service ─────────────────
remove_cron_for_service() {
    local svc="$1"
    ( crontab -l 2>/dev/null || true ) \
        | grep -vF "# $AUTORESTART_MARKER $svc" \
        | crontab - 2>/dev/null || true
}

# ── Scan and fix ALL duplicate entries in crontab ────────────
fix_all_duplicates() {
    local svcs=( $(get_paqet_services) )
    for svc in "${svcs[@]}"; do
        local cnt; cnt=$(count_cron_entries "$svc")
        if [ "$cnt" -gt 1 ]; then
            print_warning "Duplicate cronjob detected for '$svc' ($cnt entries). Fixing..."
            local last_line
            last_line=$(crontab -l 2>/dev/null \
                | grep -F "# $AUTORESTART_MARKER $svc" | tail -1)
            remove_cron_for_service "$svc"
            if [ -n "$last_line" ]; then
                ( crontab -l 2>/dev/null || true; echo "$last_line" ) | crontab -
            fi
            print_success "Fixed: '$svc' now has exactly 1 entry."
        fi
    done
}

# ── Add/replace cronjob — guaranteed no duplicates ───────────
add_cron_for_service() {
    local svc="$1"
    local mins="$2"
    local schedule
    if [[ "$mins" -eq 1 ]]; then
        schedule="* * * * *"
    else
        schedule="*/$mins * * * *"
    fi
    local line="$schedule /bin/systemctl restart $svc >/dev/null 2>&1 # $AUTORESTART_MARKER $svc"
    remove_cron_for_service "$svc"
    ( crontab -l 2>/dev/null || true; echo "$line" ) | crontab -
    # Sanity check
    local cnt; cnt=$(count_cron_entries "$svc")
    if [ "$cnt" -gt 1 ]; then
        print_warning "Unexpected duplicate after adding. Fixing..."
        fix_all_duplicates
    fi
}

# ── Check existing cron before add — ask confirmation ────────
# Returns 0 = proceed, 1 = cancel
check_existing_cron_before_add() {
    local svc="$1"
    local cnt; cnt=$(count_cron_entries "$svc")
    [ "$cnt" -eq 0 ] && return 0

    local existing_line; existing_line=$(get_cron_for_service "$svc" | head -1)
    local existing_interval; existing_interval=$(get_cron_interval "$existing_line")

    echo ""
    echo -e " ${YELLOW}────────────────────────────────────────${NC}"
    if [ "$cnt" -eq 1 ]; then
        print_warning "Service '$svc' already has a cronjob:"
        echo -e "   ${CYAN}Interval : every ${existing_interval} minute(s)${NC}"
        echo -e "   ${BLUE}Entry    :${NC} $existing_line"
    else
        print_warning "Service '$svc' has $cnt duplicate entries!"
        crontab -l 2>/dev/null | grep -F "# $AUTORESTART_MARKER $svc" \
            | while IFS= read -r l; do echo -e "   ${RED}→${NC} $l"; done
    fi
    echo -e " ${YELLOW}────────────────────────────────────────${NC}"
    echo ""
    read -p " Replace existing cronjob? [y/N]: " _ans
    _ans=$(echo "${_ans:-n}" | tr '[:upper:]' '[:lower:]')
    [ "$_ans" = "y" ] && return 0 || return 1
}

# ── Ask interval — result stored in $INTERVAL_RESULT ─────────
# NOT called inside $() — uses global var to avoid stdin issues
ask_interval() {
    local current="${1:-}"
    local _r=""
    INTERVAL_RESULT=""
    [ -n "$current" ] && \
        echo -e " ${BLUE}[i]${NC} Current interval: ${CYAN}${current} minute(s)${NC}"
    while true; do
        read -r -p " Restart every how many minutes? (1-1440): " _r
        _r=$(echo "${_r:-}" | tr -d '[:space:]')
        if [[ "$_r" =~ ^[0-9]+$ ]] && [ "$_r" -ge 1 ] && [ "$_r" -le 1440 ]; then
            INTERVAL_RESULT="$_r"
            return 0
        fi
        print_warning "Please enter a number between 1 and 1440."
    done
}

# ============================================
# Menu 1: List services + quick manage
# ============================================
menu_list_services() {
    print_header "Services & Cronjob Status"

    fix_all_duplicates 2>/dev/null || true

    local svcs=( $(get_paqet_services) )

    if [ ${#svcs[@]} -eq 0 ]; then
        print_warning "No paqet services found."
        echo ""; read -r -p "Press Enter to go back..." _
        return
    fi

    local i=1
    local has_no_cron=()

    for svc in "${svcs[@]}"; do
        local st; st=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        local cron_line; cron_line=$(get_cron_for_service "$svc" | head -1)
        local cnt; cnt=$(count_cron_entries "$svc")
        local st_color="$RED"
        [ "$st" = "active" ] && st_color="$GREEN"

        echo -e " ${WHITE}${i})${NC} ${CYAN}${svc}${NC}"
        echo -e "    Service Status : ${st_color}${st}${NC}"

        if [ -n "$cron_line" ]; then
            local interval; interval=$(get_cron_interval "$cron_line")
            echo -e "    Cronjob        : ${GREEN}✓ Active${NC} — every ${CYAN}${interval}${NC} minute(s)"
            echo -e "    ${BLUE}└─${NC} ${cron_line}"
            [ "$cnt" -gt 1 ] && \
                echo -e "    ${RED}⚠  WARNING: $cnt duplicate entries (auto-fixed)${NC}"
        else
            echo -e "    Cronjob        : ${RED}✗ Not set${NC}"
            has_no_cron+=("$svc")
        fi
        echo ""
        ((i++))
    done

    if [ ${#has_no_cron[@]} -gt 0 ]; then
        echo -e "${YELLOW}────────────────────────────────────────${NC}"
        echo -e " ${YELLOW}[!]${NC} The following services have no cronjob:"
        for svc in "${has_no_cron[@]}"; do
            echo -e "     • ${WHITE}$svc${NC}"
        done
        echo ""
        read -r -p " Would you like to add a cronjob for them? [y/N]: " _ans
        _ans=$(echo "${_ans:-n}" | tr '[:upper:]' '[:lower:]')
        if [ "$_ans" = "y" ]; then
            for svc in "${has_no_cron[@]}"; do
                echo ""
                echo -e " ${CYAN}──── $svc ────${NC}"
                ask_interval
                add_cron_for_service "$svc" "$INTERVAL_RESULT"
                print_success "Cronjob added: $svc — every $INTERVAL_RESULT minute(s)"
            done
        fi
    fi

    echo ""; read -r -p "Press Enter to go back..." _
}

# ============================================
# Menu 2: Edit / change cronjob interval
# ============================================
menu_edit_cron() {
    print_header "Edit Cronjob Interval"

    fix_all_duplicates 2>/dev/null || true

    local svcs=( $(get_paqet_services) )
    local cron_svcs=()

    for svc in "${svcs[@]}"; do
        local cron_line; cron_line=$(get_cron_for_service "$svc" | head -1)
        [ -n "$cron_line" ] && cron_svcs+=("$svc")
    done

    if [ ${#cron_svcs[@]} -eq 0 ]; then
        print_warning "No active cronjobs found."
        echo ""; read -r -p "Press Enter to go back..." _
        return
    fi

    echo -e " ${CYAN}Services with active cronjobs:${NC}\n"
    local i=1
    for svc in "${cron_svcs[@]}"; do
        local cron_line; cron_line=$(get_cron_for_service "$svc" | head -1)
        local interval; interval=$(get_cron_interval "$cron_line")
        echo -e " ${WHITE}${i})${NC} ${CYAN}${svc}${NC} ${YELLOW}(every ${interval} minute(s))${NC}"
        ((i++))
    done

    echo ""
    local choice=""
    while true; do
        read -r -p " Select service (1-${#cron_svcs[@]}): " choice
        choice=$(echo "${choice:-}" | tr -d '[:space:]')
        [[ "$choice" =~ ^[0-9]+$ ]] && \
        [ "$choice" -ge 1 ] && [ "$choice" -le "${#cron_svcs[@]}" ] && break
        print_warning "Please enter a valid number."
    done

    local selected="${cron_svcs[$((choice-1))]}"
    local cron_line; cron_line=$(get_cron_for_service "$selected" | head -1)
    local current_interval; current_interval=$(get_cron_interval "$cron_line")

    echo ""
    echo -e " ${CYAN}──── Editing: $selected ────${NC}"
    echo -e " ${BLUE}[i]${NC} Current entry:"
    echo -e "   ${CYAN}${cron_line}${NC}"

    ask_interval "$current_interval"

    add_cron_for_service "$selected" "$INTERVAL_RESULT"
    print_success "Cronjob updated: $selected — every $INTERVAL_RESULT minute(s)"

    echo ""
    echo -e " ${BLUE}New cron entry:${NC}"
    get_cron_for_service "$selected" | while IFS= read -r line; do
        echo -e "  ${GREEN}${line}${NC}"
    done

    local final_cnt; final_cnt=$(count_cron_entries "$selected")
    if [ "$final_cnt" -gt 1 ]; then
        print_warning "Unexpected duplicates ($final_cnt). Fixing..."
        fix_all_duplicates
        print_success "Duplicates resolved."
    fi

    echo ""; read -r -p "Press Enter to go back..." _
}

# ============================================
# Menu 3: Remove cronjob
# ============================================
menu_remove_cron() {
    print_header "Remove Cronjob"

    local svcs=( $(get_paqet_services) )
    local cron_svcs=()

    for svc in "${svcs[@]}"; do
        local cron_line; cron_line=$(get_cron_for_service "$svc" | head -1)
        [ -n "$cron_line" ] && cron_svcs+=("$svc")
    done

    if [ ${#cron_svcs[@]} -eq 0 ]; then
        print_warning "No active cronjobs found."
        echo ""; read -r -p "Press Enter to go back..." _
        return
    fi

    echo -e " ${CYAN}Services with active cronjobs:${NC}\n"
    local i=1
    for svc in "${cron_svcs[@]}"; do
        local cron_line; cron_line=$(get_cron_for_service "$svc" | head -1)
        local interval; interval=$(get_cron_interval "$cron_line")
        local cnt; cnt=$(count_cron_entries "$svc")
        echo -e " ${WHITE}${i})${NC} ${CYAN}${svc}${NC} ${YELLOW}(every ${interval} minute(s))${NC}"
        echo -e "    ${BLUE}└─${NC} ${cron_line}"
        [ "$cnt" -gt 1 ] && \
            echo -e "    ${RED}⚠  $cnt duplicate entries — all will be removed${NC}"
        echo ""
        ((i++))
    done

    echo -e " ${WHITE}$((${#cron_svcs[@]}+1)))${NC} ${RED}Remove ALL cronjobs${NC}"
    echo ""

    local choice=""
    while true; do
        read -r -p " Select (1-$((${#cron_svcs[@]}+1))): " choice
        choice=$(echo "${choice:-}" | tr -d '[:space:]')
        [[ "$choice" =~ ^[0-9]+$ ]] && \
        [ "$choice" -ge 1 ] && [ "$choice" -le $((${#cron_svcs[@]}+1)) ] && break
        print_warning "Please enter a valid number."
    done

    if [ "$choice" -eq $((${#cron_svcs[@]}+1)) ]; then
        read -r -p " Are you sure? All cronjobs will be removed. [y/N]: " _confirm
        _confirm=$(echo "${_confirm:-n}" | tr '[:upper:]' '[:lower:]')
        if [ "$_confirm" = "y" ]; then
            for svc in "${cron_svcs[@]}"; do
                remove_cron_for_service "$svc"
                local remaining; remaining=$(count_cron_entries "$svc")
                if [ "$remaining" -eq 0 ]; then
                    print_success "Removed: $svc"
                else
                    print_warning "Could not fully remove '$svc' ($remaining remain)"
                fi
            done
        else
            print_info "Cancelled."
        fi
    else
        local selected="${cron_svcs[$((choice-1))]}"
        local cnt; cnt=$(count_cron_entries "$selected")
        [ "$cnt" -gt 1 ] && \
            print_warning "This service has $cnt duplicate entries — all will be removed."
        read -r -p " Remove cronjob for '$selected'? [y/N]: " _confirm
        _confirm=$(echo "${_confirm:-n}" | tr '[:upper:]' '[:lower:]')
        if [ "$_confirm" = "y" ]; then
            remove_cron_for_service "$selected"
            local remaining; remaining=$(count_cron_entries "$selected")
            if [ "$remaining" -eq 0 ]; then
                print_success "Cronjob removed: $selected"
            else
                print_warning "Could not fully remove '$selected' ($remaining remain)"
            fi
        else
            print_info "Cancelled."
        fi
    fi

    echo ""; read -r -p "Press Enter to go back..." _
}

# ============================================
# Menu 4: Add cronjob manually
# ============================================
menu_add_cron() {
    print_header "Add Cronjob"

    fix_all_duplicates 2>/dev/null || true

    local svcs=( $(get_paqet_services) )

    if [ ${#svcs[@]} -eq 0 ]; then
        print_warning "No paqet services found."
        echo ""; read -r -p "Press Enter to go back..." _
        return
    fi

    echo -e " ${CYAN}Available services:${NC}\n"
    local i=1
    for svc in "${svcs[@]}"; do
        local cron_line; cron_line=$(get_cron_for_service "$svc" | head -1)
        local st; st=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        local st_color="$RED"; [ "$st" = "active" ] && st_color="$GREEN"
        local cnt; cnt=$(count_cron_entries "$svc")

        echo -e " ${WHITE}${i})${NC} ${CYAN}${svc}${NC} [${st_color}${st}${NC}]"
        if [ -n "$cron_line" ]; then
            local interval; interval=$(get_cron_interval "$cron_line")
            echo -e "    ${YELLOW}⚠  Has cronjob: every ${interval} minute(s) — will be replaced if confirmed${NC}"
            [ "$cnt" -gt 1 ] && \
                echo -e "    ${RED}⚠  $cnt duplicate entries (will all be replaced)${NC}"
        else
            echo -e "    ${GREEN}✓  No cronjob — ready to add${NC}"
        fi
        echo ""
        ((i++))
    done

    local choice=""
    while true; do
        read -r -p " Select service (1-${#svcs[@]}): " choice
        choice=$(echo "${choice:-}" | tr -d '[:space:]')
        [[ "$choice" =~ ^[0-9]+$ ]] && \
        [ "$choice" -ge 1 ] && [ "$choice" -le "${#svcs[@]}" ] && break
        print_warning "Please enter a valid number."
    done

    local selected="${svcs[$((choice-1))]}"
    echo ""
    echo -e " ${CYAN}──── $selected ────${NC}"

    if ! check_existing_cron_before_add "$selected"; then
        print_info "Operation cancelled. Cronjob unchanged."
        echo ""; read -r -p "Press Enter to go back..." _
        return
    fi

    ask_interval

    add_cron_for_service "$selected" "$INTERVAL_RESULT"
    print_success "Cronjob set: $selected — every $INTERVAL_RESULT minute(s)"

    echo ""
    echo -e " ${BLUE}Registered cron entry:${NC}"
    get_cron_for_service "$selected" | while IFS= read -r line; do
        echo -e "  ${GREEN}${line}${NC}"
    done

    local final_cnt; final_cnt=$(count_cron_entries "$selected")
    if [ "$final_cnt" -gt 1 ]; then
        print_warning "Unexpected duplicates ($final_cnt). Fixing..."
        fix_all_duplicates
        print_success "Duplicates resolved."
    else
        print_success "Verified: exactly 1 cronjob entry for $selected."
    fi

    echo ""; read -r -p "Press Enter to go back..." _
}

# ============================================
# Main menu
# ============================================
main_menu() {
    check_root
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║   Paqet CronJob Manager by worldof01  ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e " ${WHITE}1)${NC} ${GREEN}List services & cronjob status${NC}"
        echo -e " ${WHITE}2)${NC} ${CYAN}Add cronjob to a service${NC}"
        echo -e " ${WHITE}3)${NC} ${YELLOW}Edit / change cronjob interval${NC}"
        echo -e " ${WHITE}4)${NC} ${RED}Remove cronjob${NC}"
        echo -e " ${WHITE}5)${NC} ${RED}about${NC}"
        echo -e " ${WHITE}0)${NC} Exit"
        echo ""

        local svcs=( $(get_paqet_services) )
        local total=${#svcs[@]}
        local with_cron=0
        local with_dup=0
        for svc in "${svcs[@]}"; do
            local cl; cl=$(get_cron_for_service "$svc" | head -1)
            local cnt; cnt=$(count_cron_entries "$svc")
            [ -n "$cl" ] && ((with_cron++))
            [ "$cnt" -gt 1 ] && ((with_dup++))
        done

        echo -e "${CYAN}────────────────────────────────────────${NC}"
        echo -e " Total: ${WHITE}${total}${NC}  With cronjob: ${GREEN}${with_cron}${NC}  Without: ${RED}$((total - with_cron))${NC}"
        [ "$with_dup" -gt 0 ] && \
            echo -e " ${RED}⚠  Duplicates detected: $with_dup service(s) — open option 1 to fix${NC}"
        echo -e "${CYAN}────────────────────────────────────────${NC}"
        echo ""

        read -r -p " Select: " choice
        choice=$(echo "${choice:-}" | tr -d '[:space:]')

        case "$choice" in
            1) menu_list_services ;;
            2) menu_add_cron ;;
            3) menu_edit_cron ;;
            4) menu_remove_cron ;;
        5)
            clear
            print_logo
            echo -e "${BCYAN}╔════════════════════════════════════════════════════╗${NC}"
            echo -e "${BCYAN}║${NC}                    ${BPURPLE}ABOUT SCRIPT${NC}                    ${BCYAN}║${NC}"
            echo -e "${BCYAN}╠════════════════════════════════════════════════════╣${NC}"
            echo -e "${BCYAN}║${NC} ${BWHITE}This tool manages paqet cronjobs  ${NC}                 ${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC} ${BWHITE}Code by: ${BGREEN}worldof01${NC}                                 ${BCYAN}║${NC}"            
            echo -e "${BCYAN}║${NC} ${BWHITE}GitHub : ${BLUE}https://github.com/worldof01${NC}              ${BCYAN}║${NC}"
            echo -e "${BCYAN}╠════════════════════════════════════════════════════╣${NC}"
            echo -e "${BCYAN}║${NC}                    ${BYELLOW}DONATE (TON)${NC}                    ${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC} ${BWHITE}Buy me a coffee if you liked it!${NC}                   ${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}                                                    ${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC} ${BYELLOW}Tonkeeper Wallet Address:${NC}                          ${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}                                                    ${BCYAN}║${NC}"
            
            PAD="          "
            echo -e "${BCYAN}║${NC}${PAD}${BBLUE}  ▄▄▄▄▄▄▄  ▄   ▄▄▄ ▄▄▄▄▄▄▄      ${NC}${PAD}${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}${PAD}${BBLUE}  █ ▄▄▄ █ ▀ ▀█▄▀██ █ ▄▄▄ █      ${NC}${PAD}${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}${PAD}${BBLUE}  █ ███ █ ▀█▀ ▄▀ █ █ ███ █      ${NC}${PAD}${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}${PAD}${BBLUE}  █▄▄▄▄▄█ █ █ █▀▄█ █▄▄▄▄▄█      ${NC}${PAD}${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}${PAD}${BBLUE}  ▄▄▄▄  ▄ ▄▄▄▄▀ ▄▄   ▄ ▄ ▄      ${NC}${PAD}${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}${PAD}${BBLUE}  █▀▄▀▀ ▄▀█▀▀▀▀█▀▄▀▄▀▄█▀ █      ${NC}${PAD}${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}${PAD}${BBLUE}  █ █▀▀▄▄  █▀▀ ▀▄█ █▄ █ ▀█      ${NC}${PAD}${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}${PAD}${BBLUE}  ▄▄▄▄▄▄▄ █▄▄ ▀▄▀█ ▄ █ ▀▀█      ${NC}${PAD}${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}${PAD}${BBLUE}  █ ▄▄▄ █ ▄ █▄█ ▄█▄▄▄█ █▄█      ${NC}${PAD}${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}${PAD}${BBLUE}  █ ███ █ █▀▄▀ ▀▄▀ █▄▀█▀▄█      ${NC}${PAD}${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}${PAD}${BBLUE}  ▀▀▀▀▀▀▀ ▀   ▀  ▀   ▀   ▀      ${NC}${PAD}${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}                                                    ${BCYAN}║${NC}"
            echo -e "${BCYAN}║${NC}  ${GREEN}UQAykVgirxEyv8cgHAgpPGXwzUYFwviRZWS1QMGwx3KDHrsV${NC}  ${BCYAN}║${NC}"
            echo -e "${BCYAN}╚════════════════════════════════════════════════════╝${NC}"
            echo ""
            read -p "Press Enter to return..."
            ;;
             
            0) echo ""; print_info "Exiting..."; exit 0 ;;
            *) print_warning "Invalid option."; sleep 1 ;;
        esac
    done
}

main_menu
