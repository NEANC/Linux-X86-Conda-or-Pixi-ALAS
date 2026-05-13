# Shell 脚本库

懒人方案，一键安装/卸载 AzurLaneAutoScript

---

## 脚本列表

| 脚本                            | 适用平台              | 管理器                         |
| ------------------------------- | --------------------- | ------------------------------ |
| `pixi_alas_install.sh`          | Linux x86-64          | Pixi                           |
| `conda_alas_install.sh`         | Linux x86-64          | Conda (Miniforge)              |
| `arm_mac_conda_alas_install.sh` | macOS (Apple Silicon) | Conda (Miniforge via Homebrew) |
| `arm_mac_pixi_alas_install.sh`  | macOS (Apple Silicon) | Pixi                           |

---

## 参数

| 参数                   | 说明                                                 | 备注                                        |
| ---------------------- | ---------------------------------------------------- | ------------------------------------------- |
| `-d, --dir DIR`        | 指定 ALAS 安装目录（默认：`~/AzurLaneAutoScript`）   |                                             |
| `-s, --script-dir DIR` | 指定启动脚本输出目录（默认：`~/AzurLaneAutoScript`） |                                             |
| `-t TEMPLATE`          | 控制使用的 deploy 模板与国内镜像源                   |                                             |
| `-S, --skip-service`   | 跳过开机自启服务配置                                 | macOS 为 `-S, --setup-service` 配置开机自启 |
| `--uninstall`          | 反向操作：停止服务并清理所有 ALAS 相关文件           |                                             |
| `-l, --log`            | 保留安装日志，不自动删除                             |                                             |
| `-h, --help`           | 显示帮助信息                                         |                                             |

---

## Linux

### Pixi 版部署脚本

```bash
# 标准安装
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/pixi_alas_install.sh | sudo bash

# 使用国内镜像
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/pixi_alas_install.sh | sudo bash -s -- -t CN

# 卸载
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/pixi_alas_install.sh | sudo bash -s -- --uninstall
```

### Conda 版部署脚本

```bash
# 标准安装
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/conda_alas_install.sh | sudo bash

# 使用国内镜像
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/conda_alas_install.sh | sudo bash -s -- -t CN

# 卸载
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/conda_alas_install.sh | sudo bash -s -- --uninstall
```

---

## ARM macOS

### Conda 版部署脚本

```bash
# 标准安装
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/arm_mac_conda_alas_install.sh | bash

# 配置开机自启
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/arm_mac_conda_alas_install.sh | bash -s -- -S

# 使用国内镜像
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/arm_mac_conda_alas_install.sh | bash -s -- -t CN

# 使用国内镜像并配置开机自启
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/arm_mac_conda_alas_install.sh | bash -s -- -t CN -S

# 卸载
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/arm_mac_conda_alas_install.sh | bash -s -- --uninstall
```

### Pixi 版部署脚本

```bash
# 标准安装
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/arm_mac_pixi_alas_install.sh | bash

# 配置开机自启
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/arm_mac_pixi_alas_install.sh | bash -s -- -S

# 使用国内镜像
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/arm_mac_pixi_alas_install.sh | bash -s -- -t CN

# 使用国内镜像并配置开机自启
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/arm_mac_pixi_alas_install.sh | bash -s -- -t CN -S

# 卸载
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/arm_mac_pixi_alas_install.sh | bash -s -- --uninstall
```

---

## License

MIT License
