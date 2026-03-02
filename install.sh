#!/bin/bash
#
# CLIO-helper Installer
# 
# This script installs CLIO-helper and its dependencies on Linux systems.
# Supports: Arch Linux, SteamOS/SteamFork, Debian/Ubuntu
#
# Usage:
#   ./install.sh                    # Interactive install
#   ./install.sh --uninstall        # Remove installation
#   ./install.sh --status           # Check status
#   ./install.sh --no-service       # Install without systemd service
#   ./install.sh --no-clio          # Skip CLIO installation
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="$HOME/CLIO-helper"
LOCAL_BIN="$HOME/.local/bin"
LOCAL_LIB="$HOME/.local/lib/perl5"
CLIO_DIR="$HOME/.clio"
CLIO_INSTALL_DIR="$HOME/.local/clio"
CONFIG_FILE="$CLIO_DIR/discuss-config.json"
SERVICE_FILE="$HOME/.config/systemd/user/clio-helper.service"
GH_VERSION="2.87.0"

# Flags
INSTALL_SERVICE=true
INSTALL_CLIO=true
INTERACTIVE=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --uninstall)
            ACTION="uninstall"
            shift
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --no-service)
            INSTALL_SERVICE=false
            shift
            ;;
        --no-clio)
            INSTALL_CLIO=false
            shift
            ;;
        --non-interactive|-y)
            INTERACTIVE=false
            shift
            ;;
        --help|-h)
            echo "CLIO-helper Installer"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --uninstall       Remove CLIO-helper installation"
            echo "  --status          Check installation status"
            echo "  --no-service      Install without systemd service"
            echo "  --no-clio         Skip CLIO installation (if already installed)"
            echo "  --non-interactive Skip prompts (use defaults)"
            echo "  -y                Same as --non-interactive"
            echo "  --help, -h        Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

ACTION="${ACTION:-install}"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

prompt_yn() {
    local prompt="$1"
    local default="${2:-y}"
    
    if [[ "$INTERACTIVE" == "false" ]]; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi
    
    local yn
    if [[ "$default" == "y" ]]; then
        read -p "$prompt [Y/n]: " yn
        yn="${yn:-y}"
    else
        read -p "$prompt [y/N]: " yn
        yn="${yn:-n}"
    fi
    
    [[ "$yn" =~ ^[Yy] ]] && return 0 || return 1
}

check_command() {
    command -v "$1" &>/dev/null
}

# Check system requirements
check_requirements() {
    log_info "Checking system requirements..."
    
    local missing=()
    
    # Check Perl
    if ! check_command perl; then
        missing+=("perl")
    else
        local perl_version=$(perl -e 'print $^V')
        log_success "Perl $perl_version found"
    fi
    
    # Check curl
    if ! check_command curl; then
        missing+=("curl")
    fi
    
    # Check tar
    if ! check_command tar; then
        missing+=("tar")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_error "Please install these before continuing"
        exit 1
    fi
    
    log_success "All base requirements met"
}

# Install cpanm
install_cpanm() {
    if check_command cpanm || [[ -x "$LOCAL_BIN/cpanm" ]]; then
        log_success "cpanm already installed"
        return 0
    fi
    
    log_info "Installing cpanm..."
    mkdir -p "$LOCAL_BIN"
    curl -sL https://cpanmin.us/ -o "$LOCAL_BIN/cpanm"
    chmod +x "$LOCAL_BIN/cpanm"
    log_success "cpanm installed to $LOCAL_BIN/cpanm"
}

# Install Perl dependencies
install_perl_deps() {
    log_info "Checking Perl dependencies..."
    
    local cpanm="$LOCAL_BIN/cpanm"
    [[ ! -x "$cpanm" ]] && cpanm="cpanm"
    
    # Check if DBI and DBD::SQLite are installed
    local need_install=false
    
    export PERL5LIB="$LOCAL_LIB:$PERL5LIB"
    
    if ! perl -MDBI -e '1' 2>/dev/null; then
        need_install=true
    fi
    
    if ! perl -MDBD::SQLite -e '1' 2>/dev/null; then
        need_install=true
    fi
    
    if [[ "$need_install" == "true" ]]; then
        log_info "Installing DBI and DBD::SQLite..."
        mkdir -p "$LOCAL_LIB"
        $cpanm -l "$HOME/.local" DBI DBD::SQLite
        log_success "Perl dependencies installed"
    else
        log_success "Perl dependencies already installed"
    fi
}

# Install GitHub CLI
install_gh() {
    if check_command gh || [[ -x "$LOCAL_BIN/gh" ]]; then
        local gh_path=$(command -v gh || echo "$LOCAL_BIN/gh")
        local version=$($gh_path --version 2>/dev/null | head -1 | awk '{print $3}')
        log_success "GitHub CLI $version already installed"
        return 0
    fi
    
    log_info "Installing GitHub CLI v$GH_VERSION..."
    
    local arch=$(uname -m)
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac
    
    local url="https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_${os}_${arch}.tar.gz"
    local tmpdir=$(mktemp -d)
    
    cd "$tmpdir"
    curl -sL "$url" -o gh.tar.gz
    tar xzf gh.tar.gz
    mkdir -p "$LOCAL_BIN"
    cp "gh_${GH_VERSION}_${os}_${arch}/bin/gh" "$LOCAL_BIN/"
    chmod +x "$LOCAL_BIN/gh"
    cd -
    
    log_success "GitHub CLI installed to $LOCAL_BIN/gh"
}

# Install CLIO
install_clio() {
    if [[ "$INSTALL_CLIO" != "true" ]]; then
        log_info "Skipping CLIO installation (--no-clio)"
        return 0
    fi
    
    # Check if CLIO is already installed
    if check_command clio || [[ -x "$LOCAL_BIN/clio" ]] || [[ -x "$CLIO_INSTALL_DIR/clio" ]]; then
        local clio_path=$(command -v clio 2>/dev/null || echo "$LOCAL_BIN/clio")
        [[ ! -x "$clio_path" ]] && clio_path="$CLIO_INSTALL_DIR/clio"
        if [[ -x "$clio_path" ]]; then
            log_success "CLIO already installed at $clio_path"
            return 0
        fi
    fi
    
    log_info "Installing CLIO (AI assistant)..."
    
    # Get latest release
    local release_url="https://api.github.com/repos/SyntheticAutonomicMind/CLIO/releases/latest"
    local tarball_url=$(curl -sL "$release_url" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r.get('tarball_url',''))" 2>/dev/null)
    
    if [[ -z "$tarball_url" ]]; then
        log_warn "Could not get CLIO release URL, trying direct clone..."
        tarball_url="https://github.com/SyntheticAutonomicMind/CLIO/archive/refs/heads/main.tar.gz"
    fi
    
    local tmpdir=$(mktemp -d)
    
    cd "$tmpdir"
    log_info "Downloading CLIO..."
    curl -sL "$tarball_url" -o clio.tar.gz
    tar xzf clio.tar.gz
    
    # Find the extracted directory (name varies with release)
    local extracted_dir=$(ls -d */ | head -1)
    
    if [[ -z "$extracted_dir" ]]; then
        log_error "Failed to extract CLIO"
        cd -
        return 1
    fi
    
    # Install to user directory
    mkdir -p "$CLIO_INSTALL_DIR"
    cp -r "$extracted_dir"/* "$CLIO_INSTALL_DIR/"
    chmod +x "$CLIO_INSTALL_DIR/clio"
    
    # Create symlink
    mkdir -p "$LOCAL_BIN"
    ln -sf "$CLIO_INSTALL_DIR/clio" "$LOCAL_BIN/clio"
    
    cd - >/dev/null
    
    # Initialize CLIO config if needed
    mkdir -p "$CLIO_DIR"
    if [[ ! -f "$CLIO_DIR/config.json" ]]; then
        # Create minimal config
        cat > "$CLIO_DIR/config.json" << 'EOF'
{
    "model": "gpt-5-mini",
    "api_provider": "github_copilot"
}
EOF
    fi
    
    log_success "CLIO installed to $CLIO_INSTALL_DIR"
    log_success "Symlink created at $LOCAL_BIN/clio"
}

# Install CLIO-helper files
install_files() {
    log_info "Installing CLIO-helper..."
    
    # Determine source directory (where this script is located)
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    if [[ "$script_dir" != "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
        cp -r "$script_dir"/* "$INSTALL_DIR/"
        log_success "Files copied to $INSTALL_DIR"
    else
        log_success "Already in install directory"
    fi
    
    chmod +x "$INSTALL_DIR/clio-helper"
}

# Create wrapper script
create_wrapper() {
    log_info "Creating wrapper script..."
    
    # Get GitHub token from various sources
    local gh_token=""
    
    # Check existing config
    if [[ -f "$CONFIG_FILE" ]]; then
        gh_token=$(cat "$CONFIG_FILE" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('github_token',''))" 2>/dev/null || echo "")
    fi
    
    # Check CLIO github_tokens.json
    if [[ -z "$gh_token" && -f "$CLIO_DIR/github_tokens.json" ]]; then
        gh_token=$(cat "$CLIO_DIR/github_tokens.json" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('github_token',''))" 2>/dev/null || echo "")
    fi
    
    # Check environment
    if [[ -z "$gh_token" ]]; then
        gh_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    fi
    
    # Create wrapper
    cat > "$INSTALL_DIR/run-clio-helper" << EOF
#!/bin/bash
export PERL5LIB="$LOCAL_LIB:\$PERL5LIB"
export PATH="$LOCAL_BIN:\$PATH"
export GH_TOKEN="${gh_token}"
cd "$INSTALL_DIR"
exec ./clio-helper "\$@"
EOF
    chmod +x "$INSTALL_DIR/run-clio-helper"
    
    # Create symlink
    mkdir -p "$LOCAL_BIN"
    ln -sf "$INSTALL_DIR/run-clio-helper" "$LOCAL_BIN/clio-helper"
    
    log_success "Wrapper created at $LOCAL_BIN/clio-helper"
    
    if [[ -z "$gh_token" ]]; then
        log_warn "GitHub token not found. You'll need to configure it manually."
        log_warn "Edit $CONFIG_FILE and set 'github_token'"
    fi
}

# Create config file
create_config() {
    log_info "Setting up configuration..."
    
    mkdir -p "$CLIO_DIR"
    
    if [[ -f "$CONFIG_FILE" ]]; then
        log_success "Config file already exists at $CONFIG_FILE"
        return 0
    fi
    
    # Copy example config
    if [[ -f "$INSTALL_DIR/examples/config.example.json" ]]; then
        cp "$INSTALL_DIR/examples/config.example.json" "$CONFIG_FILE"
        log_success "Config created at $CONFIG_FILE"
        log_info "Edit $CONFIG_FILE to configure your repositories and GitHub token"
    else
        log_warn "Example config not found, creating minimal config"
        cat > "$CONFIG_FILE" << 'EOF'
{
    "repos": [
        {"owner": "YOUR_ORG", "repo": "YOUR_REPO"}
    ],
    "poll_interval_seconds": 120,
    "github_token": "",
    "model": "gpt-5-mini",
    "dry_run": true,
    "maintainers": [],
    "max_response_age_hours": 24,
    "response_cooldown_minutes": 30
}
EOF
        log_warn "Please edit $CONFIG_FILE with your settings"
    fi
}

# Install systemd service
install_service() {
    if [[ "$INSTALL_SERVICE" != "true" ]]; then
        log_info "Skipping systemd service installation (--no-service)"
        return 0
    fi
    
    # Check if systemd user services are available
    if ! check_command systemctl; then
        log_warn "systemctl not found, skipping service installation"
        return 0
    fi
    
    log_info "Installing systemd user service..."
    
    mkdir -p "$(dirname "$SERVICE_FILE")"
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=CLIO Helper - GitHub Discussion Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/run-clio-helper
Restart=always
RestartSec=30
Environment="HOME=$HOME"

# Logging
StandardOutput=append:$CLIO_DIR/discuss-daemon.log
StandardError=append:$CLIO_DIR/discuss-daemon.log

[Install]
WantedBy=default.target
EOF
    
    systemctl --user daemon-reload
    
    if prompt_yn "Enable and start the service now?"; then
        systemctl --user enable clio-helper.service
        systemctl --user start clio-helper.service
        
        # Enable linger for boot startup
        if check_command loginctl; then
            loginctl enable-linger "$USER" 2>/dev/null || true
        fi
        
        log_success "Service enabled and started"
    else
        log_info "Service installed but not started"
        log_info "To start: systemctl --user start clio-helper"
    fi
}

# Show status
show_status() {
    echo ""
    echo "=== CLIO-helper Status ==="
    echo ""
    
    # Check installation
    if [[ -d "$INSTALL_DIR" ]]; then
        log_success "Installation directory: $INSTALL_DIR"
    else
        log_error "Not installed: $INSTALL_DIR not found"
        return 1
    fi
    
    # Check wrapper
    if [[ -x "$LOCAL_BIN/clio-helper" ]]; then
        log_success "Wrapper: $LOCAL_BIN/clio-helper"
    else
        log_warn "Wrapper not found"
    fi
    
    # Check Perl deps
    export PERL5LIB="$LOCAL_LIB:$PERL5LIB"
    if perl -MDBI -MDBD::SQLite -e '1' 2>/dev/null; then
        log_success "Perl dependencies: DBI, DBD::SQLite"
    else
        log_warn "Missing Perl dependencies"
    fi
    
    # Check gh
    if [[ -x "$LOCAL_BIN/gh" ]] || check_command gh; then
        local gh_path=$(command -v gh 2>/dev/null || echo "$LOCAL_BIN/gh")
        local version=$($gh_path --version 2>/dev/null | head -1 | awk '{print $3}')
        log_success "GitHub CLI: v$version"
    else
        log_warn "GitHub CLI not found"
    fi
    
    # Check CLIO
    if [[ -x "$LOCAL_BIN/clio" ]] || [[ -x "$CLIO_INSTALL_DIR/clio" ]] || check_command clio; then
        local clio_path=$(command -v clio 2>/dev/null || echo "$LOCAL_BIN/clio")
        [[ ! -x "$clio_path" ]] && clio_path="$CLIO_INSTALL_DIR/clio"
        log_success "CLIO: $clio_path"
    else
        log_warn "CLIO not found (required for AI analysis)"
    fi
    
    # Check config
    if [[ -f "$CONFIG_FILE" ]]; then
        log_success "Config: $CONFIG_FILE"
        # Check token
        local token=$(cat "$CONFIG_FILE" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('github_token','')))" 2>/dev/null || echo "0")
        if [[ "$token" -gt 0 ]]; then
            log_success "GitHub token: configured ($token chars)"
        else
            log_warn "GitHub token: not configured"
        fi
    else
        log_warn "Config not found: $CONFIG_FILE"
    fi
    
    # Check service
    if [[ -f "$SERVICE_FILE" ]]; then
        local status=$(systemctl --user is-active clio-helper.service 2>/dev/null || echo "unknown")
        case "$status" in
            active)
                log_success "Service: running"
                ;;
            inactive)
                log_warn "Service: stopped"
                ;;
            *)
                log_warn "Service: $status"
                ;;
        esac
    else
        log_info "Service: not installed"
    fi
    
    # Show stats
    echo ""
    if [[ -x "$LOCAL_BIN/clio-helper" ]]; then
        "$LOCAL_BIN/clio-helper" --stats 2>/dev/null || true
    fi
    
    echo ""
}

# Uninstall
do_uninstall() {
    echo ""
    log_warn "This will remove CLIO-helper from this system."
    echo ""
    
    if ! prompt_yn "Continue with uninstall?" "n"; then
        log_info "Uninstall cancelled"
        return 0
    fi
    
    # Stop and disable service
    if [[ -f "$SERVICE_FILE" ]]; then
        log_info "Stopping service..."
        systemctl --user stop clio-helper.service 2>/dev/null || true
        systemctl --user disable clio-helper.service 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl --user daemon-reload 2>/dev/null || true
        log_success "Service removed"
    fi
    
    # Remove symlink
    if [[ -L "$LOCAL_BIN/clio-helper" ]]; then
        rm -f "$LOCAL_BIN/clio-helper"
        log_success "Symlink removed"
    fi
    
    # Remove installation directory
    if [[ -d "$INSTALL_DIR" ]]; then
        if prompt_yn "Remove $INSTALL_DIR?" "y"; then
            rm -rf "$INSTALL_DIR"
            log_success "Installation directory removed"
        fi
    fi
    
    # Keep config and state by default
    if [[ -f "$CONFIG_FILE" ]]; then
        if prompt_yn "Remove config and state files in $CLIO_DIR?" "n"; then
            rm -f "$CONFIG_FILE"
            rm -f "$CLIO_DIR/discuss-state.db"
            rm -f "$CLIO_DIR/discuss-daemon.log"
            log_success "Config and state removed"
        else
            log_info "Config preserved at $CONFIG_FILE"
        fi
    fi
    
    log_success "Uninstall complete"
}

# Main install
do_install() {
    echo ""
    echo "=== CLIO-helper Installer ==="
    echo ""
    
    check_requirements
    install_cpanm
    install_perl_deps
    install_gh
    install_clio
    install_files
    create_config
    create_wrapper
    install_service
    
    echo ""
    log_success "Installation complete!"
    echo ""
    echo "Usage:"
    echo "  clio-helper              # Start daemon (requires ~/.local/bin in PATH)"
    echo "  clio-helper --once       # Run single poll cycle"
    echo "  clio-helper --dry-run    # Analyze without posting"
    echo "  clio-helper --stats      # Show statistics"
    echo ""
    
    if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
        log_warn "Add this to your ~/.bashrc or ~/.profile:"
        echo "  export PATH=\"$LOCAL_BIN:\$PATH\""
        echo ""
    fi
    
    log_info "Edit $CONFIG_FILE to configure your repositories"
    echo ""
}

# Main
case "$ACTION" in
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    status)
        show_status
        ;;
esac
