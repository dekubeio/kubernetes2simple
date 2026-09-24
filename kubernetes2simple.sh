#!/usr/bin/env bash
# kubernetes2simple — turn the missile key.
#
# Detects your Kubernetes source format, installs missing tools,
# converts everything to docker compose. One script, one command.
#
# Prerequisites: docker compose, internet access.
# Everything else is bootstrapped into .kubernetes2simple/
#
# Usage:
#   curl -fsSL <release-url>/kubernetes2simple.sh | bash
#   # or
#   ./kubernetes2simple.sh [--clean] [--env <helmfile-env>] [--output-dir <dir>]
set -euo pipefail

K2S_DIR=".kubernetes2simple"
K2S_BIN="$K2S_DIR/bin"
K2S_VENV="$K2S_DIR/venv"
K2S_SCRIPT="$K2S_DIR/kubernetes2simple.py"
K2S_RENDER="$K2S_DIR/rendered"
K2S_REPO="dekubeio/kubernetes2simple"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    _green='\033[0;32m' _yellow='\033[0;33m' _red='\033[0;31m' _nc='\033[0m'
else
    _green='' _yellow='' _red='' _nc=''
fi

info() { printf "${_green}[k2s]${_nc} %s\n" "$1"; }
warn() { printf "${_yellow}[k2s]${_nc} %s\n" "$1"; }
fail() { printf "${_red}[k2s]${_nc} %s\n" "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
OUTPUT_DIR="."
HELMFILE_ENV=""
CLEAN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --env|-e)     HELMFILE_ENV="$2"; shift 2 ;;
        --clean)      CLEAN=true; shift ;;
        -h|--help)
            echo "Usage: kubernetes2simple.sh [--env <helmfile-env>] [--output-dir <dir>] [--clean]"
            echo ""
            echo "Detects your K8s source format and converts to docker compose."
            echo ""
            echo "Options:"
            echo "  --env, -e     Helmfile environment (helmfile mode only)"
            echo "  --output-dir  Output directory (default: current directory)"
            echo "  --clean       Remove .kubernetes2simple/ and start fresh"
            exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

if $CLEAN; then
    rm -rf "$K2S_DIR"
    info "Cleaned $K2S_DIR"
fi

mkdir -p "$K2S_DIR"

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
detect_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)        ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) fail "Unsupported architecture: $ARCH" ;;
    esac
    case "$OS" in
        linux|darwin) ;;
        *) fail "Unsupported OS: $OS" ;;
    esac
}

# ---------------------------------------------------------------------------
# GitHub helpers
# ---------------------------------------------------------------------------
github_latest_tag() {
    local repo="$1"
    curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])"
}

# ---------------------------------------------------------------------------
# curl
# ---------------------------------------------------------------------------
ensure_curl() {
    if ! command -v curl &>/dev/null; then
        fail "curl not found. Install curl and try again."
    fi
}

# ---------------------------------------------------------------------------
# Python 3.10+
# ---------------------------------------------------------------------------
ensure_python() {
    if ! command -v python3 &>/dev/null; then
        fail "Python 3 not found. Install Python 3.10+ and try again."
    fi
    local ver
    ver=$(python3 -c "import sys; v=sys.version_info; print(f'{v.major}.{v.minor}')")
    local major="${ver%%.*}" minor="${ver#*.}"
    if [[ "$major" -lt 3 || ("$major" -eq 3 && "$minor" -lt 10) ]]; then
        fail "Python 3.10+ required (found $ver)"
    fi
    info "Python $ver"
}

# ---------------------------------------------------------------------------
# Python deps (pyyaml + cryptography)
# ---------------------------------------------------------------------------
ensure_python_deps() {
    # Try system python first
    if python3 -c "import yaml; from cryptography import x509" 2>/dev/null; then
        PYTHON="python3"
        info "Python dependencies OK (system)"
        return
    fi

    # Try existing venv
    if [[ -x "$K2S_VENV/bin/python" ]]; then
        if "$K2S_VENV/bin/python" -c "import yaml; from cryptography import x509" 2>/dev/null; then
            PYTHON="$K2S_VENV/bin/python"
            info "Python dependencies OK (venv)"
            return
        fi
    fi

    # Create/update venv
    info "Installing Python dependencies..."
    if command -v uv &>/dev/null; then
        uv venv "$K2S_VENV" --quiet 2>/dev/null
        uv pip install --python "$K2S_VENV/bin/python" --quiet pyyaml cryptography
    else
        python3 -m venv "$K2S_VENV"
        "$K2S_VENV/bin/pip" install --quiet pyyaml cryptography
    fi
    PYTHON="$K2S_VENV/bin/python"
    info "Python dependencies installed"
}

# ---------------------------------------------------------------------------
# kubernetes2simple.py
# ---------------------------------------------------------------------------
# Cache is keyed on the release tag (not a TTL): cheap to check (same API
# call already used for helm/helmfile below), and it refreshes exactly when
# a new release ships instead of guessing a staleness window.
ensure_k2s_script() {
    local latest cached=""
    latest=$(github_latest_tag "$K2S_REPO")
    [[ -f "$K2S_DIR/.k2s_version" ]] && cached=$(cat "$K2S_DIR/.k2s_version")

    if [[ -f "$K2S_SCRIPT" && "$cached" == "$latest" ]]; then
        info "kubernetes2simple.py (cached, $latest)"
        return
    fi

    info "Downloading kubernetes2simple.py ($latest)..."
    local tmp
    tmp=$(mktemp "$K2S_SCRIPT.XXXXXX")
    if ! curl -fsSL -o "$tmp" \
        "https://github.com/$K2S_REPO/releases/download/$latest/kubernetes2simple.py"; then
        rm -f "$tmp"
        fail "Failed to download kubernetes2simple.py"
    fi
    mv "$tmp" "$K2S_SCRIPT"
    echo "$latest" > "$K2S_DIR/.k2s_version"
    info "Downloaded kubernetes2simple.py ($latest)"
}

# ---------------------------------------------------------------------------
# Helm
# ---------------------------------------------------------------------------
ensure_helm() {
    if command -v helm &>/dev/null; then
        HELM="helm"
        info "helm $(helm version --short 2>/dev/null || echo '(found)')"
        return
    fi
    if [[ -x "$K2S_BIN/helm" ]]; then
        HELM="$K2S_BIN/helm"
        info "helm (local install)"
        return
    fi

    info "Installing helm..."
    local tag
    tag=$(github_latest_tag helm/helm)
    local url="https://get.helm.sh/helm-${tag}-${OS}-${ARCH}.tar.gz"
    mkdir -p "$K2S_BIN"
    curl -fsSL "$url" | tar xz -C "$K2S_BIN" --strip-components=1 "${OS}-${ARCH}/helm"
    chmod +x "$K2S_BIN/helm"
    HELM="$K2S_BIN/helm"
    info "Installed helm $tag"
}

# ---------------------------------------------------------------------------
# Helmfile
# ---------------------------------------------------------------------------
ensure_helmfile() {
    if command -v helmfile &>/dev/null; then
        HELMFILE="helmfile"
        info "helmfile (found)"
        return
    fi
    if [[ -x "$K2S_BIN/helmfile" ]]; then
        HELMFILE="$K2S_BIN/helmfile"
        info "helmfile (local install)"
        return
    fi

    info "Installing helmfile..."
    local tag
    tag=$(github_latest_tag helmfile/helmfile)
    local url="https://github.com/helmfile/helmfile/releases/download/${tag}/helmfile_${tag#v}_${OS}_${ARCH}.tar.gz"
    mkdir -p "$K2S_BIN"
    curl -fsSL "$url" | tar xz -C "$K2S_BIN" helmfile
    chmod +x "$K2S_BIN/helmfile"
    HELMFILE="$K2S_BIN/helmfile"
    info "Installed helmfile $tag"
}

# ---------------------------------------------------------------------------
# Source detection
# ---------------------------------------------------------------------------
detect_source() {
    # Helmfile project
    if [[ -f helmfile.yaml || -f helmfile.yml ]]; then
        echo "helmfile"
        return
    fi

    # Helm chart
    if [[ -f Chart.yaml ]]; then
        echo "chart"
        return
    fi

    # Flat K8s manifests (any YAML with a top-level 'kind:' field)
    local f
    for f in *.yaml *.yml; do
        [[ -f "$f" ]] || continue
        if grep -q '^kind:' "$f" 2>/dev/null; then
            echo "manifests"
            return
        fi
    done

    echo "unknown"
}

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
render_helmfile() {
    local helmfile_path="helmfile.yaml"
    [[ -f "$helmfile_path" ]] || helmfile_path="helmfile.yml"

    rm -rf "$K2S_RENDER"
    mkdir -p "$K2S_RENDER"

    local env_flag=()
    if [[ -n "$HELMFILE_ENV" ]]; then
        env_flag=(-e "$HELMFILE_ENV")
    elif [[ ! -f "$K2S_DIR/.ignoreNoHelmfileEnvironment" ]]; then
        warn "No --env specified. Helmfile projects often require an environment."
        warn "If this fails, re-run with: ./k2s.sh --env <environment>"
        printf "${_yellow}[k2s]${_nc} Press Enter to continue without an environment, or Ctrl+C to abort... "
        if [[ -t 0 ]]; then
            read -r
        elif { : < /dev/tty; } 2>/dev/null; then
            # curl | bash: stdin is the script pipe, ask the terminal instead
            read -r < /dev/tty
        else
            echo ""
            warn "No terminal to prompt on — continuing without an environment."
        fi
    fi

    info "Rendering helmfile..."
    "$HELMFILE" -f "$helmfile_path" "${env_flag[@]}" template --output-dir "$K2S_RENDER" >/dev/null 2>&1

    # Helmfile succeeded without --env — don't warn next time
    if [[ -z "$HELMFILE_ENV" ]]; then
        touch "$K2S_DIR/.ignoreNoHelmfileEnvironment"
    fi
}

render_chart() {
    rm -rf "$K2S_RENDER"
    mkdir -p "$K2S_RENDER"

    # Build dependencies if Chart.lock or charts/ requirements exist
    if [[ -f Chart.lock || -f requirements.yaml ]]; then
        info "Building chart dependencies..."
        "$HELM" dependency build . >/dev/null 2>&1
    fi

    local values_flags=()
    # Pick up values files in conventional order
    for vf in values.yaml values.yml; do
        [[ -f "$vf" ]] && values_flags+=(-f "$vf")
    done

    info "Rendering chart..."
    "$HELM" template release . "${values_flags[@]}" --output-dir "$K2S_RENDER" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Convert
# ---------------------------------------------------------------------------
convert() {
    local from_dir="$1"
    info "Converting to docker compose..."
    "$PYTHON" "$K2S_SCRIPT" --from-dir "$from_dir" --output-dir "$OUTPUT_DIR"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    detect_platform

    local mode
    mode=$(detect_source)

    case "$mode" in
        helmfile)  info "Detected: helmfile project" ;;
        chart)     info "Detected: Helm chart" ;;
        manifests) info "Detected: Kubernetes manifests" ;;
        unknown)
            fail "No Kubernetes source found in current directory.

  kubernetes2simple needs one of:
    - helmfile.yaml (helmfile project)
    - Chart.yaml (Helm chart)
    - *.yaml with K8s manifests (raw manifests)

  Please open an issue: https://github.com/$K2S_REPO/issues"
            ;;
    esac

    echo ""
    info "--- Bootstrap ---"
    ensure_curl
    ensure_python
    ensure_python_deps
    ensure_k2s_script

    case "$mode" in
        helmfile)
            ensure_helm
            ensure_helmfile
            ;;
        chart)
            ensure_helm
            ;;
    esac

    echo ""
    info "--- Convert ---"
    case "$mode" in
        helmfile)
            render_helmfile
            convert "$K2S_RENDER"
            ;;
        chart)
            render_chart
            convert "$K2S_RENDER"
            ;;
        manifests)
            convert "."
            ;;
    esac

    echo ""
    info "Done! Run: docker compose up -d"
}

main "$@"
