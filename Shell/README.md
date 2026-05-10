# Shell 脚本库

懒人方案，一键安装/卸载 AzurLaneAutoScript

---

## 脚本列表

| 脚本                            | 适用平台              | 包管理器                       |
| ------------------------------- | --------------------- | ------------------------------ |
| `pixi_alas_install.sh`          | Linux x86-64          | Pixi                           |
| `conda_alas_install.sh`         | Linux x86-64          | Conda (Miniforge)              |
| `arm_mac_conda_alas_install.sh` | macOS (Apple Silicon) | Conda (Miniforge via Homebrew) |

---

## 参数

所有脚本均支持以下选项：

| 参数                   | 说明                                                 |
| ---------------------- | ---------------------------------------------------- |
| `-d, --dir DIR`        | 指定 ALAS 安装目录（默认：`~/AzurLaneAutoScript`）   |
| `-s, --script-dir DIR` | 指定启动脚本输出目录（默认：`~/AzurLaneAutoScript`） |
| `-t TEMPLATE`          | 控制使用的 deploy 模板与国内镜像源                   |
| `-S, --skip-service`   | 跳过开机自启服务配置                                 |
| `--uninstall`          | 反向操作：停止服务并清理所有 ALAS 相关文件           |
| `-h, --help`           | 显示帮助信息                                         |

---

## Linux

### Pixi 版部署脚本

```bash
# 标准安装
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/pixi_alas_install.sh | sudo bash

# 使用国内镜像
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/pixi_alas_install.sh | sudo bash -t CN

# 卸载
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/pixi_alas_install.sh | sudo bash --uninstall
```

### Conda 版部署脚本

```bash
# 标准安装
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/conda_alas_install.sh | sudo bash

# 使用国内镜像
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/conda_alas_install.sh | sudo bash -t CN

# 卸载
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/conda_alas_install.sh | sudo bash --uninstall
```

---

## ARM macOS 部署脚本

```bash
# 标准安装
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/arm_mac_conda_alas_install.sh | bash

# 使用国内镜像

# 卸载
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/arm_mac_conda_alas_install.sh | bash --uninstall
```

---

## License

MIT License
