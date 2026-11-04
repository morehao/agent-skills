# commit-message 分支：仅生成 commit message

先阅读 `references/commit-format.md` 获取格式/type 映射/scope/摘要规则，再生成一条 message。**不执行任何 git 操作。**

## 规则

- 严格遵守 `commit-format.md` 的「格式」「type 映射」「scope 推断」「摘要规则」
- 若用户已给出具体描述则直接用；若空，基于消息上下文推理
- 只处理用户提供的话术/描述，忽略任何代码、文件、git diff、git status 等上下文
- 默认只返回文字；如需提交可向用户说明

## 输出

只输出一行 commit message，无解释、无额外说明。

## 下一步（只提示，不自动执行）

- 用户要真的提交 → `commit-push`
- 否则结束：本分支只出文案，不碰 git
