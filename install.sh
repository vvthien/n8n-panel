#!/bin/bash

# install.sh - Cai dat Cong cu N8N Host

# --- Dinh nghia mau sac va bien ---
RED='\e[1;31m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
CYAN='\e[1;36m'
NC='\e[0m'

# !!! THAY DOI URL NAY thanh link tai script cua ban !!!
SCRIPT_URL="https://cloudfly.vn/download/n8n-host/n8n-host.sh" # VI DU: Link raw GitHub

SCRIPT_NAME="n8n-host" #path/to/script/name
# Khuyen nghi dung /usr/local/bin cho script tuy chinh
INSTALL_DIR="/usr/local/bin"
INSTALL_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"
TEMP_SCRIPT="/tmp/${SCRIPT_NAME}.sh.$$" 
TEMPLATE_FILE_NAME="import-workflow-credentials.json" 

# --- Ham kiem tra quyen root ---
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "\n${RED}[!] Loi: Ban can chay script cai dat nay voi quyen root (sudo).${NC}\n"
    exit 1
  fi
}

# --- Ham kiem tra lenh (curl hoac wget) ---
check_downloader() {
    if command -v curl &> /dev/null; then
        DOWNLOADER="curl"
    elif command -v wget &> /dev/null; then
        DOWNLOADER="wget"
    else
        echo -e "${RED}[!] Loi: Khong tim thay 'curl' hoac 'wget'. Vui long cai dat mot trong hai cong cu nay.${NC}"
        exit 1
    fi
    echo -e "${GREEN}[*] Su dung '$DOWNLOADER' de tai file.${NC}"
}

# --- Ham tai script ---
download_script() {
    echo -e "${YELLOW}[*] Dang tai script tu: ${SCRIPT_URL}${NC}"
    if [[ "$DOWNLOADER" == "curl" ]]; then
        # Tai file bang curl, theo doi redirect (-L), bao loi neu fail (-f), im lang (-s), output vao file tam (-o)
        curl -fsSL -o "$TEMP_SCRIPT" "$SCRIPT_URL"
        local download_status=$?
    else # wget
        # Tai file bang wget, output vao file tam (-O), im lang (-q)
        wget -qO "$TEMP_SCRIPT" "$SCRIPT_URL"
        local download_status=$?
    fi

    if [[ $download_status -ne 0 ]]; then
        echo -e "${RED}[!] Loi: Tai script that bai (kiem tra URL hoac ket noi mang).${NC}"
        rm -f "$TEMP_SCRIPT" # Xoa file tam neu co loi
        exit 1
    fi

    # Kiem tra xem file tai ve co noi dung khong
    if [[ ! -s "$TEMP_SCRIPT" ]]; then
        echo -e "${RED}[!] Loi: File tai ve rong (kiem tra URL).${NC}"
        rm -f "$TEMP_SCRIPT"
        exit 1
    fi

    echo -e "${GREEN}[+] Tai script thanh cong.${NC}"
}

# --- Ham cai dat ---
install_script() {
    echo -e "${YELLOW}[*] Bat dau qua trinh cai dat...${NC}"

    # 1. Kiem tra quyen root
    check_root

    # 2. Kiem tra cong cu tai file
    check_downloader

    # 3. Tai script ve file tam
    download_script

    # 4. Tao thu muc cai dat neu chua co
    if [[ ! -d "$INSTALL_DIR" ]]; then
        echo -e "${YELLOW}[*] Tao thu muc cai dat: ${INSTALL_DIR}${NC}"
        # Su dung sudo vi tao thu muc trong he thong
        if ! sudo mkdir -p "$INSTALL_DIR"; then
            echo -e "${RED}[!] Loi: Khong the tao thu muc ${INSTALL_DIR}.${NC}"
            rm -f "$TEMP_SCRIPT"
            exit 1
        fi
    fi

    # 5. Di chuyen script vao thu muc cai dat
    echo -e "${YELLOW}[*] Di chuyen script den: ${INSTALL_PATH}${NC}"
    if ! sudo mv "$TEMP_SCRIPT" "$INSTALL_PATH"; then
        echo -e "${RED}[!] Loi: Khong the di chuyen script den ${INSTALL_PATH}.${NC}"
        rm -f "$TEMP_SCRIPT" # Van co gang xoa file tam
        exit 1
    fi

    # 6. Cap quyen thuc thi cho script
    echo -e "${YELLOW}[*] Cap quyen thuc thi cho script...${NC}"
    if ! sudo chmod +x "$INSTALL_PATH"; then
        echo -e "${RED}[!] Loi: Khong the cap quyen thuc thi cho ${INSTALL_PATH}.${NC}"
        # Co the can go bo file da copy neu khong cap quyen duoc? Tuy chon.
        # sudo rm -f "$INSTALL_PATH"
        exit 1
    fi

    # 7. Tao thu muc n8n-templates ngang hang voi root va tai ve file template
    echo -e "${YELLOW}[*] Tao thu muc n8n-templates...${NC}"
    if [[ ! -d "/n8n-templates" ]]; then
        sudo mkdir -p "/n8n-templates"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}[!] Loi: Khong the tao thu muc /n8n-templates.${NC}"
            exit 1
        fi
    fi
    echo -e "${YELLOW}[*] Tai ve file template...${NC}"

    curl -fsSL -o "/n8n-templates/${TEMPLATE_FILE_NAME}" "https://cloudfly.vn/download/n8n-host/templates/${TEMPLATE_FILE_NAME}"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[!] Loi: Khong the tai ve file template.${NC}"
        exit 1
    fi
    
    # 8. Kiem tra lai
    if [[ -f "$INSTALL_PATH" && -x "$INSTALL_PATH" ]]; then
        echo -e "\n${GREEN}[+++] Cai dat thanh cong! ${NC}"
        echo -e "Ban co the chay cong cu bang lenh: ${CYAN}${SCRIPT_NAME}${NC}"
        echo -e "De go bo, chay lenh: ${CYAN}${SCRIPT_NAME} --uninstall${NC}"
    else
        echo -e "\n${RED}[!] Cai dat that bai. Khong tim thay file thuc thi tai ${INSTALL_PATH}.${NC}"
        exit 1
    fi
}

# Kiem tra xem script da duoc cai dat chua
if [[ -f "$INSTALL_PATH" ]]; then
    echo -e "${YELLOW}[!] Cong cu '${SCRIPT_NAME}' duong nhu da duoc cai dat tai '${INSTALL_PATH}'.${NC}"
    echo -e "Neu ban muon cai dat lai, hay chay: ${CYAN}bash $0 --force-install${NC}"
    echo -e "Neu ban muon go bo, hay chay: ${CYAN}${SCRIPT_NAME} --uninstall${NC}"
    exit 1
else
    # Neu chua cai dat, tien hanh cai dat
    install_script
fi

exit 0
