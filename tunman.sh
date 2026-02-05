#!/bin/bash

# ==============================================================================
# Project : TunMan (Tunnel Manager)
# Description : Tunnel Manager
# Version : 1.1.0
# ==============================================================================

# --- Global Config ---
INSTALL_PATH="/usr/local/bin/tunman"
CONFIG_DIR="/etc/tunman"
SERVICE_TEMPLATE="/etc/systemd/system/tunman@.service"
REPO_URL="https://raw.githubusercontent.com/MrMstafa/tunman/main/tunman.sh"

# --- IP Allocation Rules ---
# UDP   -> 192.168.100.x
# IP    -> 10.10.10.x
# VXLAN -> 172.16.20.x

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error : Please run as root (sudo)${NC}"
        exit 1
    fi
}

install_kernel_extras() {
    echo -e "${YELLOW}[System] Kernel modules missing Attempting to install extras...${NC}"
    KERNEL_VER=$(uname -r)
    
    if command -v apt-get &> /dev/null; then
        apt-get update -y -q
        if ! apt-get install -y -q "linux-modules-extra-$KERNEL_VER"; then
            apt-get install -y -q linux-image-extra-virtual
        fi
        
    elif command -v dnf &> /dev/null; then
        dnf install -y kernel-modules-extra
        
    elif command -v yum &> /dev/null; then
        yum install -y kernel-modules-extra
    fi
    
    depmod -a
}

install_dependencies() {
    if ! command -v ip &> /dev/null || ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}[Init] Installing dependencies...${NC}"
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
        if ! modprobe $mod > /dev/null 2>&1; then
            MISSING_MODS=1
        fi
    done

    if [[ $MISSING_MODS -eq 1 ]]; then
        install_kernel_extras
    fi

    echo -e "${CYAN}[Init] Loading kernel modules...${NC}"
    for mod in $REQUIRED_MODS; do
        if ! modprobe $mod > /dev/null 2>&1; then
            echo -e "${RED}Error : Failed to load module '$mod'.${NC}"
            echo -e "${YELLOW}Hint : If you are on OpenVZ/LXC, this is not supported. Use KVM/VMware.${NC}"
        fi
    done
}

self_install() {
    if [[ "$0" == "$INSTALL_PATH" ]]; then
        return
    fi

    echo -e "${CYAN}[Install] Installing TunMan to system path...${NC}"
    mkdir -p "$CONFIG_DIR"

    if [[ -f "$0" ]]; then
        cp "$0" "$INSTALL_PATH"
    else
        echo -e "${YELLOW}Downloading latest version from GitHub...${NC}"
        if ! curl -sL "$REPO_URL" -o "$INSTALL_PATH"; then
             echo -e "${RED}Error : Download failed. Check internet connection.${NC}"
             exit 1
        fi
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
    echo -e "${GREEN}[Success] Installed ! You can now run 'tunman' anywhere.${NC}"
    sleep 1
}

run_service() {
    local TYPE=$1
    local CONF_FILE="$CONFIG_DIR/${TYPE}.conf"

    if [[ -f "$CONF_FILE" ]]; then
        source "$CONF_FILE"
    else
        echo "Error : Config file for $TYPE not found"
        exit 1
    fi

    if [[ -z "$MTU" ]]; then
        case "$TYPE" in
            "udp")   MTU=1420 ;;
            "ip")    MTU=1460 ;;
            "vxlan") MTU=1450 ;;
            *)       MTU=1400 ;;
        esac
    fi

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
            ip addr flush dev l2tpeth0 2>/dev/null
            ip addr add 192.168.100.${MY_SUFFIX}/30 dev l2tpeth0
            ;;
        "ip")
            ip l2tp del tunnel tunnel_id 2000 2>/dev/null
            ip l2tp add tunnel tunnel_id 2000 peer_tunnel_id 2000 encap ip local $BIND_LOCAL remote $BIND_REMOTE
            ip l2tp add session tunnel_id 2000 session_id 2000 peer_session_id 2000
            ip link set l2tpeth1 up mtu $MTU
            ip addr flush dev l2tpeth1 2>/dev/null
            ip addr add 10.10.10.${MY_SUFFIX}/30 dev l2tpeth1
            ;;
        "vxlan")
            ip link del vxlan_tun 2>/dev/null
            MAIN_IF=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
            ip link add vxlan_tun type vxlan id 5000 local $BIND_LOCAL remote $BIND_REMOTE dstport 4789 dev $MAIN_IF
            ip link set vxlan_tun up mtu $MTU
            ip addr flush dev vxlan_tun 2>/dev/null
            ip addr add 172.16.20.${MY_SUFFIX}/30 dev vxlan_tun
            ;;
    esac

    echo "Tunnel $TYPE is ACTIVE with MTU $MTU"
    while true; do sleep 60; done
}

configure_tunnel() {
    local TYPE=$1
    local CONF_FILE="$CONFIG_DIR/${TYPE}.conf"
    
    clear
    echo -e "${CYAN}=== Configuring Tunnel : ${TYPE^^} ===${NC}"
    
    DETECTED_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    
    echo -e "Where is THIS server located for this tunnel ?"
    echo "1) IRAN    "
    echo "2) KHAREJ  "
    read -p "Select [1-2] : " LOC_OPT

    if [[ "$LOC_OPT" == "1" ]]; then ROLE="IRAN"; else ROLE="KHAREJ"; fi

    echo "------------------------------------------------"
    if [[ -n "$DETECTED_IP" ]]; then
        echo -e "Detected Local IP : ${GREEN}$DETECTED_IP${NC}"
        read -p "Press [ENTER] to confirm, or type custom IP : " USER_INPUT
        LOCAL_PUB_IP=${USER_INPUT:-$DETECTED_IP}
    else
        read -p "Enter THIS server's Public IP : " LOCAL_PUB_IP
    fi

    echo "------------------------------------------------"
    read -p "Enter REMOTE server's Public IP (Target) : " REMOTE_PUB_IP

    echo "------------------------------------------------"
    
    case "$TYPE" in
        "udp")   SUGGESTED_MTU=1420 ;; 
        "ip")    SUGGESTED_MTU=1460 ;; 
        "vxlan") SUGGESTED_MTU=1450 ;; 
    esac

    echo -e "Suggested MTU for $TYPE is ${GREEN}$SUGGESTED_MTU${NC}"
    read -p "Press [ENTER] to accept ($SUGGESTED_MTU) or type value : " USER_MTU
    MTU=${USER_MTU:-$SUGGESTED_MTU}

    cat <<EOF > "$CONF_FILE"
ROLE="$ROLE"
LOCAL_PUB_IP="$LOCAL_PUB_IP"
REMOTE_PUB_IP="$REMOTE_PUB_IP"
MTU="$MTU"
EOF
    echo -e "${GREEN}Configuration for $TYPE saved!${NC}"
    sleep 1
}

change_mtu() {
    local TYPE=$1
    local CONF_FILE="$CONFIG_DIR/${TYPE}.conf"
    
    if [[ ! -f "$CONF_FILE" ]]; then return; fi
    source "$CONF_FILE"

    echo "------------------------------------------------"
    echo -e "Current MTU : ${YELLOW}$MTU${NC}"
    
    case "$TYPE" in
        "udp")   HINT="(Standard : 1420)" ;;
        "ip")    HINT="(Standard : 1460)" ;;
        "vxlan") HINT="(Standard : 1450)" ;;
    esac
    
    read -p "Enter new MTU value $HINT : " NEW_MTU
    
    if [[ -n "$NEW_MTU" ]]; then
        if grep -q "MTU=" "$CONF_FILE"; then
             sed -i "s/MTU=.*/MTU=\"$NEW_MTU\"/" "$CONF_FILE"
        else
             echo "MTU=\"$NEW_MTU\"" >> "$CONF_FILE"
        fi
        echo -e "${GREEN}MTU updated to $NEW_MTU${NC}"
        
        read -p "Restart tunnel to apply ? [y/N] : " RST
        if [[ "$RST" =~ ^[Yy]$ ]]; then systemctl restart "tunman@$TYPE"; fi
    fi
}

is_active() { systemctl is-active --quiet "tunman@$1"; }
is_configured() { [[ -f "$CONFIG_DIR/$1.conf" ]]; }

get_state_label() {
    local TYPE=$1
    if ! is_configured "$TYPE"; then
        echo -e "${YELLOW}Not Configured${NC}"
    elif is_active "$TYPE"; then
        echo -e "${GREEN}● ACTIVE${NC}"
    else
        echo -e "${RED}○ STOPPED${NC}"
    fi
}

manage_tunnel_menu() {
    local TYPE=$1
    local NAME=$2
    local CONF_FILE="$CONFIG_DIR/${TYPE}.conf"
    local PEER_IP=$3

    while true; do
        clear
        echo -e "${CYAN}Manage : $NAME${NC}"
        
        if is_configured "$TYPE"; then
            source "$CONF_FILE"
            CURR_MTU=${MTU:-"Auto"}
            
            echo -e "Status :      $(get_state_label $TYPE)"
            echo "----------------------------------------"
            echo -e "Role :        $ROLE"
            echo -e "Local IP :    $LOCAL_PUB_IP"
            echo -e "Remote IP :   $REMOTE_PUB_IP"
            echo -e "MTU :         $CURR_MTU"
            echo "----------------------------------------"
            echo "1) Start / Enable"
            echo "2) Stop"
            echo "3) Re-Configure (IPs & MTU)"
            echo "4) Change MTU Only"
            echo "5) Remove Config & Disable"
            echo "6) Test Connectivity"
        else
            echo -e "Status :      ${YELLOW}Not Configured${NC}"
            echo "----------------------------------------"
            echo "1) Configure Now"
        fi
        echo "0) Back"
        
        read -p "Select : " ACT
        
        if ! is_configured "$TYPE"; then
            case $ACT in
                1) configure_tunnel "$TYPE" ;;
                0) return ;;
            esac
            continue
        fi

        case $ACT in
            1)
                systemctl enable "tunman@$TYPE"
                systemctl restart "tunman@$TYPE"
                echo "Started"
                sleep 1
                ;;
            2)
                systemctl stop "tunman@$TYPE"
                echo "Stopped"
                sleep 1
                ;;
            3)
                configure_tunnel "$TYPE"
                echo -e "${YELLOW}Note : Restart tunnel to apply changes${NC}"
                read -p "Restart now ? [y/N] : " RST
                if [[ "$RST" =~ ^[Yy]$ ]]; then systemctl restart "tunman@$TYPE"; fi
                ;;
            4)
                change_mtu "$TYPE"
                ;;
            5)
                systemctl stop "tunman@$TYPE"
                systemctl disable "tunman@$TYPE"
                rm "$CONF_FILE"
                echo "Config removed"
                sleep 1
                ;;
            6)
                if is_active "$TYPE"; then
                    echo "Pinging $PEER_IP..."
                    ping -c 4 $PEER_IP
                else
                    echo -e "${RED}Tunnel is not running${NC}"
                fi
                read -p "Press Enter..."
                ;;
            0) return ;;
        esac
    done
}

main_menu() {
    while true; do
        clear
        echo -e "${CYAN}TunMan${NC} | Tunnel Manager"
        echo "========================================================"
        echo -e "1) L2TPv3 UDP   [ $(get_state_label udp) ]"
        echo -e "2) L2TPv3 IP    [ $(get_state_label ip)  ]"
        echo -e "3) VXLAN        [ $(get_state_label vxlan) ]"
        echo "========================================================"
        echo "u) Uninstall All"
        echo "q) Quit"
        
        read -p "Select Tunnel : " OPT
        case $OPT in
            1) manage_tunnel_menu "udp" "L2TPv3 UDP" "192.168.100.x" ;;
            2) manage_tunnel_menu "ip" "L2TPv3 Raw IP" "10.10.10.x" ;;
            3) manage_tunnel_menu "vxlan" "VXLAN Tunnel" "172.16.20.x" ;;
            [Uu]) 
                systemctl disable --now tunman@udp tunman@ip tunman@vxlan 2>/dev/null
                rm -rf "$CONFIG_DIR" "$INSTALL_PATH" "$SERVICE_TEMPLATE"
                systemctl daemon-reload
                echo "Uninstalled"
                exit 0 ;;
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
