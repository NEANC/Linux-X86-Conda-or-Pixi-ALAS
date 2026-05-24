#!/bin/bash
#==============================================================================
# AzurLaneAutoScript macOS ARM Pixi 一键部署脚本
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
LOGFILE="$(mktemp /tmp/alas_install.XXXXXX.log)" || LOGFILE="/tmp/alas_install.$$.log"
touch "$LOGFILE" || { echo "无法创建日志文件 $LOGFILE"; exit 1; }

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

# ---------------------------- 颜色定义 ----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[37m'
NC='\033[0m'

# ---------------------------- 全局变量 ----------------------------
DEPLOY_TEMPLATE="config/deploy.template-linux.yaml"
USE_CN_MIRROR=false
GH_PROXY=""
WORK_DIR=""
ALAS_DIR=""
PIXI_BIN_PATH=""

SKIP_SERVICE=true
UNINSTALL=false
UNINSTALL_YES=false
KEEP_LOG=false
DEBUG=false
_TAIL_PID=""

# 优先取 sudo 前的用户；否则取当前用户
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    USER_NAME="${SUDO_USER}"
else
    USER_NAME="$(stat -f '%Su' /dev/console 2>/dev/null || whoami)"
fi

USER_HOME="$(dscl . -read "/Users/${USER_NAME}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
if [[ -z "${USER_HOME}" ]]; then
    USER_HOME="/Users/${USER_NAME}"
fi

HOME="${USER_HOME}"
export HOME

INSTALL_DIR="${HOME}/AzurLaneAutoScript"
SCRIPT_OUT_DIR="${HOME}/AzurLaneAutoScript"

_SPINNER_PID=""

# ---------------------------- 帮助 ----------------------------
usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  -d, --dir DIR          指定 ALAS 安装目录 (默认: ~/AzurLaneAutoScript)
  -s, --script-dir DIR   指定脚本输出目录 (默认: ~/AzurLaneAutoScript)
  -t TEMPLATE            控制使用的 deploy 模板与国内镜像源
  -S, --setup-service    配置 ALAS 开机自启
  --uninstall [-Y]       反向安装：停止并删除 ALAS、虚拟环境、开机自启
  -l, --log              保留安装日志，不自动删除
  -h, --help             显示帮助信息
  --debug                调试模式，日志将实时输出至终端
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
    if [[ "${DEBUG}" == true ]]; then
        printf '%b\n' "  ${ICON_GEAR}  ${YELLOW}${msg}${NC}"
        return 0
    fi
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
    if [[ -n "${_TAIL_PID}" ]]; then
        kill "${_TAIL_PID}" 2>/dev/null || true
    fi
    wait "${_TAIL_PID}" 2>/dev/null || true
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
        -d|--dir)
            [[ -z "${2-}" ]] && { log_error "缺少参数值: $1"; usage; exit 1; }
            INSTALL_DIR="$2"; shift 2 ;;
        -s|--script-dir)
            [[ -z "${2-}" ]] && { log_error "缺少参数值: $1"; usage; exit 1; }
            SCRIPT_OUT_DIR="$2"; shift 2 ;;
        -t|--template)
            [[ -z "${2-}" ]] && { log_error "缺少参数值: $1"; usage; exit 1; }
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
        -S|--setup-service) SKIP_SERVICE=false; shift ;;
        --debug) DEBUG=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "未知参数: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------- 平台检查 ----------------------------
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo -e "${RED}本脚本仅适用于 Apple Silicon macOS${NC}"
    exit 1
fi

# ---------------------------- sudo 警告 ----------------------------
_sudo_warning() {
    if [[ "$(id -u)" -ne 0 ]]; then
        return 0
    fi
    echo_line ""
    echo_line "  ${ICON_WARN}  ${YELLOW}警告！您正在使用 sudo/root 运行本脚本。${NC}"
    echo_line "  ${ICON_INFO}  ${GREEN}为了避免权限问题，建议使用非 root 用户安装。${NC}"
    echo_line ""
    while true; do
        echo -n "  是否继续？ [yes/N] ："
        read -r CONFIRM < /dev/tty
        CONFIRM=$(printf '%s' "${CONFIRM}" | tr -d '\r')
        case "${CONFIRM}" in
            yes|Yes|YES)
                _log_message "INFO" "已确认在 root 下继续执行"
                echo_line ""
                return 0 ;;
            no|NO|n|N)
                echo_line "  ${ICON_INFO}  已取消执行"; exit 0 ;;
            *)
                echo_line "  ${ICON_WARN}  ${YELLOW}无效输入，请输入 yes 或 N${NC}" ;;
        esac
    done
}

# ---------------------------- 系统信息收集 ----------------------------
gather_system_info() {
    NET_IP=$(ifconfig 2>/dev/null | grep "inet " | grep -Fv 127.0.0.1 | awk '{print $2}' | head -1 || echo "未获取")
    if [[ -z "${NET_IP}" ]]; then
        NET_IP="未获取"
    fi
    MACOS_VER=$(sw_vers -productVersion 2>/dev/null || echo "未知")
    CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "未知")
    CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo "未知")
    DISK_AVAIL=$(df -h / | awk 'NR==2{print $4}' || echo "未知")
    DISK_USED=$(df -h / | awk 'NR==2{print $3}' || echo "未知")
    DISK_INFO="可用: ${DISK_AVAIL}  已用: ${DISK_USED}"
    RAM_SIZE_MIB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}' || echo "未知")
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
    echo_line "  ${ICON_COMPUTER}  ARM macOS 中基于 Pixi 的 ALAS 部署脚本"
    echo_line "  ─────────────────────────────────────────────────"
    echo_line "  ${ICON_INFO}  当前局域网 IP  : ${BLUE}${NET_IP}${NC}"
    echo_line "  ${ICON_GEAR}   macOS 版本     : ${GREEN}${MACOS_VER}${NC}"
    echo_line "  ${ICON_COMPUTER}   CPU 型号       : ${GREEN}${CPU_MODEL}${NC}"
    echo_line "  ${ICON_CPU}  CPU 核心数     : ${GREEN}${CPU_CORES}${NC}"
    echo_line "  ${ICON_DISK}  磁盘大小       : ${BLUE}${DISK_INFO}${NC}"

    local ram_color="${GREEN}"
    if [[ "${RAM_SIZE_MIB}" -lt 8000 ]]; then
        ram_color="${YELLOW}"
    elif [[ "${RAM_SIZE_MIB}" -lt 16000 ]]; then
        ram_color="${BLUE}"
    fi

    echo_line "  ${ICON_RAM}  内存大小       : ${ram_color}${RAM_SIZE_MIB} MiB${NC}"
    echo_line "  ${ICON_USER}  当前用户       : ${GREEN}${USER_NAME}${NC}"
    echo_line ""
}

# ---------------------------- 安装 Homebrew ----------------------------
install_homebrew() {
    start_step "正在检查 Homebrew..."

    if command -v brew &>/dev/null; then
        BREW_VER=$(brew --version 2>/dev/null | head -n1 | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Homebrew 已就绪: ${BREW_VER}"
        return
    fi
    _log_message "WARNING" "未检测到 Homebrew"
    start_step "正在安装 Homebrew..."
    if ! /bin/bash -c "$(curl -fsSL ${GH_PROXY}https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >> "$LOGFILE" 2>&1; then
        end_step "${ICON_ERROR}" "Homebrew 安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
        exit 1
    fi
    _log_message "OK" "✓ Homebrew 安装已完成"

    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    if command -v brew &>/dev/null; then
        BREW_VER=$(brew --version 2>/dev/null | head -n1 | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Homebrew 已安装: ${BREW_VER}"
    else
        _log_message "ERROR" "Homebrew 安装后未找到 brew 可执行文件"
        end_step "${ICON_ERROR}" "Homebrew 安装失败，请查看日志: ${LOGFILE}" "${RED}"
        exit 1
    fi
}

# ---------------------------- 检查依赖 ----------------------------
install_packages() {
    start_step "正在检查依赖..."

    local missing_formulae=()
    local check_list=(git android-platform-tools pixi)

    for pkg in "${check_list[@]}"; do
        if brew list --formula "$pkg" &>/dev/null; then
            _log_message "OK" "依赖已存在: ${pkg}"
        else
            _log_message "WARNING" "依赖缺失: ${pkg}"
            missing_formulae+=("$pkg")
        fi
    done

    if [[ ${#missing_formulae[@]} -eq 0 ]]; then
        end_step "${ICON_OK}" "Git 已安装: $(git --version 2>/dev/null | awk '{print $NF}')"
        end_step "${ICON_OK}" "ADB 已安装: $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
        end_step "${ICON_OK}" "Pixi 已安装: $(pixi --version 2>/dev/null | awk '{print $NF}')"
        return
    fi

    start_step "正在安装缺失的依赖: ${missing_formulae[*]}..."

    if [[ "${USE_CN_MIRROR}" == true ]]; then
        local -a brew_mirrors=(
            "https://mirrors.ustc.edu.cn/homebrew-bottles"
            "https://mirrors.aliyun.com/homebrew/homebrew-bottles"
            "https://repo.huaweicloud.com/homebrew"
        )
        local mirror_url
        for mirror_url in "${brew_mirrors[@]}"; do
            _log_message "INFO" "尝试 Homebrew 镜像: ${mirror_url}"
            if HOMEBREW_BREW_GIT_REMOTE="${mirror_url}/brew.git" \
               HOMEBREW_CORE_GIT_REMOTE="${mirror_url}/homebrew-core.git" \
               HOMEBREW_BOTTLE_DOMAIN="${mirror_url}" \
               brew install "${missing_formulae[@]}" >> "$LOGFILE" 2>&1; then
                _log_message "OK" "✓ Homebrew 镜像 ${mirror_url} 安装成功"
                break
            fi
            _log_message "WARNING" "镜像 ${mirror_url} 不可用，尝试下一个"
        done
        if [[ ${#missing_formulae[@]} -gt 0 ]]; then
            if ! brew list --formula "${missing_formulae[@]}" &>/dev/null; then
                _log_message "ERROR" "✗ CN 镜像 brew install 失败"
                end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
                exit 1
            fi
        fi
    else
        _log_message "EXEC" "▶ brew install ${missing_formulae[*]}"
        if ! brew install "${missing_formulae[@]}" >> "$LOGFILE" 2>&1; then
            _log_message "ERROR" "✗ brew install 失败"
            end_step "${ICON_ERROR}" "依赖安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
            exit 1
        fi
    fi

    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
    fi
    end_step "${ICON_OK}" "Git 已安装: $(git --version 2>/dev/null | awk '{print $NF}')"
    end_step "${ICON_OK}" "ADB 已安装: $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
    end_step "${ICON_OK}" "Pixi 已安装: $(pixi --version 2>/dev/null | awk '{print $NF}')"
    _log_message "OK" "✓ 依赖安装完成"
}

# ---------------------------- 克隆 ALAS 仓库 ----------------------------
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
                _log_message "OK" "git 远程 URL 验证通过: ${_ca_origin_url}"
                _log_message "WARNING" "ALAS 仓库已存在，跳过克隆: ${WORK_DIR}"
                end_step "${ICON_WARN}" "ALAS 仓库已存在，跳过克隆" "${YELLOW}"
                cd "${WORK_DIR}"
                ALAS_DIR="${WORK_DIR}"
                return
                ;;
            "")
                _log_message "WARNING" "目录 ${WORK_DIR} 中无 .git 信息，可能是非完整 ALAS 安装，将覆盖安装"
                _log_message "EXEC" "▶ 删除旧目录: rm -rf ${WORK_DIR}"
                rm -rf "${WORK_DIR}" ;;
            *)
                _log_message "ERROR" "安装目录已存在，但不是 AzurLaneAutoScript 仓库: ${WORK_DIR} (remote: ${_ca_origin_url})"
                end_step "${ICON_ERROR}" "安装目录已存在且是其他 git 仓库 (${_ca_origin_url})，请使用 --dir 参数指定目录或手动处理" "${RED}"
                exit 1 ;;
        esac
    fi

    REPO_URL="https://github.com/LmeSzinc/AzurLaneAutoScript.git"
    _log_message "EXEC" "▶ git clone ${GH_PROXY}${REPO_URL} ${WORK_DIR}"

    if ! git clone "${GH_PROXY}${REPO_URL}" "${WORK_DIR}" >> "$LOGFILE" 2>&1; then
        end_step "${ICON_ERROR}" "仓库克隆错误，详情请阅读日志：${LOGFILE}" "${RED}"
        exit 1
    fi
    _log_message "OK" "✓ 仓库克隆完成"
    cd "${WORK_DIR}"
    ALAS_DIR="${WORK_DIR}"

    _log_message "OK" "ALAS 目录: ${ALAS_DIR}"
    end_step "${ICON_OK}" "ALAS 仓库已克隆"
}

# ---------------------------- 配置 Pixi 虚拟环境 ----------------------------
setup_pixi_env() {
    start_step "正在配置 Pixi 虚拟环境..."

    cd "${ALAS_DIR}"
    if [[ -f pixi.toml ]]; then
        _log_message "EXEC" "▶ 备份已有 pixi.toml → pixi.toml.bak"
        cp pixi.toml pixi.toml.bak
        _log_message "OK" "✓ 备份完成"
    fi

    _log_message "EXEC" "▶ 生成 pixi.toml"
    cat > pixi.toml << 'PIXI_EOF'
[workspace]
channels = ["conda-forge"]
name = "alas"
platforms = ["osx-arm64"]
version = "0.1.0"

[tasks]
start = "python gui.py"

[dependencies]
python = "==3.8.5"
av = ">=8.0.3,<9"
numpy = "==1.24.4"
scipy = ">=1.10,<1.11"
pillow = "*"
packaging = ">=20.3,<21"
pyzmq = "*"

[pypi-dependencies]
opencv-python = "*"
imageio = "==2.27.0"
adbutils = "==0.11.0"
uiautomator2 = "==2.16.17"
uiautomator2cache = "==0.3.0.1"
wrapt = "==1.13.1"
retrying = "*"
lz4 = "*"
psutil = "==5.9.3"
rich = "==11.2.0"
tqdm = "*"
jellyfish = "==0.11.2"
pyyaml = "*"
inflection = "*"
pydantic = "*"
aiofiles = "*"
prettytable = "==2.2.1"
anyio = "==1.3.1"
onepush = "==1.4.0"
pycryptodome = "==3.9.9"
pypresence = "==4.2.1"
cnocr = ">=1.2.2,<2"
mxnet = "==1.6.0"
pywebio = "==1.6.2"
starlette = "==0.14.2"
uvicorn = { version = "==0.17.6", extras = ["standard"] }
alas-webapp = "==0.3.7"
zerorpc = "==0.6.3"
PIXI_EOF
    _log_message "OK" "✓ pixi.toml 已生成"

    if [[ "${USE_CN_MIRROR}" == true ]]; then
        _se_cernet_conda="https://mirrors.cernet.edu.cn/anaconda"
        _se_cernet_pypi="https://mirrors.cernet.edu.cn/pypi/web/simple"

        _log_message "EXEC" "▶ 配置国内镜像源 (cernet)"
        sed -i '' "s|channels = \\[\"conda-forge\"\\]|channels = [\"${_se_cernet_conda}/cloud/conda-forge\"]|" pixi.toml
        cat >> pixi.toml << PIXI_MIRROR_EOF
[pypi-options]
index-url = "${_se_cernet_pypi}"
PIXI_MIRROR_EOF
        _log_message "OK" "✓ 国内镜像源已配置至 pixi.toml"
    fi

    if [[ -d ".pixi/envs/default" || -d ".pixi/envs/alas" || -f "pixi.lock" ]]; then
        {
            _log_message "WARNING" "检测到已有 Pixi 环境，正在清理..."
            _log_message "EXEC" "▶ pixi clean cache -y"
            pixi clean cache -y || true
            _log_message "EXEC" "▶ pixi clean --environment default"
            pixi clean --environment default || \
            _log_message "EXEC" "▶ pixi clean"
            pixi clean || \
            _log_message "EXEC" "▶ rm -rf .pixi pixi.lock"
            rm -rf .pixi pixi.lock || true
            _log_message "OK" "✓ 旧环境已清理"
        } >> "$LOGFILE" 2>&1 || true
    fi

    _se_install_log="/tmp/pixi_install_$$.log"
    _se_install_attempt=1
    _se_cn_fallback_done=false
    while true; do
        _log_message "EXEC" "▶ pixi install --manifest-path pixi.toml (第 ${_se_install_attempt} 次)"
        if pixi install --manifest-path pixi.toml > "${_se_install_log}" 2>&1; then
            cat "${_se_install_log}" >> "$LOGFILE" 2>/dev/null || true
            rm -f "${_se_install_log}"
            break
        fi

        cat "${_se_install_log}" >> "$LOGFILE" 2>/dev/null || true
        if [[ "${USE_CN_MIRROR}" == true && "${_se_cn_fallback_done}" != true ]] && \
           grep -Eqi '403|403 Forbidden|HTTP.*403' "${_se_install_log}" 2>/dev/null; then
            _log_message "WARNING" "国内镜像源不可用（403 Forbidden），自动降级到官方源"
            rm -f "${_se_install_log}"
            _se_cn_fallback_done=true
            sed -i '' 's|channels = \["https://mirrors\.cernet\.edu\.cn/anaconda/cloud/conda-forge"\]|channels = ["conda-forge"]|' pixi.toml
            sed -i '' '/\[pypi-options\]/,/^\[.*\]/ { /index-url = /d; /^$/d; }' pixi.toml 2>/dev/null || true
            {
                _log_message "WARNING" "检测到已有 Pixi 环境，正在清理..."
                _log_message "EXEC" "▶ pixi clean cache -y"
                pixi clean cache -y || true
                _log_message "EXEC" "▶ pixi clean --environment default"
                pixi clean --environment default || \
                _log_message "EXEC" "▶ pixi clean"
                pixi clean || \
                _log_message "EXEC" "▶ rm -rf .pixi pixi.lock"
                rm -rf .pixi pixi.lock || true
                _log_message "OK" "✓ 旧环境已清理"
            } >> "$LOGFILE" 2>&1 || true
            _se_install_attempt=$((_se_install_attempt + 1))
            continue
        fi

        _log_message "ERROR" "✗ pixi install 失败"
        end_step "${ICON_ERROR}" "虚拟环境构建错误，详情请阅读日志：${LOGFILE}" "${RED}"
        rm -f "${_se_install_log}"
        exit 1
    done

    end_step "${ICON_OK}" "虚拟环境已构建"
}

# ---------------------------- 配置部署 ----------------------------
configure_deploy() {
    start_step "复制 deploy.yaml..."

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
        end_step "${ICON_OK}" "deploy.yaml 已复制"
    else
        end_step "${ICON_WARN}" "模板文件 ${TEMPLATE} 不存在，请手动重命名 deploy.yaml-linux.yaml" "${YELLOW}"
    fi
}

# ---------------------------- 创建启动脚本 ----------------------------
create_launcher() {
    start_step "正在创建启动脚本..."

    PIXI_BIN_PATH=$(command -v pixi)

    cat > "${SCRIPT_OUT_DIR}/run_alas.sh" <<EOF
#!/bin/bash
cd "${ALAS_DIR}"
"${PIXI_BIN_PATH}" run start
EOF
    chmod +x "${SCRIPT_OUT_DIR}/run_alas.sh"
    _log_message "OK" "✓ 启动脚本已创建: ${SCRIPT_OUT_DIR}/run_alas.sh"

    end_step "${ICON_OK}" "启动脚本已创建: ${SCRIPT_OUT_DIR}/run_alas.sh"
}

# ---------------------------- 配置 launchctl 服务 ----------------------------
configure_service() {
    start_step "正在配置 launchctl 服务..."

    local run_at_load="false"
    if [[ "${SKIP_SERVICE}" == false ]]; then
        run_at_load="true"
    fi

    local plist_dir="${HOME}/Library/LaunchAgents"
    mkdir -p "${plist_dir}"

    _log_message "EXEC" "▶ 生成 ${plist_dir}/com.alas.run.plist"
    _log_message "INFO" "  用户: ${USER_NAME}"
    _log_message "INFO" "  ALAS 目录: ${ALAS_DIR}"
    _log_message "INFO" "  RunAtLoad: ${run_at_load}"

    cat > "${plist_dir}/com.alas.run.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.alas.run</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SCRIPT_OUT_DIR}/run_alas.sh</string>
    </array>
    <key>RunAtLoad</key>
    <${run_at_load}/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF
    chmod 644 "${plist_dir}/com.alas.run.plist"
    _log_message "OK" "✓ plist 文件已创建"

    _log_message "EXEC" "▶ launchctl bootout (卸载旧服务)"
    launchctl bootout "gui/$(id -u)/com.alas.run" 2>/dev/null || true
    _log_message "EXEC" "▶ launchctl bootstrap (注册新服务)"
    launchctl bootstrap "gui/$(id -u)" "${plist_dir}/com.alas.run.plist"

    if launchctl list 2>/dev/null | grep -q "com.alas.run"; then
        _log_message "OK" "launchctl 服务已注册"
        _log_message "EXEC" "▶ launchctl stop/start com.alas.run（立即启动）"
        launchctl stop com.alas.run 2>/dev/null || true
        launchctl start com.alas.run
        _log_message "OK" "✓ ALAS 服务已启动"
        if [[ "${run_at_load}" == true ]]; then
            end_step "${ICON_OK}" "开机自启服务已配置，请在下次重启后验证 ALAS 是否正常运行"
        else
            end_step "${ICON_OK}" "系统服务已配置，请在下次重启后双击 运行ALAS.command 启动 ALAS"
        fi
    else
end_step "${ICON_WARN}" "未成功注册 launchd 服务，请检查 plist 文件" "${YELLOW}"
    fi
}

# ---------------------------- 创建桌面快捷脚本 ----------------------------
create_desktop_commands() {
    start_step "正在创建桌面快捷脚本..."

    local desktop_dir="${HOME}/Desktop"
    mkdir -p "${desktop_dir}"

    _log_message "EXEC" "▶ 创建 ${desktop_dir}/运行ALAS.command"
    cat > "${desktop_dir}/运行ALAS.command" << 'CMD_EOF'
#!/bin/bash
WINDOW_ID=$(osascript -e 'tell application "Terminal" to id of front window')
(sleep 3 && open "http://127.0.0.1:22267") &
launchctl kickstart -k "gui/$(id -u)/com.alas.run" 2>/dev/null || launchctl start com.alas.run
osascript -e "tell application \"Terminal\" to close window id $WINDOW_ID"
CMD_EOF
    chmod +x "${desktop_dir}/运行ALAS.command"
    _log_message "OK" "✓ 运行ALAS.command 已生成"

    _log_message "EXEC" "▶ 创建 ${desktop_dir}/停止ALAS.command"
    cat > "${desktop_dir}/停止ALAS.command" << 'CMD_EOF'
#!/bin/bash
WINDOW_ID=$(osascript -e 'tell application "Terminal" to id of front window')
launchctl stop com.alas.run
osascript -e "tell application \"Terminal\" to close window id $WINDOW_ID"
CMD_EOF
    chmod +x "${desktop_dir}/停止ALAS.command"
    _log_message "OK" "✓ 停止ALAS.command 已生成"

    _log_message "EXEC" "▶ 创建 ${desktop_dir}/重启ALAS.command"
    cat > "${desktop_dir}/重启ALAS.command" << 'CMD_EOF'
#!/bin/bash
WINDOW_ID=$(osascript -e 'tell application "Terminal" to id of front window')
(sleep 3 && open "http://127.0.0.1:22267") &
launchctl kickstart -k "gui/$(id -u)/com.alas.run" 2>/dev/null || launchctl start com.alas.run
osascript -e "tell application \"Terminal\" to close window id $WINDOW_ID"
CMD_EOF
    chmod +x "${desktop_dir}/重启ALAS.command"
    _log_message "OK" "✓ 重启ALAS.command 已生成"

    end_step "${ICON_OK}" "桌面快捷脚本已创建: ${desktop_dir}"
}

# ---------------------------- 完成摘要 ----------------------------
print_completion() {
    echo_line ""
    echo_line "${ICON_ROCKET}  ALAS 已经完成安装，请通过 ${CYAN}http://${NET_IP}:22267${NC} 访问 WEBUI"
    echo_line "  ─────────────────────────────────────────────────"
    echo_line "  ${ICON_INFO}  ALAS已安装到:  ${BLUE}${ALAS_DIR}${NC}"

    if [ "${SKIP_SERVICE}" = false ]; then
        echo_line "  ${ICON_INFO}  ${GREEN}开机自启服务已配置${NC}"
    fi
    echo_line ""
    echo_line "  ${ICON_INFO}  桌面快捷脚本 (双击即可)："
    echo_line "      ${CYAN}运行ALAS.command${NC}"
    echo_line "      ${CYAN}停止ALAS.command${NC}"
    echo_line "      ${CYAN}重启ALAS.command${NC}"
    echo_line ""
    echo_line "  ${ICON_INFO}  命令行管理："
    echo_line "      启动服务: ${CYAN}launchctl start com.alas.run${NC}"
    echo_line "      停止服务: ${CYAN}launchctl stop com.alas.run${NC}"
    echo_line "      检查状态: ${CYAN}launchctl list com.alas.run${NC}"
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
    echo_line "  ${ICON_WARN}  ${YELLOW}  - 桌面快捷脚本: 运行ALAS/停止ALAS/重启ALAS.command${NC}"
    echo_line "  ${ICON_INFO}  ${GREEN}  Homebrew, git, adb, pixi 不会被删除${NC}"
    echo_line ""
    _log_message "WARNING" "等待确认卸载"
    if [[ "${UNINSTALL_YES}" == true ]]; then
        _log_message "INFO" "已通过 -Y 自动确认卸载"
    else
        while true; do
            echo -n "  确认继续吗？ [yes/N] ："
            read -r CONFIRM < /dev/tty
            CONFIRM=$(printf '%s' "${CONFIRM}" | tr -d '\r')
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

    start_step "正在停止 ALAS 服务..."
    _svc_done=false
    if launchctl list "com.alas.run" &>/dev/null; then
        _log_message "EXEC" "▶ launchctl bootout gui/$(id -u)/com.alas.run"
        launchctl bootout "gui/$(id -u)/com.alas.run" 2>/dev/null || true
        _svc_done=true
    fi
    if [[ -f "${HOME}/Library/LaunchAgents/com.alas.run.plist" ]]; then
        _log_message "EXEC" "▶ rm -f plist 文件"
        rm -f "${HOME}/Library/LaunchAgents/com.alas.run.plist"
        _svc_done=true
    fi
    if [[ "$_svc_done" == true ]]; then
        end_step "${ICON_OK}" "服务已停止并移除"
    else
        end_step "${ICON_INFO}" "未检测到 ALAS 服务，跳过" "${GREEN}"
    fi

    start_step "正在清理 Pixi 虚拟环境..."
    if [[ -d "${INSTALL_DIR}" ]]; then
        cd "${INSTALL_DIR}"
        if [[ -d ".pixi" || -f "pixi.lock" ]]; then
            _log_message "EXEC" "▶ 清理 Pixi 环境"
            _log_exec "清理 Pixi 环境 (方法1: pixi clean --environment default)" pixi clean --environment default || \
            _log_exec "清理 Pixi 环境 (方法2: pixi clean)" pixi clean || \
            _log_exec "清理 Pixi 环境 (方法3: rm -rf .pixi pixi.lock)" rm -rf .pixi pixi.lock
        else
            _log_message "INFO" "未检测到 Pixi 环境，跳过清理"
        fi
        end_step "${ICON_OK}" "虚拟环境已清理"
    else
        end_step "${ICON_INFO}" "ALAS 目录不存在，跳过虚拟环境清理" "${GREEN}"
    fi

    start_step "正在删除启动脚本..."
    if [[ -f "${SCRIPT_OUT_DIR}/run_alas.sh" ]]; then
        _log_message "EXEC" "▶ rm -f ${SCRIPT_OUT_DIR}/run_alas.sh"
        rm -f "${SCRIPT_OUT_DIR}/run_alas.sh"
        end_step "${ICON_OK}" "启动脚本已删除"
    else
        end_step "${ICON_INFO}" "启动脚本不存在，跳过" "${GREEN}"
    fi

    start_step "正在删除桌面快捷脚本..."
    _desktop_cleaned=false
    for _df in "${HOME}/Desktop/运行ALAS.command" "${HOME}/Desktop/停止ALAS.command" "${HOME}/Desktop/重启ALAS.command"; do
        if [[ -f "$_df" ]]; then
            _log_message "EXEC" "▶ rm -f $_df"
            rm -f "$_df"
            _desktop_cleaned=true
        fi
    done
    if [[ "$_desktop_cleaned" == true ]]; then
        end_step "${ICON_OK}" "桌面快捷脚本已删除"
    else
        end_step "${ICON_INFO}" "桌面快捷脚本不存在，跳过" "${GREEN}"
    fi

    start_step "正在删除 ALAS 目录..."
    if [[ -d "${INSTALL_DIR}" ]]; then
        _log_message "EXEC" "▶ rm -rf ${INSTALL_DIR}"
        cd / 2>/dev/null || true
        rm -rf "${INSTALL_DIR}"
        end_step "${ICON_OK}" "目录已删除"
    else
        end_step "${ICON_INFO}" "ALAS 目录已不存在，跳过" "${GREEN}"
    fi

    if [[ "${KEEP_LOG}" == false ]]; then
        _log_message "INFO" "清理日志文件: ${LOGFILE}"
        rm -f "$LOGFILE"
    fi
    _log_message "OK" "ALAS 卸载完成"
    echo_line ""
    echo_line "${ICON_OK}  ${GREEN}ALAS 卸载完成${NC}"
    echo_line ""
}

# ---------------------------- 主流程 ----------------------------
main() {
    if [[ "${UNINSTALL}" == true ]]; then
        if [[ "${DEBUG}" == true ]] && command -v tail >/dev/null 2>&1; then
            tail -n +0 -f "$LOGFILE" 2>/dev/null &
            _TAIL_PID=$!
            printf '%b\n' "  ${ICON_GEAR}  ${CYAN}检测到 --debug, 进入调试模式${NC}"
            printf '%b\n' "  ${ICON_GEAR}  ${CYAN}日志将实时输出至终端${NC}"
            echo_line ""
        fi
        _sudo_warning
        gather_system_info
        print_header
        do_uninstall
        if [[ -n "${_TAIL_PID}" ]]; then
            kill "${_TAIL_PID}" 2>/dev/null || true
            wait "${_TAIL_PID}" 2>/dev/null || true
        fi
        exit 0
    fi

    if [[ "${DEBUG}" == true ]] && command -v tail >/dev/null 2>&1; then
        tail -n +0 -f "$LOGFILE" 2>/dev/null &
        _TAIL_PID=$!
        printf '%b\n' "  ${ICON_GEAR}  ${CYAN}检测到 --debug, 进入调试模式${NC}"
        printf '%b\n' "  ${ICON_GEAR}  ${CYAN}日志将实时输出至终端${NC}"
        echo_line ""
    fi

    _sudo_warning
    gather_system_info
    print_header
    install_homebrew
    install_packages
    clone_alas
    setup_pixi_env
    configure_deploy
    create_launcher
    create_desktop_commands
    configure_service
    print_completion

    if [[ -n "${_TAIL_PID}" ]]; then
        kill "${_TAIL_PID}" 2>/dev/null || true
        wait "${_TAIL_PID}" 2>/dev/null || true
    fi

    if [[ "${KEEP_LOG}" == false ]]; then
        _log_message "INFO" "安装完成，清理日志文件: ${LOGFILE}"
        rm -f "$LOGFILE"
    else
        echo_line ""
        echo_line "  ${ICON_INFO}  日志已保存至：${LOGFILE}"
        echo_line ""
    fi
}
main
