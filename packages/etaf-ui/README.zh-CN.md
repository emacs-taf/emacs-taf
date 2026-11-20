# etaf-ui

`etaf-ui` 是 ETAF 的官方 Component 目录，是建立在 `etaf` 之上的可选独立包。它不增加第二套 Control 或 Widget 模型；Button、Checkbox、Label、Panel、DataGrid 都是使用同一套 View、属性、slot、事件和 Data 契约的普通 Component。
依赖 Emacs 29.1+、ETAF 0.2.2+ 和 Ebox 3.0.1+。

## 安装

在 Emacs 中执行以下代码一次，接受默认的组件画廊选项：

```elisp
;;; -*- lexical-binding: t; -*-
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)
```

package.el 自动安装 ETAF 及其依赖，不需要 Git、Python 或系统编译器，也不替换现有配置。以后用 `M-x etaf-install` 或 `M-x etaf-ui-gallery-open` 重开，包括离线使用。通过 `M-x list-packages` 更新或卸载包；更新或安装失败后先重启。详见[安装与恢复](https://etaf.top/zh-cn/introduction/#安装)。

## 第一个组件

所有 View 都使用准确的注册名称：`etaf-panel`、`etaf-label`、`etaf-button` 和
`etaf-checkbox`。把下面完整例子放进启用 lexical-binding 的 `.el` 文件求值，
再切换到 `*etaf-preferences*` 使用控件。

<!-- etaf-example: preferences -->
```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf-ui)

(etaf-define-component demo-preferences ()
  :bindings ((done (etaf-ref nil))
             (saved (etaf-ref "Unsaved"))
             (rows (etaf-ref 3)))
  :view
  (etaf-panel :title "Account"
    (slot :name 'header
      (etaf-button :label "Save" :ref 'save-button
                   :on-press (lambda () (setf (etaf-value saved) "Saved"))))
    (etaf-label :text (etaf-value saved))
    (etaf-checkbox :bind done :label "Done" :ref 'done-checkbox)
    (etaf-number-input :bind rows :label "Rows" :ref 'rows-input :min 1 :max 10)
    (text (expr (if (etaf-value done) "Complete" "Pending")))))

(etaf-mount "*etaf-preferences*" (etaf-view (demo-preferences)))
```

[完整用法与接口契约](https://etaf.top/zh-cn/ui-overview/)。

运行 `M-x etaf-ui-gallery-open` 浏览 8 类共 63 个组件。
Gallery 提供真实交互预览、中英文搜索、局部深浅主题、重置，以及每个组件的完整可复制示例，
只使用本地数据。宽窗口显示侧栏与双列总览，紧凑窗口改用分类选择器和可滚动的单列。
最小可用视口为 72 字符宽、24 行；更小的窗口保留布局并裁切。
[浏览流程与生命周期](https://etaf.top/zh-cn/ui-gallery-and-acceptance/)。

浮层界面可用 `etaf-popover`、`etaf-dropdown-menu` 和 `etaf-dialog` 组合普通控件
与 slot。运行 `M-x etaf-ui-surfaces-open` 打开[菜单与偏好设置示例](examples/etaf-ui-surfaces.el)。
运行 `make gui-check`，通过已有图形 Emacs 的 emacsclient 重复执行键盘和鼠标交互验收。
用 `make gui-check GUI_EXAMPLE=gallery` 验收集成 Gallery，覆盖抽屉切换、中文输入、受控选择和分页。

在开发工作区运行 `make perf-check PERF_ARGS='--diagnose'`，通过已有
原生 Emacs 测量注册的 Gallery 回调、键盘和鼠标场景。默认三组、每组十次，阶段、
CPU、分配诊断另行采集。复选框预算仍为 50 ms、浮层 100 ms，500 ms 是独立硬底线。
单独 checkout 可用 `PERF_TOOL=/path/to/workspace/scripts/performance.py` 指向同一工具。
基线比较、代码新鲜度与证据边界见工作区的 `docs/manual.zh-CN.md`。

选择场景分首次点击与连续切换：`gallery.selection.callback` 和
`gallery.selection.mouse` 每个样本重新挂载；带 `.steady.` 的对应场景保留页面，交替勾选和取消。
`gallery.categories.steady.callback` 和 `.mouse` 循环切换输入、数据与总览页面；
菜单、提示、通知与混合序列覆盖浮层。自建场景在计时前确定视口；批处理使用 160 字符宽、50 行。
这些版本化的目录浏览场景不能与旧 Atelier 工作台的性能结果直接比较。

## 开发

克隆后运行 `make setup-hooks`。提交变更前运行 `make check`；`make structure-check` 用于快速检查目录、命名和引用。

`make check` 运行规范检查、编译及 [tests/acceptance.json](tests/acceptance.json) 中的公共验收场景。`make test` 运行同一套公共 API 测试。清单涵盖全部维护的 Lisp 测试。GUI 与性能验收使用独立入口。
