# ALAS Pixi Docker 镜像

在 Alpine Linux 容器中运行 AzurLaneAutoScript，ALAS 本体通过卷挂载传入，即可开箱即用。

## 快速开始

### 使用 docker run 运行

```bash
git clone https://github.com/LmeSzinc/AzurLaneAutoScript.git AzurLaneAutoScript

cd AzurLaneAutoScript

docker run -v ${PWD}:/app/AzurLaneAutoScript \
           -p 22267:22267 \
           --name AzurLaneAutoScript\
           -e TZ=Asia/Shanghai
           -it ghcr.io/neanc/alas-pixi-alpine:latest
```

### 使用 docker compose

```bash
mkdir alas && cd alas

wget "https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/docker/docker-compose.yml"

nano docker-compose.yml

docker compose up -d
```

## 本地构建

```bash
# 不使用代理
docker build -t alas-pixi-alpine -f docker/Dockerfile .

# 构建过程使用代理
docker build -t alas-pixi-alpine \
  --build-arg HTTP_PROXY=http://proxy:8080 \
  --build-arg HTTPS_PROXY=http://proxy:8080 \
  -f docker/Dockerfile .

# 启动容器
docker run -d --name alas \
    -v /path/to/AzurLaneAutoScript:/AzurLaneAutoScript \
    -p 22267:22267 \
    alas-pixi-alpine
```

## 环境变量

### 运行时的环境变量

| 变量                 | 默认值                              | 说明                                          |
| -------------------- | ----------------------------------- | --------------------------------------------- |
| `ALAS_DIR`           | `/AzurLaneAutoScript`               | ALAS 仓库挂载路径                             |
| `DEPLOY_TEMPLATE`    | `config/deploy.template-linux.yaml` | deploy 模板，国内镜像用 `...-cn.yaml`         |
| `HTTP_PROXY`         | (空)                                | 运行时 HTTP 代理                              |
| `HTTPS_PROXY`        | (空)                                | 运行时 HTTPS 代理，不设则沿用 HTTP_PROXY      |
| `NO_PROXY`           | (空)                                | 不走代理的地址列表，例：`localhost,127.0.0.1` |
| `ALAS_PIXI_PREBUILT` | `/opt/alas-pixi-env`                | 预构建环境路径                                |

### 构建参数 (--build-arg)

| 参数                   | 默认值    | 说明                                            |
| ---------------------- | --------- | ----------------------------------------------- |
| `HTTP_PROXY`           | (空)      | 构建阶段 HTTP 代理                              |
| `HTTPS_PROXY`          | (空)      | 构建阶段 HTTPS 代理                             |
| `NO_PROXY`             | (空)      | 构建阶段不走代理列表，例：`localhost,127.0.0.1` |
| `ALPINE_GLIBC_VERSION` | `2.35-r1` | sgerrand glibc 版本                             |
| `ALPINE_VERSION`       | `3.21`    | Alpine 基础镜像版本                             |
