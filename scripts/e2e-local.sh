#!/usr/bin/env bash
# End-to-end walk-through of the local stack (sroka-api + sroka-parser under one `wrangler dev`).
#
# Prereqs (see workers/api/CLAUDE.md "Local stack"):
#   node scripts/dev-setup.mjs && npm run db:migrate:local -w @sroka/api && npm run build -w @sroka/web
#   npm run dev -w @sroka/api > /tmp/sroka-dev.log 2>&1 &      # OTPs are read from this log
#   (optional) npm run dev -w @sroka/web                         # enables the vite-proxy checks on :5173
# Run:  DEV_LOG=/tmp/sroka-dev.log scripts/e2e-local.sh
#
# Env: BASE (http://localhost:8787), CONTENT_BASE (http://127.0.0.1:8787), VITE_BASE (http://localhost:5173),
#      DEV_LOG (required), EMAIL (default e2e-<ts>@example.com), ARTICLE_URLS (space-separated public URLs),
#      PARSE_TIMEOUT (s, default 120), SKIP_PUBLIC=1 to skip network-dependent public article saves.
# Needs: bash, curl, jq, node. Exits non-zero on the first failed check.
set -euo pipefail

BASE=${BASE:-http://localhost:8787}
CONTENT_BASE=${CONTENT_BASE:-http://127.0.0.1:8787}
VITE_BASE=${VITE_BASE:-http://localhost:5173}
DEV_LOG=${DEV_LOG:?set DEV_LOG to the wrangler dev log file (OTP codes are read from it)}
EMAIL=${EMAIL:-e2e-$(date +%s)-$RANDOM@example.com}
ARTICLE_URLS=${ARTICLE_URLS:-"https://en.wikipedia.org/wiki/Eurasian_magpie https://blog.cloudflare.com/sqlite-in-durable-objects/"}
PARSE_TIMEOUT=${PARSE_TIMEOUT:-120}
DEVICE="dev_e2e_$RANDOM"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sroka-e2e.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
JAR="$TMP/cookies.txt"
PASS=0

ok() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; [ -f "$TMP/body" ] && head -c 600 "$TMP/body" >&2 && echo >&2; exit 1; }
section() { printf '\n== %s\n' "$*"; }

# req METHOD URL [curl args…] → sets STATUS; body in $TMP/body, headers in $TMP/headers
req() {
  local method=$1 url=$2; shift 2
  STATUS=$(curl -sS -o "$TMP/body" -D "$TMP/headers" -w '%{http_code}' -X "$method" "$url" "$@") || fail "curl $method $url"
}
api() { # api METHOD PATH [json] — bearer auth
  local method=$1 path=$2 data=${3:-}
  if [ -n "$data" ]; then req "$method" "$BASE$path" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data-binary "$data"
  else req "$method" "$BASE$path" -H "Authorization: Bearer $TOKEN"; fi
}
expect() { [ "$STATUS" = "$1" ] || fail "$2 (expected HTTP $1, got $STATUS)"; ok "$2"; }
jqb() { jq -r "$@" "$TMP/body"; }
check() { # check 'jq-bool-expr' description
  jq -e "$1" "$TMP/body" > /dev/null || fail "$2 (jq: $1)"; ok "$2"
}
header() { grep -i "^$1:" "$TMP/headers" | head -1 | cut -d' ' -f2- | tr -d '\r'; }
urlenc() { node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$1"; }

OTP_MARK=0
otp_count() { grep -cF "[sroka] OTP for $1: " "$DEV_LOG" 2>/dev/null || true; }
read_otp() { # read_otp email → newest OTP logged AFTER the last send_otp for that email
  local email=$1 code="" i
  for i in $(seq 1 40); do
    if [ "$(otp_count "$email")" -gt "$OTP_MARK" ]; then
      code=$(grep -F "[sroka] OTP for $email: " "$DEV_LOG" | tail -1 | sed -E 's/.*: ([0-9]{6}).*/\1/' || true)
      [ -n "$code" ] && { echo "$code"; return 0; }
    fi
    sleep 0.5
  done
  return 1
}

auth_post() { # auth_post URL ORIGIN JSON [curl args…] → STATUS (waits out Better Auth rate limits on 429:
  # send-verification-otp 3/min, sign-in/* 3/10s per IP)
  local url=$1 origin=$2 data=$3 i wait; shift 3
  for i in 1 2 3; do
    req POST "$url" -H 'Content-Type: application/json' -H "Origin: $origin" --data "$data" "$@"
    [ "$STATUS" = 429 ] || return 0
    wait=$(header x-retry-after); echo "  (rate limited, waiting ${wait:-30}s)"; sleep "${wait:-30}"
  done
}
send_otp() { OTP_MARK=$(otp_count "$2"); auth_post "$1/api/auth/email-otp/send-verification-otp" "$3" "{\"email\":\"$2\",\"type\":\"sign-in\"}"; }
sign_in() { # sign_in base email otp origin jar
  auth_post "$1/api/auth/sign-in/email-otp" "$4" "{\"email\":\"$2\",\"otp\":\"$3\"}" -c "$5"
}

wait_parsed() { # wait_parsed itemId → waits until parseStatus != pending; body = item response
  local id=$1 deadline=$((SECONDS + PARSE_TIMEOUT)) st
  while :; do
    api GET "/v1/items/$id"
    [ "$STATUS" = 200 ] || fail "GET item $id while polling ($STATUS)"
    st=$(jqb .item.parseStatus)
    [ "$st" != pending ] && return 0
    [ $SECONDS -ge $deadline ] && fail "item $id still pending after ${PARSE_TIMEOUT}s (is the parser queue consumer running?)"
    sleep 2
  done
}

check_content() { # check_content itemId scope-prefix → fetches article.html + an image, checks headers, tamper → 403
  local id=$1 scope=$2
  api GET "/v1/items/$id/content"; expect 200 "content urls for $id"
  local article base pkg
  article=$(jqb .articleUrl); base=$(jqb .baseUrl); pkg=$(jqb .packageUrl)
  case "$article" in "$CONTENT_BASE/s/"*"/$scope"*) ok "articleUrl on CONTENT_ORIGIN, scope $scope";; *) fail "articleUrl $article";; esac

  req GET "$article" -H "Origin: http://localhost:5173"; expect 200 "GET article.html"
  [ "$(header content-type)" = "text/html; charset=utf-8" ] || fail "article content-type: $(header content-type)"
  [ "$(header x-content-type-options)" = nosniff ] || fail "nosniff missing"
  header content-security-policy | grep -q "default-src 'none'" || fail "CSP missing"
  header content-security-policy | grep -q "sandbox" || fail "CSP sandbox missing"
  [ "$(header access-control-allow-origin)" = "http://localhost:5173" ] || fail "ACAO for dev origin: '$(header access-control-allow-origin)'"
  header vary | grep -qi origin || fail "Vary: Origin missing"
  if [ "$scope" = p ]; then header cache-control | grep -q "public" || fail "public cache-control"
  else header cache-control | grep -q "no-store" || fail "private cache-control: $(header cache-control)"; fi
  grep -qi "<script" "$TMP/body" && fail "article.html contains <script"
  ok "article headers (type, nosniff, CSP sandbox, CORS, cache-control)"
  local img
  img=$(grep -oE 'src="img/[^"]+"' "$TMP/body" | head -1 | sed -E 's/src="([^"]+)"/\1/' || true)

  req GET "$article" -H "Origin: $BASE"; expect 200 "article with APP_ORIGIN Origin"
  [ "$(header access-control-allow-origin)" = "$BASE" ] || fail "ACAO for APP_ORIGIN: '$(header access-control-allow-origin)'"
  req GET "$article" -H "Origin: https://evil.example"; expect 200 "article with foreign Origin"
  [ -z "$(header access-control-allow-origin)" ] || fail "ACAO must be absent for foreign origin"
  ok "no ACAO for foreign origin"

  if [ -n "$img" ]; then
    req GET "$base$img"; expect 200 "GET article image $img"
    header content-type | grep -q '^image/' || fail "image content-type $(header content-type)"
    [ "$(wc -c < "$TMP/body")" -gt 100 ] || fail "image too small"
    node "$SCRIPT_DIR/sniff-image.mjs" "$TMP/body" "$(header content-type)" > /dev/null || fail "image bytes don't match content-type"
    ok "image bytes ($(wc -c < "$TMP/body" | tr -d ' ') B, $(header content-type))"
  else
    echo "  (no img/ in article — skipping image check)"
  fi

  req GET "$pkg"; expect 200 "GET package.zip"
  [ "$(head -c 2 "$TMP/body")" = PK ] || fail "package.zip is not a zip"

  local tampered
  tampered=$(node -e 'const u=new URL(process.argv[1]);const p=u.pathname.split("/");const s=p[3];p[3]=(s[0]==="A"?"B":"A")+s.slice(1);u.pathname=p.join("/");console.log(u.href)' "$article")
  req GET "$tampered"; expect 403 "tampered signature → 403"
  check '.error=="forbidden"' "tampered body is forbidden"
  req POST "$article"; expect 405 "POST on content → 405"
  req GET "$CONTENT_BASE/v1/health"; expect 404 "content host serves only /s/"
}

# ---------------------------------------------------------------------------------------------
section "static + public endpoints"
req GET "$BASE/"; expect 200 "GET / (landing)"
grep -q '/assets/landing' "$TMP/body" || fail "landing html"
req GET "$BASE/app/"; expect 200 "GET /app/"
grep -q '/assets/app-' "$TMP/body" || fail "/app/ is not the SPA shell"
req GET "$BASE/app/item/x"; expect 200 "GET /app/item/x (SPA deep link)"
grep -q '/assets/app-' "$TMP/body" || fail "deep link is not the SPA shell"
asset=$(grep -oE '/assets/app-[^"]+\.js' "$TMP/body" | head -1) || true
[ -n "$asset" ] || fail "no /assets/app-*.js referenced by the SPA shell"
req GET "$BASE$asset"; expect 200 "GET $asset"
req GET "$BASE/v1/health"; expect 200 "GET /v1/health"; check '.ok==true' "health ok"
req GET "$BASE/v1/config"; expect 200 "GET /v1/config"; check '.appOrigin and .limits.maxOpsPerPush==500' "config shape"
req GET "$BASE/v1/me"; expect 401 "GET /v1/me unauthenticated"
req GET "$BASE/api/nope"; expect 404 "unknown /api path → JSON 404"
req OPTIONS "$BASE/v1/items" -H "Origin: chrome-extension://abcdef" -H "Access-Control-Request-Method: POST" -H "Access-Control-Request-Headers: authorization,content-type"
[ "$(header access-control-allow-origin)" = "chrome-extension://abcdef" ] || fail "CORS preflight for extension origin"
ok "CORS preflight for chrome-extension origin"

# ---------------------------------------------------------------------------------------------
section "auth (email OTP) as $EMAIL"
send_otp "$BASE" "$EMAIL" "$BASE"
expect 200 "send OTP"
OTP=$(read_otp "$EMAIL") || fail "OTP for $EMAIL not found in $DEV_LOG"
ok "OTP read from dev log"
WRONG=$([ "$OTP" = 000000 ] && echo 111111 || echo 000000)
sign_in "$BASE" "$EMAIL" "$WRONG" "$BASE" "$JAR"
[ "$STATUS" = 400 ] || fail "wrong OTP should be 400, got $STATUS"; ok "wrong OTP → 400"
sign_in "$BASE" "$EMAIL" "$OTP" "$BASE" "$JAR"
expect 200 "sign in"
TOKEN=$(header set-auth-token)
[ -n "$TOKEN" ] || fail "set-auth-token header missing"; ok "set-auth-token captured"
grep -q session_token "$JAR" || fail "session cookie missing"; ok "session cookie captured"

api GET /v1/me; expect 200 "/v1/me with bearer"
check ".user.email==\"$EMAIL\" and .stats.unread==0" "me (bearer) user + stats"
USER_ID=$(jqb .user.id)
req GET "$BASE/v1/me" -b "$JAR"; expect 200 "/v1/me with cookie"
check ".user.id==\"$USER_ID\"" "me (cookie) same user"
req GET "$BASE/v1/me" -H "Authorization: Bearer nope.nope"; expect 401 "bad bearer → 401"

# ---------------------------------------------------------------------------------------------
section "save items"
PUBLIC_IDS=""
if [ "${SKIP_PUBLIC:-}" != 1 ]; then
  for u in $ARTICLE_URLS; do
    api POST /v1/items "{\"url\":\"$u\",\"tags\":[\"birds\"],\"source\":\"web\"}"; expect 202 "save $u"
    check '.created==true and .item.parseStatus=="pending"' "created, pending"
    PUBLIC_IDS="$PUBLIC_IDS $(jqb .item.id)"
  done
  first_url=${ARTICLE_URLS%% *}
  api POST /v1/items "{\"url\":\"$first_url?utm_source=e2e\"}"; expect 202 "re-save same URL (utm stripped)"
  check '.created==false' "duplicate → created:false"
fi

CAP_URL="https://example.com/e2e-capture-$RANDOM"
CAP_HTML=$(node -e '
const p = Array.from({length: 12}, (_, i) => `<p>Paragraph ${i}: magpies are among the most intelligent animals, able to recognise themselves in a mirror and to cache food for later. Zanzibarquux marker.</p>`).join("");
const img = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
process.stdout.write(JSON.stringify({url: process.argv[1], title: "Captured magpie page", source: "extension", tags: ["Captured"],
  html: `<!doctype html><html lang="en"><head><title>Captured magpie page</title><script>alert(1)</script></head><body><article><h1>Captured magpie page</h1>${p}<img src="${img}" onerror="alert(1)"><p><img src="${process.argv[2]}" alt="remote"></p></article></body></html>`}));
' "$CAP_URL" "${CAPTURE_IMAGE:-https://upload.wikimedia.org/wikipedia/commons/a/a9/Example.jpg}")
api POST /v1/items "$CAP_HTML"; expect 202 "save with html capture"
CAP_ID=$(jqb .item.id)

section "parse (queue consumer)"
for id in $PUBLIC_IDS $CAP_ID; do
  wait_parsed "$id"
  st=$(jqb .item.parseStatus)
  case "$st" in ok|partial) ok "item $id parsed: $st — $(jqb .item.title) ($(jqb .item.wordCount) words)";;
    *) fail "item $id parseStatus=$st error=$(jqb .item.parseError)";; esac
done
api GET "/v1/items/$CAP_ID"
check '.item.contentPrivate==true and .item.title=="Captured magpie page"' "capture is private, title parsed"

section "content delivery"
for id in $PUBLIC_IDS; do
  check_content "$id" p
  api GET "/v1/items/$id"
  lead=$(jqb '.item.leadImageUrl // empty')
  if [ -n "$lead" ]; then
    req GET "$lead"; expect 200 "lead image (thumb)"
    node "$SCRIPT_DIR/sniff-image.mjs" "$TMP/body" "$(header content-type)" > /dev/null || fail "thumb bytes don't match content-type"
  fi
done
check_content "$CAP_ID" "u.$USER_ID"
api GET "/v1/items/$CAP_ID/content"; PRIVATE_ARTICLE=$(jqb .articleUrl)

# ---------------------------------------------------------------------------------------------
section "tags"
api PATCH "/v1/items/$CAP_ID" '{"tags":["Captured","to-read","Ćma"]}'; expect 200 "PATCH tags (replace set)"
check '(.item.tags|sort)==(["Captured","Ćma","to-read"]|sort)' "item tags replaced"
api GET /v1/tags; expect 200 "GET /v1/tags"
check '[.tags[].name]|index("to-read")!=null' "to-read listed"
TAG_ID=$(jqb '.tags[]|select(.name=="to-read")|.id')
api PATCH "/v1/tags/$TAG_ID" '{"name":"Later"}'; expect 200 "rename tag to-read → Later"
check '.tag.name=="Later" and .tag.count==1' "renamed tag with count"
api GET "/v1/items/$CAP_ID"; check '.item.tags|index("Later")!=null' "item shows renamed tag"
api PATCH "/v1/tags/$TAG_ID" '{"name":"captured"}'; expect 200 "rename into existing (merge, case-insensitive)"
check '.tag.name=="Captured"' "merged into Captured"
CMA_ID=$(api GET /v1/tags; jqb '.tags[]|select(.name=="Ćma")|.id')
api DELETE "/v1/tags/$CMA_ID"; expect 204 "DELETE tag Ćma"
api GET "/v1/items/$CAP_ID"; check '.item.tags==["Captured"]' "tag removed from item"
api DELETE "/v1/tags/$CMA_ID"; expect 404 "DELETE deleted tag → 404"
api GET "/v1/tags/suggestions?url=$(urlenc "$CAP_URL")"; expect 200 "tag suggestions"
check '.current==["Captured"]' "suggestions.current"

# ---------------------------------------------------------------------------------------------
section "item mutations"
api PATCH "/v1/items/$CAP_ID" '{"isFavorite":true}'; expect 200 "favorite"; check '.item.isFavorite==true' "isFavorite"
api PATCH "/v1/items/$CAP_ID" '{"progress":0.5,"progressAnchor":3}'; expect 200 "progress"
check '.item.progress==0.5 and .item.progressAnchor==3' "progress stored"
api PATCH "/v1/items/$CAP_ID" '{"title":"My title"}'; expect 200 "set title"; check '.item.title=="My title"' "user title"
api PATCH "/v1/items/$CAP_ID" '{"title":""}'; expect 200 "reset title"; check '.item.title=="Captured magpie page"' "title reset"
api PATCH "/v1/items/$CAP_ID" '{}'; expect 400 "empty PATCH → 400"
api PATCH "/v1/items/$CAP_ID" '{"status":"archived"}'; expect 200 "archive"
check '.item.status=="archived" and (.item.archivedAt|type)=="number"' "archived"

section "list filters"
api GET "/v1/items"; expect 200 "list default (unread)"
check "[.items[].id]|index(\"$CAP_ID\")==null" "archived item not in unread"
api GET "/v1/items?state=archived"; check "[.items[].id]==[\"$CAP_ID\"]" "state=archived"
api GET "/v1/items?state=favorites"; check "[.items[].id]==[\"$CAP_ID\"]" "state=favorites"
api GET "/v1/items?state=all&tag=captured"; check "[.items[].id]==[\"$CAP_ID\"]" "tag filter (case-insensitive)"
api GET "/v1/items?state=all&tag=nope"; check '.items==[]' "unknown tag → empty"
api GET "/v1/items?state=all&q=zanzibarq"; check "[.items[].id]==[\"$CAP_ID\"]" "q prefix search (FTS)"
api GET "/v1/items?state=all&q=$(urlenc '"(*')"; expect 200 "q with FTS syntax chars → 200"
api GET "/v1/items?state=all&domain=example.com"; check "[.items[].id]|index(\"$CAP_ID\")!=null" "domain filter"
api GET "/v1/items?state=all&url=$(urlenc "$CAP_URL?utm_source=x")"; check "[.items[].id]==[\"$CAP_ID\"]" "url lookup (normalized)"
api GET "/v1/items?url=notaurl"; expect 400 "url lookup invalid → 400"
api GET "/v1/items?cursor=garbage"; expect 400 "bad cursor → 400"
if [ -n "$PUBLIC_IDS" ]; then
  api GET "/v1/items?state=all&domain=wikipedia.org"; check '.items|length>=1' "domain=wikipedia.org (subdomain match)"
  api GET "/v1/items?state=all&tag=birds&sort=longest"; check '.items|length>=1' "tag=birds sort=longest"
  api GET "/v1/items?state=all&sort=oldest&limit=1"; expect 200 "page 1 (limit=1)"
  c=$(jqb .nextCursor); first=$(jqb '.items[0].id')
  [ "$c" != null ] || fail "nextCursor expected"
  api GET "/v1/items?state=all&sort=oldest&limit=1&cursor=$(urlenc "$c")"; expect 200 "page 2 via cursor"
  [ "$(jqb '.items[0].id')" != "$first" ] || fail "cursor paging repeated a row"; ok "cursor paging advances"
fi
api PATCH "/v1/items/$CAP_ID" '{"status":"unread"}'; expect 200 "unarchive"; check '.item.archivedAt==null' "archivedAt cleared"

section "refresh + delete"
if [ -n "$PUBLIC_IDS" ]; then
  RID=${PUBLIC_IDS# }; RID=${RID%% *}
  api POST "/v1/items/$RID/refresh"; expect 202 "refresh"; check '.item.parseStatus=="pending"' "refresh → pending"
  wait_parsed "$RID"; check '.item.parseStatus=="ok" or .item.parseStatus=="partial"' "refreshed parse finished"
fi

# ---------------------------------------------------------------------------------------------
section "sync push/pull ($DEVICE)"
api GET "/v1/sync/pull?cursor=0&limit=1000"; expect 200 "initial pull"
C0=$(jqb .cursor); check '.hasMore==false and (.items|length)>=1' "initial pull has items"
NOW=$(node -e 'console.log(Date.now())')
SYNC_ID=$(node -e 'const h=Date.now().toString(16).padStart(12,"0");const r=[...crypto.getRandomValues(new Uint8Array(10))].map(b=>b.toString(16).padStart(2,"0")).join("");console.log(`${h.slice(0,8)}-${h.slice(8)}-7${r.slice(0,3)}-a${r.slice(3,6)}-${r.slice(6,18)}`)')
PUSH=$(jq -nc --arg d "$DEVICE" --arg id "$SYNC_ID" --arg cap "$CAP_ID" --arg capurl "$CAP_URL" --argjson at "$NOW" '{deviceId:$d, ops:[
  {opId:"o1",type:"item.add",itemId:$id,at:$at,url:"https://example.org/sync-e2e?utm_medium=x",title:"From device",tags:["synced"],source:"share"},
  {opId:"o2",type:"item.setFavorite",itemId:$id,value:true,at:($at+1)},
  {opId:"o3",type:"item.add",itemId:"0192aaaa-0000-7000-8000-000000000001",at:$at,url:$capurl},
  {opId:"o4",type:"item.tag",itemId:"0192aaaa-0000-7000-8000-000000000001",tag:"via-alias",present:true,at:($at+2)},
  {opId:"o5",type:"item.setStatus",itemId:"0192bbbb-0000-7000-8000-000000000009",status:"archived",at:$at},
  {opId:"o6",type:"bogus"}]}')
api POST /v1/sync/push "$PUSH"; expect 200 "push"
check '.applied==["o1","o2","o3","o4"]' "applied o1-o4"
check '[.rejected[]|.opId+":"+.reason]|sort==["o5:unknown_item","o6:invalid_op"]' "rejected unknown_item + invalid_op"
check ".aliases[\"0192aaaa-0000-7000-8000-000000000001\"]==\"$CAP_ID\"" "duplicate add aliased to existing item"
api POST /v1/sync/push "$PUSH"; expect 200 "push again (idempotent)"; check '.applied==["o1","o2","o3","o4"]' "idempotent replay"
api GET "/v1/sync/pull?cursor=$C0"; expect 200 "pull since cursor"
check "[.items[].id]|(index(\"$SYNC_ID\")!=null and index(\"$CAP_ID\")!=null)" "pull returns changed rows"
check "(.items[]|select(.id==\"$SYNC_ID\")|.isFavorite==true and .canonicalUrl==\"https://example.org/sync-e2e\")" "synced item fields"
check "(.items[]|select(.id==\"$CAP_ID\")|.tags|index(\"via-alias\")!=null)" "op on alias id applied to target"
check '[.tags[].name]|index("synced")!=null' "new tag in pull"
C1=$(jqb .cursor)
api DELETE "/v1/items/$SYNC_ID"; expect 204 "DELETE item"
api GET "/v1/items/$SYNC_ID"; expect 404 "deleted item → 404"
api GET "/v1/sync/pull?cursor=$C1"; check ".deleted.items|index(\"$SYNC_ID\")!=null" "tombstone in pull"
api GET "/v1/sync/pull?cursor=abc"; expect 400 "pull bad cursor → 400"

# ---------------------------------------------------------------------------------------------
section "import (Pocket CSV + Netscape HTML via ImportWorkflow)"
now_s=$(date +%s)
cat > "$TMP/pocket.csv" <<CSV
title,url,time_added,tags,status
"Imported One",https://example.com/imp-one,$((now_s - 300)),alpha|beta gamma,unread
"=HYPERLINK(""http://evil.example/"",""x"")",https://example.com/imp-two,$((now_s - 200)),"x,y",archive
"No url row",,$((now_s - 100)),,unread
"Imported Three",https://example.com/imp-three,$((now_s - 50)),,unread
CSV
cat > "$TMP/bookmarks.html" <<HTML
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<DL><p>
<DT><H3>Reading Folder</H3>
<DL><p>
<DT><A HREF="https://example.com/imp-html-one" ADD_DATE="$((now_s - 400))" TAGS="htmltag,second">HTML One</A>
<DT><A HREF="https://example.com/imp-html-two" ADD_DATE="$((now_s - 350))">HTML Two</A>
</DL><p>
</DL><p>
HTML

poll_job() { # poll_job id → waits for done/failed; body = job response
  local id=$1 deadline=$((SECONDS + 120))
  while :; do
    api GET "/v1/imports/$id"
    case "$(jqb .job.status)" in done) return 0 ;; failed) fail "import job failed: $(jqb .job.error)" ;; esac
    [ $SECONDS -lt $deadline ] || fail "import job $id did not finish"
    sleep 1
  done
}
upload() { # upload FORMAT FILE → STATUS/body of POST /v1/imports
  req POST "$BASE/v1/imports" -H "Authorization: Bearer $TOKEN" -F "format=$1" -F "file=@$2"
}

upload pocket_csv "$TMP/pocket.csv"; expect 202 "POST /v1/imports (pocket_csv)"
check '.job.status=="queued" or .job.status=="running"' "job accepted"
JOB1=$(jqb .job.id)
poll_job "$JOB1"
check '.job.done==4 and .job.skipped==1 and .job.total==4' "csv job done: 4 rows processed, 1 skipped"
api GET "/v1/items?state=all&limit=100"
check '[.items[].canonicalUrl]|(index("https://example.com/imp-one")!=null and index("https://example.com/imp-three")!=null)' "csv items present"
check '(.items[]|select(.canonicalUrl=="https://example.com/imp-one")|.tags|sort)==["alpha","beta gamma"]' "csv tags split on |"
check '(.items[]|select(.canonicalUrl=="https://example.com/imp-two")|.status)=="archived"' "csv archive status"
check '(.items[]|select(.canonicalUrl=="https://example.com/imp-two")|.title|startswith("=HYPERLINK"))' "formula-looking title imported verbatim"
check '(.items[]|select(.canonicalUrl=="https://example.com/imp-two")|.tags|sort)==["x","y"]' "csv tags split on comma without |"

upload netscape_html "$TMP/bookmarks.html"; expect 202 "POST /v1/imports (netscape_html)"
JOB2=$(jqb .job.id)
poll_job "$JOB2"
check '.job.done==2' "html job done: 2 rows"
api GET "/v1/items?state=all&limit=100&tag=htmltag"
check '[.items[].canonicalUrl]==["https://example.com/imp-html-one"]' "html item present with tag filter"
upload pocket_csv "$TMP/pocket.csv"; expect 202 "re-import same csv"
poll_job "$(jqb .job.id)"
api GET "/v1/items?state=all&limit=100"
check '[.items[]|select(.canonicalUrl=="https://example.com/imp-one")]|length==1' "re-import merges duplicates"
printf 'nope' > "$TMP/bad.txt"
req POST "$BASE/v1/imports" -H "Authorization: Bearer $TOKEN" -F "format=bogus" -F "file=@$TMP/bad.txt"; expect 400 "bad import format → 400"
req POST "$BASE/v1/imports" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data '{}'; expect 415 "non-multipart import → 415"
api GET "/v1/imports/nonexistent"; expect 404 "unknown job → 404"

# ---------------------------------------------------------------------------------------------
section "exports"
api GET "/v1/exports?format=json"; expect 200 "export json"
header content-disposition | grep -q 'attachment; filename="sroka-export-.*\.json"' || fail "json content-disposition"; ok "json attachment header"
check '.format=="sroka-export" and (.items|length)>=5' "export json body"
check '(.items[]|select(.url|endswith("/imp-one"))|(.tags|sort)==["alpha","beta gamma"] and .status=="unread")' "json export has imported item with tags"
check '(.items[]|select(.url|endswith("/imp-two"))|.status=="archived")' "json export keeps archived status"
api GET "/v1/exports?format=csv"; expect 200 "export csv"
head -1 "$TMP/body" | grep -q '^title,url,time_added,tags,status,favorite' || fail "csv header"; ok "csv header"
grep -q 'example.com/imp-one,[0-9]*,alpha|beta gamma,unread,0' "$TMP/body" || fail "csv row for imp-one"; ok "csv row with tags"
grep -q "'=HYPERLINK" "$TMP/body" || fail "csv formula guard missing"; ok "csv formula injection guarded with leading '"
if grep -qE '^"?=HYPERLINK' "$TMP/body"; then fail "csv has an unguarded formula"; fi; ok "no unguarded formula cell"
cp "$TMP/body" "$TMP/export.csv"
upload pocket_csv "$TMP/export.csv"; expect 202 "re-import our own csv export"
poll_job "$(jqb .job.id)"
api GET "/v1/items?state=all&limit=100"
check '(.items[]|select(.canonicalUrl=="https://example.com/imp-two")|.title|startswith("=HYPERLINK"))' "round trip strips the guard quote"

# ---------------------------------------------------------------------------------------------
section "vite dev proxy ($VITE_BASE)"
if curl -s -o /dev/null --max-time 2 "$VITE_BASE/app/"; then
  VEMAIL="vite-$EMAIL"
  req GET "$VITE_BASE/app/items/x"; expect 200 "vite SPA deep link"
  send_otp "$VITE_BASE" "$VEMAIL" "$VITE_BASE"; expect 200 "send OTP via vite proxy"
  VOTP=$(read_otp "$VEMAIL") || fail "vite OTP not in log"
  sign_in "$VITE_BASE" "$VEMAIL" "$VOTP" "$VITE_BASE" "$TMP/vjar"; expect 200 "sign in via vite proxy (Origin localhost:5173)"
  req GET "$VITE_BASE/v1/me" -b "$TMP/vjar"; expect 200 "/v1/me via vite proxy with cookie"
  check ".user.email==\"$VEMAIL\"" "vite session user"
  req DELETE "$VITE_BASE/v1/account" -b "$TMP/vjar" -H 'Content-Type: application/json' -H "Origin: $VITE_BASE" --data '{"confirm":"DELETE"}'
  expect 200 "delete vite account"
else
  echo "  (vite not running on $VITE_BASE — skipped; start with: npm run dev -w @sroka/web)"
fi

# ---------------------------------------------------------------------------------------------
section "account deletion"
api DELETE /v1/account '{}'; expect 400 "DELETE /v1/account without confirm → 400"
api DELETE /v1/account '{"confirm":"DELETE"}'; expect 200 "DELETE /v1/account"; check '.deleted==true' "deleted:true"
api GET /v1/me; expect 401 "token invalid after deletion"
req GET "$BASE/v1/me" -b "$JAR"; expect 401 "cookie invalid after deletion"
for i in $(seq 1 20); do req GET "$PRIVATE_ARTICLE"; [ "$STATUS" = 404 ] && break; sleep 0.5; done
expect 404 "private content wiped from R2"
send_otp "$BASE" "$EMAIL" "$BASE"; expect 200 "send OTP again (same email)"
OTP=$(read_otp "$EMAIL") || fail "second OTP not found"
sign_in "$BASE" "$EMAIL" "$OTP" "$BASE" "$TMP/jar2"; expect 200 "sign up again with the same email"
TOKEN=$(header set-auth-token)
api GET /v1/me; check ".user.id!=\"$USER_ID\" and .stats.unread==0 and .stats.tags==0" "fresh account, empty stats"
api GET "/v1/items?state=all"; check '.items==[]' "fresh library is empty"
api GET "/v1/sync/pull?cursor=0"; check '.items==[] and .tags==[] and .deleted.items==[]' "fresh pull is empty"
api DELETE /v1/account '{"confirm":"DELETE"}'; expect 200 "cleanup: delete second account"

printf '\n\033[32mAll %d checks passed.\033[0m\n' "$PASS"
