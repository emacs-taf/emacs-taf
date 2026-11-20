# Ebox

[English](README.md)

Ebox 是面向 Emacs buffer 的 retained 文本布局引擎。它构建 text、box、row、column、
flex、grid 和 image 节点组成的可变节点树，计算基于 ECSS 的样式，在横向像素和纵向
行网格上排版，并把结果写入 Emacs buffer。节点挂载后，调用方继续修改同一棵树；
Ebox 跟踪 dirty 节点，只重写发生变化的 buffer 行和行内片段。

当包需要底层布局与 buffer 渲染时直接使用 Ebox；当应用还需要组件、响应式状态或应用
生命周期时，请使用同级 ETAF 包。

## 能力

- 用 `ebox-node-create`、`ebox-text-create` 或 `ebox-build` 消费的 author DSL 构建 retained 树。
- 用 `ebox-mount` 把根节点挂载到 buffer，或用 `ebox-render` 渲染离线输出。
- 通过文本、属性、状态和子列表 mutation 原地更新节点；`ebox-with-batch` 将多次 mutation 合并为一次 flush。
- 用内联属性和 ECSS scope 设置样式，并通过 selector 查询已挂载树。
- 组合 row、column、flex 和 grid 容器；测量文本与已准备的字符网格图片。
- 通过 Emacs text property 提供原生交互：keymap、help、pointer、hover 内容、focus、activation、scrolling 和 input session。
- viewport 变化时 refit 已挂载 buffer，并通过 update report 观察每次 flush。

## 先决条件

| 依赖 | 用途 |
| --- | --- |
| Emacs 29.1 或更新版本 | 所有 Ebox 使用场景。 |
| ECSS 0.1.0 或更新版本 | 样式 schema、selector、cascade 与 scope。 |
| 可选 `chafa` 或 `ffmpeg` 可执行文件 | 文本模式图片转换；不可用时回退到占位网格。 |

Ebox 没有原生模块。可用时，图片准备也可以使用 Emacs 图形图片支持。

## 从源码 checkout 安装

将 ECSS 和 Ebox 源码根目录加入 `load-path`，再 require 包入口：

```elisp
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/ebox")
(require 'ebox)
```

为了交互速度，每次更新 checkout 后在其中运行 `make native`。它会字节编译 Ebox，
并把原生代码存入你的 `eln-cache`；即使关闭了 JIT 原生编译，Emacs 也会自动用它
代替字节码，无需额外配置。之后修改过的源文件在下次 `make native` 前以字节码运行。

checkout 用户只 require `ebox`；`lisp/` 下的实现文件是私有的。权威 API 清单在
[`ebox.el`](ebox.el) 的 Commentary 中，工作流见 [ETAF 参考手册](https://etaf.top/zh-cn/ebox-node-construction/)。

## 最小可运行示例

以下示例已在 workspace 根目录用 `python3 scripts/elisp.py run -p ebox` 验证。

```elisp
(require 'ebox)

(let* ((root
        (ebox-build
         '(column :padding ((lh 1) (ch 2))
                  :border ((px 1) solid "#8A93A6")
                  (text :color "#263244" "Hello Ebox")
                  (row :item-gap (ch 1)
                       (box "Left")
                       (box "Right")))))
       (buffer (ebox-render-to-buffer "*Ebox Example*" root
                                      :width 480 :height 12)))
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))
```

`ebox-render-to-buffer` 会挂载 retained root。之后调用 `ebox-node-set-text`、
`ebox-node-set-props`、`ebox-node-insert` 等接口会修改同一棵树，并 flush 受影响的 buffer 行。

## 文档

- [参考手册](https://etaf.top/zh-cn/ebox-node-construction/)：ETAF 参考手册的 Ebox 章节。
- [架构](docs/architecture.zh-CN.md)：维护者使用的实现模块、数据流和不变式。
- [`ebox.el` Commentary](ebox.el)：完整受支持 API 清单。
- [变更日志](CHANGELOG.zh-CN.md)：用户可见变化和迁移说明。

## 检查

从 workspace 根目录运行：

```sh
make -C ebox structure-check
make -C ebox check
```

`make -C ebox check` 包含结构验证、byte compilation 和包维护的公开验收场景。

## 许可证

Ebox 按 GPL-3.0-or-later 分发。详见 [LICENSE](LICENSE)。
