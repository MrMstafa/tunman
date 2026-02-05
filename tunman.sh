#!/bin/bash

# ==============================================================================
# Project : TunMan (Tunnel Manager)
# Description : Tunnel Manager
# Version : 1.2.0
# ==============================================================================

# --- Global Config ---
INSTALL_PATH="/usr/local/bin/tunman"
CONFIG_DIR="/etc/tunman"
SERVICE_TEMPLATE="/etc/systemd/system/tunman@.service"
REPO_URL="https://raw.githubusercontent.com/MrMstafa/tunman/main/tunman.sh"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
nc='\033[0m'

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error : Please run as root (sudo)${nc}"
        exit 1
    fi
}

install_dependencies() {
    if ! command -v ip &> /dev/null || ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}[Init] Installing dependencies...${nc}"
        if command -v apt-get &> /dev/null; then
            apt-get update -y -q > /dev/null 2>&1
            apt-get install -y -q iproute2 kmod curl > /dev/null 2>&1
        elif command -v dnf &> /dev/null; then
            dnf install -y iproute kmod curl > /dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y iproute kmod curl > /dev/null 2>&1
        fi
    fi

    REQUIRED_MODS="l2tp_core l2tp_netlink l2tp_eth vxlan"
    MISSING_MODS=0
    for mod in $REQUIRED_MODS; do
        if ! modprobe $mod > /dev/null 2>&1; then MISSING_MODS=1; fi
    done

    if [[ $MISSING_MODS -eq 1 ]]; then
        echo -e "${YELLOW}[System] Missing kernel modules. Installing extras...${nc}"
        KERNEL_VER=$(uname -r)
        if command -v apt-get &> /dev/null; then
            apt-get install -y -q "linux-modules-extra-$KERNEL_VER" > /dev/null 2>&1 || apt-get install -y -q linux-image-extra-virtual > /dev/null 2>&1
        elif command -v dnf &> /dev/null; then
            dnf install -y kernel-modules-extra > /dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y kernel-modules-extra > /dev/null 2>&1
        fi

        for mod in $REQUIRED_MODS; do modprobe $mod > /dev/null 2>&1; done
    fi
}

self_install() {
    if [[ "$0" == "$INSTALL_PATH" ]]; then
        return
    fi

    echo -e "${CYAN}[Install] Installing TunMan to system path...${nc}"
    mkdir -p "$CONFIG_DIR"

    if [[ -f "$0" ]]; then
        cp "$0" "$INSTALL_PATH"
    else
        echo -e "${YELLOW}Downloading latest version from GitHub...${nc}"
        rm -f "$INSTALL_PATH"
        if ! curl -sL "$REPO_URL" -o "$INSTALL_PATH"; then
             echo -e "${RED}Error : Download failed. Check internet connection.${nc}"
             exit 1
        fi
    fi

    if [[ ! -s "$INSTALL_PATH" ]]; then
        echo -e "${RED}Error: Install failed (File empty)${nc}"
        exit 1
    fi

    chmod +x "$INSTALL_PATH"

    cat <<EOF > "$SERVICE_TEMPLATE"
[Unit]
Description=TunMan Service [%i]
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH run_service %i
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    echo -e "${GREEN}[Success] Installed successfully !${nc}"
    sleep 1
    
    exec "$INSTALL_PATH"
}

run_service() {
    local TYPE=$1
    local CONF_FILE="$CONFIG_DIR/${TYPE}.conf"

    if [[ ! -f "$CONF_FILE" ]]; then
        echo "Error: Config file not found."
        exit 1
    fi

    source "$CONF_FILE"

    if [[ -z "$MTU" ]]; then
        case "$TYPE" in
            "udp") MTU=1420 ;; "ip") MTU=1460 ;; "vxlan") MTU=1450 ;; *) MTU=1400 ;;
        esac
    fi

    # Role Logic
    if [[ "$ROLE" == "KHAREJ" ]]; then
        BIND_LOCAL=$LOCAL_PUB_IP
        BIND_REMOTE=$REMOTE_PUB_IP
        MY_SUFFIX="1"
    else
        BIND_LOCAL=$LOCAL_PUB_IP
        BIND_REMOTE=$REMOTE_PUB_IP
        MY_SUFFIX="2"
    fi

    case "$TYPE" in
        "udp")
            ip l2tp del tunnel tunnel_id 1000 2>/dev/null
            ip l2tp add tunnel tunnel_id 1000 peer_tunnel_id 1000 encap udp local $BIND_LOCAL remote $BIND_REMOTE udp_sport 5001 udp_dport 5001
            ip l2tp add session tunnel_id 1000 session_id 1000 peer_session_id 1000
            ip link set l2tpeth0 up mtu $MTU
            sleep 0.2
            ip addr flush dev l2tpeth0 2>/dev/null
            ip addr add 192.168.100.${MY_SUFFIX}/30 dev l2tpeth0
            ;;
        "ip")
            ip l2tp del tunnel tunnel_id 2000 2>/dev/null
            ip l2tp add tunnel tunnel_id 2000 peer_tunnel_id 2000 encap ip local $BIND_LOCAL remote $BIND_REMOTE
            ip l2tp add session tunnel_id 2000 session_id 2000 peer_session_id 2000
            ip link set l2tpeth1 up mtu $MTU
            sleep 0.2
            ip addr flush dev l2tpeth1 2>/dev/null
            ip addr add 10.10.10.${MY_SUFFIX}/30 dev l2tpeth1
            ;;
        "vxlan")
            ip link del vxlan_tun 2>/dev/null
            MAIN_IF=$(ip route get 8.8.8.8 | grep -oP '(?<=dev )[^ ]*' | head -1)
            ip link add vxlan_tun type vxlan id 5000 local $BIND_LOCAL remote $BIND_REMOTE dstport 4789 dev $MAIN_IF
            ip link set vxlan_tun up mtu $MTU
            sleep 0.2
            ip addr flush dev vxlan_tun 2>/dev/null
            ip addr add 172.16.20.${MY_SUFFIX}/30 dev vxlan_tun
            ;;
    esac

    echo "Tunnel $TYPE Active. IP : ...${MY_SUFFIX}"
    while true; do sleep 60; done
}

get_tunnel_info() {
    local TYPE=$1
    local CONF_FILE="$CONFIG_DIR/${TYPE}.conf"
    
    MY_TUN_IP="Unknown"
    PEER_TUN_IP="Unknown"
    
    if [[ -f "$CONF_FILE" ]]; then
        (
            source "$CONF_FILE"
            if [[ "$ROLE" == "IRAN" ]]; then
                L_SUF="2"; R_SUF="1"
            else
                L_SUF="1"; R_SUF="2"
            fi

            case "$TYPE" in
                "udp")   BASE="192.168.100" ;;
                "ip")    BASE="10.10.10" ;;
                "vxlan") BASE="172.16.20" ;;
            esac
            
            echo "$BASE.$L_SUF|$BASE.$R_SUF"
        )
    fi
}

configure_tunnel() {
    local TYPE=$1
    local CONF_FILE="$CONFIG_DIR/${TYPE}.conf"
    
    clear
    echo -e "${CYAN}=== Configuring Tunnel : ${TYPE^^} ===${nc}"
    
    DETECTED_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP '(?<=src )[^ ]*')
    
    echo -e "Where is THIS server located ?"
    echo "1) IRAN  "
    echo "2) KHAREJ"
    read -p "Select [1-2] : " LOC_OPT

    if [[ "$LOC_OPT" == "1" ]]; then ROLE="IRAN"; else ROLE="KHAREJ"; fi

    echo "------------------------------------------------"
    if [[ -n "$DETECTED_IP" ]]; then
        echo -e "Detected Local IP : ${GREEN}$DETECTED_IP${nc}"
        read -p "Press [ENTER] to confirm, or type custom IP : " USER_INPUT
        LOCAL_PUB_IP=${USER_INPUT:-$DETECTED_IP}
    else
        read -p "Enter THIS server's Public IP : " LOCAL_PUB_IP
    fi

    echo "------------------------------------------------"
    read -p "Enter REMOTE server's Public IP (Target) : " REMOTE_PUB_IP

    echo "------------------------------------------------"
    case "$TYPE" in
        "udp") SUGGESTED_MTU=1420 ;; "ip") SUGGESTED_MTU=1460 ;; "vxlan") SUGGESTED_MTU=1450 ;;
    esac
    echo -e "Suggested MTU : ${GREEN}$SUGGESTED_MTU${nc}"
    read -p "Press [ENTER] to accept or type value : " USER_MTU
    MTU=${USER_MTU:-$SUGGESTED_MTU}

    cat <<EOF > "$CONF_FILE"
ROLE="$ROLE"
LOCAL_PUB_IP="$LOCAL_PUB_IP"
REMOTE_PUB_IP="$REMOTE_PUB_IP"
MTU="$MTU"
EOF
    echo -e "${GREEN}Configuration saved !${nc}"
    sleep 1
}

change_mtu() {
    local TYPE=$1
    local CONF_FILE="$CONFIG_DIR/${TYPE}.conf"
    if [[ ! -f "$CONF_FILE" ]]; then return; fi
    source "$CONF_FILE"

    echo -e "Current MTU : ${YELLOW}$MTU${nc}"
    read -p "Enter new MTU : " NEW_MTU
    if [[ -n "$NEW_MTU" ]]; then
        sed -i '/MTU=/d' "$CONF_FILE"
        echo "MTU=\"$NEW_MTU\"" >> "$CONF_FILE"
        echo -e "${GREEN}Updated.${nc}"
        read -p "Restart tunnel? [y/N] : " RST
        if [[ "$RST" =~ ^[Yy]$ ]]; then systemctl restart "tunman@$TYPE"; fi
    fi
}

is_active() { systemctl is-active --quiet "tunman@$1"; }
is_configured() { [[ -f "$CONFIG_DIR/$1.conf" ]]; }

manage_tunnel_menu() {
    local TYPE=$1
    local NAME=$2
    local CONF_FILE="$CONFIG_DIR/${TYPE}.conf"

    while true; do
        clear
        echo -e "${CYAN}Manage : $NAME${nc}"
        echo "========================================"
        
        if is_configured "$TYPE"; then
            source "$CONF_FILE"
            CURR_MTU=${MTU:-"Auto"}
            IFS='|' read -r MY_TUN_IP PEER_TUN_IP <<< "$(get_tunnel_info $TYPE)"

            STATUS_STR=$(is_active "$TYPE" && echo -e "${GREEN}● ACTIVE${nc}" || echo -e "${RED}○ STOPPED${nc}")

            printf "%-18s %s\n" "Status :" "$STATUS_STR"
            printf "%-18s %s\n" "Role :" "$ROLE"
            echo "----------------------------------------"
            printf "%-18s ${YELLOW}%s${nc}\n" "Local Public :" "$LOCAL_PUB_IP"
            printf "%-18s ${YELLOW}%s${nc}\n" "Remote Public :" "$REMOTE_PUB_IP"
            echo "----------------------------------------"
            printf "%-18s ${GREEN}%s${nc}\n" "My Tunnel IP :" "$MY_TUN_IP"
            printf "%-18s ${CYAN}%s${nc}\n" "Peer Tunnel IP :" "$PEER_TUN_IP"
            printf "%-18s %s\n" "MTU :" "$CURR_MTU"
            echo "========================================"
            
            echo "1) Start / Enable"
            echo "2) Stop"
            echo "3) Re-Configure (IPs & MTU)"
            echo "4) Change MTU Only"
            echo "5) Remove Config & Disable"
            echo "6) Test Connectivity (Ping Peer)"
        else
            echo -e "Status : ${YELLOW}Not Configured${nc}"
            echo "----------------------------------------"
            echo "1) Configure Now"
        fi
        echo "0) Back"
        
        read -p "Select : " ACT
        
        if ! is_configured "$TYPE"; then
            [[ "$ACT" == "1" ]] && configure_tunnel "$TYPE"
            [[ "$ACT" == "0" ]] && return
            continue
        fi

        case $ACT in
            1) systemctl enable --now "tunman@$TYPE"; echo "Started."; sleep 2 ;;
            2) systemctl stop "tunman@$TYPE"; echo "Stopped."; sleep 1 ;;
            3) configure_tunnel "$TYPE"; read -p "Restart? [y/N]: " R; [[ $R =~ ^[Yy]$ ]] && systemctl restart "tunman@$TYPE" ;;
            4) change_mtu "$TYPE" ;;
            5) systemctl disable --now "tunman@$TYPE"; rm "$CONF_FILE"; echo "Removed."; sleep 1 ;;
            6) 
                IFS='|' read -r MY_TUN_IP PEER_TUN_IP <<< "$(get_tunnel_info $TYPE)"
                if is_active "$TYPE"; then
                    echo "Pinging Peer ($PEER_TUN_IP)..."
                    ping -c 4 -W 1 "$PEER_TUN_IP"
                else
                    echo -e "${RED}Tunnel is not running.${nc}"
                fi
                read -p "Enter..." ;;
            0) return ;;
        esac
    done
}

get_status_short() {
    if ! is_configured "$1"; then echo -e "${YELLOW}Not Configured${nc}"; 
    elif is_active "$1"; then echo -e "${GREEN}ACTIVE${nc}"; 
    else echo -e "${RED}STOPPED${nc}"; fi
}

main_menu() {
    while true; do
        clear
        echo -e "${CYAN}TunMan${nc} | Tunnel Manager v1.2.0"
        echo "========================================================"
        echo -e "1) L2TPv3 UDP   [ $(get_status_short udp) ]"
        echo -e "2) L2TPv3 IP    [ $(get_status_short ip)  ]"
        echo -e "3) VXLAN        [ $(get_status_short vxlan) ]"
        echo "========================================================"
        echo "u) Uninstall All"
        echo "q) Quit"
        
        read -p "Select : " OPT
        case $OPT in
            1) manage_tunnel_menu "udp" "L2TPv3 UDP" ;;
            2) manage_tunnel_menu "ip" "L2TPv3 Raw IP" ;;
            3) manage_tunnel_menu "vxlan" "VXLAN Tunnel" ;;
            [Uu]) 
                systemctl disable --now tunman@udp tunman@ip tunman@vxlan 2>/dev/null
                rm -rf "$CONFIG_DIR" "$INSTALL_PATH" "$SERVICE_TEMPLATE"
                systemctl daemon-reload
                echo "Uninstalled."; exit 0 ;;
            [Qq]) exit 0 ;;
        esac
    done
}

if [[ "$1" == "run_service" ]]; then
    run_service "$2"
else
    check_root
    install_dependencies
    self_install
    main_menu
fi
