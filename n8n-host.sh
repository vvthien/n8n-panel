#!/bin/bash

# --- Dinh nghia mau sac ---
RED='\e[1;31m'     # Mau do (dam)
GREEN='\e[1;32m'   # Mau xanh la (dam)
YELLOW='\e[1;33m'  # Mau vang (dam)
CYAN='\e[1;36m'    # Mau xanh cyan (dam)
NC='\e[0m'        # Reset mau (tro ve binh thuong)

# --- Bien Global ---
N8N_DIR="/n8n-cloud" # Thu muc chua toan bo cai dat N8N
ENV_FILE="${N8N_DIR}/.env"
DOCKER_COMPOSE_FILE="${N8N_DIR}/docker-compose.yml"
DOCKER_COMPOSE_CMD="docker compose" 
SPINNER_PID=0 
N8N_CONTAINER_NAME="n8n_app" 
N8N_SERVICE_NAME="n8n" 
NGINX_EXPORT_INCLUDE_DIR="/etc/nginx/n8n_export_includes" 
NGINX_EXPORT_INCLUDE_FILE_BASENAME="n8n_export_location" 
TEMPLATE_DIR="/n8n-templates" # Thu muc chua template tren host
TEMPLATE_FILE_NAME="import-workflow-credentials.json" # Ten file template
INSTALL_PATH="/usr/local/bin/n8n-host" # Duong dan cai dat script

# --- Ham Kiem tra ---
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "\n${RED}[!] Loi: Ban can chay script voi quyen Quan tri vien (root).${NC}\n"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_package_installed() {
  dpkg -s "$1" &> /dev/null
}

# --- Ham Phu tro ---
get_public_ip() {
  local ip
  ip=$(curl -s --ipv4 https://ifconfig.co) || \
  ip=$(curl -s --ipv4 https://api.ipify.org) || \
  ip=$(curl -s --ipv4 https://icanhazip.com) || \
  ip=$(hostname -I | awk '{print $1}')
  echo "$ip"
  if [[ -z "$ip" ]]; then
    echo -e "${RED}[!] Khong the lay dia chi IP public cua server.${NC}"
    return 1 
  fi
  return 0
}

generate_random_string() {
  local length="${1:-32}" 
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length" 
}

update_env_file() {
  local key="$1"
  local value="$2"
  if [ ! -f "${ENV_FILE}" ]; then
    echo -e "${RED}Loi: File ${ENV_FILE} khong ton tai. Khong the cap nhat.${NC}"
    return 1
  fi
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sudo sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    echo "${key}=${value}" | sudo tee -a "${ENV_FILE}" > /dev/null
  fi
}

_spinner() {
    local spin_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    tput civis 
    while true; do
        echo -n -e " ${CYAN}${spin_chars[$i]} $1 ${NC}\r"
        i=$(( (i+1) % ${#spin_chars[@]} ))
        sleep 0.1
    done
}

start_spinner() {
    local message="$1"
    if [[ $SPINNER_PID -ne 0 ]]; then
        stop_spinner
    fi
    _spinner "$message" &
    SPINNER_PID=$!
    trap "stop_spinner;" SIGINT SIGTERM 
}

stop_spinner() {
    if [[ $SPINNER_PID -ne 0 ]]; then
        kill "$SPINNER_PID" &>/dev/null
        wait "$SPINNER_PID" &>/dev/null 
        echo -n -e "\r\033[K" 
        SPINNER_PID=0
    fi
    tput cnorm 
}

run_silent_command() {
  local message="$1"
  local command_to_run="$2"
  local log_file="/tmp/n8n_manager_cmd_$(date +%s%N).log"
  local show_explicit_processing_message="${3:-true}"

  if [[ "$show_explicit_processing_message" == "false" ]]; then
    if sudo bash -c "${command_to_run}" >> "${log_file}" 2>&1; then 
      sudo rm -f "${log_file}"
      return 0
    else
      if [[ $SPINNER_PID -ne 0 ]]; then
          stop_spinner
      fi
      echo -e "\n${RED}Loi trong khi [${message}] (xu ly ngam).${NC}" 
      echo -e "${RED}Chi tiet loi da duoc ghi vao: ${log_file}${NC}"
      echo -e "${RED}5 dong cuoi cua log:${NC}"
      tail -n 5 "${log_file}" | sed 's/^/    /'
      return 1 
    fi
  else
    local spinner_was_globally_running=false
    if [[ $SPINNER_PID -ne 0 ]]; then
        spinner_was_globally_running=true
        stop_spinner 
    fi

    echo -n -e "${CYAN}Xu ly: ${message}... ${NC}"
    
    if sudo bash -c "${command_to_run}" > "${log_file}" 2>&1; then 
      echo -e "${GREEN}Xong.${NC}"
      sudo rm -f "${log_file}"
      return 0
    else
      echo -e "${RED}That bai.${NC}" 
      echo -e "${RED}Chi tiet loi da duoc ghi vao: ${log_file}${NC}"
      echo -e "${RED}5 dong cuoi cua log:${NC}"
      tail -n 5 "${log_file}" | sed 's/^/    /'
      return 1 
    fi
  fi
}

# --- Cac buoc Cai dat ---

install_prerequisites() {
  start_spinner "Kiem tra va cai dat cac goi phu thuoc..."

  run_silent_command "Cap nhat danh sach goi" "apt-get update -y" "false" 
  if [ $? -ne 0 ]; then return 1; fi 

  if ! is_package_installed nginx; then
    run_silent_command "Cai dat Nginx" "apt-get install -y nginx" "false"
    if [ $? -ne 0 ]; then return 1; fi
    sudo systemctl enable nginx >/dev/null 2>&1
    sudo systemctl start nginx >/dev/null 2>&1
  fi

  if ! command_exists docker; then
    if ! curl -fsSL https://get.docker.com -o get-docker.sh; then
        echo -e "${RED}Loi tai script cai dat Docker.${NC}"
        return 1 
    fi
    run_silent_command "Cai dat Docker tu script" "sh get-docker.sh" "false"
    if [ $? -ne 0 ]; then rm get-docker.sh; return 1; fi
    sudo usermod -aG docker "$(whoami)" >/dev/null 2>&1
    rm get-docker.sh
  fi

  if docker compose version &>/dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
  elif command_exists docker-compose; then
    DOCKER_COMPOSE_CMD="docker-compose"
  else
    LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$LATEST_COMPOSE_VERSION" ]]; then
        LATEST_COMPOSE_VERSION="1.29.2" 
    fi
    run_silent_command "Tai Docker Compose v${LATEST_COMPOSE_VERSION}" \
      "curl -L \"https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)\" -o /usr/local/bin/docker-compose" "false"
    if [ $? -ne 0 ]; then return 1; fi
    sudo chmod +x /usr/local/bin/docker-compose
    DOCKER_COMPOSE_CMD="docker-compose"
  fi

  if ! command_exists certbot; then
    run_silent_command "Cai dat Certbot va plugin Nginx" "apt-get install -y certbot python3-certbot-nginx" "false"
    if [ $? -ne 0 ]; then return 1; fi
  fi

  if ! command_exists dig; then
    run_silent_command "Cai dat dnsutils (cho dig)" "apt-get install -y dnsutils" "false"
    if [ $? -ne 0 ]; then return 1; fi
  fi

  if ! command_exists curl; then
    run_silent_command "Cai dat curl" "apt-get install -y curl" "false"
    if [ $? -ne 0 ]; then return 1; fi
  fi

  if command_exists ufw; then
    sudo ufw allow http > /dev/null
    sudo ufw allow https > /dev/null
  fi
  
  stop_spinner
  echo -e "${GREEN}Kiem tra va cai dat goi phu thuoc hoan tat.${NC}" 
}

setup_directories_and_env_file() {
  start_spinner "Thiet lap thu muc va file .env..."
  if [ ! -d "${N8N_DIR}" ]; then
    sudo mkdir -p "${N8N_DIR}"
  fi
  if [ ! -f "${ENV_FILE}" ]; then
    sudo touch "${ENV_FILE}"
    sudo chmod 600 "${ENV_FILE}"
  fi
  sudo mkdir -p "${NGINX_EXPORT_INCLUDE_DIR}"
  sudo mkdir -p "${TEMPLATE_DIR}" 

  stop_spinner
  echo -e "${GREEN}Thiet lap thu muc va file .env hoan tat.${NC}" 
}

get_domain_and_dns_check_reusable() {
  local result_var_name="$1"
  local current_domain_to_avoid="${2:-}"
  local prompt_message="${3:-Nhap ten mien ban muon su dung cho n8n (vi du: n8n.example.com)}"

  trap 'echo -e "\n${YELLOW}Huy bo nhap ten mien.${NC}"; return 1;' SIGINT SIGTERM

  echo -e "${CYAN}---> Nhap thong tin ten mien (Nhan Ctrl+C de huy bo)...${NC}" 
  local new_domain_input 
  local server_ip
  local resolved_ip

  server_ip=$(get_public_ip)
  if [ $? -ne 0 ]; then 
    trap - SIGINT SIGTERM 
    return 1; 
  fi 

  echo -e "Dia chi IP public cua server la: ${GREEN}${server_ip}${NC}"

  while true; do
    local prompt_string
    prompt_string=$(echo -e "${prompt_message}: ")
    echo -n "$prompt_string"

    if ! read -r new_domain_input; then
        echo -e "\n${YELLOW}Huy bo nhap ten mien.${NC}"
        trap - SIGINT SIGTERM 
        return 1
    fi

    if [[ -z "$new_domain_input" ]]; then
      echo -e "${RED}Ten mien khong duoc de trong. Vui long nhap lai.${NC}"
      continue
    fi

    if [[ -n "$current_domain_to_avoid" && "$new_domain_input" == "$current_domain_to_avoid" ]]; then
      echo -e "${YELLOW}Ten mien moi (${new_domain_input}) trung voi ten mien hien tai (${current_domain_to_avoid}).${NC}"
      echo -e "${YELLOW}Vui long nhap mot ten mien khac.${NC}"
      continue
    fi

    start_spinner "Kiem tra DNS cho ${new_domain_input}..."
    resolved_ip=$(timeout 5 dig +short A "$new_domain_input" @1.1.1.1 | tail -n1)
    if [[ -z "$resolved_ip" ]]; then
        local cname_target 
        cname_target=$(timeout 5 dig +short CNAME "$new_domain_input" @1.1.1.1 | tail -n1)
        if [[ -n "$cname_target" ]]; then
             resolved_ip=$(timeout 5 dig +short A "$cname_target" @1.1.1.1 | tail -n1)
        fi
    fi
    stop_spinner 

    if [[ "$resolved_ip" == "$server_ip" ]]; then
      echo -e "${GREEN}DNS cho ${new_domain_input} da duoc tro ve IP server chinh xac (${resolved_ip}).${NC}"
      printf -v "$result_var_name" "%s" "$new_domain_input"
      trap - SIGINT SIGTERM 
      break
    else
      echo -e "${RED}Loi: Ten mien ${new_domain_input} (tro ve ${resolved_ip:-'khong tim thay ban ghi A/CNAME hoac timeout'}) chua duoc tro ve IP server (${server_ip}).${NC}"
      echo -e "${YELLOW}Vui long tro DNS A record cua ten mien ${new_domain_input} ve dia chi IP ${server_ip} va doi DNS cap nhat.${NC}"
      
      trap 'echo -e "\n${YELLOW}Huy bo nhap ten mien.${NC}"; return 1;' SIGINT SIGTERM
      local choice_prompt
      choice_prompt=$(echo -e "Nhan Enter de kiem tra lai, hoac '${CYAN}s${NC}' de bo qua, '${CYAN}0${NC}' de huy bo: ")
      echo -n "$choice_prompt"
      if ! read -r dns_choice; then
          echo -e "\n${YELLOW}Huy bo nhap lua chon.${NC}"
          trap - SIGINT SIGTERM 
          return 1
      fi

      if [[ "$dns_choice" == "s" || "$dns_choice" == "S" ]]; then
        echo -e "${YELLOW}Bo qua kiem tra DNS. Dam bao ban da tro DNS chinh xac.${NC}"
        printf -v "$result_var_name" "%s" "$new_domain_input"
        trap - SIGINT SIGTERM 
        break
      elif [[ "$dns_choice" == "0" ]]; then
        echo -e "${YELLOW}Huy bo nhap ten mien.${NC}"
        trap - SIGINT SIGTERM
        return 1 
      fi
    fi
  done
  trap - SIGINT SIGTERM 
  return 0 
}


generate_credentials() {
  start_spinner "Tao thong tin dang nhap va cau hinh..."
  update_env_file "N8N_ENCRYPTION_KEY" "$(generate_random_string 64)"
  local system_timezone 
  system_timezone=$(timedatectl show --property=Timezone --value 2>/dev/null) 
  update_env_file "GENERIC_TIMEZONE" "${system_timezone:-Asia/Ho_Chi_Minh}"

  update_env_file "POSTGRES_DB" "n8n_db_$(generate_random_string 6 | tr '[:upper:]' '[:lower:]')"
  update_env_file "POSTGRES_USER" "n8n_user_$(generate_random_string 8 | tr '[:upper:]' '[:lower:]')"
  update_env_file "POSTGRES_PASSWORD" "$(generate_random_string 32)"

  update_env_file "REDIS_PASSWORD" "$(generate_random_string 32)"
  
  stop_spinner
  echo -e "${GREEN}Thong tin dang nhap va cau hinh da duoc luu vao ${ENV_FILE}.${NC}"
  echo -e "${YELLOW}Quan trong: Vui long sao luu file ${ENV_FILE}.${NC}"
}

create_docker_compose_config() {
  start_spinner "Tao file docker-compose.yml..."
  local n8n_encryption_key_val postgres_user_val postgres_password_val postgres_db_val redis_password_val
  local domain_name_val generic_timezone_val

  if [ -f "${ENV_FILE}" ]; then
    n8n_encryption_key_val=$(grep "^N8N_ENCRYPTION_KEY=" "${ENV_FILE}" | cut -d'=' -f2)
    postgres_user_val=$(grep "^POSTGRES_USER=" "${ENV_FILE}" | cut -d'=' -f2)
    postgres_password_val=$(grep "^POSTGRES_PASSWORD=" "${ENV_FILE}" | cut -d'=' -f2)
    postgres_db_val=$(grep "^POSTGRES_DB=" "${ENV_FILE}" | cut -d'=' -f2)
    redis_password_val=$(grep "^REDIS_PASSWORD=" "${ENV_FILE}" | cut -d'=' -f2)
    domain_name_val=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
    generic_timezone_val=$(grep "^GENERIC_TIMEZONE=" "${ENV_FILE}" | cut -d'=' -f2)
  fi

  sudo bash -c "cat > ${DOCKER_COMPOSE_FILE}" <<EOF
# version: '3.8' 

services:
  postgres:
    image: postgres:15-alpine
    restart: always
    container_name: n8n_postgres 
    environment:
      - POSTGRES_USER=\${POSTGRES_USER:-${postgres_user_val}}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD:-${postgres_password_val}}
      - POSTGRES_DB=\${POSTGRES_DB:-${postgres_db_val}}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER:-${postgres_user_val}} -d \${POSTGRES_DB:-${postgres_db_val}}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: always
    container_name: n8n_redis 
    command: redis-server --save 60 1 --loglevel warning --requirepass \${REDIS_PASSWORD:-${redis_password_val}}
    ports: 
      - "6379:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\${REDIS_PASSWORD:-${redis_password_val}}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  ${N8N_SERVICE_NAME}: 
    image: n8nio/n8n:latest 
    restart: always
    container_name: ${N8N_CONTAINER_NAME} 
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB:-${postgres_db_val}}
      - DB_POSTGRESDB_USER=\${POSTGRES_USER:-${postgres_user_val}}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD:-${postgres_password_val}}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY:-${n8n_encryption_key_val}} 
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE:-${generic_timezone_val}}
      - N8N_HOST=\${DOMAIN_NAME:-${domain_name_val}}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://\${DOMAIN_NAME:-${domain_name_val}}/
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true 
      - N8N_BASIC_AUTH_ACTIVE=false
      - N8N_RUNNERS_ENABLED=true
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  postgres_data:
  redis_data:
  n8n_data:
EOF
  stop_spinner
}

start_docker_containers() {
  start_spinner "Khoi chay cai dat N8N Cloud..."
  cd "${N8N_DIR}" || { return 1; } 
  
  run_silent_command "Tai Docker images" "$DOCKER_COMPOSE_CMD pull" "false" 
  
  run_silent_command "Khoi chay container qua docker-compose" "$DOCKER_COMPOSE_CMD up -d --force-recreate" "false" 
  if [ $? -ne 0 ]; then return 1; fi

  sleep 15 
  stop_spinner
  echo -e "${GREEN}N8N Cloud da khoi chay.${NC}"
  cd - > /dev/null
}

configure_nginx_and_ssl() {
  start_spinner "Cau hinh Nginx va SSL voi Certbot..."
  local domain_name 
  local user_email 
  domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
  user_email=$(grep "^LETSENCRYPT_EMAIL=" "${ENV_FILE}" | cut -d'=' -f2)
  local webroot_path="/var/www/html" 

  if [[ -z "$domain_name" || -z "$user_email" ]]; then
    echo -e "${RED}Khong tim thay DOMAIN_NAME hoac LETSENCRYPT_EMAIL trong file .env.${NC}"
    return 1
  fi

  local nginx_conf_file="/etc/nginx/sites-available/${domain_name}.conf"

  sudo mkdir -p "${webroot_path}/.well-known/acme-challenge"
  sudo chown www-data:www-data "${webroot_path}" -R 

  run_silent_command "Tao cau hinh Nginx ban dau cho HTTP challenge" \
    "bash -c \"cat > ${nginx_conf_file}\" <<EOF
server {
    listen 80;
    server_name ${domain_name};

    location /.well-known/acme-challenge/ {
        root ${webroot_path}; 
        allow all;
    }
}
EOF" "false" || return 1


  sudo ln -sfn "${nginx_conf_file}" "/etc/nginx/sites-enabled/${domain_name}.conf"
  
  run_silent_command "Kiem tra cau hinh Nginx HTTP" "nginx -t" "false" || return 1
  
  sudo systemctl reload nginx >/dev/null 2>&1

  if ! sudo certbot certonly --webroot -w "${webroot_path}" -d "${domain_name}" \
        --agree-tos --email "${user_email}" --non-interactive --quiet \
        --preferred-challenges http --force-renewal > /tmp/certbot_obtain.log 2>&1; then 
    echo -e "${RED}Lay chung chi SSL that bai.${NC}"
    echo -e "${YELLOW}Kiem tra log Certbot tai /var/log/letsencrypt/ va /tmp/certbot_obtain.log.${NC}"
    return 1
  fi

  sudo mkdir -p /etc/letsencrypt 
  if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
    run_silent_command "Tai tuy chon SSL cua Let's Encrypt" \
    "curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf -o /etc/letsencrypt/options-ssl-nginx.conf" "false" || return 1
  fi
  if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then
    run_silent_command "Tao tham so SSL DH" "openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048" "false" || return 1
  fi

  # Tao file Nginx hoan chinh
  run_silent_command "Tao cau hinh Nginx cuoi cung voi SSL va proxy" \
  "bash -c \"cat > ${nginx_conf_file}\" <<EOF
server {
    listen 80;
    server_name ${domain_name};

    location /.well-known/acme-challenge/ {
        root ${webroot_path};
        allow all;
    }

    location / {
        return 301 https://\\\$host\\\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${domain_name};

    ssl_certificate /etc/letsencrypt/live/${domain_name}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain_name}/privkey.pem;
    
    include /etc/letsencrypt/options-ssl-nginx.conf; 
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; 

    location /.well-known/acme-challenge/ {
        root ${webroot_path};
        allow all;
    }
    
    include ${NGINX_EXPORT_INCLUDE_DIR}/${NGINX_EXPORT_INCLUDE_FILE_BASENAME}_*.conf; 


    add_header X-Frame-Options \"SAMEORIGIN\" always;
    add_header X-XSS-Protection \"1; mode=block\" always;
    add_header X-Content-Type-Options \"nosniff\" always;
    add_header Referrer-Policy \"strict-origin-when-cross-origin\" always;
    add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains; preload\" always;

    client_max_body_size 100M;

    access_log /var/log/nginx/${domain_name}.access.log;
    error_log /var/log/nginx/${domain_name}.error.log;

    location / {
        proxy_pass http://127.0.0.1:5678; 
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection 'upgrade'; 
        
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 7200s; 
        proxy_send_timeout 7200s;
    }

    location ~ /\\. { 
        deny all;
    }
}
EOF" "false" || return 1
  
  if [ ! -f "${NGINX_EXPORT_INCLUDE_DIR}/${NGINX_EXPORT_INCLUDE_FILE_BASENAME}.conf" ]; then
    sudo touch "${NGINX_EXPORT_INCLUDE_DIR}/${NGINX_EXPORT_INCLUDE_FILE_BASENAME}.conf"
  fi


  run_silent_command "Kiem tra cau hinh Nginx cuoi cung" "nginx -t" "false" || return 1
  
  sudo systemctl reload nginx >/dev/null 2>&1

  if ! sudo systemctl list-timers | grep -q 'certbot.timer'; then
      sudo systemctl enable certbot.timer >/dev/null 2>&1
      sudo systemctl start certbot.timer >/dev/null 2>&1
  fi
  run_silent_command "Kiem tra gia han SSL" "certbot renew --dry-run" "false" 
  
  stop_spinner
  echo -e "${GREEN}Cau hinh Nginx va SSL hoan tat.${NC}"
}

final_checks_and_message() {
  start_spinner "Thuc hien kiem tra cuoi cung..."
  local domain_name 
  domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)

  sleep 10 

  local http_status 
  http_status=$(curl -L -s -o /dev/null -w "%{http_code}" "https://${domain_name}")
  
  stop_spinner

  if [[ "$http_status" == "200" ]]; then
    echo -e "${GREEN}N8N Cloud da duoc cai dat thanh cong!${NC}"
    echo -e "Ban co the truy cap n8n tai: ${GREEN}https://${domain_name}${NC}"
  else
    echo -e "${RED}Loi! Khong the truy cap n8n tai https://${domain_name} (HTTP Status Code: ${http_status}).${NC}"
    echo -e "${YELLOW}Vui long kiem tra cac buoc sau:${NC}"
    echo -e "  1. Log Docker cua container n8n: sudo ${DOCKER_COMPOSE_CMD} -f ${DOCKER_COMPOSE_FILE} logs ${N8N_CONTAINER_NAME}"
    echo -e "  2. Log Nginx: sudo tail -n 50 /var/log/nginx/${domain_name}.error.log (hoac access.log)"
    echo -e "  3. Trang thai Certbot: sudo certbot certificates"
    echo -e "  4. Dam bao DNS da tro dung va khong co firewall nao chan port 80/443."
    return 1 
  fi

  echo -e "${YELLOW}Quan trong: Hay luu tru file ${ENV_FILE} o mot noi an toan!${NC}"
  echo -e "Ban nen tao user dau tien cho n8n ngay sau khi truy cap."
}

# --- Ham chinh de Cai dat N8N ---
install() {
  check_root
  if [ -d "${N8N_DIR}" ] && [ -f "${DOCKER_COMPOSE_FILE}" ]; then
    echo -e "\n${YELLOW}[CANH BAO] Phat hien thu muc ${N8N_DIR} va file ${DOCKER_COMPOSE_FILE} da ton tai.${NC}"
    local existing_containers
    if command_exists $DOCKER_COMPOSE_CMD && [ -f "${DOCKER_COMPOSE_FILE}" ]; then
        pushd "${N8N_DIR}" > /dev/null || { echo -e "${RED}Khong the truy cap thu muc ${N8N_DIR}${NC}"; return 1; } 
        existing_containers=$(sudo $DOCKER_COMPOSE_CMD ps -q 2>/dev/null)
        popd > /dev/null
    fi

    if [[ -n "$existing_containers" ]] || [ -f "${DOCKER_COMPOSE_FILE}" ]; then 
        echo -e "${YELLOW}    Co ve nhu N8N da duoc cai dat hoac da co mot phan cau hinh truoc do.${NC}"
        echo -e "${YELLOW}    Neu ban muon cai dat lai tu dau, vui long chon muc '9) Xoa N8N va cai dat lai' tu menu chinh.${NC}"
        echo -e "${YELLOW}    Nhan Enter de quay lai menu chinh...${NC}"
        read -r 
        return 0 
    fi
  fi

  echo -e "\n${CYAN}===================================================${NC}"
  echo -e "${CYAN}         Bat dau qua trinh cai dat N8N Cloud        ${NC}"
  echo -e "${CYAN}===================================================${NC}\n"

  trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi trong qua trinh cai dat (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM

  install_prerequisites
  setup_directories_and_env_file
  
  local domain_name_for_install 
  if ! get_domain_and_dns_check_reusable domain_name_for_install "" "Nhap ten mien ban muon su dung cho N8N"; then
    return 0 
  fi
  update_env_file "DOMAIN_NAME" "$domain_name_for_install"
  update_env_file "LETSENCRYPT_EMAIL" "no-reply@${domain_name_for_install}"
  
  generate_credentials 
  create_docker_compose_config
  start_docker_containers
  configure_nginx_and_ssl 
  final_checks_and_message 
  
  trap - ERR SIGINT SIGTERM 

  echo -e "\n${GREEN}===================================================${NC}"
  echo -e "${GREEN}      Hoan tat qua trinh cai dat N8N Cloud!       ${NC}"
  echo -e "${GREEN}===================================================${NC}\n"
  echo -e "${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
  read -r
}

# --- Ham Xoa N8N va Cai dat lai ---
reinstall_n8n() {
    check_root
    echo -e "\n${RED}======================= CANH BAO XOA DU LIEU =======================${NC}"
    echo -e "${YELLOW}Ban da chon chuc nang XOA TOAN BO N8N va CAI DAT LAI.${NC}"
    echo -e "${RED}HANH DONG NAY SE XOA VINH VIEN:${NC}"
    echo -e "${RED}  - Toan bo du lieu n8n (workflows, credentials, executions,...).${NC}"
    echo -e "${RED}  - Database PostgreSQL cua n8n.${NC}"
    echo -e "${RED}  - Du lieu cache Redis (neu co).${NC}"
    echo -e "${RED}  - Cau hinh Nginx va SSL cho ten mien hien tai cua n8n.${NC}"
    echo -e "${RED}  - Toan bo thu muc cai dat ${N8N_DIR}.${NC}"
    echo -e "\n${YELLOW}DE NGHI: Neu ban co du lieu quan trong, hay su dung chuc nang${NC}"
    echo -e "${YELLOW}  '6) Export tat ca (workflow & credentials)'${NC}"
    echo -e "${YELLOW}de SAO LUU du lieu truoc khi tiep tuc.${NC}"
    echo -e "${RED}Hanh dong nay KHONG THE HOAN TAC.${NC}"
    
    local confirm_prompt
    confirm_prompt=$(echo -e "${YELLOW}Nhap '${NC}${RED}delete${NC}${YELLOW}' de xac nhan xoa, hoac nhap '${NC}${CYAN}0${NC}${YELLOW}' de quay lai menu: ${NC}")
    local confirmation
    echo -n "$confirm_prompt" 
    read -r confirmation


    if [[ "$confirmation" == "0" ]]; then
        echo -e "\n${GREEN}Huy bo thao tac. Quay lai menu chinh...${NC}"
        sleep 1 
        return 0
    elif [[ "$confirmation" != "delete" ]]; then
        echo -e "\n${RED}Xac nhan khong hop le. Huy bo thao tac.${NC}"
        echo -e "${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
        read -r
        return 0
    fi

    echo -e "\n${CYAN}Bat dau qua trinh xoa N8N...${NC}"
    trap 'stop_spinner; echo -e "\n${RED}Da xay ra loi hoac huy bo trong qua trinh xoa N8N.${NC}"; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Dang xoa N8N..."

    if [ -d "${N8N_DIR}" ]; then
        if [ -f "${DOCKER_COMPOSE_FILE}" ]; then
            stop_spinner 
            start_spinner "Dang tien hanh xoa du lieu..."
            pushd "${N8N_DIR}" > /dev/null || { stop_spinner; echo -e "${RED}Loi: Khong the truy cap ${N8N_DIR}.${NC}"; return 1; }
            if ! sudo $DOCKER_COMPOSE_CMD down -v --remove-orphans > /tmp/n8n_reinstall_docker_down.log 2>&1; then
                stop_spinner
                echo -e "${RED}Loi khi dung/xoa Docker. Kiem tra /tmp/n8n_reinstall_docker_down.log.${NC}"
            fi
            popd > /dev/null
            stop_spinner
            start_spinner "Tiep tuc xoa N8N..." 
        else
            echo -e "\r\033[K ${YELLOW}Khong tim thay file ${DOCKER_COMPOSE_FILE}. Bo qua buoc xoa Docker.${NC}"
        fi

        local domain_to_remove
        if [ -f "${ENV_FILE}" ]; then
            domain_to_remove=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
        fi

        if [[ -n "$domain_to_remove" ]]; then
            local nginx_conf_avail="/etc/nginx/sites-available/${domain_to_remove}.conf"
            local nginx_conf_enabled="/etc/nginx/sites-enabled/${domain_to_remove}.conf"
            
            if [ -f "$nginx_conf_avail" ] || [ -L "$nginx_conf_enabled" ]; then
                 stop_spinner
                 start_spinner "Xoa cau hinh Nginx cho ${domain_to_remove}..."
                 sudo rm -f "$nginx_conf_avail"
                 sudo rm -f "$nginx_conf_enabled"
                 sudo systemctl reload nginx > /tmp/n8n_reinstall_nginx_reload.log 2>&1
                 stop_spinner
                 start_spinner "Tiep tuc xoa N8N..."
            fi

            stop_spinner
            start_spinner "Xoa chung chi SSL cho ${domain_to_remove} (neu co)..."
            if sudo certbot certificates -d "${domain_to_remove}" 2>/dev/null | grep -q "Certificate Name:"; then
                 local cert_name_to_delete
                 cert_name_to_delete=$(sudo certbot certificates -d "${domain_to_remove}" 2>/dev/null | grep "Certificate Name:" | head -n 1 | awk '{print $3}')
                 if [[ -n "$cert_name_to_delete" ]]; then
                    if ! sudo certbot delete --cert-name "${cert_name_to_delete}" --non-interactive > /tmp/n8n_reinstall_cert_delete.log 2>&1; then
                        stop_spinner
                        echo -e "${RED}Loi khi xoa chung chi SSL. Kiem tra /tmp/n8n_reinstall_cert_delete.log.${NC}"
                    else
                        stop_spinner
                    fi
                 else
                    stop_spinner
                    echo -e "${YELLOW}Khong the xac dinh ten chung chi SSL cho ${domain_to_remove}.${NC}"
                 fi
            else
                 stop_spinner
                 echo -e "${YELLOW}Khong tim thay chung chi SSL cho ${domain_to_remove} de xoa.${NC}"
            fi
            start_spinner "Tiep tuc xoa N8N..."
        else
             echo -e "\r\033[K ${YELLOW}Khong tim thay ten mien trong ${ENV_FILE}. Bo qua xoa Nginx/SSL.${NC}"
        fi
        
        if [ -d "${NGINX_EXPORT_INCLUDE_DIR}" ]; then
            stop_spinner; start_spinner "Xoa thu muc cau hinh export Nginx tam thoi..."
            sudo rm -rf "${NGINX_EXPORT_INCLUDE_DIR}"
            stop_spinner; start_spinner "Tiep tuc xoa N8N..."
        fi

        stop_spinner
        start_spinner "Xoa thu muc cai dat ${N8N_DIR}..."
        if ! sudo rm -rf "${N8N_DIR}"; then
            stop_spinner
            echo -e "${RED}Loi khi xoa thu muc ${N8N_DIR}.${NC}"
        else
            stop_spinner
        fi
    else
        echo -e "\r\033[K ${YELLOW}Thu muc ${N8N_DIR} khong ton tai. Bo qua buoc xoa.${NC}"
    fi
    
    stop_spinner 
    echo -e "${GREEN}Qua trinh go cai dat va xoa du lieu N8N hoan tat.${NC}"
    echo -e "\n${CYAN}Tien hanh cai dat lai N8N...${NC}"
    
    trap - ERR SIGINT SIGTERM 

    install 
}

# --- Ham Lay thong tin Redis ---
get_redis_info() {
    check_root
    echo -e "\n${CYAN}--- Lay Thong Tin Ket Noi Redis ---${NC}"

    if [ ! -f "${ENV_FILE}" ]; then
        echo -e "${RED}Loi: File cau hinh ${ENV_FILE} khong tim thay.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc (chon muc 1).${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    local redis_password
    redis_password=$(grep "^REDIS_PASSWORD=" "${ENV_FILE}" | cut -d'=' -f2)

    local server_ip=$(get_public_ip)

    if [[ -z "$redis_password" ]]; then
        echo -e "${RED}Loi: Khong tim thay REDIS_PASSWORD trong file ${ENV_FILE}.${NC}"
        echo -e "${YELLOW}File cau hinh co the bi loi hoac Redis chua duoc cau hinh dung.${NC}"
    else
        echo -e "${GREEN}Thong tin ket noi Redis:${NC}"
        echo -e "  ${CYAN}Host:${NC} ${server_ip}"
        echo -e "  ${CYAN}Port:${NC} 6379"
        echo -e "  ${CYAN}User:${NC} default"
        echo -e "  ${CYAN}Password:${NC} ${YELLOW}${redis_password}${NC}"
    fi
    echo -e "\n${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
}

# --- Ham Thay doi ten mien ---
change_domain() {
    check_root
    echo -e "\n${CYAN}--- Thay Doi Ten Mien cho N8N ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    local old_domain_name
    old_domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
    if [[ -z "$old_domain_name" ]]; then
        echo -e "${RED}Loi: Khong tim thay DOMAIN_NAME trong file ${ENV_FILE}.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi
    echo -e "Ten mien hien tai cua N8N la: ${GREEN}${old_domain_name}${NC}"

    local new_domain_for_change 
    if ! get_domain_and_dns_check_reusable new_domain_for_change "$old_domain_name" "Nhap ten mien MOI ban muon su dung"; then
        read -r -p "Nhan Enter de quay lai menu..." 
        return 0 
    fi
    
    local confirmation_prompt
    confirmation_prompt=$(echo -e "\n${YELLOW}Ban co chac chan muon thay doi ten mien tu ${RED}${old_domain_name}${NC} sang ${GREEN}${new_domain_for_change}${NC} khong?${NC}\n${RED}Hanh dong nay se yeu cau cap lai SSL va khoi dong lai cac service.${NC}\nNhap '${GREEN}ok${NC}' de xac nhan, hoac bat ky phim nao khac de huy bo: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "\n${GREEN}Huy bo thay doi ten mien.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi
    
    trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi trong qua trinh thay doi ten mien (Ma loi: $RC).${NC}"; update_env_file "DOMAIN_NAME" "$old_domain_name"; update_env_file "LETSENCRYPT_EMAIL" "no-reply@${old_domain_name}"; echo -e "${YELLOW}Da khoi phuc ten mien cu trong .env.${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Dang thay doi ten mien..."

    stop_spinner; start_spinner "Cap nhat file .env voi ten mien moi..."
    if ! update_env_file "DOMAIN_NAME" "$new_domain_for_change"; then
        return 1 
    fi
    if ! update_env_file "LETSENCRYPT_EMAIL" "no-reply@${new_domain_for_change}"; then
        return 1 
    fi
    stop_spinner; start_spinner "Tiep tuc thay doi ten mien..."

    stop_spinner; start_spinner "Dung service N8N..."
    if ! sudo $DOCKER_COMPOSE_CMD -f "${DOCKER_COMPOSE_FILE}" stop ${N8N_SERVICE_NAME} > /tmp/n8n_change_domain_stop.log 2>&1; then
        echo -e "\n${YELLOW}Canh bao: Khong the dung service ${N8N_SERVICE_NAME}. Kiem tra /tmp/n8n_change_domain_stop.log. Tiep tuc voi rui ro.${NC}"
    fi
    stop_spinner; start_spinner "Tiep tuc thay doi ten mien..."

    local old_nginx_conf_avail="/etc/nginx/sites-available/${old_domain_name}.conf"
    local old_nginx_conf_enabled="/etc/nginx/sites-enabled/${old_domain_name}.conf"
    if [ -f "$old_nginx_conf_avail" ] || [ -L "$old_nginx_conf_enabled" ]; then
        stop_spinner; start_spinner "Xoa cau hinh Nginx cu..."
        sudo rm -f "$old_nginx_conf_avail"
        sudo rm -f "$old_nginx_conf_enabled"
        stop_spinner; start_spinner "Tiep tuc thay doi ten mien..."
    fi

    if sudo certbot certificates -d "${old_domain_name}" 2>/dev/null | grep -q "Certificate Name:"; then
        local old_cert_name
        old_cert_name=$(sudo certbot certificates -d "${old_domain_name}" 2>/dev/null | grep "Certificate Name:" | head -n 1 | awk '{print $3}')
        if [[ -n "$old_cert_name" ]]; then
            stop_spinner; start_spinner "Xoa chung chi SSL cu (${old_cert_name})..."
            if ! sudo certbot delete --cert-name "${old_cert_name}" --non-interactive > /tmp/n8n_change_domain_cert_delete.log 2>&1; then
                 echo -e "\n${YELLOW}Canh bao: Khong the xoa chung chi SSL cu. Kiem tra /tmp/n8n_change_domain_cert_delete.log.${NC}"
            fi
            stop_spinner; start_spinner "Tiep tuc thay doi ten mien..."
        fi
    fi
    
    stop_spinner 
    if ! create_docker_compose_config; then 
        return 1 
    fi

    if ! configure_nginx_and_ssl; then 
        return 1 
    fi

    start_spinner "Khoi dong lai cac service Docker..." 
    cd "${N8N_DIR}" || { return 1; } 
    
    if ! sudo $DOCKER_COMPOSE_CMD up -d --force-recreate > /tmp/n8n_change_domain_docker_up.log 2>&1; then
        return 1
    fi
    cd - > /dev/null
    stop_spinner

    echo -e "\n${GREEN}Thay doi ten mien thanh cong!${NC}"
    echo -e "N8N hien co the truy cap tai: ${GREEN}https://${new_domain_for_change}${NC}" 
    
    trap - ERR SIGINT SIGTERM 
    echo -e "${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
}

# --- Ham Nang cap phien ban N8N ---
upgrade_n8n_version() {
    check_root
    echo -e "\n${CYAN}--- Nang Cap Phien Ban N8N ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi
    
    local current_image_tag="latest" 
    if [ -f "${DOCKER_COMPOSE_FILE}" ]; then
        current_image_tag=$(awk '/services:/ {in_services=1} /^  [^ ]/ {if(in_services) in_n8n_service=0} /'${N8N_SERVICE_NAME}':/ {if(in_services) in_n8n_service=1} /image: n8nio\/n8n:/ {if(in_n8n_service) {gsub("n8nio/n8n:", ""); print $2; exit}}' "${DOCKER_COMPOSE_FILE}")
        if [[ -z "$current_image_tag" ]]; then
            current_image_tag="latest (khong xac dinh)"
        fi
    fi
    echo -e "Phien ban N8N hien tai (theo tag image): ${GREEN}${current_image_tag}${NC}"
    echo -e "${YELLOW}Chuc nang nay se nang cap N8N len phien ban '${GREEN}latest${YELLOW}' moi nhat tu Docker Hub.${NC}"
    
    local confirmation_prompt
    confirmation_prompt=$(echo -e "Ban co chac chan muon tiep tuc nang cap khong?\nNhap '${GREEN}ok${NC}' de xac nhan, hoac bat ky phim nao khac de huy bo: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "\n${GREEN}Huy bo nang cap phien ban.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi trong qua trinh nang cap (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM
    
    start_spinner "Dang nang cap N8N len phien ban moi nhat..."
    
    cd "${N8N_DIR}" || { return 1; }

    stop_spinner; start_spinner "Dam bao cau hinh Docker Compose su dung tag :latest..."
    if ! create_docker_compose_config; then 
        return 1
    fi
    stop_spinner; start_spinner "Tiep tuc nang cap..."


    run_silent_command "Tai image N8N moi nhat (${N8N_SERVICE_NAME} service)" "$DOCKER_COMPOSE_CMD pull ${N8N_SERVICE_NAME}" "false"
    if [ $? -ne 0 ]; then 
        cd - > /dev/null
        return 1; 
    fi
    
    run_silent_command "Khoi dong lai N8N voi phien ban moi (${N8N_SERVICE_NAME} service)" "$DOCKER_COMPOSE_CMD up -d --force-recreate ${N8N_SERVICE_NAME}" "false"
    if [ $? -ne 0 ]; then 
        cd - > /dev/null
        return 1; 
    fi

    cd - > /dev/null
    stop_spinner

    echo -e "\n${GREEN}Nang cap N8N hoan tat!${NC}"
    echo -e "${YELLOW}N8N da duoc cap nhat len phien ban '${GREEN}latest${YELLOW}' moi nhat.${NC}"
    echo -e "Vui long kiem tra giao dien web cua N8N de xac nhan phien ban."
    
    trap - ERR SIGINT SIGTERM
    echo -e "${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
}

# --- Ham Tat Xac thuc 2 buoc (2FA/MFA) ---
disable_mfa() {
    check_root
    echo -e "\n${CYAN}--- Tat Xac Thuc 2 Buoc (2FA/MFA) cho User N8N ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    local user_email
    echo -n -e "Nhap dia chi email cua tai khoan N8N can tat 2FA: "
    read -r user_email

    if [[ -z "$user_email" ]]; then
        echo -e "${RED}Email khong duoc de trong. Huy bo thao tac.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    echo -e "\n${YELLOW}Ban co chac chan muon tat 2FA cho tai khoan voi email ${GREEN}${user_email}${NC} khong?${NC}"
    local confirmation_prompt
    confirmation_prompt=$(echo -e "Nhap '${GREEN}ok${NC}' de xac nhan, hoac bat ky phim nao khac de huy bo: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "\n${GREEN}Huy bo thao tac tat 2FA.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Dang tat 2FA cho user ${user_email}..."

    local disable_mfa_log="/tmp/n8n_disable_mfa.log"
    local cli_command="docker exec -u node ${N8N_CONTAINER_NAME} n8n umfa:disable --email \"${user_email}\""
    
    if sudo bash -c "${cli_command}" > "${disable_mfa_log}" 2>&1; then
        stop_spinner
        echo -e "\n${GREEN}Lenh tat 2FA da duoc thuc thi.${NC}"
        cat "${disable_mfa_log}" 
        if grep -q -i "disabled MFA for user with email" "${disable_mfa_log}"; then 
            echo -e "${GREEN}2FA da duoc tat thanh cong cho user ${user_email}.${NC}"
        elif grep -q -i "does not exist" "${disable_mfa_log}"; then 
            echo -e "${RED}Loi: Khong tim thay user voi email ${user_email}.${NC}"
        elif grep -q -i "MFA is not enabled" "${disable_mfa_log}"; then
            echo -e "${YELLOW}Thong bao: 2FA chua duoc kich hoat cho user ${user_email}.${NC}"
        else
            echo -e "${YELLOW}Vui long kiem tra output o tren de biet ket qua chi tiet.${NC}"
        fi
    else
        stop_spinner
        echo -e "\n${RED}Loi khi thuc thi lenh tat 2FA.${NC}"
        cat "${disable_mfa_log}"
        echo -e "${YELLOW}Kiem tra log Docker cua container ${N8N_CONTAINER_NAME} de biet them chi tiet.${NC}"
    fi
    sudo rm -f "${disable_mfa_log}"


    trap - ERR SIGINT SIGTERM
    echo -e "\n${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
}

# --- Ham Dat lai thong tin dang nhap ---
reset_user_login() {
    check_root
    echo -e "\n${CYAN}--- Dat Lai Thong Tin Dang Nhap User Owner N8N ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi
    
    echo -e "\n${YELLOW}CANH BAO: Hanh dong nay se reset toan bo thong tin tai khoan owner (nguoi dung chu so huu).${NC}"
    echo -e "${YELLOW}Sau khi reset, ban se can phai tao lai tai khoan owner khi truy cap N8N lan dau.${NC}"
    local confirmation_prompt
    confirmation_prompt=$(echo -e "Ban co chac chan muon tiep tuc?\nNhap '${GREEN}ok${NC}' de xac nhan, hoac bat ky phim nao khac de huy bo: ")
    local confirmation
    read -r -p "$confirmation_prompt" confirmation

    if [[ "$confirmation" != "ok" ]]; then
        echo -e "\n${GREEN}Huy bo thao tac dat lai thong tin dang nhap.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    trap 'RC=$?; stop_spinner; if [[ $RC -ne 0 && $RC -ne 130 ]]; then echo -e "\n${RED}Da xay ra loi (Ma loi: $RC).${NC}"; fi; read -r -p "Nhan Enter de quay lai menu..."; return 0;' ERR SIGINT SIGTERM

    start_spinner "Dang reset thong tin dang nhap owner..."

    local reset_log="/tmp/n8n_reset_owner.log"
    local cli_command="docker exec -u node ${N8N_CONTAINER_NAME} n8n user-management:reset"

    local cli_exit_code=0
    sudo bash -c "${cli_command}" > "${reset_log}" 2>&1 || cli_exit_code=$?
    
    stop_spinner 

    if [[ $cli_exit_code -eq 0 ]]; then
        echo -e "\n${GREEN}Lenh reset thong tin owner da duoc thuc thi.${NC}"
        echo -e "${CYAN}Output tu lenh:${NC}"
        cat "${reset_log}" 
        
        if grep -q -i "User data for instance owner has been reset" "${reset_log}"; then
             echo -e "${GREEN}Thong tin tai khoan owner da duoc reset thanh cong.${NC}"
             echo -e "${YELLOW}Lan truy cap N8N tiep theo, ban se duoc yeu cau tao lai tai khoan owner.${NC}"
             
             start_spinner "Dang khoi dong lai N8N service..."
             cd "${N8N_DIR}" || { stop_spinner; echo -e "${RED}Khong the truy cap ${N8N_DIR}.${NC}"; return 1; } 
             if ! sudo $DOCKER_COMPOSE_CMD restart ${N8N_SERVICE_NAME} > /tmp/n8n_restart_after_reset.log 2>&1; then
                 stop_spinner
                 echo -e "${RED}Loi khi khoi dong lai N8N service. Kiem tra /tmp/n8n_restart_after_reset.log${NC}"
             else
                 stop_spinner
                 echo -e "${GREEN}N8N service da duoc khoi dong lai.${NC}"
             fi
             cd - > /dev/null
        else
            echo -e "${YELLOW}Reset co the khong thanh cong. Vui long kiem tra output o tren.${NC}"
        fi
    else 
        echo -e "\n${RED}Loi khi thuc thi lenh reset thong tin owner.${NC}"
        echo -e "${YELLOW}Output tu lenh (neu co):${NC}"
        cat "${reset_log}"
        echo -e "${YELLOW}Kiem tra log Docker cua container ${N8N_CONTAINER_NAME} de biet them chi tiet.${NC}"
    fi
    sudo rm -f "${reset_log}"


    trap - ERR SIGINT SIGTERM
    echo -e "\n${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
}

# --- Ham Export Du Lieu ---
export_all_data() {
    check_root
    echo -e "\n${CYAN}--- Export Du Lieu N8N (Workflows & Credentials) ---${NC}"

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    local domain_name
    domain_name=$(grep "^DOMAIN_NAME=" "${ENV_FILE}" | cut -d'=' -f2)
    if [[ -z "$domain_name" ]]; then
        echo -e "${RED}Loi: Khong tim thay DOMAIN_NAME trong file ${ENV_FILE}.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    local backup_base_dir="${N8N_DIR}/backups"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local current_backup_dir="${backup_base_dir}/n8n_backup_${timestamp}"
    local container_temp_export_dir="/home/node/.n8n/temp_export_$$" 
    local creds_file="credentials.json"
    local workflows_file="workflows.json"
    local temp_nginx_include_file_path_for_trap="" 

    trap 'RC=$?; stop_spinner; \
        echo -e "\n${YELLOW}Huy bo/Loi trong qua trinh export (Ma loi: $RC). Dang don dep...${NC}"; \
        sudo docker exec -u node ${N8N_CONTAINER_NAME} rm -rf "${container_temp_export_dir}" &>/dev/null; \
        if [ -n "${temp_nginx_include_file_path_for_trap}" ] && [ -f "${temp_nginx_include_file_path_for_trap}" ]; then \
            sudo rm -f "${temp_nginx_include_file_path_for_trap}"; \
            if sudo nginx -t &>/dev/null; then sudo systemctl reload nginx &>/dev/null; fi; \
            echo -e "${YELLOW}Duong dan tai xuong tam thoi da duoc go bo.${NC}"; \
        fi; \
        read -r -p "Nhan Enter de quay lai menu..."; \
        return 0;' ERR SIGINT SIGTERM

    start_spinner "Chuan bi export du lieu..."

    if ! sudo mkdir -p "${current_backup_dir}"; then
        stop_spinner
        echo -e "${RED}Loi: Khong the tao thu muc backup ${current_backup_dir}.${NC}"
        return 1
    fi
    sudo chmod 755 "${current_backup_dir}" 

    if ! sudo docker exec -u node "${N8N_CONTAINER_NAME}" mkdir -p "${container_temp_export_dir}"; then
        stop_spinner
        echo -e "${RED}Loi: Khong the tao thu muc tam trong container N8N.${NC}"
        return 1
    fi
    stop_spinner

    # Export credentials
    local export_creds_log="/tmp/n8n_export_creds.log"
    local export_creds_cmd="n8n export:credentials --all --output=${container_temp_export_dir}/${creds_file}"
    local export_creds_success=false
    
    start_spinner "Dang export credentials..."
    if sudo docker exec -u node "${N8N_CONTAINER_NAME}" ${export_creds_cmd} > "${export_creds_log}" 2>&1; then
        if sudo docker cp "${N8N_CONTAINER_NAME}:${container_temp_export_dir}/${creds_file}" "${current_backup_dir}/${creds_file}"; then
            export_creds_success=true
            echo -e "\r\033[K${GREEN}Export credentials thanh cong.${NC}"
        else
            echo -e "\r\033[K${RED}Loi khi sao chep ${creds_file} tu container.${NC}"
        fi
    else
        if grep -q -i "No credentials found" "${export_creds_log}" || \
           grep -q -i "No items to export" "${export_creds_log}" || \
           [ ! -f "$(sudo docker exec ${N8N_CONTAINER_NAME} ls ${container_temp_export_dir}/${creds_file} 2>/dev/null)" ]; then 
            echo -e "\r\033[K${YELLOW}Khong tim thay credentials de export. Tao file trong...${NC}"
            echo "{}" | sudo tee "${current_backup_dir}/${creds_file}" > /dev/null
            export_creds_success=true 
        else
            echo -e "\r\033[K${RED}Loi khi export credentials.${NC}"
            echo -e "${YELLOW}Output tu lenh:${NC}"
            cat "${export_creds_log}"
        fi
    fi
    stop_spinner
    sudo rm -f "${export_creds_log}"
    if [[ "$export_creds_success" != true ]]; then return 1; fi


    # Export workflows
    local export_workflows_log="/tmp/n8n_export_workflows.log"
    local export_workflows_cmd="n8n export:workflow --all --output=${container_temp_export_dir}/${workflows_file}"
    local export_workflows_success=false

    start_spinner "Dang export workflows..."
    if sudo docker exec -u node "${N8N_CONTAINER_NAME}" ${export_workflows_cmd} > "${export_workflows_log}" 2>&1; then
        if sudo docker cp "${N8N_CONTAINER_NAME}:${container_temp_export_dir}/${workflows_file}" "${current_backup_dir}/${workflows_file}"; then
            export_workflows_success=true
            echo -e "\r\033[K${GREEN}Export workflows thanh cong.${NC}"
        else
            echo -e "\r\033[K${RED}Loi khi sao chep ${workflows_file} tu container.${NC}"
        fi
    else
        if grep -q -i "No workflows found" "${export_workflows_log}" || \
           grep -q -i "No items to export" "${export_workflows_log}" || \
           [ ! -f "$(sudo docker exec ${N8N_CONTAINER_NAME} ls ${container_temp_export_dir}/${workflows_file} 2>/dev/null)" ]; then
            echo -e "\r\033[K${YELLOW}Khong tim thay workflows de export. Tao file trong...${NC}"
            echo "[]" | sudo tee "${current_backup_dir}/${workflows_file}" > /dev/null
            export_workflows_success=true 
        else
            echo -e "\r\033[K${RED}Loi khi export workflows.${NC}"
            echo -e "${YELLOW}Output tu lenh:${NC}"
            cat "${export_workflows_log}"
        fi
    fi
    stop_spinner
    sudo rm -f "${export_workflows_log}"
    if [[ "$export_workflows_success" != true ]]; then return 1; fi
    
    echo -e "Duong dan luu tru tren server: ${YELLOW}${current_backup_dir}${NC}"

    start_spinner "Don dep thu muc tam trong container..."
    sudo docker exec -u node "${N8N_CONTAINER_NAME}" rm -rf "${container_temp_export_dir}" &>/dev/null
    stop_spinner
    
    local random_signature
    random_signature=$(generate_random_string 16)
    sudo mkdir -p "${NGINX_EXPORT_INCLUDE_DIR}"
    local temp_nginx_include_file="${NGINX_EXPORT_INCLUDE_DIR}/${NGINX_EXPORT_INCLUDE_FILE_BASENAME}_${random_signature}.conf"
    temp_nginx_include_file_path_for_trap="${temp_nginx_include_file}" 
    local download_path_segment="n8n-backup-${random_signature}"

    start_spinner "Tao duong dan tai xuong tam thoi..."
    
    local nginx_export_content
    nginx_export_content=$(cat <<EOF
location /${download_path_segment}/ {
    alias ${current_backup_dir}/;
    add_header Content-Disposition "attachment";
    autoindex off;
    expires off;
}
EOF
)
    echo "$nginx_export_content" | sudo tee "${temp_nginx_include_file}" > /dev/null
    if [ $? -ne 0 ]; then
        stop_spinner
        echo -e "${RED}Loi khi tao file cau hinh Nginx tam thoi: ${temp_nginx_include_file}.${NC}"
        temp_nginx_include_file_path_for_trap="" 
        return 1
    fi


    if ! sudo nginx -t > /tmp/nginx_export_test.log 2>&1; then
        stop_spinner
        echo -e "${RED}Loi cau hinh Nginx. Kiem tra /tmp/nginx_export_test.log.${NC}"
        sudo rm -f "${temp_nginx_include_file}"
        temp_nginx_include_file_path_for_trap=""
        return 1
    fi
    sudo systemctl reload nginx
    stop_spinner
    echo -e "${GREEN}Duong dan tai xuong tam thoi da duoc tao.${NC}"

    echo -e "\n${YELLOW}--- HUONG DAN TAI XUONG ---${NC}"
    echo -e "Cac file backup da duoc export thanh cong."
    echo -e "Ban co the tai xuong qua cac duong dan sau (chi co hieu luc trong phien nay):"
    echo -e "  Credentials: ${GREEN}https://${domain_name}/${download_path_segment}/${creds_file}${NC}"
    echo -e "  Workflows:   ${GREEN}https://${domain_name}/${download_path_segment}/${workflows_file}${NC}"
    echo -e "\n${RED}QUAN TRONG:${NC} Sau khi ban tai xong, nhan Enter de vo hieu hoa cac duong dan nay."

    read -r -p "Nhan Enter sau khi ban da tai xong cac file..."

    start_spinner "Vo hieu hoa duong dan tai xuong..."
    sudo rm -f "${temp_nginx_include_file}"
    temp_nginx_include_file_path_for_trap="" 
    if ! sudo nginx -t > /tmp/nginx_export_test_remove.log 2>&1; then
        echo -e "\n${YELLOW}Canh bao: Co loi khi kiem tra Nginx sau khi xoa file include, nhung van tiep tuc.${NC}"
    fi
    sudo systemctl reload nginx
    stop_spinner
    echo -e "${GREEN}Duong dan tai xuong da duoc vo hieu hoa.${NC}"
    echo -e "Cac file backup van duoc luu tru tai: ${YELLOW}${current_backup_dir}${NC} tren server."

    trap - ERR SIGINT SIGTERM
    echo -e "\n${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
}

# --- Ham Import Du Lieu ---
import_data() {
    check_root

    if [[ ! -f "${ENV_FILE}" || ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        echo -e "${RED}Loi: Khong tim thay file cau hinh ${ENV_FILE} hoac ${DOCKER_COMPOSE_FILE}.${NC}"
        echo -e "${YELLOW}Co ve nhu N8N chua duoc cai dat. Vui long cai dat truoc.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi

    local template_file_full_path="${TEMPLATE_DIR}/${TEMPLATE_FILE_NAME}"

    if [ ! -f "$template_file_full_path" ]; then
        echo -e "${RED}Loi: File template '${template_file_full_path}' khong tim thay tren server.${NC}"
        echo -e "${YELLOW}Vui long tao thu muc '${TEMPLATE_DIR}' (cung cap voi script nay) va dat file '${TEMPLATE_FILE_NAME}' vao do.${NC}"
        read -r -p "Nhan Enter de quay lai menu..."
        return 0
    fi
    
    trap 'RC=$?; stop_spinner; \
        echo -e "\n${YELLOW}Huy bo/Loi trong qua trinh import (Ma loi: $RC). Dang don dep...${NC}"; \
        sudo docker exec -u node ${N8N_CONTAINER_NAME} rm -rf "/home/node/.n8n/temp_import_template_$$" &>/dev/null; \
        read -r -p "Nhan Enter de quay lai menu..."; \
        return 0;' ERR SIGINT SIGTERM

    local container_temp_import_dir="/home/node/.n8n/temp_import_template_$$"

    start_spinner "Chuan bi import workflow tu template..."
    if ! sudo docker exec -u node "${N8N_CONTAINER_NAME}" mkdir -p "${container_temp_import_dir}"; then
        stop_spinner
        echo -e "${RED}Loi: Khong the tao thu muc tam trong container N8N.${NC}"
        return 1
    fi
    
    local docker_cp_command="docker cp \"${template_file_full_path}\" \"${N8N_CONTAINER_NAME}:${container_temp_import_dir}/${TEMPLATE_FILE_NAME}\""
    if ! sudo bash -c "$docker_cp_command" >/dev/null 2>&1; then
        # stop_spinner se duoc goi boi trap
        echo -e "${RED}Loi khi sao chep file template vao container.${NC}"
        sudo docker exec -u node "${N8N_CONTAINER_NAME}" rm -rf "${container_temp_import_dir}" &>/dev/null
        return 1 # Kich hoat trap
    fi
    

    start_spinner "Dang import workflow tu template ${TEMPLATE_FILE_NAME}..."
    local import_cmd="n8n import:workflow --input=${container_temp_import_dir}/${TEMPLATE_FILE_NAME}"
    local import_log="/tmp/n8n_import_template.log"
    
    if ! sudo docker exec -u node "${N8N_CONTAINER_NAME}" ${import_cmd} > "${import_log}" 2>&1; then
        stop_spinner
        echo -e "\n${RED}Loi khi import workflow tu template.${NC}"
    else
        stop_spinner
        echo -e "\n${YELLOW}--- HUONG DAN SU DUNG ---${NC}"
        echo -e "1. Truy cap vao N8N qua trinh duyet."
        echo -e "2. Tim workflow ${GREEN}[CloudFly] Import Workflows, Credentials${NC} trong danh sach 'Workflows'."
        echo -e "3. ${GREEN}Kich hoat (Activate)${NC} workflow va doc huong dan trong workflow de su dung."
    fi
    sudo rm -f "${import_log}"
    
    start_spinner "Don dep thu muc tam trong container..."
    sudo docker exec -u node "${N8N_CONTAINER_NAME}" rm -rf "${container_temp_import_dir}" &>/dev/null
    stop_spinner

    trap - ERR SIGINT SIGTERM
    echo -e "\n${YELLOW}Nhan Enter de quay lai menu chinh...${NC}"
    read -r
}

uninstall() {
    echo -e "\n${YELLOW}[*] Dang kiem tra va go bo cong cu tai: ${INSTALL_PATH}${NC}"
    if [[ -f "$INSTALL_PATH" ]]; then
        # Su dung sudo de xoa file trong /usr/local/bin
        if sudo rm -f "$INSTALL_PATH"; then
            if [[ $? -eq 0 ]]; then
                echo -e "${GREEN}[+] Da go bo '$INSTALL_PATH' thanh cong.${NC}"
            else
                echo -e "${RED}[!] Gap loi khong xac dinh khi go bo.${NC}"
            fi
        else
             echo -e "${RED}[!] Loi khi thuc hien lenh go bo (kiem tra quyen sudo).${NC}"
        fi
    else
        echo -e "${YELLOW}[!] Khong tim thay file cong cu tai '${INSTALL_PATH}'.${NC}"
    fi
    exit 0
}

if [[ "$1" == "--help" ]]; then
    show_help
fi

# Kiem tra tham so --uninstall
if [[ "$1" == "--uninstall" ]]; then
    uninstall
fi

show_help() {
    echo "N8N Cloud Manager - Cong cu quan ly N8N tren CloudFly"
    echo "Cach su dung: n8n-host [tuy chon]"
    echo "Tuy chon:"
    echo "  --help      Hien thi thong tin tro giup nay"
    echo "  --uninstall Go bo n8n-host khoi he thong"
    exit 0
}

# --- Hien thi Menu Chinh ---
show_menu() {
  clear
  printf "${CYAN}+==================================================================================+${NC}\n"
  printf "${CYAN}|                                N8N Cloud Manager                                 |${NC}\n"
  printf "${CYAN}|                    Powered by CloudFly - https://cloudfly.vn                     |${NC}\n"
  printf "${CYAN}+==================================================================================+${NC}\n"
  echo ""
  echo -e " ${YELLOW}Phim tat: Nhan Ctrl + C hoac nhap 0 de thoat${NC}" 
  echo -e " ${GREEN}Xem huong dan:${NC} ${CYAN}https://cloudfly.vn/link/n8n-cloud-docs${NC}"
  echo "------------------------------------------------------------------------------------"
  printf " %-3s %-35s %-3s ${YELLOW}%s${NC}\n" "1)" "Cai dat N8N" "6)" "Export tat ca (workflow & credentials)" 
  printf " %-3s %-35s %-3s %s\n" "2)" "Thay doi ten mien" "7)" "Import workflow & credentials"
  printf " %-3s %-35s %-3s ${GREEN}%s${NC}\n" "3)" "Nang cap phien ban N8N" "8)" "Lay thong tin Redis" 
  printf " %-3s %-35s %-3s ${RED}%s${NC}\n" "4)" "Tat xac thuc 2 buoc (2FA/MFA)" "9)" "Xoa N8N va cai dat lai" 
  printf " %-3s %-35s %-3s %s\n" "5)" "Dat lai thong tin dang nhap"
  echo "------------------------------------------------------------------------------------"
  read -p "$(echo -e ${CYAN}'Nhap lua chon cua ban (1-9) [ 0 = Thoat ]: '${NC})" choice
  echo ""
}


while true; do
  show_menu
  case "$choice" in
    1) install ;;            
    2) change_domain ;; 
    3) upgrade_n8n_version ;;       
    4) disable_mfa ;;   
    5) reset_user_login ;;    
    6) export_all_data ;;    
    7) import_data ;; 
    8) get_redis_info ;;  
    9) reinstall_n8n ;;   
    *) 
      if [[ "$choice" == "0" ]]; then
        echo "Tam biet!"
        exit 0
      # Kiem tra cac lua chon khong hop le
      elif ! [[ "$choice" =~ ^[1-9]$ ]]; then
        echo -e "${RED}[!] Lua chon khong dung. Vui long chon lai.${NC}"
      fi
      sleep 1 
      ;;
  esac
done
