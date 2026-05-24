#!/bin/sh
set -eu

ALAS_DIR="${ALAS_DIR:-/alas}"
DEPLOY_TEMPLATE="${DEPLOY_TEMPLATE:-config/deploy.template-linux.yaml}"

log()     { printf '%b\n' "  [INFO]  $1"; }
log_ok()  { printf '%b\n' "  [OK]    $1"; }
log_warn(){ printf '%b\n' "  [WARN]  $1"; }
log_err() { printf '%b\n' "  [ERROR] $1"; }

generate_pixi_toml() {
    _gp_template="${ALAS_PIXI_PREBUILT:-/opt/alas-pixi-env}/pixi.toml"
    if [ ! -f "${_gp_template}" ]; then
        log_err "pixi.toml 模板不存在: ${_gp_template}"
        exit 1
    fi
    log "正在生成 pixi.toml ..."
    cat > "${ALAS_DIR}/pixi.toml" << 'PIXI_EOF'
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
    log_ok "pixi.toml 已生成"
}

configure_deploy() {
    if [ -f "${ALAS_DIR}/config/deploy.yaml" ]; then
        log "config/deploy.yaml 已存在，跳过配置"
        return 0
    fi
    if [ -f "${ALAS_DIR}/${DEPLOY_TEMPLATE}" ]; then
        log "从模板复制 deploy.yaml: ${DEPLOY_TEMPLATE}"
        cp "${ALAS_DIR}/${DEPLOY_TEMPLATE}" "${ALAS_DIR}/config/deploy.yaml"
        log_ok "deploy.yaml 已配置"
    else
        log_warn "模板 ${DEPLOY_TEMPLATE} 不存在，请手动配置 config/deploy.yaml"
    fi
}

use_prebuilt_pixi_env() {
    _up_prebuilt="${ALAS_PIXI_PREBUILT:-/opt/alas-pixi-env}"
    if [ ! -d "${_up_prebuilt}/.pixi" ] || [ ! -f "${_up_prebuilt}/pixi.lock" ]; then
        return 1
    fi

    log "发现预构建的 Pixi 环境，正在部署..."
    if [ -d .pixi ] || [ -f pixi.lock ]; then
        log "检测到不完整的 Pixi 环境，正在清理..."
        rm -rf .pixi pixi.lock
    fi

    cp -a "${_up_prebuilt}/.pixi" .pixi
    cp "${_up_prebuilt}/pixi.lock" pixi.lock

    if [ -x .pixi/envs/default/bin/python ] && .pixi/envs/default/bin/python -V >/dev/null 2>&1; then
        log_ok "预构建环境部署成功（秒级就绪）"
        return 0
    fi

    log_warn "预构建环境不可用，回退到在线安装"
    rm -rf .pixi pixi.lock
    return 1
}

setup_pixi_env() {
    cd "${ALAS_DIR}"

    if [ ! -f "pixi.toml" ]; then
        generate_pixi_toml
    else
        log "pixi.toml 已存在，跳过生成"
    fi

    if [ -f "pixi.lock" ] && [ -d ".pixi" ]; then
        log "Pixi 虚拟环境已就绪，跳过安装"
        log "如需重建环境，请删除 .pixi 目录和 pixi.lock 后重启容器"
        return 0
    fi

    if use_prebuilt_pixi_env; then
        return 0
    fi

    log "正在在线安装 Pixi 虚拟环境（可能需要 5-15 分钟）..."
    if [ -d ".pixi" ] || [ -f "pixi.lock" ]; then
        log "检测到不完整的 Pixi 环境，正在清理..."
        rm -rf .pixi pixi.lock
    fi

    if pixi install --manifest-path pixi.toml; then
        log_ok "Pixi 虚拟环境安装完成"
    else
        log_err "Pixi 环境安装失败，请检查日志"
        log_err "常见解决方案:"
        log_err "  1. 确保网络可正常访问 conda-forge 和 pypi.org"
        log_err "  2. 删除 .pixi 目录和 pixi.lock 后重试"
        log_err "  3. 使用 -e DEPLOY_TEMPLATE=config/deploy.template-linux-cn.yaml 启用国内镜像"
        exit 1
    fi
}

setup_proxy() {
    if [ -z "${HTTP_PROXY:-}" ] && [ -z "${http_proxy:-}" ]; then
        return 0
    fi
    _sp_http="${HTTP_PROXY:-${http_proxy}}"
    _sp_https="${HTTPS_PROXY:-${https_proxy:-${_sp_http}}}"
    export http_proxy="${_sp_http}"
    export https_proxy="${_sp_https}"
    export HTTP_PROXY="${_sp_http}"
    export HTTPS_PROXY="${_sp_https}"
    if [ -n "${NO_PROXY:-}" ]; then
        export no_proxy="${NO_PROXY}"
    elif [ -n "${no_proxy:-}" ]; then
        export NO_PROXY="${no_proxy}"
    fi
    log "代理已启用: http_proxy=${_sp_http}"
}

main() {
    setup_proxy

    if [ ! -d "${ALAS_DIR}" ]; then
        log_err "ALAS 目录不存在: ${ALAS_DIR}"
        log_err "请将 AzurLaneAutoScript 目录挂载到 ${ALAS_DIR}"
        log_err "示例: docker run -v /path/to/AzurLaneAutoScript:${ALAS_DIR} ..."
        exit 1
    fi

    if [ ! -d "${ALAS_DIR}/.git" ] && [ ! -f "${ALAS_DIR}/gui.py" ]; then
        log_warn "${ALAS_DIR} 不像是 AzurLaneAutoScript 仓库目录"
        log_warn "请确认挂载路径正确"
    fi

    configure_deploy
    setup_pixi_env

    log "启动 ALAS: pixi run ${*:-start}"
    exec pixi run "$@"
}

main "$@"
