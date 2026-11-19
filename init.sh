#!/usr/bin/env bash
# Prepare a fresh clone: generate .env, start the stack and do the one-time flowctl admin setup.
# Safe to re-run: existing .env is kept, existing namespace/users/members are reused, secrets are re-synced from .env.
set -euo pipefail

cd "$(dirname "$0")"

BASE_URL=http://localhost:7070
NAMESPACE=operations
OPERATOR_EMAIL=operator@flowctl.internal
OPERATOR_NAME=operator

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for cmd in docker curl openssl; do
  command -v "$cmd" >/dev/null || die "$cmd is required"
done
docker compose version >/dev/null 2>&1 || die "docker compose (v2) is required"

# --- 1. .env -----------------------------------------------------------------
if [[ -f .env ]]; then
  log ".env exists, keeping it (a new KEYSTORE_KEEPER_URL would make stored secrets unreadable)"
else
  log "Generating .env with random credentials"
  rand() { openssl rand -hex 16; }
  umask 077
  cat > .env <<EOF
ADMIN_USERNAME=flowctl_admin
ADMIN_PASSWORD=$(rand)
POSTGRES_USER=flowctl
POSTGRES_PASSWORD=$(rand)
POSTGRES_DB=flowctl
KEYSTORE_KEEPER_URL=base64key://$(openssl rand -base64 32 | tr '+/' '-_')
OIDC_CLIENT_SECRET=$(rand)
SERVICE_A_USER=service-a-user
SERVICE_A_PASSWORD=$(rand)
SERVICE_B_USER=service-b-user
SERVICE_B_PASSWORD=$(rand)
EOF
fi
set -a; . ./.env; set +a

# --- 2. Stack ----------------------------------------------------------------
wait_for_flowctl() {
  for _ in $(seq 1 90); do
    curl -fsS -o /dev/null "$BASE_URL/ping" 2>/dev/null && return 0
    sleep 2
  done
  die "flowctl did not become reachable at $BASE_URL (see: docker compose logs flowctl)"
}

log "Starting the stack (first run builds images, this can take a few minutes)"
docker compose up -d --build
wait_for_flowctl

# --- 3. Admin API session ----------------------------------------------------
JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT

# flowctl requires the _csrf cookie value echoed back in X-CSRF-Token on writes.
curl -fsS -c "$JAR" -b "$JAR" -o /dev/null "$BASE_URL/ping"
csrf() { awk '$6 == "_csrf" { print $7 }' "$JAR"; }

# api METHOD PATH [JSON] -> prints body, sets HTTP_CODE
api() {
  local method=$1 path=$2 data=${3:-} out
  out=$(curl -sS -c "$JAR" -b "$JAR" -X "$method" -H "X-CSRF-Token: $(csrf)" \
    -H 'Content-Type: application/json' ${data:+-d "$data"} -w '\n%{http_code}' "$BASE_URL$path")
  HTTP_CODE=${out##*$'\n'}
  printf '%s' "${out%$'\n'*}"
}

log "Logging in as admin"
api POST /login "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\"}" >/dev/null
[[ $HTTP_CODE == 200 ]] || die "admin login failed (HTTP $HTTP_CODE)"

# --- 4. Namespace and flows --------------------------------------------------
if api GET "/api/v1/namespaces?count_per_page=100" | grep -q "\"name\":\"$NAMESPACE\""; then
  log "Namespace '$NAMESPACE' exists"
else
  log "Creating namespace '$NAMESPACE'"
  api POST /api/v1/namespaces "{\"name\":\"$NAMESPACE\"}" >/dev/null
  [[ $HTTP_CODE == 201 ]] || die "could not create namespace (HTTP $HTTP_CODE)"
fi

# flowctl only loads flow files at startup, for namespaces that already exist.
if ! api GET "/api/v1/$NAMESPACE/flows" | grep -q '"id":"lookup_service_b"'; then
  log "Restarting flowctl to load the flows"
  docker compose restart flowctl >/dev/null
  wait_for_flowctl
  api POST /login "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\"}" >/dev/null
  [[ $HTTP_CODE == 200 ]] || die "admin login failed after restart (HTTP $HTTP_CODE)"
fi
flows=$(api GET "/api/v1/$NAMESPACE/flows")
for flow in lookup_service_a lookup_service_b; do
  grep -q "\"id\":\"$flow\"" <<<"$flows" || die "flow $flow was not loaded (see: docker compose logs flowctl)"
done
log "Flows loaded: lookup_service_a, lookup_service_b"

# --- 5. Flow secrets (created or updated from .env) --------------------------
set_secret() {
  local flow=$1 key=$2 value=$3 existing id
  existing=$(api GET "/api/v1/$NAMESPACE/flows/$flow/secrets")
  id=$(grep -o "\"id\":\"[^\"]*\",\"key\":\"$key\"" <<<"$existing" | cut -d'"' -f4 || true)
  if [[ -n $id ]]; then
    api PUT "/api/v1/$NAMESPACE/flows/$flow/secrets/$id" "{\"value\":\"$value\"}" >/dev/null
    [[ $HTTP_CODE == 200 ]] || die "could not update secret $flow/$key (HTTP $HTTP_CODE)"
  else
    api POST "/api/v1/$NAMESPACE/flows/$flow/secrets" "{\"key\":\"$key\",\"value\":\"$value\"}" >/dev/null
    [[ $HTTP_CODE == 201 ]] || die "could not create secret $flow/$key (HTTP $HTTP_CODE)"
  fi
}
log "Storing downstream credentials as flow secrets"
set_secret lookup_service_a SERVICE_A_USER "$SERVICE_A_USER"
set_secret lookup_service_a SERVICE_A_PASSWORD "$SERVICE_A_PASSWORD"
set_secret lookup_service_b SERVICE_B_USER "$SERVICE_B_USER"
set_secret lookup_service_b SERVICE_B_PASSWORD "$SERVICE_B_PASSWORD"

# --- 6. Operator user and role -----------------------------------------------
find_user_id() {
  api GET "/api/v1/users?filter=$OPERATOR_EMAIL&count_per_page=100" \
    | grep -o "\"id\":\"[^\"]*\",\"username\":\"$OPERATOR_EMAIL\"" | cut -d'"' -f4 || true
}
user_id=$(find_user_id)
if [[ -z $user_id ]]; then
  log "Creating user $OPERATOR_EMAIL (logs in via Dex)"
  api POST /api/v1/users "{\"name\":\"$OPERATOR_NAME\",\"username\":\"$OPERATOR_EMAIL\"}" >/dev/null
  [[ $HTTP_CODE == 201 ]] || die "could not create user (HTTP $HTTP_CODE)"
  user_id=$(find_user_id)
  [[ -n $user_id ]] || die "user was created but could not be found"
else
  log "User $OPERATOR_EMAIL exists"
fi

if api GET "/api/v1/$NAMESPACE/members" | grep -q "\"subject_id\":\"$user_id\""; then
  log "$OPERATOR_EMAIL is already a member of '$NAMESPACE'"
else
  log "Granting role 'operator' in '$NAMESPACE' to $OPERATOR_EMAIL"
  api POST "/api/v1/$NAMESPACE/members" \
    "{\"subject_id\":\"$user_id\",\"subject_type\":\"user\",\"role\":\"operator\"}" >/dev/null
  [[ $HTTP_CODE == 200 ]] || die "could not add member (HTTP $HTTP_CODE)"
fi

cat <<EOF

Done. Open $BASE_URL
  Admin:     $ADMIN_USERNAME / (ADMIN_PASSWORD in .env)
  Operator:  Dex login, $OPERATOR_EMAIL / operator-demo  (namespace: $NAMESPACE)
  No access: Dex login, noaccess@flowctl.internal / noaccess-demo
EOF
