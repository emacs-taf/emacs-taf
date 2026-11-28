---
title: 窗格工作区
author: ETAF Contributors
date: 2026-11-15
version: 1.0
status: 示例
license: GPL-3.0-or-later
tags: [面板, 标签页, 表单]
---

这一页用三个新容器拼出一个终端工作区：面板把标题与状态画在顶边上，标签页坐在面板的顶边里，表单行只在下划线里写字。全部内容都是 Markdown，渲染器不给这些位置留额外的行。

# 一个四窗格的工作区

:::columns {columns=2 divider=false gap="2ch"}
:::col
:::tab-panel {accent=primary}
@tab {title="notes.md" selected=true}
### Cell borders

:badge[rust]{.success} :badge[tui]{.info} :badge[ghostty]{.warning}

细线画在格子的边上，正文因此能贴到边框。窗格、标签、输入框和图表共用同一条线，页面看起来是一块整东西。

保存之后才刷新，改到一半不重排。

@tab todo.md
### 待办

- [x] 把标题画到顶边上
- [x] 标签页坐在顶边里
- [ ] 给图表加网格线
:::

:::panel {title="app.log" status="system.log" accent=danger}
:::log
- 09:41:14 WARN slow query 41ms
- 09:41:15 INFO pane 2 moved
- 09:41:16 ERROR attach failed
- 09:41:18 DEBUG pen cache hit
- 09:41:20 INFO listen :8080
:::
:::
:::
:::col
:::panel {title="top" status="#1" accent=important}
:::table {highlight-rows="2" text-align=right}
| PID | NAME | CPU% | MEM |
| --- | --- | --- | --- |
| 412 | ghostty | 12.4 | 312M |
| 977 | cargo | 41.0 | 905M |
| 1203 | rust-analyzer | 18.7 | 1650M |
| 88 | Launchd | 0.3 | 24M |
| 2311 | jj | 1.2 | 48M |
:::
:::

:::panel {title="general" status="#3" accent=success}
:::form
- Display name：Josh
- Theme：Ghostty Dark
- 字号：14 pt
:::
:::
:::
:::

:::statusbar {mode="notes" keys="n:下一块,p:上一块,q:退出,?:帮助" note="4 个窗格"}

# 面板

`:::panel` 只多一个顶边：标题在左、状态在右，正文从下一行开始；`focus=true` 把整圈线换成强调色，`variant=flat` 只留线不铺底色。

:::panel {title="一个普通面板" status="3 项"}
面板里的正文照常写，列表、代码、表格都能放。
:::

:::panel {title="聚焦的面板" focus=true status="editing"}
focus 用强调色画线，表示键盘落在这个面板里。
:::

:::panel {title="不铺底色的面板" variant=flat}
flat 只留线，适合已经在大底色里的面板。
:::

# 标签页

`:::tab-panel` 的标签与正文在同一个框里：标签那一行就是顶边，选中的标签用强调色和底色标出来。

:::tab-panel
@tab 概览
标签页的正文，放在面板里面。
@tab {title="配置" selected=true}
换一页只换正文，框不动。
:::

# 表单

`:::form` 的正文是一个列表，每项写 `名称：值`；名称在上、值在下，值下面是一条线。

:::form
- 仓库地址：github.com/emacs-taf
- 渲染器：Ebox
- 状态：stable
:::


# 图表

`:::chart` 用方块字符画面积图：每个格子八级高度，因此不依赖盲文字体；`values` 是空格或逗号分隔的数字，`width` 与 `height` 是格子数，`label` 写在图表上方。

:::chart {values="3 5 4 8 6 9 7 11 9 12 10 13 11 15 13 16 14 18 16 20 17 21 19 23 20 24 22 26 23 27 25 29 26 30 28 32 29 33 31 34" width="46" height="6" label="每秒请求"}
:::

:::chart {values="12 18 16 22 19 24 21 27 25 30" width="46" height="3" label="延迟（毫秒）"}
:::

# 状态栏

`:::statusbar` 一行放下模式、按键提示和右端说明；`keys` 写成 `按键:说明`，逗号分隔。

:::statusbar {mode="notes" keys="n:下一块,p:上一块,q:退出" note="3 个窗格"}
:::

:::statusbar {mode="general" keys="s:保存,r:重置,?:帮助" note="未保存的改动" }
:::
