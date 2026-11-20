# 安装、加载与构建

本章列出各包对 Emacs 和系统的要求，说明怎样从源码检出或经 package.el 加载它们、怎样编译、怎样构建原生部分，以及缺少某个可选程序或库时会发生什么。

## 环境要求

<!-- index: 环境要求; Emacs 版本; SQLite 支持 -->

| 包 | Emacs | 可选的程序与库 |
| --- | --- | --- |
| `ecss` | 28.1 | — |
| `ekp` | 29.1 | C 模块需要：Emacs 支持动态模块、`make`、支持 POSIX 线程的 C11 编译器 |
| `ebox` | 29.1 | 终端帧里显示图片需要 `chafa` 或 `ffmpeg`；macOS 上的彩色 emoji 需要 `swiftc` |
| `etaf` | 29.1 | 视频需要 `ffmpeg`、`ffprobe` 和 `ffplay` |
| `etaf-ui` | 29.1 | 字体图标集需要对应的图标字体 |
| `etaf-db` | 29.1，且编译时带 SQLite 支持 | — |

一个包还要满足它所依赖的每个包对 Emacs 版本的要求，所以 ECSS 之上的包都需要 Emacs 29.1。EKP 用到 `string-pixel-width` 和 `object-intervals`，这两个函数是 Emacs 29.1 引入的。etaf-db 需要 `sqlite-available-p` 返回非 nil 的 Emacs。

批处理模式的 Emacs 能加载所有包、挂载 View、计算布局，各包自己的测试就是这样运行的。

### 图形帧与终端帧

<!-- index: 图形帧; 终端帧 -->

这些包在图形帧和终端帧里都能运行。终端帧里有些部分画法不同：

| 部分 | 图形帧 | 终端帧 |
| --- | --- | --- |
| 盒子背景 | `:border-radius` 把角变圆 | 方角，背景占满整行 |
| 边框 | 1 px 细线与圆角 | 一格宽的盒线；空白的边框行画成 `┌──┐` / `└──┘` |
| 字号 | `:font-size` 缩放字形 | 只有一个字号；提高字号的文字用粗体 |
| 图片 | 由 Emacs 显示 | 用 `chafa` 转成字符格，没有就用 `ffmpeg`，都没有就显示占位符 |
| `image` 模式的视频 | 每一帧显示为图片 | 退回 `ascii` 模式 |
| 图标 | SVG 图标集显示为图片，字体图标集画成 SVG 文字，高出行的字形不会被裁掉 | 注册的 `tty` 图标集提供一格宽的 Unicode 标记；其它图标集用文字变体 |

两种帧里，buffer 的每一行都保持标准行高，buffer 里的文字也从不被替换。在图形帧里，有的字符簇会把所在行撑高，比如彩色 emoji。Ebox 能渲染这种字符簇时，就在上面盖一张一行高的图片（见[Ebox 的 emoji 渲染器](#ebox-的-emoji-渲染器)），否则用 `height` display 属性把它缩小到放得下为止。批处理模式和终端帧里，字符簇保持原样。

### 字体

<!-- index: 字体; 图标字体 -->

Ebox 用帧实际使用的字体测量文字，所以普通文字不需要特定字体，比例字体和 CJK 字体都能对齐。组件目录的图标只有字体图标集需要字体：

| 图标集 | 字体族 |
| --- | --- |
| `nerd` | DroidSansMono Nerd Font 或 DejaVuSansMono Nerd Font |
| `fa` | FontAwesome |
| `material` | Material Icons |
| `octicons` | github-octicons |
| `sys`、`svg` | 不需要 |

`etaf-ui-icon-default-set` 的初始值是 `nerd`。图标的字体或字形缺失时，`etaf-ui-icon` 依次到默认图标集、`sys`、`svg` 里找这个图标，都没有就把图标名显示为纯文本。对于字体缺失的图标集，`etaf-ui-icon-metrics` 报告的像素高度和适配结果为 nil。

## 从源码检出加载

<!-- index: 源码检出; load-path; require -->

把每个仓库的根目录加进 `load-path`，再 require 要用的那个包的入口 feature。require 一个包会加载它依赖的包，所以那些包的根目录也要在 `load-path` 里：

| 要 require 的包 | 要加入的根目录 |
| --- | --- |
| `ecss` | `ecss` |
| `ekp` | `ekp` |
| `ebox` | `ecss`、`ebox` |
| `etaf` | `ecss`、`ebox`、`etaf` |
| `etaf-ui` | `ecss`、`ebox`、`etaf`、`etaf-ui` |
| `etaf-db` | `ecss`、`ebox`、`etaf`、`etaf-db` |

```elisp
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/ebox")
(add-to-list 'load-path "/path/to/etaf")
(add-to-list 'load-path "/path/to/etaf-ui")
(require 'etaf-ui)
```

只加根目录。每个入口文件加载时会自己把 `lisp/` 目录加进去，而那个目录里的 feature 都是内部的（见[公共接口](ecosystem-and-layers.md#公共接口)）。保持每个仓库的目录结构不变：EKP 从 `dictionaries/` 读断词词典，从 `native/` 读 C 模块；Ebox 从 `native/` 读 emoji 渲染器的源码。

除非 `load-prefer-newer` 非 nil，否则即使源码更新，Emacs 也会加载字节编译文件，只打印一条消息提醒。更新了含编译文件的检出后，要重新编译，或者在加载这些包之前设置 `load-prefer-newer`。

## 用 package.el 安装

<!-- index: package.el; autoload; 包归档 -->

每个入口文件都带有 package.el 读取的 `Version` 和 `Package-Requires` 头。一个包的归档包含它的入口文件和 `lisp/` 目录；EKP 的归档还需要包含 `dictionaries/` 和 `native/`。

Function 与 Macro 记录可以带一个 autoload 标记：

```elisp
;; Function: ekp-c-module-load ()
;;;###autoload (autoload 'ekp-c-module-load "ekp" nil t)
```

package.el 安装一个包时，会把这些标记收集进这个包的 autoload 文件。`ekp-c-module-build` 这样的公共命令装好就能用 `M-x` 调用。没有标记的公共函数或宏要等包加载后才可用；调用前先 require 这个包。其他种类的记录没有 autoload，同样要先 require。源码检出没有 autoload 文件，要直接 require 入口。

## 编译

<!-- index: 字节编译; 原生编译; load-prefer-newer -->

正式使用前要先编译：解释执行的代码慢得多。比如 EKP 字节编译后比解释执行快大约十倍。package.el 安装包时会对它做字节编译。在源码检出里：

- `make compile` 对包做字节编译。
- 在 Ebox 和 ETAF 仓库里，`make native` 先做字节编译，再把包编译成原生代码，放进 `eln-cache`。Emacs 无需额外配置就会用这份代码代替字节码，即使关闭了即时原生编译也一样。之后再改过的源文件以字节码运行，直到下一次 `make native`。
- `make clean` 删除编译产物。

#### Function: ebox-byte-compile ()

把每个 Ebox Lisp 源文件重编译到相邻的 `.elc` 文件。

**语义。** 该函数在它被加载的那个检出里，把 Ebox 入口与 `lisp/ebox-*.el` 模块就地字节编译，编译器输出写到 `*Ebox Byte Compile*`。Ebox 仓库的 `make compile` 运行的就是它。某个文件失败也会继续尝试其余文件；失败被收集起来，连同失败文件名一起报出。成功构建后重启 Emacs，让当前会话加载新的字节码；之后再改过的源文件要到下一次编译才以字节码运行。

**返回。** 未指定；效果就是这次编译。

**错误。** `error→ error` "Ebox byte compilation failed: FILE, …"，点名每个编译失败的文件。

## 原生组件

### EKP 的 C 模块

<!-- index: EKP C 模块; 动态模块 -->

EKP 可以用 C 动态模块计算断行：最优化计算在 C 里进行，多个段落在线程池里并行排版。这个模块是可选的，没有它，EKP 就用 Emacs Lisp 计算断行。

构建模块需要支持动态模块的 Emacs（即 `module-file-suffix` 非 nil），以及 `make` 和支持 POSIX 线程的 C11 编译器。有两种构建方式：

- `M-x ekp-c-module-build` 在 `native/` 目录里异步运行 `make`，构建成功后加载模块。它会读取一个构建 profile，默认是 `portable`。
- 在 EKP 仓库里运行 `make native-build`，构建 `portable` profile。构建结果用 `ekp-c-module-load` 加载。

| Profile | 编译器选项 |
| --- | --- |
| `portable` | `-O3`，不使用构建机器特有的指令 |
| `native` | `-O3 -march=native -flto`，针对构建机器优化 |
| `debug` | `-O0 -g3`，供调试器使用 |
| `sanitize` | `-O1 -g3`，加上地址检查和未定义行为检查 |

模块是 `native/` 目录里的一个文件，名为 `ekp`，后缀在 macOS 上是 `.dylib`，在 Windows 上是 `.dll`，其他系统上是 `.so`。require EKP 不会加载它。`ekp-c-module-load` 负责加载，并在回显区报告结果：

- 文件不存在时，报告找不到模块，EKP 继续用 Emacs Lisp。
- 模块比当前 EKP 要求的版本旧时，报告模块过旧，EKP 继续用 Emacs Lisp。这时要重新构建模块。
- 其他情况下启用模块，并报告它的版本和线程数。

`ekp-c-module-load` 加载的是文件的副本，所以会话中途重新构建的模块，可以再用同一个命令加载。

两个变量决定已加载的模块何时使用。`ekp-use-c-module` 默认非 nil，允许 EKP 使用模块；设为 nil 则强制用 Emacs Lisp。`ekp-auto-justify-native-append` 只作用于自动两端对齐开启时追加的文字；模块不可用时，这条路径退回 Emacs Lisp。

遇到未知的 profile、`native/` 目录里没有 Makefile，或者找不到 `make` 程序时，`ekp-c-module-build` 发出 `user-error`。构建失败时，它报告退出状态，并显示保存构建输出的 buffer。

### Ebox 的 emoji 渲染器

<!-- index: emoji; 彩色 emoji -->

彩色 emoji 的字形常常比一行文字高。在 macOS 上，Ebox 自己把这类 emoji 渲染成正好一行高的方形图片，让行高保持不变。条件是：帧是窗口系统为 `ns` 的图形帧，Emacs 支持 PNG 图片，能找到 `swiftc` 编译器，Ebox 仓库里有渲染器的源码。第一次需要图片时，Ebox 把一个小的辅助程序编译到 `user-emacs-directory` 下的 `ebox-emoji/` 目录，辅助程序渲染出的图片也以 PNG 文件存在这个目录里。辅助程序的源码变了时，Ebox 删除旧的辅助程序和图片，再构建新的辅助程序。Ebox 第一次需要辅助程序时如果它不可用，同一会话里就不再尝试。辅助程序是一个可执行程序，不是动态模块，也不需要单独的构建步骤。

渲染器不可用时，Ebox 改为把过高的字符簇缩小，见[图形帧与终端帧](#图形帧与终端帧)。

## 缺少可选依赖时

<!-- index: 可选依赖; chafa; ffmpeg; ffprobe; ffplay -->

| 缺少 | 结果 | 恢复办法 |
| --- | --- | --- |
| EKP 的 C 模块，或动态模块支持 | EKP 用 Emacs Lisp 计算断行 | 构建并加载模块 |
| 终端帧里的 `chafa` 和 `ffmpeg` | Ebox 在每张图片的位置显示占位符 | 安装其中任意一个 |
| `swiftc`，或者系统不是 macOS | Ebox 把过高的 emoji 缩小，不渲染成图片 | — |
| `ffmpeg` | 开始播放视频时，在启动任何进程之前发出 `user-error`，消息为 `ffmpeg is not available: PROGRAM` | 安装 ffmpeg，或把 `etaf-video-ffmpeg-program` 设为它的名字或绝对路径 |
| `ffprobe` | `etaf-video-source-info` 返回文档所述的默认元数据 | 安装 ffprobe，或设置 `etaf-video-ffprobe-program` |
| `ffplay` | 视频播放时没有声音，不报错 | 安装 ffplay，或设置 `etaf-video-ffplay-program` |
| Emacs 的 SQLite 支持 | etaf-db 每个要连接数据库的操作都发出 `etaf-sqlite-unavailable`；声明表和数据库仍然可用 | 换用编译时带 SQLite 支持的 Emacs |
| 某个图标字体 | `etaf-ui-icon` 从后备图标集里取该图标集的图标 | 安装这个字体 |

EKP 整个包都是可选的：其他包都不使用它，只有自己 require EKP 的程序才需要它。
