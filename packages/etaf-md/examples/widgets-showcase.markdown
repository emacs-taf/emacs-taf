---
title: ETAF Markdown 现代组件精选
author: ETAF Contributors
date: 2026-11-22
version: 0.3.0
status: active
tags: [etaf-md, editorial, living-doc]
---

:::breadcrumb {items="[首页](all-syntax.markdown) > 扩展文档 > 现代组件精选"}
:::

这一页按「书刊阅读流 + Emacs 活文档」的克制美学，集中展示精选保留且视觉重构后的核心扩展组件；每个组件都有明确的阅读或工程场景，遵循统一字号、去重套框与四级叶级 Hover 纪律。按 `C-c t` 可随时开关独立 Emacs 右侧大纲窗口，按 `t` 切换深色 / 浅色 / 护眼三套主题。

## 1. 行内轻语义、可折叠提示与增强代码块

*[ETAF]: Emacs Text Application Framework

文档保留纯净阅读流，仅按需嵌入轻量语义：防剧透遮罩 !!点击或按 S 揭晓隐藏结论!!、展开旁注 [+hover-policy]、术语缩写 ETAF、跨文档双链 [[all-syntax#表格|全语法示例]]、Emacs 活符号 :sym[etaf-md-open] 与色值 :color[#4493f8]。%% 文档内联注释不会渲染到页面上 %%

[+hover-policy]: 静态正文、代码行与已选标签永不挂 `mouse-face`；仅未选中的单色叶控件获得主题派生悬停底色。

- [x] 修复 `card` 六种强调色与 `box` 七种底色层级
- [x] 修复独立数学公式并发缓存竞态与 `columns`/`table`/`file-tree` 属性缺陷
- [ ] 在真实 GUI Emacs 中完成深色、浅色、护眼三主题逐屏验收

> [!tip]- 技巧 · 可折叠 Obsidian 风格提示（点击标题就地展开）
> 把补充细节藏在可折叠提示块中，既不打断主阅读流，又能在需要时原地展开查看。

```elisp title="live-snippet.el" {2} /highlight/ :line-numbers :collapsed-lines=3 :indent-guides
(defun etaf-demo-greeting (name)
  ;; 高亮行与关键词 highlight
  (let ((highlight (format "Hello, %s!" name)))
    (when (stringp name)
      (message "%s" highlight))
    highlight))
```

## 2. 指标卡与书刊三线排序表

:::stats {columns=3}
:::stat {title="通过验收用例" value="403 项" trend="↑ +18%" accent=success spark="4,6,5,8,7,9,11"}
:::
:::stat {title="首屏渲染耗时" value="14 ms" trend="↓ -24%" accent=primary spark="19,17,18,16,15,14"}
:::
:::stat {title="Hover 违规项" value="0 处" trend="三主题全检" note="零静态污染" accent=success}
:::
:::

:::table {title="组件渲染开销实测（点击表头排序）" sortable=true copy=true}
| 组件 | 数据层 | 耗时 (ms) | 说明 |
| --- | --- | ---: | --- |
| diff | L0 纯文本 | 1.2 | 配对对齐并排 / 窄窗自动统一 |
| code-ref | L1 发布期读盘 | 3.5 | 按完整顶层定义引用源码 |
| git-log | L1 异步子进程 | 6.4 | 同时兼容 Git 与 Jujutsu 仓库 |
:::

:::progress {title="重构交付进度" accent=success}
- 核心 UI 与主题色盘 : 100%
- 老语法缺陷修复 : 15/15
- 书刊风组件重构 : 100%
:::

:::chart {type=bar label="各阶段耗时对比" values="解析:4,布局:7,绘制:3" unit="ms" accent=primary}
:::

:::chart {type=stacked label="代码归属分布" values="Emacs 原生:58,纯文本组件:27,外部排版器:15" unit="%"}
:::

## 3. 横向时间线与配对对齐 Diff

:::timeline {orientation=horizontal card=true}
:::event {title="解析层与 Hover 纪律" time="Phase 1" status=success}
行内微语义、代码高亮折叠、叶级悬停。
:::
:::event {title="精简组件并统一书刊风" time="Phase 2" status=info}
砍掉凑数组件，重构视觉与响应式排版。
:::
:::event {title="真机多主题逐屏对比" time="Phase 3" status=warning}
暗 / 浅 / 护眼三主题与宽窄窗口实测对齐。
:::
:::

:::diff {title="Hover 策略重构" mode=side}
@before 旧实现（容器悬停破坏子色）
```elisp
(box :hover-style '(:background-color "#ddf"))
  (text :color muted "摘要")
  (text :color accent "链接")
```
@after 新实现（仅叶节点悬停）
```elisp
(box :pointer 'hand)
  (text :color muted "摘要")
  (etaf-md--leaf-button env "链接" fn)
```
:::

## 4. 权衡卡、Demo 与快捷键

:::pros-cons
@pro 优势
- 原生 Emacs 滚动、`isearch` 与终端兼容
- 零浏览器进程，启动与增量重排毫秒级
- 与 Emacs 符号、Git、工作区天然打通
@con 局限
- 不追求像素级阴影或复杂 CSS 动效
- 交互须遵守单色叶悬停，不覆盖子色（窄窗口自动垂直堆叠）
:::

:::demo {title="效果预览"}
> [!NOTE]
> 在 `:::demo` 中直接写 Markdown，顶部只看真实渲染效果，底部轻条按需展开源码。
:::

:::keymap {title="常用阅读快捷键" columns=2}
- C-c t : 开关独立大纲窗口
- v : 开关双栏对照编辑
- K : 就地预览链接或符号
- t : 切换深色 / 浅色 / 护眼
- n / p : 下一节 / 上一节标题
- e / o : 跳回 Markdown 源码行
:::

## 5. Emacs 原生活文档组件

:::symbol {name="etaf-md-open"}
:::

:::code-ref {src="../etaf-md.el" symbol="etaf-md-doctor"}
:::

:::include {src="../etaf-md.el" lines="1-12" title="etaf-md.el 入口头"}
:::

:::project-tree {path=".." depth=2 title="packages/etaf-md/"}
:::

:::git-log {limit=5 title="仓库最近提交"}
:::

:::run {title="检查 etaf-md 公开 API 边界" cwd="../../.."}
```sh
python3 scripts/check-api.py --workspace packages/etaf-md
```
:::
