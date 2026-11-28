# ETAF Org 扩展与组件指南

`etaf-org` 通过一套统一节点模型同时驱动原生 Org 语法与扩展组件：两者共用 `etaf-org-node-definitions` 注册表、9 种属性类型校验、`etaf-org-set-attr` 样式规则级联，以及 12 个公开 `env` 渲染原语。

## Org 原生扩展语法

1. **特殊块容器**：`#+begin_<name> :key val ... #+end_<name>`，支持最多 8 层嵌套；块内可自由书写任意原生 Org 段落、列表、表格、代码与公式。
2. **附着属性**：`#+attr_etaf: :key val` 可附着在 `#+begin_src`、Org 表格、引用块或容器上方；优先级为行内参数 > `#+attr_etaf:` > 其他 `#+attr_*:`。
3. **子块标记**：使用 `#+<marker>:` 切分多面板容器（如 `tabs` 内的 `#+tab:`、`diff` 内的 `#+before:` / `#+after:`、`pros-cons` 内的 `#+pro:` / `#+con:`）。
4. **动态块**：`#+BEGIN: clocktable` / `columnview` 直接渲染内部生成的 Org 表格；`org-query`、`clock-summary` 等活视图同时支持 `#+begin_` 与 `#+BEGIN:` 写法。
5. **行内链接微组件与语法糖**：`[[kbd:T]]`、`[[badge:success:就绪]]`、`[[sym:etaf-org-open]]`、`[[color:#0969da]]`、`[[spoiler:隐藏]]`、`[[icon:star]]`、`[[abbr:ETAF]]`、`[[roam:id]]`、`[[denote:id]]`，以及 `==高亮==` 与 `!!剧透!!`。

## 内置组件清单

调用 `(etaf-org-describe-nodes)` 可随时查看全部已注册节点的属性、子块与生效样式规则。

- **可设样式的核心 Org 节点**：`headline`、`src`、`table`、`quote`、`callout`、`drawer`、`planning`、`math`。
- **L0 提示与排版**：`note`..`danger`（统一 3px 左竖条 + 柔底色）、`box`（7 种底色层级）、`card`（6 种语义强调色含 `important`，支持 `:text-align center`）、`columns`/`col`（`:grow`、`:justify-content`、`:wrap`、`:divider`）、`details`、`left`/`center`/`right`/`justify`、`window`、`panel`、`tab-panel`、`form`、`log`、`statusbar`。
- **L0 集合、交互与展示**：`steps`/`step`、`timeline`/`event`（横向 `:time` 眉行 + `< 28ch` 自动退化纵向）、`stats`/`stat`（四象限简洁布局，支持 `:from` 绑定命名 Org 表格）、`field`、`file-tree`（支持 `:lines nil` 与 `*focus*`/`**focus**` 高亮）、`chat`、`tabs`、`code-tabs`（单层外框）、`accordion`、`swiper`、`code-tree`（视口滚动不裁半行且按词折行）、`home-box`、`link-card`、`image-card`、`qrcode`。
- **L0 数据可视化与对比**：`chart`（`line`/`bar`/`stacked`/`heatmap`，支持 `:from` 绑定命名 Org 表格，`stacked` 单位为 `%` 时不重复标注）、`progress`、`keymap`（三线书刊表，`/` 分隔符不画键帽）、`breadcrumb`、`diff`（并排配对对齐，窄窗自动切统一视图且 `-` 严格在 `+` 之前）、`pros-cons`（去重框、3px 左竖条 + 等高）、`demo`（顶部纯净画布 + 底部轻条按需展开源码）。
- **L1 工作区只读视图**：`include`（单框）、`code-ref`（单框 + `forward-sexp` 完整平衡 Elisp 表单抓取）、`symbol`（API 词条风，展示完整首段文档）、`project-tree`、`git-log`（兼容 Git 与 Jujutsu）、`git-diff`（兼容 Git 与 Jujutsu）。
- **Org 专属 L1 活视图**：`org-query`、`kanban`、`clock-summary`、`transclude`、`backlinks`。
- **L2 显式确认动作**：`run`。

## 样式规则与自定义节点

```elisp
;; 为一级标题加编号与前缀
(etaf-org-set-attr '(headline :level 1) '((prefix "§ ") (numbering decimal)))

;; 将自定义节点放入 etaf-org-node-directory（默认 ~/.emacs.d/etaf-org/nodes/）
(etaf-org-define-node 'release-note
  :name "release-note"
  :summary "版本发布卡片"
  :attrs '((version :type string :required t :doc "版本号"))
  :view (lambda (env)
          (etaf-node 'column (list :width 'stretch
                                   :border-left (list '(px 3) 'solid (etaf-org-accent env 'primary))
                                   :background-color (etaf-org-surface env 'raised)
                                   :padding '((lh 1) (ch 2)))
                     (list (etaf-node 'text (list :color (etaf-org-accent env 'primary)
                                                  :font-weight 'bold)
                                      (list (format "版本 %s" (etaf-org-attr env :version))))
                           (etaf-org-content env)))))
```

也可以通过 `etaf-org-set-view` 包装已有节点的绘制逻辑（内部调用 `etaf-org-default-view`），或在 `etaf-org-src-renderers` 中为任意源码语言注册自定义渲染函数。
