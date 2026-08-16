#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LABEL=com.anhoder.display-steward
LEGACY_LABEL=com.anhoder.screen-manager
PLIST_PATH="$ROOT_DIR/$LABEL.plist"
INSTALL_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_INSTALL_PATH="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
CONFIG_PATH="$HOME/.config/display-steward"
LEGACY_CONFIG_PATH="$HOME/.config/screen-manager"

MODE=${1:-install}

# Render the LaunchAgent template with the checkout and log paths of this
# machine. The committed plist only carries __ROOT_DIR__/__LOG_DIR__ markers
# so the repository stays machine-independent.
render_plist() {
    sed -e "s|__ROOT_DIR__|$ROOT_DIR|g" -e "s|__LOG_DIR__|$HOME/Library/Logs|g" "$PLIST_PATH"
}

if test "$MODE" = "--smoke-test"; then
    "$ROOT_DIR/build.sh"
    STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/display-steward-install.XXXXXX")
    trap 'rm -rf "$STAGING_DIR"' EXIT INT TERM
    STAGED_PLIST="$STAGING_DIR/$LABEL.plist"
    render_plist > "$STAGED_PLIST"
    plutil -lint "$ROOT_DIR/Info.plist" "$PLIST_PATH" "$STAGED_PLIST" "$ROOT_DIR/build/Display Steward.app/Contents/Info.plist"
    test "$(plutil -extract Label raw -o - "$STAGED_PLIST")" = "$LABEL"
    test "$(plutil -extract ProgramArguments.0 raw -o - "$STAGED_PLIST")" = "$ROOT_DIR/build/Display Steward.app/Contents/MacOS/DisplaySteward"
    test -x "$ROOT_DIR/build/Display Steward.app/Contents/MacOS/DisplaySteward"
    codesign --verify --deep --strict --verbose=2 "$ROOT_DIR/build/Display Steward.app"
    printf 'Install smoke passed without changing LaunchAgents, processes, configuration, or displays.\n'
    exit 0
fi
if test "$MODE" != "install"; then
    printf 'Usage: %s [--smoke-test]\n' "$0" >&2
    exit 64
fi

"$ROOT_DIR/build.sh"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/.config"

uid=$(id -u)
launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$uid/$LEGACY_LABEL" 2>/dev/null || true
pkill -TERM -x DisplaySteward 2>/dev/null || true
pkill -TERM -x ScreenManager 2>/dev/null || true
sleep 1

if test -d "$LEGACY_CONFIG_PATH" && ! test -e "$CONFIG_PATH"; then
    mv "$LEGACY_CONFIG_PATH" "$CONFIG_PATH"
fi

render_plist > "$INSTALL_PATH"
plutil -lint "$INSTALL_PATH"
rm -f "$LEGACY_INSTALL_PATH"
launchctl bootstrap "gui/$uid" "$INSTALL_PATH"
launchctl print "gui/$uid/$LABEL" | sed -n '1,20p'
printf 'Installed: %s\n' "$INSTALL_PATH"
