#!/usr/bin/env bash
# Copyright (C) 2026 Kynox - All Rights Reserved.
# SPDX-License-Identifier: GPL-3.0-only
#
# Provisions a self-contained QEMU + OVMF environment for the Kynox validation
# suites, without root and without touching the system directories.
#
# The script is deliberately boring: it looks for an existing installation,
# then for a local copy under .tools/qemu, and only then tries to download a
# prebuilt pair into .tools/qemu. Everything it writes stays under .tools/
# (git-ignored). It never edits the user's shell profile.
#
# Usage:
#   scripts/provision-qemu.sh            # provision if needed, print exports
#   scripts/provision-qemu.sh --check    # report what is missing, change nothing
#
# Exit codes:
#   0  environment ready (already present or provisioned)
#   1  environment unavailable; the reason is printed
#   2  usage error

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${KYNOX_TOOLS_DIR:-$ROOT/.tools}"
QEMU_DIR="$TOOLS/qemu"
OVMF_DIR="$TOOLS/ovmf"
CHECK_ONLY="false"

for argument in "$@"; do
    case "$argument" in
        --check) CHECK_ONLY="true" ;;
        --help|-h)
            sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "provision-qemu: unknown argument: $argument" >&2; exit 2 ;;
    esac
done

note() { echo "provision-qemu: $*"; }
fail() { echo "provision-qemu: $*" >&2; }

# --- 1. an installation that is already usable ------------------------------

find_ovmf() {
    local code vars
    if [[ -n "${OVMF_CODE:-}" && -n "${OVMF_VARS:-}" && -f "${OVMF_CODE}" && -f "${OVMF_VARS}" ]]; then
        echo "${OVMF_CODE}:${OVMF_VARS}"
        return 0
    fi
    for pair in \
        "$OVMF_DIR/OVMF_CODE.fd:$OVMF_DIR/OVMF_VARS.fd" \
        /usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_CODE_4M.fd:/usr/share/edk2/ovmf/OVMF_VARS_4M.fd \
        /usr/share/edk2/x64/OVMF_CODE.fd:/usr/share/edk2/x64/OVMF_VARS.fd \
        /usr/share/edk2-ovmf/OVMF_CODE.fd:/usr/share/edk2-ovmf/OVMF_VARS.fd \
        /usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/qemu/OVMF_CODE.fd:/usr/share/qemu/OVMF_VARS.fd
    do
        code="${pair%%:*}"
        vars="${pair#*:}"
        if [[ -f "$code" && -f "$vars" ]]; then
            echo "$pair"
            return 0
        fi
    done
    return 1
}

find_qemu() {
    if command -v qemu-system-x86_64 >/dev/null 2>&1; then
        command -v qemu-system-x86_64
        return 0
    fi
    if [[ -x "$QEMU_DIR/bin/qemu-system-x86_64" ]]; then
        echo "$QEMU_DIR/bin/qemu-system-x86_64"
        return 0
    fi
    return 1
}

report_state() {
    local qemu ovmf
    qemu="$(find_qemu)" || qemu=""
    ovmf="$(find_ovmf)" || ovmf=""

    note "qemu-system-x86_64: ${qemu:-MISSING}"
    note "OVMF pair:           ${ovmf:-MISSING}"
    if [[ -n "$qemu" && -n "$ovmf" ]]; then
        note "environment ready"
        echo
        echo "export QEMU_BIN=\"$qemu\""
        echo "export OVMF_CODE=\"${ovmf%%:*}\""
        echo "export OVMF_VARS=\"${ovmf#*:}\""
        return 0
    fi
    return 1
}

if report_state; then
    exit 0
fi
[[ "$CHECK_ONLY" == "true" ]] && exit 1

mkdir -p "$TOOLS" "$QEMU_DIR" "$OVMF_DIR"

# --- 2. a prebuilt pair from GitHub releases -------------------------------
#
# rust-osdev/ovmf-prebuilt and ziglang/qemu-static publish ready-to-run
# binaries. The asset URL is resolved through the API so a failed download
# reports the exact HTTP/TLS condition instead of a generic error.

download() {
    local url="$1" destination="$2"
    note "downloading $url"
    if ! curl --fail --location --silent --show-error --max-time 300 \
            --output "$destination" "$url"; then
        fail "download failed: $url"
        return 1
    fi
    note "wrote $(wc -c <"$destination") bytes to $destination"
}

provision_ovmf() {
    local tag="edk2-stable202605-r1" asset="edk2-stable202605-r1-bin.tar.xz"
    local archive="$TOOLS/$asset"
    download "https://github.com/rust-osdev/ovmf-prebuilt/releases/download/$tag/$asset" "$archive" || return 1
    tar -xJf "$archive" -C "$TOOLS" || { fail "cannot extract $archive"; return 1; }
    # The archive contains a directory per target; copy the x64 pair.
    local found_code found_vars
    found_code="$(find "$TOOLS" -name 'OVMF_CODE*.fd' -type f | head -1)"
    found_vars="$(find "$TOOLS" -name 'OVMF_VARS*.fd' -type f | head -1)"
    if [[ -z "$found_code" || -z "$found_vars" ]]; then
        fail "the archive does not contain a CODE/VARS pair"
        return 1
    fi
    cp "$found_code" "$OVMF_DIR/OVMF_CODE.fd"
    cp "$found_vars" "$OVMF_DIR/OVMF_VARS.fd"
    note "OVMF installed under $OVMF_DIR"
}

provision_qemu() {
    local tag="10.1.2.2" asset="qemu-linux-x86_64-10.1.2.2.tar.xz"
    local archive="$TOOLS/$asset"
    download "https://github.com/ziglang/qemu-static/releases/download/$tag/$asset" "$archive" || return 1
    tar -xJf "$archive" -C "$QEMU_DIR" || { fail "cannot extract $archive"; return 1; }
    if [[ ! -x "$QEMU_DIR/bin/qemu-system-x86_64" ]]; then
        # Some archives unpack with the tree directly at the root.
        local found
        found="$(find "$QEMU_DIR" -name qemu-system-x86_64 -type f | head -1)"
        [[ -n "$found" ]] || { fail "the archive does not contain qemu-system-x86_64"; return 1; }
        mkdir -p "$QEMU_DIR/bin"
        cp "$found" "$QEMU_DIR/bin/qemu-system-x86_64"
    fi
    chmod +x "$QEMU_DIR/bin/qemu-system-x86_64" 2>/dev/null || true
    note "QEMU installed under $QEMU_DIR/bin"
}

provision_ovmf || true
provision_qemu || true

echo
if report_state; then
    exit 0
fi
fail "no reproducible source for QEMU+OVMF is reachable from this environment"
fail "either install qemu-system-x86 + ovmf system-wide, or set QEMU_BIN/OVMF_CODE/OVMF_VARS"
exit 1
