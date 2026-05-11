#!/bin/bash
#==============================================================================
# AzurLaneAutoScript Pixi 一键部署脚本 
# 特性：
#   - 静默执行，网络自适应，系统信息面板，步骤反馈
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

# 调试追踪 (set -x) 输出到 stderr (终端)，日志文件只接受 _log_message 的结构化记录
PS4='+$(date "+%H:%M:%S.%3N | DEBUG  | ")'
set -x

# ---------------------------- 日志格式化 ----------------------------
# 格式: LEVEL | HH:MM:SS.mmm | message
# (等效于 Python: '%(levelname)s | %(asctime)s.%(msecs)03d | %(message)s', datefmt='%H:%M:%S')
_LOG_DATEFMT='%H:%M:%S'

_log_message() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date "+${_LOG_DATEFMT}.%3N")
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
KEEP_LOG=false
USE_CN_MIRROR=false
GH_PROXY=""
DEPLOY_TEMPLATE="config/deploy.template-linux.yaml"
INSTALL_DIR="${HOME}/AzurLaneAutoScript"
SCRIPT_OUT_DIR="${HOME}/AzurLaneAutoScript"
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
  -d, --dir DIR          指定 ALAS 安装目录 (默认: ~/AzurLaneAutoScript)
  -s, --script-dir DIR   指定脚本输出目录 (默认: ~/AzurLaneAutoScript)
  -t TEMPLATE            控制使用的 deploy 模板与国内镜像源
  -S, --skip-service     跳过 systemd 开机自启服务配置
  --uninstall            反向安装：停止并删除 ALAS、虚拟环境、开机自启
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
    set +x
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
    set -x
}

end_step() {
    set +x
    local icon="$1"
    local msg="$2"
    local color="${3:-${GREEN}}"
    _cleanup_spinner
    printf "\r${icon}  ${color}%s${NC}\033[K\n" "$msg"
    set -x
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
        --uninstall) UNINSTALL=true; shift ;;
        -l|--log) KEEP_LOG=true; shift ;;
        -S|--skip-service) SKIP_SERVICE=true; shift ;;
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
    echo_line "  ${ICON_COMPUTER}  X86-64 Linux 中基于 Pixi 的 ALAS 部署脚本"
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
        _log_message "OK" "Pixi 已安装: ${PIXI_VER}"
        end_step "${ICON_OK}" "Pixi 已安装: ${PIXI_VER}"
        return
    fi

    if [[ -x "${HOME}/.pixi/bin/pixi" ]]; then
        export PATH="${HOME}/.pixi/bin:${PATH}"
        PIXI_VER=$(pixi --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        _log_message "OK" "Pixi 已激活: ${PIXI_VER}"
        end_step "${ICON_OK}" "Pixi 已激活: ${PIXI_VER}"
        return
    fi

    # 官方安装方式，输出重定向到日志文件
    _log_message "EXEC" "▶ 安装 Pixi: curl -fsSL https://pixi.sh/install.sh | sh"
    if ! curl -fsSL https://pixi.sh/install.sh | sh >> "$LOGFILE" 2>&1; then
        _log_message "ERROR" "✗ Pixi 安装失败"
        end_step "${ICON_ERROR}" "Pixi 安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
        exit 1
    fi
    _log_message "OK" "✓ Pixi 安装命令已完成"

    export PATH="${HOME}/.pixi/bin:${PATH}"
    if command -v pixi &>/dev/null; then
        PIXI_VER=$(pixi --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        _log_message "OK" "Pixi 已安装: ${PIXI_VER}"
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

    local missing_pkgs=()

    case "${OS_ID}" in
        debian|ubuntu)
            local check_list=(git adb)
            for pkg in "${check_list[@]}"; do
                if dpkg -s "$pkg" &>/dev/null; then
                    _log_message "OK" "依赖已存在: ${pkg}"
                else
                    _log_message "WARNING" "依赖缺失: ${pkg}"
                    missing_pkgs+=("$pkg")
                fi
            done
            ;;
        arch)
            local check_list=(git android-tools)
            for pkg in "${check_list[@]}"; do
                if pacman -Q "$pkg" &>/dev/null; then
                    _log_message "OK" "依赖已存在: ${pkg}"
                else
                    _log_message "WARNING" "依赖缺失: ${pkg}"
                    missing_pkgs+=("$pkg")
                fi
            done
            ;;
        centos|rhel|fedora)
            local check_list=(git adb)
            for pkg in "${check_list[@]}"; do
                if rpm -q "$pkg" &>/dev/null; then
                    _log_message "OK" "依赖已存在: ${pkg}"
                else
                    _log_message "WARNING" "依赖缺失: ${pkg}"
                    missing_pkgs+=("$pkg")
                fi
            done
            ;;
        *)
            end_step "${ICON_ERROR}" "不支持的发行版: ${OS_ID}" "${RED}"
            exit 1 ;;
    esac

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        _log_message "OK" "Git: $(git --version 2>/dev/null)"
        _log_message "OK" "ADB: $(adb --version 2>/dev/null | head -n1)"
        end_step "${ICON_OK}" "Git 已安装: $(git --version 2>/dev/null | awk '{print $NF}')"
        end_step "${ICON_OK}" "ADB 已安装: $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
        return
    fi

    start_step "正在安装缺失的依赖: ${missing_pkgs[*]}..."

    case "${OS_ID}" in
        debian|ubuntu)
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
            fi
            _log_message "OK" "✓ 依赖安装完成" ;;
        arch)
            _log_message "EXEC" "▶ pacman -Syy --noconfirm ${missing_pkgs[*]}"
            if ! pacman -Syy --noconfirm "${missing_pkgs[@]}" >> "$LOGFILE" 2>&1; then
                _log_message "ERROR" "✗ pacman 安装失败"
                end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
                exit 1
            fi
            _log_message "OK" "✓ 依赖安装完成" ;;
        centos|rhel|fedora)
            if command -v dnf &>/dev/null; then
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
                fi
                _log_message "OK" "✓ 依赖安装完成"
            else
                _log_message "EXEC" "▶ yum install -y ${missing_pkgs[*]}"
                if ! yum -q install -y "${missing_pkgs[@]}" >> "$LOGFILE" 2>&1; then
                    _log_message "ERROR" "✗ yum install 失败"
                    end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
                    exit 1
                fi
                _log_message "OK" "✓ 依赖安装完成"
            fi ;;
    esac

    _log_message "OK" "Git: $(git --version 2>/dev/null)"
    _log_message "OK" "ADB: $(adb --version 2>/dev/null | head -n1)"
    end_step "${ICON_OK}" "Git 已安装: $(git --version 2>/dev/null | awk '{print $NF}')"
    end_step "${ICON_OK}" "ADB 已安装: $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
}

# ---------------------------- 第3步: 克隆仓库 ----------------------------
clone_alas() {
    start_step "正在克隆 AzurLaneAutoScript 仓库..."

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
        _log_message "ERROR" "✗ 仓库克隆失败"
        end_step "${ICON_ERROR}" "仓库克隆错误，详情请阅读日志：${LOGFILE}" "${RED}"
        exit 1
    fi
    _log_message "OK" "✓ 仓库克隆完成"
    cd "${WORK_DIR}"
    ALAS_DIR="${WORK_DIR}"

    _log_message "OK" "ALAS 目录: ${ALAS_DIR}"
    end_step "${ICON_OK}" "ALAS 仓库已克隆"
}

# ---------------------------- 第4步: 配置虚拟环境 ----------------------------
setup_pixi_env() {
    start_step "正在配置 Pixi 虚拟环境..."

    cd "${ALAS_DIR}"
    if [[ -f pixi.toml ]]; then
        _log_message "EXEC" "▶ 备份已有 pixi.toml → pixi.toml.bak"
        cp pixi.toml pixi.toml.bak
        _log_message "OK" "✓ 备份完成"
    fi

    TOML_URL="https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Pixi/pixi.toml"
    _log_message "EXEC" "▶ 生成 pixi.toml"

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

    if [[ -d ".pixi/envs/alas" || -f "pixi.lock" ]]; then
        _log_message "WARNING" "检测到已有 Pixi 环境，正在清理..."
        _log_exec "清理 Pixi 缓存" pixi clean cache -y || true
        _log_exec "清理 Pixi 环境 (方法1: pixi clean --environment default)" pixi clean --environment default || \
        _log_exec "清理 Pixi 环境 (方法2: pixi clean)" pixi clean || \
        _log_exec "清理 Pixi 环境 (方法3: rm -rf .pixi pixi.lock)" rm -rf .pixi pixi.lock
        _log_message "OK" "✓ 旧环境已清理"
    fi

    if [[ "${USE_CN_MIRROR}" == true ]]; then
        _log_message "EXEC" "▶ 配置国内镜像源"
        local PIXI_CONF="${HOME}/.pixi/config.toml"
        local PIXI_CONF_BAK="${PIXI_CONF}.bak"

        if [[ -f "${PIXI_CONF_BAK}" ]]; then
            cp "${PIXI_CONF}" /tmp/pixi_config.toml.live 2>/dev/null || true
            cp "${PIXI_CONF_BAK}" /tmp/pixi_config.toml.bak 2>/dev/null || true
        elif [[ -f "${PIXI_CONF}" ]]; then
            cp "${PIXI_CONF}" "${PIXI_CONF_BAK}"
        fi

        pixi config set --global pypi-config.index-url "https://mirror.nju.edu.cn/pypi/web/simple/" >> "$LOGFILE" 2>&1
        pixi config set --global default-channels '["https://pypi.mirrors.ustc.edu.cn/simple/"]' >> "$LOGFILE" 2>&1
        _log_message "OK" "✓ 国内镜像源已配置"
    fi

    _log_message "EXEC" "▶ pixi install --manifest-path pixi.toml (这可能需要较长时间)"
    if ! pixi install --manifest-path pixi.toml >> "$LOGFILE" 2>&1; then
        _log_message "ERROR" "✗ pixi install 失败"
        end_step "${ICON_ERROR}" "虚拟环境构建错误，详情请阅读日志：${LOGFILE}" "${RED}"
        exit 1
    fi
    _log_message "OK" "✓ pixi install 完成"

    if [[ "${USE_CN_MIRROR}" == true ]]; then
        if [[ -f "${PIXI_CONF_BAK}" ]]; then
            _log_message "EXEC" "▶ 恢复 Pixi 配置备份"
            mv -f "${PIXI_CONF_BAK}" "${PIXI_CONF}" >> "$LOGFILE" 2>&1
            _log_message "OK" "✓ Pixi 配置已恢复"
        fi
    fi

    _log_message "OK" "Pixi 虚拟环境已构建"
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
        _log_message "OK" "✓ deploy.yaml 已配置"
        end_step "${ICON_OK}" "cp ${TEMPLATE} config/deploy.yaml"
    else
        _log_message "WARNING" "模板文件 ${TEMPLATE} 不存在，跳过"
        end_step "${ICON_WARN}" "模板文件 ${TEMPLATE} 不存在，请手动执行 cp ${TEMPLATE} config/deploy.yaml" "${YELLOW}"
    fi
}

# ---------------------------- 第6步: systemd 服务 ----------------------------
configure_service() {
    if [[ "${SKIP_SERVICE}" == true ]]; then
        _log_message "INFO" "已跳过 systemd 服务配置 (--skip-service)"
        end_step "${ICON_INFO}" "已跳过 systemd 服务配置"
        return
    fi

    start_step "正在配置 systemd 开机自启..."

    PIXI_BIN_PATH=$(command -v pixi)
    _log_message "EXEC" "▶ 生成 /etc/systemd/system/run_alas.service"
    _log_message "INFO" "  用户: ${USER_NAME}, 组: ${USER_GROUP}"
    _log_message "INFO" "  工作目录: ${ALAS_DIR}"
    _log_message "INFO" "  启动命令: ${PIXI_BIN_PATH} run start"

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
        _log_message "OK" "systemd 服务运行正常"
        end_step "${ICON_OK}" "systemd 服务已启动并设为开机自启"
    else
        _log_message "ERROR" "systemd 服务启动失败"
        end_step "${ICON_ERROR}" "systemd 服务启动失败，请查看日志: ${LOGFILE}" "${RED}"
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
    echo_line "  ${ICON_WARN}  ${YELLOW}  - Pixi 虚拟环境${NC}"
    echo_line "  ${ICON_WARN}  ${YELLOW}  - ALAS 目录: ${INSTALL_DIR}${NC}"
    echo_line "  ${ICON_WARN}  ${YELLOW}  - 启动脚本: ${SCRIPT_OUT_DIR}/run_alas.sh${NC}"
    echo_line "  ${ICON_INFO}  ${GREEN}  依赖库 (git, adb, pixi) 不会被删除${NC}"
    echo_line ""
    _log_message "WARNING" "用户确认卸载流程开始"
    while true; do
        echo -n "  确认继续吗？ [yes/N] ："
        read -r CONFIRM < /dev/tty
        case "${CONFIRM}" in
            yes|YES)
                _log_message "INFO" "用户已确认卸载"
                break ;;
            no|NO|n|N)
                _log_message "INFO" "用户取消卸载"
                echo_line "  ${ICON_INFO}  已取消卸载"; exit 0 ;;
            *)
                echo_line "  ${ICON_WARN}  无效输入，请输入 yes 或 N" "${YELLOW}" ;;
        esac
    done

    echo_line ""

    start_step "正在停止 ALAS 服务..."
    if systemctl is-active --quiet run_alas.service 2>/dev/null; then
        _log_message "EXEC" "▶ systemctl stop run_alas.service"
        systemctl stop run_alas.service >> "$LOGFILE" 2>&1
        _log_message "OK" "✓ 服务已停止"
    fi
    if systemctl is-enabled --quiet run_alas.service 2>/dev/null; then
        _log_message "EXEC" "▶ systemctl disable run_alas.service"
        systemctl disable run_alas.service >> "$LOGFILE" 2>&1
        _log_message "OK" "✓ 服务已禁用"
    fi
    if [[ -f /etc/systemd/system/run_alas.service ]]; then
        _log_message "EXEC" "▶ 删除服务单元文件"
        rm -f /etc/systemd/system/run_alas.service
        systemctl daemon-reload >> "$LOGFILE" 2>&1
        _log_message "OK" "✓ 服务单元文件已删除"
    fi
    end_step "${ICON_OK}" "服务已停止并移除"

    start_step "正在清理 Pixi 虚拟环境..."
    cd "${INSTALL_DIR}"
    if [[ -d ".pixi" || -f "pixi.lock" ]]; then
        _log_message "EXEC" "▶ 清理 Pixi 环境"
        _log_exec "清理 Pixi 环境 (方法1: pixi clean --environment alas)" pixi clean --environment alas || \
        _log_exec "清理 Pixi 环境 (方法2: pixi clean)" pixi clean || \
        _log_exec "清理 Pixi 环境 (方法3: rm -rf .pixi pixi.lock)" rm -rf .pixi pixi.lock
        _log_message "OK" "✓ Pixi 环境已清理"
    else
        _log_message "INFO" "未检测到 Pixi 环境，跳过"
    fi
    end_step "${ICON_OK}" "虚拟环境已清理"

    start_step "正在删除 ALAS 目录..."
    _log_message "EXEC" "▶ rm -rf ${INSTALL_DIR}"
    rm -rf "${INSTALL_DIR}"
    _log_message "OK" "✓ ALAS 目录已删除"
    end_step "${ICON_OK}" "目录已删除"

    start_step "正在删除启动脚本..."
    _log_message "EXEC" "▶ rm -f ${SCRIPT_OUT_DIR}/run_alas.sh"
    rm -f "${SCRIPT_OUT_DIR}/run_alas.sh"
    _log_message "OK" "✓ 启动脚本已删除"
    end_step "${ICON_OK}" "启动脚本已删除"

    _log_message "OK" "ALAS 卸载完成"
    echo_line ""
    echo_line "${ICON_OK}  ${GREEN}ALAS 卸载完成${NC}"
    echo_line ""
}

# ---------------------------- 主流程 ----------------------------
main() {
    if [[ "${UNINSTALL}" == true ]]; then
        do_uninstall
        rm -f "$LOGFILE"
        exit 0
    fi

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
    if [[ "${KEEP_LOG}" == false ]]; then
        _log_message "INFO" "安装完成，清理日志文件: ${LOGFILE}"
        rm -f "$LOGFILE"
    else
        _log_message "INFO" "安装完成，日志已保存至: ${LOGFILE}"
        echo_line "  ${ICON_INFO}  日志已保存至：${LOGFILE}"
    fi
}

main