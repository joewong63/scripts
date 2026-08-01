#!/usr/bin/env bash
set -euo pipefail

# HTTPS subscription service for Argosbx-generated files.
# It serves a dedicated directory that only contains symlinks to the source files,
# so source file updates are visible immediately without copying.

SCRIPT_NAME="${0##*/}"

STATE_DIR="/etc/agsbx-https-sub"
STATE_FILE="$STATE_DIR/config.env"
TOKEN_FILE="$STATE_DIR/token"
DATA_DIR="/var/lib/agsbx-https-sub"
PUBLIC_ROOT="$DATA_DIR/public"
CADDY_CONF_DIR="/etc/caddy/conf.d"
CADDY_SNIPPET="$CADDY_CONF_DIR/agsbx-sub.caddy"
CADDY_PLACEHOLDER="$CADDY_CONF_DIR/00-empty.caddy"

DEFAULT_SOURCE_DIR="$HOME/agsbx"
DEFAULT_HTTPS_PORT="8443"

COMMAND="install"
SOURCE_DIR="$DEFAULT_SOURCE_DIR"
HTTPS_PORT="$DEFAULT_HTTPS_PORT"
PUBLIC_IP=""
HTTPS_HOST=""
TOKEN_OVERRIDE=""
ROTATE_TOKEN="0"
KEEP_STATE="0"
CONTENT_TARGET=""
TOKEN=""

log() {
  printf '[agsbx-sub] %s\n' "$*"
}

die() {
  printf '[agsbx-sub] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME install [options]
  $SCRIPT_NAME show
  $SCRIPT_NAME cat jhsub|sbox|clmi|all
  $SCRIPT_NAME remove [--keep-state]

Commands:
  install       Install or update the HTTPS subscription service.
  show          Show service config, file status, and subscription URLs.
  cat           Print local subscription file content from the configured source dir.
  remove        Remove only this HTTPS subscription service config.

Install options:
  -d, --source-dir DIR     Source dir containing clmi.yaml, sbox.json, jhsub.txt.
                           Default: $DEFAULT_SOURCE_DIR
  -p, --port PORT          HTTPS listen port. Default: $DEFAULT_HTTPS_PORT
  --public-ip IP           IPv4 used to build IP.sslip.io hostname.
  --host HOST              Explicit hostname. Example: 1-2-3-4.sslip.io
  -t, --token TOKEN        Set a fixed URL token. Reuses existing token if omitted.
  --rotate-token           Generate a new random token.

Remove options:
  --keep-state             Remove Caddy site config but keep saved token/config.

Examples:
  $SCRIPT_NAME install
  $SCRIPT_NAME install --port 2053
  $SCRIPT_NAME install --source-dir "\$HOME/agsbx" --public-ip 1.2.3.4
  $SCRIPT_NAME install --host 1-2-3-4.sslip.io --port 8443 --token my-long-secret-token
  $SCRIPT_NAME show
  $SCRIPT_NAME cat jhsub
  $SCRIPT_NAME remove
EOF
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "run as root. Example: sudo bash $SCRIPT_NAME install --source-dir \"\$HOME/agsbx\""
  fi
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

has_openrc() {
  command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1
}

expand_source_dir() {
  case "$SOURCE_DIR" in
    "~")
      SOURCE_DIR="$HOME"
      ;;
    "~/"*)
      SOURCE_DIR="$HOME/${SOURCE_DIR#~/}"
      ;;
  esac

  if [ "${SOURCE_DIR#/}" = "$SOURCE_DIR" ]; then
    SOURCE_DIR="$(pwd -P)/$SOURCE_DIR"
  fi
}

is_ipv4() {
  printf '%s\n' "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
    }
  '
}

validate_port() {
  case "$HTTPS_PORT" in
    ''|*[!0-9]*)
      die "port must be a number"
      ;;
  esac

  if [ "$HTTPS_PORT" -lt 1 ] || [ "$HTTPS_PORT" -gt 65535 ]; then
    die "port must be between 1 and 65535"
  fi
}

validate_host() {
  case "$HTTPS_HOST" in
    ""|*"://"*|*/*|*:*|*_*|.*|*.)
      die "host must be a hostname only, without scheme, slash, underscore, or port"
      ;;
  esac

  if ! printf '%s' "$HTTPS_HOST" | grep -Eq '^[A-Za-z0-9.-]+$'; then
    die "host contains unsupported characters"
  fi
}

validate_token() {
  local token="$1"

  if ! printf '%s' "$token" | grep -Eq '^[A-Za-z0-9._~-]{12,128}$'; then
    die "token must be 12-128 URL-safe characters: A-Z a-z 0-9 . _ ~ -"
  fi
}

install_base_tools() {
  if command -v curl >/dev/null 2>&1 \
    && command -v openssl >/dev/null 2>&1 \
    && command -v setfacl >/dev/null 2>&1; then
    return
  fi

  log "Installing basic tools"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl ca-certificates openssl gpg acl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates openssl gnupg2 acl
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ca-certificates openssl bash acl
  else
    die "cannot install curl/openssl/acl automatically on this OS"
  fi

  update-ca-certificates >/dev/null 2>&1 || true
}

install_caddy() {
  if command -v caddy >/dev/null 2>&1; then
    log "Caddy is already installed: $(caddy version 2>/dev/null || true)"
    return
  fi

  log "Installing Caddy"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
    install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
      | gpg --dearmor > /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
      > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y dnf-plugins-core || dnf install -y 'dnf-command(copr)'
    dnf copr enable -y @caddy/caddy
    dnf install -y caddy
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache caddy
  else
    die "cannot install Caddy automatically on this OS"
  fi
}

detect_public_ipv4() {
  local ip
  for url in \
    "https://api.ipify.org" \
    "https://icanhazip.com" \
    "https://ifconfig.me/ip"
  do
    ip="$(curl -4fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

resolve_host() {
  if [ -n "$HTTPS_HOST" ]; then
    validate_host
    return
  fi

  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="$(detect_public_ipv4)" || die "cannot detect public IPv4. Use --public-ip 1.2.3.4 or --host 1-2-3-4.sslip.io"
  fi

  is_ipv4 "$PUBLIC_IP" || die "--public-ip must be a valid IPv4 address"
  HTTPS_HOST="${PUBLIC_IP//./-}.sslip.io"
  validate_host
}

generate_random_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    tr -d '-' < /proc/sys/kernel/random/uuid
  else
    date +%s%N | sha256sum | awk '{print $1}'
  fi
}

resolve_token() {
  if [ -n "$TOKEN_OVERRIDE" ]; then
    validate_token "$TOKEN_OVERRIDE"
    TOKEN="$TOKEN_OVERRIDE"
    return
  fi

  if [ "$ROTATE_TOKEN" = "1" ]; then
    TOKEN="$(generate_random_token)"
    validate_token "$TOKEN"
    return
  fi

  if [ -s "$TOKEN_FILE" ]; then
    TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    validate_token "$TOKEN"
    return
  fi

  TOKEN="$(generate_random_token)"
  validate_token "$TOKEN"
}

write_state() {
  mkdir -p "$STATE_DIR"
  chmod 0700 "$STATE_DIR"

  printf '%s\n' "$TOKEN" > "$TOKEN_FILE"
  chmod 0600 "$TOKEN_FILE"

  {
    printf 'SOURCE_DIR=%q\n' "$SOURCE_DIR"
    printf 'PUBLIC_ROOT=%q\n' "$PUBLIC_ROOT"
    printf 'HTTPS_HOST=%q\n' "$HTTPS_HOST"
    printf 'HTTPS_PORT=%q\n' "$HTTPS_PORT"
    printf 'TOKEN=%q\n' "$TOKEN"
  } > "$STATE_FILE"
  chmod 0600 "$STATE_FILE"
}

load_state() {
  [ -f "$STATE_FILE" ] || die "HTTPS subscription service is not installed. Run: $SCRIPT_NAME install"

  # shellcheck disable=SC1090
  . "$STATE_FILE"

  [ -n "${SOURCE_DIR:-}" ] || die "saved SOURCE_DIR is empty"
  PUBLIC_ROOT="${PUBLIC_ROOT:-$DATA_DIR/public}"
  [ -n "${HTTPS_HOST:-}" ] || die "saved HTTPS_HOST is empty"
  [ -n "${HTTPS_PORT:-}" ] || die "saved HTTPS_PORT is empty"
  [ -n "${TOKEN:-}" ] || die "saved TOKEN is empty"

  validate_port
  validate_host
  validate_token "$TOKEN"
}

ensure_caddy_import() {
  mkdir -p "$CADDY_CONF_DIR"
  [ -f "$CADDY_PLACEHOLDER" ] || printf '# Empty placeholder for Caddy import glob.\n' > "$CADDY_PLACEHOLDER"

  if [ ! -f /etc/caddy/Caddyfile ]; then
    printf 'import /etc/caddy/conf.d/*.caddy\n' > /etc/caddy/Caddyfile
    return
  fi

  if ! grep -Eq '^[[:space:]]*import[[:space:]]+/etc/caddy/conf\.d/\*\.caddy' /etc/caddy/Caddyfile; then
    cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d%H%M%S)"
    printf '\nimport /etc/caddy/conf.d/*.caddy\n' >> /etc/caddy/Caddyfile
  fi
}

escape_caddy_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_caddy_site() {
  local public_root_escaped
  public_root_escaped="$(escape_caddy_string "$PUBLIC_ROOT")"

  cat > "$CADDY_SNIPPET" <<EOF
https://$HTTPS_HOST:$HTTPS_PORT {
    @subfiles path /$TOKEN/clmi.yaml /$TOKEN/sbox.json /$TOKEN/jhsub.txt
    handle @subfiles {
        root * "$public_root_escaped"
        file_server
    }

    handle {
        respond "not found" 404
    }

    header @subfiles {
        Cache-Control "no-store"
        X-Content-Type-Options "nosniff"
    }
}
EOF

  caddy fmt --overwrite "$CADDY_SNIPPET" >/dev/null 2>&1 || true
  caddy validate --config /etc/caddy/Caddyfile
}

start_or_reload_caddy() {
  if has_systemd; then
    systemctl enable caddy
    if systemctl is-active --quiet caddy; then
      systemctl reload caddy || systemctl restart caddy
    else
      systemctl start caddy
    fi
  elif has_openrc; then
    rc-update add caddy default >/dev/null 2>&1 || true
    rc-service caddy status >/dev/null 2>&1 && rc-service caddy reload || rc-service caddy start
  else
    die "systemd/OpenRC not found; cannot configure Caddy auto-start"
  fi
}

reload_caddy_if_running() {
  command -v caddy >/dev/null 2>&1 || return

  if has_systemd; then
    if systemctl is-active --quiet caddy; then
      systemctl reload caddy || systemctl restart caddy
    fi
  elif has_openrc; then
    if rc-service caddy status >/dev/null 2>&1; then
      rc-service caddy reload || rc-service caddy restart
    fi
  fi
}

prepare_symlink_tree() {
  local link_dir file target link_path

  link_dir="$PUBLIC_ROOT/$TOKEN"
  mkdir -p "$link_dir"
  chmod 0755 "$DATA_DIR" "$PUBLIC_ROOT" "$link_dir"

  for file in clmi.yaml sbox.json jhsub.txt; do
    target="$SOURCE_DIR/$file"
    link_path="$link_dir/$file"

    if [ -e "$link_path" ] && [ ! -L "$link_path" ]; then
      rm -f "$link_path"
    fi

    ln -sfn "$target" "$link_path"
  done
}

service_status() {
  if has_systemd; then
    systemctl is-active caddy 2>/dev/null || true
  elif has_openrc; then
    rc-service caddy status 2>/dev/null | sed -n '1p' || true
  else
    printf 'unknown\n'
  fi
}

grant_acl_on_source() {
  if ! id caddy >/dev/null 2>&1; then
    log "WARNING: caddy user not found; skipping source ACL setup"
    return
  fi

  mkdir -p "$SOURCE_DIR"

  if ! command -v setfacl >/dev/null 2>&1; then
    log "WARNING: setfacl unavailable. Ensure caddy can read $SOURCE_DIR"
    return
  fi

  local abs_dir parent dir
  abs_dir="$(cd "$SOURCE_DIR" && pwd -P)"
  parent="$(dirname "$abs_dir")"
  dir="$parent"

  while [ "$dir" != "/" ]; do
    setfacl -m u:caddy:x "$dir" 2>/dev/null || true
    dir="$(dirname "$dir")"
  done

  setfacl -m u:caddy:rx "$abs_dir" 2>/dev/null || true
  setfacl -d -m u:caddy:rx "$abs_dir" 2>/dev/null || true

  for file in clmi.yaml sbox.json jhsub.txt; do
    [ -f "$abs_dir/$file" ] && setfacl -m u:caddy:r "$abs_dir/$file" 2>/dev/null || true
  done

  SOURCE_DIR="$abs_dir"
}

warn_missing_sources() {
  local missing=""
  for file in clmi.yaml sbox.json jhsub.txt; do
    if [ ! -f "$SOURCE_DIR/$file" ]; then
      missing="$missing $SOURCE_DIR/$file"
    fi
  done

  if [ -n "$missing" ]; then
    log "WARNING: missing source file(s):$missing"
    log "URLs will return 404 for missing files until Argosbx generates them."
  fi
}

check_port_conflicts() {
  if ! command -v ss >/dev/null 2>&1; then
    return
  fi

  local https_listener http_listener
  https_listener="$(ss -ltnp "sport = :$HTTPS_PORT" 2>/dev/null | awk 'NR > 1' || true)"
  if [ -n "$https_listener" ] && ! printf '%s\n' "$https_listener" | grep -q 'caddy'; then
    printf '%s\n' "$https_listener" >&2
    die "TCP port $HTTPS_PORT is already in use. Use --port 2053/2083/2087/2096/8443 or stop the conflicting service."
  fi

  http_listener="$(ss -ltnp 'sport = :80' 2>/dev/null | awk 'NR > 1' || true)"
  if [ -n "$http_listener" ] && ! printf '%s\n' "$http_listener" | grep -q 'caddy'; then
    printf '%s\n' "$http_listener" >&2
    die "TCP port 80 is already in use. Caddy needs it for Let's Encrypt HTTP-01 validation."
  fi
}

url_for() {
  printf 'https://%s:%s/%s/%s\n' "$HTTPS_HOST" "$HTTPS_PORT" "$TOKEN" "$1"
}

print_urls() {
  printf 'Clash/Mihomo: %s\n' "$(url_for clmi.yaml)"
  printf 'Sing-box:     %s\n' "$(url_for sbox.json)"
  printf 'Aggregate:    %s\n' "$(url_for jhsub.txt)"
}

print_file_status() {
  local file path link_path size readable link_state

  for file in clmi.yaml sbox.json jhsub.txt; do
    path="$SOURCE_DIR/$file"
    link_path="$PUBLIC_ROOT/$TOKEN/$file"
    if [ -f "$path" ]; then
      size="$(wc -c < "$path" | tr -d '[:space:]')"
      readable="no"
      [ -r "$path" ] && readable="yes"
      link_state="missing"
      [ -L "$link_path" ] && link_state="symlink -> $(readlink "$link_path")"
      printf '  %-10s exists, %s bytes, readable=%s, %s\n' "$file" "$size" "$readable" "$link_state"
    else
      link_state="missing"
      [ -L "$link_path" ] && link_state="symlink -> $(readlink "$link_path")"
      printf '  %-10s missing, %s\n' "$file" "$link_state"
    fi
  done
}

map_content_target() {
  case "$1" in
    clmi|mihomo|clash|clmi.yaml)
      printf 'clmi.yaml\n'
      ;;
    sbox|singbox|sing-box|sbox.json)
      printf 'sbox.json\n'
      ;;
    jhsub|aggregate|all-in-one|jhsub.txt)
      printf 'jhsub.txt\n'
      ;;
    all)
      printf 'all\n'
      ;;
    *)
      die "unknown content target: $1. Use jhsub, sbox, clmi, or all"
      ;;
  esac
}

cmd_install() {
  require_root
  expand_source_dir
  validate_port
  install_base_tools
  resolve_host
  resolve_token
  check_port_conflicts
  install_caddy
  grant_acl_on_source
  write_state
  prepare_symlink_tree
  warn_missing_sources
  ensure_caddy_import
  write_caddy_site
  start_or_reload_caddy

  cat <<EOF

Installed.

Source dir: $SOURCE_DIR
Link dir:   $PUBLIC_ROOT/$TOKEN
Host:       $HTTPS_HOST
Port:       $HTTPS_PORT
Token:      $TOKEN

EOF
  print_urls

  cat <<EOF

Open inbound TCP 80 and $HTTPS_PORT in the VPS firewall/security group.
TCP 80 is used by Let's Encrypt validation; the subscription URLs use $HTTPS_PORT.
EOF
}

cmd_show() {
  require_root
  load_state

  cat <<EOF
HTTPS subscription service:
  State:      installed
  Caddy:      $(service_status)
  Source dir: $SOURCE_DIR
  Link dir:   $PUBLIC_ROOT/$TOKEN
  Host:       $HTTPS_HOST
  Port:       $HTTPS_PORT
  Token:      $TOKEN
  Caddy file: $CADDY_SNIPPET

Source files:
EOF
  print_file_status

  printf '\nSubscription URLs:\n'
  print_urls
}

cmd_cat() {
  require_root
  load_state

  local target file path
  target="$(map_content_target "${CONTENT_TARGET:-jhsub}")"

  if [ "$target" = "all" ]; then
    for file in clmi.yaml sbox.json jhsub.txt; do
      path="$SOURCE_DIR/$file"
      printf '\n===== %s =====\n' "$path"
      [ -f "$path" ] || die "missing file: $path"
      cat "$path"
      printf '\n'
    done
    return
  fi

  path="$SOURCE_DIR/$target"
  [ -f "$path" ] || die "missing file: $path"
  cat "$path"
}

cmd_remove() {
  require_root

  rm -f "$CADDY_SNIPPET"
  rm -rf "$PUBLIC_ROOT"

  if command -v caddy >/dev/null 2>&1 && [ -f /etc/caddy/Caddyfile ]; then
    caddy validate --config /etc/caddy/Caddyfile
    reload_caddy_if_running
  fi

  if [ "$KEEP_STATE" != "1" ]; then
    rm -rf "$STATE_DIR"
  fi

  log "Removed HTTPS subscription service config. Caddy package itself was not uninstalled."
}

parse_args() {
  if [ "$#" -gt 0 ]; then
    case "$1" in
      install|show|status|list|cat|content|remove|uninstall|delete|del)
        COMMAND="$1"
        shift
        ;;
      help|-h|--help)
        usage
        exit 0
        ;;
      --*)
        COMMAND="install"
        ;;
      *)
        die "unknown command: $1. Run: $SCRIPT_NAME help"
        ;;
    esac
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -d|--source-dir)
        [ "$#" -ge 2 ] || die "$1 requires a value"
        SOURCE_DIR="$2"
        shift 2
        ;;
      --source-dir=*)
        SOURCE_DIR="${1#*=}"
        shift
        ;;
      -p|--port)
        [ "$#" -ge 2 ] || die "$1 requires a value"
        HTTPS_PORT="$2"
        shift 2
        ;;
      --port=*)
        HTTPS_PORT="${1#*=}"
        shift
        ;;
      --public-ip)
        [ "$#" -ge 2 ] || die "$1 requires a value"
        PUBLIC_IP="$2"
        shift 2
        ;;
      --public-ip=*)
        PUBLIC_IP="${1#*=}"
        shift
        ;;
      --host)
        [ "$#" -ge 2 ] || die "$1 requires a value"
        HTTPS_HOST="$2"
        shift 2
        ;;
      --host=*)
        HTTPS_HOST="${1#*=}"
        shift
        ;;
      -t|--token)
        [ "$#" -ge 2 ] || die "$1 requires a value"
        TOKEN_OVERRIDE="$2"
        shift 2
        ;;
      --token=*)
        TOKEN_OVERRIDE="${1#*=}"
        shift
        ;;
      --rotate-token)
        ROTATE_TOKEN="1"
        shift
        ;;
      --keep-state)
        KEEP_STATE="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [ "$COMMAND" = "cat" ] || [ "$COMMAND" = "content" ]; then
          [ -z "$CONTENT_TARGET" ] || die "only one content target is allowed"
          CONTENT_TARGET="$1"
          shift
        else
          die "unknown option or argument: $1. Run: $SCRIPT_NAME help"
        fi
        ;;
    esac
  done

  case "$COMMAND" in
    status|list)
      COMMAND="show"
      ;;
    content)
      COMMAND="cat"
      ;;
    uninstall|delete|del)
      COMMAND="remove"
      ;;
  esac
}

main() {
  parse_args "$@"

  case "$COMMAND" in
    install)
      cmd_install
      ;;
    show)
      cmd_show
      ;;
    cat)
      cmd_cat
      ;;
    remove)
      cmd_remove
      ;;
    *)
      die "unknown command: $COMMAND"
      ;;
  esac
}

main "$@"
