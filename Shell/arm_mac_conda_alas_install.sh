#!/bin/bash
#==============================================================================
# AzurLaneAutoScript macOS ARM Conda 一键部署脚本
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

exec {TRACE_FD}>>"$LOGFILE"
BASH_XTRACEFD=$TRACE_FD
PS4='+$(date "+%H:%M:%S") | '
set -x

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
INSTALL_DIR="${HOME}/AzurLaneAutoScript"
SCRIPT_OUT_DIR="${HOME}/AzurLaneAutoScript"
DEPLOY_TEMPLATE="config/deploy.template-linux.yaml"
USE_CN_MIRROR=false
GH_PROXY=""
WORK_DIR=""
ALAS_DIR=""
CONDA_BIN=""
USER_NAME="$(whoami)"
_SPINNER_PID=""
SKIP_SERVICE=false
UNINSTALL=false

# ---------------------------- 帮助 ----------------------------
usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  -d, --dir DIR          指定 ALAS 安装目录 (默认: ~/AzurLaneAutoScript)
  -s, --script-dir DIR   指定脚本输出目录 (默认: ~/AzurLaneAutoScript)
  -t TEMPLATE            控制使用的 deploy 模板与国内镜像源
  -S, --skip-service     跳过开机自启服务配置
  --uninstall            反向安装：停止并删除 ALAS、虚拟环境、开机自启
  -h, --help             显示帮助信息
EOF
}

# ---------------------------- 输出与日志函数 ----------------------------
echo_line() {
    local term_line="$1"
    echo -e "$term_line"
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
            sleep 0.30 2>/dev/null || true
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
        -S|--skip-service) SKIP_SERVICE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "未知参数: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------- 平台检查 ----------------------------
if [[ "$(uname)" != "Darwin" ]]; then
    echo -e "${RED}本脚本仅适用于 arm 架构的 macOS 系统${NC}"
    exit 1
fi

# ---------------------------- 系统信息收集 ----------------------------
gather_system_info() {
    NET_IP=$(ifconfig 2>/dev/null | grep "inet " | grep -Fv 127.0.0.1 | awk '{print $2}' | head -1 || echo "未获取")
    [[ -z "${NET_IP}" ]] && NET_IP="未获取"
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
    clear
    echo_line "${WHITE}"
    echo_line "    ___    __    ___   _____"
    echo_line "   /   |  / /   /   | / ___/"
    echo_line "  / /| | / /   / /| | \\__ \\ "
    echo_line " / ___ |/ /___/ ___ |___/ / "
    echo_line "/_/  |_/_____/_/  |_/____/  "
    echo_line "${NC}"
    echo_line "  ${ICON_COMPUTER}  ARM macOS 中基于 Conda 的 ALAS 部署脚本"
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

# ---------------------------- 第1步: 安装 Homebrew ----------------------------
install_homebrew() {
    start_step "正在检查 Homebrew..."

    if command -v brew &>/dev/null; then
        BREW_VER=$(brew --version 2>/dev/null | head -n1 | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Homebrew 已就绪: ${BREW_VER}"
        return
    fi

    /bin/bash -c "$(curl -fsSL ${GH_PROXY}https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >> "$LOGFILE" 2>&1

    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    if command -v brew &>/dev/null; then
        BREW_VER=$(brew --version 2>/dev/null | head -n1 | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Homebrew 已安装: ${BREW_VER}"
    else
        end_step "${ICON_ERROR}" "Homebrew 安装失败，请查看日志: ${LOGFILE}" "${RED}"
        exit 1
    fi
}

# ---------------------------- 第2步: 安装 Miniforge、Git 和 ADB ----------------------------
install_packages() {
    start_step "正在检查依赖库..."

    local missing_formulae=()
    local check_list=(miniforge git android-platform-tools)

    for pkg in "${check_list[@]}"; do
        if brew list --formula "$pkg" &>/dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S')   ${ICON_OK} ${pkg} 已安装" >> "$LOGFILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S')   ${ICON_WARN} ${pkg} 未安装" >> "$LOGFILE"
            missing_formulae+=("$pkg")
        fi
    done

    if [[ ${#missing_formulae[@]} -eq 0 ]]; then
        end_step "${ICON_OK}" "Git 已安装: $(git --version 2>/dev/null | awk '{print $NF}')"
        end_step "${ICON_OK}" "ADB 已安装: $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
        CONDA_BIN=$(command -v conda 2>/dev/null || echo "${HOME}/miniforge3/bin/conda")
        end_step "${ICON_OK}" "Conda 已就绪: $(conda --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')"
        echo "$(date '+%Y-%m-%d %H:%M:%S')   Git: $(git --version 2>/dev/null)" >> "$LOGFILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S')   ADB: $(adb --version 2>/dev/null | head -n1)" >> "$LOGFILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S')   Conda: $(conda --version 2>/dev/null)" >> "$LOGFILE"
        return
    fi

    start_step "正在安装缺失的依赖..."

    brew install "${missing_formulae[@]}" >> "$LOGFILE" 2>&1

    # 激活 miniforge
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
    fi

    end_step "${ICON_OK}" "Git 已安装: $(git --version 2>/dev/null | awk '{print $NF}')"
    end_step "${ICON_OK}" "ADB 已安装: $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
    CONDA_BIN=$(command -v conda 2>/dev/null || echo "${HOME}/miniforge3/bin/conda")
    end_step "${ICON_OK}" "Conda 已就绪: $(conda --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')"
    echo "$(date '+%Y-%m-%d %H:%M:%S')   Git: $(git --version 2>/dev/null)" >> "$LOGFILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S')   ADB: $(adb --version 2>/dev/null | head -n1)" >> "$LOGFILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S')   Conda: $(conda --version 2>/dev/null)" >> "$LOGFILE"
}

# ---------------------------- 第3步: 克隆仓库 ----------------------------
clone_alas() {
    start_step "正在克隆 AzurLaneAutoScript 仓库..."

    WORK_DIR="${INSTALL_DIR}"
    if [[ -d "${WORK_DIR}" ]]; then
        end_step "${ICON_WARN}" "ALAS 目录已存在，跳过克隆" "${YELLOW}"
        cd "${WORK_DIR}"
        ALAS_DIR="${WORK_DIR}"
        return
    fi

    REPO_URL="https://github.com/LmeSzinc/AzurLaneAutoScript.git"

    git clone "${GH_PROXY}${REPO_URL}" "${WORK_DIR}" >> "$LOGFILE" 2>&1
    cd "${WORK_DIR}"
    ALAS_DIR="${WORK_DIR}"

    end_step "${ICON_OK}" "ALAS 仓库已克隆"
}

# ---------------------------- 第4步: 配置虚拟环境 ----------------------------
setup_conda_env() {
    start_step "正在配置 Conda 虚拟环境..."

    cd "${ALAS_DIR}"
    if [[ -f environment.yml ]]; then
        cp environment.yml environment.yml.bak
    fi

    ENV_URL="https://raw.githubusercontent.com/Dreamry2C/MAC-arm-conda-alas/master/environment.yml"

    curl -fsSL -o environment.yml "${GH_PROXY}${ENV_URL}" >> "$LOGFILE" 2>&1

    eval "$("${CONDA_BIN}" shell.bash hook)" >> "$LOGFILE" 2>&1

    if [[ "${USE_CN_MIRROR}" == true ]]; then
        conda config --prepend channels https://mirror.nju.edu.cn/anaconda/cloud/conda-forge/ >> "$LOGFILE" 2>&1
        conda config --prepend channels https://mirror.nju.edu.cn/anaconda/pkgs/main/ >> "$LOGFILE" 2>&1
        conda config --append channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge/ >> "$LOGFILE" 2>&1
        conda config --append channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main/ >> "$LOGFILE" 2>&1
        conda config --append channels https://mirror.sjtu.edu.cn/anaconda/cloud/conda-forge/ >> "$LOGFILE" 2>&1
        conda config --append channels https://mirror.sjtu.edu.cn/anaconda/pkgs/main/ >> "$LOGFILE" 2>&1

        export PIP_INDEX_URL="https://pypi.mirrors.ustc.edu.cn/simple/"
        export PIP_EXTRA_INDEX_URL="https://mirrors.aliyun.com/pypi/simple/ https://pypi.tuna.tsinghua.edu.cn/simple/"
        export PIP_TRUSTED_HOST="pypi.mirrors.ustc.edu.cn mirrors.aliyun.com pypi.tuna.tsinghua.edu.cn"
        export PIP_TIMEOUT=60
    fi

    if conda env list 2>/dev/null | grep -q "^alas "; then
        conda env remove -n alas -y >> "$LOGFILE" 2>&1 || \
        rm -rf "$(conda info --base 2>/dev/null)/envs/alas" >> "$LOGFILE" 2>&1
    fi

    conda env create -f environment.yml >> "$LOGFILE" 2>&1

    unset PIP_INDEX_URL PIP_EXTRA_INDEX_URL

    if ! conda run -n alas python -c "import alas_webapp" >> "$LOGFILE" 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S')   尝试修复缺失依赖..." >> "$LOGFILE"
        conda env update -n alas --file environment.yml >> "$LOGFILE" 2>&1 || true
    fi

    end_step "${ICON_OK}" "虚拟环境已构建"
}

# ---------------------------- 第5步: 配置 deploy.yaml ----------------------------
configure_deploy() {
    start_step "复制 deploy.yaml..."

    cd "${ALAS_DIR}"
    if [[ -f config/deploy.yaml ]]; then
        cp config/deploy.yaml config/deploy.yaml.bak
    fi

    TEMPLATE="${DEPLOY_TEMPLATE}"

    if [[ -f "${TEMPLATE}" ]]; then
        cp "${TEMPLATE}" config/deploy.yaml
        end_step "${ICON_OK}" "deploy.yaml 已复制"
    else
        end_step "${ICON_WARN}" "模板文件 ${TEMPLATE} 不存在，请手动重命名 deploy.yaml-linux.yaml" "${YELLOW}"
    fi
}

# ---------------------------- 第6步: 创建启动脚本 ----------------------------
create_launcher() {
    start_step "正在生成启动脚本..."

    cat > "${SCRIPT_OUT_DIR}/run_alas.sh" <<EOF
#!/bin/bash

osascript -e 'tell application "Terminal" to set miniaturized of front window to true'

eval "\$(${CONDA_BIN} shell.bash hook)"
conda activate alas
cd ${ALAS_DIR}
(sleep 2 && open http://127.0.0.1:22267) &
python gui.py
EOF
    chmod +x "${SCRIPT_OUT_DIR}/run_alas.sh"

    end_step "${ICON_OK}" "启动脚本已生成: ${SCRIPT_OUT_DIR}/run_alas.sh"
}

# ---------------------------- 第7步: 开机自启 (LaunchAgent) ----------------------------
configure_service() {
    if [[ "${SKIP_SERVICE}" == true ]]; then
        end_step "${ICON_INFO}" "已跳过开机自启服务配置"
        return
    fi

    start_step "正在配置开机自启..."

    local plist_dir="${HOME}/Library/LaunchAgents"
    mkdir -p "${plist_dir}"

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
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

    launchctl bootout "gui/$(id -u)/com.alas.run" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "${plist_dir}/com.alas.run.plist"

    if launchctl list 2>/dev/null | grep -q "com.alas.run"; then
        end_step "${ICON_OK}" "开机自启服务已配置"
    else
        end_step "${ICON_WARN}" "服务配置已完成，请重启后验证" "${YELLOW}"
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
    echo_line "  ${ICON_INFO}  ${GREEN}  依赖库 (brew, git, adb, conda) 不会被删除${NC}"
    echo_line ""
    echo -n "  确认？[yes/NO] "
    read -r CONFIRM
    if [[ "${CONFIRM}" != "yes" && "${CONFIRM}" != "YES" ]]; then
        echo_line "  ${ICON_INFO}  已取消卸载"
        exit 0
    fi

    echo_line ""

    start_step "正在停止 ALAS 服务..."
    launchctl bootout "gui/$(id -u)/com.alas.run" 2>/dev/null || true
    rm -f "${HOME}/Library/LaunchAgents/com.alas.run.plist"
    end_step "${ICON_OK}" "服务已停止并移除"

    start_step "正在清理 Conda 虚拟环境..."
    CONDA_BIN="${HOME}/miniforge3/bin/conda"
    command -v conda &>/dev/null && CONDA_BIN=$(command -v conda)
    eval "$("${CONDA_BIN}" shell.bash hook)" >> "$LOGFILE" 2>&1
    if conda env list 2>/dev/null | grep -q "^alas "; then
        conda env remove -n alas -y >> "$LOGFILE" 2>&1 || \
        rm -rf "$(conda info --base 2>/dev/null)/envs/alas" >> "$LOGFILE" 2>&1
    fi
    end_step "${ICON_OK}" "虚拟环境已清理"

    start_step "正在删除 ALAS 目录..."
    rm -rf "${INSTALL_DIR}"
    end_step "${ICON_OK}" "目录已删除"

    start_step "正在删除启动脚本..."
    rm -f "${SCRIPT_OUT_DIR}/run_alas.sh"
    end_step "${ICON_OK}" "启动脚本已删除"

    rm -f "$LOGFILE"
    echo_line ""
    echo_line "${ICON_OK}  ${GREEN}ALAS 卸载完成${NC}"
    echo_line ""
}

# ---------------------------- 主流程 ----------------------------
main() {
    if [[ "${UNINSTALL}" == true ]]; then
        do_uninstall
        exit 0
    fi

    gather_system_info
    print_header

    install_homebrew
    install_packages
    clone_alas
    setup_conda_env
    configure_deploy
    create_launcher
    configure_service

    print_completion
    rm -f "$LOGFILE"
}

main
