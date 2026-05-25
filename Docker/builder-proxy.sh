#!/bin/sh
# builder 阶段代理注入脚本，由 Dockerfile COPY 到 /tmp/builder-proxy.sh
# 在每个构造步骤开头 source，不传代理时零开销跳过
if [ -n "${HTTP_PROXY:-}" ]; then
    export http_proxy="${HTTP_PROXY}"
    export https_proxy="${HTTPS_PROXY:-${HTTP_PROXY}}"
    if [ -n "${NO_PROXY:-}" ]; then
        export no_proxy="${NO_PROXY}"
    fi
fi
