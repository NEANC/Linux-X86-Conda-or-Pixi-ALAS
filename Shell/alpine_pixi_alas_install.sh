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
RAM_SIZE_MIB=""
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
用法: sh $0 [选项]

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

enable_alpine_community_repo() {
    if grep -Eq '^[[:space:]]*[^#].*/community([[:space:]]*)?$' /etc/apk/repositories 2>/dev/null; then
        _log_message "OK" "Alpine community 仓库已启用"
        return 0
    fi
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
    if [ -e "${ALPINE_GLIBC_LOADER}" ]; then
        _log_message "OK" "glibc loader 已存在: ${ALPINE_GLIBC_LOADER}"
        return 0
    fi
    for _eg_candidate in /lib/ld-linux-x86-64.so.2 /usr/glibc-compat/lib/ld-linux-x86-64.so.2; do
        if [ -e "${_eg_candidate}" ]; then
            mkdir -p /lib64
            ln -sf "${_eg_candidate}" "${ALPINE_GLIBC_LOADER}"
            _log_message "OK" "已创建 glibc loader 兼容链接: ${ALPINE_GLIBC_LOADER} -> ${_eg_candidate}"
            return 0
        fi
    done

    _log_message "ERROR" "未找到 glibc loader，Pixi 的 linux-64 Python 可能无法启动"
    return 1
}

install_alpine_real_glibc() {
    _log_message "INFO" "正在安装 Alpine 第三方 glibc 兼容包..."
    _log_message "WARNING" "将安装 sgerrand/alpine-pkg-glibc (${ALPINE_GLIBC_VERSION})，用于运行 conda linux-64 Python"

    if apk info -e glibc >/dev/null 2>&1 && [ -e /usr/glibc-compat/lib/ld-linux-x86-64.so.2 ]; then
        mkdir -p /lib64
        ln -sf /usr/glibc-compat/lib/ld-linux-x86-64.so.2 "${ALPINE_GLIBC_LOADER}"
        _log_message "OK" "第三方 glibc 已存在"
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
    if ! curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
            -o "${key_file}" "${key_url}" >> "$LOGFILE" 2>&1; then
        _log_message "WARNING" "sgerrand 官方源不可用，尝试 GitHub raw fallback"
        if ! curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
                -o "${key_file}" "${key_fallback}" >> "$LOGFILE" 2>&1; then
            rm -rf "${tmp_dir}"
            end_step "${ICON_ERROR}" "第三方 glibc key 下载失败" "${RED}"
            exit 1
        fi
    fi

    _log_message "EXEC" "▶ 下载 glibc APK: ${ALPINE_GLIBC_VERSION}"
    if ! curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
            -o "${glibc_apk}" "${GH_PROXY}${release_url}/glibc-${ALPINE_GLIBC_VERSION}.apk" >> "$LOGFILE" 2>&1 || \
       ! curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
            -o "${glibc_bin_apk}" "${GH_PROXY}${release_url}/glibc-bin-${ALPINE_GLIBC_VERSION}.apk" >> "$LOGFILE" 2>&1; then
        rm -rf "${tmp_dir}"
        end_step "${ICON_ERROR}" "第三方 glibc APK 下载失败: ${release_url}" "${RED}"
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
        _log_message "OK" "第三方 glibc 安装完成"
    else
        end_step "${ICON_ERROR}" "第三方 glibc 安装后仍缺少 loader" "${RED}"
        exit 1
    fi
}

pixi_install_needs_real_glibc() {
    _pn_install_log="$1"
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
    _vp_env_python=".pixi/envs/default/bin/python"
    _vp_python_log="/tmp/pixi_python_check_$$.log"

    if [ ! -x "${_vp_env_python}" ]; then
        _log_message "ERROR" "Pixi Python 不存在或不可执行: ${_vp_env_python}"
        end_step "${ICON_ERROR}" "Pixi 环境缺少 Python，Alpine glibc 兼容层可能不足" "${RED}"
        return 1
    fi

    if ! "${_vp_env_python}" -V > "${_vp_python_log}" 2>&1; then
        cat "${_vp_python_log}" >> "$LOGFILE" 2>/dev/null || true
        rm -f "${_vp_python_log}"
        _log_message "ERROR" "Pixi Python 前缀健康检查失败: ${_vp_env_python}"
        end_step "${ICON_ERROR}" "Alpine glibc 兼容层不足，Pixi 的 linux-64 Python 无法运行" "${RED}"
        return 1
    fi

    _log_message "OK" "✓ Pixi Python 可运行: $(tr -d '\r\n' < "${_vp_python_log}")"
    rm -f "${_vp_python_log}"
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
        --uninstall) UNINSTALL=true; shift ;;
        -l|--log) KEEP_LOG=true; shift ;;
        -S|--skip-service) SKIP_SERVICE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "未知参数: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------- 权限检查 ----------------------------
if [ "$(id -u)" -ne 0  ]; then
    printf '%b\n' "${RED}请使用 root 权限运行此脚本 (sudo sh $0)${NC}"
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

    # Alpine 系统检查
    if [ "${OS_ID}" != "alpine" ]; then
        echo_line "  ${ICON_ERROR}  ${RED}此脚本仅支持 Alpine Linux，当前系统: ${OS_ID}，请阅读发行说明${NC}"
        exit 1
    fi
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

# ---------------------------- 安装/激活 Pixi ----------------------------
install_pixi() {
    start_step "正在检查 Pixi..."

    if command -v pixi >/dev/null 2>&1; then
        PIXI_VER=$(pixi --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Pixi 已安装: ${PIXI_VER}"
        return
    fi

    if [ -x "${HOME}/.pixi/bin/pixi" ]; then
        export PATH="${HOME}/.pixi/bin:${PATH}"
        PIXI_VER=$(pixi --version 2>/dev/null | awk '{print $NF}' || echo '版本获取失败')
        end_step "${ICON_OK}" "Pixi 已激活: ${PIXI_VER}"
        return
    fi

    _log_message "ERROR" "未检测到 Pixi"
    start_step "正在安装 Pixi..."
    if [ "${USE_CN_MIRROR}" = true ]; then
        _ip_pixi_dl="${GH_PROXY}https://github.com/prefix-dev/pixi/releases/latest/download/pixi-x86_64-unknown-linux-musl.tar.gz"
        _log_message "EXEC" "▶ 安装 Pixi (国内源): PIXI_DOWNLOAD_URL=${_ip_pixi_dl}"
        if ! PIXI_DOWNLOAD_URL="${_ip_pixi_dl}" curl -fsSL https://pixi.sh/install.sh | sh >> "$LOGFILE" 2>&1; then
            end_step "${ICON_ERROR}" "Pixi 安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
            exit 1
        fi
    else
        _log_message "EXEC" "▶ 安装 Pixi: curl -fsSL https://pixi.sh/install.sh | sh"
        if ! curl -fsSL https://pixi.sh/install.sh | sh >> "$LOGFILE" 2>&1; then
            end_step "${ICON_ERROR}" "Pixi 安装错误，详情请阅读日志：${LOGFILE}" "${RED}"
            exit 1
        fi
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

# ---------------------------- 检查依赖----------------------------
install_deps() {
    start_step "正在检查依赖..."

    _ga_missing=""
    for _ga_pkg in git android-tools curl ca-certificates tar xz libstdc++ libgcc; do
        if apk info -e "${_ga_pkg}" >/dev/null 2>&1; then
            _log_message "OK" "依赖已存在: ${_ga_pkg}"
        else
            _log_message "WARNING" "依赖缺失: ${_ga_pkg}"
            _ga_missing="${_ga_missing} ${_ga_pkg}"
        fi
    done

    if [ -n "${_ga_missing}" ]; then
        start_step "正在安装缺失的依赖:${_ga_missing}..."
        enable_alpine_community_repo
        _log_message "EXEC" "▶ apk update"
        if ! apk update >> "$LOGFILE" 2>&1; then
            log_error "依赖更新错误，详情请阅读日志：${LOGFILE}"
            exit 1
        fi
        _log_message "EXEC" "▶ apk add --no-cache${_ga_missing}"
        # shellcheck disable=SC2086
        if [ "${USE_CN_MIRROR}" = true ]; then
            if ! _apk_add_cn_mirror ${_ga_missing}; then
                log_error "依赖安装错误，详情请阅读日志：${LOGFILE}"
                exit 1
            fi
        elif ! apk add --no-cache ${_ga_missing} >> "$LOGFILE" 2>&1; then
            log_error "依赖安装错误，详情请阅读日志：${LOGFILE}"
            exit 1
        fi
        if command -v update-ca-certificates >/dev/null 2>&1; then
            _log_exec "更新 CA 证书" update-ca-certificates || true
        fi
    fi

    # Alpine glibc 兼容层（gcompat → 自动降级第三方 glibc）
    _ga_gcompat_missing=""
    if apk info -e gcompat >/dev/null 2>&1; then
        _log_message "OK" "glibc 兼容层已存在: gcompat"
    else
        _ga_gcompat_missing="gcompat"
    fi

    if [ -n "${_ga_gcompat_missing}" ]; then
        _log_message "WARNING" "glibc 兼容层缺失: gcompat"
        enable_alpine_community_repo
        _log_message "EXEC" "▶ apk add --no-cache gcompat"
        if [ "${USE_CN_MIRROR}" = true ]; then
            _apk_add_cn_mirror gcompat
            _ga_gcompat_ok=$?
        else
            apk add --no-cache gcompat >> "$LOGFILE" 2>&1
            _ga_gcompat_ok=$?
        fi
        if [ "${_ga_gcompat_ok}" = 0 ]; then
            _log_message "OK" "✓ gcompat 安装成功"
        else
            _log_message "WARNING" "gcompat 在当前仓库不可用，自动降级到第三方 glibc"
            install_alpine_real_glibc
        fi
    fi

    # 确保 glibc loader 存在（gcompat 或第三方 glibc 都应提供）
    if ! ensure_alpine_glibc_loader; then
        _log_message "WARNING" "gcompat 未提供 glibc loader，自动降级到第三方 glibc"
        install_alpine_real_glibc
    fi

    _log_message "OK" "Git 已安装: $(git --version 2>/dev/null | awk '{print $NF}')"
    _log_message "OK" "ADB 已安装: $(adb --version 2>/dev/null | head -n1 | awk '{print $NF}')"
    _log_message "OK" "curl 已安装: $(curl --version 2>/dev/null | head -1 | awk '{print $2}')"
    _log_message "OK" "tar 已安装: $(tar --version 2>/dev/null | head -1 | awk '{print $NF}')"
    _log_message "OK" "xz 已安装: $(xz --version 2>/dev/null | head -1 | awk '{print $NF}')"
    _log_message "OK" "ca-certificates 已安装: $(apk info -v ca-certificates 2>/dev/null | sed 's/^ca-certificates-//' || echo '✓')"
    _log_message "OK" "libstdc++ 已安装: $(apk info -v libstdc++ 2>/dev/null | sed 's/^libstdc++-//' || echo '✓')"
    _log_message "OK" "libgcc 已安装: $(apk info -v libgcc 2>/dev/null | sed 's/^libgcc-//' || echo '✓')"
    end_step "${ICON_OK}" "依赖检查完成"
}

# CN 镜像 APK 安装：尝试中国镜像源；失败时回退官方源
_apk_add_cn_mirror() {
    _ac_pkgs="$*"
    _ac_alpine_ver=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo "latest-stable")
    _log_message "EXEC" "▶ apk add${_ac_pkgs} (CN 镜像)"
    for _ac_mirror in \
        "https://mirrors.ustc.edu.cn/alpine/v${_ac_alpine_ver}/main" \
        "https://mirrors.ustc.edu.cn/alpine/v${_ac_alpine_ver}/community" \
        "https://mirrors.aliyun.com/alpine/v${_ac_alpine_ver}/main" \
        "https://mirrors.aliyun.com/alpine/v${_ac_alpine_ver}/community" \
        "https://repo.huaweicloud.com/alpine/v${_ac_alpine_ver}/main" \
        "https://repo.huaweicloud.com/alpine/v${_ac_alpine_ver}/community"; do
        if apk add --no-cache --repository="${_ac_mirror}" ${_ac_pkgs} >> "$LOGFILE" 2>&1; then
            return 0
        fi
        _log_message "WARNING" "镜像 ${_ac_mirror} 不可用，尝试下一个"
    done
    # 所有镜像失败，回退官方源
    _log_message "WARNING" "所有 CN 镜像不可用，回退官方源"
    apk add --no-cache ${_ac_pkgs} >> "$LOGFILE" 2>&1
}

# ---------------------------- 克隆仓库 ----------------------------
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
    if [ -f "pixi.toml" ] && [ ! -f "pixi.toml.bak" ]; then
        cp pixi.toml pixi.toml.bak
        _log_message "OK" "✓ 已备份 pixi.toml → pixi.toml.bak"
    fi

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

        _log_message "EXEC" "▶ 配置国内镜像源"
    cernet_channel="${cernet_conda}/cloud/conda-forge/"
        sed -i "s|channels = \\[\"conda-forge\"\\]|channels = [\"${cernet_channel}\"]|" pixi.toml
        cat >> pixi.toml << PIXI_EOF
[pypi-options]
index-url = "${cernet_pypi}"
PIXI_EOF
        _log_message "OK" "✓ 国内镜像源已配置至 pixi.toml"
    fi

    if [ -d ".pixi/envs/default" ] || [ -d ".pixi/envs/alas" ] || [ -f "pixi.lock" ]; then
        _log_message "WARNING" "检测到已有 Pixi 环境，正在清理..."
        _log_exec "清理 Pixi 缓存" pixi clean cache -y || true
        _log_exec "清理 Pixi 环境 (方法1: pixi clean --environment default)" pixi clean --environment default || \
        _log_exec "清理 Pixi 环境 (方法2: pixi clean)" pixi clean || \
        _log_exec "清理 Pixi 环境 (方法3: rm -rf .pixi pixi.lock)" rm -rf .pixi pixi.lock
        _log_message "OK" "✓ 旧环境已清理"
    fi

    export CONDA_OVERRIDE_GLIBC="${CONDA_OVERRIDE_GLIBC:-${ALPINE_GLIBC_OVERRIDE}}"
    _log_message "INFO" "Alpine 已设置 CONDA_OVERRIDE_GLIBC=${CONDA_OVERRIDE_GLIBC}"
    ensure_alpine_glibc_loader || {
        end_step "${ICON_ERROR}" "Alpine glibc 兼容层不足，请检查 gcompat" "${RED}"
        exit 1
    }

    _pe_install_log="/tmp/pixi_install_$$.log"
    _pe_install_attempt=1
    while true; do
        _log_message "EXEC" "▶ pixi install --manifest-path pixi.toml (第 ${_pe_install_attempt} 次)"
        if pixi install --manifest-path pixi.toml > "${_pe_install_log}" 2>&1; then
            cat "${_pe_install_log}" >> "$LOGFILE" 2>/dev/null || true
            rm -f "${_pe_install_log}"
            break
        fi

        cat "${_pe_install_log}" >> "$LOGFILE" 2>/dev/null || true
        if [ "${ALPINE_GLIBC_RETRY_DONE}" != true ] && \
           pixi_install_needs_real_glibc "${_pe_install_log}"; then
            _log_message "WARNING" "gcompat 无法启动 conda linux-64 Python，自动切换到第三方 glibc 并重试"
            end_step "${ICON_WARN}" "gcompat 不足，正在安装第三方 glibc 后自动重试" "${YELLOW}"
            rm -f "${_pe_install_log}"
            ALPINE_GLIBC_RETRY_DONE=true
            install_alpine_real_glibc
            _log_exec "清理失败的 Pixi 环境" pixi clean --environment default || \
            _log_exec "清理失败的 Pixi 环境 (rm -rf)" rm -rf .pixi pixi.lock
            _pe_install_attempt=$((_pe_install_attempt + 1))
            start_step "正在重新配置 Pixi 虚拟环境..."
            continue
        fi

        diagnose_pixi_install_failure "${_pe_install_log}"
        rm -f "${_pe_install_log}"
        exit 1
    done

    if ! verify_pixi_python_prefix; then
        exit 1
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

# ---------------------------- 第6步: 开机自启服务（OpenRC）----------------------------
_configure_openrc() {
    start_step "正在配置 OpenRC 开机自启..."
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
        echo_line "  ${ICON_WARN}  ${YELLOW}未检测到 OpenRC，跳过服务配置，请手动配置开机自启${NC}"
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
    echo_line "${ICON_ROCKET}  ${GREEN}ALAS 已经完成安装，请通过 ${CYAN}http://${NET_IP}:22267${NC} ${GREEN}访问 WEBUI${NC}"
    echo_line "  ─────────────────────────────────────────────────"
    echo_line "  ${ICON_INFO}  安装目录    : ${BLUE}${ALAS_DIR}${NC}"


    if [ "${SKIP_SERVICE}" = true ]; then
        echo_line "  ${ICON_INFO}  手动启动    : ${CYAN}sh ${ALAS_DIR}/run_alas.sh${NC}"
    else
        echo_line ""
        echo_line "  ${ICON_INFO}  init 服务管理："
        echo_line "      启动服务:  ${CYAN}rc-service run_alas start${NC}"
        echo_line "      停止服务:  ${CYAN}rc-service run_alas stop${NC}"
        echo_line "      重启服务:  ${CYAN}rc-service run_alas restart${NC}"
        echo_line "      检查状态:  ${CYAN}rc-service run_alas status${NC}"
    fi
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
    if [ -d ".pixi" ] || [ -f "pixi.lock" ]; then
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
    install_deps
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
