#!/bin/bash
#==============================================================================
# AzurLaneAutoScript Pixi 一键部署脚本 
# 特性：
#   - 静默执行，网络自适应，系统信息面板，步骤反馈
#==============================================================================

set -euo pipefail

# ---------------------------- 脚本目录 ----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------- 日志文件 ----------------------------
LOGFILE="/var/log/pixi_alas_install.log"
touch "$LOGFILE" || { echo "无法创建日志文件 $LOGFILE"; exit 1; }

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
WORK_DIR=""
ALAS_DIR=""
PIXI_BIN_PATH=""
USER_NAME="${SUDO_USER:-$(whoami)}"
USER_GROUP=$(id -gn "${USER_NAME}")
_SPINNER_PID=""

# ---------------------------- 帮助 ----------------------------
usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  -s, --skip-service   跳过 systemd 开机自启服务配置
  -h, --help           显示本帮助信息

示例:
  sudo bash $0
  sudo bash $0 --skip-service
EOF
}

# ---------------------------- 输出与日志函数 ----------------------------
echo_line() {
    # 参数：终端输出字符串（可含颜色和图标）
    local term_line="$1"
    echo -e "$term_line"
    # 写入日志前移除所有 ANSI 颜色码
    echo -e "$(echo -e "$term_line" | sed 's/\x1b\[[0-9;]*m//g')" >> "$LOGFILE"
}

log_out() {
    local icon="$1"
    local color="$2"
    local msg="$3"
    echo_line "  ${icon}  ${color}${msg}${NC}"
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
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$LOGFILE"
    local spin_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local idx=0
    {
        while true; do
            printf "\r${YELLOW}%s  %s${NC}\033[K" "${spin_chars[$idx]}" "$msg"
            idx=$(( (idx + 1) % 10 ))
            sleep 0.15 2>/dev/null || true
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
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${icon} ${msg}" >> "$LOGFILE"
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
        -s|--skip-service) SKIP_SERVICE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "未知参数: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------- 权限检查 ----------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}请使用 root 权限运行此脚本 (sudo bash $0)${NC}"
    exit 1
fi

# ---------------------------- 系统信息收集 ----------------------------
gather_system_info() {
    NET_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "${NET_IP}" ]] && NET_IP="未获取"
    KERNEL=$(uname -r)
    CPU_MODEL=$(lscpu | grep "Model name" | sed 's/Model name:\s*//' || echo "未知")
    CPU_CORES=$(nproc)
    DISK_AVAIL=$(df -h / | awk 'NR==2{print $4}')
    DISK_USED=$(df -h / | awk 'NR==2{print $3}')
    DISK_INFO="可用: ${DISK_AVAIL}  已用: ${DISK_USED}"
    RAM_SIZE_MIB=$(free -m | awk '/Mem:/{print $2}')
}

# ---------------------------- 打印标题与系统面板 ----------------------------
print_header() {
    clear
    echo_line "${WHITE}"
    echo_line "    ___    __    ___   _____"
    echo_line "   /   |  / /   /   | / ___/"
    echo_line "  / /| | / /   / /| | \\__ \\ "
    echo_line " / ___ |/ /___/ ___ |___/ / "
    echo_line "/_/  |_/_____/_/  |_/____/  "
    echo_line "${NC}"
    echo_line "  ${ICON_COMPUTER}  基于 Pixi 的 ALAS 部署脚本"
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
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
    else
        log_error "无法检测 Linux 发行版"
        exit 1
    fi
}

# ---------------------------- 第1步: 安装/激活 Pixi ----------------------------
install_pixi() {
    start_step "正在检查 Pixi 包管理器..."

    if command -v pixi &>/dev/null; then
        PIXI_VER=$(pixi --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Pixi 已安装: ${PIXI_VER}"
        return
    fi

    if [[ -x "${HOME}/.pixi/bin/pixi" ]]; then
        export PATH="${HOME}/.pixi/bin:${PATH}"
        PIXI_VER=$(pixi --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Pixi 已激活: ${PIXI_VER}"
        return
    fi

    # 官方安装方式，输出重定向到日志文件
    curl -fsSL https://pixi.sh/install.sh | sh >> "$LOGFILE" 2>&1

    export PATH="${HOME}/.pixi/bin:${PATH}"
    if command -v pixi &>/dev/null; then
        PIXI_VER=$(pixi --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Pixi 已安装: ${PIXI_VER}"
    else
        end_step "${ICON_ERROR}" "Pixi 安装失败，请查看日志: ${LOGFILE}" "${RED}"
        exit 1
    fi
}

# ---------------------------- 第2步: 安装 Git 和 ADB 及相关依赖库 ----------------------------
install_git_adb() {
    start_step "正在检查依赖库..."

    local missing_pkgs=()

    case "${OS_ID}" in
        debian|ubuntu)
            local check_list=(git adb libgomp1 libgl1 libglib2.0-0t64 libsm6 libxrender1 libxext6)
            for pkg in "${check_list[@]}"; do
                if dpkg -s "$pkg" &>/dev/null; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S')   ${ICON_OK} ${pkg} 已安装" >> "$LOGFILE"
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S')   ${ICON_WARN} ${pkg} 未安装" >> "$LOGFILE"
                    missing_pkgs+=("$pkg")
                fi
            done
            ;;
        arch)
            local check_list=(git android-tools)
            for pkg in "${check_list[@]}"; do
                if pacman -Q "$pkg" &>/dev/null; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S')   ${ICON_OK} ${pkg} 已安装" >> "$LOGFILE"
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S')   ${ICON_WARN} ${pkg} 未安装" >> "$LOGFILE"
                    missing_pkgs+=("$pkg")
                fi
            done
            ;;
        centos|rhel|fedora)
            local check_list=(git adb libgomp mesa-libGL glib2 libSM libXrender libXext)
            for pkg in "${check_list[@]}"; do
                if rpm -q "$pkg" &>/dev/null; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S')   ${ICON_OK} ${pkg} 已安装" >> "$LOGFILE"
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S')   ${ICON_WARN} ${pkg} 未安装" >> "$LOGFILE"
                    missing_pkgs+=("$pkg")
                fi
            done
            ;;
        *)
            end_step "${ICON_ERROR}" "不支持的发行版: ${OS_ID}" "${RED}"
            exit 1 ;;
    esac

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        end_step "${ICON_OK}" "Git 已安装: $(git --version 2>/dev/null | awk '{print $NF}')"
        end_step "${ICON_OK}" "ADB 已安装: $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
        echo "$(date '+%Y-%m-%d %H:%M:%S')   Git: $(git --version 2>/dev/null)" >> "$LOGFILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S')   ADB: $(adb --version 2>/dev/null | head -n1)" >> "$LOGFILE"
        return
    fi

    start_step "正在安装缺失的依赖..."

    case "${OS_ID}" in
        debian|ubuntu)
            apt-get -qq update >> "$LOGFILE" 2>&1
            apt-get -qq install -y "${missing_pkgs[@]}" >> "$LOGFILE" 2>&1 ;;
        arch)
            pacman -Syy --noconfirm "${missing_pkgs[@]}" >> "$LOGFILE" 2>&1 ;;
        centos|rhel|fedora)
            if command -v dnf &>/dev/null; then
                dnf -q makecache >> "$LOGFILE" 2>&1
                dnf -q install -y "${missing_pkgs[@]}" >> "$LOGFILE" 2>&1
            else
                yum -q install -y "${missing_pkgs[@]}" >> "$LOGFILE" 2>&1
            fi ;;
    esac

    end_step "${ICON_OK}" "Git 已安装: $(git --version 2>/dev/null | awk '{print $NF}')"
    end_step "${ICON_OK}" "ADB 已安装: $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
    echo "$(date '+%Y-%m-%d %H:%M:%S')   Git: $(git --version 2>/dev/null)" >> "$LOGFILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S')   ADB: $(adb --version 2>/dev/null | head -n1)" >> "$LOGFILE"
}

# ---------------------------- 第3步: 克隆仓库 ----------------------------
clone_alas() {
    start_step "正在克隆 AzurLaneAutoScript 仓库..."

    WORK_DIR="${HOME}/AzurLaneAutoScript"
    if [[ -d "${WORK_DIR}" ]]; then
        end_step "${ICON_WARN}" "ALAS 目录已存在，跳过克隆" "${YELLOW}"
        cd "${WORK_DIR}"
        ALAS_DIR="${WORK_DIR}"
        return
    fi

    REPO_URL="https://github.com/LmeSzinc/AzurLaneAutoScript.git"

    git clone "${REPO_URL}" "${WORK_DIR}" >> "$LOGFILE" 2>&1
    cd "${WORK_DIR}"
    ALAS_DIR="${WORK_DIR}"

    end_step "${ICON_OK}" "ALAS 仓库已克隆"
}

# ---------------------------- 第4步: 配置虚拟环境 ----------------------------
setup_pixi_env() {
    start_step "正在配置 Pixi 虚拟环境..."

    cd "${ALAS_DIR}"
    if [[ -f pixi.toml ]]; then
        cp pixi.toml pixi.toml.bak
    fi

    TOML_URL="https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Pixi/pixi.toml"

    wget -q -O pixi.toml "${TOML_URL}" >> "$LOGFILE" 2>&1

    if [[ -d ".pixi/envs/alas" || -f "pixi.lock" ]]; then
        pixi clean --environment alas >> "$LOGFILE" 2>&1 || \
        pixi clean >> "$LOGFILE" 2>&1 || \
        rm -rf .pixi pixi.lock >> "$LOGFILE" 2>&1
    fi

    pixi install --manifest-path pixi.toml >> "$LOGFILE" 2>&1

    end_step "${ICON_OK}" "虚拟环境已构建"
}

# ---------------------------- 第5步: 配置 deploy.yaml ----------------------------
configure_deploy() {
    start_step "正在生成 deploy.yaml..."

    cd "${ALAS_DIR}"
    if [[ -f config/deploy.yaml ]]; then
        cp config/deploy.yaml config/deploy.yaml.bak
    fi

    TEMPLATE="config/deploy.template-linux.yaml"

    if [[ -f "${TEMPLATE}" ]]; then
        cp "${TEMPLATE}" config/deploy.yaml
        end_step "${ICON_OK}" "deploy.yaml 已配置"
    else
        end_step "${ICON_WARN}" "模板文件 ${TEMPLATE} 不存在，请手动配置" "${YELLOW}"
    fi
}

# ---------------------------- 第6步: systemd 服务 ----------------------------
configure_service() {
    if [[ "${SKIP_SERVICE}" == true ]]; then
        end_step "${ICON_INFO}" "已跳过 systemd 服务配置"
        return
    fi

    start_step "正在配置 systemd 开机自启..."

    PIXI_BIN_PATH=$(command -v pixi)
    cat > /etc/systemd/system/run_alas.service <<EOF
[Unit]
Description=ALAS Auto Script
After=network.target
Wants=network-online.target

[Service]
User=${USER_NAME}
Group=${USER_GROUP}
WorkingDirectory=${ALAS_DIR}
ExecStart=${PIXI_BIN_PATH} run start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/run_alas.service
    systemctl daemon-reload >> "$LOGFILE" 2>&1
    systemctl enable run_alas.service >> "$LOGFILE" 2>&1
    systemctl start run_alas.service >> "$LOGFILE" 2>&1

    if systemctl is-active --quiet run_alas.service; then
        end_step "${ICON_OK}" "systemd 服务已启动并设为开机自启"
    else
        end_step "${ICON_ERROR}" "systemd 服务启动失败，请查看日志: ${LOGFILE}" "${RED}"
    fi
}

# ---------------------------- 完成摘要 ----------------------------
print_completion() {
    echo_line ""
    echo_line "${ICON_ROCKET}  ALAS 已经完成安装，请通过 ${CYAN}http://${NET_IP}:22267${NC} 访问 WEBUI"
    echo_line ""
}

# ---------------------------- 主流程 ----------------------------
main() {
    detect_os
    gather_system_info
    print_header

    install_pixi
    install_git_adb
    clone_alas
    setup_pixi_env
    configure_deploy
    configure_service

    print_completion
    rm -f "$LOGFILE"
}

main