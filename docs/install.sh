#!/bin/sh
set -eu

REPO="dasimmet/ssh-copy-id"
PAGES_URL="${SSH_COPY_ID_PAGES_URL:-https://dasimmet.github.io/ssh-copy-id}"
VERSION="${SSH_COPY_ID_VERSION:-latest}"
INSTALL_DIR="${SSH_COPY_ID_INSTALL_DIR:-}"
SCOPE="${SSH_COPY_ID_SCOPE:-auto}"
LIBC="${SSH_COPY_ID_LIBC:-musl}"
NO_MODIFY_PATH="${SSH_COPY_ID_NO_MODIFY_PATH:-0}"

usage() {
    cat <<EOF
ssh-copy-id installer for Linux, macOS, and BSD

Usage:
  curl -fsSL https://dasimmet.github.io/ssh-copy-id/install.sh | sh
  sh install.sh [OPTIONS]

Options:
  --version <tag>   Release tag, 'latest' (default; falls back to main build), or 'main'
  --dir <path>      Override installation directory
  --user            Install for current user only (~/.local/bin, no admin needed)
  --system          Install system-wide (/usr/local/bin, uses sudo/doas if needed)
  --libc <type>     Linux libc variant: musl (default, static) or gnu
  --no-path         Do not edit shell profile files to add install dir to PATH
  -h, --help        Show this help message

Environment overrides:
  SSH_COPY_ID_VERSION, SSH_COPY_ID_INSTALL_DIR, SSH_COPY_ID_SCOPE,
  SSH_COPY_ID_LIBC, SSH_COPY_ID_NO_MODIFY_PATH, SSH_COPY_ID_PAGES_URL
EOF
}

log() {
    printf '%s\n' "$*"
}

err() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || err "--version requires an argument"
            VERSION="$2"
            shift 2
            ;;
        --dir)
            [ "$#" -ge 2 ] || err "--dir requires an argument"
            INSTALL_DIR="$2"
            shift 2
            ;;
        --user)
            SCOPE="user"
            shift
            ;;
        --system)
            SCOPE="system"
            shift
            ;;
        --libc)
            [ "$#" -ge 2 ] || err "--libc requires an argument"
            LIBC="$2"
            shift 2
            ;;
        --no-path)
            NO_MODIFY_PATH="1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            err "unknown option: $1 (try --help)"
            ;;
    esac
done

detect_os() {
    os_raw=$(uname -s)
    case "$os_raw" in
        Linux) echo "linux" ;;
        Darwin) echo "macos" ;;
        FreeBSD) echo "freebsd" ;;
        OpenBSD) echo "openbsd" ;;
        NetBSD) echo "netbsd" ;;
        *) err "unsupported operating system: $os_raw" ;;
    esac
}

detect_arch() {
    os="$1"
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64)
            if [ "$os" = "macos" ] && command -v sysctl >/dev/null 2>&1; then
                if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
                    echo "aarch64"
                    return
                fi
            fi
            echo "x86_64"
            ;;
        aarch64|arm64) echo "aarch64" ;;
        i386|i486|i586|i686|x86) echo "x86" ;;
        armv7l|armv7*|armhf) echo "arm" ;;
        riscv64) echo "riscv64" ;;
        loongarch64) echo "loongarch64" ;;
        *) err "unsupported CPU architecture: $arch_raw" ;;
    esac
}

resolve_target() {
    os="$1"
    arch="$2"
    case "$os" in
        linux)
            case "$arch" in
                x86_64|aarch64|riscv64|loongarch64)
                    case "$LIBC" in
                        musl|gnu) echo "${arch}-linux-${LIBC}" ;;
                        *) err "unsupported libc '$LIBC' (expected musl or gnu)" ;;
                    esac
                    ;;
                x86)
                    echo "x86-linux-musl"
                    ;;
                arm)
                    case "$LIBC" in
                        musl) echo "arm-linux-musleabihf" ;;
                        gnu) echo "arm-linux-gnueabihf" ;;
                        *) err "unsupported libc '$LIBC' (expected musl or gnu)" ;;
                    esac
                    ;;
                *) err "unsupported Linux architecture: $arch" ;;
            esac
            ;;
        macos|freebsd|openbsd|netbsd)
            case "$arch" in
                x86_64|aarch64) echo "${arch}-${os}" ;;
                *) err "unsupported ${os} architecture: $arch" ;;
            esac
            ;;
    esac
}

download_file() {
    url="$1"
    dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    elif command -v fetch >/dev/null 2>&1; then
        fetch -qo "$dest" "$url"
    elif command -v ftp >/dev/null 2>&1; then
        ftp -o "$dest" "$url"
    else
        err "no download tool found (install curl or wget)"
    fi
}

sha256_of() {
    file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v sha256 >/dev/null 2>&1; then
        sha256 -q "$file"
    elif command -v cksum >/dev/null 2>&1; then
        cksum -a sha256 -q "$file" 2>/dev/null || return 1
    else
        return 1
    fi
}

resolve_install_dir() {
    if [ -n "$INSTALL_DIR" ]; then
        printf '%s\n' "$INSTALL_DIR"
        return
    fi
    uid=$(id -u)
    case "$SCOPE" in
        system)
            printf '%s\n' "/usr/local/bin"
            ;;
        user)
            printf '%s\n' "${XDG_BIN_HOME:-$HOME/.local/bin}"
            ;;
        auto)
            if [ "$uid" = "0" ] || { [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; }; then
                printf '%s\n' "/usr/local/bin"
            else
                printf '%s\n' "${XDG_BIN_HOME:-$HOME/.local/bin}"
            fi
            ;;
        *)
            err "invalid scope '$SCOPE' (expected auto, user, or system)"
            ;;
    esac
}

run_privileged() {
    if [ "$(id -u)" = "0" ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas "$@"
    else
        err "directory requires elevated privileges and neither sudo nor doas is available; re-run with --user"
    fi
}

append_line_if_missing() {
    rc_file="$1"
    line="$2"
    rc_dir=$(dirname "$rc_file")
    mkdir -p "$rc_dir"
    if [ -f "$rc_file" ] && grep -Fq "$line" "$rc_file" 2>/dev/null; then
        return 0
    fi
    if [ -f "$rc_file" ] && [ -s "$rc_file" ] && [ -n "$(tail -c 1 "$rc_file" 2>/dev/null || true)" ]; then
        printf '\n' >> "$rc_file"
    fi
    printf '%s\n' "$line" >> "$rc_file"
    log "Updated PATH in $rc_file"
}

ensure_in_path() {
    dir="$1"
    case ":$PATH:" in
        *":$dir:"*)
            return 0
            ;;
    esac
    if [ "$NO_MODIFY_PATH" = "1" ]; then
        log "Note: '$dir' is not in PATH. Add it manually:"
        log "  export PATH=\"$dir:\$PATH\""
        return 0
    fi

    display_dir="$dir"
    case "$dir" in
        "$HOME"/*)
            display_dir="\$HOME/${dir#"$HOME"/}"
            ;;
    esac
    posix_line="export PATH=\"$display_dir:\$PATH\""

    updated=0
    shell_name=$(basename "${SHELL:-sh}")
    case "$shell_name" in
        zsh)
            append_line_if_missing "$HOME/.zshrc" "$posix_line"
            updated=1
            ;;
        bash)
            if [ -f "$HOME/.bashrc" ]; then
                append_line_if_missing "$HOME/.bashrc" "$posix_line"
            elif [ -f "$HOME/.bash_profile" ]; then
                append_line_if_missing "$HOME/.bash_profile" "$posix_line"
            else
                append_line_if_missing "$HOME/.bashrc" "$posix_line"
                append_line_if_missing "$HOME/.profile" "$posix_line"
            fi
            updated=1
            ;;
        fish)
            append_line_if_missing "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" "fish_add_path -g \"$dir\""
            updated=1
            ;;
    esac

    if [ "$updated" = "0" ] || [ -f "$HOME/.profile" ]; then
        append_line_if_missing "$HOME/.profile" "$posix_line"
    fi

    log ""
    log "To use ssh-copy-id in this terminal right away, run:"
    if [ "$shell_name" = "fish" ]; then
        log "  fish_add_path -g \"$dir\""
    else
        log "  $posix_line"
    fi
}

OS=$(detect_os)
ARCH=$(detect_arch "$OS")
TARGET=$(resolve_target "$OS" "$ARCH")
DEST_DIR=$(resolve_install_dir)

ARCHIVE="ssh-copy-id-${TARGET}.tar.gz"
RELEASE_BASE="https://github.com/${REPO}/releases/latest/download"
MAIN_BASE="${PAGES_URL%/}/builds/main"

TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t ssh-copy-id)
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

log "Detected platform: ${OS}/${ARCH} (target: ${TARGET})"

ACTIVE_BASE=""
if [ "$VERSION" = "main" ]; then
    ACTIVE_BASE="$MAIN_BASE"
    log "Downloading ${ARCHIVE} (latest main build)..."
    download_file "${ACTIVE_BASE}/${ARCHIVE}" "${TMP_DIR}/${ARCHIVE}"
elif [ "$VERSION" = "latest" ]; then
    log "Downloading ${ARCHIVE} (latest release)..."
    if download_file "${RELEASE_BASE}/${ARCHIVE}" "${TMP_DIR}/${ARCHIVE}" 2>/dev/null; then
        ACTIVE_BASE="$RELEASE_BASE"
    else
        log "No GitHub Release found; falling back to latest main build..."
        ACTIVE_BASE="$MAIN_BASE"
        download_file "${ACTIVE_BASE}/${ARCHIVE}" "${TMP_DIR}/${ARCHIVE}"
    fi
else
    ACTIVE_BASE="https://github.com/${REPO}/releases/download/${VERSION}"
    log "Downloading ${ARCHIVE} (${VERSION})..."
    download_file "${ACTIVE_BASE}/${ARCHIVE}" "${TMP_DIR}/${ARCHIVE}"
fi

if download_file "${ACTIVE_BASE}/checksums.txt" "${TMP_DIR}/checksums.txt" 2>/dev/null; then
    expected=$(awk -v f="$ARCHIVE" '$2 == f || $2 == ("*" f) {print $1; exit}' "${TMP_DIR}/checksums.txt")
    if [ -n "$expected" ]; then
        if actual=$(sha256_of "${TMP_DIR}/${ARCHIVE}"); then
            if [ "$actual" != "$expected" ]; then
                err "SHA256 verification failed for ${ARCHIVE} (expected ${expected}, got ${actual})"
            fi
            log "Verified SHA256 checksum."
        else
            log "Warning: no sha256 tool found; skipping checksum verification."
        fi
    fi
fi

mkdir -p "${TMP_DIR}/extract"
tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "${TMP_DIR}/extract"

BIN_SRC=$(find "${TMP_DIR}/extract" -type f -name "ssh-copy-id" | head -n 1)
[ -n "$BIN_SRC" ] || err "ssh-copy-id binary not found in ${ARCHIVE}"
chmod 755 "$BIN_SRC"

DEST_BIN="${DEST_DIR}/ssh-copy-id"
if mkdir -p "$DEST_DIR" 2>/dev/null && [ -w "$DEST_DIR" ]; then
    cp "$BIN_SRC" "${DEST_BIN}.tmp.$$"
    chmod 755 "${DEST_BIN}.tmp.$$"
    mv -f "${DEST_BIN}.tmp.$$" "$DEST_BIN"
else
    run_privileged mkdir -p "$DEST_DIR"
    run_privileged cp "$BIN_SRC" "$DEST_BIN"
    run_privileged chmod 755 "$DEST_BIN"
fi

log "Installed ssh-copy-id to ${DEST_BIN}"
"${DEST_BIN}" --version || true
ensure_in_path "$DEST_DIR"
