# Git 钩子

[English](<README.md>) | [简体中文](<README.zh-CN.md>)

## 提交前钩子

[提交前钩子](<pre-commit>) 会在提交之前从仓库根目录运行 `moon check`。启用前，请安装 MoonBit 工具链，并确保 `PATH` 中可以找到 `moon`。检查失败会阻止提交。此钩子使用工作树和模块的默认目标，不会将检查限制在已暂存文件，也不会运行格式化、测试或 moonlint。

### 使用说明

使用此提交前钩子的步骤：

1. 如果钩子尚不可执行，为其添加可执行权限：
   ```bash
   chmod +x .githooks/pre-commit
   ```

2. 配置 Git 使用 .githooks 目录中的钩子：
   ```bash
   git config core.hooksPath .githooks
   ```

3. 执行 `git commit` 时，钩子会自动运行。
