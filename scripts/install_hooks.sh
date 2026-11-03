#!/bin/bash
#
# install_hooks.sh — install the repository's git hooks (today: pre-push → scripts/check_all.sh).
#
# The installed hook is a two-line stub that runs scripts/hooks/<name> from whichever worktree is
# pushing, so it keeps working when a worktree is removed and always runs that tree's own version.
# Hooks live in the common git dir, shared by every worktree: install once per clone.
#
# An existing hook that is not ours is left alone and reported: it may be the owner's.
#
# Usage: scripts/install_hooks.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="$(cd "$ROOT" && git rev-parse --path-format=absolute --git-common-dir)/hooks"
MARK="# installed by scripts/install_hooks.sh"
STATUS=0

if [ -n "$(cd "$ROOT" && git config core.hooksPath || true)" ]; then
  echo "✗ core.hooksPath is set; git will not read $HOOKS_DIR. Unset it or install there by hand."
  exit 1
fi

mkdir -p "$HOOKS_DIR"
for src in "$ROOT"/scripts/hooks/*; do
  name="$(basename "$src")"
  dest="$HOOKS_DIR/$name"
  if [ -e "$dest" ] && ! grep -qF "$MARK" "$dest"; then
    echo "✗ $dest exists and is not ours — left as is"
    STATUS=1
    continue
  fi
  cat > "$dest" <<EOF
#!/bin/bash
$MARK
# A branch cut before the hook existed has no scripts/hooks/$name; nothing to run there.
hook="\$(git rev-parse --show-toplevel)/scripts/hooks/$name"
[ -x "\$hook" ] || exit 0
exec "\$hook" "\$@"
EOF
  chmod +x "$dest"
  echo "✓ $name"
done
exit $STATUS
