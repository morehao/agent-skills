# 主流版本约定（示例先验：给模型读，不是给脚本读）

**这份文件是「读仓库前的先验知识」，不是脚本的规则表。** `release-preflight.sh` 里没有、也不该有
任何生态分支——它只做三件与语言无关的事：从已有 tag 推断命名样式、比较版本号大小、可选项回查
「这个版本字符串在不在这个文件里」。哪种仓库属于哪种约定、版本写在哪个字段，由你读仓库判断。

用法：先按本表认出仓库属于哪一类 → 按该类给出的命令跑预检 → 计划卡里写清证据（`文件:行号 → 原文`）。

## 一览

| 约定 | 版本写在哪 | tag 形状 | 版本回查 | 典型注意点 |
|---|---|---|---|---|
| npm / Node（单包） | `package.json` → `version` | `v1.2.3` | `--version <v> --version-file package.json` | 仓根即包根时最常见 |
| npm workspaces / pnpm / yarn | 每个包各自 `version` | `<pkg>-v1.2.3` 或 `@scope/pkg@1.2.3` | 指到具体包的文件 | 多版本线：必须显式 `--tag` |
| Rust / Cargo | `[package] version`；workspace 用 `[workspace.package]` + `version.workspace = true` | `v1.2.3` | 指到真正的声明文件 | inherit 型要指 workspace 根，不是成员 crate |
| Go（单模块） | **文件里没有**，构建时 `-ldflags -X ...=$tag` 注入 | `v1.2.3`（module proxy 强制） | **不回查** | 源码里常是 `dev` 占位，回查必然失败 |
| Go（同仓多模块） | 同上，一条版本线一套 tag | `sub/v1.2.3` | **不回查** | 一次只发一条线，用完整 tag |
| Python 静态（PEP 621） | `pyproject.toml` → `[project] version` | `v1.2.3` | 指 `pyproject.toml` | `[tool.poetry] version` 是另一处，选发布脚本真正读的那个 |
| Python 动态（setuptools-scm / hatch-vcs） | `dynamic = ["version"]`，真值只在 tag | `v1.2.3` | **不回查** | 指 `pyproject.toml` 会「找不到版本」，那是正常的 |
| Maven / Gradle（CI-friendly） | `pom.xml` 里可能是 `${revision}`，真值在 `.mvn/maven.config` / `gradle.properties` | `v1.2.3` | 指到真值所在文件 | 指 `pom.xml` 会假失败 |
| Dart / Flutter | `pubspec.yaml` → `version: 1.2.3+45`（版本 + build 号） | `v1.2.3+45` | 声明时**带上 `+build`** | 只写 `1.2.3` 会与文件不匹配 |
| Helm chart | `Chart.yaml` 有两个版本：`version`（chart）与 `appVersion`（应用） | `demo-1.0.0` 或 `v1.0.0` | 声明 chart 的 `version` | tag 跟 chart 版本，不是 appVersion |
| PHP / Composer | `composer.json` 常常**不写** `version` | `v1.2.3` | 通常不回查 | 版本由 tag 派生 |
| Ruby gem | `.gemspec` 读 `lib/*/version.rb` 常量 | `v1.2.3` | 指 `version.rb` | gemspec 里是变量名，不是字面值 |
| .NET | `VersionPrefix` / `MinVer` / `GitVersion` | `v1.2.3` | 视情况，MinVer 类**不回查** | 派生型的版本只来自 tag |
| 容器镜像 / 文档站 / 纯脚本 | 无 | 任意（`2026.10`、`release-1.2`） | 不回查 | 没有版本号概念也完全能发版 |

## 逐类示例

### 1. npm 插件仓（本仓生态的靶子仓：`@morehao/dsh-commands`）

- 仓根即包根：`package.json` → `version`；`publishConfig.access=public`
- tag：`v<version>`，由 `.github/workflows/release.yml` 的 `on: push: tags: ['v*']` 触发
- 发布脚本有**硬守卫**：tag 版本 ≠ `package.json.version` 直接 `exit 1`（tag 已推就不可改）
- CI **不建** Release → Release 由 `release` 流程默认创建
- npm 上同版本已存在则跳过（幂等）

```bash
bash scripts/release-preflight.sh --version 0.1.9 --version-file package.json --require-version-match
# 有了 --require-version-match：回查失败即 BLOCKED（这个仓值得严格，因为 CI 会拒发）
bash scripts/release-preflight.sh --version 0.1.9 --version-file package.json
# 不加严格模式：回查失败只 WARN + VERSION_FILE_HINT 告诉你稳定分支上实际是什么（升版本 PR 未合并时就是这种）
```

### 2. Node / Rust / Python 静态：一条命令

```bash
bash scripts/release-preflight.sh --version 1.2.3 --version-file package.json     # Node
bash scripts/release-preflight.sh --version 1.2.3 --version-file Cargo.toml       # Rust（inherit 型指 workspace 根）
bash scripts/release-preflight.sh --version 1.2.3 --version-file pyproject.toml   # Python 静态
```

### 3. Go / 动态版本：只给 tag，指定版本就够

```bash
bash scripts/release-preflight.sh --tag v1.2.3          # 单模块
bash scripts/release-preflight.sh --tag sub/v1.2.3      # 同仓多模块（一次一条线）
```

输出里会出现 `VERSION_ORIGIN=tag` 与 `WARN=version-origin-tag`——这是正常状态，不是缺陷。

### 4. Maven / Gradle：版本藏在属性文件里

```bash
bash scripts/release-preflight.sh --version 1.2.3 --version-file .mvn/maven.config   # ${revision}=1.2.3
bash scripts/release-preflight.sh --version 1.2.3 --version-file gradle.properties   # version=1.2.3
```

指 `pom.xml` 多半会得到 `VERSION_IN_FILE=no`（里面是 `${revision}`），用 `VERSION_FILE_HINT` 判断是不是指错了。

### 5. Dart / Flutter：`+build` 一起声明

```bash
bash scripts/release-preflight.sh --version 1.2.3+45 --version-file pubspec.yaml
# tag 也应带 build 号：v1.2.3+45（否则 tag 与 pubspec 对不上，或被当作同一版本）
```

### 6. Helm：两个版本，别选错

```bash
bash scripts/release-preflight.sh --version 1.0.0 --version-file Chart.yaml
# 声明 appVersion（2.5.0）也会 VERSION_IN_FILE=yes——所以计划卡要写 VERSION_FILE_LINE/VERSION_FILE_TEXT，
# 让用户看得到命中的是 `appVersion:` 那一行
```

### 7. 多版本线 / monorepo

```bash
# 直接给完整 tag：脚本不会替你在多条线之间猜
bash scripts/release-preflight.sh --version 1.4.0 --version-file a/VERSION --tag a-v1.4.0
# 只给 --version 且仓库有多个 tag 前缀 → BLOCKERS=target-tag-ambiguous（停下来问用户发哪条线）
```

## 计划卡里要写成什么样

```
版本源   package.json:3 → "version": "0.1.9"（回查 yes）
         | Chart.yaml:3 → appVersion: "2.5.0"（回查 yes，但 tag 用 chart 版本 1.0.0）
         | 未回查（注入型：真值来自 tag）
```

回查 `no` 时把 `VERSION_FILE_HINT` 一起写出来（「稳定分支上该文件现在是 1.0.0」），它比一句
`version-not-in-declared-file` 有用得多。
