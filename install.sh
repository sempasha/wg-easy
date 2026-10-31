#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly APP_DIR="${APP_DIR:-/opt/wg-easy}"
readonly REPOSITORY_URL="${REPOSITORY_URL:-https://github.com/sempasha/wg-easy.git}"
readonly REPOSITORY_REF="${REPOSITORY_REF:-master}"
readonly HELPER_IMAGE="alpine:3.20"

NEW_USER=""
NEW_USER_KEY_FILE=""
NEW_SSH_PORT="22"
APP_READY=0
SOURCE_HOST=""
SOURCE_PORT="22"
SOURCE_USER=""
SOURCE_AUTH=""
SOURCE_KEY_FILE=""
SOURCE_PASSWORD_FD=""
SOURCE_KNOWN_HOSTS=""
SOURCE_DOCKER=""
SOURCE_SSH_OPTIONS=()
declare -a CURRENT_SSH_PORTS=()
declare -a SOURCE_STOPPED=()
declare -a SOURCE_WAS_RUNNING=()

log() { printf '\n🚀 [%s] %s\n' "$SCRIPT_NAME" "$*"; }
warn() { printf '\n⚠️  WARNING: %s\n' "$*" >&2; }
die() { printf '\n❌ ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  local status=$? i container
  set +e
  for i in "${!SOURCE_STOPPED[@]}"; do
    container="${SOURCE_STOPPED[$i]}"
    if [[ "${SOURCE_WAS_RUNNING[$i]}" == true ]]; then
      source_exec "$SOURCE_DOCKER start $(printf '%q' "$container") >/dev/null" || \
        warn "Could not restart old container $container"
    fi
  done
  [[ -n "$SOURCE_PASSWORD_FD" ]] && eval "exec ${SOURCE_PASSWORD_FD}<&-" 2>/dev/null || true
  [[ -n "$SOURCE_KEY_FILE" ]] && rm -f -- "$SOURCE_KEY_FILE" "$SOURCE_KEY_FILE.pub"
  [[ -n "$SOURCE_KNOWN_HOSTS" ]] && rm -f -- "$SOURCE_KNOWN_HOSTS"
  exit "$status"
}
trap cleanup EXIT

ask() {
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$prompt: " answer
    printf '%s' "$answer"
  fi
}

yes_or_no() {
  local answer
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

require_root() { [[ "$(id -u)" == 0 ]] || die "Run this script as root"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl git iproute2 jq openssh-client openssh-server sudo tar ufw
  command -v docker >/dev/null 2>&1 || apt-get install -y docker.io
  getent group docker >/dev/null 2>&1 || groupadd docker
  docker compose version >/dev/null 2>&1 || {
    apt-get install -y docker-compose-v2 2>/dev/null || apt-get install -y docker-compose-plugin
  }
  systemctl enable --now docker
  systemctl enable --now ssh
}

configure_ipv6() {
  local sysctl_file=/etc/sysctl.d/99-wg-easy-ipv6.conf daemon=/etc/docker/daemon.json temp backup
  if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" != 0 || \
        "$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 1)" != 0 ]]; then
    cat >"$sysctl_file" <<'EOF'
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
EOF
    sysctl --system >/dev/null
  fi
  [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" == 0 ]] || die "Could not enable IPv6 in the kernel"
  mkdir -p /etc/docker
  if [[ -e "$daemon" ]] && ! jq -e 'type == "object"' "$daemon" >/dev/null 2>&1; then
    die "$daemon is not a JSON object"
  fi
  temp="$(mktemp)"
  if [[ -e "$daemon" ]]; then jq '. + {ipv6: true, ip6tables: true}' "$daemon" >"$temp"; else printf '%s\n' '{"ipv6":true,"ip6tables":true}' >"$temp"; fi
  if [[ ! -e "$daemon" ]] || ! cmp -s "$temp" "$daemon"; then
    if [[ -e "$daemon" ]]; then backup="${daemon}.wg-easy.$(date +%Y%m%d%H%M%S).bak"; cp -a "$daemon" "$backup"; log "Docker configuration backup: $backup"; fi
    install -m 0644 "$temp" "$daemon"
    systemctl restart docker
  fi
  rm -f "$temp"
  local address route
  address="$(ip -6 -o addr show scope global 2>/dev/null | awk 'NR==1 {print $4}' || true)"
  route="$(ip -6 route show default 2>/dev/null | head -n1 || true)"
  [[ -n "$address" && -n "$route" ]] && log "✅ Host IPv6: $address" || warn "No public IPv6 address/default route was detected"
  curl -6fsS --max-time 10 https://api64.ipify.org >/dev/null 2>&1 && log "✅ Outbound IPv6 works" || warn "Outbound IPv6 connectivity could not be verified"
}

read_public_key() {
  local key
  NEW_USER_KEY_FILE="$(mktemp)"
  while :; do
    read -r -p "Public SSH key: " key
    printf '%s\n' "$key" >"$NEW_USER_KEY_FILE"
    ssh-keygen -lf "$NEW_USER_KEY_FILE" >/dev/null 2>&1 && break
    warn "Invalid OpenSSH public key"
  done
}

create_admin() {
  local user current
  current="${SUDO_USER:-${USER:-admin}}"; [[ "$current" == root ]] && current=admin
  user="$(ask "Administrator username" "$current")"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username"
  read_public_key
  id "$user" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$user"
  usermod --append --groups sudo,docker "$user" 2>/dev/null || usermod --append --groups sudo "$user"
  install -d -m 0700 -o "$user" -g "$user" "/home/$user/.ssh"
  touch "/home/$user/.ssh/authorized_keys"
  cat "$NEW_USER_KEY_FILE" >>"/home/$user/.ssh/authorized_keys"
  chown "$user:$user" "/home/$user/.ssh/authorized_keys"
  chmod 0600 "/home/$user/.ssh/authorized_keys"
  NEW_USER="$user"
}

configure_ssh() {
  local -a current_ports=() port
  local selected port_file verified_user
  mapfile -t current_ports < <(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -nu)
  ((${#current_ports[@]} > 0)) || current_ports=(22)
  CURRENT_SSH_PORTS=("${current_ports[@]}")
  NEW_SSH_PORT="${current_ports[0]}"

  if yes_or_no "Change SSH port from ${current_ports[*]}?"; then
    selected="$(ask "New SSH port" "${current_ports[0]}")"
    [[ "$selected" =~ ^[0-9]+$ ]] || die "SSH port must be numeric"
    port_file=/etc/ssh/sshd_config.d/90-wg-easy-ports.conf
    { for port in "${current_ports[@]}"; do printf 'Port %s\n' "$port"; done; printf 'Port %s\n' "$selected"; } >"$port_file"
    sshd -t && systemctl reload ssh || die "Invalid SSH configuration"
    NEW_SSH_PORT="$selected"
  fi

  if yes_or_no "Disable root SSH login and SSH password authentication?"; then
    verified_user="$NEW_USER"
    [[ -n "$verified_user" ]] || verified_user="$(ask "Username whose key-based login you verified")"
    printf 'Test now: ssh -p %s %s@<server-address>\n' "$NEW_SSH_PORT" "$verified_user"
    if yes_or_no "Did key-based SSH login succeed?"; then
      cat >/etc/ssh/sshd_config.d/99-wg-easy-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
EOF
      sshd -t && systemctl reload ssh || die "Invalid SSH hardening configuration"
      passwd -l root >/dev/null 2>&1 || true
    else
      warn "SSH hardening skipped"
    fi
  fi
}

prepare_repository() {
  local script_dir="$(cd "$(dirname "$0")" && pwd)"
  if [[ -f "$script_dir/docker-compose.yaml" && -d "$script_dir/traefik" ]]; then
    mkdir -p "$APP_DIR"; cp -a "$script_dir/." "$APP_DIR/"
  elif [[ -e "$APP_DIR/.git" ]]; then
    warn "$APP_DIR already exists; existing files are preserved"
  else
    [[ ! -e "$APP_DIR" ]] || die "$APP_DIR exists and is not a Git checkout"
    git clone --depth 1 --branch "$REPOSITORY_REF" "$REPOSITORY_URL" "$APP_DIR"
  fi
  [[ -f "$APP_DIR/docker-compose.yaml" ]] || die "Compose file not found"
}

configure_application() {
  local domain email
  domain="$(ask "Domain name")"; email="$(ask "Let's Encrypt email")"
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid domain"
  [[ "$email" == *@*.* ]] || die "Invalid email"
  printf 'COMPOSE_PROJECT_NAME=wg-easy\nDOMAIN_NAME=%s\nACME_EMAIL=%s\n' "$domain" "$email" >"$APP_DIR/.env"
  chmod 0600 "$APP_DIR/.env"
  touch "$APP_DIR/traefik/acme.json"; chmod 0600 "$APP_DIR/traefik/acme.json"
  docker compose -f "$APP_DIR/docker-compose.yaml" --env-file "$APP_DIR/.env" config >/dev/null
  APP_READY=1
}

configure_firewall() {
  local mapping published protocol port
  if grep -q '^IPV6=' /etc/default/ufw; then sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw; else printf '\nIPV6=yes\n' >>/etc/default/ufw; fi
  ufw allow "${NEW_SSH_PORT}/tcp" >/dev/null
  for port in "${CURRENT_SSH_PORTS[@]}"; do ufw allow "${port}/tcp" >/dev/null; done
  if [[ "$APP_READY" == 1 ]]; then
    while IFS= read -r mapping; do
      [[ -n "$mapping" ]] || continue
      published="${mapping%%/*}"; published="${published%%:*}"; protocol="${mapping##*/}"
      [[ "$published" =~ ^[0-9]+$ && ( "$protocol" == tcp || "$protocol" == udp ) ]] && ufw allow "$published/$protocol" >/dev/null
    done < <(docker compose -f "$APP_DIR/docker-compose.yaml" --env-file "$APP_DIR/.env" config --format json 2>/dev/null | jq -r '.services[]?.ports[]? | if type == "string" then . else ((.published|tostring)+":"+(.target|tostring)+"/"+(.protocol // "tcp")) end' 2>/dev/null || true)
  fi
  ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null; ufw --force enable >/dev/null
}

source_ssh() {
  local -a cmd=(ssh); cmd+=("${SOURCE_SSH_OPTIONS[@]}")
  [[ "$SOURCE_AUTH" == password ]] && cmd=(sshpass -d "$SOURCE_PASSWORD_FD" "${cmd[@]}")
  "${cmd[@]}" "$SOURCE_USER@$SOURCE_HOST" -- "$1"
}
source_exec() { source_ssh "$1"; }

setup_source_auth() {
  local password temp public
  SOURCE_HOST="$(ask "Old server hostname or IP")"; SOURCE_PORT="$(ask "Old server SSH port" 22)"; SOURCE_USER="$(ask "Old server username" "${NEW_USER:-}")"
  SOURCE_KNOWN_HOSTS="$(mktemp)"; SOURCE_SSH_OPTIONS=(-p "$SOURCE_PORT" -o "UserKnownHostsFile=$SOURCE_KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
  printf '1) temporary key\n2) paste private key\n3) password\n'; SOURCE_AUTH="$(ask "Authentication method" 1)"
  case "$SOURCE_AUTH" in
    1) temp="$(mktemp)"; rm -f "$temp"; ssh-keygen -q -t ed25519 -N '' -f "$temp" -C wg-easy-migration; SOURCE_KEY_FILE="$temp"; public="$(cat "$temp.pub")"; printf '\nAdd this key to %s@%s:\n%s\n' "$SOURCE_USER" "$SOURCE_HOST" "$public"; read -r -p "Press Enter after adding it..." _; SOURCE_SSH_OPTIONS+=(-i "$temp"); ;;
    2) SOURCE_KEY_FILE="$(mktemp)"; chmod 0600 "$SOURCE_KEY_FILE"; printf 'Paste private key, then type END_PRIVATE_KEY on a new line.\n'; while IFS= read -r temp; do [[ "$temp" == END_PRIVATE_KEY ]] && break; printf '%s\n' "$temp" >>"$SOURCE_KEY_FILE"; done; SOURCE_SSH_OPTIONS+=(-i "$SOURCE_KEY_FILE"); ;;
    3) if ! command -v sshpass >/dev/null 2>&1; then yes_or_no "Install sshpass for password authentication?" || die "Password authentication cannot be used without sshpass"; apt-get install -y sshpass; fi; password="$(read -r -s -p 'Old server password: ' temp; printf '\n' >&2; printf '%s' "$temp")"; exec {SOURCE_PASSWORD_FD}<<<"$password"; unset password; ;;
    *) die "Authentication method must be 1, 2, or 3" ;;
  esac
  local result; result="$(source_exec 'docker ps >/dev/null 2>&1 && echo direct || { sudo -n docker ps >/dev/null 2>&1 && echo sudo || echo none; }')"
  case "$result" in direct) SOURCE_DOCKER=docker ;; sudo) SOURCE_DOCKER='sudo -n docker' ;; *) die "Old user has no Docker access" ;; esac
  if ! source_exec "$SOURCE_DOCKER image inspect $HELPER_IMAGE >/dev/null 2>&1"; then
    yes_or_no "Pull $HELPER_IMAGE on the old server for volume transfer?" || die "The helper image is required for migration"
    source_exec "$SOURCE_DOCKER pull $HELPER_IMAGE >/dev/null"
  fi
}

local_service_value() { docker compose -f "$APP_DIR/docker-compose.yaml" --env-file "$APP_DIR/.env" config --format json | jq -r --arg s "$1" --arg k "$2" '.services[$s][$k] // empty'; }
image_repo() { local x="${1%@*}"; [[ "${x##*/}" == *:* ]] && x="${x%:*}"; printf '%s' "$x"; }

find_source_container() {
  local service="$1" expected_name expected_image expected_repo line id name image repo choice i
  local -a candidates=() all=()
  expected_name="$(local_service_value "$service" container_name)"; expected_image="$(local_service_value "$service" image)"; expected_repo="$(image_repo "$expected_image")"
  mapfile -t all < <(source_exec "$SOURCE_DOCKER ps -a --format '{{.ID}} {{.Names}} {{.Image}}'")
  for line in "${all[@]}"; do read -r id name image <<<"$line"; [[ "$name" == "$expected_name" && -n "$expected_name" ]] && { printf '%s' "$id"; return; }; done
  for line in "${all[@]}"; do read -r id name image <<<"$line"; [[ "$image" == "$expected_image" && -n "$expected_image" ]] && { printf '%s' "$id"; return; }; done
  for line in "${all[@]}"; do read -r id name image <<<"$line"; repo="$(image_repo "$image")"; [[ "$repo" == "$expected_repo" && -n "$expected_repo" ]] && candidates+=("$id $name $image"); done
  ((${#candidates[@]} == 1)) && { printf '%s' "${candidates[0]%% *}"; return; }
  ((${#all[@]} > 0)) || return 1
  printf '\nNo automatic match for Compose service %s. Select the old container:\n' "$service" >&2
  for i in "${!all[@]}"; do printf '  %d) %s\n' "$((i+1))" "${all[$i]}" >&2; done
  choice="$(ask "Container number (0 skips)" 0)"; [[ "$choice" =~ ^[0-9]+$ && "$choice" -gt 0 && "$choice" -le ${#all[@]} ]] || return 1
  printf '%s' "${all[$((choice-1))]%% *}"
}

source_mount() {
  local service="$1" target="$2" container mount escaped quoted_container
  container="$(find_source_container "$service" || true)"; [[ -n "$container" ]] || return 1
  escaped="$target"
  printf -v quoted_container '%q' "$container"
  mount="$(source_exec "$SOURCE_DOCKER inspect -f '{{range .Mounts}}{{if eq .Destination \"$escaped\"}}{{.Type}}|{{.Name}}|{{.Source}}{{end}}{{end}}' $quoted_container")"
  [[ -n "$mount" ]] || { warn "No mount at $target in the selected old container"; return 1; }
  printf '%s\t%s\n' "$container" "$mount"
}

stop_source() {
  local container="$1" running i
  for i in "${!SOURCE_STOPPED[@]}"; do [[ "${SOURCE_STOPPED[$i]}" == "$container" ]] && return; done
  running="$(source_exec "$SOURCE_DOCKER inspect -f '{{.State.Running}}' $(printf '%q' "$container")")"; SOURCE_STOPPED+=("$container"); SOURCE_WAS_RUNNING+=("$running")
  [[ "$running" == true ]] && source_exec "$SOURCE_DOCKER stop $(printf '%q' "$container") >/dev/null"
}

prepare_destination_volume() {
  local volume="$1" backup
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    docker volume create "$volume" >/dev/null
    return 0
  fi
  if docker run --rm -v "$volume:/data:ro" "$HELPER_IMAGE" sh -c 'test -n "$(find /data -mindepth 1 -print -quit)"' >/dev/null 2>&1; then
    yes_or_no "Overwrite existing destination volume $volume?" || return 1
    mkdir -p /var/backups/wg-easy; chmod 0700 /var/backups/wg-easy
    backup="/var/backups/wg-easy/${volume//[^A-Za-z0-9_.-]/_}-$(date +%Y%m%d%H%M%S).tar.gz"
    docker run --rm -v "$volume:/from:ro" -v /var/backups/wg-easy:/backup "$HELPER_IMAGE" tar -C /from -czf "/backup/$(basename "$backup")" .
    docker run --rm -v "$volume:/to" "$HELPER_IMAGE" sh -c 'find /to -mindepth 1 -delete'
    log "Destination backup: $backup"
  fi
  return 0
}

copy_volume() {
  local service="$1" logical="$2" target="$3" found container mount type source destination
  found="$(source_mount "$service" "$target" || true)"; [[ -n "$found" ]] || return 1
  container="${found%%$'\t'*}"; mount="${found#*$'\t'}"; type="${mount%%|*}"; mount="${mount#*|}"; source="${mount#*|}"
  [[ "$type" == volume ]] || { warn "Expected a Docker volume at $target"; return 1; }
  destination="$(docker compose -f "$APP_DIR/docker-compose.yaml" --env-file "$APP_DIR/.env" config --format json | jq -r --arg v "$logical" '.volumes[$v].name // $v')"
  stop_source "$container"; prepare_destination_volume "$destination" || { warn "Skipped destination volume $destination"; return 1; }
  log "Copying old volume $source to $destination"
  source_exec "$SOURCE_DOCKER run --rm -v $(printf '%q' "$source"):/from:ro $HELPER_IMAGE tar -C /from -cf - ." | docker run --rm -i -v "$destination:/to" "$HELPER_IMAGE" tar -C /to -xf -
}

copy_acme() {
  local service="$1" source_path="$2" found container mount type source destination escaped
  found="$(source_mount "$service" /etc/traefik/acme.json || true)"; [[ -n "$found" ]] || return 0
  container="${found%%$'\t'*}"; mount="${found#*$'\t'}"; type="${mount%%|*}"; mount="${mount#*|}"; source="${mount#*|}"
  [[ "$type" == bind ]] || return 0; destination="$APP_DIR/${source_path#./}"; stop_source "$container"; mkdir -p "$(dirname "$destination")"; printf -v escaped '%q' "$source"; source_exec "cat -- $escaped" >"$destination"; chmod 0600 "$destination"
}

migrate_data() {
  local line service logical target source_path
  while IFS=$'\t' read -r service logical target; do
    [[ -n "$logical" ]] || continue
    copy_volume "$service" "$logical" "$target" || warn "Skipped volume $logical"
  done < <(docker compose -f "$APP_DIR/docker-compose.yaml" --env-file "$APP_DIR/.env" config --format json | jq -r '.services | to_entries[] as $s | ($s.value.volumes // [])[] | select(.type == "volume") | [$s.key,.source,.target] | @tsv')
  while IFS=$'\t' read -r service source_path target; do
    [[ "$target" == /etc/traefik/acme.json ]] && copy_acme "$service" "$source_path"
  done < <(docker compose -f "$APP_DIR/docker-compose.yaml" --env-file "$APP_DIR/.env" config --format json | jq -r '.services | to_entries[] as $s | ($s.value.volumes // [])[] | select(.type == "bind") | [$s.key,.source,.target] | @tsv')
}

start_application() {
  (cd "$APP_DIR" && docker compose --env-file .env up -d)
  docker compose -f "$APP_DIR/docker-compose.yaml" --env-file "$APP_DIR/.env" ps
  check_compose_ipv6
  check_endpoints
}

check_compose_ipv6() {
  local network_json address
  network_json="$(docker network inspect wg-easy 2>/dev/null || true)"
  [[ -n "$network_json" ]] || { warn "Docker network wg-easy was not found"; return; }
  jq -e '.[0].EnableIPv6 == true' <<<"$network_json" >/dev/null || { warn "Docker network wg-easy has no IPv6 support"; return; }
  address="$(jq -r '.[0].Containers // {} | to_entries[]?.value.IPv6Address // empty' <<<"$network_json" | head -n1)"
  [[ -n "$address" ]] && log "✅ Docker IPv6 network is working: $address" || warn "No container IPv6 address was found"
}

check_endpoints() {
  local domain ip
  domain="$(sed -n 's/^DOMAIN_NAME=//p' "$APP_DIR/.env")"
  ip="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  [[ -n "$ip" ]] && log "DNS: $domain -> $ip" || warn "DNS name $domain does not resolve yet"
  curl -fsSIL --max-time 15 "http://$domain" >/dev/null 2>&1 && log "✅ HTTP endpoint is reachable" || warn "HTTP endpoint check failed"
  curl -kfsSIL --max-time 15 "https://$domain" >/dev/null 2>&1 && log "✅ HTTPS endpoint is reachable" || warn "HTTPS endpoint check failed"
}

main() {
  require_root; source /etc/os-release; [[ "$ID" == ubuntu && ( "$VERSION_ID" == 22.04 || "$VERSION_ID" == 24.04 ) ]] || die "Ubuntu 22.04 or 24.04 is required"
  if yes_or_no "Install or update packages, Docker, and SSH?"; then
    install_packages
  else
    require_command docker; require_command jq; require_command sshd
  fi
  if yes_or_no "Configure host and Docker IPv6?"; then configure_ipv6; else log "IPv6 configuration skipped"; fi
  if yes_or_no "Create an administrator and install a public SSH key?"; then create_admin; else log "Administrator setup skipped"; fi
  if yes_or_no "Download or prepare Compose files?"; then prepare_repository; else log "Compose preparation skipped"; fi
  if [[ -f "$APP_DIR/docker-compose.yaml" ]] && yes_or_no "Create application .env and ACME file?"; then configure_application; else log "Application configuration skipped"; fi
  if yes_or_no "Configure SSH port and hardening?"; then configure_ssh; else log "SSH configuration skipped"; fi
  if yes_or_no "Configure UFW firewall?"; then configure_firewall; else log "Firewall configuration skipped"; fi
  if [[ "$APP_READY" == 1 ]] && yes_or_no "Migrate data from an old server?"; then setup_source_auth; migrate_data; else log "Data migration skipped"; fi
  if [[ "$APP_READY" == 1 ]] && yes_or_no "Start Docker Compose?"; then start_application; else log "Docker Compose startup skipped"; fi
  log "✅ Finished"
}
main "$@"
