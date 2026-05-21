#!/bin/sh
#==============================================================================
# AzurLaneAutoScript Conda 一键部署脚本 (POSIX 版)
# 特性：
#   - 纯 POSIX sh 兼容 (ash, busybox sh, dash)
#   - 支持多发行版 (Debian/Ubuntu, Arch, Fedora, RHEL, openSUSE, Alpine)
#   - 支持多 init 系统 (systemd, OpenRC, SysVinit)
#   - 静默执行，系统信息面板，步骤反馈
#   - 国内镜像加速 (-t cn)，开机自启
#==============================================================================
# 用法: sh posix_conda_alas_install.sh [-t cn] [-S] [-d DIR] [-l] [--uninstall [-Y]]
#       sh posix_conda_alas_install.sh -h  # 查看完整帮助

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

if date "+%3N" >/dev/null 2>&1; then
    _LOG_DATEFMT='%H:%M:%S.%3N'
fi

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
GH_PROXY=""
DEPLOY_TEMPLATE="config/deploy.template-linux.yaml"
INSTALL_DIR="${HOME}/AzurLaneAutoScript"
SCRIPT_OUT_DIR="${HOME}/AzurLaneAutoScript"
WORK_DIR=""
ALAS_DIR=""
CONDA_BIN=""
USER_NAME="${SUDO_USER:-$(whoami)}"
USER_GROUP=$(id -gn "${USER_NAME}" 2>/dev/null || id -gn 2>/dev/null || echo "${USER_NAME}")
INIT_SYSTEM=""
PACKAGE_MANAGER=""
_SPINNER_PID=""
RAM_SIZE_MIB=""
ALPINE_GLIBC_LOADER="/lib64/ld-linux-x86-64.so.2"
UNINSTALL_YES=false

# ---------------------------- 帮助 ----------------------------
usage() {
    cat <<EOF
用法: sh $0 [选项]

选项:
  -d, --dir DIR          指定 ALAS 安装目录 (默认: ~/AzurLaneAutoScript)
  -s, --script-dir DIR   指定启动脚本输出目录 (默认: ~/AzurLaneAutoScript)
  -t TEMPLATE            控制使用的 deploy 模板与国内镜像源
  -S, --skip-service     跳过开机自启服务配置
  --uninstall [-Y]       反向安装：停止并删除 ALAS、虚拟环境、开机自启
  -l, --log              保留安装日志，不自动删除
  -h, --help             显示帮助信息
EOF
}

# ---------------------------- 输出与日志函数 ----------------------------
echo_line() {
    printf '%b\n' "$1"
}

log_out() {
    _lo_icon="$1"
    _lo_color="$2"
    _lo_msg="$3"
    echo_line "  ${_lo_icon}  ${_lo_color}${_lo_msg}${NC}"
    _lo_level="INFO"
    case "$_lo_icon" in
        "${ICON_OK}")    _lo_level="OK"      ;;
        "${ICON_WARN}")  _lo_level="WARNING" ;;
        "${ICON_ERROR}") _lo_level="ERROR"   ;;
    esac
    _log_message "${_lo_level}" "${_lo_msg}"
}

log_info()    { log_out "${ICON_INFO}"  "${GREEN}"  "$1"; }
log_ok()      { log_out "${ICON_OK}"   "${GREEN}"  "$1"; }
log_warn()    { log_out "${ICON_WARN}"  "${YELLOW}" "$1"; }
log_error()   { log_out "${ICON_ERROR}" "${RED}"    "$1"; }

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
    _es_icon="$1"
    _es_msg="$2"
    _es_color="${3:-${GREEN}}"
    _cleanup_spinner
    printf "\r${_es_icon}  ${_es_color}%s${NC}\033[K\n" "$_es_msg"
    _es_level="INFO"
    case "$_es_icon" in
        "${ICON_OK}")    _es_level="OK"      ;;
        "${ICON_WARN}")  _es_level="WARNING" ;;
        "${ICON_ERROR}") _es_level="ERROR"   ;;
    esac
    _log_message "${_es_level}" "${_es_msg}"
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
            case "$2" in
                [Cc][Nn])
                DEPLOY_TEMPLATE="config/deploy.template-linux-cn.yaml"
                USE_CN_MIRROR=true
                GH_PROXY="https://ghfast.top/"
                shift 2 ;;
            *)
                DEPLOY_TEMPLATE="$2"
                shift 2 ;;
            esac ;;
        --uninstall)
            UNINSTALL=true
            case "${2-}" in
                -Y|-y|--yes) UNINSTALL_YES=true; shift ;;
            esac
            shift ;;
        -l|--log) KEEP_LOG=true; shift ;;
        -S|--skip-service) SKIP_SERVICE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "未知参数: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------- 检测 init 系统 ----------------------------
detect_init_system() {
    if command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
        _log_message "INFO" "检测到 init 系统: systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
        _log_message "INFO" "检测到 init 系统: OpenRC"
    elif command -v service >/dev/null 2>&1 && [ -d /etc/init.d ]; then
        INIT_SYSTEM="sysvinit"
        _log_message "INFO" "检测到 init 系统: SysVinit"
    else
        INIT_SYSTEM="unknown"
        _log_message "WARNING" "无法检测 init 系统，将跳过服务配置"
    fi
}

# ---------------------------- 权限检查 ----------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        _log_message "ERROR" "请使用 root 权限运行 (sudo sh $0)"
        echo_line "  ${ICON_ERROR}  ${RED}请使用 root 权限运行 (sudo sh $0)${NC}"
        exit 1
    fi
}

# ---------------------------- 系统信息收集 ----------------------------
gather_system_info() {
    # 优先用 ip 命令（Alpine/BusyBox hostname -I 不一定可用）
    NET_IP=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -z "${NET_IP}" ] && NET_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "${NET_IP}" ]; then
        NET_IP="未获取"
    fi
    KERNEL=$(uname -r)
    # lscpu 在 Alpine 不一定可用，回退到 /proc/cpuinfo
    if command -v lscpu >/dev/null 2>&1; then
        CPU_MODEL=$(lscpu | grep -i "Model name" | sed 's/.*:\s*//' | xargs || echo "未知")
    else
        CPU_MODEL=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | sed 's/.*: //' | xargs || echo "未知")
    fi
    CPU_CORES=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")
    # 磁盘信息：通过匹配挂载点 / 定位数据行，从行尾反向取列，
    _gs_disk_used=""
    _gs_disk_avail=""
    # 方法1: df -h（人类可读）
    _gs_df_inner=$(df -h / 2>/dev/null | awk '$NF == "/" {print $(NF-3), $(NF-2)}')
    if [ -n "${_gs_df_inner}" ]; then
        _gs_disk_used=$(echo "${_gs_df_inner}" | awk '{print $1}')
        _gs_disk_avail=$(echo "${_gs_df_inner}" | awk '{print $2}')
    fi
    # 方法2: df -P（POSIX 标准，1K 块）
    if [ -z "${_gs_disk_avail}" ]; then
        _gs_df_inner=$(df -P / 2>/dev/null | awk '$NF == "/" {print $(NF-3), $(NF-2)}')
        if [ -n "${_gs_df_inner}" ]; then
            _gs_disk_used=$(echo "${_gs_df_inner}" | awk '{print $1}')
            _gs_disk_avail=$(echo "${_gs_df_inner}" | awk '{print $2}')
        fi
    fi
    # 方法3: df（默认格式，1K 块）
    if [ -z "${_gs_disk_avail}" ]; then
        _gs_df_inner=$(df / 2>/dev/null | awk '$NF == "/" {print $(NF-3), $(NF-2)}')
        if [ -n "${_gs_df_inner}" ]; then
            _gs_disk_used=$(echo "${_gs_df_inner}" | awk '{print $1}')
            _gs_disk_avail=$(echo "${_gs_df_inner}" | awk '{print $2}')
        fi
    fi
    # 将 1K 块数值转换为可读格式（非数值原样保留，如 df -h 的 "4.7G"）
    if [ -n "${_gs_disk_used}" ]; then
        if echo "${_gs_disk_used}" | grep -qE '^[0-9]+$'; then
            DISK_USED=$(awk -v v="${_gs_disk_used}" 'BEGIN{if(v>=1048576) printf "%.1fG",v/1048576; else if(v>=1024) printf "%.1fM",v/1024; else printf "%dK",v}')
        else
            DISK_USED="${_gs_disk_used}"
        fi
    else
        DISK_USED="?"
    fi
    if [ -n "${_gs_disk_avail}" ]; then
        if echo "${_gs_disk_avail}" | grep -qE '^[0-9]+$'; then
            DISK_AVAIL=$(awk -v v="${_gs_disk_avail}" 'BEGIN{if(v>=1048576) printf "%.1fG",v/1048576; else if(v>=1024) printf "%.1fM",v/1024; else printf "%dK",v}')
        else
            DISK_AVAIL="${_gs_disk_avail}"
        fi
    else
        DISK_AVAIL="?"
    fi
    DISK_INFO="可用: ${DISK_AVAIL}  已用: ${DISK_USED}"

    # 内存大小：优选 /proc/meminfo（Linux 内核接口，不受容器 cgroup 偏差影响）
    RAM_SIZE_MIB=""
    RAM_SIZE_MIB=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || true)
    if [ -z "${RAM_SIZE_MIB}" ] || [ "${RAM_SIZE_MIB}" = "0" ]; then
        if [ -r /sys/fs/cgroup/memory.max ]; then
            _gs_cg_mem=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
            if [ "${_gs_cg_mem}" != "max" ] && [ -n "${_gs_cg_mem}" ]; then
                RAM_SIZE_MIB=$(( _gs_cg_mem / 1048576 ))
            fi
        elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
            _gs_cg_mem=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
            if [ -n "${_gs_cg_mem}" ] && [ "${_gs_cg_mem}" -lt 1099511627776 ]; then
                RAM_SIZE_MIB=$(( _gs_cg_mem / 1048576 ))
            fi
        fi
    fi
    if [ -z "${RAM_SIZE_MIB}" ]; then
        RAM_SIZE_MIB=$(free -m 2>/dev/null | awk '/Mem:/{print $2}' || \
                       awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
    fi
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
    echo_line "  ${ICON_COMPUTER}  X86-64 Linux 中基于 Conda 的 ALAS 部署脚本"
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
    _do_kernel_name=$(uname -s 2>/dev/null || true)
    case "${_do_kernel_name}" in
        FreeBSD|OpenBSD|NetBSD)
            _log_message "ERROR" "非 Linux 内核 (${_do_kernel_name})，Unix 系统请手动安装"
            echo_line "  ${ICON_ERROR}  ${RED}非 Linux 内核 (${_do_kernel_name})，Unix 系统请手动安装${NC}"
            exit 1 ;;
        Linux) ;;
        *)
            _log_message "ERROR" "不支持的操作系统: ${_do_kernel_name}"
            echo_line "  ${ICON_ERROR}  ${RED}不支持的操作系统: ${_do_kernel_name}${NC}"
            exit 1 ;;
    esac

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-}"
        if [ -z "${OS_VERSION}" ]; then
            OS_VERSION="${BUILD_ID:-}"
        fi
        if [ -z "${OS_VERSION}" ]; then
            OS_VERSION="${VERSION:-}"
        fi
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS_ID=$(printf '%s' "${DISTRIB_ID:-}" | tr '[:upper:]' '[:lower:]')
        OS_VERSION="${DISTRIB_RELEASE:-}"
    elif [ -f /etc/debian_version ]; then
        OS_ID="debian"
        OS_VERSION=$(cat /etc/debian_version 2>/dev/null)
    elif [ -f /etc/redhat-release ]; then
        OS_ID="rhel"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release 2>/dev/null || echo "unknown")
    elif [ -f /etc/centos-release ]; then
        OS_ID="centos"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/centos-release 2>/dev/null || echo "unknown")
    elif [ -f /etc/fedora-release ]; then
        OS_ID="fedora"
        OS_VERSION=$(grep -oE '[0-9]+' /etc/fedora-release 2>/dev/null || echo "unknown")
    elif [ -f /etc/arch-release ]; then
        OS_ID="arch"
        OS_VERSION="rolling"
    elif [ -f /etc/alpine-release ]; then
        OS_ID="alpine"
        OS_VERSION=$(cat /etc/alpine-release 2>/dev/null)
    elif [ -f /etc/SuSE-release ]; then
        OS_ID="opensuse"
        OS_VERSION=$(sed -n 's/.*VERSION = \([0-9.]*\).*/\1/p' /etc/SuSE-release 2>/dev/null || echo "unknown")
    else
        _log_message "ERROR" "无法检测 Linux 发行版，请检查 /etc/os-release"
        echo_line "  ${ICON_ERROR}  ${RED}无法检测 Linux 发行版，请检查 /etc/os-release${NC}"
        exit 1
    fi
}

# ---------------------------- 安装/激活 Miniforge ----------------------------
install_miniforge() {
    start_step "正在检查 Miniforge..."

    CONDA_BIN="${HOME}/miniforge3/bin/conda"
    if command -v conda >/dev/null 2>&1; then
        CONDA_VER=$(conda --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        CONDA_BIN=$(command -v conda)
        end_step "${ICON_OK}" "Conda 已就绪: ${CONDA_VER}"
        return
    fi

    if [ -x "${CONDA_BIN}" ]; then
        CONDA_VER=$("${CONDA_BIN}" --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Conda 已安装: ${CONDA_VER}"
        return
    fi

    _log_message "ERROR" "未检测到 Conda"
    start_step "正在安装 Miniforge..."
    _log_message "EXEC" "▶ 下载 Miniforge3-Linux-x86_64.sh"
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 \
        -o /tmp/Miniforge3-Linux-x86_64.sh \
        "${GH_PROXY}https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh" >> "$LOGFILE" 2>&1; then
        end_step "${ICON_ERROR}" "Miniforge 下载错误，详情请阅读日志：${LOGFILE}" "${RED}"
        exit 1
    fi
    _log_message "OK" "✓ Miniforge 下载完成"

    _log_message "EXEC" "▶ 安装 Miniforge"
    prepare_alpine_conda_runtime
    if ! bash /tmp/Miniforge3-Linux-x86_64.sh -b -p "${HOME}/miniforge3" >> "$LOGFILE" 2>&1; then
        end_step "${ICON_ERROR}" "Miniforge 安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
        rm -f /tmp/Miniforge3-Linux-x86_64.sh
        exit 1
    fi
    _log_message "OK" "✓ Miniforge 安装完成"
    rm -f /tmp/Miniforge3-Linux-x86_64.sh

    if [ -x "${CONDA_BIN}" ]; then
        CONDA_VER=$("${CONDA_BIN}" --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Miniforge 已安装: ${CONDA_VER}"
    else
        _log_message "ERROR" "Miniforge 安装后未找到 conda 可执行文件"
        end_step "${ICON_ERROR}" "Miniforge 安装失败，请查看日志: ${LOGFILE}" "${RED}"
        exit 1
    fi
}

# ---------------------------- 包管理器检测 ----------------------------
detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PACKAGE_MANAGER="apt"
    elif command -v pacman >/dev/null 2>&1; then
        PACKAGE_MANAGER="pacman"
    elif command -v dnf >/dev/null 2>&1; then
        PACKAGE_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PACKAGE_MANAGER="yum"
    elif command -v zypper >/dev/null 2>&1; then
        PACKAGE_MANAGER="zypper"
    elif command -v apk >/dev/null 2>&1; then
        PACKAGE_MANAGER="apk"
    else
        PACKAGE_MANAGER="unknown"
    fi
    _log_message "INFO" "检测到包管理器: ${PACKAGE_MANAGER}"
}

# ---------------------------- 国内镜像安装 ----------------------------
cn_package_mirrors() {
    case "${PACKAGE_MANAGER}" in
        apt)
            _cm_codename=$(lsb_release -sc 2>/dev/null)
            if [ -z "${_cm_codename}" ]; then
                _cm_codename=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-stable}")
            fi
            if [ "${OS_ID}" = "debian" ]; then
                _cm_dist_path="debian/"
                _cm_components="main contrib non-free"
            else
                _cm_dist_path="ubuntu/"
                _cm_components="main universe"
            fi
            for _cm_mirror in \
                "https://mirrors.ustc.edu.cn/${_cm_dist_path}" \
                "https://mirrors.aliyun.com/${_cm_dist_path}" \
                "https://repo.huaweicloud.com/${_cm_dist_path}"; do
                cat > "/tmp/alas-apt-$$.list" <<EOF
deb ${_cm_mirror} ${_cm_codename} ${_cm_components}
deb ${_cm_mirror} ${_cm_codename}-updates ${_cm_components}
EOF
                if [ "${OS_ID}" = "debian" ]; then
                    _cm_sec_mirror=$(printf '%s' "${_cm_mirror}" | sed 's|/debian/|/debian-security/|')
                    printf 'deb %s %s %s\n' "${_cm_sec_mirror}" "${_cm_codename}-security" "${_cm_components}" >> "/tmp/alas-apt-$$.list"
                else
                    printf 'deb %s %s %s\n' "${_cm_mirror}" "${_cm_codename}-security" "${_cm_components}" >> "/tmp/alas-apt-$$.list"
                fi
                _log_message "INFO" "尝试镜像: ${_cm_mirror}"
                if apt-get -o Dir::Etc::sourcelist="/tmp/alas-apt-$$.list" \
                            -o Dir::Etc::sourceparts="-" \
                            -o APT::Get::List-Cleanup="0" \
                            -qq update >> "$LOGFILE" 2>&1; then
                    if apt-get -o Dir::Etc::sourcelist="/tmp/alas-apt-$$.list" \
                               -o Dir::Etc::sourceparts="-" \
                               -qq install -y "$@" >> "$LOGFILE" 2>&1; then
                        rm -f "/tmp/alas-apt-$$.list"
                        return 0
                    fi
                fi
                rm -f "/tmp/alas-apt-$$.list"
                _log_message "WARNING" "镜像 ${_cm_mirror} 不可用，尝试下一个"
            done
            return 1
            ;;
        pacman)
            for _cm_mirror in \
                "https://mirrors.ustc.edu.cn/archlinux/\$repo/os/\$arch" \
                "https://mirrors.aliyun.com/archlinux/\$repo/os/\$arch" \
                "https://repo.huaweicloud.com/archlinux/\$repo/os/\$arch"; do
                echo "Server = ${_cm_mirror}" > "/tmp/alas-mirrorlist-$$"
                sed "s|^Include = /etc/pacman.d/mirrorlist|Include = /tmp/alas-mirrorlist-$$|g" \
                    /etc/pacman.conf > "/tmp/alas-pacman-$$.conf"
                _log_message "INFO" "尝试镜像: ${_cm_mirror}"
                if pacman --config "/tmp/alas-pacman-$$.conf" -Syy --noconfirm "$@" >> "$LOGFILE" 2>&1; then
                    rm -f "/tmp/alas-pacman-$$.conf" "/tmp/alas-mirrorlist-$$"
                    return 0
                fi
                rm -f "/tmp/alas-pacman-$$.conf" "/tmp/alas-mirrorlist-$$"
                _log_message "WARNING" "镜像 ${_cm_mirror} 不可用，尝试下一个"
            done
            return 1
            ;;
        dnf)
            if [ "${OS_ID}" = "fedora" ]; then
                _cm_dnf_base="fedora/linux/releases/\$releasever/Everything/\$basearch/os/"
            else
                _cm_dnf_base="centos/\$releasever/BaseOS/\$basearch/os/"
            fi
            for _cm_mirror in \
                "https://mirrors.ustc.edu.cn/${_cm_dnf_base}" \
                "https://mirrors.aliyun.com/${_cm_dnf_base}" \
                "https://repo.huaweicloud.com/${_cm_dnf_base}"; do
                _log_message "INFO" "尝试镜像: ${_cm_mirror}"
                if dnf --disablerepo='*' --repofrompath="cn-temp-$$,${_cm_mirror}" --enablerepo="cn-temp-$$" \
                       -q makecache >> "$LOGFILE" 2>&1; then
                    if dnf --disablerepo='*' --repofrompath="cn-temp-$$,${_cm_mirror}" --enablerepo="cn-temp-$$" \
                           -q install -y "$@" >> "$LOGFILE" 2>&1; then
                        return 0
                    fi
                fi
                _log_message "WARNING" "镜像 ${_cm_mirror} 不可用，尝试下一个"
            done
            return 1
            ;;
        apk)
            _cm_alpine_ver=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo "latest-stable")
            for _cm_mirror in \
                "https://mirrors.ustc.edu.cn/alpine/v${_cm_alpine_ver}/main" \
                "https://mirrors.ustc.edu.cn/alpine/v${_cm_alpine_ver}/community" \
                "https://mirrors.aliyun.com/alpine/v${_cm_alpine_ver}/main" \
                "https://mirrors.aliyun.com/alpine/v${_cm_alpine_ver}/community" \
                "https://repo.huaweicloud.com/alpine/v${_cm_alpine_ver}/main" \
                "https://repo.huaweicloud.com/alpine/v${_cm_alpine_ver}/community"; do
                _log_message "INFO" "尝试镜像: ${_cm_mirror}"
                if apk add --no-cache --repository="${_cm_mirror}" "$@" >> "$LOGFILE" 2>&1; then
                    return 0
                fi
                _log_message "WARNING" "镜像 ${_cm_mirror} 不可用，尝试下一个"
            done
            return 1
            ;;
        zypper)
            _cm_zypp_ver=$(sed -n 's/.*VERSION_ID="\?\([^"]*\).*/\1/p' /etc/os-release 2>/dev/null || echo "15.6")
            for _cm_mirror in \
                "https://mirrors.ustc.edu.cn/opensuse/distribution/leap/${_cm_zypp_ver}/repo/oss/" \
                "https://mirrors.aliyun.com/opensuse/distribution/leap/${_cm_zypp_ver}/repo/oss/" \
                "https://repo.huaweicloud.com/opensuse/distribution/leap/${_cm_zypp_ver}/repo/oss/"; do
                _log_message "INFO" "尝试镜像: ${_cm_mirror}"
                if zypper --non-interactive --no-gpg-checks --plus-repo "${_cm_mirror}" \
                       install -y "$@" >> "$LOGFILE" 2>&1; then
                    return 0
                fi
                _log_message "WARNING" "镜像 ${_cm_mirror} 不可用，尝试下一个"
            done
            return 1
            ;;
        *)
            _log_message "ERROR" "CN 镜像不支持包管理器: ${PACKAGE_MANAGER}"
            return 1
            ;;
    esac
}

# ---------------------------- Alpine 专用：确保 glibc loader ----------------------------
ensure_alpine_glibc_loader() {
    if [ -e "${ALPINE_GLIBC_LOADER}" ]; then
        _log_message "OK" "glibc loader 已存在: ${ALPINE_GLIBC_LOADER}"
        return 0
    fi

    for _eg_candidate in /usr/glibc-compat/lib/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2; do
        if [ -e "${_eg_candidate}" ]; then
            mkdir -p /lib64 /lib

            if [ "${_eg_candidate}" != "${ALPINE_GLIBC_LOADER}" ]; then
                ln -sf "${_eg_candidate}" "${ALPINE_GLIBC_LOADER}"
            fi

            if [ "${_eg_candidate}" != "/lib/ld-linux-x86-64.so.2" ]; then
                ln -sf "${_eg_candidate}" /lib/ld-linux-x86-64.so.2 2>/dev/null || true
            fi

            if [ -e "${ALPINE_GLIBC_LOADER}" ]; then
                _log_message "OK" "已创建 glibc loader 兼容链接: ${ALPINE_GLIBC_LOADER} -> ${_eg_candidate}"
                return 0
            fi
        fi
    done

    _log_message "ERROR" "未找到 glibc loader，Conda 的 linux-64 Python 可能无法启动"
    return 1
}

# ---------------------------- Alpine 专用：安装第三方 glibc（sgerrand v2.34）----------------------------
install_alpine_real_glibc() {
    _ir_glibc_ver="2.34-r0"
    _log_message "INFO" "正在安装 Alpine 第三方 glibc 兼容包..."
    _log_message "WARNING" "将安装 sgerrand/alpine-pkg-glibc (${_ir_glibc_ver})，用于运行 conda linux-64 Python"

    if apk info -e glibc >/dev/null 2>&1 && has_real_glibc; then
        _log_message "OK" "第三方 glibc 已存在"
        return
    fi

    if apk info -e gcompat >/dev/null 2>&1; then
        _log_message "EXEC" "▶ 移除 gcompat 以避免与 glibc loader 冲突"
        apk del gcompat >> "$LOGFILE" 2>&1 || true
    fi

    _ir_tmp_dir="/tmp/alas_glibc_$$"
    _ir_key_file="/etc/apk/keys/sgerrand.rsa.pub"
    _ir_key_url="https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub"
    _ir_key_fallback="https://raw.githubusercontent.com/sgerrand/alpine-pkg-glibc/master/sgerrand.rsa.pub"
    _ir_release_url="https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${_ir_glibc_ver}"
    _ir_glibc_apk="${_ir_tmp_dir}/glibc-${_ir_glibc_ver}.apk"
    _ir_glibc_bin_apk="${_ir_tmp_dir}/glibc-bin-${_ir_glibc_ver}.apk"

    mkdir -p "${_ir_tmp_dir}" /etc/apk/keys /lib64 /lib

    _log_message "EXEC" "▶ 下载 sgerrand APK 签名 key"
    if ! curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
            -o "${_ir_key_file}" "${_ir_key_url}" >> "$LOGFILE" 2>&1; then
        _log_message "WARNING" "sgerrand 官方源不可用，尝试 GitHub raw fallback"
        if ! curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
                -o "${_ir_key_file}" "${_ir_key_fallback}" >> "$LOGFILE" 2>&1; then
            rm -rf "${_ir_tmp_dir}"
            end_step "${ICON_ERROR}" "第三方 glibc key 下载失败" "${RED}"
            exit 1
        fi
    fi

    _log_message "EXEC" "▶ 下载 glibc APK: ${_ir_glibc_ver}"
    if ! curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
            -o "${_ir_glibc_apk}" "${GH_PROXY}${_ir_release_url}/glibc-${_ir_glibc_ver}.apk" >> "$LOGFILE" 2>&1 || \
       ! curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
            -o "${_ir_glibc_bin_apk}" "${GH_PROXY}${_ir_release_url}/glibc-bin-${_ir_glibc_ver}.apk" >> "$LOGFILE" 2>&1; then
        rm -rf "${_ir_tmp_dir}"
        end_step "${ICON_ERROR}" "第三方 glibc APK 下载失败: ${_ir_release_url}" "${RED}"
        exit 1
    fi

    _log_message "EXEC" "▶ apk add --force-overwrite glibc"
    if ! apk add --force-overwrite "${_ir_glibc_apk}" "${_ir_glibc_bin_apk}" >> "$LOGFILE" 2>&1; then
        rm -rf "${_ir_tmp_dir}"
        end_step "${ICON_ERROR}" "第三方 glibc 安装失败，详情请查看日志: ${LOGFILE}" "${RED}"
        exit 1
    fi

    rm -rf "${_ir_tmp_dir}"

    ensure_alpine_glibc_loader || {
        end_step "${ICON_ERROR}" "第三方 glibc 安装后仍缺少 loader" "${RED}"
        exit 1
    }

    has_real_glibc || {
        end_step "${ICON_ERROR}" "第三方 glibc 安装完成，但真实 glibc 校验失败" "${RED}"
        exit 1
    }

    _log_message "OK" "第三方 glibc 安装完成"
}

# ---------------------------- Alpine 专用：检测真实 glibc ----------------------------
has_real_glibc() {
    if [ -x /usr/glibc-compat/bin/getconf ]; then
        /usr/glibc-compat/bin/getconf GNU_LIBC_VERSION >/dev/null 2>&1 && return 0
    fi

    if command -v getconf >/dev/null 2>&1; then
        getconf GNU_LIBC_VERSION >/dev/null 2>&1 && return 0
    fi

    if [ -x /usr/glibc-compat/lib/libc.so.6 ]; then
        /usr/glibc-compat/lib/libc.so.6 2>&1 | grep -qi 'GNU C Library' && return 0
    fi

    return 1
}

# ---------------------------- Alpine 专用：准备 Conda 运行环境 ----------------------------
prepare_alpine_conda_runtime() {
    if [ "${PACKAGE_MANAGER}" != "apk" ]; then
        return 0
    fi
    _log_message "INFO" "正在准备 Alpine Conda 运行环境..."

    if apk info -e gcompat >/dev/null 2>&1; then
        _log_message "EXEC" "▶ 移除 gcompat，避免与真实 glibc 冲突"
        apk del gcompat >> "$LOGFILE" 2>&1 || {
            end_step "${ICON_ERROR}" "gcompat 移除失败，请先手动执行: apk del gcompat" "${RED}"
            exit 1
        }
    fi

    if ! has_real_glibc; then
        install_alpine_real_glibc || {
            end_step "${ICON_ERROR}" "Alpine glibc 安装失败" "${RED}"
            exit 1
        }
    fi

    has_real_glibc || {
        end_step "${ICON_ERROR}" "未检测到真实 glibc，不能继续安装 Miniforge" "${RED}"
        exit 1
    }

    ensure_alpine_glibc_loader || {
        end_step "${ICON_ERROR}" "未检测到 glibc loader: ${ALPINE_GLIBC_LOADER}" "${RED}"
        exit 1
    }

    command -v bash >/dev/null 2>&1 || {
        end_step "${ICON_ERROR}" "未检测到 bash，Miniforge 安装器不能使用 BusyBox sh 执行" "${RED}"
        exit 1
    }
}

# ---------------------------- 检查依赖 ----------------------------
install_deps() {
    start_step "正在检查依赖..."

    detect_package_manager

    _id_missing=""

    case "${PACKAGE_MANAGER}" in
        apt)
            for _id_pkg in curl git adb; do
                if dpkg -s "$_id_pkg" >/dev/null 2>&1; then
                    _log_message "OK" "依赖已存在: ${_id_pkg}"
                else
                    _log_message "WARNING" "依赖缺失: ${_id_pkg}"
                    _id_missing="${_id_missing} ${_id_pkg}"
                fi
            done ;;
        pacman)
            for _id_pkg in curl git android-tools; do
                if pacman -Q "$_id_pkg" >/dev/null 2>&1; then
                    _log_message "OK" "依赖已存在: ${_id_pkg}"
                else
                    _log_message "WARNING" "依赖缺失: ${_id_pkg}"
                    _id_missing="${_id_missing} ${_id_pkg}"
                fi
            done ;;
        dnf|yum|zypper)
            for _id_pkg in curl git adb; do
                if rpm -q "$_id_pkg" >/dev/null 2>&1; then
                    _log_message "OK" "依赖已存在: ${_id_pkg}"
                else
                    _log_message "WARNING" "依赖缺失: ${_id_pkg}"
                    _id_missing="${_id_missing} ${_id_pkg}"
                fi
            done ;;
        apk)
            for _id_pkg in git android-tools curl ca-certificates tar gzip xz bzip2 zstd bash libstdc++ libgcc coreutils; do
                if apk info -e "$_id_pkg" >/dev/null 2>&1; then
                    _log_message "OK" "依赖已存在: ${_id_pkg}"
                else
                    _log_message "WARNING" "依赖缺失: ${_id_pkg}"
                    _id_missing="${_id_missing} ${_id_pkg}"
                fi
            done ;;
        *)
            end_step "${ICON_ERROR}" "不支持的包管理器: ${PACKAGE_MANAGER}" "${RED}"
            exit 1 ;;
    esac

    if [ -z "${_id_missing}" ]; then
        prepare_alpine_conda_runtime
        _log_message "OK" "✓ curl $(curl --version 2>/dev/null | head -n1 | awk '{print $2}')"
        _log_message "OK" "✓ Git $(git --version 2>/dev/null | awk '{print $NF}')"
        _log_message "OK" "✓ ADB $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
        if [ "${PACKAGE_MANAGER}" = "apk" ]; then
            _log_message "OK" "✓ tar $(tar --version 2>/dev/null | head -1 | awk '{print $NF}')"
            _log_message "OK" "✓ xz $(xz --version 2>/dev/null | head -1 | awk '{print $NF}')"
            _log_message "OK" "✓ ca-certificates $(apk info -v ca-certificates 2>/dev/null | sed 's/^ca-certificates-//' || echo '✓')"
            _log_message "OK" "✓ libstdc++ $(apk info -v libstdc++ 2>/dev/null | sed 's/^libstdc++-//' || echo '✓')"
            _log_message "OK" "✓ libgcc $(apk info -v libgcc 2>/dev/null | sed 's/^libgcc-//' || echo '✓')"
        fi
        end_step "${ICON_OK}" "依赖检查完成"
        return
    fi

    start_step "正在安装缺失的依赖:${_id_missing}..."

    _cn_fallback=false
    if [ "${USE_CN_MIRROR}" = true ]; then
        _log_message "EXEC" "▶ ${PACKAGE_MANAGER} (CN mirrors)${_id_missing}"
        # shellcheck disable=SC2086
        if cn_package_mirrors ${_id_missing}; then
            _log_message "OK" "✓ CN 镜像安装完成"
        else
            _log_message "WARNING" "CN 镜像全部不可用，自动回退官方源"
            _cn_fallback=true
        fi
    fi
    if [ "${USE_CN_MIRROR}" != true ] || [ "${_cn_fallback}" = true ]; then
        case "${PACKAGE_MANAGER}" in
            apt)
                _log_message "EXEC" "▶ apt-get update"
                if ! apt-get -qq update >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ apt-get update 失败"
                    end_step "${ICON_ERROR}" "依赖更新错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi
                _log_message "OK" "✓ apt-get update 完成"
                _log_message "EXEC" "▶ apt-get install -y${_id_missing}"
                # shellcheck disable=SC2086
                if ! apt-get -qq install -y ${_id_missing} >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ apt-get install 失败"
                    end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi ;;
            pacman)
                _log_message "EXEC" "▶ pacman -Syy --noconfirm${_id_missing}"
                # shellcheck disable=SC2086
                if ! pacman -Syy --noconfirm ${_id_missing} >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ pacman 安装失败"
                    end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi ;;
            dnf)
                _log_message "EXEC" "▶ dnf makecache"
                if ! dnf -q makecache >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ dnf makecache 失败"
                    end_step "${ICON_ERROR}" "依赖更新错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi
                _log_message "OK" "✓ dnf makecache 完成"
                _log_message "EXEC" "▶ dnf install -y${_id_missing}"
                # shellcheck disable=SC2086
                if ! dnf -q install -y ${_id_missing} >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ dnf install 失败"
                    end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi ;;
            yum)
                _log_message "EXEC" "▶ yum install -y${_id_missing}"
                # shellcheck disable=SC2086
                if ! yum -q install -y ${_id_missing} >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ yum install 失败"
                    end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi ;;
            zypper)
                _log_message "EXEC" "▶ zypper --non-interactive refresh"
                if ! zypper --non-interactive refresh >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ zypper refresh 失败"
                    end_step "${ICON_ERROR}" "依赖更新错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi
                _log_message "OK" "✓ zypper refresh 完成"
                _log_message "EXEC" "▶ zypper --non-interactive install -y${_id_missing}"
                # shellcheck disable=SC2086
                if ! zypper --non-interactive install -y ${_id_missing} >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ zypper install 失败"
                    end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi ;;
            apk)
                _log_message "EXEC" "▶ apk add --no-cache${_id_missing}"
                # shellcheck disable=SC2086
                if ! apk add --no-cache ${_id_missing} >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ apk add 失败"
                    end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi ;;
        esac
    fi

    prepare_alpine_conda_runtime

    _log_message "OK" "✓ curl $(curl --version 2>/dev/null | head -n1 | awk '{print $2}')"
    _log_message "OK" "✓ Git $(git --version 2>/dev/null | awk '{print $NF}')"
    _log_message "OK" "✓ ADB $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
    if [ "${PACKAGE_MANAGER}" = "apk" ]; then
        _log_message "OK" "✓ tar $(tar --version 2>/dev/null | head -1 | awk '{print $NF}')"
        _log_message "OK" "✓ xz $(xz --version 2>/dev/null | head -1 | awk '{print $NF}')"
        _log_message "OK" "✓ ca-certificates $(apk info -v ca-certificates 2>/dev/null | sed 's/^ca-certificates-//' || echo '✓')"
        _log_message "OK" "✓ libstdc++ $(apk info -v libstdc++ 2>/dev/null | sed 's/^libstdc++-//' || echo '✓')"
        _log_message "OK" "✓ libgcc $(apk info -v libgcc 2>/dev/null | sed 's/^libgcc-//' || echo '✓')"
    fi
    end_step "${ICON_OK}" "依赖检查完成"
}

# ---------------------------- 克隆仓库 ----------------------------
clone_alas() {
    start_step "正在克隆 ALAS 仓库..."

    WORK_DIR="${INSTALL_DIR}"
    if [ -d "${WORK_DIR}" ]; then
        _ca_origin_url=""
        if [ -d "${WORK_DIR}/.git" ]; then
            _ca_origin_url=$(git -C "${WORK_DIR}" remote get-url origin 2>/dev/null || true)
        fi

        case "${_ca_origin_url}" in
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

# ---------------------------- 配置虚拟环境 ----------------------------
setup_conda_env() {
    start_step "正在配置 Conda 虚拟环境..."

    cd "${ALAS_DIR}"
    if [ -f environment.yml ]; then
        _log_message "EXEC" "▶ 备份已有 environment.yml → environment.yml.bak"
        cp environment.yml environment.yml.bak
        _log_message "OK" "✓ 备份完成"
    fi

    _log_message "EXEC" "▶ 生成 environment.yml"
    cat > environment.yml << 'YML_EOF'
name: alas
channels:
  - conda-forge
platforms:
  - linux-64
dependencies:
  - libglib
  - libgomp
  - libgl
  - xorg-libsm
  - xorg-libxrender
  - xorg-libxext
  - python=3.7.6
  - av>=8.0.3,<9
  - numpy=1.16.6
  - scipy=1.4.1
  - pillow
  - psutil=5.9.3
  - pyyaml
  - tqdm
  - lz4
  - pyzmq=22.3.0
  - pip:
    - opencv-python==4.5.5.62
    - imageio==2.27.0
    - adbutils==0.11.0
    - uiautomator2==2.16.17
    - uiautomator2cache==0.3.0.1
    - wrapt==1.13.1
    - retrying==1.3.3
    - rich==11.2.0
    - jellyfish==0.11.2
    - inflection==0.5.1
    - pydantic==1.9.2
    - aiofiles==0.8.0
    - prettytable==2.2.1
    - anyio==1.3.1
    - onepush==1.4.0
    - pycryptodome==3.9.9
    - pypresence==4.2.1
    - cnocr==1.2.2
    - mxnet==1.6.0
    - pywebio==1.6.2
    - starlette==0.14.2
    - uvicorn==0.17.6
    - websockets==10.4
    - alas-webapp==0.3.7
    - zerorpc==0.6.3
YML_EOF
    _log_message "OK" "✓ environment.yml 已生成"

    . "$(dirname "$(dirname "${CONDA_BIN}")")/etc/profile.d/conda.sh" >> "$LOGFILE" 2>&1
    _log_message "OK" "✓ Conda shell 已加载 (POSIX)"

    if [ "${USE_CN_MIRROR}" = true ]; then
        _se_cernet_conda="https://mirrors.cernet.edu.cn/anaconda"
        _se_cernet_pypi="https://mirrors.cernet.edu.cn/pypi/web/simple"

        _log_message "EXEC" "▶ 配置国内镜像源 (cernet)"
        conda config --prepend channels "${_se_cernet_conda}/cloud/conda-forge/" >> "$LOGFILE" 2>&1
        conda config --prepend channels "${_se_cernet_conda}/pkgs/main/" >> "$LOGFILE" 2>&1

        export PIP_INDEX_URL="${_se_cernet_pypi}"
        export PIP_TRUSTED_HOST="mirrors.cernet.edu.cn"
        export PIP_TIMEOUT=60
        _log_message "OK" "✓ 国内镜像源已配置"
    fi

    if conda env list 2>/dev/null | grep -q "^alas "; then
        _log_message "WARNING" "检测到已有 alas 环境，正在移除..."
        _log_exec "移除旧环境 (方法1: conda env remove)" conda env remove -n alas -y || \
        _log_exec "移除旧环境 (方法2: rm -rf)" rm -rf "$(conda info --base 2>/dev/null)/envs/alas"
        _log_message "OK" "✓ 旧环境已移除"
    fi

    _se_install_log="/tmp/conda_install_$$.log"
    _se_install_attempt=1
    _se_cn_fallback_done=false
    while true; do
        _log_message "EXEC" "▶ conda env create -f environment.yml (第 ${_se_install_attempt} 次，这可能需要较长时间)"
        if conda env create -f environment.yml > "${_se_install_log}" 2>&1; then
            cat "${_se_install_log}" >> "$LOGFILE" 2>/dev/null || true
            rm -f "${_se_install_log}"
            break
        fi

        cat "${_se_install_log}" >> "$LOGFILE" 2>/dev/null || true
        if [ "${USE_CN_MIRROR}" = true ] && [ "${_se_cn_fallback_done}" != true ] && \
           grep -Eqi '403|403 Forbidden|HTTP.*403' "${_se_install_log}" 2>/dev/null; then
            _log_message "WARNING" "国内镜像源不可用（403 Forbidden），自动降级到官方源"
            rm -f "${_se_install_log}"
            _se_cn_fallback_done=true
            conda config --remove channels "https://mirrors.cernet.edu.cn/anaconda/cloud/conda-forge/" >> "$LOGFILE" 2>&1 || true
            conda config --remove channels "https://mirrors.cernet.edu.cn/anaconda/pkgs/main/" >> "$LOGFILE" 2>&1 || true
            unset PIP_INDEX_URL
            conda env remove -n alas -y >> "$LOGFILE" 2>&1 || true
            _se_install_attempt=$((_se_install_attempt + 1))
            continue
        fi

        end_step "${ICON_ERROR}" "虚拟环境构建错误，详情请阅读日志：${LOGFILE}" "${RED}"
        rm -f "${_se_install_log}"
        exit 1
    done
    _log_message "OK" "✓ conda env create 完成"

    unset PIP_INDEX_URL

    _log_message "EXEC" "▶ 验证环境: python -c 'import alas_webapp'"
    if ! conda run -n alas python -c "import alas_webapp" >> "$LOGFILE" 2>&1; then
        _log_message "WARNING" "⚠ 依赖完整性检查未通过，尝试修复..."
        conda env update -n alas --file environment.yml >> "$LOGFILE" 2>&1 || true
        _log_message "OK" "✓ 依赖修复完成"
    else
        _log_message "OK" "✓ 依赖完整性检查通过"
    fi
    end_step "${ICON_OK}" "虚拟环境已构建"
}

# ---------------------------- 配置 config/deploy.yaml ----------------------------
configure_deploy() {
    start_step "配置 config/deploy.yaml"

    cd "${ALAS_DIR}"
    if [ -f config/deploy.yaml ]; then
        _log_message "EXEC" "▶ 备份已有 deploy.yaml → deploy.yaml.bak"
        cp config/deploy.yaml config/deploy.yaml.bak
        _log_message "OK" "✓ 备份完成"
    fi

    TEMPLATE="${DEPLOY_TEMPLATE}"

    if [ -f "${TEMPLATE}" ]; then
        _log_message "EXEC" "▶ cp ${TEMPLATE} config/deploy.yaml"
        cp "${TEMPLATE}" config/deploy.yaml
        end_step "${ICON_OK}" "cp ${TEMPLATE} config/deploy.yaml"
    else
        end_step "${ICON_WARN}" "模板文件 ${TEMPLATE} 不存在，请手动执行 cp ${TEMPLATE} config/deploy.yaml" "${YELLOW}"
    fi
}

# ---------------------------- 创建启动脚本 ----------------------------
create_launcher() {
    start_step "正在生成启动脚本..."

    _log_message "EXEC" "▶ 生成 ${SCRIPT_OUT_DIR}/run_alas.sh"
    _log_message "INFO" "  Conda: ${CONDA_BIN}"
    _log_message "INFO" "  ALAS 目录: ${ALAS_DIR}"

    cat > "${SCRIPT_OUT_DIR}/run_alas.sh" <<EOF
#!/bin/sh
# ALAS 启动脚本 (由 posix_conda_alas_install.sh 自动生成)
# 用法: sh ${SCRIPT_OUT_DIR}/run_alas.sh
. "$(dirname "$(dirname "${CONDA_BIN}")")/etc/profile.d/conda.sh"
conda activate alas
cd ${ALAS_DIR}
python gui.py
EOF
    chmod +x "${SCRIPT_OUT_DIR}/run_alas.sh"
    end_step "${ICON_OK}" "启动脚本已生成: ${SCRIPT_OUT_DIR}/run_alas.sh"
}

# ---------------------------- 配置 init 服务 ----------------------------
configure_service() {
    if [ "${SKIP_SERVICE}" = true ]; then
        end_step "${ICON_INFO}" "检测到 -S、--skip-service 已跳过服务配置"
        return
    fi

    if [ "${INIT_SYSTEM}" = "unknown" ]; then
        end_step "${ICON_WARN}" "未检测到 init 系统，跳过服务配置" "${YELLOW}"
        return
    fi

    if [ "${INIT_SYSTEM}" = "systemd" ]; then
        _configure_systemd
    elif [ "${INIT_SYSTEM}" = "openrc" ]; then
        _configure_openrc
    elif [ "${INIT_SYSTEM}" = "sysvinit" ]; then
        _configure_sysvinit
    fi
}

_configure_systemd() {
    start_step "正在配置 systemd 开机自启..."

    _log_message "EXEC" "▶ 生成 /etc/systemd/system/run_alas.service"
    _log_message "INFO" "  用户: ${USER_NAME}, 组: ${USER_GROUP}"
    _log_message "INFO" "  工作目录: ${ALAS_DIR}"
    _log_message "INFO" "  启动命令: ${SCRIPT_OUT_DIR}/run_alas.sh"

    cat > /etc/systemd/system/run_alas.service <<EOF
[Unit]
Description=ALAS Auto Script
After=network.target
Wants=network-online.target

[Service]
User=${USER_NAME}
Group=${USER_GROUP}
WorkingDirectory=${ALAS_DIR}
ExecStart=${SCRIPT_OUT_DIR}/run_alas.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    _log_message "OK" "✓ 服务单元文件已创建"
    chmod 644 /etc/systemd/system/run_alas.service

    _log_message "EXEC" "▶ systemctl daemon-reload"
    systemctl daemon-reload >> "$LOGFILE" 2>&1
    _log_message "OK" "✓ daemon-reload 完成"

    _log_message "EXEC" "▶ systemctl enable run_alas.service"
    systemctl enable run_alas.service >> "$LOGFILE" 2>&1
    _log_message "OK" "✓ 服务已启用开机自启"

    _log_message "EXEC" "▶ systemctl start run_alas.service"
    systemctl start run_alas.service >> "$LOGFILE" 2>&1
    _log_message "OK" "✓ 服务已启动"

    if systemctl is-active --quiet run_alas.service 2>/dev/null; then
        end_step "${ICON_OK}" "systemd 服务已启动并设为开机自启"
    else
        end_step "${ICON_ERROR}" "systemd 服务启动失败，请查看日志: ${LOGFILE}" "${RED}"
    fi
}

_configure_openrc() {
    start_step "正在配置 OpenRC 开机自启..."

    _log_message "EXEC" "▶ 生成 /etc/init.d/run_alas"
    _log_message "INFO" "  用户: ${USER_NAME}, 组: ${USER_GROUP}"
    _log_message "INFO" "  工作目录: ${ALAS_DIR}"
    _log_message "INFO" "  启动命令: ${SCRIPT_OUT_DIR}/run_alas.sh"

    cat > /etc/init.d/run_alas <<EOF
#!/sbin/openrc-run

name="ALAS Auto Script"
description="AzurLaneAutoScript"
command="${SCRIPT_OUT_DIR}/run_alas.sh"
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
    _log_message "OK" "✓ 服务已添加至 default 运行级"

    _log_message "EXEC" "▶ rc-service run_alas start"
    rc-service run_alas start >> "$LOGFILE" 2>&1
    _log_message "OK" "✓ 服务已启动"

    if rc-service run_alas status >/dev/null 2>&1; then
        end_step "${ICON_OK}" "OpenRC 服务已启动并设为开机自启"
    else
        end_step "${ICON_WARN}" "OpenRC 已注册开机自启，但容器内首次启动失败（容器重启后将自动运行）" "${YELLOW}"
    fi
}

_configure_sysvinit() {
    start_step "正在配置 SysVinit 开机自启..."

    _log_message "EXEC" "▶ 生成 /etc/init.d/run_alas"
    _log_message "INFO" "  用户: ${USER_NAME}, 组: ${USER_GROUP}"
    _log_message "INFO" "  工作目录: ${ALAS_DIR}"
    _log_message "INFO" "  启动命令: ${SCRIPT_OUT_DIR}/run_alas.sh"

    cat > /etc/init.d/run_alas <<'SYSV_EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          run_alas
# Required-Start:    $network $remote_fs
# Required-Stop:     $network $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ALAS Auto Script
### END INIT INFO

case "$1" in
    start)
        echo "Starting ALAS..."
        start-stop-daemon --start --background --make-pidfile \
            --pidfile /var/run/run_alas.pid \
            --chdir DIR_PLACEHOLDER \
            --user USER_PLACEHOLDER \
            --exec SCRIPT_PLACEHOLDER
        ;;
    stop)
        echo "Stopping ALAS..."
        start-stop-daemon --stop --pidfile /var/run/run_alas.pid
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    status)
        if kill -0 "$(cat /var/run/run_alas.pid 2>/dev/null)" 2>/dev/null; then
            echo "ALAS is running"
        else
            echo "ALAS is not running"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
exit 0
SYSV_EOF

    sed -i "s|DIR_PLACEHOLDER|${ALAS_DIR}|g" /etc/init.d/run_alas
    sed -i "s|USER_PLACEHOLDER|${USER_NAME}|g" /etc/init.d/run_alas
    sed -i "s|SCRIPT_PLACEHOLDER|${SCRIPT_OUT_DIR}/run_alas.sh|g" /etc/init.d/run_alas
    chmod 755 /etc/init.d/run_alas
    _log_message "OK" "✓ SysVinit 服务脚本已创建"

    if command -v update-rc.d >/dev/null 2>&1; then
        _log_message "EXEC" "▶ update-rc.d run_alas defaults"
        update-rc.d run_alas defaults >> "$LOGFILE" 2>&1
    elif command -v chkconfig >/dev/null 2>&1; then
        _log_message "EXEC" "▶ chkconfig --add run_alas"
        chkconfig --add run_alas >> "$LOGFILE" 2>&1
    fi
    _log_message "OK" "✓ 服务已注册"

    _log_message "EXEC" "▶ service run_alas start"
    if service run_alas start >> "$LOGFILE" 2>&1; then
        end_step "${ICON_OK}" "SysVinit 服务已启动并设为开机自启"
    else
        end_step "${ICON_ERROR}" "SysVinit 服务启动失败，请查看日志: ${LOGFILE}" "${RED}"
    fi
}

# ---------------------------- 完成摘要 ----------------------------
print_completion() {
    echo_line ""
    echo_line "${ICON_ROCKET}  ${GREEN}ALAS 已经完成安装，请通过 ${CYAN}http://${NET_IP}:22267${NC} ${GREEN}访问 WEBUI${NC}"
    echo_line "  ─────────────────────────────────────────────────"
    echo_line "  ${ICON_INFO}  ALAS已安装到:  ${BLUE}${ALAS_DIR}${NC}"

    if [ "${SKIP_SERVICE}" = true ]; then
        echo_line "  ${ICON_INFO}  手动启动:  ${CYAN}sh ${SCRIPT_OUT_DIR}/run_alas.sh${NC}"
    else
        echo_line ""
        echo_line "  ${ICON_INFO}  服务管理命令: "
        case "${INIT_SYSTEM}" in
            systemd)
                echo_line "      启动服务:  ${CYAN}systemctl start run_alas.service${NC}"
                echo_line "      停止服务:  ${CYAN}systemctl stop run_alas.service${NC}"
                echo_line "      重启服务:  ${CYAN}systemctl restart run_alas.service${NC}"
                echo_line "      检查状态:  ${CYAN}systemctl status run_alas.service${NC}"
                ;;
            openrc)
                echo_line "      启动服务:  ${CYAN}rc-service run_alas start${NC}"
                echo_line "      停止服务:  ${CYAN}rc-service run_alas stop${NC}"
                echo_line "      重启服务:  ${CYAN}rc-service run_alas restart${NC}"
                echo_line "      检查状态:  ${CYAN}rc-service run_alas status${NC}"
                ;;
            sysvinit)
                echo_line "      启动服务:  ${CYAN}service run_alas start${NC}"
                echo_line "      停止服务:  ${CYAN}service run_alas stop${NC}"
                echo_line "      重启服务:  ${CYAN}service run_alas restart${NC}"
                echo_line "      检查状态:  ${CYAN}service run_alas status${NC}"
                ;;
        esac
    fi
}

# ---------------------------- 反向安装（卸载） ----------------------------
do_uninstall() {
    echo_line ""
    echo_line "  ${ICON_WARN}  ${YELLOW}即将执行 ALAS 卸载，将删除以下内容：${NC}"
    echo_line "  ${ICON_WARN}  ${YELLOW}  - 开机自启服务${NC}"
    echo_line "  ${ICON_WARN}  ${YELLOW}  - Conda 虚拟环境 (alas)${NC}"
    echo_line "  ${ICON_WARN}  ${YELLOW}  - ALAS 目录: ${INSTALL_DIR}${NC}"
    echo_line "  ${ICON_WARN}  ${YELLOW}  - 启动脚本: ${SCRIPT_OUT_DIR}/run_alas.sh${NC}"
    echo_line "  ${ICON_INFO}  ${GREEN}  Git, ADB, Miniforge 不会被删除${NC}"
    echo_line ""
    _log_message "WARNING" "等待确认卸载"
    if [ "${UNINSTALL_YES}" = true ]; then
        _log_message "INFO" "已通过 -Y 自动确认卸载"
    elif [ "${OS_ID}" = "alpine" ]; then
        echo_line "  ${ICON_ERROR}  ${RED}脚本无法读取终端输入，请使用静默方式运行卸载${NC}"
        exit 1
    else
        while true; do
            printf "  确认继续吗？ [yes/N] ："
            if [ -c /dev/tty ] && [ -r /dev/tty ]; then
                read -r CONFIRM < /dev/tty
            else
                read -r CONFIRM || {
                    echo_line "  ${ICON_ERROR}  ${RED}脚本无法读取终端输入，请使用静默方式运行卸载${NC}"
                    exit 1
                }
            fi
            CONFIRM=$(printf '%s' "${CONFIRM}" | tr -d '\r')
            # 去除字符串末尾的所有空白字符，等效 CONFIRM=$(printf "%s" "$CONFIRM" | sed -e 's/[[:space:]]*$//')
            CONFIRM=${CONFIRM%"${CONFIRM##*[![:space:]]}"}
            case "${CONFIRM}" in
                yes|Yes|YES)
                    _log_message "INFO" "已确认卸载"
                    break ;;
                no|NO|n|N)
                    _log_message "INFO" "卸载取消"
                    echo_line "  ${ICON_INFO}  已取消卸载"; exit 0 ;;
                *)
                    echo_line "  ${ICON_WARN}  ${YELLOW}无效输入，请输入 yes 或 N${NC}" ;;
            esac
        done
    fi

    echo_line ""

    detect_init_system

    start_step "正在停止 ALAS 服务..."
    _svc_done=false
    if [ "${INIT_SYSTEM}" = "systemd" ]; then
        if systemctl is-active --quiet run_alas.service 2>/dev/null; then
            _log_message "EXEC" "▶ systemctl stop run_alas.service"
            systemctl stop run_alas.service >> "$LOGFILE" 2>&1
            _log_message "OK" "✓ 服务已停止"
            _svc_done=true
        fi
        if systemctl is-enabled --quiet run_alas.service 2>/dev/null; then
            _log_message "EXEC" "▶ systemctl disable run_alas.service"
            systemctl disable run_alas.service >> "$LOGFILE" 2>&1
            _log_message "OK" "✓ 服务已禁用"
            _svc_done=true
        fi
        if [ -f /etc/systemd/system/run_alas.service ]; then
            _log_message "EXEC" "▶ 删除服务单元文件"
            rm -f /etc/systemd/system/run_alas.service
            systemctl daemon-reload >> "$LOGFILE" 2>&1
            _svc_done=true
        fi
    elif [ "${INIT_SYSTEM}" = "openrc" ]; then
        if command -v rc-service >/dev/null 2>&1; then
            rc-service run_alas stop >> "$LOGFILE" 2>&1 || true
            _log_message "OK" "✓ 服务已停止"
            _svc_done=true
        fi
        rc-update del run_alas default >> "$LOGFILE" 2>&1 || true
        if [ -f /etc/init.d/run_alas ]; then
            _log_message "EXEC" "▶ 删除 OpenRC 服务脚本"
            rm -f /etc/init.d/run_alas
            _svc_done=true
        fi
    elif [ "${INIT_SYSTEM}" = "sysvinit" ]; then
        service run_alas stop >> "$LOGFILE" 2>&1 || true
        _log_message "OK" "✓ 服务已停止"
        _svc_done=true
        if command -v update-rc.d >/dev/null 2>&1; then
            _log_message "EXEC" "▶ update-rc.d -f run_alas remove"
            update-rc.d -f run_alas remove >> "$LOGFILE" 2>&1 || true
        elif command -v chkconfig >/dev/null 2>&1; then
            _log_message "EXEC" "▶ chkconfig --del run_alas"
            chkconfig --del run_alas >> "$LOGFILE" 2>&1 || true
        fi
        if [ -f /etc/init.d/run_alas ]; then
            _log_message "EXEC" "▶ 删除 SysVinit 服务脚本"
            rm -f /etc/init.d/run_alas
        fi
    fi
    if [ "$_svc_done" = true ]; then
        end_step "${ICON_OK}" "服务已停止并移除"
    else
        end_step "${ICON_INFO}" "未检测到 ALAS 服务，跳过" "${GREEN}"
    fi

    start_step "正在清理 Conda 虚拟环境..."
    if command -v conda >/dev/null 2>&1; then
        CONDA_BIN=$(command -v conda)
        . "$(dirname "$(dirname "${CONDA_BIN}")")/etc/profile.d/conda.sh" >> "$LOGFILE" 2>&1
        if conda env list 2>/dev/null | grep -q "^alas "; then
            _log_message "EXEC" "▶ conda env remove -n alas"
            _log_exec "移除 Conda 环境 (方法1: conda env remove)" conda env remove -n alas -y || \
            _log_exec "移除 Conda 环境 (方法2: rm -rf)" rm -rf "$(conda info --base 2>/dev/null)/envs/alas"
        else
            _log_message "INFO" "未检测到 alas 环境，跳过"
        fi
        end_step "${ICON_OK}" "虚拟环境已清理"
    else
        end_step "${ICON_INFO}" "未检测到 Conda，跳过虚拟环境清理" "${GREEN}"
    fi

    start_step "正在删除 ALAS 目录..."
    if [ -d "${INSTALL_DIR}" ]; then
        _log_message "EXEC" "▶ rm -rf ${INSTALL_DIR}"
        rm -rf "${INSTALL_DIR}"
        end_step "${ICON_OK}" "目录已删除"
    else
        end_step "${ICON_INFO}" "ALAS 目录已不存在，跳过" "${GREEN}"
    fi

    start_step "正在删除启动脚本..."
    if [ -f "${SCRIPT_OUT_DIR}/run_alas.sh" ]; then
        _log_message "EXEC" "▶ rm -f ${SCRIPT_OUT_DIR}/run_alas.sh"
        rm -f "${SCRIPT_OUT_DIR}/run_alas.sh"
        end_step "${ICON_OK}" "启动脚本已删除"
    else
        end_step "${ICON_INFO}" "启动脚本不存在，跳过" "${GREEN}"
    fi

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
        check_root
        do_uninstall
        exit 0
    fi
    detect_os
    gather_system_info
    print_header
    check_root
    detect_init_system
    install_deps
    install_miniforge
    clone_alas
    setup_conda_env
    configure_deploy
    create_launcher
    configure_service
    print_completion
    if [ "${KEEP_LOG}" = false ]; then
        _log_message "INFO" "安装完成，清理日志文件: ${LOGFILE}"
        rm -f "$LOGFILE"
    else
        echo_line ""
        echo_line "  ${ICON_INFO}  日志已保存至：${LOGFILE}"
        echo_line ""
    fi
}
main
