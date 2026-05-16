#!/bin/sh
#==============================================================================
# AzurLaneAutoScript Pixi 一键部署脚本 (Alpine 专用 POSIX 版)
# 特性：
#   - 纯 POSIX sh 兼容 (ash, busybox sh)
#   - 静默执行，网络自适应，系统信息面板，步骤反馈
#   - glibc 兼容层自动配置与降级
#   - 多 GitHub 代理自动切换，curl 进度条下载
#   - 国内镜像加速 (-t cn)，OpenRC 开机自启
#==============================================================================
# 用法: sh pixi_alas_install.sh [-t cn] [-S] [-d DIR] [-l] [--uninstall]
#       sh pixi_alas_install.sh -h  # 查看完整帮助

set -eu

# ---------------------------- 脚本目录（支持管道执行） ----------------------------
case "$0" in
    bash|-bash|*/bash|sh|-sh|*/sh|dash|*/dash|ash|*/ash)
        SCRIPT_DIR="$PWD" ;;
    *)
        SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) ;;
esac

# ---------------------------- 日志文件 ----------------------------
LOGFILE="/tmp/alas_install.log"
touch "$LOGFILE" || { echo "无法创建日志文件 $LOGFILE"; exit 1; }

# ---------------------------- 日志格式化 ----------------------------
# 格式: LEVEL | HH:MM:SS.mmm | message
# (等效于 Python: '%(levelname)s | %(asctime)s.%(msecs)03d | %(message)s', datefmt='%H:%M:%S')
_LOG_DATEFMT='%H:%M:%S'

_log_message() {
    _lm_level="$1"
    _lm_msg="$2"
    _lm_timestamp=$(date "+${_LOG_DATEFMT}")
    echo "${_lm_level} | ${_lm_timestamp} | ${_lm_msg}" >> "$LOGFILE"
}

_log_exec() {
    _le_step_name="$1"
    shift
    _log_message "EXEC" "▶ ${_le_step_name}: $*"
    "$@" >> "$LOGFILE" 2>&1
    _le_ret=$?
    if [ $_le_ret -ne 0 ]; then
        _log_message "ERROR" "✗ ${_le_step_name}: 命令失败 (exit ${_le_ret})"
    else
        _log_message "OK"    "✓ ${_le_step_name}: 命令完成"
    fi
    return $_le_ret
}

# ---------------------------- 加载图标 ----------------------------

ICON_INFO="💡"
ICON_OK="✔️"
ICON_WARN="⚠️"
ICON_ERROR="❌"
ICON_ROCKET="🚀"
ICON_GEAR="⚙️"
ICON_PACKAGE="📦"
ICON_COMPUTER="🖥️"
ICON_CPU="🧠"
ICON_DISK="💾"
ICON_RAM="🧮"
ICON_USER="🆔"
ICON_KERNEL="🐧"

# ---------------------------- 颜色定义 ----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[37m'
NC='\033[0m'

# ---------------------------- 全局变量 ----------------------------
SKIP_SERVICE=false
UNINSTALL=false
KEEP_LOG=false
USE_CN_MIRROR=false
ALPINE_GLIBC_AUTO_RETRY=true
GH_PROXY=""
DEPLOY_TEMPLATE="config/deploy.template-linux.yaml"
INSTALL_DIR="${HOME}/AzurLaneAutoScript"
SCRIPT_OUT_DIR="${HOME}/AzurLaneAutoScript"
WORK_DIR=""
ALAS_DIR=""
PIXI_BIN_PATH=""
USER_NAME="${SUDO_USER:-$(whoami)}"
USER_GROUP=$(id -gn "${USER_NAME}" 2>/dev/null || id -gn 2>/dev/null || echo "${USER_NAME}")
_SPINNER_PID=""
ALPINE_GLIBC_OVERRIDE="${CONDA_OVERRIDE_GLIBC:-2.28}"
ALPINE_GLIBC_LOADER="/lib64/ld-linux-x86-64.so.2"
ALPINE_GLIBC_VERSION="${ALPINE_GLIBC_VERSION:-2.35-r1}"
ALPINE_GLIBC_RETRY_DONE=false

if [ -x "${HOME}/.pixi/bin/pixi"  ]; then
    export PATH="${HOME}/.pixi/bin:${PATH}"
fi

# ---------------------------- 帮助 ----------------------------
usage() {
    cat <<EOF
用法: bash $0 [选项]

选项:
  -d, --dir DIR          指定 ALAS 安装目录 (默认: ~/AzurLaneAutoScript)
  -s, --script-dir DIR   指定脚本输出目录 (默认: ~/AzurLaneAutoScript)
  -t TEMPLATE            控制使用的 deploy 模板与国内镜像源
  -S, --skip-service     跳过 OpenRC 开机自启服务配置
  --uninstall            反向安装：停止并删除 ALAS、虚拟环境、开机自启
  -l, --log              保留安装日志，不自动删除
  -h, --help             显示帮助信息
EOF
}

# ---------------------------- 输出与日志函数 ----------------------------
echo_line() {
    printf '%b\n' "$1"
}

log_out() {
    icon="$1"
    color="$2"
    msg="$3"
    echo_line "  ${icon}  ${color}${msg}${NC}"
    level="INFO"
    case "$icon" in
        "${ICON_OK}")    level="OK"      ;;
        "${ICON_WARN}")  level="WARNING" ;;
        "${ICON_ERROR}") level="ERROR"   ;;
    esac
    _log_message "${level}" "${msg}"
}

log_info()    { log_out "${ICON_INFO}"  "${GREEN}"  "$1"; }
log_ok()      { log_out "${ICON_OK}"   "${GREEN}"  "$1"; }
log_warn()    { log_out "${ICON_WARN}"  "${YELLOW}" "$1"; }
log_error()   { log_out "${ICON_ERROR}" "${RED}"    "$1"; }

# ---------------------------- 通用辅助函数 ----------------------------
is_alpine() {
    [ "${OS_ID:-}" = "alpine" ]
}

backup_file_once() {
    file="$1"
    backup="${file}.bak"
    if [ ! -f "${file}"  ]; then
        return 0
    fi
    if [ -f "${backup}"  ]; then
        _log_message "INFO" "已存在备份 ${backup}，跳过重复覆盖"
        return 0
    fi
    _log_message "EXEC" "▶ 备份 ${file} → ${backup}"
    cp "${file}" "${backup}"
    _log_message "OK" "✓ 备份完成"
}

download_to_file() {
    url="$1"
    output="$2"

    rm -f "${output}"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
            -o "${output}" "${url}" >> "$LOGFILE" 2>&1
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -O "${output}" "${url}" >> "$LOGFILE" 2>&1
        return $?
    fi
    _log_message "ERROR" "未找到 curl 或 wget，无法下载: ${url}"
    return 1
}

download_github_asset_to_file() {
    _dg_github_url="$1"
    _dg_output="$2"

    if [ -n "${GH_PROXY}" ]; then
        if download_to_file "${GH_PROXY}${_dg_github_url}" "${_dg_output}"; then
            return 0
        fi
    fi

    if download_to_file "${_dg_github_url}" "${_dg_output}"; then
        return 0
    fi

    for _dg_proxy in \
        "https://gh.llkk.cc/" \
        "https://ghproxy.net/" \
        "https://hub.gitmirror.com/" \
        "https://gh-proxy.com/"; do
        if download_to_file "${_dg_proxy}${_dg_github_url}" "${_dg_output}"; then
            return 0
        fi
    done

    return 1
}

enable_alpine_community_repo() {
    is_alpine || return 0
    if grep -Eq '^[[:space:]]*[^#].*/community([[:space:]]*)?$' /etc/apk/repositories 2>/dev/null; then
        _log_message "OK" "Alpine community 仓库已启用"
        return 0
    fi
    main_repo community_repo alpine_ver
    main_repo=$(awk '/^[[:space:]]*[^#].*\/main([[:space:]]*)?$/ {print $1; exit}' /etc/apk/repositories 2>/dev/null || true)
    if [ -n "${main_repo}"  ]; then
        community_repo="${main_repo%/main}/community"
    else
        alpine_ver=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo "edge")
        if [ "${alpine_ver}" = "edge"  ]; then
            community_repo="https://dl-cdn.alpinelinux.org/alpine/edge/community"
        else
            community_repo="https://dl-cdn.alpinelinux.org/alpine/v${alpine_ver}/community"
        fi
    fi

    _log_message "INFO" "▶ 启用 Alpine community 仓库: ${community_repo}"
    printf '%s\n' "${community_repo}" >> /etc/apk/repositories
}

ensure_alpine_glibc_loader() {
    is_alpine || return 0

    if [ -e "${ALPINE_GLIBC_LOADER}"  ]; then
        _log_message "OK" "glibc loader 已存在: ${ALPINE_GLIBC_LOADER}"
        return 0
    fi
    loader=""
    candidate
    for candidate in /lib/ld-linux-x86-64.so.2 /usr/glibc-compat/lib/ld-linux-x86-64.so.2; do
        if [ -e "${candidate}"  ]; then
            loader="${candidate}"
            break
        fi
    done

    if [ -n "${loader}"  ]; then
        mkdir -p /lib64
        ln -sf "${loader}" "${ALPINE_GLIBC_LOADER}"
        _log_message "OK" "已创建 glibc loader 兼容链接: ${ALPINE_GLIBC_LOADER} -> ${loader}"
        return 0
    fi

    _log_message "ERROR" "未找到 glibc loader，Pixi 的 linux-64 Python 可能无法启动"
    return 1
}

prepare_alpine_glibc_compat() {
    [ "${OS_ID:-}" = "alpine" ] || return 0

    start_step "正在检查 Alpine glibc 兼容层..."
    _pg_missing=""
    for _pg_pkg in gcompat libstdc++ libgcc; do
        if apk info -e "${_pg_pkg}" >/dev/null 2>&1; then
            _log_message "OK" "兼容依赖已存在: ${_pg_pkg}"
        else
            _log_message "WARNING" "依赖缺失: ${_pg_pkg}"
            _pg_missing="${_pg_missing} ${_pg_pkg}"
        fi
    done

    if [ -n "${_pg_missing}" ]; then
        enable_alpine_community_repo
        _log_message "EXEC" "▶ apk update"
        apk update >> "$LOGFILE" 2>&1
        # shellcheck disable=SC2086
        _log_message "EXEC" "▶ apk add --no-cache${_pg_missing}"
        # shellcheck disable=SC2086
        if apk add --no-cache ${_pg_missing} >> "$LOGFILE" 2>&1; then
            _log_message "OK" "✓ gcompat 兼容层安装成功"
        else
            _log_message "WARNING" "gcompat 在当前 Alpine 仓库中不可用，自动降级到第三方 glibc"
            end_step "${ICON_WARN}" "gcompat 不可用，正在安装第三方 glibc..." "${YELLOW}"
            install_alpine_real_glibc
            return
        fi
    fi

    if ensure_alpine_glibc_loader; then
        end_step "${ICON_OK}" "Alpine glibc 兼容层检查完成"
    else
        _log_message "WARNING" "gcompat 兼容层未提供 glibc loader，自动降级到第三方 glibc"
        end_step "${ICON_WARN}" "gcompat 兼容层不足，正在安装第三方 glibc..." "${YELLOW}"
        install_alpine_real_glibc
    fi
}

install_alpine_real_glibc() {
    is_alpine || return 0

    start_step "正在安装 Alpine 第三方 glibc 兼容包..."
    _log_message "WARNING" "将安装 sgerrand/alpine-pkg-glibc (${ALPINE_GLIBC_VERSION})，用于运行 conda linux-64 Python"

    if apk info -e glibc >/dev/null 2>&1 && [ -e /usr/glibc-compat/lib/ld-linux-x86-64.so.2 ]; then
        mkdir -p /lib64
        ln -sf /usr/glibc-compat/lib/ld-linux-x86-64.so.2 "${ALPINE_GLIBC_LOADER}"
        end_step "${ICON_OK}" "第三方 glibc 已存在"
        return
    fi
    tmp_dir="/tmp/alas_glibc_$$"
    key_file="/etc/apk/keys/sgerrand.rsa.pub"
    key_url="https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub"
    key_fallback="https://raw.githubusercontent.com/sgerrand/alpine-pkg-glibc/master/sgerrand.rsa.pub"
    release_url="https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${ALPINE_GLIBC_VERSION}"
    glibc_apk="${tmp_dir}/glibc-${ALPINE_GLIBC_VERSION}.apk"
    glibc_bin_apk="${tmp_dir}/glibc-bin-${ALPINE_GLIBC_VERSION}.apk"

    mkdir -p "${tmp_dir}" /etc/apk/keys /lib64

    _log_message "EXEC" "▶ 下载 sgerrand APK 签名 key"
    if ! download_to_file "${key_url}" "${key_file}"; then
        _log_message "WARNING" "sgerrand key 官方地址下载失败，尝试 GitHub fallback"
        if ! download_github_asset_to_file "${key_fallback}" "${key_file}"; then
            rm -rf "${tmp_dir}"
            end_step "${ICON_ERROR}" "第三方 glibc key 下载失败，所有下载源均不可用" "${RED}"
            exit 1
        fi
    fi

    _log_message "EXEC" "▶ 下载 glibc APK: ${ALPINE_GLIBC_VERSION}"
    if ! download_github_asset_to_file "${release_url}/glibc-${ALPINE_GLIBC_VERSION}.apk" "${glibc_apk}" || \
       ! download_github_asset_to_file "${release_url}/glibc-bin-${ALPINE_GLIBC_VERSION}.apk" "${glibc_bin_apk}"; then
        rm -rf "${tmp_dir}"
        end_step "${ICON_ERROR}" "第三方 glibc APK 下载失败，所有 GitHub/代理源均不可用" "${RED}"
        exit 1
    fi

    if apk info -e gcompat >/dev/null 2>&1; then
        _log_message "EXEC" "▶ 移除 gcompat 以避免与 glibc loader 冲突"
        apk del gcompat >> "$LOGFILE" 2>&1 || true
    fi

    _log_message "EXEC" "▶ apk add --force-overwrite glibc"
    if ! apk add --force-overwrite "${glibc_apk}" "${glibc_bin_apk}" >> "$LOGFILE" 2>&1; then
        rm -rf "${tmp_dir}"
        end_step "${ICON_ERROR}" "第三方 glibc 安装失败，详情请查看日志: ${LOGFILE}" "${RED}"
        exit 1
    fi

    if [ -e /usr/glibc-compat/lib/ld-linux-x86-64.so.2  ]; then
        ln -sf /usr/glibc-compat/lib/ld-linux-x86-64.so.2 "${ALPINE_GLIBC_LOADER}"
    fi
    rm -rf "${tmp_dir}"

    if ensure_alpine_glibc_loader; then
        end_step "${ICON_OK}" "第三方 glibc 安装完成"
    else
        end_step "${ICON_ERROR}" "第三方 glibc 安装后仍缺少 loader" "${RED}"
        exit 1
    fi
}

pixi_install_needs_real_glibc() {
    _pn_install_log="$1"
    is_alpine || return 1
    [ -f "${_pn_install_log}" ] || return 1
    grep -Eqi 'failed to query interpreter|build dispatch initialization failed|ld-linux|No such file or directory|not found' "${_pn_install_log}"
}

diagnose_pixi_install_failure() {
    install_log="$1"
    _log_message "ERROR" "✗ pixi install 失败"

    if pixi_install_needs_real_glibc "${install_log}"; then
        _log_message "ERROR" "Alpine glibc 兼容层不足，Pixi 的 linux-64 Python 无法启动"
        end_step "${ICON_ERROR}" "Pixi 无法启动 linux-64 Python：第三方 glibc 已安装但仍失败，请查看日志" "${RED}"
        return
    fi

    end_step "${ICON_ERROR}" "虚拟环境构建错误，详情请阅读日志：${LOGFILE}" "${RED}"
}

verify_pixi_python_prefix() {
    env_python=".pixi/envs/default/bin/python"
    python_log="/tmp/pixi_python_check_$$.log"

    if [ ! -x "${env_python}"  ]; then
        _log_message "ERROR" "Pixi Python 不存在或不可执行: ${env_python}"
        if is_alpine; then
            end_step "${ICON_ERROR}" "Pixi 环境缺少 Python，Alpine glibc 兼容层可能不足" "${RED}"
        else
            end_step "${ICON_ERROR}" "Pixi 环境缺少 Python，请查看日志: ${LOGFILE}" "${RED}"
        fi
        return 1
    fi

    if ! "${env_python}" -V > "${python_log}" 2>&1; then
        cat "${python_log}" >> "$LOGFILE" 2>/dev/null || true
        rm -f "${python_log}"
        _log_message "ERROR" "Pixi Python 前缀健康检查失败: ${env_python}"
        if is_alpine; then
            end_step "${ICON_ERROR}" "Alpine glibc 兼容层不足，Pixi 的 linux-64 Python 无法运行" "${RED}"
        else
            end_step "${ICON_ERROR}" "Pixi Python 无法运行，请查看日志: ${LOGFILE}" "${RED}"
        fi
        return 1
    fi

    _log_message "OK" "✓ Pixi Python 可运行: $(tr -d '\r\n' < "${python_log}")"
    rm -f "${python_log}"
    return 0
}

# ---------------------------- 流水灯系统 ----------------------------
_cleanup_spinner() {
    if [ -n "$_SPINNER_PID"  ]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
        wait "$_SPINNER_PID" 2>/dev/null || true
        _SPINNER_PID=""
    fi
}

_get_spin_char() {
    case $_SPINNER_IDX in
        0) printf '⠋' ;;
        1) printf '⠙' ;;
        2) printf '⠹' ;;
        3) printf '⠸' ;;
        4) printf '⠼' ;;
        5) printf '⠴' ;;
        6) printf '⠦' ;;
        7) printf '⠧' ;;
        8) printf '⠇' ;;
        9) printf '⠏' ;;
    esac
}

start_step() {
    _cleanup_spinner
    _ss_msg="$1"
    _log_message "START" "${_ss_msg}"
    _SPINNER_IDX=0
    {
        while true; do
            _c=$(_get_spin_char)
            printf "\r${YELLOW}%s  %s${NC}\033[K" "$_c" "$_ss_msg"
            _SPINNER_IDX=$(( (_SPINNER_IDX + 1) % 10 ))
            sleep 0.20 2>/dev/null || true
        done
    } &
    _SPINNER_PID=$!
}

end_step() {
    icon="$1"
    msg="$2"
    color="${3:-${GREEN}}"
    _cleanup_spinner
    printf "\r${icon}  ${color}%s${NC}\033[K\n" "$msg"
    level="INFO"
    case "$icon" in
        "${ICON_OK}")    level="OK"      ;;
        "${ICON_WARN}")  level="WARNING" ;;
        "${ICON_ERROR}") level="ERROR"   ;;
    esac
    _log_message "${level}" "${msg}"
}

# ---------------------------- 中断信号处理 ----------------------------
_sigint_handler() {
    _cleanup_spinner
    printf '%b\n' "\n  ${ICON_WARN}  ${YELLOW}脚本已被用户中断${NC}"
    exit 130
}
trap '_sigint_handler' INT

# ---------------------------- 参数解析 ----------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dir) INSTALL_DIR="$2"; shift 2 ;;
        -s|--script-dir) SCRIPT_OUT_DIR="$2"; shift 2 ;;
        -t|--template)
            if [ "$2" =~ ^[Cc][Nn]$  ]; then
                DEPLOY_TEMPLATE="config/deploy.template-linux-cn.yaml"
                USE_CN_MIRROR=true
                GH_PROXY="https://ghfast.top/"
            else
                DEPLOY_TEMPLATE="$2"
            fi
            shift 2 ;;
        --uninstall) UNINSTALL=true; shift ;;
        -l|--log) KEEP_LOG=true; shift ;;
        -S|--skip-service) SKIP_SERVICE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "未知参数: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------- 权限检查 ----------------------------
if [ "$(id -u)" -ne 0  ]; then
    printf '%b\n' "${RED}请使用 root 权限运行此脚本 (sudo bash $0)${NC}"
    exit 1
fi

# ---------------------------- 系统信息收集 ----------------------------
gather_system_info() {
    # 优先用 ip 命令（Alpine/BusyBox hostname -I 不一定可用）
    NET_IP=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -z "${NET_IP}" ] && NET_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "${NET_IP}" ] && NET_IP="未获取"
    KERNEL=$(uname -r)
    # lscpu 在 Alpine 不一定可用，回退到 /proc/cpuinfo
    if command -v lscpu >/dev/null 2>&1; then
        CPU_MODEL=$(lscpu | grep -i "Model name" | sed 's/.*:\s*//' | xargs || echo "未知")
    else
        CPU_MODEL=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | sed 's/.*: //' | xargs || echo "未知")
    fi
    CPU_CORES=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")
    DISK_AVAIL=$(df -h / | awk 'NR==2{print $4}')
    DISK_USED=$(df -h / | awk 'NR==2{print $3}')
    DISK_INFO="可用: ${DISK_AVAIL}  已用: ${DISK_USED}"
    RAM_SIZE_MIB=$(free -m 2>/dev/null | awk '/Mem:/{print $2}' || awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
}

# ---------------------------- 打印标题与系统面板 ----------------------------
print_header() {
    clear 2>/dev/null || printf '\033[2J\033[H' 2>/dev/null || true
    echo_line "${WHITE}"
    echo_line "    ___    __    ___   _____"
    echo_line "   /   |  / /   /   | / ___/"
    echo_line "  / /| | / /   / /| | \\__ \\ "
    echo_line " / ___ |/ /___/ ___ |___/ / "
    echo_line "/_/  |_/_____/_/  |_/____/  "
    echo_line "${NC}"
    echo_line "  ${ICON_COMPUTER}  Alpine Linux 中基于 Pixi 的 ALAS 部署脚本"
    echo_line "  ─────────────────────────────────────────────────"
    echo_line "  ${ICON_INFO}  当前局域网 IP  : ${BLUE}${NET_IP}${NC}"
    echo_line "  ${ICON_GEAR}  系统发行版     : ${GREEN}${OS_ID} ${OS_VERSION}${NC}"
    echo_line "  ${ICON_KERNEL}  内核版本       : ${GREEN}${KERNEL}${NC}"
    echo_line "  ${ICON_COMPUTER}  CPU 型号       : ${GREEN}${CPU_MODEL}${NC}"
    echo_line "  ${ICON_CPU}  CPU 核心数     : ${GREEN}${CPU_CORES}${NC}"
    echo_line "  ${ICON_DISK}  磁盘大小       : ${BLUE}${DISK_INFO}${NC}"

    _ph_ram_color="${GREEN}"
    _ph_ram="${RAM_SIZE_MIB}"
    if echo "${_ph_ram}" | grep -Eq '^[0-9]+$'; then
        if [ "${_ph_ram}" -lt 1000 ]; then
            _ph_ram_color="${YELLOW}"
        elif [ "${_ph_ram}" -lt 2000 ]; then
            _ph_ram_color="${BLUE}"
        fi
    fi
    echo_line "  ${ICON_RAM}  内存大小       : ${_ph_ram_color}${_ph_ram} MiB${NC}"

    _ph_user_color="${GREEN}"
    if [ "${USER_NAME}" = "root" ] && [ "${USER_GROUP}" = "root" ]; then
        _ph_user_color="${YELLOW}"
    fi
    echo_line "  ${ICON_USER}  当前用户/组    : ${_ph_user_color}${USER_NAME} / ${USER_GROUP}${NC}"
    echo_line ""
}

# ---------------------------- 发行版检测 ----------------------------
detect_os() {
    if [ -f /etc/os-release  ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-}"
    else
        log_error "无法检测 Linux 发行版"
        exit 1
    fi
}

# ---------------------------- Pixi 二进制下载（顶层函数，可被多处调用）----------------------------
# 用法: _install_pixi_binary <download_url>
# 下载 pixi tar.gz 并解压到 ~/.pixi/bin/pixi，支持 curl/wget 自动切换
_install_pixi_binary() {
    _ip_dl_url="$1"
    _ip_tmp_tar="/tmp/pixi_install_$$.tar.gz"
    _log_message "EXEC" "▶ 下载 Pixi 二进制: ${_ip_dl_url}"
    mkdir -p "${HOME}/.pixi/bin"

    _cleanup_spinner
    printf "  ${CYAN}📥  正在下载 Pixi...${NC}\n"

    _ip_download_ok=false

    if command -v curl >/dev/null 2>&1; then
        if curl -fSL --retry 3 --retry-delay 2 --progress-bar \
               -o "${_ip_tmp_tar}" "${_ip_dl_url}" 2>&1; then
            _ip_download_ok=true
            _log_message "OK" "✓ curl 下载完成"
        else
            _log_message "ERROR" "✗ curl 下载失败，尝试 wget..."
            printf "  ${YELLOW}${ICON_WARN}  curl 失败，切换 wget...${NC}\n"
        fi
    else
        _log_message "WARNING" "未找到 curl，尝试 wget..."
    fi

    if [ "${_ip_download_ok}" = false ] && command -v wget >/dev/null 2>&1; then
        _ip_wget_cmd="wget -O \"${_ip_tmp_tar}\" \"${_ip_dl_url}\""
        if wget --help 2>&1 | grep -q -- '--show-progress'; then
            _ip_wget_cmd="wget --show-progress -q --tries=3 -O \"${_ip_tmp_tar}\" \"${_ip_dl_url}\""
        fi
        if eval "${_ip_wget_cmd}" 2>&1; then
            _ip_download_ok=true
            _log_message "OK" "✓ wget 下载完成"
        else
            _log_message "ERROR" "✗ wget 下载也失败"
        fi
    fi

    if [ "${_ip_download_ok}" = false ]; then
        rm -f "${_ip_tmp_tar}"
        return 1
    fi

    printf "  ${GREEN}✓  下载完成，正在解压...${NC}\n"
    _log_message "EXEC" "▶ tar 解压 pixi 到 ${HOME}/.pixi/bin/"
    if tar -xz -C "${HOME}/.pixi/bin/" pixi < "${_ip_tmp_tar}" >> "$LOGFILE" 2>&1; then
        chmod +x "${HOME}/.pixi/bin/pixi"
        rm -f "${_ip_tmp_tar}"
        _log_message "OK" "✓ Pixi 二进制解压完成"
        return 0
    fi

    rm -f "${_ip_tmp_tar}"
    _log_message "ERROR" "✗ tar 解压失败"
    return 1
}

# ---------------------------- 第1步: 安装/激活 Pixi ----------------------------
install_pixi() {
    start_step "正在检查 Pixi..."
    arch pixi_archive
    arch=$(uname -m)
    case "${arch}" in
        x86_64|amd64) pixi_archive="pixi-x86_64-unknown-linux-musl.tar.gz" ;;
        *)
            end_step "${ICON_ERROR}" "当前脚本仅支持 x86-64 Linux，当前架构: ${arch}" "${RED}"
            exit 1 ;;
    esac

    if command -v pixi >/dev/null 2>&1; then
        PIXI_VER=$(pixi --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Pixi 已安装: ${PIXI_VER}"
        return
    fi

    if [ -x "${HOME}/.pixi/bin/pixi"  ]; then
        export PATH="${HOME}/.pixi/bin:${PATH}"
        PIXI_VER=$(pixi --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Pixi 已激活: ${PIXI_VER}"
        return
    fi

    _log_message "INFO" "未检测到 Pixi，开始安装..."
    start_step "正在安装 Pixi..."
    pixi_dl
    if [ "${USE_CN_MIRROR}" = true ]; then
        pixi_dl="${GH_PROXY}https://github.com/prefix-dev/pixi/releases/latest/download/${pixi_archive}"
        _log_message "EXEC" "▶ 安装 Pixi (国内源): ${pixi_dl}"
    else
        pixi_dl="https://github.com/prefix-dev/pixi/releases/latest/download/${pixi_archive}"
        _log_message "EXEC" "▶ 安装 Pixi (直连): ${pixi_dl}"
    fi

    if ! _install_pixi_binary "${pixi_dl}"; then
        end_step "${ICON_ERROR}" "Pixi 安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
        exit 1
    fi
    _log_message "OK" "✓ Pixi 安装已完成"

    export PATH="${HOME}/.pixi/bin:${PATH}"
    if command -v pixi >/dev/null 2>&1; then
        PIXI_VER=$(pixi --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Pixi 已安装: ${PIXI_VER}"
    else
        _log_message "ERROR" "Pixi 安装后未找到可执行文件"
        end_step "${ICON_ERROR}" "Pixi 安装失败，请查看日志: ${LOGFILE}" "${RED}"
        exit 1
    fi
}

# ---------------------------- 第2步: 安装 Git 和 ADB 及相关依赖库 ----------------------------
install_git_adb() {
    start_step "正在检查依赖..."

    _ga_missing=""
    for _ga_pkg in bash git android-tools curl ca-certificates tar xz libstdc++ libgcc; do
        if apk info -e "${_ga_pkg}" >/dev/null 2>&1; then
            _log_message "OK" "依赖已存在: ${_ga_pkg}"
        else
            _log_message "WARNING" "依赖缺失: ${_ga_pkg}"
            _ga_missing="${_ga_missing} ${_ga_pkg}"
        fi
    done

    if [ -z "${_ga_missing}" ]; then
        end_step "${ICON_OK}" "Git 已安装: $(git --version 2>/dev/null | awk '{print $NF}')"
        end_step "${ICON_OK}" "ADB 已安装: $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
        return
    fi

    start_step "正在安装缺失的依赖:${_ga_missing}..."

    enable_alpine_community_repo
    _log_message "EXEC" "▶ apk update"
    if ! apk update >> "$LOGFILE" 2>&1; then
        _log_message "ERROR" "✗ apk update 失败"
        end_step "${ICON_ERROR}" "依赖更新错误，详情请阅读日志：${LOGFILE}" "${RED}"
        exit 1
    fi
    _log_message "OK" "✓ apk update 完成"
    # shellcheck disable=SC2086
    _log_message "EXEC" "▶ apk add --no-cache${_ga_missing}"
    # shellcheck disable=SC2086
    if ! apk add --no-cache ${_ga_missing} >> "$LOGFILE" 2>&1; then
        _log_message "ERROR" "✗ apk add 失败"
        end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
        exit 1
    fi
    if command -v update-ca-certificates >/dev/null 2>&1; then
        _log_exec "更新 CA 证书" update-ca-certificates || true
    fi

    end_step "${ICON_OK}" "Git 已安装: $(git --version 2>/dev/null | awk '{print $NF}')"
    end_step "${ICON_OK}" "ADB 已安装: $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
    _log_message "OK" "✓ 依赖安装完成"
}

# ---------------------------- 第3步: 克隆仓库 ----------------------------
clone_alas() {
    start_step "正在克隆 ALAS 仓库..."

    WORK_DIR="${INSTALL_DIR}"
    if [ -d "${WORK_DIR}"  ]; then
    origin_url=""
        if [ -d "${WORK_DIR}/.git"  ]; then
            origin_url=$(git -C "${WORK_DIR}" remote get-url origin 2>/dev/null || true)
        fi

        case "${origin_url}" in
            *AzurLaneAutoScript*)
            _log_message "WARNING" "ALAS 仓库已存在，跳过克隆: ${WORK_DIR}"
            end_step "${ICON_WARN}" "ALAS 仓库已存在，跳过克隆" "${YELLOW}"
            cd "${WORK_DIR}"
            ALAS_DIR="${WORK_DIR}"
            return
            ;;
        esac

        _log_message "ERROR" "安装目录已存在，但不是 AzurLaneAutoScript 仓库: ${WORK_DIR}"
        end_step "${ICON_ERROR}" "安装目录已存在且不是 ALAS 仓库，请更换 --dir 或手动处理" "${RED}"
        exit 1
    fi

    REPO_URL="https://github.com/LmeSzinc/AzurLaneAutoScript.git"
    _log_message "EXEC" "▶ git clone ${GH_PROXY}${REPO_URL} ${WORK_DIR}"

    if ! git clone "${GH_PROXY}${REPO_URL}" "${WORK_DIR}" >> "$LOGFILE" 2>&1; then
        end_step "${ICON_ERROR}" "仓库克隆错误，详情请阅读日志：${LOGFILE}" "${RED}"
        exit 1
    fi
    cd "${WORK_DIR}"
    ALAS_DIR="${WORK_DIR}"

    _log_message "OK" "ALAS 目录: ${ALAS_DIR}"
    end_step "${ICON_OK}" "ALAS 仓库已克隆"
}

# ---------------------------- 第4步: 配置虚拟环境 ----------------------------
setup_pixi_env() {
    start_step "正在配置 Pixi 虚拟环境..."

    cd "${ALAS_DIR}"
    backup_file_once "pixi.toml"

    # 生成最小化 pixi.toml：只保留 conda 系统/科学包，去掉 [pypi-dependencies]
    # 原因：cnocr(pip) 要求 numpy<1.20，av(conda) 要求 numpy>=1.20，无法共存。
    # 解决：pixi 只建 conda 基础环境，ALAS 启动时自己 pip install headless/requirements.txt。
    _log_message "EXEC" "▶ 生成 pixi.toml (conda-only 模式)"
    cat > pixi.toml << 'PIXI_EOF'
[workspace]
channels = ["conda-forge"]
name = "alas"
platforms = ["linux-64"]
version = "0.1.0"

[tasks]
start = "python gui.py"

[dependencies]
libglib = "*"
libgomp = "*"
libgl = "*"
xorg-libsm = "*"
xorg-libxrender = "*"
xorg-libxext = "*"
python = "==3.7.6"
av = ">=8.0.3,<9"
numpy = "==1.21.6"
scipy = "==1.4.1"
pillow = "*"
opencv = "*"
imageio = "==2.27.0"
wrapt = "==1.13.1"
retrying = "*"
lz4 = "*"
psutil = "==5.9.3"
rich = "==11.2.0"
tqdm = "*"
pyyaml = "*"
inflection = "*"
prettytable = "==2.2.1"
pycryptodome = "==3.9.9"
starlette = "==0.14.2"
pyzmq = "==22.3.0"
aiofiles = "*"
uvicorn = "==0.17.6"
httptools = "*"
uvloop = "*"
websockets = "*"
h11 = "*"
python-dotenv = "*"
requests = "*"

[pypi-dependencies]
anyio = "==1.3.1"
adbutils = "==0.11.0"
uiautomator2 = "==2.16.17"
uiautomator2cache = "==0.3.0.1"
onepush = "==1.4.0"
pypresence = "==4.2.1"
cnocr = "==1.2.3"
mxnet = "==1.6.0"
jellyfish = "==0.11.2"
pydantic = "*"
pywebio = "==1.6.2"
zerorpc = "==0.6.3"
alas-webapp = "==0.3.7"
PIXI_EOF
    _log_message "OK" "✓ pixi.toml 已生成"

    if [ "${USE_CN_MIRROR}" = true ]; then
    cernet_conda="https://mirrors.cernet.edu.cn/anaconda"
    cernet_pypi="https://mirrors.cernet.edu.cn/pypi/web/simple"

        _log_message "EXEC" "▶ 配置国内镜像源 (cernet)"
    cernet_channel="${cernet_conda}/cloud/conda-forge/"
        sed -i "s|channels = \\[\"conda-forge\"\\]|channels = [\"${cernet_channel}\"]|" pixi.toml
        cat >> pixi.toml << PIXI_EOF
[pypi-options]
index-url = "${cernet_pypi}"
PIXI_EOF
        _log_message "OK" "✓ 国内镜像源已配置至 pixi.toml"
    fi

    if [ -d ".pixi/envs/default" || -d ".pixi/envs/alas" || -f "pixi.lock"  ]; then
        _log_message "WARNING" "检测到已有 Pixi 环境，正在清理..."
        _log_exec "清理 Pixi 缓存" pixi clean cache -y || true
        _log_exec "清理 Pixi 环境 (方法1: pixi clean --environment default)" pixi clean --environment default || \
        _log_exec "清理 Pixi 环境 (方法2: pixi clean)" pixi clean || \
        _log_exec "清理 Pixi 环境 (方法3: rm -rf .pixi pixi.lock)" rm -rf .pixi pixi.lock
        _log_message "OK" "✓ 旧环境已清理"
    fi

    if is_alpine; then
        export CONDA_OVERRIDE_GLIBC="${CONDA_OVERRIDE_GLIBC:-${ALPINE_GLIBC_OVERRIDE}}"
        _log_message "INFO" "Alpine 已设置 CONDA_OVERRIDE_GLIBC=${CONDA_OVERRIDE_GLIBC}"
        ensure_alpine_glibc_loader || {
            end_step "${ICON_ERROR}" "Alpine glibc 兼容层不足，请检查 gcompat" "${RED}"
            exit 1
        }
    fi
    pixi_install_log="/tmp/pixi_install_$$.log"
    pixi_install_attempt=1
    while true; do
        _log_message "EXEC" "▶ pixi install --manifest-path pixi.toml (第 ${pixi_install_attempt} 次)"
        if pixi install --manifest-path pixi.toml > "${pixi_install_log}" 2>&1; then
            cat "${pixi_install_log}" >> "$LOGFILE" 2>/dev/null || true
            rm -f "${pixi_install_log}"
            break
        fi

        cat "${pixi_install_log}" >> "$LOGFILE" 2>/dev/null || true
        if [ "${ALPINE_GLIBC_AUTO_RETRY}" = true ] && [ "${ALPINE_GLIBC_RETRY_DONE}" != true ] && \
           pixi_install_needs_real_glibc "${pixi_install_log}"; then
            _log_message "WARNING" "gcompat 无法启动 conda linux-64 Python，自动切换到第三方 glibc 并重试"
            end_step "${ICON_WARN}" "gcompat 不足，正在安装第三方 glibc 后自动重试" "${YELLOW}"
            rm -f "${pixi_install_log}"
            ALPINE_GLIBC_RETRY_DONE=true
            install_alpine_real_glibc
            _log_exec "清理失败的 Pixi 环境" pixi clean --environment default || \
            _log_exec "清理失败的 Pixi 环境 (rm -rf)" rm -rf .pixi pixi.lock
            pixi_install_attempt=$((pixi_install_attempt + 1))
            start_step "正在重新配置 Pixi 虚拟环境..."
            continue
        fi

        diagnose_pixi_install_failure "${pixi_install_log}"
        rm -f "${pixi_install_log}"
        exit 1
    done

    if ! verify_pixi_python_prefix; then
        exit 1
    fi
    end_step "${ICON_OK}" "虚拟环境已构建"
}

# ---------------------------- 第5步: 配置 config/deploy.yaml ----------------------------
configure_deploy() {
    start_step "正在配置 ALAS (config/deploy.yaml)..."

    cd "${ALAS_DIR}"
    backup_file_once "config/deploy.yaml"

    # ── 选择官方模板：CN 优先用 CN 模板，否则用标准 Linux 模板 ─────────────
    base_tmpl
    if [ "${USE_CN_MIRROR}" = true ] && [ -f "config/deploy.template-linux-cn.yaml" ]; then
        base_tmpl="config/deploy.template-linux-cn.yaml"
    elif [ -f "config/deploy.template-linux.yaml"  ]; then
        base_tmpl="config/deploy.template-linux.yaml"
    else
        end_step "${ICON_WARN}" "未找到官方模板文件，跳过 deploy.yaml 配置" "${YELLOW}"
        return
    fi

    _log_message "EXEC" "▶ 使用官方模板: ${base_tmpl}"
    cp "${base_tmpl}" config/deploy.yaml
    _log_message "OK" "✓ 已复制: ${base_tmpl} → config/deploy.yaml"

    # ── 自动探测可执行文件路径 ─────────────────────────────────────────────
    adb_path git_path
    adb_path=$(command -v adb 2>/dev/null || echo "/usr/bin/adb")
    git_path=$(command -v git 2>/dev/null || echo "/usr/bin/git")

    # AdbExecutable: 使用系统实际 adb 路径
    sed -i "s|AdbExecutable:.*|AdbExecutable: ${adb_path}|" config/deploy.yaml
    _log_message "OK" "✓ AdbExecutable  → ${adb_path}"

    # GitExecutable: 使用系统实际 git 路径
    sed -i "s|GitExecutable:.*|GitExecutable: ${git_path}|" config/deploy.yaml
    _log_message "OK" "✓ GitExecutable  → ${git_path}"

    # PythonExecutable: pixi run 激活后 python 在 PATH 中，保持 'python' 即可
    sed -i "s|PythonExecutable:.*|PythonExecutable: python|" config/deploy.yaml
    _log_message "OK" "✓ PythonExecutable → python  (via pixi 虚拟环境)"

    # WebuiHost: 服务器/PVE CT 部署必须监听所有网卡
    sed -i "s|WebuiHost:.*|WebuiHost: 0.0.0.0|" config/deploy.yaml
    _log_message "OK" "✓ WebuiHost      → 0.0.0.0  (服务器模式，局域网可访问)"

    # ── CN 镜像额外修正（若使用标准模板且 -t cn）─────────────────────────
    if [ "${USE_CN_MIRROR}" = true ] && echo "${base_tmpl}" | grep -q 'linux.yaml'; then
        sed -i "s|Repository:.*github.*|Repository: git://git.lyoko.io/AzurLaneAutoScript|" config/deploy.yaml
        _log_message "OK" "✓ Repository     → git://git.lyoko.io/AzurLaneAutoScript (CN 镜像)"
        sed -i "s|PypiMirror: null|PypiMirror: https://mirrors.aliyun.com/pypi/simple|" config/deploy.yaml
        _log_message "OK" "✓ PypiMirror     → mirrors.aliyun.com/pypi/simple"
        sed -i "s|Language:.*|Language: zh-CN|" config/deploy.yaml
        _log_message "OK" "✓ Language       → zh-CN"
    fi

    # ── 打印关键配置摘要 ───────────────────────────────────────────────────
    _log_message "INFO" "── deploy.yaml 关键配置 ──────────────────────────"
    key
    for key in Repository PythonExecutable AdbExecutable GitExecutable \
                WebuiHost WebuiPort Language PypiMirror RequirementsFile; do
    val
        val=$(grep -E "^\s+${key}:" config/deploy.yaml 2>/dev/null | head -1 | sed 's/.*: *//')
        [ -n "${val}" ] && _log_message "INFO" "  ${key}: ${val}"
    done

    end_step "${ICON_OK}" "deploy.yaml 已配置（官方模板 + 环境自适应）"
}

# ---------------------------- 第6步: 开机自启服务（OpenRC）----------------------------
_configure_openrc() {
    start_step "正在配置 OpenRC 开机自启 (Alpine)..."
    _log_message "EXEC" "▶ 生成 /etc/init.d/run_alas"
    _log_message "INFO" "  用户: ${USER_NAME}, 组: ${USER_GROUP}"
    _log_message "INFO" "  工作目录: ${ALAS_DIR}"
    _log_message "INFO" "  启动命令: ${PIXI_BIN_PATH} run start"
    cat > /etc/init.d/run_alas <<EOF
#!/sbin/openrc-run

name="ALAS Auto Script"
description="AzurLaneAutoScript"
command="${PIXI_BIN_PATH}"
command_args="run start"
command_user="${USER_NAME}:${USER_GROUP}"
directory="${ALAS_DIR}"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background=true

depend() {
    need net
    after firewall
}
EOF
    chmod 755 /etc/init.d/run_alas
    _log_message "OK" "✓ OpenRC 服务脚本已创建"
    _log_message "EXEC" "▶ rc-update add run_alas default"
    rc-update add run_alas default >> "$LOGFILE" 2>&1
    _log_message "OK" "✓ 已加入 default runlevel"
    _log_message "EXEC" "▶ rc-service run_alas start"
    if rc-service run_alas start >> "$LOGFILE" 2>&1; then
        end_step "${ICON_OK}" "OpenRC 服务已启动并设为开机自启"
    else
        end_step "${ICON_WARN}" "OpenRC 已注册开机自启，但容器内首次启动失败（容器重启后将自动运行）" "${YELLOW}"
    fi
}

configure_service() {
    if [ "${SKIP_SERVICE}" = true ]; then
        _log_message "INFO" "已跳过服务配置 (--skip-service)"
        end_step "${ICON_INFO}" "已跳过服务配置"
        return
    fi
    PIXI_BIN_PATH=$(command -v pixi)
    if command -v rc-service >/dev/null 2>&1; then
        _configure_openrc
    else
        log_warn "未检测到 OpenRC，跳过服务配置，请手动配置开机自启"
    fi
}

# ---------------------------- 创建启动脚本 ----------------------------
create_startup_script() {
    script_path="${ALAS_DIR}/run_alas.sh"
    _log_message "EXEC" "▶ 创建启动脚本: ${script_path}"
    cat > "${script_path}" <<EOF
#!/bin/bash
# ALAS 启动脚本 (由 pixi_alas_install.sh 自动生成)
# 用法: bash ${script_path}
cd "${ALAS_DIR}" || exit 1
exec "${PIXI_BIN_PATH}" run start
EOF
    chmod +x "${script_path}"
    _log_message "OK" "✓ 启动脚本已创建: ${script_path}"
}

# ---------------------------- 完成摘要 ----------------------------
print_completion() {
    echo_line ""
    echo_line "  ${ICON_ROCKET}  ${GREEN}ALAS 安装完成！${NC}"
    echo_line "  ─────────────────────────────────────────────────"
    echo_line "  ${ICON_INFO}  WebUI 地址  : ${CYAN}http://${NET_IP}:22267${NC}"
    echo_line "  ${ICON_INFO}  手动启动    : ${CYAN}bash ${ALAS_DIR}/run_alas.sh${NC}"
    echo_line "  ${ICON_INFO}  安装目录    : ${BLUE}${ALAS_DIR}${NC}"
    echo_line ""
}

# ---------------------------- 反向安装（卸载） ----------------------------
do_uninstall() {
    echo_line ""
    echo_line "  ${ICON_WARN}  ${YELLOW}即将执行 ALAS 卸载，将删除以下内容：${NC}"
    echo_line "  ${ICON_WARN}  ${YELLOW}  - 开机自启服务${NC}"
    echo_line "  ${ICON_WARN}  ${YELLOW}  - Pixi 虚拟环境${NC}"
    echo_line "  ${ICON_WARN}  ${YELLOW}  - ALAS 目录: ${INSTALL_DIR}${NC}"
    echo_line "  ${ICON_WARN}  ${YELLOW}  - 启动脚本: ${SCRIPT_OUT_DIR}/run_alas.sh${NC}"
    echo_line "  ${ICON_INFO}  ${GREEN}  Git, ADB, Pixi 不会被删除${NC}"
    echo_line ""
    _log_message "WARNING" "等待确认卸载"
    while true; do
        printf "  确认继续吗？ [yes/N] ："
        read -r CONFIRM < /dev/tty
        case "${CONFIRM}" in
            yes|YES)
                _log_message "INFO" "已确认卸载"
                break ;;
            no|NO|n|N)
                _log_message "INFO" "卸载取消"
                echo_line "  ${ICON_INFO}  已取消卸载"; exit 0 ;;
            *)
                echo_line "  ${ICON_WARN}  无效输入，请输入 yes 或 N" "${YELLOW}" ;;
        esac
    done

    echo_line ""

    start_step "正在停止 ALAS 服务..."
    if command -v rc-service >/dev/null 2>&1; then
        rc-service run_alas stop >> "$LOGFILE" 2>&1 || true
        _log_message "OK" "✓ 服务已停止"
        rc-update del run_alas default >> "$LOGFILE" 2>&1 || true
        _log_message "OK" "✓ 服务已从 runlevel 移除"
        if [ -f /etc/init.d/run_alas  ]; then
            _log_message "EXEC" "▶ 删除 OpenRC 服务脚本"
            rm -f /etc/init.d/run_alas
            _log_message "OK" "✓ OpenRC 服务脚本已删除"
        fi
    fi
    end_step "${ICON_OK}" "服务已停止并移除"

    start_step "正在清理 Pixi 虚拟环境..."
    cd "${INSTALL_DIR}"
    if [ -d ".pixi" || -f "pixi.lock"  ]; then
        _log_message "EXEC" "▶ 清理 Pixi 环境"
        _log_exec "清理 Pixi 环境 (方法1: pixi clean --environment default)" pixi clean --environment default || \
        _log_exec "清理 Pixi 环境 (方法2: pixi clean)" pixi clean || \
        _log_exec "清理 Pixi 环境 (方法3: rm -rf .pixi pixi.lock)" rm -rf .pixi pixi.lock
    else
        _log_message "INFO" "未检测到 Pixi 环境，跳过清理"
    fi
    end_step "${ICON_OK}" "虚拟环境已清理"

    start_step "正在删除 ALAS 目录..."
    _log_message "EXEC" "▶ rm -rf ${INSTALL_DIR}"
    rm -rf "${INSTALL_DIR}"
    end_step "${ICON_OK}" "目录已删除"

    start_step "正在删除启动脚本..."
    _run_script="${INSTALL_DIR}/run_alas.sh"
    _log_message "EXEC" "▶ rm -f ${_run_script}"
    rm -f "${_run_script}"
    end_step "${ICON_OK}" "启动脚本已删除"

    if [ "${KEEP_LOG}" = false ]; then
        _log_message "INFO" "清理日志文件: ${LOGFILE}"
        rm -f "$LOGFILE"
    fi
    echo_line ""
    echo_line "${ICON_OK}  ${GREEN}ALAS 卸载完成${NC}"
    echo_line ""
}

# ---------------------------- 主流程 ----------------------------
main() {
    if [ "${UNINSTALL}" = true ]; then
        detect_os
        gather_system_info
        print_header
        do_uninstall
        exit 0
    fi
    detect_os
    gather_system_info
    print_header
    install_git_adb
    prepare_alpine_glibc_compat
    install_pixi
    clone_alas
    setup_pixi_env
    configure_deploy
    configure_service
    create_startup_script
    print_completion
    if [ "${KEEP_LOG}" = false ]; then
        _log_message "INFO" "安装完成，清理日志文件: ${LOGFILE}"
        rm -f "$LOGFILE"
    else
        echo_line "  ${ICON_INFO}  日志已保存至：${LOGFILE}"
    fi
}
main
