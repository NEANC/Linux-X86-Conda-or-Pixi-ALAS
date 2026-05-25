# Shell 脚本库

懒人方案，一键安装/卸载 AzurLaneAutoScript

---

## 脚本列表

| 脚本                            | 适用平台              | Python 管理器                  |
| ------------------------------- | --------------------- | ------------------------------ |
| `pixi_alas_install.sh`          | Linux x86-64          | Pixi                           |
| `conda_alas_install.sh`         | Linux x86-64          | Conda (Miniforge)              |
| `arm_mac_conda_alas_install.sh` | macOS (Apple Silicon) | Conda (Miniforge via Homebrew) |
| `arm_mac_pixi_alas_install.sh`  | macOS (Apple Silicon) | Pixi                           |
| `win_pixi_install.ps1`          | Windows               | Pixi                           |
| `win_conda_alas_install.ps1`    | Windows               | Conda (Miniforge)              |

---

## 参数

| 参数                   | 说明                                                 | 备注                                                   |
| ---------------------- | ---------------------------------------------------- | ------------------------------------------------------ |
| `-d, --dir DIR`        | 指定 ALAS 安装目录（默认：`~/AzurLaneAutoScript`）   |                                                        |
| `-s, --script-dir DIR` | 指定启动脚本输出目录（默认：`~/AzurLaneAutoScript`） |                                                        |
| `-t TEMPLATE`          | 控制使用的 deploy 模板与国内镜像源                   |                                                        |
| `-S, --skip-service`   | 跳过开机自启服务配置                                 | macOS 与 Windows 为 `-S, --setup-service` 配置开机自启 |
| `--uninstall`          | 反向操作：停止服务并清理所有 ALAS 相关文件           |                                                        |
| `-l, --log`            | 保留安装日志，不自动删除                             |                                                        |
| `-h, --help`           | 显示帮助信息                                         |                                                        |
| `--debug`              | 调试模式，日志将实时输出至终端                       |                                                        |

---

## Linux x86-64

> [!IMPORTANT]
> 脚本测试环境为 PVE 下的 LXC Debian 13 X86_64 与 Alpine Linux x86-64，GitHub Actions 的 Ubuntu-latest  
> 其他版本的 Linux 若遇到问题请提交 Issues

### Pixi 版部署脚本

```bash
# 标准安装
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/pixi_alas_install.sh | sudo sh

# 使用国内镜像
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/pixi_alas_install.sh | sudo sh -s -- -t CN

# 卸载
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/pixi_alas_install.sh | sudo sh -s -- --uninstall
```

### Conda 版部署脚本

```bash
# 标准安装
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/conda_alas_install.sh | sudo sh

# 使用国内镜像
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/conda_alas_install.sh | sudo sh -s -- -t CN

# 卸载
curl -fsSL https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/conda_alas_install.sh | sudo sh -s -- --uninstall
```

---

## ARM macOS

> [!IMPORTANT]
> 已通过 GitHub Actions 的 macOS-latest 环境测试  
> 其他版本的 macOS 若遇到问题请提交 Issues

### Conda 版部署脚本 via Homebrew

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

### Pixi 版部署脚本 via Homebrew

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

## Windows

> [!IMPORTANT]
> 请以 **管理员身份** 打开 PowerShell 运行以下命令
>
> > 已通过 GitHub Actions 的 Windows-latest 环境测试，若遇到问题请提交 Issues

### Pixi 版部署脚本 via PowerShell

```powershell
# 标准安装
irm https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/win_pixi_install.ps1 | iex

# 使用国内镜像
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/win_pixi_install.ps1'))) -t CN

# 卸载
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/win_pixi_install.ps1'))) --uninstall
```

### Conda 版部署脚本 via PowerShell

```powershell
# 标准安装
irm https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/win_conda_alas_install.ps1 | iex

# 使用国内镜像
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/win_conda_alas_install.ps1'))) -t CN

# 卸载
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/NEANC/Linux-X86-Conda-or-Pixi-ALAS/master/Shell/win_conda_alas_install.ps1'))) --uninstall
```

---

## License

MIT License
