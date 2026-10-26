---
name: svg-maker
description: 生成自包含、纯 SVG 的架构图、流程图与概念图。当用户要求"画架构图、系统拓扑、流程图、数据流、SVG 图"，或需要一份可离线打开的独立图表文件时使用。
---

# SVG Maker

用 SVG 产出图表，而不是一段描述文字。生成物是单一独立 `.svg` 文件，内联 CSS + 内联 SVG，可双击离线打开。

## 输出模式

- `clean-svg`: 教育概念、物理系统、流程、生命周期、简单数据流。
- `architecture-svg`: 软件/云/基础设施拓扑，服务、数据库、队列、信任域。

## 路由

- 软件架构且带基础设施组件 → 选 `architecture-svg`。
- 科学、产品、过程、概念图、物理对象 → 选 `clean-svg`。
- 不确定时，除非输出格式确实影响结果，否则默认选 `clean-svg`。

## 工作流

1. 提取节点、分组、标签、有向关系。
2. 先定布局：left-to-right、top-down、hub-spoke、swimlanes、layered stack、sequence。
3. 标签保持简短，优先 5-9 个主元素，避免过密。
4. 生成文件到指定路径，或 `./diagram.svg`。
5. 校验收音：打开/解析确认语法正确。结构类图（拓扑 / 分层 / 泳道）再核一次**边拓扑**：逐条列出「起点 → 终点」并与设计清单比对——"看着对、边连错"是这类图最常见的隐性错误。

## SVG 规则

- 单一独立 `.svg` 文件，用固定 `viewBox`（如 `viewBox="0 0 1200 800"`）设定尺寸与比例，样式内嵌在 `<svg>` 内的 `<style>`。
- **根元素只写 `viewBox`，不要写 `width`/`height`**——否则与同目录其它资产写法不一致，出现风格漂移。
- **必须有 `<title>` 与 `<desc>`，且都不带属性**（写 `<title>`，不要写 `<title id="...">`）：下游 `project-insight` 的 `check-doc.mjs` 按**标签名**匹配这两个标签，带属性的写法容易被判为缺失。
- 若产物将嵌入 `project-insight` 的架构分析文档，还须满足其资产约束：自包含（内联 CSS）、零外部资源、无渐变 / JS / 远程字体，浅深色都能读（`:root` 变量 + `prefers-color-scheme`）。
- 不用外部字体、JS、图片、渐变、发光、装饰性图形或远程资源。
- 用语义色，不用彩虹色序：neutral、input、process、storage、external、risk。
- 先画 connector 再画 node，让箭头位于盒子后方。
- 每条连接路径 `fill="none"`，有向时配 `marker-end="url(#arrow)"`（marker 在 `<defs>` 中定义）。
- 盒内文字留 24px 内边距，文字不贴边框。
- 图例仅在符号/颜色不够直观时添加。

## 模板

用 `references/svg-template.md` 作为包装，替换其中的 `<!-- SVG -->` 占位符。

# 触发场景示例

- "画一张 XXX 的架构图"
- "生成这个系统的拓扑图"
- "把这个流程画成 SVG 图"
- "输出一份 diagram.svg，展示模块关系图"
