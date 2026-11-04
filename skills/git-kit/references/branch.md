# branch 分支：基于中文描述创建并切换分支

基于中文描述生成 3 个候选分支名，用户选一后从基准分支创建并切换。只处理用户文本，忽略代码/文件/diff。

## 执行流程

1. **确定基准**：让用户选 A（远端最新 main/master，探测 `origin/main` 与 `origin/master` 取存在者作基准引用 `origin/<base>`，不拉取本地分支）或 B（当前分支）
2. **生成候选 3 个**：`<type>/<简短英文描述>`，风格/粒度各异（如 `feature/user-auth`、`feature/add-user-authentication`、`feature/login-secure-access`）；type 用下方「分支 type 映射」
3. **用户选**：请用户输 1/2/3
4. **创建切换**（同一 bash 链式）：
   - 基准 A：`git fetch origin && git switch -c <branchname> origin/<base> && echo "SWITCH_OK"`
   - 基准 B：`git switch -c <branchname> && echo "SWITCH_OK"`
5. **验证**：出现 `SWITCH_OK` 且 `git branch --show-current` 为 `<branchname>`

## 分支 type 映射（前缀用功能词）

| 中文语义 | 前缀 |
|---------|------|
| 新增、添加、实现 | feature |
| 修复、解决 | fix |
| 重构 | refactor |
| 文档 | docs |
| 格式/空格 | style |
| 测试 | test |
| 构建/依赖/脚本 | chore |
| 性能/优化 | perf |
| 热修复、紧急修复生产问题 | hotfix |
| 发布、版本准备 | release |
| 实验性尝试 | experiment |
| 概念验证 | poc |

## 候选规则

- 三个候选需风格/粒度不同（如简洁型 `feature/user-auth`、展开型 `feature/add-user-authentication`、侧重实现点型 `feature/login-secure-access`）
- 均 kebab-case 小写、≤50 字符、简洁、概括意图
- 不与仓库已有分支冲突（可先 `git branch --list` / `git branch -r` 核对，冲突则换名）
- 实验/临时性工作优先用 `experiment/` 或 `poc/` 前缀，避免与正式功能混淆

## 示例

| 输入 | 候选 |
|------|------|
| 新增用户认证功能 | `feature/user-auth` / `feature/add-user-authentication` / `feature/login-secure-access` |
| 修复登录页密码验证 bug | `fix/login-password-validation` / `fix/auth-password-check` / `fix/login-form-security` |
| 重构订单模块代码结构 | `refactor/order-module` / `refactor/order-code-structure` / `refactor/order-domain` |
| 优化首页加载性能 | `perf/homepage-load-speed` / `perf/index-page-performance` / `perf/front-page-render` |
| 紧急修复线上登录崩溃 | `hotfix/login-crash` / `hotfix/auth-online-halt` / `hotfix/fix-login-meltdown` |
| 发布 v2.0 版本准备 | `release/v2.0` / `release/2.0.0` / `release/version-2` |

## 验收标准

- 出现 `SWITCH_OK` 且 `git branch --show-current` 为新分支
- 未真正创建切换（仅列候选名）即失败，继续
- 分支已存在/`git switch` 报错等 → 停并完整报告，不伪造成功

## 下一步（只提示，不自动执行）

- 改动完成后 → `commit-push` → `pr-create`
- 否则结束：本分支只建/切，不提交
