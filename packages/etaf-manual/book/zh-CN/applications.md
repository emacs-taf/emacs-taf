# 应用

*应用*是一个具名缓冲区里显示的一个已挂载 View，带着用户对一个程序期待的生命周期：在选中窗口里打开，随窗口变化让内容适配窗口，每个单元格都跟随主题，响应自己的键，离开时只保存一次状态。本章定义 `etaf-app-open` 与 `etaf-app-close` 提供的应用生命周期，应用的适配、主题与按键如何运作，以及打开或关闭失败时的恢复规则。运行命令行后端属于[异步模型](async.md#子进程)。

应用建立在 [Runtime](runtime.md) 之上：`etaf-app-open` 准备并显示缓冲区，然后调用 `etaf-mount`。嵌在别的缓冲区里的 View 或测试只需要 Runtime；应用在它外面补上顶层程序需要的东西。

<!-- index: 应用; 应用缓冲区; 应用生命周期 -->

## 模型

应用有一个名字（同时是它的缓冲区名）、一个 View，以及三份以函数提供的可选行为：让应用状态适配显示窗口的适配函数，保存或释放应用所持资源的关闭函数，以及画布的主题颜色。应用还带一个不透明的状态值，通常是它的命令要操作的记录或会话对象。

打开是一个事务：缓冲区被准备成画布、显示、适配、挂载，任何一步失败都会把应用再关掉。关闭有三种触发：杀掉缓冲区、`etaf-app-close`、用同一个名字重新打开；每一种都在 View 仍挂载时恰好运行一次关闭函数。

## 打开与关闭

#### Function: etaf-app-open (name view &key state on-fit on-close background foreground (cursor 'inherit) mode-line (display t) mount-options)

把 VIEW 作为应用缓冲区 NAME 打开，并返回该缓冲区。

**参数。**

- NAME 是缓冲区名。同名但不是已打开应用的缓冲区会被复用。
- VIEW 传给 `etaf-mount`：归一化的 View，或返回 View 的零参函数。
- STATE 是任意值；`etaf-app-state` 返回它。
- ON-FIT 是 nil 或单参函数，参数是显示窗口。它在应用缓冲区为当前缓冲区时运行。
- ON-CLOSE 是 nil 或无参函数。它在应用缓冲区为当前缓冲区时运行。
- BACKGROUND 与 FOREGROUND 是 nil 或一种颜色：颜色字符串、ref、computed，或返回颜色字符串或 nil 的零参函数。
- CURSOR 是一个 `cursor-type` 值，或 `inherit`（默认），表示保留缓冲区的光标。
- MODE-LINE 为 nil（默认）时隐藏 mode line，为 t 时保留，否则是一个 `mode-line-format` 值。
- DISPLAY 为 t（默认）时在选中窗口里显示缓冲区，是函数时由它接收并显示缓冲区，为 nil 时不显示。
- MOUNT-OPTIONS 是 `etaf-mount` 的 OPTIONS plist，或一个以显示窗口为参数（缓冲区未显示时为 nil）返回它的函数。函数在缓冲区里、ON-FIT 之后运行，所以固定的 `:viewport-height` 这类选项可以取自适配后的状态。

**语义。** 各步骤按以下顺序运行。

1. 名为 NAME 的已打开应用先被关闭，并运行它的关闭函数。
2. 缓冲区被准备成画布：截断长行，关闭水平滚动与滚动边距，关闭行号，被截断的行不显示续行符号，所以比窗口宽的内容被干净地裁掉。CURSOR 与 MODE-LINE 按上文生效。
3. BACKGROUND 与 FOREGROUND 重映射缓冲区的 default face，让 View 没有绘制的单元格（例如最后一行下面的区域）与应用的表面一致。响应式颜色变化时会重绘，直到应用关闭。
4. DISPLAY 显示缓冲区。为 t 时，用户的 `display-buffer` 规则无法把它转到别的窗口或拆分 frame。
5. 缓冲区有窗口时，ON-FIT 以该窗口运行一次，所以首次渲染就用上适配后的尺寸。
6. VIEW 以 MOUNT-OPTIONS 挂载；它是函数时先调用它。

挂载之后，显示窗口每次稳定下来的变化都会再运行 ON-FIT，见[适配窗口](#适配窗口)。

**返回。** 应用缓冲区。

**错误。** 任何一步的错误都会关闭应用，包括 MOUNT-OPTIONS 无效时的 `etaf-runtime-error`、View 的错误以及打开过程中的 `quit`：关闭函数运行、缓冲区被杀掉、条件向外传播。

**示例。** 一个笔记应用把会话对象当作状态，在适配函数里设定列表大小，关闭时保存。

```elisp
(defun notes-open ()
  (interactive)
  (let ((session (notes-session-create)))
    (etaf-app-open "*notes*" (lambda () (notes-view session))
                   :state session
                   :on-fit (lambda (window)
                             (notes-set-page-size
                              session (- (window-body-height window) 2)))
                   :on-close (lambda () (notes-save session))
                   :background (notes-theme-color session :bg))))
```

**参见。** `etaf-app-close`、`etaf-mount` 与[原生应用窗口](runtime.md#原生应用窗口)。

#### Function: etaf-app-close (&optional buffer-or-name)

关闭 BUFFER-OR-NAME（默认当前缓冲区）里的应用，返回 t。

**语义。** 关闭函数在 View 仍挂载时运行，然后 View 卸载、缓冲区被杀掉。交互调用时关闭当前缓冲区里的应用，所以应用可以在根 `:keys` 里把它绑到 `q`。

**返回。** t。

**错误。** 缓冲区里没有已打开的应用时 `error→ user-error`。关闭函数的错误在缓冲区消失之后向外传播；直接杀掉缓冲区时，同一个错误改为以消息报告，所以 `kill-buffer` 本身从不失败。

## 查找应用

#### Function: etaf-app-state (&optional buffer-or-name)

返回 BUFFER-OR-NAME（默认当前缓冲区）里已打开应用的 STATE，没有则返回 nil。

**语义。** 键命令在应用缓冲区里运行，所以它用 `(etaf-app-state)` 找到自己的会话，而不必另设一个缓冲区局部变量。关闭函数仍能看到这个状态，所以它可以保存自己所属的会话；关闭函数返回之后，这个调用返回 nil。

#### Function: etaf-app-buffer (name)

返回已打开应用 NAME 的缓冲区，没有则返回 nil。

**语义。** 入口命令若应回到已打开的应用而不是重新打开，就先检查它，再选中它返回的缓冲区。

## 适配窗口

<!-- index: 适配; 尺寸变化; 显示窗口; 固定视口 -->

应用在 ON-FIT 里让内容适配窗口：页面大小、行数预算、列宽，或者为画布有固有尺寸的应用设定固定视口。函数接收显示窗口并读取它的正文尺寸；它写 ref，View 据此渲染。

挂载之后，ON-FIT 每次稳定下来的变化运行一次：拖动窗口时 Emacs 会多次报告尺寸变化，引擎等这些变化停下来再重新适配 Runtime。随后 ON-FIT 在一个响应式批次里运行，排在 Runtime 自己的视口更新之后，所以重新适配与应用的改动一起发布。显示窗口的正文宽度或高度变化、缓冲区换到另一个窗口、文字缩放变化时它都会运行。minibuffer 或回显区消息临时占用窗口的行时它不运行，因为它们一关闭空间就回来了；重新适配会让内容跳动两次。

以固定 `:viewport-width` 或 `:viewport-height` 挂载的应用仍会收到 ON-FIT，所以可以在里面用新尺寸调用 `etaf-refit`。

## 主题与画布

<!-- index: 画布; default face; 应用背景 -->

View 只绘制它画出的单元格。窗口其余部分（例如短 View 下面的行，或窄 View 的右边缘）显示缓冲区的 default face。BACKGROUND 与 FOREGROUND 让这些单元格与应用一致：传入根 Host 使用的同一组主题颜色；主题可能在应用打开期间变化时，传 ref 或函数。重映射只属于应用缓冲区，并在应用关闭时结束。

## 按键

<!-- index: 应用按键; 根 :keys -->

应用在根 Host 的 `:keys` 里声明它的命令，见[键盘](keyboard.md#host-键)；它不安装自己的 keymap。根上的键出现在帮助里，让位于更近的 Host 与模态作用域，也不会破坏框架键。两条解析规则让根上的键足够应用使用。

- 根上的 RET 作用于应用的选中项，但比根更近的聚焦按钮仍会收到 RET。
- 指针事件（例如 `<wheel-down>`）从指针下的 Host 开始解析，所以一个窗格可以用自己的滚轮绑定滚动自己。

## 错误与恢复

打开从不留下半开的应用：某一步失败时，关闭函数运行、缓冲区被杀掉、条件向外传播，调用者可以修正原因后再次打开。关闭函数不应该发出信号；如果发出了，`etaf-app-close` 在缓冲区消失之后报告该错误，杀掉缓冲区则以消息报告它。无论哪种情况，应用都已关闭，它的名字可以再次打开。

Emacs 退出时关闭函数不运行。状态必须跨会话保留的应用还要在 `kill-emacs-hook` 里保存它。
