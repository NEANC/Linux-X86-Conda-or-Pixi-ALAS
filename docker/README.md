# ALAS Pixi Docker 部署配置

## 用法

```bash
docker compose -f docker/docker-compose.yml up -d

docker run -d --name alas \
    -v /path/to/AzurLaneAutoScript:/alas \
    -p 22267:22267 \
    ghcr.io/neanc/alas-pixi-alpine:latest
```

## 本地构建

```bash
# 不使用代理
docker build -t alas-pixi-alpine -f docker/Dockerfile .

# 使用代理
docker build -t alas-pixi-alpine \
  --build-arg HTTP_PROXY=http://proxy:8080 \
  --build-arg HTTPS_PROXY=http://proxy:8080 \
  -f docker/Dockerfile .

docker run -d --name alas \
    -v /path/to/AzurLaneAutoScript:/alas \
    -p 22267:22267 \
    alas-pixi-alpine
```
