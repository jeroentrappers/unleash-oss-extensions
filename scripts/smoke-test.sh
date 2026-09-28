#!/usr/bin/env bash
# Behavioural check that our two adaptations still work on the unleash-server version
# in package.json. It is what makes an automated upstream bump safe to review: an
# image that builds is not enough, because both adaptations lean on unleash-server
# internals that upstream may change without notice.
#
#   1. Custom environments: with `ui.environment: "pro"` the testing/staging rows
#      from sql/01-environments.sql are visible to the admin API, and a backend token
#      scoped to `testing` is accepted by the SDK API.
#   2. OpenID Connect sign-in (oidc-auth-hook.js) against a real Keycloak: role from
#      the ID token decides access and the Unleash root role (re-synced on every
#      login), refused users get no account, the password login and API tokens keep
#      working, and the login page is offered both password and SSO.
#
# With --upgrade-from, the database is first created and seeded (environments, tokens,
# a flag) by the OLDER image, then the image under test boots on top of it: that
# exercises upstream's DB migrations from the version we run today, which is where a
# major bump breaks, and checks the seeded data survives them.
#
# Needs only docker. Runs a throwaway postgres + the image on a private network;
# everything is removed on exit.
#
# Usage: scripts/smoke-test.sh [--image <ref>] [--upgrade-from <ref>]
#        (default --image: build the working tree)
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=""
UPGRADE_FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --upgrade-from) UPGRADE_FROM="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

RUN_ID="unleash-smoke-$$"
NET="${RUN_ID}-net"
DB="${RUN_ID}-db"
APP="${RUN_ID}-app"
KC="${RUN_ID}-kc"
KC_IMAGE="quay.io/keycloak/keycloak:26.7.2"
CURL_IMAGE="curlimages/curl:8.16.0"
ADMIN_TOKEN="*:*.smoke-admin-${RUN_ID}"
TESTING_TOKEN="default:testing.smoke-backend-${RUN_ID}"

cleanup() {
  docker rm -f "${APP}" "${DB}" "${KC}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  if [ -n "${BUILT_IMAGE:-}" ]; then docker rmi -f "${BUILT_IMAGE}" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; docker logs --tail 50 "${APP}" >&2 2>/dev/null || true; exit 1; }

if [ -z "${IMAGE}" ]; then
  BUILT_IMAGE="${RUN_ID}:local"
  IMAGE="${BUILT_IMAGE}"
  echo "== Building ${IMAGE}"
  docker build -q -t "${IMAGE}" . >/dev/null
fi

docker network create "${NET}" >/dev/null
docker run -d --name "${DB}" --network "${NET}" \
  -e POSTGRES_DB=unleash -e POSTGRES_USER=unleash -e POSTGRES_PASSWORD=unleash \
  postgres:17-alpine >/dev/null
for _ in $(seq 1 60); do
  docker exec "${DB}" pg_isready -U unleash -d unleash >/dev/null 2>&1 && break
  sleep 1
done

# start_app <image> [docker run args...]: (re)starts the app container.
start_app() {
  local image="$1"; shift
  docker rm -f "${APP}" >/dev/null 2>&1 || true
  docker run -d --name "${APP}" --network "${NET}" --network-alias unleash -p 127.0.0.1::4242 \
    -e DATABASE_HOST="${DB}" -e DATABASE_NAME=unleash \
    -e DATABASE_USERNAME=unleash -e DATABASE_PASSWORD=unleash -e DATABASE_SSL=false \
    "$@" "${image}" >/dev/null
  PORT="$(docker port "${APP}" 4242/tcp | head -1 | awk -F: '{print $NF}')"
  BASE="http://127.0.0.1:${PORT}"
  for _ in $(seq 1 90); do
    curl -sf "${BASE}/health" >/dev/null 2>&1 && return 0
    docker inspect -f '{{.State.Running}}' "${APP}" 2>/dev/null | grep -q true || fail "container exited during start-up"
    sleep 2
  done
  fail "no healthy /health within 180 s"
}

# http <expected status> <path> [curl args...]; body lands in $BODY.
http() {
  local want="$1" path="$2"; shift 2
  local out code
  out="$(mktemp)"
  code="$(curl -s -o "${out}" -w '%{http_code}' "$@" "${BASE}${path}")"
  BODY="$(cat "${out}")"; rm -f "${out}"
  [ "${code}" = "${want}" ] || fail "${path}: expected HTTP ${want}, got ${code}: ${BODY:0:300}"
}

image_version() {
  docker run --rm --entrypoint node "$1" -p 'require("/unleash/package.json").dependencies["unleash-server"]'
}
version="$(image_version "${IMAGE}")"
SEED_IMAGE="${UPGRADE_FROM:-${IMAGE}}"
if [ -n "${UPGRADE_FROM}" ]; then
  echo "== unleash-server $(image_version "${SEED_IMAGE}") -> ${version} (upgrade path)"
else
  echo "== unleash-server ${version}"
fi

echo "== First boot: upstream migrations create the schema"
start_app "${SEED_IMAGE}"

echo "== Provision testing/staging (sql/01-environments.sql)"
docker exec -i "${DB}" psql -q -v ON_ERROR_STOP=1 -U unleash unleash < sql/01-environments.sql

echo "== Second boot: seed tokens and a flag"
# INIT_* tokens are only created when the api_tokens table is empty, which it still is.
# A backend token for `testing` can only be created once that environment exists.
start_app "${SEED_IMAGE}" -e INIT_ADMIN_API_TOKENS="${ADMIN_TOKEN}" -e INIT_BACKEND_API_TOKENS="${TESTING_TOKEN}"
http 201 /api/admin/projects/default/features -X POST -H "Authorization: ${ADMIN_TOKEN}" \
  -H 'Content-Type: application/json' -d '{"name":"smoke-flag"}'

if [ -n "${UPGRADE_FROM}" ]; then
  echo "== Boot ${version} on the seeded database (runs its migrations)"
  start_app "${IMAGE}"
fi

echo "== Custom environments must be visible"
http 200 /api/admin/environments -H "Authorization: ${ADMIN_TOKEN}"
envs="$(printf '%s' "${BODY}" | python3 -c 'import json,sys; print(" ".join(sorted(e["name"] for e in json.load(sys.stdin)["environments"])))')"
echo "   environments: ${envs}"
for want in testing staging production; do
  case " ${envs} " in *" ${want} "*) ;; *) fail "environment '${want}' not visible — the ui.environment=pro adaptation no longer works" ;; esac
done

http 200 /api/client/features -H "Authorization: ${TESTING_TOKEN}"
printf '%s' "${BODY}" | grep -q '"smoke-flag"' || fail "seeded flag missing from /api/client/features: ${BODY:0:300}"
echo "   /api/client/features accepts a testing-scoped backend token and serves the seeded flag"

echo "== Keycloak (${KC_IMAGE}) with realm test/keycloak-realm.json"
docker create --name "${KC}" --network "${NET}" --network-alias keycloak \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  "${KC_IMAGE}" start-dev --import-realm --http-port 8080 >/dev/null
# The image has no data/import yet; copying a directory creates it.
KC_IMPORT="$(mktemp -d)"; mkdir -p "${KC_IMPORT}/import"
cp test/keycloak-realm.json "${KC_IMPORT}/import/smoke-realm.json"
docker cp "${KC_IMPORT}/import" "${KC}:/opt/keycloak/data/"
rm -rf "${KC_IMPORT}"
docker start "${KC}" >/dev/null
# Plays the browser from inside the network, so Unleash and the "browser" see the
# same issuer URL (http://keycloak:8080/realms/smoke).
browser() { docker run --rm --network "${NET}" "${CURL_IMAGE}" sh -c "$1"; }
for _ in $(seq 1 90); do
  browser 'curl -sf -o /dev/null http://keycloak:8080/realms/smoke/.well-known/openid-configuration' && break
  docker inspect -f '{{.State.Running}}' "${KC}" | grep -q true || { docker logs --tail 40 "${KC}" >&2; fail "Keycloak exited"; }
  sleep 2
done
browser 'curl -sf -o /dev/null http://keycloak:8080/realms/smoke/.well-known/openid-configuration' || fail "Keycloak realm not ready within 180 s"

echo "== Third boot: OIDC sign-in enabled"
start_app "${IMAGE}" -e UNLEASH_URL=http://unleash:4242 \
  -e UNLEASH_OIDC_ISSUER=http://keycloak:8080/realms/smoke \
  -e UNLEASH_OIDC_CLIENT_ID=unleash -e UNLEASH_OIDC_CLIENT_SECRET=smoke-secret \
  -e UNLEASH_OIDC_ALLOWED_DOMAINS=example.com -e UNLEASH_OIDC_ALLOW_INSECURE=true \
  -e UNLEASH_OIDC_BUTTON_TEXT="Sign in with SSO" -e UNLEASH_SOURCE_URL=https://example.com/source

http 401 /api/admin/environments
printf '%s' "${BODY}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d.get("type") == "password", d
assert d.get("path", "").endswith("/auth/simple/login"), d
opts = d.get("options") or []
assert any(o.get("path", "").endswith("/auth/oidc/login") and o.get("message") == "Sign in with SSO" for o in opts), d
' || fail "login page is not offered password + SSO: ${BODY:0:300}"
echo "   anonymous /api/admin -> 401 offering the password form and the SSO button"

http 302 /source
echo "   /source redirects to the published source"

# oidc_login <email>: full authorization-code flow; prints the final redirect and
# the /api/admin/user status seen with the resulting session.
oidc_login() {
  browser "
    set -e; J=/tmp/jar
    kc=\$(curl -s -o /dev/null -w '%{redirect_url}' -c \$J -b \$J http://unleash:4242/auth/oidc/login)
    page=\$(curl -s -c \$J -b \$J \"\$kc\")
    action=\$(printf '%s' \"\$page\" | grep -o 'action=\"[^\"]*login-actions/authenticate[^\"]*\"' | head -1 | sed -e 's/^action=\"//' -e 's/\"\$//' -e 's/&amp;/\\&/g')
    [ -n \"\$action\" ] || { echo 'NO_LOGIN_FORM'; exit 0; }
    cb=\$(curl -s -o /dev/null -w '%{redirect_url}' -c \$J -b \$J --data-urlencode 'username=$1' --data-urlencode 'password=smoke-pass' \"\$action\")
    final=\$(curl -s -o /dev/null -w '%{redirect_url}' -c \$J -b \$J \"\$cb\")
    me=\$(curl -s -o /dev/null -w '%{http_code}' -c \$J -b \$J http://unleash:4242/api/admin/user)
    echo \"final=\$final me=\$me\"
  "
}
root_role_of() {
  curl -s -H "Authorization: ${ADMIN_TOKEN}" "${BASE}/api/admin/user-admin" | python3 -c '
import json, sys
d = json.load(sys.stdin); roles = {r["id"]: r["name"] for r in d.get("rootRoles", [])}
print(next((roles.get(u.get("rootRole"), "?") for u in d["users"] if u.get("email") == sys.argv[1]), "none"))' "$1"
}
expect_login() { # <email> <expected root role, or "denied">
  local out role; out="$(oidc_login "$1")"
  role="$(root_role_of "$1")"
  if [ "$2" = "denied" ]; then
    case "${out}" in *"/login?errorMsg="*" me=401"*) ;; *) fail "$1 should be refused, got: ${out}" ;; esac
    [ "${role}" = "none" ] || fail "$1 was refused but an Unleash user was created (role ${role})"
    echo "   $1 -> refused, no account created"
  else
    case "${out}" in *"final=http://unleash:4242/ me=200"*) ;; *) fail "$1 should sign in, got: ${out}" ;; esac
    [ "${role}" = "$2" ] || fail "$1 signed in with root role ${role}, expected $2"
    echo "   $1 -> signed in as $2"
  fi
}
expect_login admin@example.com Admin
expect_login editor@example.com Editor
expect_login norole@example.com denied
expect_login outsider@example.org denied
expect_login unverified@example.com denied

echo "== Group change at the identity provider applies at next login"
docker exec "${KC}" sh -c '
  K=/opt/keycloak/bin/kcadm.sh
  $K config credentials --server http://localhost:8080 --realm master --user admin --password admin >/dev/null 2>&1
  uid=$($K get users -r smoke -q email=editor@example.com --fields id --format csv --noquotes)
  from=$($K get groups -r smoke -q search=unleash-editors --fields id --format csv --noquotes | head -1)
  to=$($K get groups -r smoke -q search=unleash-viewers --fields id --format csv --noquotes | head -1)
  $K delete "users/$uid/groups/$from" -r smoke
  $K update "users/$uid/groups/$to" -r smoke -s realm=smoke -s userId="$uid" -s groupId="$to" -n
' || fail "could not move editor@example.com to unleash-viewers in Keycloak"
expect_login editor@example.com Viewer

echo "== Password login and API tokens still work next to SSO"
http 200 /auth/simple/login -X POST -H 'Content-Type: application/json' -d '{"username":"admin","password":"unleash4all"}'
echo "   /auth/simple/login (built-in password) -> 200"
http 200 /api/admin/environments -H "Authorization: ${ADMIN_TOKEN}"
http 200 /api/client/features -H "Authorization: ${TESTING_TOKEN}"
echo "   API tokens still bypass the hook"

echo "PASS: unleash-server ${version} keeps both adaptations${UPGRADE_FROM:+ (upgraded from $(image_version "${UPGRADE_FROM}"))}"
