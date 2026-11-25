# ETAF Org 用户手册

`etaf-org` 在 Emacs 内把纯文本 Org 文档渲染为现代交互阅读视图，磁盘文件始终保持标准纯文本。

## 打开与实时对照

- `M-x etaf-org-open`：主阅读入口。在 `.org` 缓冲区无前缀参数调用时零弹窗在当前窗口全宽直开，并自动定位到对应源码行；加 `C-u` 或在非 Org 缓冲区调用时才弹文件选择。阅读结束后按 `q`（`etaf-org-close`）原地切回原缓冲区，不误删用户窗口。重复打开同一真实路径文件会复用已有预览，不同目录同名文件自动消歧。
- `M-x etaf-org-preview`：在 `.org` 源码右侧非破坏性开关实时对照预览，保持光标留在源码中并开启比例跟随滚动；再次调用（或在预览中按 `q`）时仅回收其拆出的分屏窗口，不破坏其他窗格。在预览缓冲区内直接调用时等价于切换分屏（`etaf-org-toggle-split`）。
- 与 `etaf-md` 保持严格一致：全局 `M-x` 公共命令只保留 `etaf-org-open` 与 `etaf-org-preview` 两个入口；所有预览内操作通过预览缓冲区的快捷键触发且保持为非交互 Elisp 函数，不污染 `M-x`。可选编写辅助函数 `etaf-org-edit-mode`（柔和着色、CAPF 补全与块配对高亮）及 `etaf-org-insert-block` 可在 `org-mode-hook` 或自定义按键中按需挂接。

## 阅读快捷键

| 按键 | 命令 | 说明 |
| --- | --- | --- |
| `v` | `etaf-org-toggle-split` | 一键切换「单窗全宽阅读 ↔ 左源码右预览」 |
| `e` / `o` | `etaf-org-goto-source` | 跳回对应 Org 源码精确行并脉冲高亮（单窗时原地切回源码） |
| `n` / `C-c n` | `etaf-org-next-heading` | 下一个可见标题 |
| `p` / `C-c p` | `etaf-org-previous-heading` | 上一个可见标题 |
| `C-c j` | `etaf-org-goto-heading` | 补全跳转到任意标题 |
| `RET` / `C-c C-o` | `etaf-org-open-link` | 激活光标处链接、脚注、按钮或图片 |
| `K` | `etaf-org-preview-link` | 打开或关闭光标处链接/脚注/引用/目标的页内速览卡 |
| `f` | `etaf-org-follow-scroll` | 切换源码到预览的比例跟随滚动 |
| `C-c t` | `etaf-org-toggle-toc` | 开关独立右侧边大纲窗口（`*ETAF Org Outline*`） |
| `C-c /` | `etaf-org-filter` | 按 TODO、`:tag:`、`#A` 或关键词实时筛选章节 |
| `z` / `Z` | `etaf-org-cycle-fold` / `etaf-org-cycle-global-fold` | 折叠/展开当前节或全文 |
| `S` | `etaf-org-toggle-spoilers` | 全局显示/隐藏剧透遮罩 |
| `C-c v` | `etaf-org-toggle-hidden` | 切换显示注释、属性抽屉、LOGBOOK 与元数据 |
| `t` | `etaf-org-cycle-theme` | 循环切换 `dark` → `light` → `sepia` → `auto` |
| `[` / `]` | `etaf-org-narrower` / `etaf-org-wider` | 缩窄/加宽最大阅读栏宽 |
| `g` / `r` | `etaf-org-reload` | 重新读取并重绘文档 |
| `C-c h` / `?` | `etaf-help` | 查看快捷键帮助 |
| `q` | `etaf-org-close` | 卸载并关闭预览（自动回收独立大纲窗与分屏） |

## 方言控制（`etaf-org-flavor`）

- `etaf`（默认）：完整原生 Org 语法 + Org 原生扩展容器 + `#+attr_etaf:` + 行内链接微组件 + `==高亮==` / `!!剧透!!`。
- `standard`：仅渲染标准 Org 语法，关闭扩展容器与行内语法糖。
- 文档内覆盖：`#+ETAF_FLAVOR: standard` 或 `#+OPTIONS: etaf:nil`。
- 会话级覆盖：在 `etaf-org-create` 中传入 `:flavor 'standard` 或特性 plist。

## 主题与信任边界

- 主题 `auto`（默认）直接从当前 Emacs 主题的 face 推导表面与文字色，不覆盖页面背景；另有 `dark`、`light`、`sepia` 三套固定主题。`etaf-org-theme-tokens` 返回全部规范化为 6 位 `#RRGGBB` 的 ETAF UI Token 表。
- **L0（纯阅读）**：渲染阶段零磁盘、零进程、零网络 I/O。
- **L1（工作区只读沙箱）**：受 `etaf-org-allow-local-read`（默认 `t`）控制，涵盖 `#+SETUPFILE:`、`#+INCLUDE:`、`#+BIBLIOGRAPHY:` 以及 `include`、`code-ref`、`symbol`、`project-tree`、`org-query`、`kanban`、`clock-summary`、`transclude`、`git-log`、`git-diff`、`backlinks`；任何越出工作区根目录的路径均会被拒绝。
- **L2（显式确认动作）**：`etaf-org-allow-actions`（默认 `'ask`）控制 `run` 显式命令卡；`etaf-org-allow-babel`（默认 `nil`）控制代码块可选 Babel 执行；`etaf-org-interactive-checkbox`（默认 `t`）支持点击复选框同步源码与进度计数；`etaf-org-interactive-todo`（默认 `nil`）可选开启点击 TODO 标签轮换状态。

## 诊断与恢复

- 调用 `(etaf-org-doctor)` 检查外部可选能力（`mmdc`、`ffmpeg`、`qrencode`、`git`、`jj`、`rg`、`dot`、`plantuml` 等）。
- 扩展块属性错误、未闭合块或越界路径均在原位显示行号诊断卡，绝不阻塞文档其余部分。
- 磁盘缓存目录遵循 `etaf-org-cache-max-bytes`（默认 100 MiB）自动做空闲 LRU 清理。
