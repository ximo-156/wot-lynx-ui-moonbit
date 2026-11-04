# 本地验收记录与申报复核

## 验收对象

- 工作区模块：`ximo-156/moonlint`，本地版本 **0.3.0**。
- 工具链：moon 0.1.20261102（ea07287）、moonc v0.10.19+bee578715；`rr_moon_mod`、`rr_moon_pkg`。
- 环境：macOS native 后端，使用本机 C 工具链；未宣称 Windows / wasm 测试通过。
- 本轮没有执行项目仓库的 commit、push 或报名提交命令。检测到仓库 HEAD / 本地 origin/main 追踪引用在工作期间更新为 `4bebde5`（17:07 的功能提交）；后续修正仍在工作区。测试对象不是该中间提交，也不代表远端 CI 已通过。

## 最终运行结果

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| `moon check --target native` | 退出 0，230 warnings、0 errors | [check log](<../.workbuddy-ai/final-check.log>) |
| `moon test --target native` | **383/383 passed** | [unit log](<../.workbuddy-ai/final-unit.log>) |
| `moon build --target native` | 退出 0，161 warnings、0 errors | [build log](<../.workbuddy-ai/final-build.log>) |
| 全部 CLI 阶段 | **194 项：192 passed、2 expectedFailure**，退出 0 | [CLI log](<../.workbuddy-ai/final-cli.log>) |
| 仓库自身规范 | 配置范围内 0 findings、0 source/context failures，未加载基线 | [self report](<../.workbuddy-ai/self-current.json>) |
| `moon info && moon fmt` | 两个命令退出 0；后续完整 native/CLI 门禁重新运行 | [info log](<../.workbuddy-ai/info-current.log>)、[fmt log](<../.workbuddy-ai/fmt-current.log>) |
| 实际示例模块 | MoonBit convention、package policy、API before/after 四模块 check/test/build 退出 0 | [example log](<../.workbuddy-ai/example-gates.log>) |
| 完整当前库接口 | 整份生成接口成功快照；同快照比较 0 变化、退出 0 | [API check](<../.workbuddy-ai/current-full-api-check.json>) |

日志属于本地忽略的验收数据，不随公共仓库自动发布。以上通过不意味着 warning-free，也不把两项 expectedFailure 计为已修复。

## 正反业务回归

- MoonBit lexer/文档/调用：区分真实注释、分隔符、quoted/raw/`$|` 字面量和插值代码；空文档与公开 suberror 可检测，定义和测试体不当作普通调用。同行属性、属性闭合同行声明及 BOM 有独立回归。
- 修复：真实编译模块的 CRLF、Unicode、quoted/raw/interpolated literal bytes 和运行结果在修复前后相同；只修可安全改变的代码空白，literal 里的 tabs/尾空格与 final raw EOF 保留并继续报告。非 MoonBit 修复保守拒绝未知文字值区域。
- Git：新增 8 个 CLI 用例全部通过。未选择的 TS/JSON 文件仍参与解析；dirty worktree 不污染 HEAD/index 上下文；完整环图只报告选中文件；坏 UTF-8 context 必须退出 2。
- Git 不可变：在完整 `ls-tree` / `ls-files --stage` 列表完成后切 HEAD 或改 index，仍读取捕获的旧 blob OID。另有真实 `git replace` 回归；固定 argv 禁用 replace refs，不能把替换对象冒充原 blob。
- 包政策：35 个专项 native 用例通过；真实无环 root→domain→ui 示例先编译成功，再因 domain→ui 团队规则退出 1。标准库与传递依赖未伪称覆盖，target/kind 不适用明确显示。
- API：18 个专项 native 用例通过；历史 Incremental 接口在版本不变时被识别删除。真实 before 0.2.0 / after 0.3.0 默认删除门禁退出 1；显式 semver 策略退出 0，但删除 warning 保留。
- 基线 v2：30 个专项 native 用例通过；行移动稳定、复制受次数限制、改名/内容变化不误豁免、到期日含当日、过期不可抑制、未用及部分未用预算进入审计。迁移只转换当前仍匹配的旧豁免，新增 error 仍退出 1。
- CLI 新政策阶段共 16 个真实用例全部通过，另 8 个 Git context 用例全部通过。两项旧 JS 字面量文本匹配 expectedFailure 不属于新增 MoonBit 前端能力。

## 公共接口审查

[生成接口](<../pkg.generated.mbti>) 已对修复前 `20b2025` 审查完整差异：

- 新增 baseline v2、package/API gate 与 project report API。
- `LintResult` 增加 context counters 和 source snapshot；`CommentMode` / `StructuralCheck` 增加 MoonBit 变体。这对直接结构体构造、穷举匹配调用方是**源兼容性变更**，因此模块版本改为 0.3.0，而非声称纯内部重构。
- `derive(...)` → `#derive(...)` 等是当前 formatter 的机械迁移；既有导出及 derived 方法没有被无说明删除。
- API 门禁只对受支持的声明形状作保守审查；不是 ABI、类型可赋值、行为或编译器来源证明。接口元数据由调用方声明。

## 仍保留的边界

1. 源码前端不是完整 AST / type / binding resolver。跨物理行插值和不能识别的公开形式返回不确定错误；仍须运行 `moon check`。
2. JS/TS 旧 line matcher 会看到 literal text，两项已知限制继续 expectedFailure；不声称全部 JS/TS 规则具备 AST 语义。
3. 基线指纹为非密码学内容身份，不能区分预算内的相同删除/替换，也不识别祖先；内部或字面量空白不折叠。
4. Git blob 映射捕获发生在 selection 之后，不能保证 selection 期间的并发变更原子性。live-tree context 与 fix 的预写重读也不是文件系统 CAS 事务。
5. CI 安装 latest 并记录版本，不是固定工具链；本轮没有核验远端 CI 或解除历史账单/网络问题。

## 申报书复核

[仓库校正稿](<申报书.md>) 与桌面副本同步；原稿分别保存在本地忽略的 [repo original](<internal/submission-before-20261104/repo-original.md>)、[desktop original](<internal/submission-before-20261104/desktop-original.md>)。

- 已恢复 1–8 项，去掉坏表格与坏链接，修正 W74 / Rust 使用条件 / 显式 baseline / 实际六条示例 / reference-license 事实。
- 已按核实的八项要求精简，未取得登录后的原始模板正文，因此不保证原样版式或单页打印。提交前请本人对照正式模板控制页数。
- 公告要求本人撰写。这里做了 AI 辅助事实与格式校正，**不能作为“未使用 AI 编写”的证明，也不建议直接提交**；须本人审阅、重写定稿。
- 至少 10 个历史实质实现/回归提交可逐项复核：`d5a7404`、`97c07fc`、`24b77cf`、`6ba3812`、`c114681`、`d97b769`、`bed9736`、`9ac5b96`、`3a0fec7`、`3792f15`。没有把 33 次总提交数当作全部有效性证明。
- 不保证比赛仍接受补交或最终评审通过；公开代码和最终材料须由申请人复核、更新、提交。
