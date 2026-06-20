#!/usr/bin/env sh
# grove installer
#   curl -fsSL https://raw.githubusercontent.com/jlopez/grove/main/install.sh | sh
#
# Env overrides: GROVE_REPO, GROVE_REF, GROVE_BIN_DIR
set -eu

REPO="${GROVE_REPO:-jlopez/grove}"
REF="${GROVE_REF:-main}"
BIN_DIR="${GROVE_BIN_DIR:-$HOME/.local/bin}"
URL="https://raw.githubusercontent.com/$REPO/$REF/bin/grove"

say() { printf 'grove-install: %s\n' "$*" >&2; }

mkdir -p "$BIN_DIR"
say "downloading grove → $BIN_DIR/grove"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$BIN_DIR/grove"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$BIN_DIR/grove" "$URL"
else
  say "error: need curl or wget"; exit 1
fi
chmod +x "$BIN_DIR/grove"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "NOTE: $BIN_DIR is not on your PATH — add this to your shell rc:"
     say "      export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

say "installed: $("$BIN_DIR/grove" version 2>/dev/null || echo grove)"
say "next: run 'grove doctor', then 'grove init'"
