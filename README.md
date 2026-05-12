# Linux-X86-Conda-or-Pixi-ALAS

> [!IMPORTANT]
> 本文测试环境为 PVE 下的 LXC Debian 13 X86_64，其他版本的 Linux 可能会有些许差异，但整体步骤基本相同；  
> 由于 Linux 发行版众多，无法保证每个发行版都能完全适用，若遇到问题请提交 Issues

在 X86_64 Linux 中使用 Conda 或 Pixi 安装与配置 [AzurLaneAutoScript](https://github.com/LmeSzinc/AzurLaneAutoScript) 的指南

---

> [!NOTE]
> 推荐使用 Pixi 版本，因更简单也更快更轻  
> 若需要更好的兼容性，也提供 Conda 版本教程

## 目录

1. [Pixi 版本](./Pixi/README.md)
2. [Conda 版本](./Conda/README.md)
3. [Shell 脚本](./Shell/README.md)

---

> [!TIP]
> 现提供一键安装 Shell 脚本  
> 脚本已通过 PVE 下的 LXC Debian 13 X86_64 中测试，若有错误请提交 Issues

## Shell 脚本

请前往 [Shell 脚本库](./Shell/README.md)

---

## 特别鸣谢

[guoh064](https://github.com/guoh064) 没有你，就没有这个教程

- 提供了最初的 `pixi.toml` 文件

---

## License

MIT License 与 [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License][cc-by-nc-sa] 共同使用，其中代码部分为 MIT License，文档部分为 [CC BY-NC-SA 4.0][cc-by-nc-sa]

[![CC BY-NC-SA 4.0][cc-by-nc-sa-image]][cc-by-nc-sa]

[cc-by-nc-sa]: http://creativecommons.org/licenses/by-nc-sa/4.0/
[cc-by-nc-sa-image]: https://licensebuttons.net/l/by-nc-sa/4.0/88x31.png
