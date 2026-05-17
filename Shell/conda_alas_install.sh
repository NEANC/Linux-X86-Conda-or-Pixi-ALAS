#!/bin/bash
#==============================================================================
# AzurLaneAutoScript Conda 一键部署脚本
# 特性：
#   - 静默执行，系统信息面板，步骤反馈
#==============================================================================

set -euo pipefail

# ---------------------------- 脚本目录（支持管道执行） ----------------------------
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" && "${BASH_SOURCE[0]}" != "-bash" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [[ "$0" != "bash" && "$0" != "-bash" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
else
    SCRIPT_DIR="$PWD"
fi

# ---------------------------- 日志文件 ----------------------------
LOGFILE="/tmp/alas_install.log"
touch "$LOGFILE" || { echo "无法创建日志文件 $LOGFILE"; exit 1; }

# ---------------------------- 日志格式化 ----------------------------
# 格式: LEVEL | HH:MM:SS.mmm | message
# (等效于 Python: '%(levelname)s | %(asctime)s.%(msecs)03d | %(message)s', datefmt='%H:%M:%S')
_LOG_DATEFMT='%H:%M:%S'

if date "+%3N" &>/dev/null; then
    _LOG_DATEFMT='%H:%M:%S.%3N'
fi

_log_message() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date "+${_LOG_DATEFMT}")
    echo "${level} | ${timestamp} | ${msg}" >> "$LOGFILE"
}

_log_exec() {
    local step_name="$1"
    shift
    _log_message "EXEC" "▶ ${step_name}: $*"
    "$@" >> "$LOGFILE" 2>&1
    local ret=$?
    if [[ $ret -ne 0 ]]; then
        _log_message "ERROR" "✗ ${step_name}: 命令失败 (exit ${ret})"
    else
        _log_message "OK"    "✓ ${step_name}: 命令完成"
    fi
    return $ret
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
UNINSTALL_YES=false
KEEP_LOG=false
DEPLOY_TEMPLATE="config/deploy.template-linux.yaml"
USE_CN_MIRROR=false
GH_PROXY=""
INSTALL_DIR="${HOME}/AzurLaneAutoScript"
SCRIPT_OUT_DIR="${HOME}/AzurLaneAutoScript"
WORK_DIR=""
ALAS_DIR=""
CONDA_BIN=""
USER_NAME="${SUDO_USER:-$(whoami)}"
USER_GROUP=$(id -gn "${USER_NAME}")
INIT_SYSTEM=""
PACKAGE_MANAGER=""
_SPINNER_PID=""

# ---------------------------- 帮助 ----------------------------
usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  -d, --dir DIR          指定 ALAS 安装目录 (默认: ~/AzurLaneAutoScript)
  -s, --script-dir DIR   指定脚本输出目录 (默认: ~/AzurLaneAutoScript)
  -t TEMPLATE            控制使用的 deploy 模板与国内镜像源
  -S, --skip-service     跳过 systemd 开机自启服务配置
  --uninstall [-Y]       反向安装：停止并删除 ALAS、虚拟环境、开机自启
  -l, --log              保留安装日志，不自动删除
  -h, --help             显示帮助信息
EOF
}

# ---------------------------- 输出与日志函数 ----------------------------
echo_line() {
    echo -e "$1"
}

log_out() {
    local icon="$1"
    local color="$2"
    local msg="$3"
    echo_line "  ${icon}  ${color}${msg}${NC}"
    local level="INFO"
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

# ---------------------------- 流水灯系统 ----------------------------
_cleanup_spinner() {
    if [[ -n "$_SPINNER_PID" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
        wait "$_SPINNER_PID" 2>/dev/null || true
        _SPINNER_PID=""
    fi
}

start_step() {
    _cleanup_spinner
    local msg="$1"
    _log_message "START" "${msg}"
    local spin_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local idx=0
    {
        while true; do
            printf "\r${YELLOW}%s  %s${NC}\033[K" "${spin_chars[$idx]}" "$msg"
            idx=$(( (idx + 1) % 10 ))
            sleep 0.20 2>/dev/null || true
        done
    } &
    _SPINNER_PID=$!
}

end_step() {
    local icon="$1"
    local msg="$2"
    local color="${3:-${GREEN}}"
    _cleanup_spinner
    printf "\r${icon}  ${color}%s${NC}\033[K\n" "$msg"
    local level="INFO"
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
    echo -e "\n  ${ICON_WARN}  ${YELLOW}脚本已被用户中断${NC}"
    exit 130
}
trap '_sigint_handler' INT

# ---------------------------- 错误处理 ----------------------------
error_handler() {
    _cleanup_spinner
    local line_no=$1
    local error_code=$2
    echo_line "  ${ICON_ERROR}  ${RED}脚本在第 ${line_no} 行发生错误 (错误码: ${error_code})${NC}"
    echo_line "  日志保存于: ${LOGFILE}"
    exit "${error_code}"
}
trap 'error_handler ${LINENO} $?' ERR

# ---------------------------- 参数解析 ----------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir) INSTALL_DIR="$2"; shift 2 ;;
        -s|--script-dir) SCRIPT_OUT_DIR="$2"; shift 2 ;;
        -t|--template)
            if [[ "$2" =~ ^[Cc][Nn]$ ]]; then
                DEPLOY_TEMPLATE="config/deploy.template-linux-cn.yaml"
                USE_CN_MIRROR=true
                GH_PROXY="https://ghfast.top/"
            else
                DEPLOY_TEMPLATE="$2"
            fi
            shift 2 ;;
        --uninstall)
            UNINSTALL=true
            if [[ "${2-}" == -Y || "${2-}" == -y || "${2-}" == --yes ]]; then
                UNINSTALL_YES=true
                shift
            fi
            shift ;;
        -l|--log) KEEP_LOG=true; shift ;;
        -S|--skip-service) SKIP_SERVICE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "未知参数: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------- 检测 init 系统 ----------------------------
detect_init_system() {
    if command -v systemctl &>/dev/null; then
        INIT_SYSTEM="systemd"
        _log_message "INFO" "检测到 init 系统: systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
        _log_message "INFO" "检测到 init 系统: OpenRC"
    elif command -v service &>/dev/null && [[ -d /etc/init.d ]]; then
        INIT_SYSTEM="sysvinit"
        _log_message "INFO" "检测到 init 系统: SysVinit"
    else
        INIT_SYSTEM="unknown"
        _log_message "WARNING" "无法检测 init 系统，将跳过服务配置"
    fi
}

# ---------------------------- 权限检查 ----------------------------
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        _log_message "ERROR" "请使用 root 权限运行 (sudo bash $0)"
        echo_line "  ${ICON_ERROR}  ${RED}请使用 root 权限运行 (sudo bash $0)${NC}"
        exit 1
    fi
}

# ---------------------------- 系统信息收集 ----------------------------
gather_system_info() {
    NET_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    if [[ -z "${NET_IP}" ]]; then
        NET_IP=$(ip route get 1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' || true)
    fi
    if [[ -z "${NET_IP}" ]]; then
        NET_IP="未获取"
    fi

    KERNEL=$(uname -r)

    CPU_MODEL=$(lscpu 2>/dev/null | grep "Model name" | sed 's/Model name:\s*//' || true)
    if [[ -z "${CPU_MODEL}" ]]; then
        CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || true)
    fi
    if [[ -z "${CPU_MODEL}" ]]; then
        CPU_MODEL="未知"
    fi

    CPU_CORES=$(nproc 2>/dev/null || true)
    if [[ -z "${CPU_CORES}" ]]; then
        CPU_CORES=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || true)
    fi
    if [[ -z "${CPU_CORES}" ]]; then
        CPU_CORES="未知"
    fi

    DISK_AVAIL=$(df -h / 2>/dev/null | awk 'NR==2{print $4}' || true)
    DISK_USED=$(df -h / 2>/dev/null | awk 'NR==2{print $3}' || true)
    DISK_INFO="可用: ${DISK_AVAIL}  已用: ${DISK_USED}"

    RAM_SIZE_MIB=$(free -m 2>/dev/null | awk '/Mem:/{print $2}' || true)
    if [[ -z "${RAM_SIZE_MIB}" ]]; then
        RAM_SIZE_MIB=$(awk '/MemTotal:/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || true)
    fi
    if [[ -z "${RAM_SIZE_MIB}" ]]; then
        RAM_SIZE_MIB="未知"
    fi
    return 0
}

# ---------------------------- 打印标题与系统面板 ----------------------------
print_header() {
    clear 2>/dev/null || true
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

    local ram_color="${GREEN}"
    if [[ "${RAM_SIZE_MIB}" -lt 1000 ]]; then
        ram_color="${YELLOW}"
    elif [[ "${RAM_SIZE_MIB}" -lt 2000 ]]; then
        ram_color="${BLUE}"
    fi
    echo_line "  ${ICON_RAM}  内存大小       : ${ram_color}${RAM_SIZE_MIB} MiB${NC}"

    local user_color="${GREEN}"
    if [[ "${USER_NAME}" == "root" && "${USER_GROUP}" == "root" ]]; then
        user_color="${YELLOW}"
    fi
    echo_line "  ${ICON_USER}  当前用户/组    : ${user_color}${USER_NAME} / ${USER_GROUP}${NC}"
    echo_line ""
}

# ---------------------------- 发行版检测 ----------------------------
detect_os() {
    local kernel_name
    kernel_name=$(uname -s 2>/dev/null || true)
    case "${kernel_name}" in
        FreeBSD|OpenBSD|NetBSD)
            _log_message "ERROR" "非 Linux 内核 (${kernel_name})，Unix 系统请手动安装"
            echo_line "  ${ICON_ERROR}  ${RED}非 Linux 内核 (${kernel_name})，Unix 系统请手动安装${NC}"
            exit 1 ;;
        Linux) ;;
        *)
            _log_message "ERROR" "不支持的操作系统: ${kernel_name}"
            echo_line "  ${ICON_ERROR}  ${RED}不支持的操作系统: ${kernel_name}${NC}"
            exit 1 ;;
    esac

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID:-${BUILD_ID:-${VERSION:-}}}"
    elif [[ -f /etc/lsb-release ]]; then
        . /etc/lsb-release
        OS_ID="${DISTRIB_ID,,}"
        OS_VERSION="${DISTRIB_RELEASE}"
    elif [[ -f /etc/debian_version ]]; then
        OS_ID="debian"
        OS_VERSION=$(cat /etc/debian_version 2>/dev/null)
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="rhel"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release 2>/dev/null || echo "unknown")
    elif [[ -f /etc/centos-release ]]; then
        OS_ID="centos"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/centos-release 2>/dev/null || echo "unknown")
    elif [[ -f /etc/fedora-release ]]; then
        OS_ID="fedora"
        OS_VERSION=$(grep -oE '[0-9]+' /etc/fedora-release 2>/dev/null || echo "unknown")
    elif [[ -f /etc/arch-release ]]; then
        OS_ID="arch"
        OS_VERSION="rolling"
    elif [[ -f /etc/alpine-release ]]; then
        OS_ID="alpine"
        OS_VERSION=$(cat /etc/alpine-release 2>/dev/null)
    elif [[ -f /etc/SuSE-release ]]; then
        OS_ID="opensuse"
        OS_VERSION=$(sed -n 's/.*VERSION = \([0-9.]*\).*/\1/p' /etc/SuSE-release 2>/dev/null || echo "unknown")
    else
        _log_message "ERROR" "无法检测 Linux 发行版，请检查 /etc/os-release"
        echo_line "  ${ICON_ERROR}  ${RED}无法检测 Linux 发行版，请检查 /etc/os-release${NC}"
        exit 1
    fi
}

# ---------------------------- 第2步: 安装/激活 Miniforge ----------------------------
install_miniforge() {
    start_step "正在检查 Miniforge..."

    CONDA_BIN="${HOME}/miniforge3/bin/conda"
    if command -v conda &>/dev/null; then
        CONDA_VER=$(conda --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        CONDA_BIN=$(command -v conda)
        end_step "${ICON_OK}" "Conda 已就绪: ${CONDA_VER}"
        return
    fi

    if [[ -x "${CONDA_BIN}" ]]; then
        CONDA_VER=$("${CONDA_BIN}" --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Conda 已安装: ${CONDA_VER}"
        return
    fi
    _log_message "ERROR" "未检测到 Conda"
    start_step "正在安装 Miniforge..."
    _log_message "EXEC" "▶ 下载 Miniforge3-Linux-x86_64.sh"
    if ! wget -q -O /tmp/Miniforge3-Linux-x86_64.sh \
        "${GH_PROXY}https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh" >> "$LOGFILE" 2>&1; then
        end_step "${ICON_ERROR}" "Miniforge 下载错误，详情请阅读日志：${LOGFILE}" "${RED}"
        exit 1
    fi
    _log_message "OK" "✓ Miniforge 下载完成"

    _log_message "EXEC" "▶ 安装 Miniforge"
    if ! bash /tmp/Miniforge3-Linux-x86_64.sh -b >> "$LOGFILE" 2>&1; then
        end_step "${ICON_ERROR}" "Miniforge 安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
        rm -f /tmp/Miniforge3-Linux-x86_64.sh
        exit 1
    fi
    _log_message "OK" "✓ Miniforge 安装完成"
    rm -f /tmp/Miniforge3-Linux-x86_64.sh

    if [[ -x "${CONDA_BIN}" ]]; then
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
    if command -v apt-get &>/dev/null; then
        PACKAGE_MANAGER="apt"
    elif command -v pacman &>/dev/null; then
        PACKAGE_MANAGER="pacman"
    elif command -v dnf &>/dev/null; then
        PACKAGE_MANAGER="dnf"
    elif command -v yum &>/dev/null; then
        PACKAGE_MANAGER="yum"
    elif command -v zypper &>/dev/null; then
        PACKAGE_MANAGER="zypper"
    elif command -v apk &>/dev/null; then
        PACKAGE_MANAGER="apk"
    else
        PACKAGE_MANAGER="unknown"
    fi
    _log_message "INFO" "检测到包管理器: ${PACKAGE_MANAGER}"
}

# ---------------------------- 国内镜像安装 ----------------------------
cn_package_mirrors() {
    local -a pkgs=("$@")

    case "${PACKAGE_MANAGER}" in
        apt)
            local codename
            codename=$(lsb_release -sc 2>/dev/null || echo "stable")
            local dist_path="ubuntu/"
            [[ "${OS_ID}" == "debian" ]] && dist_path="debian/"
            local -a apt_mirrors=(
                "https://mirrors.ustc.edu.cn/${dist_path}"
                "https://mirrors.aliyun.com/${dist_path}"
                "https://repo.huaweicloud.com/${dist_path}"
            )
            local mirror_url
            for mirror_url in "${apt_mirrors[@]}"; do
                cat > "/tmp/alas-apt-$$.list" <<EOF
deb ${mirror_url} ${codename} main universe
deb ${mirror_url} ${codename}-updates main universe
deb ${mirror_url} ${codename}-security main universe
EOF
                _log_message "INFO" "尝试镜像: ${mirror_url}"
                if apt-get -o Dir::Etc::sourcelist="/tmp/alas-apt-$$.list" \
                            -o Dir::Etc::sourceparts="-" \
                            -o APT::Get::List-Cleanup="0" \
                            -qq update >> "$LOGFILE" 2>&1; then
                    if apt-get -o Dir::Etc::sourcelist="/tmp/alas-apt-$$.list" \
                               -o Dir::Etc::sourceparts="-" \
                               -qq install -y "${pkgs[@]}" >> "$LOGFILE" 2>&1; then
                        rm -f "/tmp/alas-apt-$$.list"
                        return 0
                    fi
                fi
                rm -f "/tmp/alas-apt-$$.list"
                _log_message "WARNING" "镜像 ${mirror_url} 不可用，尝试下一个"
            done
            return 1
            ;;
        pacman)
            local -a pacman_mirrors=(
                "https://mirrors.ustc.edu.cn/archlinux/\$repo/os/\$arch"
                "https://mirrors.aliyun.com/archlinux/\$repo/os/\$arch"
                "https://repo.huaweicloud.com/archlinux/\$repo/os/\$arch"
            )
            local mirror_url
            for mirror_url in "${pacman_mirrors[@]}"; do
                echo "Server = ${mirror_url}" > "/tmp/alas-mirrorlist-$$"
                sed "s|^Include = /etc/pacman.d/mirrorlist|Include = /tmp/alas-mirrorlist-$$|" \
                    /etc/pacman.conf > "/tmp/alas-pacman-$$.conf"
                _log_message "INFO" "尝试镜像: ${mirror_url}"
                if pacman --config "/tmp/alas-pacman-$$.conf" -Syy --noconfirm "${pkgs[@]}" >> "$LOGFILE" 2>&1; then
                    rm -f "/tmp/alas-pacman-$$.conf" "/tmp/alas-mirrorlist-$$"
                    return 0
                fi
                rm -f "/tmp/alas-pacman-$$.conf" "/tmp/alas-mirrorlist-$$"
                _log_message "WARNING" "镜像 ${mirror_url} 不可用，尝试下一个"
            done
            return 1
            ;;
        dnf)
            local -a dnf_mirrors=(
                "https://mirrors.ustc.edu.cn/centos/\$releasever/BaseOS/\$basearch/os/"
                "https://mirrors.aliyun.com/centos/\$releasever/BaseOS/\$basearch/os/"
                "https://repo.huaweicloud.com/centos/\$releasever/BaseOS/\$basearch/os/"
            )
            local mirror_url
            for mirror_url in "${dnf_mirrors[@]}"; do
                _log_message "INFO" "尝试镜像: ${mirror_url}"
                if dnf --disablerepo='*' --repofrompath="cn-temp-$$,${mirror_url}" --enablerepo="cn-temp-$$" \
                       -q makecache >> "$LOGFILE" 2>&1; then
                    if dnf --disablerepo='*' --repofrompath="cn-temp-$$,${mirror_url}" --enablerepo="cn-temp-$$" \
                           -q install -y "${pkgs[@]}" >> "$LOGFILE" 2>&1; then
                        return 0
                    fi
                fi
                _log_message "WARNING" "镜像 ${mirror_url} 不可用，尝试下一个"
            done
            return 1
            ;;
        apk)
            local alpine_ver
            alpine_ver=$(cat /etc/alpine-release 2>/dev/null | cut -d. -f1,2 || echo "latest-stable")
            local -a apk_mirrors=(
                "https://mirrors.ustc.edu.cn/alpine/v${alpine_ver}/main"
                "https://mirrors.ustc.edu.cn/alpine/v${alpine_ver}/community"
                "https://mirrors.aliyun.com/alpine/v${alpine_ver}/main"
                "https://mirrors.aliyun.com/alpine/v${alpine_ver}/community"
                "https://repo.huaweicloud.com/alpine/v${alpine_ver}/main"
                "https://repo.huaweicloud.com/alpine/v${alpine_ver}/community"
            )
            local mirror_url
            for mirror_url in "${apk_mirrors[@]}"; do
                _log_message "INFO" "尝试镜像: ${mirror_url}"
                if apk add --no-cache --repository="${mirror_url}" "${pkgs[@]}" >> "$LOGFILE" 2>&1; then
                    return 0
                fi
                _log_message "WARNING" "镜像 ${mirror_url} 不可用，尝试下一个"
            done
            return 1
            ;;
        zypper)
            local zypp_ver
            zypp_ver=$(sed -n 's/.*VERSION_ID="\?\([^"]*\).*/\1/p' /etc/os-release 2>/dev/null || echo "15.6")
            local -a zypp_mirrors=(
                "https://mirrors.ustc.edu.cn/opensuse/distribution/leap/${zypp_ver}/repo/oss/"
                "https://mirrors.aliyun.com/opensuse/distribution/leap/${zypp_ver}/repo/oss/"
                "https://repo.huaweicloud.com/opensuse/distribution/leap/${zypp_ver}/repo/oss/"
            )
            local mirror_url
            for mirror_url in "${zypp_mirrors[@]}"; do
                _log_message "INFO" "尝试镜像: ${mirror_url}"
                if zypper --non-interactive --no-gpg-checks --plus-repo "${mirror_url}" \
                       install -y "${pkgs[@]}" >> "$LOGFILE" 2>&1; then
                    return 0
                fi
                _log_message "WARNING" "镜像 ${mirror_url} 不可用，尝试下一个"
            done
            return 1
            ;;
        *)
            _log_message "ERROR" "CN 镜像不支持包管理器: ${PACKAGE_MANAGER}"
            return 1
            ;;
    esac
}

# ---------------------------- 第1步: 检查依赖 ----------------------------
install_deps() {
    start_step "正在检查依赖..."

    detect_package_manager

    local missing_pkgs=()

    case "${PACKAGE_MANAGER}" in
        apt)
            local check_list=(curl git adb)
            for pkg in "${check_list[@]}"; do
                if dpkg -s "$pkg" &>/dev/null; then
                    _log_message "OK" "依赖已存在: ${pkg}"
                else
                    _log_message "WARNING" "依赖缺失: ${pkg}"
                    missing_pkgs+=("$pkg")
                fi
            done ;;
        pacman)
            local check_list=(curl git android-tools)
            for pkg in "${check_list[@]}"; do
                if pacman -Q "$pkg" &>/dev/null; then
                    _log_message "OK" "依赖已存在: ${pkg}"
                else
                    _log_message "WARNING" "依赖缺失: ${pkg}"
                    missing_pkgs+=("$pkg")
                fi
            done ;;
        dnf|yum|zypper)
            local check_list=(curl git adb)
            for pkg in "${check_list[@]}"; do
                if rpm -q "$pkg" &>/dev/null; then
                    _log_message "OK" "依赖已存在: ${pkg}"
                else
                    _log_message "WARNING" "依赖缺失: ${pkg}"
                    missing_pkgs+=("$pkg")
                fi
            done ;;
        apk)
            local check_list=(curl git android-tools)
            for pkg in "${check_list[@]}"; do
                if apk info -e "$pkg" &>/dev/null; then
                    _log_message "OK" "依赖已存在: ${pkg}"
                else
                    _log_message "WARNING" "依赖缺失: ${pkg}"
                    missing_pkgs+=("$pkg")
                fi
            done ;;
        *)
            end_step "${ICON_ERROR}" "不支持的包管理器: ${PACKAGE_MANAGER}" "${RED}"
            exit 1 ;;
    esac

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        end_step "${ICON_OK}" "curl 已安装: $(curl --version 2>/dev/null | head -n1 | awk '{print $2}')"
        end_step "${ICON_OK}" "Git 已安装: $(git --version 2>/dev/null | awk '{print $NF}')"
        end_step "${ICON_OK}" "ADB 已安装: $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
        return
    fi

    start_step "正在安装缺失的依赖: ${missing_pkgs[*]}..."

    if [[ "${USE_CN_MIRROR}" == true ]]; then
        _log_message "EXEC" "▶ ${PACKAGE_MANAGER} (CN mirrors) ${missing_pkgs[*]}"
        cn_package_mirrors "${missing_pkgs[@]}" || {
            _log_message "ERROR" "✗ CN 镜像安装失败"
            end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
            exit 1
        }
    else
        case "${PACKAGE_MANAGER}" in
            apt)
                _log_message "EXEC" "▶ apt-get update"
                if ! apt-get -qq update >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ apt-get update 失败"
                    end_step "${ICON_ERROR}" "依赖更新错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi
                _log_message "OK" "✓ apt-get update 完成"
                _log_message "EXEC" "▶ apt-get install -y ${missing_pkgs[*]}"
                if ! apt-get -qq install -y "${missing_pkgs[@]}" >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ apt-get install 失败"
                    end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi ;;
            pacman)
                _log_message "EXEC" "▶ pacman -Syy --noconfirm ${missing_pkgs[*]}"
                if ! pacman -Syy --noconfirm "${missing_pkgs[@]}" >> "$LOGFILE" 2>&1; then
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
                _log_message "EXEC" "▶ dnf install -y ${missing_pkgs[*]}"
                if ! dnf -q install -y "${missing_pkgs[@]}" >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ dnf install 失败"
                    end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi ;;
            yum)
                _log_message "EXEC" "▶ yum install -y ${missing_pkgs[*]}"
                if ! yum -q install -y "${missing_pkgs[@]}" >> "$LOGFILE" 2>&1; then
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
                _log_message "EXEC" "▶ zypper --non-interactive install -y ${missing_pkgs[*]}"
                if ! zypper --non-interactive install -y "${missing_pkgs[@]}" >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ zypper install 失败"
                    end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi ;;
            apk)
                _log_message "EXEC" "▶ apk add --no-cache ${missing_pkgs[*]}"
                if ! apk add --no-cache "${missing_pkgs[@]}" >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ apk add 失败"
                    end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi ;;
        esac
    fi

    end_step "${ICON_OK}" "curl 已安装: $(curl --version 2>/dev/null | head -n1 | awk '{print $2}')"
    end_step "${ICON_OK}" "Git 已安装: $(git --version 2>/dev/null | awk '{print $NF}')"
    end_step "${ICON_OK}" "ADB 已安装: $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
    _log_message "OK" "✓ 依赖安装完成"
}

# ---------------------------- 第3步: 克隆仓库 ----------------------------
clone_alas() {
    start_step "正在克隆 ALAS 仓库..."

    WORK_DIR="${INSTALL_DIR}"
    if [[ -d "${WORK_DIR}" ]]; then
        _log_message "WARNING" "ALAS 目录已存在，跳过克隆: ${WORK_DIR}"
        end_step "${ICON_WARN}" "ALAS 目录已存在，跳过克隆" "${YELLOW}"
        cd "${WORK_DIR}"
        ALAS_DIR="${WORK_DIR}"
        return
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
setup_conda_env() {
    start_step "正在配置 Conda 虚拟环境..."

    cd "${ALAS_DIR}"
    if [[ -f environment.yml ]]; then
        _log_message "EXEC" "▶ 备份已有 environment.yml → environment.yml.bak"
        cp environment.yml environment.yml.bak
        _log_message "OK" "✓ 备份完成"
    fi

    ENV_URL="https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Conda/environment.yml"
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

    eval "$("${CONDA_BIN}" shell.bash hook)" >> "$LOGFILE" 2>&1
    _log_message "OK" "✓ Conda shell hook 已加载"

    if [[ "${USE_CN_MIRROR}" == true ]]; then
        local cernet_conda="https://mirrors.cernet.edu.cn/anaconda"
        local cernet_pypi="https://mirrors.cernet.edu.cn/pypi/web/simple"

        _log_message "EXEC" "▶ 配置国内镜像源 (cernet)"
        conda config --prepend channels "${cernet_conda}/cloud/conda-forge/" >> "$LOGFILE" 2>&1
        conda config --prepend channels "${cernet_conda}/pkgs/main/" >> "$LOGFILE" 2>&1

        export PIP_INDEX_URL="${cernet_pypi}"
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
        if [[ "${USE_CN_MIRROR}" == true && "${_se_cn_fallback_done}" != true ]] && \
           grep -Eqi '403|403 Forbidden|HTTP.*403' "${_se_install_log}" 2>/dev/null; then
            _log_message "WARNING" "国内镜像源不可用（403 Forbidden），自动降级到官方源"
            end_step "${ICON_WARN}" "国内镜像源不可用，自动降级到官方源并重试" "${YELLOW}"
            rm -f "${_se_install_log}"
            _se_cn_fallback_done=true
            conda config --remove channels "https://mirrors.cernet.edu.cn/anaconda/cloud/conda-forge/" >> "$LOGFILE" 2>&1 || true
            conda config --remove channels "https://mirrors.cernet.edu.cn/anaconda/pkgs/main/" >> "$LOGFILE" 2>&1 || true
            unset PIP_INDEX_URL
            conda env remove -n alas -y >> "$LOGFILE" 2>&1 || true
            _se_install_attempt=$((_se_install_attempt + 1))
            start_step "正在重新配置 Conda 虚拟环境..."
            continue
        fi

        _log_message "ERROR" "✗ conda env create 失败 (尝试 #${_se_install_attempt})"
        rm -f "${_se_install_log}"
        end_step "${ICON_ERROR}" "虚拟环境构建错误，详情请阅读日志：${LOGFILE}" "${RED}"
        exit 1
    done
    _log_message "OK" "✓ conda env create 完成"

    unset PIP_INDEX_URL

    # 检查是否有依赖缺失，如有则逐条尝试独立安装
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

# ---------------------------- 第5步: 配置 config/deploy.yaml ----------------------------
configure_deploy() {
    start_step "配置 config/deploy.yaml"

    cd "${ALAS_DIR}"
    if [[ -f config/deploy.yaml ]]; then
        _log_message "EXEC" "▶ 备份已有 deploy.yaml → deploy.yaml.bak"
        cp config/deploy.yaml config/deploy.yaml.bak
        _log_message "OK" "✓ 备份完成"
    fi

    TEMPLATE="${DEPLOY_TEMPLATE}"

    if [[ -f "${TEMPLATE}" ]]; then
        _log_message "EXEC" "▶ cp ${TEMPLATE} config/deploy.yaml"
        cp "${TEMPLATE}" config/deploy.yaml
        end_step "${ICON_OK}" "cp ${TEMPLATE} config/deploy.yaml"
    else
        end_step "${ICON_WARN}" "模板文件 ${TEMPLATE} 不存在，请手动执行 cp ${TEMPLATE} config/deploy.yaml" "${YELLOW}"
    fi
}

# ---------------------------- 第6步: 创建启动脚本 ----------------------------
create_launcher() {
    start_step "正在生成启动脚本..."

    _log_message "EXEC" "▶ 生成 ${SCRIPT_OUT_DIR}/run_alas.sh"
    _log_message "INFO" "  Conda: ${CONDA_BIN}"
    _log_message "INFO" "  ALAS 目录: ${ALAS_DIR}"

    cat > "${SCRIPT_OUT_DIR}/run_alas.sh" <<EOF
#!/bin/bash
eval "\$(${CONDA_BIN} shell.bash hook)"
conda activate alas
cd ${ALAS_DIR}
python gui.py
EOF
    chmod +x "${SCRIPT_OUT_DIR}/run_alas.sh"
    end_step "${ICON_OK}" "启动脚本已生成: ${SCRIPT_OUT_DIR}/run_alas.sh"
}

# ---------------------------- 第7步: 配置 init 服务 ----------------------------
configure_service() {
    if [[ "${SKIP_SERVICE}" == true ]]; then
        end_step "${ICON_INFO}" "检测到 -S、--skip-service 已跳过服务配置"
        return
    fi

    if [[ "${INIT_SYSTEM}" == "unknown" ]]; then
        end_step "${ICON_WARN}" "未检测到 init 系统，跳过服务配置" "${YELLOW}"
        return
    fi

    if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
        _configure_systemd
    elif [[ "${INIT_SYSTEM}" == "openrc" ]]; then
        _configure_openrc
    elif [[ "${INIT_SYSTEM}" == "sysvinit" ]]; then
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

    if systemctl is-active --quiet run_alas.service; then
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

    cat > /etc/init.d/run_alas <<'OPENRC_EOF'
#!/sbin/openrc-run
name="run_alas"
description="ALAS Auto Script"

depend() {
    need net
    after bootmisc
}

start() {
    ebegin "Starting ALAS"
    start-stop-daemon --start --background --make-pidfile \
        --pidfile /var/run/run_alas.pid \
        --chdir ALAS_DIR_PLACEHOLDER \
        --user USER_PLACEHOLDER \
        --exec SCRIPT_PLACEHOLDER
    eend $?
}

stop() {
    ebegin "Stopping ALAS"
    start-stop-daemon --stop --pidfile /var/run/run_alas.pid
    eend $?
}
OPENRC_EOF

    sed -i "s|ALAS_DIR_PLACEHOLDER|${ALAS_DIR}|g" /etc/init.d/run_alas
    sed -i "s|USER_PLACEHOLDER|${USER_NAME}|g" /etc/init.d/run_alas
    sed -i "s|SCRIPT_PLACEHOLDER|${SCRIPT_OUT_DIR}/run_alas.sh|g" /etc/init.d/run_alas
    chmod +x /etc/init.d/run_alas
    _log_message "OK" "✓ OpenRC 服务脚本已创建"

    _log_message "EXEC" "▶ rc-update add run_alas default"
    rc-update add run_alas default >> "$LOGFILE" 2>&1
    _log_message "OK" "✓ 服务已添加至 default 运行级"

    _log_message "EXEC" "▶ rc-service run_alas start"
    rc-service run_alas start >> "$LOGFILE" 2>&1
    _log_message "OK" "✓ 服务已启动"

    if rc-service run_alas status &>/dev/null; then
        end_step "${ICON_OK}" "OpenRC 服务已启动并设为开机自启"
    else
        end_step "${ICON_ERROR}" "OpenRC 服务启动失败，请查看日志: ${LOGFILE}" "${RED}"
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

    sed -i "s|USER_PLACEHOLDER|${USER_NAME}|g" /etc/init.d/run_alas
    sed -i "s|DIR_PLACEHOLDER|${ALAS_DIR}|g" /etc/init.d/run_alas
    sed -i "s|SCRIPT_PLACEHOLDER|${SCRIPT_OUT_DIR}/run_alas.sh|g" /etc/init.d/run_alas
    chmod +x /etc/init.d/run_alas
    _log_message "OK" "✓ SysVinit 服务脚本已创建"

    if command -v update-rc.d &>/dev/null; then
        _log_message "EXEC" "▶ update-rc.d run_alas defaults"
        update-rc.d run_alas defaults >> "$LOGFILE" 2>&1
    elif command -v chkconfig &>/dev/null; then
        _log_message "EXEC" "▶ chkconfig --add run_alas"
        chkconfig --add run_alas >> "$LOGFILE" 2>&1
    fi
    _log_message "OK" "✓ 服务已添加至启动项"

    _log_message "EXEC" "▶ service run_alas start"
    service run_alas start >> "$LOGFILE" 2>&1
    _log_message "OK" "✓ 服务已启动"

    if service run_alas status >> "$LOGFILE" 2>&1; then
        end_step "${ICON_OK}" "SysVinit 服务已启动并设为开机自启"
    else
        end_step "${ICON_ERROR}" "SysVinit 服务启动失败，请查看日志: ${LOGFILE}" "${RED}"
    fi
}

# ---------------------------- 完成摘要 ----------------------------
print_completion() {
    echo_line ""
    echo_line "${ICON_ROCKET}  ALAS 已经完成安装，请通过 ${CYAN}http://${NET_IP}:22267${NC} 访问 WEBUI"
    echo_line ""
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
    if [[ "${UNINSTALL_YES}" == true ]]; then
        _log_message "INFO" "已通过 -Y 自动确认卸载"
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
    if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
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
        if [[ -f /etc/systemd/system/run_alas.service ]]; then
            _log_message "EXEC" "▶ 删除服务单元文件"
            rm -f /etc/systemd/system/run_alas.service
            systemctl daemon-reload >> "$LOGFILE" 2>&1
            _svc_done=true
        fi
    elif [[ "${INIT_SYSTEM}" == "openrc" ]]; then
        if command -v rc-service >/dev/null 2>&1; then
            rc-service run_alas stop >> "$LOGFILE" 2>&1 || true
            _log_message "OK" "✓ 服务已停止"
            _svc_done=true
        fi
        rc-update del run_alas default >> "$LOGFILE" 2>&1 || true
        if [[ -f /etc/init.d/run_alas ]]; then
            _log_message "EXEC" "▶ 删除 OpenRC 服务脚本"
            rm -f /etc/init.d/run_alas
            _svc_done=true
        fi
    elif [[ "${INIT_SYSTEM}" == "sysvinit" ]]; then
        service run_alas stop >> "$LOGFILE" 2>&1 || true
        _log_message "OK" "✓ 服务已停止"
        _svc_done=true
        if command -v update-rc.d &>/dev/null; then
            _log_message "EXEC" "▶ update-rc.d -f run_alas remove"
            update-rc.d -f run_alas remove >> "$LOGFILE" 2>&1 || true
        elif command -v chkconfig &>/dev/null; then
            _log_message "EXEC" "▶ chkconfig --del run_alas"
            chkconfig --del run_alas >> "$LOGFILE" 2>&1 || true
        fi
        if [[ -f /etc/init.d/run_alas ]]; then
            _log_message "EXEC" "▶ 删除 SysVinit 服务脚本"
            rm -f /etc/init.d/run_alas
        fi
    fi
    if [[ "$_svc_done" == true ]]; then
        end_step "${ICON_OK}" "服务已停止并移除"
    else
        end_step "${ICON_INFO}" "未检测到 ALAS 服务，跳过" "${GREEN}"
    fi

    start_step "正在清理 Conda 虚拟环境..."
    if command -v conda &>/dev/null; then
        CONDA_BIN=$(command -v conda)
        eval "$("${CONDA_BIN}" shell.bash hook)" >> "$LOGFILE" 2>&1
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

    start_step "正在删除启动脚本..."
    if [[ -f "${SCRIPT_OUT_DIR}/run_alas.sh" ]]; then
        _log_message "EXEC" "▶ rm -f ${SCRIPT_OUT_DIR}/run_alas.sh"
        rm -f "${SCRIPT_OUT_DIR}/run_alas.sh"
        end_step "${ICON_OK}" "启动脚本已删除"
    else
        end_step "${ICON_INFO}" "启动脚本不存在，跳过" "${GREEN}"
    fi

    start_step "正在删除 ALAS 目录..."
    if [[ -d "${INSTALL_DIR}" ]]; then
        _log_message "EXEC" "▶ rm -rf ${INSTALL_DIR}"
        rm -rf "${INSTALL_DIR}"
        end_step "${ICON_OK}" "目录已删除"
    else
        end_step "${ICON_INFO}" "ALAS 目录已不存在，跳过" "${GREEN}"
    fi

    if [[ "${KEEP_LOG}" == false ]]; then
        _log_message "INFO" "清理日志文件: ${LOGFILE}"
        rm -f "$LOGFILE"
    fi
    echo_line ""
    echo_line "${ICON_OK}  ${GREEN}ALAS 卸载完成${NC}"
    echo_line ""
}

# ---------------------------- 主流程 ----------------------------
main() {
    if [[ "${UNINSTALL}" == true ]]; then
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
    if [[ "${KEEP_LOG}" == false ]]; then
        _log_message "INFO" "安装完成，清理日志文件: ${LOGFILE}"
        rm -f "$LOGFILE"
    else
        echo_line "  ${ICON_INFO}  日志已保存至：${LOGFILE}"
    fi
}
main
