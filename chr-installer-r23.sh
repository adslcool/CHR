#!/usr/bin/env bash
# Reinstall the current Linux system from an online or local MikroTik RouterOS CHR image.
# WARNING: the selected target disk is overwritten completely.

set -Eeuo pipefail
umask 077
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

SCRIPT_BUILD="2026.09.05-dual-mode-r23-dhcp-singapore-jaclaz-gpt-fat16"
BASH_MINIMUM_MAJOR=4
ONLINE_CHANNEL="long-term"
ONLINE_VERSION_ENDPOINT="https://download.mikrotik.com/routeros/NEWESTa7.long-term"
ONLINE_DOWNLOAD_ROOT="https://download.mikrotik.com/routeros"
DOWNLOAD_CACHE_DIR="/var/cache/chr-installer"
DOWNLOAD_MAX_ATTEMPTS=5
DOWNLOAD_RETRY_DELAY=3
SYS_CLASS_BLOCK_ROOT="/sys/class/block"

# User-provided RouterOS device-mode message. It is an M2 TLV blob whose
# decoded structure is: key 0x0001 -> { key 0x001c = true, key 0x000a = 0 }.
# Base64 is used because Bash variables cannot contain the embedded NUL bytes.
ROSMODE_BASE64="TTIBAAApC00yHAAAAQoAAAkA"
ROSMODE_SHA256="a661eb6e5da4767267f70487f77fb1f4b4f222fed57f0deb3cf01a3803df7f3d"

LANGUAGE="en"
INSTALL_MODE=""
HOST_ARCH=""
CHR_ARCH=""
DETECTED_BOOT_MODE=""
BOOT_MODE=""
BOOT_MODE_OVERRIDE="${BOOT_MODE_OVERRIDE:-}"
IMAGE_PATH=""
IMAGE_SIZE=0
SOURCE_IMAGE_PATH=""
LOCAL_UPLOAD_DIR="/tmp"
LOCAL_IMAGE_FILE=""
LOCAL_CONTAINER_PACKAGE=""
ONLINE_VERSION=""
CA_BUNDLE=""
HTTPS_CA_PROBE_ERROR=""
CONTAINER_PACKAGE_PATH=""
CONTAINER_PACKAGE_SHA256=""
WORK_DIR=""
IMAGE_DIR=""
MOUNT_DIR=""
LOOP_DEVICE=""
MOUNTED=0
BOOT_PARTITION=""
SYSTEM_PARTITION=""
BOOT_PARTITION_FILESYSTEM=""
SYSTEM_PARTITION_FILESYSTEM=""
BOOT_PARTITION_NUMBER=""
BOOT_PARTITION_START=""
BOOT_PARTITION_SIZE=""
SYSTEM_PARTITION_NUMBER=""
SYSTEM_PARTITION_START=""
SYSTEM_PARTITION_SIZE=""
IMAGE_PARTITION_LAYOUT=""
SOURCE_LOOP_DEVICE=""
SOURCE_MOUNT_DIR=""
SOURCE_MOUNTED=0
SOURCE_BOOT_PARTITION=""
SOURCE_BOOT_PARTITION_NUMBER=""
SOURCE_BOOT_PARTITION_START=""
SOURCE_BOOT_PARTITION_SIZE=""
SOURCE_PARTITION_LAYOUT=""

ETH=""
MAC=""
NETWORK_MODE="dhcp"
ADDRESS=""
GATEWAY=""
DNS=""
ROUTEROS_TIME_ZONE="Asia/Singapore"
ADMIN_PASSWORD=""
PASSWORD_WAS_GENERATED=0
TARGET_DISK=""
TARGET_DISK_SECTORS=0
INTERACTIVE_FD=0

BASE_REQUIRED_COMMANDS=(
    awk base64 bash blkid blockdev chmod chown cp dd df findmnt head ip lsblk
    losetup mkdir mkfs.fat mktemp mount od readlink rm rmdir sha256sum sleep
    sort swapoff sync tar tr umount uname wc
)
REQUIRED_COMMANDS=()
MISSING_COMMANDS=()

i18n() {
    if [[ "$LANGUAGE" == "zh" ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

say() {
    printf '%s\n' "$(i18n "$1" "$2")"
}

warn() {
    printf '%s %s\n' "$(i18n '警告：' 'Warning:')" "$(i18n "$1" "$2")" >&2
}

die() {
    printf '%s %s\n' "$(i18n '错误：' 'Error:')" "$(i18n "$1" "$2")" >&2
    exit 1
}

show_build_banner() {
    printf '\n%s %s\n' 'MikroTik CHR Installer build:' "$SCRIPT_BUILD"
    printf '%s\n\n' 'Online longTerm or local IMG installation（在线 longTerm 或本地 IMG 安装）'
}

setup_interactive_input() {
    if [[ -r /dev/tty && -w /dev/tty ]] && { exec 3<>/dev/tty; } 2>/dev/null; then
        INTERACTIVE_FD=3
    elif [[ -t 0 ]]; then
        INTERACTIVE_FD=0
    else
        die \
            '当前运行方式没有可用的交互终端；请先下载脚本，再使用 bash 脚本名运行。' \
            'No interactive terminal is available; download the script first, then run it with bash.'
    fi
}

cleanup() {
    local rc=$?
    set +e

    if (( MOUNTED == 1 )) && [[ -n "$MOUNT_DIR" ]]; then
        umount "$MOUNT_DIR" >/dev/null 2>&1
        MOUNTED=0
    fi
    if (( SOURCE_MOUNTED == 1 )) && [[ -n "$SOURCE_MOUNT_DIR" ]]; then
        umount "$SOURCE_MOUNT_DIR" >/dev/null 2>&1
        SOURCE_MOUNTED=0
    fi
    if [[ -n "$LOOP_DEVICE" ]]; then
        losetup -d "$LOOP_DEVICE" >/dev/null 2>&1
        LOOP_DEVICE=""
    fi
    if [[ -n "$SOURCE_LOOP_DEVICE" ]]; then
        losetup -d "$SOURCE_LOOP_DEVICE" >/dev/null 2>&1
        SOURCE_LOOP_DEVICE=""
    fi

    if [[ -n "$WORK_DIR" && "$WORK_DIR" == /tmp/chr-local.* ]]; then
        rm -f -- \
            "$WORK_DIR/container.npk" \
            "$WORK_DIR/chr-original.img" \
            "$WORK_DIR/boot-files.tar" >/dev/null 2>&1
        rmdir -- "$WORK_DIR" >/dev/null 2>&1
    fi
    if [[ -n "$IMAGE_DIR" && "$IMAGE_DIR" == /dev/shm/chr-local.* ]]; then
        rm -f -- "$IMAGE_DIR/chr.img" >/dev/null 2>&1
        rmdir -- "$IMAGE_DIR" >/dev/null 2>&1
    fi
    if [[ -n "$MOUNT_DIR" && "$MOUNT_DIR" == /tmp/chr-mount.* ]]; then
        rmdir -- "$MOUNT_DIR" >/dev/null 2>&1
    fi
    if [[ -n "$SOURCE_MOUNT_DIR" && "$SOURCE_MOUNT_DIR" == /tmp/chr-source-mount.* ]]; then
        rmdir -- "$SOURCE_MOUNT_DIR" >/dev/null 2>&1
    fi

    return "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT TERM HUP

select_language() {
    local choice
    while true; do
        printf '%s\n' 'Select your language / 请选择语言：'
        printf '%s\n' '1. English'
        printf '%s\n' '2. 简体中文'
        read -r -u "$INTERACTIVE_FD" -p 'Please choose / 请选择 [1]: ' choice
        choice=${choice:-1}
        case "$choice" in
            1) LANGUAGE="en"; break ;;
            2) LANGUAGE="zh"; break ;;
            *) printf '%s\n' 'Invalid option / 无效选项' >&2 ;;
        esac
    done
}

select_install_mode() {
    local choice

    while true; do
        printf '\n%s\n' "$(i18n '请选择安装方式：' 'Select installation mode:')"
        printf '%s\n' "$(i18n '1. 在线安装（RouterOS v7 longTerm，自动识别 x86/ARM64）' '1. Online installation (RouterOS v7 longTerm; detect x86/ARM64 automatically)')"
        printf '%s\n' "$(i18n '2. 本地安装（读取 /tmp/chr-*.img，可选 /tmp/container-*.npk）' '2. Local installation (use /tmp/chr-*.img; /tmp/container-*.npk is optional)')"
        read -r -u "$INTERACTIVE_FD" -p "$(i18n '请选择 [1]：' 'Please choose [1]: ')" choice
        choice=${choice:-1}
        case "$choice" in
            1) INSTALL_MODE="online"; break ;;
            2) INSTALL_MODE="local"; break ;;
            *) warn '无效选项。' 'Invalid option.' ;;
        esac
    done
}

set_required_commands() {
    local requested_boot_mode detected_boot_mode raw_arch

    REQUIRED_COMMANDS=("${BASE_REQUIRED_COMMANDS[@]}")
    if [[ "$INSTALL_MODE" == "online" ]]; then
        REQUIRED_COMMANDS+=(curl rsync unzip)
    fi

    raw_arch=$(uname -m)
    detected_boot_mode=$([[ -d /sys/firmware/efi ]] && printf 'UEFI' || printf 'BIOS')
    requested_boot_mode=${BOOT_MODE_OVERRIDE^^}
    [[ -n "$requested_boot_mode" ]] || requested_boot_mode=$detected_boot_mode
    if [[ "$raw_arch" == "x86_64" || "$raw_arch" == "amd64" ]]; then
        if [[ "$requested_boot_mode" == "UEFI" ]]; then
            REQUIRED_COMMANDS+=(gdisk sgdisk)
        fi
    fi
}

require_root() {
    (( EUID == 0 )) || die '请使用 root 用户运行此脚本。' 'Run this script as root.'
}

require_bash_version() {
    (( BASH_VERSINFO[0] >= BASH_MINIMUM_MAJOR )) || die \
        "需要 Bash ${BASH_MINIMUM_MAJOR}.0 或更高版本。" \
        "Bash ${BASH_MINIMUM_MAJOR}.0 or newer is required."
}

find_missing_commands() {
    local command_name

    MISSING_COMMANDS=()
    for command_name in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 || MISSING_COMMANDS+=("$command_name")
    done
}

install_missing_commands() {
    local package_manager=""
    local command_name apt_package existing found
    local apt_packages=()
    local online_packages=()
    local rpm_gpt_packages=()
    local other_gpt_packages=()

    if [[ "$INSTALL_MODE" == "online" ]]; then
        online_packages=(curl rsync unzip)
    fi
    if [[ " ${REQUIRED_COMMANDS[*]} " == *" gdisk "* ]]; then
        rpm_gpt_packages=(gdisk)
        other_gpt_packages=(gptfdisk)
    fi

    say '正在检查脚本所需命令……' 'Checking commands required by the script...'
    find_missing_commands
    if (( ${#MISSING_COMMANDS[@]} == 0 )); then
        say '所需命令均已安装。' 'All required commands are already installed.'
        return 0
    fi

    printf '%s %s\n' "$(i18n '缺少命令：' 'Missing commands:')" "${MISSING_COMMANDS[*]}"
    say \
        '正在使用系统软件包管理器安装缺少的工具；此步骤发生在获取镜像和操作磁盘之前。' \
        'Installing missing tools with the system package manager; this happens before obtaining an image or operating on a disk.'

    if command -v apt-get >/dev/null 2>&1; then
        package_manager="apt-get"
        for command_name in "${MISSING_COMMANDS[@]}"; do
            case "$command_name" in
                awk) apt_package="gawk" ;;
                bash) apt_package="bash" ;;
                blkid|blockdev|findmnt|losetup|lsblk|swapoff) apt_package="util-linux" ;;
                ip) apt_package="iproute2" ;;
                mkfs.fat) apt_package="dosfstools" ;;
                mount|umount) apt_package="mount" ;;
                tar) apt_package="tar" ;;
                curl) apt_package="curl" ;;
                gdisk|sgdisk) apt_package="gdisk" ;;
                rsync) apt_package="rsync" ;;
                unzip) apt_package="unzip" ;;
                *) apt_package="coreutils" ;;
            esac
            found=0
            for existing in "${apt_packages[@]}"; do
                if [[ "$existing" == "$apt_package" ]]; then
                    found=1
                    break
                fi
            done
            if (( found == 0 )); then
                apt_packages+=("$apt_package")
            fi
        done
        printf '%s %s\n' "$(i18n '准备安装软件包：' 'Packages to install:')" "${apt_packages[*]}"
        if ! apt-get -o Acquire::Retries=3 update; then
            warn \
                'apt-get 更新索引失败；可能是镜像站正在同步，将继续尝试使用现有索引安装缺少的软件包。' \
                'apt-get failed to refresh indexes; the mirror may be synchronizing, so installation will be attempted with the existing indexes.'
        fi
        DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install \
            -y --no-install-recommends --no-upgrade "${apt_packages[@]}" || die \
            'apt-get 安装依赖失败，尚未进行任何磁盘操作。' \
            'apt-get failed to install dependencies; no disk operation has been performed.'
    elif command -v dnf >/dev/null 2>&1; then
        package_manager="dnf"
        dnf install -y \
            bash coreutils util-linux gawk iproute dosfstools tar \
            "${online_packages[@]}" "${rpm_gpt_packages[@]}" || die \
            'dnf 安装依赖失败，尚未进行任何磁盘操作。' \
            'dnf failed to install dependencies; no disk operation has been performed.'
    elif command -v microdnf >/dev/null 2>&1; then
        package_manager="microdnf"
        microdnf install -y \
            bash coreutils util-linux gawk iproute dosfstools tar \
            "${online_packages[@]}" "${rpm_gpt_packages[@]}" || die \
            'microdnf 安装依赖失败，尚未进行任何磁盘操作。' \
            'microdnf failed to install dependencies; no disk operation has been performed.'
    elif command -v yum >/dev/null 2>&1; then
        package_manager="yum"
        yum install -y \
            bash coreutils util-linux gawk iproute dosfstools tar \
            "${online_packages[@]}" "${rpm_gpt_packages[@]}" || die \
            'yum 安装依赖失败，尚未进行任何磁盘操作。' \
            'yum failed to install dependencies; no disk operation has been performed.'
    elif command -v apk >/dev/null 2>&1; then
        package_manager="apk"
        apk add --no-cache \
            bash coreutils util-linux gawk iproute2 dosfstools tar \
            "${online_packages[@]}" "${other_gpt_packages[@]}" || die \
            'apk 安装依赖失败，尚未进行任何磁盘操作。' \
            'apk failed to install dependencies; no disk operation has been performed.'
    elif command -v pacman >/dev/null 2>&1; then
        package_manager="pacman"
        pacman -Sy --noconfirm --needed \
            bash coreutils util-linux gawk iproute2 dosfstools tar \
            "${online_packages[@]}" "${other_gpt_packages[@]}" || die \
            'pacman 安装依赖失败，尚未进行任何磁盘操作。' \
            'pacman failed to install dependencies; no disk operation has been performed.'
    elif command -v zypper >/dev/null 2>&1; then
        package_manager="zypper"
        zypper --non-interactive refresh || die \
            'zypper 更新软件源失败，尚未进行任何磁盘操作。' \
            'zypper failed to refresh repositories; no disk operation has been performed.'
        zypper --non-interactive install \
            bash coreutils util-linux gawk iproute2 dosfstools tar \
            "${online_packages[@]}" "${other_gpt_packages[@]}" || die \
            'zypper 安装依赖失败，尚未进行任何磁盘操作。' \
            'zypper failed to install dependencies; no disk operation has been performed.'
    else
        die \
            "缺少命令：${MISSING_COMMANDS[*]}；且未找到支持的软件包管理器（apt-get、dnf、microdnf、yum、apk、pacman 或 zypper）。" \
            "Missing commands: ${MISSING_COMMANDS[*]}; no supported package manager was found (apt-get, dnf, microdnf, yum, apk, pacman, or zypper)."
    fi

    hash -r
    find_missing_commands
    (( ${#MISSING_COMMANDS[@]} == 0 )) || die \
        "使用 $package_manager 安装后仍缺少命令：${MISSING_COMMANDS[*]}" \
        "Commands still missing after installation with $package_manager: ${MISSING_COMMANDS[*]}"
    printf '%s %s\n' "$(i18n '依赖安装完成，软件包管理器：' 'Dependencies installed with package manager:')" "$package_manager"
}

find_ca_bundle() {
    local candidate

    CA_BUNDLE=""
    for candidate in \
        /etc/ssl/certs/ca-certificates.crt \
        /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
        /etc/pki/tls/certs/ca-bundle.crt \
        /etc/ssl/ca-bundle.pem \
        /var/lib/ca-certificates/ca-bundle.pem \
        /etc/ssl/cert.pem; do
        if [[ -f "$candidate" && -r "$candidate" && -s "$candidate" ]]; then
            CA_BUNDLE=$candidate
            return 0
        fi
    done
    return 1
}

probe_online_https() {
    local rc

    [[ -n "$CA_BUNDLE" && -f "$CA_BUNDLE" && -r "$CA_BUNDLE" && -s "$CA_BUNDLE" ]] || return 77
    if HTTPS_CA_PROBE_ERROR=$(
        (
            unset CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR
            curl \
                --fail \
                --location \
                --silent \
                --show-error \
                --connect-timeout 20 \
                --max-time 60 \
                --proto '=https' \
                --proto-redir '=https' \
                --cacert "$CA_BUNDLE" \
                --output /dev/null \
                "$ONLINE_VERSION_ENDPOINT"
        ) 2>&1
    ); then
        HTTPS_CA_PROBE_ERROR=""
        return 0
    else
        rc=$?
        return "$rc"
    fi
}

repair_ca_certificates() {
    local package_manager=""

    say \
        '正在安装或重建系统 CA 证书包……' \
        'Installing or rebuilding the system CA certificate bundle...'

    if command -v apt-get >/dev/null 2>&1; then
        package_manager="apt-get"
        if ! DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install \
            -y --no-install-recommends --reinstall ca-certificates; then
            warn \
                '首次安装 ca-certificates 失败，将刷新软件包索引后重试。' \
                'The first ca-certificates installation attempt failed; refreshing package indexes before retrying.'
            if ! apt-get -o Acquire::Retries=3 update; then
                warn \
                    'apt-get 更新索引失败，将继续使用现有索引重试 ca-certificates。' \
                    'apt-get failed to refresh indexes; retrying ca-certificates with existing indexes.'
            fi
            DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install \
                -y --no-install-recommends --reinstall ca-certificates || die \
                'apt-get 无法安装或修复 ca-certificates，尚未进行任何磁盘操作。' \
                'apt-get could not install or repair ca-certificates; no disk operation has been performed.'
        fi
    elif command -v dnf >/dev/null 2>&1; then
        package_manager="dnf"
        dnf reinstall -y ca-certificates || dnf install -y ca-certificates || die \
            'dnf 无法安装或修复 ca-certificates。' \
            'dnf could not install or repair ca-certificates.'
    elif command -v microdnf >/dev/null 2>&1; then
        package_manager="microdnf"
        microdnf install -y ca-certificates || die \
            'microdnf 无法安装 ca-certificates。' \
            'microdnf could not install ca-certificates.'
    elif command -v yum >/dev/null 2>&1; then
        package_manager="yum"
        yum reinstall -y ca-certificates || yum install -y ca-certificates || die \
            'yum 无法安装或修复 ca-certificates。' \
            'yum could not install or repair ca-certificates.'
    elif command -v apk >/dev/null 2>&1; then
        package_manager="apk"
        apk fix ca-certificates || apk add --no-cache ca-certificates || die \
            'apk 无法安装或修复 ca-certificates。' \
            'apk could not install or repair ca-certificates.'
    elif command -v pacman >/dev/null 2>&1; then
        package_manager="pacman"
        pacman -Sy --noconfirm ca-certificates ca-certificates-utils || die \
            'pacman 无法安装或修复 CA 证书包。' \
            'pacman could not install or repair the CA certificate packages.'
    elif command -v zypper >/dev/null 2>&1; then
        package_manager="zypper"
        zypper --non-interactive install --force ca-certificates || die \
            'zypper 无法安装或修复 ca-certificates。' \
            'zypper could not install or repair ca-certificates.'
    else
        die \
            '未找到支持的软件包管理器，无法修复系统 CA 证书包。' \
            'No supported package manager was found to repair the system CA certificate bundle.'
    fi

    if command -v update-ca-certificates >/dev/null 2>&1; then
        update-ca-certificates || die \
            '重建系统 CA 证书包失败。' \
            'Failed to rebuild the system CA certificate bundle.'
    elif command -v update-ca-trust >/dev/null 2>&1; then
        update-ca-trust extract || die \
            '重建系统 CA 信任库失败。' \
            'Failed to rebuild the system CA trust store.'
    fi

    printf '%s %s\n' \
        "$(i18n 'CA 证书处理完成，软件包管理器：' 'CA certificate handling completed with package manager:')" \
        "$package_manager"
}

ensure_online_ca_certificates() {
    local probe_rc

    [[ "$INSTALL_MODE" == "online" ]] || return 0
    say '正在检查 HTTPS CA 证书……' 'Checking HTTPS CA certificates...'

    if find_ca_bundle; then
        if probe_online_https; then
            printf '%s %s\n' "$(i18n 'HTTPS CA 证书正常：' 'HTTPS CA certificate bundle is valid:')" "$CA_BUNDLE"
            return 0
        else
            probe_rc=$?
            case "$probe_rc" in
                60|77)
                    warn \
                        "系统 CA 证书不可用（curl $probe_rc），将自动修复。" \
                        "The system CA certificate bundle is unusable (curl $probe_rc); attempting automatic repair."
                    ;;
                *)
                    die \
                        "HTTPS 连通性检查失败（curl $probe_rc）：${HTTPS_CA_PROBE_ERROR:-unknown error}" \
                        "HTTPS connectivity check failed (curl $probe_rc): ${HTTPS_CA_PROBE_ERROR:-unknown error}"
                    ;;
            esac
        fi
    else
        warn \
            '未找到可读且非空的系统 CA 证书包，将自动安装。' \
            'No readable, non-empty system CA certificate bundle was found; attempting automatic installation.'
    fi

    repair_ca_certificates
    find_ca_bundle || die \
        '安装后仍未找到有效的系统 CA 证书文件。' \
        'No valid system CA certificate file was found after installation.'
    if probe_online_https; then
        :
    else
        probe_rc=$?
        die \
            "修复 CA 证书后 HTTPS 验证仍失败（curl $probe_rc）：${HTTPS_CA_PROBE_ERROR:-unknown error}" \
            "HTTPS verification still failed after repairing CA certificates (curl $probe_rc): ${HTTPS_CA_PROBE_ERROR:-unknown error}"
    fi
    printf '%s %s\n' "$(i18n 'HTTPS CA 证书已修复：' 'HTTPS CA certificate bundle repaired:')" "$CA_BUNDLE"
}

ask_value() {
    local prompt=$1
    local default_value=${2:-}
    local value

    while true; do
        if [[ -n "$default_value" ]]; then
            printf '%s [%s]: ' "$prompt" "$default_value"
        else
            printf '%s: ' "$prompt"
        fi
        IFS= read -r -u "$INTERACTIVE_FD" value
        value=${value:-$default_value}
        if [[ -n "$value" ]]; then
            REPLY=$value
            return 0
        fi
    done
}

valid_ipv4() {
    local value=$1
    local a b c d
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$value"
    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 ))
}

valid_ipv4_cidr() {
    local value=$1
    local ip_part prefix
    [[ "$value" == */* ]] || return 1
    ip_part=${value%/*}
    prefix=${value##*/}
    valid_ipv4 "$ip_part" || return 1
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
    (( 10#$prefix >= 0 && 10#$prefix <= 32 ))
}

valid_dns_list() {
    local value=$1
    local server
    local servers=()
    IFS=, read -r -a servers <<< "$value"
    (( ${#servers[@]} > 0 )) || return 1
    for server in "${servers[@]}"; do
        valid_ipv4 "$server" || return 1
    done
}

ipv4_to_int() {
    local value=$1
    local a b c d
    IFS=. read -r a b c d <<< "$value"
    printf '%u' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

gateway_is_on_link() {
    local cidr=$1
    local gateway=$2
    local ip_part=${cidr%/*}
    local prefix=${cidr##*/}
    local ip_num gateway_num mask

    ip_num=$(ipv4_to_int "$ip_part")
    gateway_num=$(ipv4_to_int "$gateway")
    if (( 10#$prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF ))
    fi
    (( (ip_num & mask) == (gateway_num & mask) ))
}

secure_boot_is_enabled() {
    local secure_boot_file value

    [[ "$BOOT_MODE" == "UEFI" && "$DETECTED_BOOT_MODE" == "UEFI" ]] || return 1
    for secure_boot_file in /sys/firmware/efi/efivars/SecureBoot-*; do
        [[ -r "$secure_boot_file" ]] || continue
        value=$(od -An -j4 -N1 -tu1 "$secure_boot_file" 2>/dev/null | tr -d '[:space:]') || continue
        [[ "$value" == "1" ]] && return 0
    done
    return 1
}

show_system_info() {
    local requested_boot_mode raw_arch

    raw_arch=$(uname -m)
    case "$raw_arch" in
        x86_64|amd64) HOST_ARCH="x86_64" ;;
        aarch64|arm64) HOST_ARCH="arm64" ;;
        *)
            die \
                "官方 CHR 镜像不支持当前架构：$raw_arch" \
                "Unsupported architecture for official CHR: $raw_arch" ;;
    esac
    DETECTED_BOOT_MODE=$([[ -d /sys/firmware/efi ]] && printf 'UEFI' || printf 'BIOS')
    requested_boot_mode=${BOOT_MODE_OVERRIDE^^}
    case "$requested_boot_mode" in
        "") BOOT_MODE="$DETECTED_BOOT_MODE" ;;
        BIOS|UEFI) BOOT_MODE="$requested_boot_mode" ;;
        *) die \
            "BOOT_MODE_OVERRIDE 只能是 BIOS 或 UEFI：$BOOT_MODE_OVERRIDE" \
            "BOOT_MODE_OVERRIDE must be BIOS or UEFI: $BOOT_MODE_OVERRIDE" ;;
    esac

    case "$HOST_ARCH" in
        x86_64) ;;
        arm64)
            [[ "$BOOT_MODE" == "UEFI" ]] || die \
                '官方 ARM64 CHR 镜像要求 UEFI 启动。' \
                'The official ARM64 CHR image requires UEFI boot.'
            ;;
    esac

    if secure_boot_is_enabled; then
        die \
            '检测到 Secure Boot 已开启；CHR EFI 启动文件可能被固件拒绝，请先关闭 Secure Boot。' \
            'Secure Boot is enabled; firmware may reject the CHR EFI loader. Disable Secure Boot first.'
    fi

    printf '%s %s\n' "$(i18n 'CPU 架构：' 'Architecture:')" "$HOST_ARCH"
    printf '%s %s\n' "$(i18n '启动方式：' 'Boot mode:')" "$BOOT_MODE"
    if [[ -n "$BOOT_MODE_OVERRIDE" ]]; then
        printf '%s %s\n' "$(i18n '自动检测：' 'Auto-detected:')" "$DETECTED_BOOT_MODE"
        warn \
            '已使用 BOOT_MODE_OVERRIDE；请确认它与目标虚拟机的固件模式一致。' \
            'BOOT_MODE_OVERRIDE is active; ensure it matches the target VM firmware mode.'
    fi
}

find_local_install_files() {
    local candidate image_name container_name container_arch expected_host_arch
    local image_candidates=()
    local container_candidates=()

    LOCAL_IMAGE_FILE=""
    LOCAL_CONTAINER_PACKAGE=""
    CONTAINER_PACKAGE_PATH=""
    CONTAINER_PACKAGE_SHA256=""
    CHR_ARCH=""

    for candidate in "$LOCAL_UPLOAD_DIR"/chr-*.img; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        image_candidates+=("$candidate")
    done
    if (( ${#image_candidates[@]} != 1 )); then
        warn \
            "$LOCAL_UPLOAD_DIR 中必须恰好有一个 chr-*.img，当前找到 ${#image_candidates[@]} 个。" \
            "$LOCAL_UPLOAD_DIR must contain exactly one chr-*.img; found ${#image_candidates[@]}."
        return 1
    fi

    LOCAL_IMAGE_FILE=${image_candidates[0]}
    if [[ ! -f "$LOCAL_IMAGE_FILE" || -L "$LOCAL_IMAGE_FILE" || \
          ! -r "$LOCAL_IMAGE_FILE" || ! -s "$LOCAL_IMAGE_FILE" ]]; then
        warn \
            "CHR 镜像不是可读、非空的普通文件，或是符号链接：$LOCAL_IMAGE_FILE" \
            "The CHR image is not a readable, non-empty regular file, or it is a symbolic link: $LOCAL_IMAGE_FILE"
        return 1
    fi
    printf '%s %s\n' "$(i18n '本地 CHR 文件：' 'Local CHR file:')" "$LOCAL_IMAGE_FILE"

    image_name=${LOCAL_IMAGE_FILE##*/}
    if [[ "${image_name,,}" == *arm* ]]; then
        CHR_ARCH="arm64"
        expected_host_arch="arm64"
    else
        CHR_ARCH="x86"
        expected_host_arch="x86_64"
    fi
    printf '%s %s\n' "$(i18n '本地镜像架构：' 'Local image architecture:')" "$CHR_ARCH"
    if [[ "$HOST_ARCH" != "$expected_host_arch" ]]; then
        warn \
            "本地镜像按文件名判定为 $CHR_ARCH，但当前 CPU 为 $HOST_ARCH。" \
            "The local image filename indicates $CHR_ARCH, but the current CPU is $HOST_ARCH."
        return 1
    fi

    for candidate in "$LOCAL_UPLOAD_DIR"/container-*.npk; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        container_candidates+=("$candidate")
    done
    if (( ${#container_candidates[@]} == 0 )); then
        say \
            '未发现 /tmp/container-*.npk，将跳过 Container 软件包预置。' \
            'No /tmp/container-*.npk was found; Container package staging will be skipped.'
        warn \
            '仅按 CHR 文件名是否包含 arm 判断架构，不识别版本；将检查镜像结构及复制一致性，但不联网验证官方真实性。' \
            'Architecture is inferred only from whether the CHR filename contains arm; no version is inferred. Image structure and copy integrity will be checked, but official authenticity is not verified online.'
        return 0
    fi
    if (( ${#container_candidates[@]} != 1 )); then
        warn \
            "$LOCAL_UPLOAD_DIR 中的 container-*.npk 必须至多一个，当前找到 ${#container_candidates[@]} 个。" \
            "$LOCAL_UPLOAD_DIR may contain at most one container-*.npk; found ${#container_candidates[@]}."
        return 1
    fi

    LOCAL_CONTAINER_PACKAGE=${container_candidates[0]}
    if [[ ! -f "$LOCAL_CONTAINER_PACKAGE" || -L "$LOCAL_CONTAINER_PACKAGE" || \
          ! -r "$LOCAL_CONTAINER_PACKAGE" || ! -s "$LOCAL_CONTAINER_PACKAGE" ]]; then
        warn \
            "Container 文件不是可读、非空的普通文件，或是符号链接：$LOCAL_CONTAINER_PACKAGE" \
            "The Container file is not a readable, non-empty regular file, or it is a symbolic link: $LOCAL_CONTAINER_PACKAGE"
        return 1
    fi
    printf '%s %s\n' "$(i18n '本地 Container 软件包：' 'Local Container package:')" "$LOCAL_CONTAINER_PACKAGE"

    container_name=${LOCAL_CONTAINER_PACKAGE##*/}
    if [[ "${container_name,,}" == *arm* ]]; then
        container_arch="arm64"
    else
        container_arch="x86"
    fi
    printf '%s %s\n' "$(i18n '本地 Container 架构：' 'Local Container architecture:')" "$container_arch"
    if [[ "$container_arch" != "$CHR_ARCH" ]]; then
        warn \
            "CHR 镜像按文件名判定为 $CHR_ARCH，但 Container 软件包判定为 $container_arch。" \
            "The CHR image filename indicates $CHR_ARCH, but the Container package filename indicates $container_arch."
        return 1
    fi
    warn \
        '仅按 CHR 与 Container 文件名是否包含 arm 判断架构，不识别 IMG 或 NPK 版本；只检查镜像结构及文件复制一致性，不联网验证官方真实性。' \
        'Architecture is inferred only from whether the CHR and Container filenames contain arm; no IMG or NPK version is inferred. Only image structure and file copy integrity are checked, without online authenticity verification.'
}

prepare_work_directories() {
    [[ -d /dev/shm && -w /dev/shm ]] || die \
        '必须存在可写的 /dev/shm；镜像需要放在内存文件系统中，避免覆盖系统盘时破坏源镜像。' \
        'A writable /dev/shm is required so the source image remains in memory while the system disk is overwritten.'
    [[ $(findmnt -n -o FSTYPE -T /dev/shm 2>/dev/null | awk 'NR == 1 {print; exit}') == "tmpfs" ]] || die \
        '/dev/shm 必须是 tmpfs 内存文件系统。' \
        '/dev/shm must be a tmpfs memory filesystem.'

    WORK_DIR=$(mktemp -d /tmp/chr-local.XXXXXX)
    IMAGE_DIR=$(mktemp -d /dev/shm/chr-local.XXXXXX)
    MOUNT_DIR=$(mktemp -d /tmp/chr-mount.XXXXXX)
    IMAGE_PATH="$IMAGE_DIR/chr.img"
    if [[ "$INSTALL_MODE" == "online" && "$HOST_ARCH" == "x86_64" && "$BOOT_MODE" == "UEFI" ]]; then
        SOURCE_IMAGE_PATH="$WORK_DIR/chr-original.img"
        SOURCE_MOUNT_DIR=$(mktemp -d /tmp/chr-source-mount.XXXXXX)
    fi
}

download_https() {
    [[ -n "$CA_BUNDLE" && -f "$CA_BUNDLE" && -r "$CA_BUNDLE" && -s "$CA_BUNDLE" ]] || die \
        'HTTPS CA 证书包尚未准备好。' \
        'The HTTPS CA certificate bundle is not ready.'
    (
        unset CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR
        curl \
            --fail \
            --location \
            --silent \
            --show-error \
            --retry 3 \
            --retry-delay 2 \
            --connect-timeout 20 \
            --max-time 900 \
            --proto '=https' \
            --proto-redir '=https' \
            --cacert "$CA_BUNDLE" \
            "$@"
    )
}

prepare_download_cache() {
    local cache_parent=${DOWNLOAD_CACHE_DIR%/*}

    [[ -d "$cache_parent" && ! -L "$cache_parent" && -w "$cache_parent" ]] || die \
        "下载缓存父目录不可用：$cache_parent" \
        "The download-cache parent directory is unavailable: $cache_parent"
    if [[ -e "$DOWNLOAD_CACHE_DIR" || -L "$DOWNLOAD_CACHE_DIR" ]]; then
        [[ -d "$DOWNLOAD_CACHE_DIR" && ! -L "$DOWNLOAD_CACHE_DIR" ]] || die \
            "下载缓存路径不是普通目录，或是符号链接：$DOWNLOAD_CACHE_DIR" \
            "The download-cache path is not a regular directory, or is a symbolic link: $DOWNLOAD_CACHE_DIR"
    else
        mkdir --mode=700 -- "$DOWNLOAD_CACHE_DIR" || die \
            "无法创建下载缓存目录：$DOWNLOAD_CACHE_DIR" \
            "Could not create the download-cache directory: $DOWNLOAD_CACHE_DIR"
    fi
    chown 0:0 -- "$DOWNLOAD_CACHE_DIR" || die \
        '无法将下载缓存目录设为 root 所有。' \
        'Could not set root ownership on the download-cache directory.'
    chmod 700 -- "$DOWNLOAD_CACHE_DIR" || die \
        '无法保护下载缓存目录权限。' \
        'Could not secure the download-cache directory permissions.'
    printf '%s %s\n' "$(i18n '断点续传缓存：' 'Resume cache:')" "$DOWNLOAD_CACHE_DIR"
}

download_https_file() {
    local url=$1
    local destination=$2
    local resume_bytes=0 current_bytes=0 curl_rc=0 attempt=1
    local curl_args=(
        --fail
        --location
        --show-error
        --progress-bar
        --connect-timeout 20
        --max-time 900
        --proto '=https'
        --proto-redir '=https'
        --cacert "$CA_BUNDLE"
        --output "$destination"
    )

    [[ -n "$CA_BUNDLE" && -f "$CA_BUNDLE" && -r "$CA_BUNDLE" && -s "$CA_BUNDLE" ]] || die \
        'HTTPS CA 证书包尚未准备好。' \
        'The HTTPS CA certificate bundle is not ready.'

    while (( attempt <= DOWNLOAD_MAX_ATTEMPTS )); do
        resume_bytes=0
        if [[ -e "$destination" || -L "$destination" ]]; then
            [[ -f "$destination" && ! -L "$destination" ]] || die \
                "下载目标不是普通文件，或是符号链接：$destination" \
                "The download target is not a regular file, or is a symbolic link: $destination"
            resume_bytes=$(wc -c < "$destination")
        fi

        if (( resume_bytes > 0 )); then
            if (( attempt == 1 )); then
                printf '%s %s bytes\n' \
                    "$(i18n '检测到未完成文件，尝试从现有大小续传：' 'Partial file found; resuming from its current size:')" \
                    "$resume_bytes"
            fi
            if (
                unset CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR
                curl "${curl_args[@]}" --continue-at - "$url"
            ); then
                return 0
            else
                curl_rc=$?
            fi
        else
            if (
                unset CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR
                curl "${curl_args[@]}" "$url"
            ); then
                return 0
            else
                curl_rc=$?
            fi
        fi

        if (( resume_bytes > 0 && (curl_rc == 33 || curl_rc == 36) )); then
            warn \
                "下载服务器拒绝当前断点（curl $curl_rc），下一次将从头下载。" \
                "The server rejected the current resume offset (curl $curl_rc); the next attempt will start from the beginning."
            rm -f -- "$destination"
        elif (( curl_rc == 3 || curl_rc == 23 || curl_rc == 26 || curl_rc == 27 || \
                curl_rc == 60 || curl_rc == 63 || curl_rc == 77 || curl_rc == 90 || \
                curl_rc == 91 )); then
            return "$curl_rc"
        fi

        if (( attempt >= DOWNLOAD_MAX_ATTEMPTS )); then
            warn \
                "下载在 $DOWNLOAD_MAX_ATTEMPTS 次尝试后仍失败（curl $curl_rc）；已下载内容保留，可再次运行脚本继续。" \
                "The download still failed after $DOWNLOAD_MAX_ATTEMPTS attempts (curl $curl_rc); downloaded data was retained for a later rerun."
            return "$curl_rc"
        fi

        current_bytes=0
        if [[ -f "$destination" && ! -L "$destination" ]]; then
            current_bytes=$(wc -c < "$destination")
        fi
        if (( current_bytes > 0 )); then
            warn \
                "下载中断（curl $curl_rc，第 $attempt/$DOWNLOAD_MAX_ATTEMPTS 次）；$DOWNLOAD_RETRY_DELAY 秒后从 $current_bytes bytes 自动续传。" \
                "Download interrupted (curl $curl_rc, attempt $attempt/$DOWNLOAD_MAX_ATTEMPTS); resuming from $current_bytes bytes in $DOWNLOAD_RETRY_DELAY seconds."
        else
            warn \
                "下载失败（curl $curl_rc，第 $attempt/$DOWNLOAD_MAX_ATTEMPTS 次）；$DOWNLOAD_RETRY_DELAY 秒后自动重试。" \
                "Download failed (curl $curl_rc, attempt $attempt/$DOWNLOAD_MAX_ATTEMPTS); retrying in $DOWNLOAD_RETRY_DELAY seconds."
        fi
        sleep "$DOWNLOAD_RETRY_DELAY"
        attempt=$((attempt + 1))
    done
}

download_verified_zip() {
    local url=$1
    local destination=$2
    local description_zh=$3
    local description_en=$4
    local checksum_text expected_sha actual_sha

    printf '%s %s\n' "$(i18n '正在下载：' 'Downloading:')" "$(i18n "$description_zh" "$description_en")"
    checksum_text=$(download_https "${url}.sha256") || die \
        "无法下载 $description_zh 的官方 SHA-256。" \
        "Could not download the official SHA-256 for $description_en."
    expected_sha=$(awk 'NR == 1 {print tolower($1); exit}' <<< "$checksum_text")
    [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die \
        "$description_zh 的官方 SHA-256 格式无效。" \
        "The official SHA-256 for $description_en has an invalid format."

    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -f "$destination" && ! -L "$destination" ]] || die \
            "缓存目标不是普通文件，或是符号链接：$destination" \
            "The cached target is not a regular file, or is a symbolic link: $destination"
        if [[ -s "$destination" ]]; then
            actual_sha=$(sha256sum "$destination" | awk '{print $1}')
            if [[ "$actual_sha" == "$expected_sha" ]]; then
                say \
                    "$description_zh 已存在于缓存并通过官方 SHA-256 校验，无需重新下载。" \
                    "$description_en is already cached and passed verification against the official SHA-256; no download is needed."
                return 0
            fi
            say \
                "$description_zh 缓存尚未完成或校验不一致，将尝试断点续传。" \
                "$description_en is incomplete or does not match its checksum; attempting to resume."
        else
            rm -f -- "$destination"
        fi
    fi

    download_https_file "$url" "$destination" || die \
        "下载 $description_zh 失败。" \
        "Failed to download $description_en."
    [[ -f "$destination" && ! -L "$destination" && -s "$destination" ]] || die \
        "下载的 $description_zh 不是有效普通文件。" \
        "The downloaded $description_en is not a valid regular file."

    actual_sha=$(sha256sum "$destination" | awk '{print $1}')
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        warn \
            "$description_zh 续传后的 SHA-256 不一致，将删除错误缓存并完整重下。" \
            "The resumed $description_en failed SHA-256 verification; the bad cache will be removed and downloaded again in full."
        rm -f -- "$destination"
        download_https_file "$url" "$destination" || die \
            "重新下载 $description_zh 失败。" \
            "Failed to download $description_en again."
        [[ -f "$destination" && ! -L "$destination" && -s "$destination" ]] || die \
            "重新下载的 $description_zh 不是有效普通文件。" \
            "The newly downloaded $description_en is not a valid regular file."
        actual_sha=$(sha256sum "$destination" | awk '{print $1}')
        [[ "$actual_sha" == "$expected_sha" ]] || die \
            "$description_zh 完整重下后仍未通过官方 SHA-256 校验。" \
            "$description_en still failed verification against the official SHA-256 after a full download."
    fi
    say \
        "$description_zh 已通过官方 SHA-256 校验。" \
        "$description_en passed verification against the official SHA-256."
}

load_online_release() {
    local version_response download_base image_zip packages_zip
    local package_arch display_arch expected_image_entry expected_container_entry zip_listing
    local uncompressed_bytes available_kib required_kib extracted_bytes
    local source_available_kib source_required_kib source_sha copied_sha copied_bytes
    local image_entries=()
    local container_entries=()

    case "$HOST_ARCH" in
        x86_64)
            CHR_ARCH="x86"
            package_arch="x86"
            display_arch="x86_64"
            ;;
        arm64)
            CHR_ARCH="arm64"
            package_arch="arm64"
            display_arch="ARM64"
            ;;
        *)
            die \
                "在线安装不支持当前 CPU 架构：$HOST_ARCH" \
                "Online installation does not support this CPU architecture: $HOST_ARCH" ;;
    esac

    say \
        '正在查询 RouterOS v7 longTerm 最新版本……' \
        'Checking the latest RouterOS v7 longTerm release...'
    version_response=$(download_https "$ONLINE_VERSION_ENDPOINT") || die \
        '无法查询 RouterOS v7 longTerm 最新版本。' \
        'Could not query the latest RouterOS v7 longTerm release.'
    ONLINE_VERSION=$(awk 'NR == 1 {gsub(/\r/, "", $1); print $1; exit}' <<< "$version_response")
    [[ "$ONLINE_VERSION" =~ ^7\.[0-9]+(\.[0-9]+)*$ ]] || die \
        "longTerm 版本响应无效：${ONLINE_VERSION:-empty}" \
        "Invalid longTerm version response: ${ONLINE_VERSION:-empty}"

    printf '%s %s (%s)\n' \
        "$(i18n '在线版本：' 'Online version:')" "$ONLINE_VERSION" "$ONLINE_CHANNEL"
    printf '%s %s\n' "$(i18n '在线镜像架构：' 'Online image architecture:')" "$display_arch"
    download_base="$ONLINE_DOWNLOAD_ROOT/$ONLINE_VERSION"
    if [[ "$CHR_ARCH" == "arm64" ]]; then
        expected_image_entry="chr-$ONLINE_VERSION-arm64.img"
        expected_container_entry="container-$ONLINE_VERSION-arm64.npk"
    else
        expected_image_entry="chr-$ONLINE_VERSION.img"
        expected_container_entry="container-$ONLINE_VERSION.npk"
    fi
    prepare_download_cache
    image_zip="$DOWNLOAD_CACHE_DIR/$expected_image_entry.zip"
    packages_zip="$DOWNLOAD_CACHE_DIR/all_packages-$package_arch-$ONLINE_VERSION.zip"

    download_verified_zip \
        "$download_base/$expected_image_entry.zip" \
        "$image_zip" \
        "$display_arch CHR RAW 镜像 ZIP" \
        "$display_arch CHR RAW image ZIP"
    download_verified_zip \
        "$download_base/all_packages-$package_arch-$ONLINE_VERSION.zip" \
        "$packages_zip" \
        "$display_arch Extra packages ZIP" \
        "$display_arch Extra packages ZIP"

    zip_listing=$(unzip -Z1 "$image_zip") || die \
        '无法读取 CHR ZIP 文件列表。' 'Could not read the CHR ZIP file list.'
    mapfile -t image_entries < <(
        awk -v expected="$expected_image_entry" '$0 == expected {print}' <<< "$zip_listing"
    )
    (( ${#image_entries[@]} == 1 )) || die \
        "CHR ZIP 中必须恰好包含 $expected_image_entry。" \
        "The CHR ZIP must contain exactly one $expected_image_entry."

    uncompressed_bytes=$(unzip -l "$image_zip" "$expected_image_entry" | \
        awk -v expected="$expected_image_entry" '$NF == expected {print $1; exit}')
    [[ "$uncompressed_bytes" =~ ^[0-9]+$ && "$uncompressed_bytes" -gt 0 ]] || die \
        '无法读取 CHR IMG 解压后大小。' \
        'Could not determine the uncompressed CHR IMG size.'
    available_kib=$(df -Pk /dev/shm | awk 'NR == 2 {print $4}')
    required_kib=$(( (uncompressed_bytes + 1023) / 1024 + 8192 ))
    (( available_kib >= required_kib )) || die \
        "内存文件系统空间不足，需要至少 ${required_kib} KiB，当前可用 ${available_kib} KiB。" \
        "Not enough tmpfs space: ${required_kib} KiB required, ${available_kib} KiB available."

    if [[ -n "$SOURCE_IMAGE_PATH" ]]; then
        source_available_kib=$(df -Pk "$WORK_DIR" | awk 'NR == 2 {print $4}')
        source_required_kib=$(( (uncompressed_bytes + 1023) / 1024 + 8192 ))
        (( source_available_kib >= source_required_kib )) || die \
            "临时文件系统空间不足，保存官方原始 IMG 至少需要 ${source_required_kib} KiB，当前可用 ${source_available_kib} KiB。" \
            "Not enough temporary-disk space to retain the official source IMG: ${source_required_kib} KiB required, ${source_available_kib} KiB available."
        say \
            '正在保留官方原始 CHR IMG，并复制出在线 UEFI 工作镜像……' \
            'Retaining the official source CHR IMG and creating the online UEFI working image...'
        unzip -p "$image_zip" "$expected_image_entry" > "$SOURCE_IMAGE_PATH" || die \
            '解压官方原始 CHR IMG 失败。' 'Failed to extract the official source CHR IMG.'
        [[ -f "$SOURCE_IMAGE_PATH" && ! -L "$SOURCE_IMAGE_PATH" && -s "$SOURCE_IMAGE_PATH" ]] || die \
            '解压后的官方原始 CHR IMG 无效。' 'The extracted official source CHR IMG is invalid.'
        extracted_bytes=$(wc -c < "$SOURCE_IMAGE_PATH")
        (( extracted_bytes == uncompressed_bytes )) || die \
            '官方原始 CHR IMG 解压后大小与 ZIP 目录记录不一致。' \
            'The extracted official source CHR IMG size does not match the ZIP directory record.'
        source_sha=$(sha256sum "$SOURCE_IMAGE_PATH" | awk '{print $1}')
        cp -- "$SOURCE_IMAGE_PATH" "$IMAGE_PATH" || die \
            '复制在线 UEFI 工作镜像失败。' 'Failed to copy the online UEFI working image.'
        copied_bytes=$(wc -c < "$IMAGE_PATH")
        copied_sha=$(sha256sum "$IMAGE_PATH" | awk '{print $1}')
        (( copied_bytes == extracted_bytes )) && [[ "$copied_sha" == "$source_sha" ]] || die \
            '在线 UEFI 工作镜像与官方原始 IMG 不一致。' \
            'The online UEFI working image does not match the official source IMG.'
        IMAGE_SIZE=$copied_bytes
    else
        say '正在将 CHR IMG 解压到内存……' 'Extracting the CHR IMG into memory...'
        unzip -p "$image_zip" "$expected_image_entry" > "$IMAGE_PATH" || die \
            '解压 CHR IMG 失败。' 'Failed to extract the CHR IMG.'
        [[ -f "$IMAGE_PATH" && ! -L "$IMAGE_PATH" && -s "$IMAGE_PATH" ]] || die \
            '解压后的 CHR IMG 无效。' 'The extracted CHR IMG is invalid.'
        extracted_bytes=$(wc -c < "$IMAGE_PATH")
        (( extracted_bytes == uncompressed_bytes )) || die \
            'CHR IMG 解压后大小与 ZIP 目录记录不一致。' \
            'The extracted CHR IMG size does not match the ZIP directory record.'
        IMAGE_SIZE=$extracted_bytes
    fi

    zip_listing=$(unzip -Z1 "$packages_zip") || die \
        '无法读取 Extra packages ZIP 文件列表。' \
        'Could not read the Extra packages ZIP file list.'
    mapfile -t container_entries < <(
        awk -v expected="$expected_container_entry" '$0 == expected {print}' <<< "$zip_listing"
    )
    (( ${#container_entries[@]} == 1 )) || die \
        "Extra packages ZIP 中必须恰好包含 $expected_container_entry。" \
        "The Extra packages ZIP must contain exactly one $expected_container_entry."

    CONTAINER_PACKAGE_PATH="$WORK_DIR/container.npk"
    unzip -p "$packages_zip" "$expected_container_entry" > "$CONTAINER_PACKAGE_PATH" || die \
        '从 Extra packages ZIP 解压 Container NPK 失败。' \
        'Failed to extract the Container NPK from the Extra packages ZIP.'
    [[ -f "$CONTAINER_PACKAGE_PATH" && ! -L "$CONTAINER_PACKAGE_PATH" && \
       -s "$CONTAINER_PACKAGE_PATH" ]] || die \
        '解压后的 Container NPK 无效。' 'The extracted Container NPK is invalid.'
    CONTAINER_PACKAGE_SHA256=$(sha256sum "$CONTAINER_PACKAGE_PATH" | awk '{print $1}')
    [[ "$CONTAINER_PACKAGE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die \
        '无法计算在线 Container NPK 的 SHA-256。' \
        'Could not calculate the SHA-256 of the online Container NPK.'

    say \
        '在线 CHR IMG 和 Container NPK 已解压并准备写入镜像；已验证 ZIP 保留在断点续传缓存中。' \
        'The online CHR IMG and Container NPK were extracted and are ready for image customization; verified ZIP files remain in the resume cache.'
}

load_local_image() {
    local source_bytes copied_bytes available_kib required_kib
    local source_sha copied_sha

    [[ -f "$LOCAL_IMAGE_FILE" && ! -L "$LOCAL_IMAGE_FILE" && \
       -r "$LOCAL_IMAGE_FILE" && -s "$LOCAL_IMAGE_FILE" ]] || die \
        '本地 CHR IMG 不存在、不可读、为空或是符号链接。' \
        'The local CHR IMG is missing, unreadable, empty, or a symbolic link.'

    source_bytes=$(wc -c < "$LOCAL_IMAGE_FILE")
    [[ "$source_bytes" =~ ^[0-9]+$ && "$source_bytes" -gt 0 ]] || die \
        '本地 CHR IMG 大小无效。' 'The local CHR IMG has an invalid size.'
    available_kib=$(df -Pk /dev/shm | awk 'NR == 2 {print $4}')
    required_kib=$(( (source_bytes + 1023) / 1024 + 8192 ))
    (( available_kib >= required_kib )) || die \
        "内存文件系统空间不足，需要至少 ${required_kib} KiB，当前可用 ${available_kib} KiB。" \
        "Not enough tmpfs space: ${required_kib} KiB required, ${available_kib} KiB available."

    source_sha=$(sha256sum "$LOCAL_IMAGE_FILE" | awk '{print $1}')
    [[ "$source_sha" =~ ^[0-9a-f]{64}$ ]] || die \
        '无法计算本地 CHR IMG 的 SHA-256。' \
        'Could not calculate SHA-256 for the local CHR IMG.'
    printf '%s %s\n' "$(i18n '正在复制本地 CHR IMG 到内存：' 'Copying the local CHR IMG into memory:')" "$LOCAL_IMAGE_FILE"
    cp -- "$LOCAL_IMAGE_FILE" "$IMAGE_PATH" || die \
        '复制本地 CHR IMG 到内存失败。' \
        'Failed to copy the local CHR IMG into memory.'

    copied_bytes=$(wc -c < "$IMAGE_PATH")
    copied_sha=$(sha256sum "$IMAGE_PATH" | awk '{print $1}')
    (( copied_bytes == source_bytes )) && [[ "$copied_sha" == "$source_sha" ]] || die \
        '内存中的 CHR IMG 与 /tmp 源文件校验不一致。' \
        'The in-memory CHR IMG does not match its /tmp source file.'
    IMAGE_SIZE=$copied_bytes
    say \
        'CHR IMG 已完整复制到内存并通过 SHA-256 一致性校验；/tmp 源文件不会被修改。' \
        'The CHR IMG was copied into memory and passed SHA-256 integrity verification; the /tmp source file will not be modified.'
}

load_local_container_package() {
    local source_bytes copied_bytes source_sha copied_sha

    [[ -f "$LOCAL_CONTAINER_PACKAGE" && ! -L "$LOCAL_CONTAINER_PACKAGE" && \
       -r "$LOCAL_CONTAINER_PACKAGE" && -s "$LOCAL_CONTAINER_PACKAGE" ]] || die \
        '本地 container.npk 不存在、不可读、为空或是符号链接。' \
        'The local container.npk is missing, unreadable, empty, or a symbolic link.'

    source_bytes=$(wc -c < "$LOCAL_CONTAINER_PACKAGE")
    source_sha=$(sha256sum "$LOCAL_CONTAINER_PACKAGE" | awk '{print $1}')
    [[ "$source_bytes" =~ ^[0-9]+$ && "$source_bytes" -gt 0 && \
       "$source_sha" =~ ^[0-9a-f]{64}$ ]] || die \
        '无法读取本地 container.npk 的大小或 SHA-256。' \
        'Could not read the size or SHA-256 of the local container.npk.'

    CONTAINER_PACKAGE_PATH="$WORK_DIR/container.npk"
    cp -- "$LOCAL_CONTAINER_PACKAGE" "$CONTAINER_PACKAGE_PATH" || die \
        '复制本地 container.npk 失败。' 'Failed to copy the local container.npk.'
    copied_bytes=$(wc -c < "$CONTAINER_PACKAGE_PATH")
    copied_sha=$(sha256sum "$CONTAINER_PACKAGE_PATH" | awk '{print $1}')
    (( copied_bytes == source_bytes )) && [[ "$copied_sha" == "$source_sha" ]] || die \
        '复制后的 container.npk 与 /tmp 源文件校验不一致。' \
        'The copied container.npk does not match its /tmp source file.'
    CONTAINER_PACKAGE_SHA256=$copied_sha

    printf '%s %s (%s bytes)\n' \
        "$(i18n '已载入本地软件包：' 'Loaded local package:')" \
        "$LOCAL_CONTAINER_PACKAGE" "$copied_bytes"
    warn \
        '本地 container.npk 已通过复制一致性检查；架构仅由文件名是否包含 arm 判定，未识别版本，也未执行官方真实性校验。' \
        'The local container.npk passed copy-integrity checks; architecture was inferred only from whether its filename contains arm, no version was inferred, and official authenticity was not verified.'
}

filesystem_type() {
    blkid -c /dev/null -s TYPE -o value "$1" 2>/dev/null
}

partition_geometry() {
    local input=$1
    local resolved device_name sys_path identity
    local part_number="" part_start="" part_size=""

    resolved=$(readlink -f "$input" 2>/dev/null) || return 1
    [[ -n "$resolved" ]] || return 1
    partition_device_is_ready "$resolved" || return 1
    device_name=${resolved##*/}
    sys_path="$SYS_CLASS_BLOCK_ROOT/$device_name"

    # Kernel sysfs is the most stable source for a partition number and its
    # start sector. Some util-linux releases leave PARTN/START empty when
    # lsblk -d is used on a loop partition such as /dev/loop0p1.
    if [[ -r "$sys_path/partition" && -r "$sys_path/start" ]]; then
        IFS= read -r part_number < "$sys_path/partition" || part_number=""
        IFS= read -r part_start < "$sys_path/start" || part_start=""
    fi

    # Keep an lsblk fallback for environments without a mounted/readable
    # sysfs. Do not use -d here: older lsblk versions can suppress partition
    # metadata for an explicitly selected loop partition when -d is present.
    if [[ ! "$part_number" =~ ^[0-9]+$ || ! "$part_start" =~ ^[0-9]+$ ]]; then
        identity=$(lsblk -nro PARTN,START "$resolved" 2>/dev/null | \
            awk 'NF >= 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {print $1, $2; exit}') || true
        if [[ "$identity" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
            part_number=${BASH_REMATCH[1]}
            part_start=${BASH_REMATCH[2]}
        fi
    fi

    part_size=$(blockdev --getsize64 "$resolved" 2>/dev/null) || return 1
    [[ "$part_number" =~ ^[0-9]+$ && "$part_start" =~ ^[0-9]+$ && \
       "$part_size" =~ ^[0-9]+$ ]] || return 1
    (( 10#$part_number > 0 && 10#$part_size > 0 )) || return 1
    printf '%s %s %s\n' "$part_number" "$part_start" "$part_size"
}

loop_partition_layout() {
    local loop_device=$1
    local partition geometry part_number part_start part_size
    local layout=""
    local partitions=()

    mapfile -t partitions < <(
        lsblk -nrpo NAME,TYPE "$loop_device" | awk '$2 == "part" {print $1}'
    )
    (( ${#partitions[@]} >= 1 && ${#partitions[@]} <= 16 )) || return 1
    for partition in "${partitions[@]}"; do
        partition_device_is_ready "$partition" || return 1
        geometry=$(partition_geometry "$partition") || return 1
        read -r part_number part_start part_size <<< "$geometry"
        layout+="${part_number}:${part_start}:${part_size}"$'\n'
    done
    printf '%s' "$layout" | sort -t: -k1,1n -k2,2n -k3,3n
}

read_le_uint() {
    local device=$1
    local offset=$2
    local length=$3
    local raw octet
    local value=0
    local index
    local octets=()

    raw=$(od -An -v -j "$offset" -N "$length" -tu1 "$device" 2>/dev/null) || return 1
    read -r -a octets <<< "$raw"
    (( ${#octets[@]} == length )) || return 1
    for (( index=0; index<length; index++ )); do
        octet=${octets[index]}
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
        value=$(( value | (10#$octet << (8 * index)) ))
    done
    printf '%u\n' "$value"
}

fat_filesystem_summary() {
    local device=$1
    local bytes_per_sector sectors_per_cluster reserved_sectors fat_count
    local root_entries total_sectors_16 total_sectors_32 total_sectors
    local fat_sectors_16 fat_sectors_32 fat_sectors hidden_sectors media_byte
    local sectors_per_track head_count drive_number extended_boot_signature
    local boot_signature root_dir_sectors root_start data_start data_sectors
    local cluster_count volume_bytes fat_variant

    bytes_per_sector=$(read_le_uint "$device" 11 2) || return 1
    sectors_per_cluster=$(read_le_uint "$device" 13 1) || return 1
    reserved_sectors=$(read_le_uint "$device" 14 2) || return 1
    fat_count=$(read_le_uint "$device" 16 1) || return 1
    root_entries=$(read_le_uint "$device" 17 2) || return 1
    total_sectors_16=$(read_le_uint "$device" 19 2) || return 1
    media_byte=$(read_le_uint "$device" 21 1) || return 1
    fat_sectors_16=$(read_le_uint "$device" 22 2) || return 1
    sectors_per_track=$(read_le_uint "$device" 24 2) || return 1
    head_count=$(read_le_uint "$device" 26 2) || return 1
    hidden_sectors=$(read_le_uint "$device" 28 4) || return 1
    total_sectors_32=$(read_le_uint "$device" 32 4) || return 1
    fat_sectors_32=$(read_le_uint "$device" 36 4) || return 1
    drive_number=$(read_le_uint "$device" 36 1) || return 1
    extended_boot_signature=$(read_le_uint "$device" 38 1) || return 1
    boot_signature=$(read_le_uint "$device" 510 2) || return 1

    (( boot_signature == 43605 )) || return 1
    (( bytes_per_sector >= 512 && bytes_per_sector <= 4096 && \
       (bytes_per_sector & (bytes_per_sector - 1)) == 0 )) || return 1
    (( sectors_per_cluster >= 1 && sectors_per_cluster <= 128 && \
       (sectors_per_cluster & (sectors_per_cluster - 1)) == 0 )) || return 1
    (( reserved_sectors >= 1 && fat_count >= 1 && fat_count <= 4 )) || return 1

    if (( total_sectors_16 > 0 )); then
        total_sectors=$total_sectors_16
    else
        total_sectors=$total_sectors_32
    fi
    if (( fat_sectors_16 > 0 )); then
        fat_sectors=$fat_sectors_16
    else
        fat_sectors=$fat_sectors_32
    fi
    (( total_sectors > 0 && fat_sectors > 0 )) || return 1

    root_dir_sectors=$(( (root_entries * 32 + bytes_per_sector - 1) / bytes_per_sector ))
    root_start=$(( reserved_sectors + fat_count * fat_sectors ))
    data_start=$(( root_start + root_dir_sectors ))
    (( total_sectors > data_start )) || return 1
    data_sectors=$(( total_sectors - data_start ))
    cluster_count=$(( data_sectors / sectors_per_cluster ))
    if (( cluster_count < 4085 )); then
        fat_variant="FAT12"
    elif (( cluster_count < 65525 )); then
        fat_variant="FAT16"
    else
        fat_variant="FAT32"
    fi
    volume_bytes=$(( total_sectors * bytes_per_sector ))

    printf '%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s\n' \
        "$fat_variant" "$bytes_per_sector" "$sectors_per_cluster" \
        "$reserved_sectors" "$fat_count" "$root_entries" "$total_sectors" \
        "$fat_sectors" "$hidden_sectors" "$media_byte" "$sectors_per_track" \
        "$head_count" "$drive_number" "$extended_boot_signature" "$root_start" \
        "$data_start" "$cluster_count" "$volume_bytes"
}

target_fat16_summary() {
    local partition=$1
    local expected_bytes=$2
    local expected_start=$3
    local summary fat_variant bytes_per_sector sectors_per_cluster
    local reserved_sectors fat_count root_entries total_sectors fat_sectors
    local hidden_sectors media_byte sectors_per_track head_count drive_number
    local extended_boot_signature root_start data_start cluster_count volume_bytes
    local fat1_media fat2_media

    summary=$(fat_filesystem_summary "$partition") || return 1
    IFS=: read -r fat_variant bytes_per_sector sectors_per_cluster \
        reserved_sectors fat_count root_entries total_sectors fat_sectors \
        hidden_sectors media_byte sectors_per_track head_count drive_number \
        extended_boot_signature root_start data_start cluster_count volume_bytes <<< "$summary"

    [[ "$fat_variant" == "FAT16" ]] || return 1
    (( bytes_per_sector == 512 && volume_bytes == expected_bytes && \
       fat_count == 2 && root_entries > 0 && hidden_sectors == expected_start && \
       media_byte == 248 && sectors_per_track == 32 && head_count == 8 && \
       drive_number == 128 && extended_boot_signature == 41 )) || return 1

    fat1_media=$(read_le_uint "$partition" "$(( reserved_sectors * bytes_per_sector ))" 1) || return 1
    fat2_media=$(read_le_uint "$partition" \
        "$(( (reserved_sectors + fat_sectors) * bytes_per_sector ))" 1) || return 1
    [[ "$fat1_media" == "$media_byte" && "$fat2_media" == "$media_byte" ]] || return 1

    if (( expected_bytes == 33554432 )); then
        (( sectors_per_cluster == 4 && reserved_sectors == 4 && fat_count == 2 && \
           root_entries == 512 && total_sectors == 65536 && fat_sectors == 64 && \
           root_start == 132 && data_start == 164 )) || return 1
    fi

    printf '%s\n' "$summary"
}

verify_fat16_partition() {
    local partition=$1
    local expected_bytes=$2
    local expected_start=$3
    local summary fat_variant bytes_per_sector sectors_per_cluster
    local reserved_sectors fat_count root_entries total_sectors fat_sectors
    local hidden_sectors media_byte sectors_per_track head_count drive_number
    local extended_boot_signature root_start data_start cluster_count volume_bytes
    summary=$(target_fat16_summary "$partition" "$expected_bytes" "$expected_start" || true)
    [[ -n "$summary" ]] || die \
        "FAT16 启动分区 BPB 不符合目标参数：$partition" \
        "The FAT16 boot-partition BPB does not match the target parameters: $partition"
    IFS=: read -r fat_variant bytes_per_sector sectors_per_cluster \
        reserved_sectors fat_count root_entries total_sectors fat_sectors \
        hidden_sectors media_byte sectors_per_track head_count drive_number \
        extended_boot_signature root_start data_start cluster_count volume_bytes <<< "$summary"

    printf '%s %s; %s=%s, %s=%s, %s=%s, %s=%s, %s=0x%02X\n' \
        "$(i18n 'FAT16 BPB 已核验：' 'FAT16 BPB verified:')" "$partition" \
        "$(i18n '容量' 'bytes')" "$volume_bytes" \
        "$(i18n '每簇扇区' 'sectors/cluster')" "$sectors_per_cluster" \
        "$(i18n '保留扇区' 'reserved')" "$reserved_sectors" \
        "$(i18n '隐藏扇区' 'hidden')" "$hidden_sectors" \
        "$(i18n '介质字节' 'media')" "$media_byte"
}

image_header_sha256() {
    dd if="$IMAGE_PATH" bs=512 count=1 status=none 2>/dev/null | \
        sha256sum | awk '{print $1}'
}

read_hex_bytes() {
    local device=$1
    local offset=$2
    local length=$3
    local value

    value=$(od -An -v -j "$offset" -N "$length" -tx1 "$device" 2>/dev/null | \
        tr -d '[:space:]') || return 1
    [[ ${#value} -eq $(( length * 2 )) && "$value" =~ ^[0-9a-f]+$ ]] || return 1
    printf '%s\n' "$value"
}

mbr_partition_entry_matches() {
    local device=$1
    local entry_number=$2
    local expected_status=$3
    local expected_type=$4
    local expected_start=$5
    local expected_sectors=$6
    local entry_offset status type start sectors

    (( entry_number >= 1 && entry_number <= 4 )) || return 1
    entry_offset=$(( 446 + (entry_number - 1) * 16 ))
    status=$(read_le_uint "$device" "$entry_offset" 1) || return 1
    type=$(read_le_uint "$device" "$(( entry_offset + 4 ))" 1) || return 1
    start=$(read_le_uint "$device" "$(( entry_offset + 8 ))" 4) || return 1
    sectors=$(read_le_uint "$device" "$(( entry_offset + 12 ))" 4) || return 1
    (( status == expected_status && type == expected_type && \
       start == expected_start && sectors == expected_sectors ))
}

x86_uefi_source_layout_is_safe() {
    local image_bytes image_sectors partition_count
    local boot_sectors system_sectors boot_end system_end mbr_signature

    [[ "$CHR_ARCH" == "x86" && "$BOOT_MODE" == "UEFI" ]] || return 1
    [[ "$BOOT_PARTITION_NUMBER" == "1" && "$SYSTEM_PARTITION_NUMBER" == "2" ]] || return 1
    partition_count=$(awk -F: 'NF == 3 {count++} END {print count + 0}' \
        <<< "$IMAGE_PARTITION_LAYOUT")
    (( partition_count == 2 )) || return 1

    image_bytes=$(wc -c < "$IMAGE_PATH") || return 1
    [[ "$image_bytes" =~ ^[0-9]+$ ]] || return 1
    (( image_bytes == IMAGE_SIZE && image_bytes % 512 == 0 && \
       BOOT_PARTITION_SIZE % 512 == 0 && SYSTEM_PARTITION_SIZE % 512 == 0 )) || return 1
    image_sectors=$(( image_bytes / 512 ))
    boot_sectors=$(( BOOT_PARTITION_SIZE / 512 ))
    system_sectors=$(( SYSTEM_PARTITION_SIZE / 512 ))
    boot_end=$(( BOOT_PARTITION_START + boot_sectors - 1 ))
    system_end=$(( SYSTEM_PARTITION_START + system_sectors - 1 ))
    (( BOOT_PARTITION_START >= 34 && boot_sectors > 0 && \
       boot_end < SYSTEM_PARTITION_START && system_sectors > 0 && \
       system_end < image_sectors )) || return 1

    mbr_signature=$(read_le_uint "$IMAGE_PATH" 510 2) || return 1
    (( mbr_signature == 43605 )) || return 1
    mbr_partition_entry_matches "$IMAGE_PATH" 1 128 131 \
        "$BOOT_PARTITION_START" "$boot_sectors" || return 1
    mbr_partition_entry_matches "$IMAGE_PATH" 2 0 131 \
        "$SYSTEM_PARTITION_START" "$system_sectors" || return 1
}

x86_uefi_partition_table_is_clean() {
    local image_bytes image_sectors boot_sectors system_sectors
    local primary_header=512 current_lba backup_lba first_usable last_usable
    local entries_lba entry_count entry_size table_sectors backup_entries_lba
    local boot_entry system_entry boot_start boot_end boot_attributes
    local system_start system_end protective_sectors
    local backup_header backup_current backup_other backup_table
    local esp_guid_le='28732ac11ff8d211ba4b00a0c93ec93b'
    local linux_guid_le='af3dc60f838472478e793d69d8477de4'

    x86_uefi_source_layout_is_safe || return 1
    sgdisk -v "$IMAGE_PATH" >/dev/null 2>&1 || return 1

    image_bytes=$(wc -c < "$IMAGE_PATH") || return 1
    image_sectors=$(( image_bytes / 512 ))
    boot_sectors=$(( BOOT_PARTITION_SIZE / 512 ))
    system_sectors=$(( SYSTEM_PARTITION_SIZE / 512 ))
    [[ $(read_hex_bytes "$IMAGE_PATH" "$primary_header" 8 || true) == \
       '4546492050415254' ]] || return 1

    current_lba=$(read_le_uint "$IMAGE_PATH" "$(( primary_header + 24 ))" 8) || return 1
    backup_lba=$(read_le_uint "$IMAGE_PATH" "$(( primary_header + 32 ))" 8) || return 1
    first_usable=$(read_le_uint "$IMAGE_PATH" "$(( primary_header + 40 ))" 8) || return 1
    last_usable=$(read_le_uint "$IMAGE_PATH" "$(( primary_header + 48 ))" 8) || return 1
    entries_lba=$(read_le_uint "$IMAGE_PATH" "$(( primary_header + 72 ))" 8) || return 1
    entry_count=$(read_le_uint "$IMAGE_PATH" "$(( primary_header + 80 ))" 4) || return 1
    entry_size=$(read_le_uint "$IMAGE_PATH" "$(( primary_header + 84 ))" 4) || return 1
    (( current_lba == 1 && backup_lba == image_sectors - 1 && \
       first_usable <= BOOT_PARTITION_START && entries_lba == 2 && \
       entry_count >= 2 && entry_count <= 1024 && entry_size == 128 )) || return 1

    table_sectors=$(( (entry_count * entry_size + 511) / 512 ))
    backup_entries_lba=$(( backup_lba - table_sectors ))
    (( last_usable == backup_entries_lba - 1 && \
       entries_lba + table_sectors <= first_usable )) || return 1

    boot_entry=$(( entries_lba * 512 + (BOOT_PARTITION_NUMBER - 1) * entry_size ))
    system_entry=$(( entries_lba * 512 + (SYSTEM_PARTITION_NUMBER - 1) * entry_size ))
    [[ $(read_hex_bytes "$IMAGE_PATH" "$boot_entry" 16 || true) == "$esp_guid_le" ]] || return 1
    [[ $(read_hex_bytes "$IMAGE_PATH" "$system_entry" 16 || true) == "$linux_guid_le" ]] || return 1
    boot_start=$(read_le_uint "$IMAGE_PATH" "$(( boot_entry + 32 ))" 8) || return 1
    boot_end=$(read_le_uint "$IMAGE_PATH" "$(( boot_entry + 40 ))" 8) || return 1
    boot_attributes=$(read_le_uint "$IMAGE_PATH" "$(( boot_entry + 48 ))" 8) || return 1
    system_start=$(read_le_uint "$IMAGE_PATH" "$(( system_entry + 32 ))" 8) || return 1
    system_end=$(read_le_uint "$IMAGE_PATH" "$(( system_entry + 40 ))" 8) || return 1
    (( boot_start == BOOT_PARTITION_START && \
       boot_end == BOOT_PARTITION_START + boot_sectors - 1 && \
       (boot_attributes & 4) == 4 && system_start == SYSTEM_PARTITION_START && \
       system_end == SYSTEM_PARTITION_START + system_sectors - 1 )) || return 1

    protective_sectors=$(( 1 + table_sectors ))
    mbr_partition_entry_matches "$IMAGE_PATH" 3 0 238 1 "$protective_sectors" || return 1
    mbr_partition_entry_matches "$IMAGE_PATH" 4 0 0 0 0 || return 1

    backup_header=$(( backup_lba * 512 ))
    [[ $(read_hex_bytes "$IMAGE_PATH" "$backup_header" 8 || true) == \
       '4546492050415254' ]] || return 1
    backup_current=$(read_le_uint "$IMAGE_PATH" "$(( backup_header + 24 ))" 8) || return 1
    backup_other=$(read_le_uint "$IMAGE_PATH" "$(( backup_header + 32 ))" 8) || return 1
    backup_table=$(read_le_uint "$IMAGE_PATH" "$(( backup_header + 72 ))" 8) || return 1
    (( backup_current == backup_lba && backup_other == 1 && \
       backup_table == backup_entries_lba ))
}

repair_x86_uefi_partition_table() {
    local expected_layout expected_boot_sha expected_system_sha
    local gdisk_output current_boot_sha current_system_sha

    [[ "$CHR_ARCH" == "x86" && "$BOOT_MODE" == "UEFI" ]] || return 0
    x86_uefi_source_layout_is_safe || die \
        'x86 UEFI 只支持经核验的双分区 CHR 布局：MBR 第 1 分区必须是活动的启动分区，第 2 分区必须是 RouterOS，且几何信息必须一致。' \
        'x86 UEFI requires a verified two-partition CHR layout: MBR partition 1 must be the active boot partition, partition 2 must be RouterOS, and all geometry must agree.'

    if x86_uefi_partition_table_is_clean; then
        say \
            'x86 UEFI GPT/Hybrid MBR 已经完整、无重叠且校验有效，无需重建。' \
            'The x86 UEFI GPT/Hybrid MBR is already complete, non-overlapping, and valid; no rebuild is needed.'
        return 0
    fi

    expected_layout=$IMAGE_PARTITION_LAYOUT
    expected_boot_sha=$(sha256sum "$BOOT_PARTITION" | awk '{print $1}')
    expected_system_sha=$(sha256sum "$SYSTEM_PARTITION" | awk '{print $1}')
    [[ "$expected_boot_sha" =~ ^[0-9a-f]{64}$ && \
       "$expected_system_sha" =~ ^[0-9a-f]{64}$ ]] || die \
        '无法建立 GPT/Hybrid MBR 重建前的分区内容校验。' \
        'Could not establish partition-content checksums before rebuilding GPT/Hybrid MBR.'

    detach_image
    say \
        '正在按 jaclaz 方法从已核验的 MBR 几何重建 GPT，并生成兼容云平台固件的 Hybrid MBR……' \
        'Rebuilding GPT from the verified MBR geometry with the jaclaz method and creating a cloud-firmware-compatible Hybrid MBR...'
    if ! gdisk_output=$(
        {
            printf '%s\n' 2 x e r f y x a 1 2 '' m t 1 EF00
            printf '%s\n' c 1 'RouterOS Boot' c 2 RouterOS
            printf '%s\n' x k '' r h '1 2' n 83 y 83 n n w y
        } | gdisk "$IMAGE_PATH" 2>&1
    ); then
        printf '%s\n' "$gdisk_output" >&2
        die \
            'gdisk 未能完成 x86 UEFI 分区表重建；内存镜像未写入目标磁盘。' \
            'gdisk could not rebuild the x86 UEFI partition table; the in-memory image was not written to the target disk.'
    fi
    sync "$IMAGE_PATH"

    attach_image
    [[ "$IMAGE_PARTITION_LAYOUT" == "$expected_layout" ]] || die \
        '重建 GPT/Hybrid MBR 后分区编号、起点或容量发生变化。' \
        'Partition numbers, starts, or sizes changed after rebuilding GPT/Hybrid MBR.'
    current_boot_sha=$(sha256sum "$BOOT_PARTITION" | awk '{print $1}')
    current_system_sha=$(sha256sum "$SYSTEM_PARTITION" | awk '{print $1}')
    [[ "$current_boot_sha" == "$expected_boot_sha" && \
       "$current_system_sha" == "$expected_system_sha" ]] || die \
        '重建 GPT/Hybrid MBR 改变了启动分区或 RouterOS 系统分区内容。' \
        'Rebuilding GPT/Hybrid MBR changed the boot or RouterOS system partition contents.'
    x86_uefi_partition_table_is_clean || die \
        '重建后的 GPT/Hybrid MBR 未通过 CRC、ESP 类型、活动标志或备份表位置核验。' \
        'The rebuilt GPT/Hybrid MBR failed validation of CRCs, ESP type, active flag, or backup-table placement.'
    verify_fat16_partition "$BOOT_PARTITION" "$BOOT_PARTITION_SIZE" "$BOOT_PARTITION_START"
    say \
        'GPT/Hybrid MBR 核验通过：无分区重叠，主表与备份表有效，ESP 类型和活动标志正确，两个分区内容未改变。' \
        'GPT/Hybrid MBR validation passed: no partition overlap, valid primary and backup tables, correct ESP type and active flag, and unchanged partition contents.'
}

verify_conversion_guards() {
    local expected_header_sha=$1
    local expected_system_sha=$2
    local current_layout current_header_sha current_system_sha current_system_fs geometry
    local part_number part_start part_size

    current_layout=$(loop_partition_layout "$LOOP_DEVICE" || true)
    [[ -n "$current_layout" && "$current_layout" == "$IMAGE_PARTITION_LAYOUT" ]] || die \
        'FAT16 转换后分区数量、编号、起点或容量发生变化。' \
        'The partition count, numbers, starts, or sizes changed during FAT16 conversion.'
    current_header_sha=$(image_header_sha256 || true)
    [[ "$current_header_sha" =~ ^[0-9a-f]{64}$ && \
       "$current_header_sha" == "$expected_header_sha" ]] || die \
        'FAT16 转换后磁盘首扇区发生变化，分区表标志可能已被修改。' \
        'The disk header sector changed during FAT16 conversion; partition-table flags may have been modified.'
    current_system_sha=$(sha256sum "$SYSTEM_PARTITION" | awk '{print $1}')
    [[ "$current_system_sha" == "$expected_system_sha" ]] || die \
        'FAT16 转换影响了 RouterOS 系统分区，已停止后续写盘。' \
        'FAT16 conversion altered the RouterOS system partition; subsequent disk writing was stopped.'
    current_system_fs=$(filesystem_type "$SYSTEM_PARTITION" || true)
    [[ "$current_system_fs" == "$SYSTEM_PARTITION_FILESYSTEM" ]] || die \
        'FAT16 转换后 RouterOS 系统分区文件系统类型发生变化。' \
        'The RouterOS system-partition filesystem type changed during FAT16 conversion.'

    geometry=$(partition_geometry "$BOOT_PARTITION" || true)
    [[ -n "$geometry" ]] || die \
        'FAT16 转换后无法复核启动分区几何信息。' \
        'Could not revalidate boot-partition geometry after FAT16 conversion.'
    read -r part_number part_start part_size <<< "$geometry"
    [[ "$part_number" == "$BOOT_PARTITION_NUMBER" && \
       "$part_start" == "$BOOT_PARTITION_START" && \
       "$part_size" == "$BOOT_PARTITION_SIZE" ]] || die \
        'FAT16 转换后启动分区几何信息发生变化。' \
        'Boot-partition geometry changed during FAT16 conversion.'

    geometry=$(partition_geometry "$SYSTEM_PARTITION" || true)
    [[ -n "$geometry" ]] || die \
        'FAT16 转换后无法复核 RouterOS 系统分区几何信息。' \
        'Could not revalidate RouterOS system-partition geometry after FAT16 conversion.'
    read -r part_number part_start part_size <<< "$geometry"
    [[ "$part_number" == "$SYSTEM_PARTITION_NUMBER" && \
       "$part_start" == "$SYSTEM_PARTITION_START" && \
       "$part_size" == "$SYSTEM_PARTITION_SIZE" ]] || die \
        'FAT16 转换后 RouterOS 系统分区几何信息发生变化。' \
        'RouterOS system-partition geometry changed during FAT16 conversion.'

    verify_fat16_partition "$BOOT_PARTITION" "$BOOT_PARTITION_SIZE" "$BOOT_PARTITION_START"
    say \
        '转换保护核验通过：分区表首扇区及全部分区几何未变，RouterOS 系统分区逐字节未变。' \
        'Conversion guards passed: the partition-table header and all partition geometry are unchanged, and the RouterOS system partition is byte-for-byte unchanged.'
}

format_x86_uefi_boot_partition_fat16() {
    if (( BOOT_PARTITION_SIZE == 33554432 )); then
        mkfs.fat -F 16 -S 512 -s 4 -R 4 -f 2 -r 512 -M 0xF8 \
            -g 8/32 -h "$BOOT_PARTITION_START" -D 0x80 \
            "$BOOT_PARTITION" >/dev/null || die \
            "无法按参考参数格式化 32 MiB FAT16 启动分区：$BOOT_PARTITION" \
            "Failed to format the 32 MiB FAT16 boot partition with the reference parameters: $BOOT_PARTITION"
    else
        warn \
            "启动分区容量不是参考图中的 32 MiB（实际 ${BOOT_PARTITION_SIZE} bytes）；将保留原容量并自适应创建 FAT16。" \
            "The boot partition is not the 32 MiB size shown in the reference (${BOOT_PARTITION_SIZE} bytes); its original size will be retained while creating FAT16 adaptively."
        mkfs.fat -F 16 -S 512 -f 2 -r 512 -M 0xF8 \
            -g 8/32 -h "$BOOT_PARTITION_START" -D 0x80 \
            "$BOOT_PARTITION" >/dev/null || die \
            "无法将已识别的工作镜像启动分区格式化为 FAT16：$BOOT_PARTITION" \
            "Failed to format the identified working-image boot partition as FAT16: $BOOT_PARTITION"
    fi
    verify_fat16_partition "$BOOT_PARTITION" "$BOOT_PARTITION_SIZE" "$BOOT_PARTITION_START"
}

mount_partition_readonly() {
    local partition=$1
    local target=$2
    local fs_type=$3
    local options="ro,nosuid,nodev,noexec"

    case "$fs_type" in
        ext3|ext4) options+=",noload" ;;
    esac
    mount -t "$fs_type" -o "$options" "$partition" "$target"
}

mount_has_routeros_system_layout() {
    local root=$1

    [[ -d "$root" && ! -L "$root" && \
       -d "$root/rw" && ! -L "$root/rw" && \
       -d "$root/var" && ! -L "$root/var" && \
       -d "$root/var/pdb" && ! -L "$root/var/pdb" && \
       -d "$root/var/pdb/system" && ! -L "$root/var/pdb/system" && \
       -f "$root/var/pdb/system/image" && \
       ! -L "$root/var/pdb/system/image" && \
       -s "$root/var/pdb/system/image" ]]
}

mount_has_x86_uefi_boot_layout() {
    local root=$1

    [[ -d "$root" && ! -L "$root" && \
       -d "$root/EFI" && ! -L "$root/EFI" && \
       -d "$root/EFI/BOOT" && ! -L "$root/EFI/BOOT" && \
       -f "$root/EFI/BOOT/BOOTX64.EFI" && \
       ! -L "$root/EFI/BOOT/BOOTX64.EFI" && \
       -s "$root/EFI/BOOT/BOOTX64.EFI" && \
       -f "$root/map" && ! -L "$root/map" && -s "$root/map" ]]
}

partition_device_is_ready() {
    [[ -b "$1" ]]
}

attach_image() {
    local attempt partition fs_type geometry
    local part_number part_start part_size
    local partitions_ready=0
    local partitions=()
    local system_candidates=()
    local boot_candidates=()

    LOOP_DEVICE=$(losetup --find --show --partscan "$IMAGE_PATH") || die \
        '无法为镜像建立 loop 设备。' 'Failed to attach the image to a loop device.'

    for attempt in 1 2 3 4 5; do
        partitions=()
        partitions_ready=0
        mapfile -t partitions < <(
            lsblk -nrpo NAME,TYPE "$LOOP_DEVICE" | awk '$2 == "part" {print $1}'
        )
        if (( ${#partitions[@]} >= 1 && ${#partitions[@]} <= 16 )); then
            partitions_ready=1
            for partition in "${partitions[@]}"; do
                if ! partition_device_is_ready "$partition"; then
                    partitions_ready=0
                    break
                fi
            done
        fi
        if (( partitions_ready == 1 )); then
            break
        fi
        sleep 1
    done
    (( partitions_ready == 1 )) || die \
        'CHR 镜像未生成有效分区设备，或分区数超过安全上限 16。' \
        'The CHR image exposed no valid partition devices or exceeded the safety limit of 16 partitions.'
    for partition in "${partitions[@]}"; do
        partition_device_is_ready "$partition" || die \
            "CHR 镜像分区设备无效：$partition" \
            "Invalid CHR image partition device: $partition"
    done

    IMAGE_PARTITION_LAYOUT=""
    for partition in "${partitions[@]}"; do
        geometry=$(partition_geometry "$partition" || true)
        [[ -n "$geometry" ]] || die \
            "无法读取 CHR 镜像分区几何信息：$partition" \
            "Could not read CHR image partition geometry: $partition"
        read -r part_number part_start part_size <<< "$geometry"
        IMAGE_PARTITION_LAYOUT+="${part_number}:${part_start}:${part_size}"$'\n'

        fs_type=$(filesystem_type "$partition" || true)
        case "$fs_type" in
            ext2|ext3|ext4)
                if mount_partition_readonly "$partition" "$MOUNT_DIR" "$fs_type"; then
                    MOUNTED=1
                    if mount_has_routeros_system_layout "$MOUNT_DIR"; then
                        system_candidates+=("$partition")
                    fi
                    umount "$MOUNT_DIR" || die \
                        "探测后无法卸载 CHR 分区：$partition" \
                        "Could not unmount CHR partition after probing: $partition"
                    MOUNTED=0
                else
                    warn \
                        "无法以只读方式探测 CHR 分区：$partition ($fs_type)" \
                        "Could not probe CHR partition read-only: $partition ($fs_type)"
                fi
                ;;
        esac
    done
    IMAGE_PARTITION_LAYOUT=$(printf '%s' "$IMAGE_PARTITION_LAYOUT" | \
        sort -t: -k1,1n -k2,2n -k3,3n) || die \
            '无法规范化 CHR 镜像分区几何信息。' \
            'Could not normalize the CHR image partition geometry.'

    (( ${#system_candidates[@]} == 1 )) || die \
        "必须根据内部结构唯一识别一个 RouterOS 系统分区，当前匹配 ${#system_candidates[@]} 个。" \
        "Exactly one RouterOS system partition must be identified by its contents; found ${#system_candidates[@]}."
    SYSTEM_PARTITION=${system_candidates[0]}
    SYSTEM_PARTITION_FILESYSTEM=$(filesystem_type "$SYSTEM_PARTITION" || true)
    case "$SYSTEM_PARTITION_FILESYSTEM" in
        ext2|ext3|ext4) ;;
        *) die \
            '唯一匹配的 RouterOS 系统分区文件系统类型无效。' \
            'The filesystem type of the uniquely matched RouterOS system partition is invalid.' ;;
    esac
    geometry=$(partition_geometry "$SYSTEM_PARTITION" || true)
    [[ -n "$geometry" ]] || die \
        '无法复核 RouterOS 系统分区几何信息。' \
        'Could not revalidate the RouterOS system-partition geometry.'
    read -r SYSTEM_PARTITION_NUMBER SYSTEM_PARTITION_START SYSTEM_PARTITION_SIZE <<< "$geometry"

    if [[ "$CHR_ARCH" == "x86" && "$BOOT_MODE" == "UEFI" ]]; then
        for partition in "${partitions[@]}"; do
            fs_type=$(filesystem_type "$partition" || true)
            case "$fs_type" in
                ext2|ext3|ext4|vfat)
                    if mount_partition_readonly "$partition" "$MOUNT_DIR" "$fs_type"; then
                        MOUNTED=1
                        if mount_has_x86_uefi_boot_layout "$MOUNT_DIR"; then
                            boot_candidates+=("$partition")
                        fi
                        umount "$MOUNT_DIR" || die \
                            "探测后无法卸载 CHR 分区：$partition" \
                            "Could not unmount CHR partition after probing: $partition"
                        MOUNTED=0
                    else
                        warn \
                            "无法以只读方式探测 x86 UEFI 分区：$partition ($fs_type)" \
                            "Could not probe x86 UEFI partition read-only: $partition ($fs_type)"
                    fi
                    ;;
            esac
        done
        (( ${#boot_candidates[@]} == 1 )) || die \
            "必须根据内部结构唯一识别一个 x86 UEFI 启动分区，当前匹配 ${#boot_candidates[@]} 个。" \
            "Exactly one x86 UEFI boot partition must be identified by its contents; found ${#boot_candidates[@]}."
        BOOT_PARTITION=${boot_candidates[0]}
        BOOT_PARTITION_FILESYSTEM=$(filesystem_type "$BOOT_PARTITION" || true)
        [[ "$BOOT_PARTITION" != "$SYSTEM_PARTITION" ]] || die \
            '同一分区不能同时作为 RouterOS 系统分区和 x86 UEFI 启动分区。' \
            'The same partition cannot be both the RouterOS system partition and the x86 UEFI boot partition.'
        geometry=$(partition_geometry "$BOOT_PARTITION" || true)
        [[ -n "$geometry" ]] || die \
            '无法复核 x86 UEFI 启动分区几何信息。' \
            'Could not revalidate the x86 UEFI boot-partition geometry.'
        read -r BOOT_PARTITION_NUMBER BOOT_PARTITION_START BOOT_PARTITION_SIZE <<< "$geometry"
    fi

    printf '%s %s (FS=%s, PARTN=%s, START=%s, SIZE=%s)\n' \
        "$(i18n '已识别 RouterOS 系统分区：' 'Identified RouterOS system partition:')" \
        "$SYSTEM_PARTITION" "$SYSTEM_PARTITION_FILESYSTEM" "$SYSTEM_PARTITION_NUMBER" \
        "$SYSTEM_PARTITION_START" "$SYSTEM_PARTITION_SIZE"
    if [[ -n "$BOOT_PARTITION" ]]; then
        printf '%s %s (FS=%s, PARTN=%s, START=%s, SIZE=%s)\n' \
            "$(i18n '已识别 x86 UEFI 启动分区：' 'Identified x86 UEFI boot partition:')" \
            "$BOOT_PARTITION" "$BOOT_PARTITION_FILESYSTEM" "$BOOT_PARTITION_NUMBER" \
            "$BOOT_PARTITION_START" "$BOOT_PARTITION_SIZE"
    fi
}

detach_image() {
    [[ -n "$LOOP_DEVICE" ]] || return 0
    losetup -d "$LOOP_DEVICE" || die \
        '无法分离 CHR 镜像 loop 设备。' 'Failed to detach the CHR image loop device.'
    LOOP_DEVICE=""
    BOOT_PARTITION=""
    SYSTEM_PARTITION=""
    BOOT_PARTITION_FILESYSTEM=""
    SYSTEM_PARTITION_FILESYSTEM=""
    BOOT_PARTITION_NUMBER=""
    BOOT_PARTITION_START=""
    BOOT_PARTITION_SIZE=""
    SYSTEM_PARTITION_NUMBER=""
    SYSTEM_PARTITION_START=""
    SYSTEM_PARTITION_SIZE=""
    IMAGE_PARTITION_LAYOUT=""
}

attach_source_image() {
    local attempt partition fs_type geometry
    local part_number part_start part_size
    local partitions_ready=0
    local partitions=()
    local boot_candidates=()

    [[ -f "$SOURCE_IMAGE_PATH" && ! -L "$SOURCE_IMAGE_PATH" && -s "$SOURCE_IMAGE_PATH" ]] || die \
        '在线 UEFI 转换所需的官方原始 IMG 不存在或无效。' \
        'The official source IMG required for online UEFI conversion is missing or invalid.'
    SOURCE_LOOP_DEVICE=$(losetup --read-only --find --show --partscan "$SOURCE_IMAGE_PATH") || die \
        '无法以只读方式连接官方原始 CHR 镜像。' \
        'Failed to attach the official source CHR image read-only.'

    for attempt in 1 2 3 4 5; do
        partitions=()
        partitions_ready=0
        mapfile -t partitions < <(
            lsblk -nrpo NAME,TYPE "$SOURCE_LOOP_DEVICE" | awk '$2 == "part" {print $1}'
        )
        if (( ${#partitions[@]} >= 1 && ${#partitions[@]} <= 16 )); then
            partitions_ready=1
            for partition in "${partitions[@]}"; do
                if ! partition_device_is_ready "$partition"; then
                    partitions_ready=0
                    break
                fi
            done
        fi
        if (( partitions_ready == 1 )); then
            break
        fi
        sleep 1
    done
    (( partitions_ready == 1 )) || die \
        '官方原始 CHR 镜像未生成有效分区设备，或分区数超过安全上限 16。' \
        'The official source CHR image exposed no valid partition devices or exceeded the safety limit of 16 partitions.'
    for partition in "${partitions[@]}"; do
        partition_device_is_ready "$partition" || die \
            "官方原始 CHR 分区设备无效：$partition" \
            "Invalid official source CHR partition device: $partition"
    done

    SOURCE_PARTITION_LAYOUT=""
    for partition in "${partitions[@]}"; do
        geometry=$(partition_geometry "$partition" || true)
        [[ -n "$geometry" ]] || die \
            "无法读取官方原始 CHR 分区几何信息：$partition" \
            "Could not read official source CHR partition geometry: $partition"
        read -r part_number part_start part_size <<< "$geometry"
        SOURCE_PARTITION_LAYOUT+="${part_number}:${part_start}:${part_size}"$'\n'

        fs_type=$(filesystem_type "$partition" || true)
        case "$fs_type" in
            ext2|ext3|ext4|vfat)
                if mount_partition_readonly "$partition" "$SOURCE_MOUNT_DIR" "$fs_type"; then
                    SOURCE_MOUNTED=1
                    if mount_has_x86_uefi_boot_layout "$SOURCE_MOUNT_DIR"; then
                        boot_candidates+=("$partition")
                    fi
                    umount "$SOURCE_MOUNT_DIR" || die \
                        "探测后无法卸载官方原始 CHR 分区：$partition" \
                        "Could not unmount official source CHR partition after probing: $partition"
                    SOURCE_MOUNTED=0
                else
                    warn \
                        "无法以只读方式探测官方原始 CHR 分区：$partition ($fs_type)" \
                        "Could not probe official source CHR partition read-only: $partition ($fs_type)"
                fi
                ;;
        esac
    done
    SOURCE_PARTITION_LAYOUT=$(printf '%s' "$SOURCE_PARTITION_LAYOUT" | \
        sort -t: -k1,1n -k2,2n -k3,3n) || die \
            '无法规范化官方原始 CHR 分区几何信息。' \
            'Could not normalize the official source CHR partition geometry.'

    (( ${#boot_candidates[@]} == 1 )) || die \
        "必须从官方原始 IMG 唯一识别一个 x86 UEFI 启动分区，当前匹配 ${#boot_candidates[@]} 个。" \
        "Exactly one x86 UEFI boot partition must be identified in the official source IMG; found ${#boot_candidates[@]}."
    SOURCE_BOOT_PARTITION=${boot_candidates[0]}
    geometry=$(partition_geometry "$SOURCE_BOOT_PARTITION" || true)
    [[ -n "$geometry" ]] || die \
        '无法复核官方原图的 x86 UEFI 启动分区几何信息。' \
        'Could not revalidate the x86 UEFI boot-partition geometry in the official source IMG.'
    read -r SOURCE_BOOT_PARTITION_NUMBER SOURCE_BOOT_PARTITION_START \
        SOURCE_BOOT_PARTITION_SIZE <<< "$geometry"

    [[ "$SOURCE_PARTITION_LAYOUT" == "$IMAGE_PARTITION_LAYOUT" ]] || die \
        '官方原始 IMG 与 UEFI 工作镜像的分区布局不一致，拒绝格式化。' \
        'The official source IMG and UEFI working image have different partition layouts; refusing to format.'
    [[ "$SOURCE_BOOT_PARTITION_NUMBER" == "$BOOT_PARTITION_NUMBER" && \
       "$SOURCE_BOOT_PARTITION_START" == "$BOOT_PARTITION_START" && \
       "$SOURCE_BOOT_PARTITION_SIZE" == "$BOOT_PARTITION_SIZE" ]] || die \
        '官方原始 IMG 与工作镜像识别出的 UEFI 启动分区几何信息不一致，拒绝格式化。' \
        'The detected UEFI boot-partition geometry differs between the official source and working images; refusing to format.'
    printf '%s %s (PARTN=%s, START=%s, SIZE=%s)\n' \
        "$(i18n '官方原图 UEFI 分区核验一致：' 'Official-source UEFI partition verified:')" \
        "$SOURCE_BOOT_PARTITION" "$SOURCE_BOOT_PARTITION_NUMBER" \
        "$SOURCE_BOOT_PARTITION_START" "$SOURCE_BOOT_PARTITION_SIZE"
}

detach_source_image() {
    [[ -n "$SOURCE_LOOP_DEVICE" ]] || return 0
    losetup -d "$SOURCE_LOOP_DEVICE" || die \
        '无法分离官方原始 CHR 镜像 loop 设备。' \
        'Failed to detach the official source CHR loop device.'
    SOURCE_LOOP_DEVICE=""
    SOURCE_BOOT_PARTITION=""
    SOURCE_BOOT_PARTITION_NUMBER=""
    SOURCE_BOOT_PARTITION_START=""
    SOURCE_BOOT_PARTITION_SIZE=""
    SOURCE_PARTITION_LAYOUT=""
}

verify_uefi_boot_partition() {
    local partition=$1
    local loader_name=$2
    local loader_path

    mount_partition_readonly "$partition" "$MOUNT_DIR" "$(filesystem_type "$partition" || true)" || die \
        '无法挂载 CHR EFI 启动分区。' 'Failed to mount the CHR EFI boot partition.'
    MOUNTED=1
    loader_path="$MOUNT_DIR/EFI/BOOT/$loader_name"
    mount_has_x86_uefi_boot_layout "$MOUNT_DIR" && \
        [[ -f "$loader_path" && ! -L "$loader_path" && -s "$loader_path" ]] || die \
            "CHR 镜像中缺少安全的 EFI/BOOT/$loader_name 或 map。" \
            "The CHR image lacks a safe EFI/BOOT/$loader_name or map file."
    umount "$MOUNT_DIR" || die \
        '验证后无法卸载 CHR EFI 启动分区。' \
        'Could not unmount the CHR EFI boot partition after verification.'
    MOUNTED=0
    verify_fat16_partition "$partition" "$BOOT_PARTITION_SIZE" "$BOOT_PARTITION_START"
}

convert_online_x86_uefi_boot_partition() {
    local source_boot_fs
    local source_loader source_map target_loader target_map
    local loader_sha map_sha verification_output
    local image_header_sha_before system_sha_before

    [[ "$INSTALL_MODE" == "online" && "$CHR_ARCH" == "x86" && "$BOOT_MODE" == "UEFI" ]] || die \
        '在线 x86 UEFI 转换在错误的安装状态下被调用。' \
        'Online x86 UEFI conversion was called in an invalid installation state.'
    [[ -n "$SOURCE_MOUNT_DIR" && -d "$SOURCE_MOUNT_DIR" && ! -L "$SOURCE_MOUNT_DIR" ]] || die \
        '官方原始 CHR 启动分区挂载目录无效。' \
        'The source CHR boot-partition mount directory is invalid.'

    attach_source_image
    source_boot_fs=$(filesystem_type "$SOURCE_BOOT_PARTITION" || true)
    case "$source_boot_fs" in
        ext2|ext3|ext4|vfat) ;;
        *) die \
            "官方原始 x86 CHR 启动分区文件系统不受支持：${source_boot_fs:-unknown}" \
            "The official source x86 CHR boot-partition filesystem is unsupported: ${source_boot_fs:-unknown}" ;;
    esac

    mount_partition_readonly "$SOURCE_BOOT_PARTITION" "$SOURCE_MOUNT_DIR" "$source_boot_fs" || die \
        '无法只读挂载官方原始 CHR 启动分区。' \
        'Failed to mount the official source CHR boot partition read-only.'
    SOURCE_MOUNTED=1
    source_loader="$SOURCE_MOUNT_DIR/EFI/BOOT/BOOTX64.EFI"
    source_map="$SOURCE_MOUNT_DIR/map"
    mount_has_x86_uefi_boot_layout "$SOURCE_MOUNT_DIR" || die \
        '官方原始 CHR 启动分区缺少安全的 BOOTX64.EFI 或 map。' \
        'The official source CHR boot partition lacks a safe BOOTX64.EFI or map file.'
    loader_sha=$(sha256sum "$source_loader" | awk '{print $1}')
    map_sha=$(sha256sum "$source_map" | awk '{print $1}')

    image_header_sha_before=$(image_header_sha256 || true)
    system_sha_before=$(sha256sum "$SYSTEM_PARTITION" | awk '{print $1}')
    [[ "$image_header_sha_before" =~ ^[0-9a-f]{64}$ && \
       "$system_sha_before" =~ ^[0-9a-f]{64}$ ]] || die \
        '无法建立 FAT16 转换前的分区保护校验。' \
        'Could not establish pre-conversion partition guards for FAT16 conversion.'

    format_x86_uefi_boot_partition_fat16
    mount -o rw,nosuid,nodev,noexec "$BOOT_PARTITION" "$MOUNT_DIR" || die \
        '无法挂载格式化后的在线 UEFI 工作分区。' \
        'Failed to mount the formatted online UEFI working partition.'
    MOUNTED=1
    rsync -a -- "$SOURCE_MOUNT_DIR/" "$MOUNT_DIR/" || die \
        '从官方原始分区同步全部 UEFI 启动文件失败。' \
        'Failed to synchronize all UEFI boot files from the official source partition.'
    sync

    target_loader="$MOUNT_DIR/EFI/BOOT/BOOTX64.EFI"
    target_map="$MOUNT_DIR/map"
    mount_has_x86_uefi_boot_layout "$MOUNT_DIR" || die \
        'FAT 启动分区同步后缺少安全的 BOOTX64.EFI 或 map。' \
        'A safe BOOTX64.EFI or map file is missing from the synchronized FAT boot partition.'
    [[ $(sha256sum "$target_loader" | awk '{print $1}') == "$loader_sha" && \
       $(sha256sum "$target_map" | awk '{print $1}') == "$map_sha" ]] || die \
        '在线 UEFI 启动关键文件同步校验失败。' \
        'Verification of synchronized online UEFI boot files failed.'
    verification_output=$(rsync -rcn --delete --out-format='%i %n%L' -- \
        "$SOURCE_MOUNT_DIR/" "$MOUNT_DIR/") || die \
        '无法复核在线 UEFI 启动分区的全部文件。' \
        'Could not verify all files on the online UEFI boot partition.'
    [[ -z "$verification_output" ]] || die \
        '在线 UEFI 启动分区与官方原始分区的文件内容不一致。' \
        'The online UEFI boot partition does not match the official source partition.'

    umount "$MOUNT_DIR" || die \
        '同步后无法卸载在线 UEFI 工作分区。' \
        'Could not unmount the online UEFI working partition after synchronization.'
    MOUNTED=0
    verify_conversion_guards "$image_header_sha_before" "$system_sha_before"
    umount "$SOURCE_MOUNT_DIR" || die \
        '同步后无法卸载官方原始 CHR 启动分区。' \
        'Could not unmount the official source CHR boot partition after synchronization.'
    SOURCE_MOUNTED=0
    detach_source_image
    rm -f -- "$SOURCE_IMAGE_PATH"
    SOURCE_IMAGE_PATH=""

    say \
        '已按参考目标：动态识别启动分区，将工作副本对应分区格式化为 FAT16，并同步及校验全部启动文件；RouterOS 系统分区保持不变。' \
        'Applied the reference target: dynamically identified the boot partition, formatted the corresponding working-copy partition as FAT16, synchronized and verified every boot file, and kept the RouterOS system partition unchanged.'
}

convert_local_x86_uefi_boot_partition() {
    local archive_path="$WORK_DIR/boot-files.tar"
    local loader_path map_path loader_sha map_sha
    local image_header_sha_before system_sha_before

    # Local images use an in-place backup/restore path because no separately
    # verified official source image is available.
    image_header_sha_before=$(image_header_sha256 || true)
    system_sha_before=$(sha256sum "$SYSTEM_PARTITION" | awk '{print $1}')
    [[ "$image_header_sha_before" =~ ^[0-9a-f]{64}$ && \
       "$system_sha_before" =~ ^[0-9a-f]{64}$ ]] || die \
        '无法建立本地 FAT16 转换前的分区保护校验。' \
        'Could not establish pre-conversion partition guards for local FAT16 conversion.'

    mount_partition_readonly "$BOOT_PARTITION" "$MOUNT_DIR" \
        "$(filesystem_type "$BOOT_PARTITION" || true)" || die \
            '无法只读挂载已识别的本地 CHR 启动分区。' \
            'Failed to mount the identified local CHR boot partition read-only.'
    MOUNTED=1
    loader_path="$MOUNT_DIR/EFI/BOOT/BOOTX64.EFI"
    map_path="$MOUNT_DIR/map"
    mount_has_x86_uefi_boot_layout "$MOUNT_DIR" || die \
        '本地 CHR 启动分区缺少安全的 BOOTX64.EFI 或 map，不能转换。' \
        'The local CHR boot partition lacks a safe BOOTX64.EFI or map file and cannot be converted.'
    loader_sha=$(sha256sum "$loader_path" | awk '{print $1}')
    map_sha=$(sha256sum "$map_path" | awk '{print $1}')

    tar --create --file="$archive_path" --directory="$MOUNT_DIR" . || die \
        '备份 CHR 启动文件失败。' 'Failed to back up the CHR boot files.'
    umount "$MOUNT_DIR" || die \
        '备份后无法卸载本地 CHR 启动分区。' \
        'Could not unmount the local CHR boot partition after backup.'
    MOUNTED=0

    format_x86_uefi_boot_partition_fat16
    mount -o rw,nosuid,nodev,noexec "$BOOT_PARTITION" "$MOUNT_DIR" || die \
        '无法挂载转换后的 CHR FAT16 启动分区。' \
        'Failed to mount the converted CHR FAT16 boot partition.'
    MOUNTED=1
    tar --extract --file="$archive_path" --directory="$MOUNT_DIR" \
        --no-same-owner --no-same-permissions || die \
        '恢复 CHR EFI 启动文件失败。' 'Failed to restore the CHR EFI boot files.'

    loader_path="$MOUNT_DIR/EFI/BOOT/BOOTX64.EFI"
    map_path="$MOUNT_DIR/map"
    mount_has_x86_uefi_boot_layout "$MOUNT_DIR" || die \
        'FAT16 启动分区恢复后缺少安全的 BOOTX64.EFI 或 map。' \
        'A safe BOOTX64.EFI or map file is missing after restoring the FAT16 boot partition.'
    [[ $(sha256sum "$loader_path" | awk '{print $1}') == "$loader_sha" && \
       $(sha256sum "$map_path" | awk '{print $1}') == "$map_sha" ]] || die \
        'FAT16 转换后 EFI 启动文件校验失败。' \
        'EFI boot-file verification failed after FAT16 conversion.'
    sync "$loader_path" "$map_path"
    umount "$MOUNT_DIR" || die \
        '恢复后无法卸载本地 CHR FAT16 启动分区。' \
        'Could not unmount the local CHR FAT16 boot partition after restoration.'
    MOUNTED=0
    rm -f -- "$archive_path"

    verify_conversion_guards "$image_header_sha_before" "$system_sha_before"
    say \
        '已将动态识别出的本地 x86 CHR 启动分区转换为 FAT16，逐字节校验 EFI 文件，并确认 RouterOS 系统分区未改变。' \
        'Converted the dynamically identified local x86 CHR boot partition to FAT16, verified the EFI files byte-for-byte, and confirmed that the RouterOS system partition was unchanged.'
}

prepare_x86_uefi_boot_partition() {
    local boot_fs fat_summary fat_variant

    [[ "$CHR_ARCH" == "x86" && "$BOOT_MODE" == "UEFI" ]] || return 0
    x86_uefi_source_layout_is_safe || die \
        'x86 UEFI 转换前检查失败：仅接受 MBR 中第 1 分区活动、第 2 分区为 RouterOS，且无重叠的双分区 CHR 镜像。' \
        'Pre-conversion x86 UEFI validation failed: only a non-overlapping, two-partition CHR image with active MBR partition 1 and RouterOS partition 2 is accepted.'
    boot_fs=$(filesystem_type "$BOOT_PARTITION" || true)

    case "$boot_fs" in
        vfat)
            fat_summary=$(fat_filesystem_summary "$BOOT_PARTITION" || true)
            fat_variant=${fat_summary%%:*}
            if [[ "$fat_variant" == "FAT16" ]] && \
               target_fat16_summary "$BOOT_PARTITION" \
                   "$BOOT_PARTITION_SIZE" "$BOOT_PARTITION_START" >/dev/null; then
                verify_uefi_boot_partition "$BOOT_PARTITION" 'BOOTX64.EFI'
                if [[ "$INSTALL_MODE" == "online" && -n "$SOURCE_IMAGE_PATH" ]]; then
                    rm -f -- "$SOURCE_IMAGE_PATH"
                    SOURCE_IMAGE_PATH=""
                fi
                say 'x86 UEFI CHR 启动分区已经是合格的 FAT16，无需转换。' \
                    'The x86 UEFI CHR boot partition is already valid FAT16; no conversion is needed.'
            else
                warn \
                    "x86 UEFI 启动分区是 ${fat_variant:-无法识别的 FAT}，或其 BPB 不符合目标；将按参考目标重新创建为 FAT16。" \
                    "The x86 UEFI boot partition is ${fat_variant:-an unrecognized FAT variant}, or its BPB does not match the target; it will be recreated as FAT16."
                if [[ "$INSTALL_MODE" == "online" ]]; then
                    convert_online_x86_uefi_boot_partition
                else
                    convert_local_x86_uefi_boot_partition
                fi
            fi
            ;;
        ext2|ext3|ext4)
            if [[ "$INSTALL_MODE" == "online" ]]; then
                convert_online_x86_uefi_boot_partition
            else
                convert_local_x86_uefi_boot_partition
            fi
            ;;
        *)
            die \
                "x86 UEFI CHR 启动分区文件系统不受支持：${boot_fs:-unknown}" \
                "Unsupported x86 UEFI CHR boot-partition filesystem: ${boot_fs:-unknown}"
            ;;
    esac
    repair_x86_uefi_partition_table
}

install_container_package() {
    local image_root=$1
    local package_store_root="$image_root/var/pdb"
    local system_package_dir="$image_root/var/pdb/system"
    local system_package_image="$image_root/var/pdb/system/image"
    local container_package_dir="$image_root/var/pdb/container"
    local container_package_image="$image_root/var/pdb/container/image"
    local package_bytes available_kib required_kib installed_sha

    [[ -s "$CONTAINER_PACKAGE_PATH" && \
       "$CONTAINER_PACKAGE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die \
        '待预置的 container.npk 不存在或未通过校验。' \
        'The container.npk to be staged is missing or was not verified.'
    [[ -d "$image_root/var" && ! -L "$image_root/var" && \
       -d "$package_store_root" && ! -L "$package_store_root" && \
       -d "$system_package_dir" && ! -L "$system_package_dir" && \
       -f "$system_package_image" && ! -L "$system_package_image" && \
       -s "$system_package_image" ]] || die \
        'CHR 镜像的软件包存储结构无法识别或含有符号链接，拒绝预置 container.npk。' \
        'The CHR package-store layout is unrecognized or contains a symbolic link; refusing to stage container.npk.'
    [[ ! -L "$container_package_dir" && \
       ( ! -e "$container_package_dir" || -d "$container_package_dir" ) ]] || die \
        'CHR 镜像中的 container 软件包路径不是目录。' \
        'The container package path in the CHR image is not a directory.'
    [[ ! -L "$container_package_image" && \
       ( ! -e "$container_package_image" || -f "$container_package_image" ) ]] || die \
        'CHR 镜像中的 container 软件包文件路径无效或是符号链接。' \
        'The Container package-file path in the CHR image is invalid or is a symbolic link.'

    package_bytes=$(wc -c < "$CONTAINER_PACKAGE_PATH")
    available_kib=$(df -Pk "$image_root" | awk 'NR == 2 {print $4}')
    required_kib=$(( (package_bytes + 1023) / 1024 + 1024 ))
    (( available_kib >= required_kib )) || die \
        "CHR 系统分区空间不足：container.npk 需要至少 ${required_kib} KiB，当前可用 ${available_kib} KiB。" \
        "Not enough space in the CHR system partition: ${required_kib} KiB required for container.npk, ${available_kib} KiB available."

    mkdir -p -- "$container_package_dir"
    [[ -d "$container_package_dir" && ! -L "$container_package_dir" ]] || die \
        '无法安全创建 CHR container 软件包目录。' \
        'Could not safely create the CHR Container package directory.'
    chown --reference="$system_package_dir" "$container_package_dir"
    chmod --reference="$system_package_dir" "$container_package_dir"
    cp -- "$CONTAINER_PACKAGE_PATH" "$container_package_image"
    chown --reference="$system_package_image" "$container_package_image"
    chmod --reference="$system_package_image" "$container_package_image"

    installed_sha=$(sha256sum "$container_package_image" | awk '{print $1}')
    [[ "$installed_sha" == "$CONTAINER_PACKAGE_SHA256" ]] || die \
        '写入 CHR 镜像的 container.npk 校验失败。' \
        'Verification failed for container.npk written into the CHR image.'
}

choose_network_config() {
    local default_route detected_dns choice

    default_route=$(ip -4 route show default | head -n 1 || true)
    ETH=$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$default_route")
    GATEWAY=$(awk '{for (i=1; i<=NF; i++) if ($i == "via") {print $(i+1); exit}}' <<< "$default_route")

    if [[ -n "$ETH" && -r "/sys/class/net/$ETH/address" ]]; then
        MAC=$(tr '[:lower:]' '[:upper:]' < "/sys/class/net/$ETH/address")
        ADDRESS=$(ip -4 -o address show dev "$ETH" scope global | awk 'NR == 1 {print $4}')
    fi

    detected_dns=""
    if [[ -r /etc/resolv.conf ]]; then
        detected_dns=$(awk '$1 == "nameserver" && $2 !~ /^127\./ {print $2; exit}' /etc/resolv.conf)
    fi
    if [[ -n "$detected_dns" ]] && ! valid_ipv4 "$detected_dns"; then
        detected_dns=""
    fi
    DNS=${detected_dns:-"1.1.1.1,8.8.8.8"}

    [[ -n "$ETH" && -n "$MAC" ]] || die \
        '无法检测默认 IPv4 网卡及其 MAC 地址。' 'Could not detect the default IPv4 interface and MAC address.'

    while true; do
        printf '%s' "$(i18n '是否手动指定静态 IPv4、网关和 DNS？[y/N]: ' 'Specify static IPv4, gateway, and DNS? [y/N]: ')"
        IFS= read -r -u "$INTERACTIVE_FD" choice
        case "$choice" in
            ""|n|N)
                NETWORK_MODE="dhcp"
                ADDRESS=""
                GATEWAY=""
                DNS=""
                say \
                    '网络配置：DHCP（自动获取 IPv4、默认网关和 DNS）。' \
                    'Network configuration: DHCP (automatic IPv4 address, default gateway, and DNS).'
                return 0
                ;;
            y|Y)
                NETWORK_MODE="static"
                break
                ;;
            *)
                warn '请输入 y 或 n；直接回车默认使用 DHCP。' \
                    'Enter y or n; press Enter to use DHCP by default.'
                ;;
        esac
    done

    while true; do
        ask_value "$(i18n 'IPv4 地址（带 CIDR）' 'IPv4 address with CIDR')" "$ADDRESS"
        valid_ipv4_cidr "$REPLY" && ADDRESS=$REPLY && break
        warn 'IPv4/CIDR 格式无效，例如 203.0.113.10/24。' 'Invalid IPv4/CIDR, for example 203.0.113.10/24.'
    done
    while true; do
        ask_value "$(i18n 'IPv4 网关' 'IPv4 gateway')" "$GATEWAY"
        valid_ipv4 "$REPLY" && GATEWAY=$REPLY && break
        warn 'IPv4 网关格式无效。' 'Invalid IPv4 gateway.'
    done
    while true; do
        ask_value "$(i18n 'DNS（多个地址用英文逗号分隔）' 'DNS servers, comma-separated')" "$DNS"
        REPLY=${REPLY//[[:space:]]/}
        valid_dns_list "$REPLY" && DNS=$REPLY && break
        warn 'DNS 列表无效。' 'Invalid DNS server list.'
    done

    printf '%s %s, %s, %s\n' \
        "$(i18n '网络配置：静态 IPv4' 'Network configuration: static IPv4')" \
        "$ADDRESS" "$GATEWAY" "$DNS"
}

choose_admin_password() {
    local generated input
    generated=$(od -An -N12 -tx1 /dev/urandom | tr -d '[:space:]')

    while true; do
        printf '%s' "$(i18n '管理员密码（输入内容会显示；直接回车使用随机密码）：' 'Admin password (input is visible; press Enter for a random password): ')"
        IFS= read -r -u "$INTERACTIVE_FD" input
        if [[ -z "$input" ]]; then
            ADMIN_PASSWORD=$generated
            PASSWORD_WAS_GENERATED=1
            return
        fi
        if [[ "$input" =~ ^[A-Za-z0-9._@%+=,:-]{8,64}$ ]]; then
            ADMIN_PASSWORD=$input
            PASSWORD_WAS_GENERATED=0
            return
        fi
        warn \
            '密码须为 8–64 位，仅允许字母、数字和 ._@%+=,:-' \
            'Password must be 8-64 characters using letters, digits, and ._@%+=,:-'
    done
}

write_autorun_file() {
    local autorun_path=$1
    local gateway_host_route=""

    if [[ "$NETWORK_MODE" == "static" ]] && ! gateway_is_on_link "$ADDRESS" "$GATEWAY"; then
        gateway_host_route="/ip/route/add dst-address=\"$GATEWAY/32\" gateway=\$ifname scope=10"
    fi

    {
        printf '%s\n' ':delay 2s'
        printf '/user/set [find where name="admin"] password="%s"\n' "$ADMIN_PASSWORD"
        printf '/system/clock/set time-zone-autodetect=no time-zone-name=%s\n' "$ROUTEROS_TIME_ZONE"
        printf ':local iface [/interface/ethernet/find where mac-address="%s"]\n' "$MAC"
        printf '%s\n' ':if ([:len $iface] = 0) do={ :set iface [/interface/ethernet/find where default-name="ether1"] }'
        printf '%s\n' ':if ([:len $iface] = 0) do={ :error "Ethernet interface not found" }'
        printf '%s\n' ':local ifname [/interface/ethernet/get $iface name]'
        printf '%s\n' ':foreach item in=[/ip/dhcp-client/find] do={ /ip/dhcp-client/remove $item }'
        if [[ "$NETWORK_MODE" == "dhcp" ]]; then
            printf '%s\n' '/ip/dhcp-client/add interface=$ifname add-default-route=yes default-route-distance=1 use-peer-dns=yes use-peer-ntp=yes disabled=no'
        else
            printf '/ip/dns/set servers="%s"\n' "$DNS"
            printf '/ip/address/add address="%s" interface=$ifname\n' "$ADDRESS"
            [[ -z "$gateway_host_route" ]] || printf '%s\n' "$gateway_host_route"
            printf '/ip/route/add dst-address=0.0.0.0/0 gateway="%s"\n' "$GATEWAY"
        fi
        printf '%s\n' '/ip/neighbor/discovery-settings/set discover-interface-list=none'
        printf '%s\n' '/ip/service/set [find where name="telnet"] disabled=yes'
        printf '%s\n' '/ip/service/set [find where name="ftp"] disabled=yes'
        printf '%s\n' '/ip/service/set [find where name="www"] disabled=yes'
        printf '%s\n' '/ip/service/set [find where name="api"] disabled=yes'
        printf '%s\n' '/ip/service/set [find where name="api-ssl"] disabled=yes'
        printf '%s\n' '/tool/bandwidth-server/set enabled=no'
    } > "$autorun_path"
    if awk '/^[[:space:]]*$/ || /#/ {bad=1} END {exit bad ? 0 : 1}' "$autorun_path"; then
        die \
            '生成的 autorun.scr 含有空行或注释，已停止写入。' \
            'The generated autorun.scr contains a blank line or comment; staging was stopped.'
    fi
    chmod 600 "$autorun_path"
}

write_rosmode_file() {
    local rosmode_path=$1
    local actual_sha

    printf '%s' "$ROSMODE_BASE64" | base64 -d > "$rosmode_path" || die \
        '无法生成 rosmode.msg。' 'Failed to create rosmode.msg.'
    chmod 644 "$rosmode_path"

    actual_sha=$(sha256sum "$rosmode_path" | awk '{print $1}')
    [[ "$actual_sha" == "$ROSMODE_SHA256" ]] || die \
        'rosmode.msg 写入校验失败。' 'rosmode.msg verification failed.'
}

customize_image() {
    local autorun_path rosmode_path

    attach_image
    prepare_x86_uefi_boot_partition

    mount -o rw,nosuid,nodev,noexec "$SYSTEM_PARTITION" "$MOUNT_DIR" || die \
        '无法挂载 CHR 镜像的 RouterOS 分区。' 'Failed to mount the RouterOS partition in the CHR image.'
    MOUNTED=1
    mount_has_routeros_system_layout "$MOUNT_DIR" || die \
        '写入前复核失败：已识别分区不再具有安全、完整的 RouterOS 系统结构。' \
        'Pre-write revalidation failed: the identified partition no longer has a safe, complete RouterOS system layout.'

    autorun_path="$MOUNT_DIR/rw/autorun.scr"
    rosmode_path="$MOUNT_DIR/rw/rosmode.msg"
    [[ ! -L "$autorun_path" && ( ! -e "$autorun_path" || -f "$autorun_path" ) ]] || die \
        'CHR 镜像中的 autorun.scr 路径无效或是符号链接。' \
        'The autorun.scr path in the CHR image is invalid or is a symbolic link.'
    [[ ! -L "$rosmode_path" && ( ! -e "$rosmode_path" || -f "$rosmode_path" ) ]] || die \
        'CHR 镜像中的 rosmode.msg 路径无效或是符号链接。' \
        'The rosmode.msg path in the CHR image is invalid or is a symbolic link.'
    if [[ -n "$CONTAINER_PACKAGE_PATH" ]]; then
        install_container_package "$MOUNT_DIR"
    fi
    write_autorun_file "$autorun_path"
    write_rosmode_file "$rosmode_path"
    if [[ -n "$CONTAINER_PACKAGE_PATH" ]]; then
        sync "$MOUNT_DIR/var/pdb/container/image" "$autorun_path" "$rosmode_path"
    else
        sync "$autorun_path" "$rosmode_path"
    fi

    umount "$MOUNT_DIR"
    MOUNTED=0
    if [[ "$CHR_ARCH" == "x86" && "$BOOT_MODE" == "UEFI" ]]; then
        x86_uefi_partition_table_is_clean || die \
            '最终镜像的 GPT/Hybrid MBR 校验失败，拒绝写入目标磁盘。' \
            'Final-image GPT/Hybrid MBR validation failed; refusing to write the target disk.'
        verify_uefi_boot_partition "$BOOT_PARTITION" 'BOOTX64.EFI'
        say \
            '最终 x86 UEFI 启动核验通过：GPT、Hybrid MBR、FAT16 BPB、BOOTX64.EFI 和 map 均有效。' \
            'Final x86 UEFI boot validation passed: GPT, Hybrid MBR, FAT16 BPB, BOOTX64.EFI, and map are all valid.'
    fi
    detach_image

    if [[ -n "$CONTAINER_PACKAGE_PATH" ]]; then
        say 'Container 包、无注释首启配置和容器设备模式文件均已写入 CHR 镜像。' \
            'The Container package, comment-free first-boot configuration, and container device-mode file were written into the CHR image.'
    else
        say '未提供 Container 包；已跳过软件包预置，并写入无注释首启配置和容器设备模式文件。' \
            'No Container package was provided; package staging was skipped, while the comment-free first-boot configuration and container device-mode file were written.'
    fi
    if [[ "$NETWORK_MODE" == "dhcp" ]]; then
        say \
            'CHR 首次启动将通过 DHCP 自动获取 IPv4、默认网关和 DNS。' \
            'On first boot, CHR will obtain its IPv4 address, default gateway, and DNS through DHCP.'
    else
        say \
            'CHR 首次启动将使用指定的静态 IPv4、网关和 DNS。' \
            'On first boot, CHR will use the specified static IPv4 address, gateway, and DNS.'
    fi
    printf '%s %s\n' "$(i18n 'RouterOS 时区：' 'RouterOS time zone:')" "$ROUTEROS_TIME_ZONE"
    say '已保留 SSH 和 WinBox，关闭 Telnet、FTP、HTTP、API。' \
        'SSH and WinBox remain enabled, while Telnet, FTP, HTTP, and API are disabled.'
    say '已关闭所有接口上的 IP Neighbor 发送与接收，不发现其它设备，也不被其它设备发现。' \
        'IP Neighbor transmission and reception are disabled on every interface, so the router neither discovers nor advertises to other devices.'
    if (( PASSWORD_WAS_GENERATED == 1 )); then
        printf '%s %s\n' "$(i18n '生成的 admin 密码：' 'Generated admin password:')" "$ADMIN_PASSWORD"
        read -r -u "$INTERACTIVE_FD" -p "$(i18n '请保存密码，然后按回车继续。' 'Save this password, then press Enter to continue.')"
    fi
}

detect_root_disk() {
    local root_source
    root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    [[ -n "$root_source" ]] || return 0
    readlink -f "$root_source" 2>/dev/null || printf '%s' "$root_source"
}

confirm_storage() {
    local default_source default_disk entered disk_type target_size logical_sector_size

    say '检测到的磁盘：' 'Detected disks:'
    lsblk -dpno NAME,SIZE,MODEL,TYPE | awk '$NF == "disk" {print}'

    default_source=$(detect_root_disk)
    default_disk=""
    if [[ -n "$default_source" ]]; then
        default_disk=$(lsblk -srnpo NAME,TYPE "$default_source" 2>/dev/null | awk '$2 == "disk" && !found {print $1; found=1}')
    fi

    while true; do
        ask_value "$(i18n '要覆盖的整块磁盘' 'Whole disk to overwrite')" "$default_disk"
        entered=$REPLY
        [[ "$entered" == /dev/* ]] || entered="/dev/$entered"
        TARGET_DISK=$(readlink -f "$entered" 2>/dev/null || true)
        if [[ -z "$TARGET_DISK" || ! -b "$TARGET_DISK" ]]; then
            warn '目标不是有效的块设备。' 'The target is not a valid block device.'
            continue
        fi
        disk_type=$(lsblk -dn -o TYPE "$TARGET_DISK" 2>/dev/null || true)
        if [[ "$disk_type" != "disk" ]]; then
            warn '必须选择整块磁盘，不能选择分区。' 'Select a whole disk, not a partition.'
            continue
        fi
        if [[ $(lsblk -dn -o RO "$TARGET_DISK") == "1" ]]; then
            warn '目标磁盘是只读设备。' 'The target disk is read-only.'
            continue
        fi
        break
    done

    target_size=$(blockdev --getsize64 "$TARGET_DISK")
    logical_sector_size=$(blockdev --getss "$TARGET_DISK" 2>/dev/null || true)
    [[ "$target_size" =~ ^[0-9]+$ && "$logical_sector_size" == "512" ]] || die \
        '目标磁盘必须使用 512-byte 逻辑扇区；4Kn 磁盘不能直接写入此 CHR RAW 镜像。' \
        'The target disk must use 512-byte logical sectors; this CHR RAW image cannot be written directly to a 4Kn disk.'
    (( target_size % 512 == 0 && target_size >= IMAGE_SIZE )) || die \
        '目标磁盘容量小于 CHR 镜像。' 'The target disk is smaller than the CHR image.'
    TARGET_DISK_SECTORS=$(( target_size / 512 ))

    printf '\n'
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$TARGET_DISK"
    printf '\n'
    warn \
        "$TARGET_DISK 上的分区、Linux 系统和全部数据都会永久丢失。" \
        "All partitions, the Linux system, and all data on $TARGET_DISK will be permanently destroyed."
    printf '%s' "$(i18n '请输入 y 确认写入磁盘：' 'Enter y to confirm writing to the disk: ')"
    IFS= read -r -u "$INTERACTIVE_FD" REPLY
    [[ "${REPLY,,}" == "y" ]] || die '未输入 y，操作已中止。' 'y was not entered; aborted.'
}

discard_work_files() {
    rm -f -- \
        "$WORK_DIR/container.npk" \
        "$WORK_DIR/chr-original.img" \
        "$WORK_DIR/boot-files.tar"
    rmdir -- "$WORK_DIR"
    WORK_DIR=""
    rmdir -- "$MOUNT_DIR"
    MOUNT_DIR=""
    if [[ -n "$SOURCE_MOUNT_DIR" ]]; then
        rmdir -- "$SOURCE_MOUNT_DIR"
        SOURCE_MOUNT_DIR=""
    fi
}

write_and_reboot() {
    local tail_wipe_sectors=2048
    local tail_wipe_start

    discard_work_files
    say \
        '正在停用交换空间，确保内存镜像不会依赖即将覆盖的磁盘……' \
        'Disabling swap so the in-memory image cannot depend on the disk that will be overwritten...'
    swapoff -a || die \
        '无法停用交换空间，未写入磁盘。' \
        'Could not disable swap; the disk was not written.'
    sync

    [[ -w /proc/sys/kernel/sysrq && -w /proc/sysrq-trigger ]] || die \
        '内核 SysRq 不可用，无法在覆盖系统盘后可靠重启。' \
        'Kernel SysRq is unavailable, so a reliable reboot after overwriting the system disk is not possible.'
    printf '1\n' > /proc/sys/kernel/sysrq
    exec 8> /proc/sysrq-trigger
    exec 9> /proc/sysrq-trigger

    printf '%s\n' "$(i18n '正在将已定制的 CHR 镜像写入磁盘，禁止断电……' 'Writing the customized CHR image; do not interrupt power...')"

    # Everything below is parsed into this function before the live root disk is overwritten.
    # Keep the image on tmpfs, remount filesystems read-only, clear stale end-of-disk
    # metadata, write with fsync, then reboot via an open /proc fd.
    printf 'u' >&8
    tail_wipe_start=$(( TARGET_DISK_SECTORS - tail_wipe_sectors ))
    printf '%s\n' "$(i18n '正在清除目标磁盘末尾的旧 GPT/RAID 元数据……' 'Clearing stale GPT/RAID metadata at the end of the target disk...')"
    if ! dd if=/dev/zero of="$TARGET_DISK" bs=512 seek="$tail_wipe_start" \
        count="$tail_wipe_sectors" conv=fsync,notrunc status=none; then
        printf '%s\n' "$(i18n '清除目标磁盘旧尾部元数据失败；磁盘可能已被部分修改，请使用救援系统恢复。' 'Failed to clear stale end-of-disk metadata; the disk may be partially modified. Use the rescue system to recover.')" >&2
        return 1
    fi
    if ! dd if="$IMAGE_PATH" of="$TARGET_DISK" bs=4M conv=fsync status=progress; then
        printf '%s\n' "$(i18n '磁盘写入失败；系统盘可能已部分损坏，请立即使用控制台或救援系统恢复。' 'Disk write failed; the system disk may be partially damaged. Use the console or rescue system immediately.')" >&2
        return 1
    fi

    printf '%s\n' "$(i18n '写入完成，正在强制重启……' 'Write completed; forcing reboot...')"
    trap - EXIT INT TERM HUP
    printf 'b' >&9
}

main() {
    show_build_banner
    setup_interactive_input
    select_language
    select_install_mode
    require_bash_version
    require_root
    set_required_commands
    install_missing_commands
    ensure_online_ca_certificates
    show_system_info
    if [[ "$INSTALL_MODE" == "local" ]]; then
        find_local_install_files || die \
            '本地安装文件检查失败；请整理 /tmp 后重新运行脚本。' \
            'Local installation-file validation failed; correct /tmp and run the script again.'
        say \
            '安装使用 /tmp 中匹配 chr-*.img 的本地镜像；CHR 与可选 Container 文件名包含 arm 判为 ARM64，否则判为 x86，且不解析版本。' \
            'Installation uses the local chr-*.img in /tmp; CHR and optional Container filenames containing arm are treated as ARM64, otherwise as x86, and no version is parsed.'
    fi
    prepare_work_directories
    if [[ "$INSTALL_MODE" == "online" ]]; then
        load_online_release
    else
        load_local_image
        if [[ -n "$LOCAL_CONTAINER_PACKAGE" ]]; then
            load_local_container_package
        fi
    fi
    choose_network_config
    choose_admin_password
    customize_image
    confirm_storage
    write_and_reboot
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    main "$@"
fi
