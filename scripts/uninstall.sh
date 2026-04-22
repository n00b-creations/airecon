#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
ORANGE='\033[38;5;214m'
CYAN='\033[0;36m'
BOLD='\033[1m'
MUTED='\033[0;2m'
NC='\033[0m'

# Restore cursor on unexpected exit
_cursor_hidden=0
_restore_cursor() { [ "$_cursor_hidden" -eq 1 ] && printf "\033[?25h" >&2; }
trap '_restore_cursor' EXIT INT TERM

# ── Spinner ───────────────────────────────────────────────────────────────────
run_spinner() {
    local label="$1"
    shift

    if [ ! -t 2 ]; then
        "$@" > /dev/null 2>&1
        return $?
    fi

    local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    local n=${#frames[@]}
    local i=0

    local out_file
    out_file=$(mktemp /tmp/airecon_spin_XXXXXX)

    printf "\033[?25l" >&2
    _cursor_hidden=1

    "$@" > "$out_file" 2>&1 &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${ORANGE}%s${NC}  ${MUTED}%s${NC}" "${frames[$i]}" "$label" >&2
        i=$(( (i + 1) % n ))
        sleep 0.08
    done

    wait "$pid"
    local rc=$?

    printf "\r\033[K" >&2
    printf "\033[?25h" >&2
    _cursor_hidden=0

    if [ "$rc" -eq 0 ]; then
        printf "  ${GREEN}✓${NC}  ${MUTED}%s${NC}\n" "$label" >&2
    else
        printf "  ${RED}✗${NC}  %s\n" "$label" >&2
        cat "$out_file" >&2
    fi

    rm -f "$out_file"
    return "$rc"
}

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}AIRecon Uninstaller${NC}"
echo ""

PYTHON_CMD="python3"
[ -f "/usr/bin/python3" ] && PYTHON_CMD="/usr/bin/python3"

# ── Check if installed ────────────────────────────────────────────────────────
CURRENT_VERSION=""
if command -v airecon &> /dev/null; then
    CURRENT_VERSION=$(airecon --version 2>/dev/null | awk '{print $NF}' || true)
fi

if [ -z "$CURRENT_VERSION" ]; then
    # Try pip as fallback even if binary not in PATH
    CURRENT_VERSION=$(pip show airecon 2>/dev/null | grep '^Version:' | awk '{print $2}' || true)
fi

if [ -z "$CURRENT_VERSION" ]; then
    echo -e "  ${YELLOW}!${NC}  ${MUTED}airecon does not appear to be installed.${NC}"
    echo ""
    exit 0
fi

echo -e "  ${MUTED}Installed version:${NC} ${BOLD}v${CURRENT_VERSION}${NC}"
echo ""

# ── Confirm ───────────────────────────────────────────────────────────────────
AUTO_YES=0
[ "${1:-}" = "-y" ] || [ "${1:-}" = "--yes" ] && AUTO_YES=1

if [ "$AUTO_YES" -eq 0 ]; then
    printf "  ${YELLOW}?${NC}  ${MUTED}Remove airecon v${CURRENT_VERSION}? [y/N]${NC} "
    read -r _reply
    case "$_reply" in
        y|Y|yes|YES) ;;
        *) echo -e "\n  ${MUTED}Aborted.${NC}"; echo ""; exit 0 ;;
    esac
    echo ""
fi

# ── Collect installed scripts before removing package ────────────────────────
_SCRIPTS=$(pip show -f airecon 2>/dev/null \
    | grep -E '^\s+\.\.' | grep '/bin/' \
    | sed 's|.*/bin/||; s/\r//' || true)

_PY_USER_LIB=$("$PYTHON_CMD" -c "import site; print(site.getusersitepackages())" 2>/dev/null || echo "")

# ── Remove pip package ────────────────────────────────────────────────────────
run_spinner "Removing pip package" bash -c "
    pip uninstall -y airecon --break-system-packages > /dev/null 2>&1 || true

    # Remove any leftover scripts (handles wrong-ownership from Docker UIDs)
    echo '${_SCRIPTS}' | while IFS= read -r _s; do
        [ -z \"\$_s\" ] && continue
        rm -f \"\$HOME/.local/bin/\$_s\" 2>/dev/null || \
            sudo rm -f \"\$HOME/.local/bin/\$_s\" 2>/dev/null || true
    done

    # Remove leftover site-packages dirs (pip may leave them on permission error)
    if [ -n '${_PY_USER_LIB}' ]; then
        rm -rf '${_PY_USER_LIB}/airecon' '${_PY_USER_LIB}/airecon-'*.dist-info 2>/dev/null || \
            sudo rm -rf '${_PY_USER_LIB}/airecon' '${_PY_USER_LIB}/airecon-'*.dist-info 2>/dev/null || true
    fi
"

# ── Remove Docker images (optional) ──────────────────────────────────────────
_SANDBOX_IMAGE="airecon-sandbox"
_SEARXNG_IMAGE="docker.io/searxng/searxng:latest"

_ask_remove_docker() {
    local _image="$1"
    local _label="$2"

    if ! command -v docker &> /dev/null; then
        return
    fi

    # Check image exists locally
    if ! docker image inspect "$_image" > /dev/null 2>&1; then
        return
    fi

    local _size
    _size=$(docker image inspect "$_image" --format '{{.Size}}' 2>/dev/null | \
        awk '{printf "%.1f GB", $1/1073741824}' || echo "")
    local _label_with_size="$_label"
    [ -n "$_size" ] && _label_with_size="$_label (${_size})"

    printf "  ${YELLOW}?${NC}  ${MUTED}Remove Docker image %s? [y/N]${NC} " "$_label_with_size"
    local _dr
    if [ "${AUTO_YES:-0}" = "1" ]; then
        _dr="y"; echo "y"
    else
        read -r _dr
    fi
    if [ "$_dr" = "y" ] || [ "$_dr" = "Y" ]; then
        echo ""
        run_spinner "Removing $_label image" docker rmi -f "$_image"
    else
        echo ""
    fi
}

_ask_remove_docker "$_SANDBOX_IMAGE" "airecon-sandbox"
_ask_remove_docker "$_SEARXNG_IMAGE" "searxng/searxng"

# ── Remove Playwright browser data (optional) ─────────────────────────────────
_PLAYWRIGHT_DIR="${HOME}/.cache/ms-playwright"
if [ -d "$_PLAYWRIGHT_DIR" ]; then
    printf "  ${YELLOW}?${NC}  ${MUTED}Remove Playwright browser cache (~/.cache/ms-playwright)? [y/N]${NC} "
    if [ "$AUTO_YES" -eq 1 ]; then
        _pw_reply="y"; echo "y"
    else
        read -r _pw_reply
    fi
    if [ "$_pw_reply" = "y" ] || [ "$_pw_reply" = "Y" ]; then
        echo ""
        run_spinner "Removing Playwright browsers" rm -rf "$_PLAYWRIGHT_DIR"
    else
        echo ""
    fi
fi

# ── Remove airecon config / data (optional) ───────────────────────────────────
_AIRECON_DATA="${HOME}/.airecon"
if [ -d "$_AIRECON_DATA" ]; then
    printf "  ${YELLOW}?${NC}  ${MUTED}Remove airecon data directory (~/.airecon — includes datasets)? [y/N]${NC} "
    if [ "$AUTO_YES" -eq 1 ]; then
        _data_reply="y"; echo "y"
    else
        read -r _data_reply
    fi
    if [ "$_data_reply" = "y" ] || [ "$_data_reply" = "Y" ]; then
        echo ""
        run_spinner "Removing ~/.airecon data" rm -rf "$_AIRECON_DATA"
    else
        echo ""
    fi
fi

echo ""

# ── Verify removed ────────────────────────────────────────────────────────────
if command -v airecon &> /dev/null; then
    echo -e "  ${YELLOW}!${NC}  ${MUTED}airecon binary still found in PATH. You may need to restart your shell.${NC}"
else
    echo -e "  ${GREEN}✓${NC}  ${MUTED}airecon has been removed${NC}"
fi

echo ""
echo -e "  ${MUTED}To reinstall:${NC}"
echo -e "     ${CYAN}curl -sSL https://pikpikcu.github.io/airecon/scripts/install.sh | bash${NC}"
echo ""
