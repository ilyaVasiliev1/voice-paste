#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
source "${0:A:h}/lib/update-common.sh"
[[ -n "${1:-}" ]] || { print -u2 "Укажите тег или коммит для отката"; exit 2; }
REF=$(git -C "$PROJECT_ROOT" rev-parse --verify "$1^{commit}")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/VoicePaste-rollback.XXXXXX")
cleanup() {
    git -C "$PROJECT_ROOT" worktree remove --force "$WORK/source" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT
git -C "$PROJECT_ROOT" worktree add --detach "$WORK/source" "$REF"
APP=$(build_debug "$WORK/source" "$HOME/Library/Caches/VoicePaste/Build/rollback")
python3 "$PROJECT_ROOT/scripts/build-info.py" stamp "$APP" "$WORK/source" >/dev/null
zsh "$PROJECT_ROOT/scripts/install-local.sh" "$APP"
