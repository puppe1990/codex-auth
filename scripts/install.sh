#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Install codex-auth from GitHub Releases.

Usage:
  ./scripts/install.sh [--repo <owner/repo>] [--version <tag|latest>] [--install-dir <dir>]

Options:
  --repo <owner/repo>  GitHub repo (default: loongphy/codex-auth)
  --version <value>    Release tag or 'latest' (default: latest)
  --install-dir <dir>  Install directory (default: $HOME/.local/bin)
  -h, --help           Show help
EOF
}

INSTALL_DIR="${HOME}/.local/bin"
VERSION="latest"
REPO="loongphy/codex-auth"

detect_asset() {
  local os arch ext
  os="$(uname -s)"
  arch="$(uname -m)"

  case "${os}" in
    Linux) os="Linux"; ext="tar.gz" ;;
    Darwin) os="macOS"; ext="tar.gz" ;;
    *)
      echo "Unsupported OS: ${os}" >&2
      exit 1
      ;;
  esac

  case "${arch}" in
    x86_64|amd64) arch="X64" ;;
    arm64|aarch64) arch="ARM64" ;;
    *)
      echo "Unsupported architecture: ${arch}" >&2
      exit 1
      ;;
  esac

  echo "codex-auth-${os}-${arch}.${ext}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

ASSET="$(detect_asset)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

URL=""
if [[ "${VERSION}" == "latest" ]]; then
  URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
else
  URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
fi

echo "Downloading ${URL}"
curl -fL "${URL}" -o "${TMP_DIR}/${ASSET}"

BIN_PATH=""
case "${ASSET}" in
  *.tar.gz)
    tar -xzf "${TMP_DIR}/${ASSET}" -C "${TMP_DIR}"
    BIN_PATH="${TMP_DIR}/codex-auth"
    ;;
  *.zip)
    if command -v unzip >/dev/null 2>&1; then
      unzip -q "${TMP_DIR}/${ASSET}" -d "${TMP_DIR}"
      BIN_PATH="${TMP_DIR}/codex-auth"
    else
      echo "unzip is required to extract ${ASSET}" >&2
      exit 1
    fi
    ;;
esac

if [[ -z "${BIN_PATH}" || ! -f "${BIN_PATH}" ]]; then
  echo "Downloaded archive does not contain codex-auth binary." >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}"
DEST_BIN="${INSTALL_DIR}/codex-auth"

if command -v install >/dev/null 2>&1; then
  install -m 0755 "${BIN_PATH}" "${DEST_BIN}"
else
  cp "${BIN_PATH}" "${DEST_BIN}"
  chmod 0755 "${DEST_BIN}"
fi

echo "Installed: ${DEST_BIN}"
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  echo "Note: ${INSTALL_DIR} is not in PATH."
  echo "Add this to your shell profile:"
  echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
fi
