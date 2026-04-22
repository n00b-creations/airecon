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

REPO_URL="https://github.com/pikpikcu/airecon"
BRANCH="main"

# Restore cursor on unexpected exit
_cursor_hidden=0
_restore_cursor() { [ "$_cursor_hidden" -eq 1 ] && printf "\033[?25h" >&2; }
trap '_restore_cursor' EXIT INT TERM

# ── Spinner for long-running commands ────────────────────────────────────────
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

# ── Download progress bar (real bytes) ───────────────────────────────────────
print_progress() {
    local bytes="$1"
    local length="$2"
    [ "$length" -gt 0 ] || return 0

    local width=46
    local percent=$(( bytes * 100 / length ))
    [ "$percent" -gt 100 ] && percent=100
    local on=$(( percent * width / 100 ))
    local off=$(( width - on ))

    local filled=$(printf "%*s" "$on" "")
    filled=${filled// /■}
    local empty=$(printf "%*s" "$off" "")
    empty=${empty// /·}

    printf "\r  ${ORANGE}%s%s${NC} ${MUTED}%3d%%${NC}" "$filled" "$empty" "$percent" >&4
}

unbuffered_sed() {
    if echo | sed -u -e "" >/dev/null 2>&1; then
        sed -nu "$@"
    elif echo | sed -l -e "" >/dev/null 2>&1; then
        sed -nl "$@"
    else
        local pad="$(printf "\n%512s" "")"
        sed -ne "s/$/\\${pad}/" "$@"
    fi
}

download_with_progress() {
    local url="$1"
    local output="$2"
    local label="${3:-Downloading...}"

    if [ -t 2 ]; then
        exec 4>&2
    else
        exec 4>/dev/null
    fi

    local tmp_dir=${TMPDIR:-/tmp}
    local tracefile="${tmp_dir}/airecon_trace_$$"

    rm -f "$tracefile"
    mkfifo "$tracefile"

    printf "\033[?25l" >&4
    _cursor_hidden=1
    printf "  ${MUTED}%s${NC}\n" "$label" >&4

    trap "trap - RETURN; rm -f \"$tracefile\"; printf '\033[?25h' >&4; _cursor_hidden=0; exec 4>&-" RETURN

    curl --trace-ascii "$tracefile" -s -L -o "$output" "$url" &
    local curl_pid=$!

    unbuffered_sed \
        -e 'y/ACDEGHLNORTV/acdeghlnortv/' \
        -e '/^0000: content-length:/p' \
        -e '/^<= recv data/p' \
        "$tracefile" | \
    {
        local length=0
        local bytes=0

        while IFS=" " read -r -a line; do
            [ "${#line[@]}" -lt 2 ] && continue
            local tag="${line[0]} ${line[1]}"

            if [ "$tag" = "0000: content-length:" ]; then
                length="${line[2]}"
                length=$(echo "$length" | tr -d '\r')
                bytes=0
            elif [ "$tag" = "<= recv" ]; then
                local size="${line[3]}"
                bytes=$(( bytes + size ))
                if [ "$length" -gt 0 ]; then
                    print_progress "$bytes" "$length"
                fi
            fi
        done
    }

    wait "$curl_pid"
    local exit_code=$?

    printf "\r\033[K" >&4
    printf "\033[?25h" >&4
    _cursor_hidden=0

    if [ "$exit_code" -eq 0 ]; then
        printf "  ${GREEN}✓${NC}  ${MUTED}%s${NC}\n" "$label" >&4
    else
        printf "  ${RED}✗${NC}  Download failed\n" >&4
    fi

    rm -f "$tracefile"
    exec 4>&-
    return "$exit_code"
}

# ── Detect local vs remote (curl|bash) mode ──────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/tmp}")" && pwd 2>/dev/null || echo /tmp)"
PYPROJECT="$SCRIPT_DIR/pyproject.toml"

if [ ! -f "$PYPROJECT" ]; then
    if ! command -v git &> /dev/null; then
        echo -e "${RED}[!] git is required but not installed.${NC}"
        exit 1
    fi

    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"; _restore_cursor' EXIT

    run_spinner "Cloning repository" \
        git clone --quiet --depth=1 --branch "$BRANCH" "$REPO_URL" "$TMP_DIR" \
        || { echo -e "${RED}[!] Failed to clone repository.${NC}"; exit 1; }

    SCRIPT_DIR="$TMP_DIR"
    PYPROJECT="$SCRIPT_DIR/pyproject.toml"
fi

cd "$SCRIPT_DIR"

# ── Detect version ────────────────────────────────────────────────────────────
NEW_VERSION=$(grep -m1 '^version' "$PYPROJECT" | sed 's/version = "\(.*\)"/\1/')

normalize_ver() {
    echo "$1" | sed 's/-beta$/b0/; s/-alpha$/a0/; s/-rc\([0-9]*\)$/rc\1/'
}

PYTHON_CMD="python3"
[ -f "/usr/bin/python3" ] && PYTHON_CMD="/usr/bin/python3"

# ── Show installed / incoming version ────────────────────────────────────────
CURRENT_VERSION=""
if command -v airecon &> /dev/null; then
    CURRENT_VERSION=$(airecon --version 2>/dev/null | awk '{print $NF}' || true)
fi

echo ""
if [ -n "$CURRENT_VERSION" ]; then
    echo -e "  ${MUTED}Installed:${NC} ${BOLD}v${CURRENT_VERSION}${NC}"
fi
echo -e "  ${MUTED}Installing:${NC} ${BOLD}v${NEW_VERSION}${NC}"
echo ""

# ── Check Python >= 3.12 ──────────────────────────────────────────────────────
PY_OK=$($PYTHON_CMD -c "import sys; print('yes' if sys.version_info >= (3,12) else 'no')" 2>/dev/null || echo "no")
if [ "$PY_OK" != "yes" ]; then
    PY_VERSION=$($PYTHON_CMD -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
    echo -e "${RED}[!] Python >= 3.12 required, found $PY_VERSION${NC}"
    exit 1
fi

# ── Version comparison ────────────────────────────────────────────────────────
if [ -n "$CURRENT_VERSION" ]; then
    if [ "$(normalize_ver "$CURRENT_VERSION")" = "$(normalize_ver "$NEW_VERSION")" ]; then
        echo -e "  ${MUTED}Already installed — reinstalling${NC}"
    else
        echo -e "  ${MUTED}Upgrading${NC} v${CURRENT_VERSION} ${MUTED}→${NC} v${NEW_VERSION}"
    fi
    echo ""
fi

# ── Check / install Poetry ────────────────────────────────────────────────────
if ! command -v poetry &> /dev/null; then
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}[!] curl is required to install Poetry.${NC}"
        exit 1
    fi
    run_spinner "Installing Poetry" \
        bash -c 'curl -sSL https://install.python-poetry.org | python3 - > /dev/null 2>&1'
    export PATH="$HOME/.local/bin:$PATH"
fi

# ── Uninstall previous ────────────────────────────────────────────────────────
# Collect installed script names BEFORE uninstalling so we can force-remove
# leftover files that might have wrong permissions (e.g. from a prior sudo pip).
_STALE_SCRIPTS=$(pip show -f airecon 2>/dev/null \
    | grep -E '^\s+\.\.' | grep '/bin/' \
    | sed 's|.*/bin/||; s/\r//' || true)

run_spinner "Removing previous installation" bash -c "
    pip uninstall -y airecon > /dev/null 2>&1 || true
    rm -rf dist/ build/ *.egg-info 2>/dev/null || true
    # Force-remove any leftover scripts that may block reinstall (permission issues)
    echo '${_STALE_SCRIPTS}' | while IFS= read -r _s; do
        [ -n \"\$_s\" ] && rm -f \"\$HOME/.local/bin/\$_s\" 2>/dev/null || true
    done
"

# ── Build wheel ───────────────────────────────────────────────────────────────
run_spinner "Building package" \
    bash -c 'POETRY_VIRTUALENVS_CREATE=false poetry build > /dev/null 2>&1' \
    || { echo -e "${RED}[!] Build failed.${NC}"; exit 1; }

# ── Install wheel ─────────────────────────────────────────────────────────────
WHEEL_FILE=$(find dist -name "airecon-*.whl" | head -n 1)
if [ -z "$WHEEL_FILE" ]; then
    echo -e "${RED}[!] No wheel file found in dist/.${NC}"
    exit 1
fi

run_spinner "Installing airecon" \
    "$PYTHON_CMD" -m pip install "$WHEEL_FILE" \
        --user --no-cache-dir --force-reinstall \
        --break-system-packages --quiet \
    || { echo -e "${RED}[!] pip install failed.${NC}"; exit 1; }

# ── Install Playwright browser engine ─────────────────────────────────────────
run_spinner "Installing browser engine (Chromium)" \
    "$PYTHON_CMD" -m playwright install chromium \
    || true   # non-fatal — browser features optional

echo ""

# ── Print banner ──────────────────────────────────────────────────────────────
INSTALLED_VERSION=$($PYTHON_CMD -c "
try:
    from airecon._version import __version__
    print(__version__)
except Exception:
    print('${NEW_VERSION}')
" 2>/dev/null || echo "$NEW_VERSION")

echo -e "     █████████   █████ ███████████"
echo -e "    ███▒▒▒▒▒███ ▒▒███ ▒▒███▒▒▒▒▒███"
echo -e "   ▒███    ▒███  ▒███  ▒███    ▒███   ██████   ██████   ██████  ████████"
echo -e "   ▒███████████  ▒███  ▒██████████   ███▒▒███ ███▒▒███ ███▒▒███▒▒███▒▒███"
echo -e "   ▒███▒▒▒▒▒███  ▒███  ▒███▒▒▒▒▒███ ▒███████ ▒███ ▒▒▒ ▒███ ▒███ ▒███ ▒███"
echo -e "   ▒███    ▒███  ▒███  ▒███    ▒███ ▒███▒▒▒  ▒███  ███▒███ ▒███ ▒███ ▒███"
echo -e "   █████   █████ █████ █████   █████▒▒██████ ▒▒██████ ▒▒██████  ████ █████"
echo -e "   ▒▒▒▒▒   ▒▒▒▒▒ ▒▒▒▒▒ ▒▒▒▒▒   ▒▒▒▒▒  ▒▒▒▒▒▒   ▒▒▒▒▒▒   ▒▒▒▒▒▒  ▒▒▒▒ ▒▒▒▒▒"
echo -e ""
echo -e "${MUTED}            v${INSTALLED_VERSION} — AI-Powered Security Reconnaissance${NC}"
echo -e ""
echo -e "  ${MUTED}Quick start:${NC}    ${CYAN}airecon start${NC}"
echo -e "  ${MUTED}All options:${NC}    ${CYAN}airecon -h${NC}"
echo -e "  ${MUTED}Documentation:${NC}  ${CYAN}https://pikpikcu.github.io/airecon/${NC}"
echo -e ""

# ── Verify PATH ───────────────────────────────────────────────────────────────
if command -v airecon &> /dev/null; then
    echo -e "  ${GREEN}✓${NC}  ${MUTED}airecon is in your PATH${NC}"
else
    echo -e "  ${YELLOW}!${NC}  ${MUTED}Add to your shell profile:${NC}"
    echo -e "     ${BOLD}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
fi
echo ""
