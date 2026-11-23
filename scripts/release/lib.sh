# Shared helpers for scripts/release/*.sh. Sourced, not run.
#
# Store credentials live OUTSIDE the repo (this repo is public):
#   $SROKA_RELEASE_CREDS (default ~/keystores/sroka-store), directory mode 700, files mode 600.
# Layout and how to create each file: docs/releasing.md.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CREDS_DIR=${SROKA_RELEASE_CREDS:-$HOME/keystores/sroka-store}

die() { echo "release: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

# creds_file <name>: path of a credential file; fails if missing, inside the repo, or readable by others.
creds_file() {
  local f="$CREDS_DIR/$1" mode
  [ -f "$f" ] || die "missing credential $f (see docs/releasing.md)"
  case "$(cd "$(dirname "$f")" && pwd -P)/" in
    "$REPO_ROOT"/*) die "credential $f is inside the repo; move it to $CREDS_DIR outside the checkout" ;;
  esac
  mode=$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f")
  case "$mode" in
    600 | 400) ;;
    *) die "credential $f has mode $mode; run: chmod 600 '$f'" ;;
  esac
  printf '%s\n' "$f"
}

# load_env <name>: export KEY=value lines from a credential file (no shell evaluation of values).
load_env() {
  local f key value
  f=$(creds_file "$1") || exit 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    value=${value#\"}; value=${value%\"}
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "bad line in $f: $key"
    export "$key=$value"
  done <"$f"
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "needs '$1' on PATH"; }

# Refuse to release from a dirty tree: the uploaded build must match a commit.
require_clean_tree() {
  [ "${ALLOW_DIRTY:-0}" = 1 ] && return 0
  [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] \
    || die "working tree has uncommitted changes (commit first, or ALLOW_DIRTY=1)"
}

# GitHub Releases (--github-release): the same artifact that went to the store, on a tag at HEAD.
# gh_release_preflight <tag>: run BEFORE uploading anything, so a store upload never strands without its release.
gh_release_preflight() {
  require_cmd gh
  gh auth status >/dev/null 2>&1 || die "gh is not signed in (gh auth login)"
  gh release view "$1" >/dev/null 2>&1 && die "GitHub release $1 already exists; bump the version"
  git -C "$REPO_ROOT" fetch -q origin main
  git -C "$REPO_ROOT" merge-base --is-ancestor HEAD origin/main \
    || die "HEAD is not on origin/main; push it first so the release tag points at a published commit"
}

# gh_release_create <tag> <title> <notes-file> <asset>...
gh_release_create() {
  local tag=$1 title=$2 notes=$3
  shift 3
  step "GitHub release $tag"
  gh release create "$tag" "$@" --title "$title" --notes-file "$notes" \
    --target "$(git -C "$REPO_ROOT" rev-parse HEAD)"
}

# release_body <out> <heading> <notes-file> [footer]: markdown body in the style of earlier releases.
release_body() {
  {
    printf '## %s\n\n' "$2"
    cat "$3"
    if [ -n "${4:-}" ]; then printf "\n%s\n" "$4"; fi
  } >"$1"
}
