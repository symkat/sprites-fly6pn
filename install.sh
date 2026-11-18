#!/usr/bin/env bash
# sprite-fly6pn: join a Sprite to a Fly.io organization's private network (6PN).
#
#   curl -fsSL https://raw.githubusercontent.com/<owner>/sprite-fly6pn/main/install.sh | bash
#
# The only setup is a Fly.io credential: a Sprite connector for https://api.fly.io,
# or a Fly token (fly tokens create wireguard) in ~/.fly-token. The org is detected from the credential.
#
# Actions: install (default), status, uninstall
#   curl -fsSL .../install.sh | bash -s -- status
#   curl -fsSL .../install.sh | bash -s -- uninstall
#
# See README.md for every configuration variable.
set -euo pipefail

ACTION="${1:-install}"

# ---------------------------------------------------------------------------
# Configuration (all optional except where noted; see README)
# ---------------------------------------------------------------------------
FLY_ORG="${FLY_ORG:-}"                        # org slug; auto-detected if the credential sees exactly one org
FLY_REGION="${FLY_REGION:-}"                  # WireGuard gateway region; default: Fly's nearestRegion
FLY_PEER_NAME="${FLY_PEER_NAME:-}"            # default: sprite-<sprite name>
FLY_NETWORK="${FLY_NETWORK:-}"                # custom private network name; default: the org's default 6PN

FLY_AUTH="${FLY_AUTH:-auto}"                  # auto | env | file | connector
FLY_API_TOKEN="${FLY_API_TOKEN:-}"            # token in the environment (used, never written to disk)
FLY_TOKEN_FILE="${FLY_TOKEN_FILE:-$HOME/.fly-token}"
FLY_CONNECTOR="${FLY_CONNECTOR:-}"            # Sprite connector id, name, or gateway_base_url; default: discover

FLY6PN_HOME="${FLY6PN_HOME:-$HOME/.fly6pn}"
FLY6PN_DNS="${FLY6PN_DNS:-1}"                 # 1 = run split DNS and point /etc/resolv.conf at it
FLY6PN_DNS_DOMAINS="${FLY6PN_DNS_DOMAINS:-internal flycast flympg.net}"
FLY6PN_MTU="${FLY6PN_MTU:-1420}"
FLY6PN_REPLACE_PEER="${FLY6PN_REPLACE_PEER:-0}"  # 1 = delete and recreate the peer if FLY_PEER_NAME already exists
FLY6PN_KEEP_PEER="${FLY6PN_KEEP_PEER:-0}"        # uninstall: 1 = leave the peer registered at Fly
FLY6PN_YES="${FLY6PN_YES:-0}"                    # 1 = don't ask for confirmation
# Where Sprites list their connectors: Sprites 2, then Sprites 1. The first that answers wins.
FLY6PN_GATEWAY_LISTS="${FLY6PN_GATEWAY_LISTS:-http://sprite.internal/v1/gateway/list https://api.sprites.dev/v1/gateway/list}"
FLY6PN_SERVICE="${FLY6PN_SERVICE:-fly6pn}"
FLY6PN_DNS_SERVICE="${FLY6PN_DNS_SERVICE:-fly6pn-dns}"

FLY_GRAPHQL_URL="https://api.fly.io/graphql"
IFACE=fly0
DNS_LISTEN=127.0.0.2

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
  sed -n '2,11p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
  echo "Usage: install.sh [install|status|uninstall]"
}

# ---------------------------------------------------------------------------
# Credentials: env token, token file, or Sprite connector
# ---------------------------------------------------------------------------
AUTH_MODE=""
TOKEN=""
GATEWAY_URL=""
CONNECTOR_ID=""
CONNECTOR_NAME=""
CONNECTOR_PREFER=""   # connector id saved by an earlier install; reused without asking

load_token_file() {
  [ -r "$FLY_TOKEN_FILE" ] || return 1
  TOKEN="$(tr -d '\r\n' < "$FLY_TOKEN_FILE")"
  [ -n "$TOKEN" ] || return 1
  if [ -n "$(find "$FLY_TOKEN_FILE" -perm /077 2>/dev/null)" ]; then
    warn "$FLY_TOKEN_FILE is readable by other users; run: chmod 600 $FLY_TOKEN_FILE"
  fi
}

# Can we ask the person running the installer? (With `curl | bash`, stdin is
# the script itself, so questions go to /dev/tty.)
can_prompt() {
  [ "$FLY6PN_YES" != 1 ] && ( : </dev/tty ) 2>/dev/null
}

ask() {  # ask <prompt>; prints the answer
  local answer
  printf '%s' "$1" >/dev/tty
  IFS= read -r answer </dev/tty || answer=""
  printf '%s' "$answer"
}

# Reads the Sprite's connector list from the first gateway in
# FLY6PN_GATEWAY_LISTS that answers (Sprites 2: sprite.internal; Sprites 1:
# api.sprites.dev), adding .gateway_base_url where the gateway leaves it out.
# Sets GATEWAY_LIST_URL and GATEWAY_JSON; returns 1 if no gateway answered.
GATEWAY_LIST_URL=""
GATEWAY_JSON=""
gateway_list() {
  local url json
  for url in $FLY6PN_GATEWAY_LISTS; do
    json="$(curl -fsS -m10 "$url" 2>/dev/null)" || continue
    jq -e '.connections | type == "array"' >/dev/null 2>&1 <<<"$json" || continue
    GATEWAY_LIST_URL="$url"
    GATEWAY_JSON="$(jq --arg base "${url%/list}" '.connections |= map(.gateway_base_url //= "\($base)/custom_api/\(.id)")' <<<"$json")"
    return 0
  done
  return 1
}

# Lists the Fly API connectors this Sprite may use, one per line:
# id <TAB> display name <TAB> gateway_base_url. The gateway only lists
# connectors whose access policy admits this Sprite.
fly_connectors() {
  gateway_list || return 0
  jq -r '
    .connections[]?
    | select(.provider == "custom_api")
    | select(((.base_api_url // .provider_info.base_api_url // "") | rtrimstr("/")) == "https://api.fly.io")
    | [.id, (.display_name // .provider_account_name // .id), (.gateway_base_url | rtrimstr("/"))]
    | @tsv' <<<"$GATEWAY_JSON" 2>/dev/null || true
}

# Picks a Fly API connector (and, with it, the org): FLY_CONNECTOR if set,
# otherwise every visible connector paired with each org it can see.
# Sets GATEWAY_URL, CONNECTOR_ID, CONNECTOR_NAME and FLY_ORG.
# Returns 1 if this Sprite has no usable Fly API connector.
choose_connector() {
  local want="$FLY_CONNECTOR" lines id name gw orgs org i choice
  local -a cands=()

  case "$want" in
    http://*|https://*)
      GATEWAY_URL="${want%/}"; CONNECTOR_ID="${GATEWAY_URL##*/}"; CONNECTOR_NAME="$CONNECTOR_ID"
      return 0 ;;
  esac

  lines="$(fly_connectors)"
  if [ -n "$want" ]; then
    lines="$(awk -F'\t' -v w="$want" 'tolower($1) == tolower(w) || tolower($2) == tolower(w)' <<<"$lines")"
    [ -n "$lines" ] || die "no Fly API connector '$want' is visible to this Sprite.
  Visible Fly API connectors: $(fly_connectors | cut -f1,2 | tr '\t\n' ' ;')
  Check the connector's access policy, and that its base URL is https://api.fly.io."
  fi
  [ -n "$lines" ] || return 1

  # Ask each connector which orgs its token can see.
  while IFS=$'\t' read -r id name gw; do
    [ -n "$id" ] || continue
    if ! orgs="$( (AUTH_MODE=connector; GATEWAY_URL="$gw"; gql_query '{organizations{nodes{slug}}}') 2>/dev/null \
                  | jq -r '.organizations.nodes[].slug')"; then
      warn "connector '$name' ($id) did not answer as the Fly.io API; skipping it"
      continue
    fi
    [ -n "$orgs" ] || { warn "connector '$name' ($id) can't see any org (expired token?); skipping it"; continue; }
    while IFS= read -r org; do
      [ -z "$FLY_ORG" ] || [ "$org" = "$FLY_ORG" ] || continue
      cands+=("$id"$'\t'"$name"$'\t'"$gw"$'\t'"$org")
    done <<<"$orgs"
  done <<<"$lines"

  if [ "${#cands[@]}" = 0 ]; then
    [ -z "$FLY_ORG" ] || die "no Fly API connector visible to this Sprite can see org '$FLY_ORG'"
    return 1
  fi

  choice=""
  # A connector saved by an earlier install wins, so rotations and uninstall don't ask.
  if [ -n "$CONNECTOR_PREFER" ]; then
    for i in "${!cands[@]}"; do
      if [ "$(cut -f1 <<<"${cands[$i]}")" = "$CONNECTOR_PREFER" ]; then choice="$i"; break; fi
    done
  fi

  if [ -z "$choice" ] && [ "${#cands[@]}" = 1 ]; then
    choice=0
    if can_prompt; then
      IFS=$'\t' read -r id name gw org <<<"${cands[0]}"
      case "$(ask "Use Sprite connector '$name' ($id) to join Fly.io org '$org'? [Y/n] ")" in
        ""|y|Y|yes|YES) ;;
        *) die "cancelled. Choose a credential with FLY_CONNECTOR, FLY_TOKEN_FILE or FLY_API_TOKEN." ;;
      esac
    fi
  elif [ -z "$choice" ]; then
    if ! can_prompt; then
      {
        echo "Several Fly.io connector/org combinations are available:"
        for i in "${!cands[@]}"; do
          IFS=$'\t' read -r id name gw org <<<"${cands[$i]}"
          echo "  FLY_CONNECTOR=$id FLY_ORG=$org    ($name)"
        done
      } >&2
      die "choose one by exporting its FLY_CONNECTOR and FLY_ORG, then run the installer again"
    fi
    {
      echo "Fly.io connectors this Sprite can use:"
      for i in "${!cands[@]}"; do
        IFS=$'\t' read -r id name gw org <<<"${cands[$i]}"
        printf '  %d) %-24s org %-24s (%s)\n' "$((i + 1))" "$name" "$org" "$id"
      done
    } >/dev/tty
    choice="$(ask "Choose [1-${#cands[@]}]: ")"
    case "$choice" in ''|*[!0-9]*) die "not a number: '$choice'" ;; esac
    [ "$choice" -ge 1 ] && [ "$choice" -le "${#cands[@]}" ] || die "no option $choice"
    choice=$((choice - 1))
  fi

  IFS=$'\t' read -r CONNECTOR_ID CONNECTOR_NAME GATEWAY_URL FLY_ORG <<<"${cands[$choice]}"
}

# Explains, for error messages, which connectors this Sprite can see and why
# none of them was used.
describe_connectors() {
  local list
  if ! gateway_list; then
    printf '  (no connector gateway answered; tried %s)\n' "$FLY6PN_GATEWAY_LISTS"
    return
  fi
  list="$(jq -r '.connections[]?
    | "  - \(.display_name // .id) (\(.id)): provider \(.provider), base URL \((.base_api_url // .provider_info.base_api_url // "none") | tojson)"' \
    <<<"$GATEWAY_JSON" 2>/dev/null)"
  if [ -n "$list" ]; then
    printf '  Connectors this Sprite can see at %s\n  (a Fly API connector needs provider custom_api and base URL exactly "https://api.fly.io"):\n%s\n' "$GATEWAY_LIST_URL" "$list"
  else
    printf '  This Sprite sees no connectors at all: check the connector is in the same\n  Sprites organization as this Sprite, and that its access policy admits it.\n'
  fi
}

resolve_auth() {
  case "$FLY_AUTH" in
    env)
      [ -n "$FLY_API_TOKEN" ] || die "FLY_AUTH=env but FLY_API_TOKEN is empty"
      TOKEN="$FLY_API_TOKEN"; AUTH_MODE="env" ;;
    file)
      load_token_file || die "FLY_AUTH=file but $FLY_TOKEN_FILE is missing or empty"
      AUTH_MODE="file" ;;
    connector)
      choose_connector || die "this Sprite can't use any Fly API connector.
  Create a Custom API connector with base URL https://api.fly.io and let this Sprite
  use it (see README.md, \"Option A: Sprite connector\").
$(describe_connectors)"
      AUTH_MODE=connector ;;
    auto)
      if [ -n "$FLY_API_TOKEN" ]; then TOKEN="$FLY_API_TOKEN"; AUTH_MODE="env"
      elif choose_connector; then AUTH_MODE=connector
      elif load_token_file; then AUTH_MODE="file"
      else
        die "no Fly.io credential found. Provide one of:
  - a Sprite connector this Sprite may use (Custom API, base URL https://api.fly.io)
  - a token file at $FLY_TOKEN_FILE (chmod 600), or FLY_TOKEN_FILE=<path>
  - FLY_API_TOKEN in the environment
$(describe_connectors)
See README.md, section \"Fly.io credentials\"."
      fi ;;
    *) die "FLY_AUTH must be auto, env, file or connector (got '$FLY_AUTH')" ;;
  esac
  case "$AUTH_MODE" in
    connector) log "Using Sprite connector '$CONNECTOR_NAME' ($CONNECTOR_ID) for org $FLY_ORG" ;;
    file)      log "Using token file: $FLY_TOKEN_FILE" ;;
    env)       log "Using FLY_API_TOKEN from the environment" ;;
  esac
}

# gql <json-body>: POST to Fly's GraphQL API, print .data, die on errors.
# The token goes to curl on a file descriptor, so it never shows in `ps`.
gql() {
  local body="$1" url out
  if [ "$AUTH_MODE" = connector ]; then
    url="$GATEWAY_URL/graphql"
    out="$(curl -sS -m60 -H 'Content-Type: application/json' --data-binary @- "$url" <<<"$body")" \
      || die "request to the Sprite gateway failed ($url)"
  else
    local hdr="$TOKEN"
    case "$hdr" in FlyV1\ *|Bearer\ *) ;; *) hdr="Bearer $hdr" ;; esac
    out="$(curl -sS -m60 -H @<(printf 'Authorization: %s\n' "$hdr") -H 'Content-Type: application/json' \
            --data-binary @- "$FLY_GRAPHQL_URL" <<<"$body")" || die "request to $FLY_GRAPHQL_URL failed"
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"$out"; then
    die "unexpected response from the Fly API: $(head -c 300 <<<"$out")"
  fi
  if jq -e '.errors | length > 0' >/dev/null 2>&1 <<<"$out"; then
    die "Fly API error: $(jq -r '[.errors[].message] | join("; ")' <<<"$out")"
  fi
  jq -c '.data' <<<"$out"
}

gql_query() {  # gql_query <query> [variables-json]
  local vars="${2:-}"
  [ -n "$vars" ] || vars='{}'
  gql "$(jq -nc --arg q "$1" --argjson v "$vars" '{query:$q, variables:$v}')"
}

org_id() {
  gql_query 'query($s:String!){organization(slug:$s){id}}' "$(jq -nc --arg s "$FLY_ORG" '{s:$s}')" \
    | jq -r '.organization.id // empty'
}

detect_org() {
  [ -n "$FLY_ORG" ] && return 0
  local slugs
  slugs="$(gql_query '{organizations{nodes{slug}}}' | jq -r '.organizations.nodes[].slug')"
  local count
  count="$(grep -c . <<<"$slugs" || true)"
  if [ "$count" = 1 ]; then
    FLY_ORG="$slugs"; log "Detected org: $FLY_ORG"
  elif [ "$count" = 0 ]; then
    die "this credential can't see any Fly.io org; check that the token is valid and not expired"
  else
    die "this credential can see several orgs (a personal token?): $(tr '\n' ' ' <<<"$slugs")
  Set FLY_ORG to one of them, or use an org token: fly tokens create org -o <org>"
  fi
}

peer_exists() {  # peer_exists <org-slug> <name>
  gql_query 'query($s:String!){organization(slug:$s){wireGuardPeers{nodes{name}}}}' \
      "$(jq -nc --arg s "$1" '{s:$s}')" \
    | jq -e --arg n "$2" '.organization.wireGuardPeers.nodes | map(.name) | index($n) != null' >/dev/null
}

remove_peer() {  # remove_peer <org-id> <name>
  gql_query 'mutation($i:RemoveWireGuardPeerInput!){removeWireGuardPeer(input:$i){organization{id}}}' \
    "$(jq -nc --arg o "$1" --arg n "$2" '{i:{organizationId:$o, name:$n}}')" >/dev/null
}

# ---------------------------------------------------------------------------
# Install steps
# ---------------------------------------------------------------------------
preflight() {
  need_cmd sprite-env || die "sprite-env not found; this installer is meant to run inside a Sprite"
  sudo -n true 2>/dev/null || die "passwordless sudo is required"
  [ -c /dev/net/tun ] || die "/dev/net/tun is missing"
}

check_network_policy() {
  local rules
  rules="$(sprite-env policy network get 2>/dev/null | jq -r '.rules | length' 2>/dev/null || echo 0)"
  if [ "${rules:-0}" != 0 ]; then
    warn "this Sprite has a restrictive network policy; WireGuard needs outbound UDP 51820, which such policies block"
  fi
}

install_packages() {
  local missing=()
  need_cmd wireguard-go || missing+=(wireguard-go)
  need_cmd wg           || missing+=(wireguard-tools)
  need_cmd jq           || missing+=(jq)
  need_cmd curl         || missing+=(curl)
  need_cmd dig          || missing+=(dnsutils)
  [ -x /usr/sbin/dnsmasq ] || missing+=(dnsmasq-base)
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing packages: ${missing[*]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
  fi
}

sprite_name() {
  local n
  n="$(sprite-env info 2>/dev/null | jq -r '.name // empty' || true)"
  echo "${n:-$(hostname)}"
}

default_peer_name() {
  local n
  n="sprite-$(sprite_name)"
  tr 'A-Z' 'a-z' <<<"$n" | tr -c 'a-z0-9-\n' '-'
}

create_peer() {
  local oid priv pub data peerip endpoint prefix
  oid="$(org_id)"; [ -n "$oid" ] || die "organization '$FLY_ORG' not found or not visible to this credential"

  if peer_exists "$FLY_ORG" "$FLY_PEER_NAME"; then
    [ "$FLY6PN_REPLACE_PEER" = 1 ] || die "a WireGuard peer named '$FLY_PEER_NAME' already exists in $FLY_ORG.
  Set FLY_PEER_NAME to another name, or FLY6PN_REPLACE_PEER=1 to delete and recreate it
  (any other machine using that peer's key will lose access)."
    log "Removing existing peer $FLY_PEER_NAME"
    remove_peer "$oid" "$FLY_PEER_NAME"
  fi

  if [ -z "$FLY_REGION" ]; then
    FLY_REGION="$(gql_query '{nearestRegion{code}}' | jq -r '.nearestRegion.code')"
    log "Using nearest region: $FLY_REGION"
  fi

  log "Creating WireGuard peer $FLY_PEER_NAME in $FLY_ORG ($FLY_REGION)"
  priv="$(wg genkey)"; pub="$(wg pubkey <<<"$priv")"
  data="$(gql_query 'mutation($i:AddWireGuardPeerInput!){addWireGuardPeer(input:$i){peerip endpointip pubkey}}' \
    "$(jq -nc --arg o "$oid" --arg r "$FLY_REGION" --arg n "$FLY_PEER_NAME" --arg k "$pub" --arg net "$FLY_NETWORK" \
       '{i:({organizationId:$o, region:$r, name:$n, pubkey:$k} + (if $net != "" then {network:$net} else {} end))}')")"
  peerip="$(jq -r '.addWireGuardPeer.peerip' <<<"$data")"
  endpoint="$(jq -r '.addWireGuardPeer.endpointip' <<<"$data")"
  # The org's 6PN prefix is the first three groups of the peer address (fdaa:X:Y).
  prefix="$(cut -d: -f1-3 <<<"$peerip")"

  ( umask 077
    cat > "$FLY6PN_HOME/fly0.conf" <<EOF
# Fly.io WireGuard peer "$FLY_PEER_NAME" in org "$FLY_ORG" (created by sprite-fly6pn)
[Interface]
PrivateKey = $priv
Address = $peerip/120
DNS = $prefix::3

[Peer]
PublicKey = $(jq -r '.addWireGuardPeer.pubkey' <<<"$data")
AllowedIPs = $prefix::/48
Endpoint = $endpoint:51820
PersistentKeepalive = 15
EOF
  )
  local saved_connector=""
  if [ "$AUTH_MODE" = connector ]; then saved_connector="$CONNECTOR_ID"; fi
  cat > "$FLY6PN_HOME/peer.env" <<EOF
FLY_ORG=$FLY_ORG
FLY_PEER_NAME=$FLY_PEER_NAME
FLY_REGION=$FLY_REGION
PEER_IP=$peerip
ORG_DNS=$prefix::3
SPRITE_NAME=$(sprite_name)
CONNECTOR_ID=$saved_connector
EOF
}

write_runners() {
  mkdir -p "$FLY6PN_HOME/bin"

  # Tunnel runner: userspace wireguard-go in the foreground, supervised as a Sprite service.
  cat > "$FLY6PN_HOME/bin/fly6pn-tunnel" <<'EOF'
#!/bin/sh
# Bring up the Fly.io WireGuard peer with userspace wireguard-go (the Sprite
# kernel has no wireguard module). Stays in the foreground for the service manager.
set -eu
DIR=$(cd "$(dirname "$0")/.." && pwd)
IF=fly0
CONF="$DIR/fly0.conf"
MTU=$(cat "$DIR/mtu" 2>/dev/null || echo 1420)
ADDR=$(sed -n 's/^Address *= *//p' "$CONF")
NET=$(sed -n 's/^AllowedIPs *= *//p' "$CONF")

ip link del "$IF" 2>/dev/null || true
WG_PROCESS_FOREGROUND=1 wireguard-go -f "$IF" &
PID=$!
trap 'kill $PID 2>/dev/null; ip link del $IF 2>/dev/null' TERM INT
for i in $(seq 50); do [ -S /var/run/wireguard/$IF.sock ] && break; sleep 0.1; done

# wg setconf understands only wg(8) keys; Address and DNS are wg-quick extensions.
grep -vE '^(Address|DNS) *=' "$CONF" | wg setconf "$IF" /dev/stdin
ip -6 addr add "$ADDR" dev "$IF"
ip link set "$IF" mtu "$MTU" up
ip -6 route replace "$NET" dev "$IF"
echo "$IF up: $ADDR -> $NET"
wait $PID
EOF

  # DNS runner: re-point /etc/resolv.conf on every start (the runtime may restore
  # its own at boot), then run dnsmasq in the foreground. Sprites 2 has a
  # symlinked /etc/resolv.conf, which we re-link; Sprites 1 bind-mounts it
  # read-only, so we bind-mount our file over it instead (mode in resolv.mode).
  cat > "$FLY6PN_HOME/bin/fly6pn-dns" <<'EOF'
#!/bin/sh
set -eu
DIR=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(cat "$DIR/resolv.mode" 2>/dev/null || echo symlink)" = bind ]; then
  cmp -s "$DIR/resolv.conf" /etc/resolv.conf || mount --bind "$DIR/resolv.conf" /etc/resolv.conf
else
  [ "$(readlink /etc/resolv.conf)" = "$DIR/resolv.conf" ] || ln -sfn "$DIR/resolv.conf" /etc/resolv.conf
fi
exec /usr/sbin/dnsmasq --keep-in-foreground --conf-file="$DIR/dnsmasq.conf"
EOF
  chmod 755 "$FLY6PN_HOME/bin/fly6pn-tunnel" "$FLY6PN_HOME/bin/fly6pn-dns"
  echo "$FLY6PN_MTU" > "$FLY6PN_HOME/mtu"
}

# Is /etc/resolv.conf a mount point? (Sprites 1 bind-mounts it read-only;
# Sprites 2 makes it a symlink.)
resolv_is_mount() {
  awk '$5 == "/etc/resolv.conf" { found = 1 } END { exit !found }' /proc/self/mountinfo
}

# Drops our bind mounts over /etc/resolv.conf (Sprites 1), uncovering the runtime's.
unmount_our_resolv() {
  local i
  for i in 1 2 3 4 5; do
    cmp -s "$FLY6PN_HOME/resolv.conf" /etc/resolv.conf || return 0
    sudo umount /etc/resolv.conf || return 1
  done
}

write_dns_config() {
  local org_dns d mode up ups=""
  org_dns="$(sed -n 's/^DNS *= *//p' "$FLY6PN_HOME/fly0.conf")"

  if [ -L /etc/resolv.conf ] || ! resolv_is_mount; then
    # Sprites 2: symlink /etc/resolv.conf; the Sprite resolver is 127.0.0.1.
    mode=symlink; ups="127.0.0.1"
  else
    # Sprites 1: bind-mount over /etc/resolv.conf; forward to the runtime's own
    # nameservers, read with any earlier install's mount removed.
    mode=bind
    unmount_our_resolv || die "could not unmount the earlier fly6pn /etc/resolv.conf"
    ups="$(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf | tr '\n' ' ')"
    [ -n "$ups" ] || die "found no nameservers in /etc/resolv.conf to forward to"
  fi
  echo "$mode" > "$FLY6PN_HOME/resolv.mode"

  {
    echo "# Split DNS for sprite-fly6pn: org names via the WireGuard tunnel,"
    echo "# everything else (including *.sprite.internal) via the Sprite resolver."
    echo "listen-address=$DNS_LISTEN"
    echo "bind-interfaces"
    echo "no-resolv"
    echo "no-hosts"
    for up in $ups; do echo "server=/sprite.internal/$up"; done
    for d in $FLY6PN_DNS_DOMAINS; do echo "server=/$d/$org_dns"; done
    for up in $ups; do echo "server=$up"; done
  } > "$FLY6PN_HOME/dnsmasq.conf"
  # Fall back to the Sprite resolver directly if dnsmasq is down.
  {
    echo "nameserver $DNS_LISTEN"
    echo "nameserver ${ups%% *}"
    echo "options timeout:2"
  } > "$FLY6PN_HOME/resolv.conf"

  # Remember the runtime's resolver symlink once, so uninstall can restore it.
  if [ "$mode" = symlink ]; then
    local cur
    cur="$(readlink /etc/resolv.conf || true)"
    if [ ! -e "$FLY6PN_HOME/resolv.conf.orig" ] && [ "$cur" != "$FLY6PN_HOME/resolv.conf" ]; then
      echo "${cur:-../.fly/run/resolv.conf}" > "$FLY6PN_HOME/resolv.conf.orig"
    fi
  else
    rm -f "$FLY6PN_HOME/resolv.conf.orig"
  fi
}

# Sprites 1 and Sprites 2 ship different `sprite-env services create` CLIs:
#   Sprites 2: create <name> --restart always --description <text> -- <cmd> [args...]
#   Sprites 1: create <name> --cmd <cmd> --args <a,b,...>  (PUT /v1/services/<name>)
# Sprites 1's help documents --cmd; Sprites 2's does not.
SERVICES_API=""
services_api() {
  if [ -z "$SERVICES_API" ]; then
    if sprite-env services --help 2>&1 | grep -q -- '--cmd <command>'; then
      SERVICES_API=1
    else
      SERVICES_API=2
    fi
  fi
  echo "$SERVICES_API"
}

# add_service <name> <description> <cmd> [args...]: create or replace a
# service that always restarts, and (re)start it so it runs the new config.
add_service() {
  local name="$1" desc="$2"; shift 2
  if [ "$(services_api)" = 2 ]; then
    # Sprites 2 replaces an existing service of the same name.
    sprite-env services create "$name" --restart always --description "$desc" -- "$@" >/dev/null \
      || die "could not create Sprite service $name"
    sprite-env services restart "$name" >/dev/null 2>&1 || true
  else
    # Sprites 1 has no restart policy flag (failed services are always retried
    # with backoff) and no descriptions. Its PUT won't replace a running
    # service, so delete it first; creating a service also starts it. The API
    # is called directly so arguments containing commas survive.
    local cmd="$1"; shift
    sprite-env services delete "$name" >/dev/null 2>&1 || true
    sprite-env curl -X PUT "/v1/services/$name?duration=1s" \
      -d "$(jq -nc --arg c "$cmd" '{cmd:$c, args:$ARGS.positional, env:{}, needs:[]}' --args "$@")" >/dev/null \
      || die "could not create Sprite service $name"
  fi
}

create_services() {
  log "Creating Sprite service $FLY6PN_SERVICE"
  add_service "$FLY6PN_SERVICE" \
    "WireGuard peer $FLY_PEER_NAME into the $FLY_ORG Fly.io 6PN (interface $IFACE)" \
    sudo "$FLY6PN_HOME/bin/fly6pn-tunnel"

  if [ "$FLY6PN_DNS" = 1 ]; then
    log "Creating Sprite service $FLY6PN_DNS_SERVICE"
    add_service "$FLY6PN_DNS_SERVICE" \
      "Split DNS on $DNS_LISTEN: $FLY6PN_DNS_DOMAINS -> Fly 6PN, everything else -> Sprite resolver" \
      sudo "$FLY6PN_HOME/bin/fly6pn-dns"
  fi
}

verify() {
  local org_dns hs=0
  org_dns="$(sed -n 's/^DNS *= *//p' "$FLY6PN_HOME/fly0.conf")"
  log "Waiting for the WireGuard handshake"
  for _ in $(seq 30); do
    # fly0 may not exist yet while the service restarts; don't let pipefail end the script.
    hs="$(sudo wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1 || true)"
    [ "${hs:-0}" != 0 ] && break
    sleep 1
  done
  [ "${hs:-0}" != 0 ] || die "no handshake after 30s. Check: sprite-env services logs $FLY6PN_SERVICE; sprite-env policy network get"
  # A new peer can complete its handshake a few seconds before Fly routes its
  # traffic, so give the org DNS up to 30s to start answering.
  local ok=0
  for _ in $(seq 10); do
    if dig +short +time=3 +tries=1 AAAA _api.internal "@$org_dns" 2>/dev/null | grep -q .; then ok=1; break; fi
  done
  [ "$ok" = 1 ] || die "tunnel is up but the org DNS ($org_dns) did not answer within 30s"
  if [ "$FLY6PN_DNS" = 1 ]; then
    sleep 1
    getent ahosts _api.internal >/dev/null || warn "split DNS is not answering yet; check: sprite-env services logs $FLY6PN_DNS_SERVICE"
  fi
}

summary() {
  # shellcheck disable=SC1091
  . "$FLY6PN_HOME/peer.env"
  cat >&2 <<EOF

$(printf '\033[1;32m')sprite-fly6pn is up.$(printf '\033[0m')
  org:          $FLY_ORG
  peer:         $FLY_PEER_NAME ($FLY_REGION)
  6PN address:  $PEER_IP
  org DNS:      $ORG_DNS
  services:     $FLY6PN_SERVICE$( [ "$FLY6PN_DNS" = 1 ] && echo ", $FLY6PN_DNS_SERVICE")

From this Sprite:
  dig +short txt _apps.internal          # apps in the org
  curl http://<app>.flycast/             # Flycast (through fly-proxy)
  curl http://<app>.internal:<port>/     # straight to Machines over 6PN

From a Fly Machine in $FLY_ORG, this Sprite is:
  $FLY_PEER_NAME._peer.internal  ->  $PEER_IP
  (the Sprite must be awake; see README "Reaching the Sprite from Fly Machines")
EOF
}

do_install() {
  preflight
  install_packages
  check_network_policy
  mkdir -p "$FLY6PN_HOME"; chmod 700 "$FLY6PN_HOME"

  if [ -s "$FLY6PN_HOME/fly0.conf" ] && [ "$FLY6PN_REPLACE_PEER" != 1 ]; then
    # shellcheck disable=SC1091
    . "$FLY6PN_HOME/peer.env"
    log "Reusing existing peer $FLY_PEER_NAME from $FLY6PN_HOME/fly0.conf (FLY6PN_REPLACE_PEER=1 creates a new one)"
    if [ -n "${SPRITE_NAME:-}" ] && [ "$SPRITE_NAME" != "$(sprite_name)" ]; then
      warn "this peer was created on Sprite '$SPRITE_NAME'; this looks like a fork sharing its key.
  Give this Sprite its own peer: FLY6PN_REPLACE_PEER=1 bash install.sh"
    fi
  else
    # When replacing, default to the saved org, peer name and region so a key
    # rotation recreates the same peer; environment variables still win.
    local saved_org="" saved_name="" saved_region="" saved_sprite=""
    if [ -s "$FLY6PN_HOME/peer.env" ]; then
      saved_org="$(sed -n 's/^FLY_ORG=//p' "$FLY6PN_HOME/peer.env")"
      saved_name="$(sed -n 's/^FLY_PEER_NAME=//p' "$FLY6PN_HOME/peer.env")"
      saved_region="$(sed -n 's/^FLY_REGION=//p' "$FLY6PN_HOME/peer.env")"
      saved_sprite="$(sed -n 's/^SPRITE_NAME=//p' "$FLY6PN_HOME/peer.env")"
      CONNECTOR_PREFER="$(sed -n 's/^CONNECTOR_ID=//p' "$FLY6PN_HOME/peer.env")"
    fi
    # In a fork, the saved peer belongs to the original Sprite: never reuse
    # (and so delete) it by default; fall back to this Sprite's own name.
    local reuse_name="$saved_name"
    if [ -n "$saved_sprite" ] && [ "$saved_sprite" != "$(sprite_name)" ]; then
      log "Peer config came from Sprite '$saved_sprite' (a fork?); not reusing its peer name '$saved_name'"
      reuse_name=""
    fi
    FLY_ORG="${FLY_ORG:-$saved_org}"
    FLY_REGION="${FLY_REGION:-$saved_region}"
    resolve_auth
    detect_org
    FLY_PEER_NAME="${FLY_PEER_NAME:-${reuse_name:-$(default_peer_name)}}"
    create_peer
    if [ -n "$saved_name" ] && [ "$saved_name" != "$FLY_PEER_NAME" ]; then
      # Not removed automatically: in a fork, the original Sprite still uses it.
      warn "the previous peer '$saved_name' is still registered in $saved_org; if nothing else uses it, remove it: fly wireguard remove $saved_org $saved_name"
    fi
  fi

  write_runners
  [ "$FLY6PN_DNS" = 1 ] && write_dns_config
  create_services
  verify
  summary
}

do_status() {
  [ -s "$FLY6PN_HOME/peer.env" ] || die "not installed ($FLY6PN_HOME/peer.env not found)"
  # shellcheck disable=SC1091
  . "$FLY6PN_HOME/peer.env"
  echo "peer $FLY_PEER_NAME in $FLY_ORG ($FLY_REGION), address $PEER_IP"
  sudo wg show "$IFACE" 2>/dev/null | sed -n 's/^ *\(endpoint\|latest handshake\|transfer\):/  \1:/p' \
    || echo "  interface $IFACE is down"
  for s in "$FLY6PN_SERVICE" "$FLY6PN_DNS_SERVICE"; do
    printf '  service %-12s %s\n' "$s" "$(sprite-env services get "$s" 2>/dev/null | jq -r '.service.desired_state // .state.status // "absent"' 2>/dev/null || echo absent)"
  done
  if [ -L /etc/resolv.conf ]; then
    printf '  resolv.conf -> %s\n' "$(readlink /etc/resolv.conf)"
  elif cmp -s "$FLY6PN_HOME/resolv.conf" /etc/resolv.conf; then
    printf '  resolv.conf: fly6pn split DNS (bind mount)\n'
  else
    printf '  resolv.conf: (runtime default)\n'
  fi
  printf '  _apps.internal: %s\n' "$(dig +short +time=3 TXT _apps.internal "@$ORG_DNS" 2>/dev/null || echo unreachable)"
}

do_uninstall() {
  local peer_name="" org=""
  if [ -s "$FLY6PN_HOME/peer.env" ]; then
    # shellcheck disable=SC1091
    . "$FLY6PN_HOME/peer.env"; peer_name="$FLY_PEER_NAME"; org="$FLY_ORG"
    CONNECTOR_PREFER="${CONNECTOR_ID:-}"
  fi

  log "Removing Sprite services"
  sprite-env services delete "$FLY6PN_DNS_SERVICE" >/dev/null 2>&1 || true
  sprite-env services delete "$FLY6PN_SERVICE" >/dev/null 2>&1 || true
  sudo ip link del "$IFACE" 2>/dev/null || true

  if [ -f "$FLY6PN_HOME/resolv.conf" ] && [ ! -L /etc/resolv.conf ] \
      && cmp -s "$FLY6PN_HOME/resolv.conf" /etc/resolv.conf; then
    log "Unmounting fly6pn's /etc/resolv.conf"
    unmount_our_resolv || warn "could not unmount /etc/resolv.conf; run: sudo umount /etc/resolv.conf"
  elif [ "$(readlink /etc/resolv.conf || true)" = "$FLY6PN_HOME/resolv.conf" ]; then
    local orig
    orig="$(cat "$FLY6PN_HOME/resolv.conf.orig" 2>/dev/null || echo ../.fly/run/resolv.conf)"
    log "Restoring /etc/resolv.conf -> $orig"
    sudo ln -sfn "$orig" /etc/resolv.conf
  fi

  if [ -n "$peer_name" ] && [ "$FLY6PN_KEEP_PEER" != 1 ]; then
    FLY_ORG="$org"; FLY6PN_YES=1
    if ( resolve_auth ) >/dev/null 2>&1; then
      resolve_auth
      local oid; oid="$(org_id)"
      if [ -n "$oid" ] && peer_exists "$org" "$peer_name"; then
        log "Removing WireGuard peer $peer_name from $org"
        remove_peer "$oid" "$peer_name"
      fi
    else
      warn "no Fly.io credential available; remove the peer yourself: fly wireguard remove $org $peer_name"
    fi
  fi

  log "Deleting $FLY6PN_HOME (includes the WireGuard private key)"
  rm -rf "$FLY6PN_HOME"
  log "Uninstalled."
}

case "$ACTION" in
  install)   do_install ;;
  status)    do_status ;;
  uninstall) do_uninstall ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
