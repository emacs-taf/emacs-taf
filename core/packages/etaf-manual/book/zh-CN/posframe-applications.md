# 面板应用

面板应用是窗口为浮动面板的 ETAF 应用：计时器、播放器、阅读器。注册一个应用就是描述怎么建它的会话、怎么渲染它，之后由注册表负责打开、关闭、保活与绑键，应用不必自己写命令、开关与 keymap。面板本体见[浮动面板](posframe-panels.md)，本章讲注册表。

## 注册应用

<!-- index: 面板应用; etaf-posframe-register-app; 保活; 停止回调 -->

#### Function: etaf-posframe-register-app (id &rest options)

把一个 ETAF 应用注册成浮动面板。

**参数。** ID 是命名该应用的符号。OPTIONS 由注册选项与面板选项两部分组成：

| 注册选项 | 取值 | 默认 | 含义 |
| --- | --- | --- | --- |
| `:create` | 零参函数 | 必填 | 返回这个应用的新会话。 |
| `:view` | 一参函数 | 必填 | 接收会话，返回它的 View。 |
| `:title` | 字符串 | ID 的名字 | 人类可读的名字，也是面板标题栏文字。 |
| `:shortcut` | 非空键字符串 | 无 | `etaf-posframe-app-prefix` 给这个应用绑的键。 |
| `:require` | feature 符号 | 无 | 建会话之前要加载的 feature。 |
| `:keep-alive` | `t`、`nil` | `nil` | 关闭时只隐藏面板、会话留给下次打开，音乐与游戏因此能继续；nil 时面板关闭即停止应用。 |
| `:on-stop` | 一参函数、`nil` | `nil` | 应用停止时以会话为参数调用。 |

其余面板选项原样交给 `etaf-posframe-show`，注册时没给的取注册默认：

| 面板选项 | 注册默认 |
| --- | --- |
| `:at` | `frame-top-right` |
| `:stack` | `t` |
| `:width` | `etaf-posframe-default-width` |
| `:height` | `etaf-posframe-default-max-height` |
| `:title` | 注册里的 `:title` |
| `:focusable` | `t` |
| `:focus-on-open`、`:auto-hide`、`:fill-height`、`:theme`、`:border`、`:draggable`、`:resizable` | 与 `etaf-posframe-show` 的默认相同 |

应用在自己的 View 里用 `etaf-surface-declare` 声明了表面时，`:theme` 对它不再起作用：面板画应用自己的调色板，标题栏给出应用自己的模式，应用内部的切换与标题栏的切换写同一格状态，见[表面声明](component-styles-and-themes.md#表面声明)。`:key` 不能由注册指定：注册表把它设成 ID，`etaf-posframe-app` 才能找到自己开的面板。面板选项的完整取值表见[面板选项](posframe-panels.md#面板选项)。

**语义。** 注册是全局的，与任何已打开的面板无关：它只记录怎么建这个应用，所以同一个 ID 再注册是替换记录与快捷键，而不是开出两个面板。会话由 `:create` 建、由面板持有；关掉一个没有 `:keep-alive` 的应用会停止它，面板关了就不留东西在跑，而 `:keep-alive` 的应用会一直留着会话，直到 `etaf-posframe-app-quit` 停它。`:on-stop` 是应用释放会话所持东西的唯一地方——一个连接、一个计时器、一个文件。

**返回。** 注册用的 ID。

**错误。** ID 不是符号、或注册里没有 `:create` 或 `:view` 时报 `etaf-posframe-error`。其他选项的值等到开面板时才用，所以非法的面板选项从 `etaf-posframe-app` 报出来，而 `kbd` 读不了的 `:shortcut` 在重建快捷键 keymap 时报错。

**示例。**

```elisp
(etaf-posframe-register-app
 'timer :title "Timer" :shortcut "t"
 :create #'my-timer-create :view #'my-timer-view
 :require 'my-timer
 :width 42 :at 'frame-top-right :stack t
 :focusable t :draggable t)
```

## 打开与关闭

<!-- index: etaf-posframe-app; etaf-posframe-app-quit; 应用开关 -->

#### Function: etaf-posframe-app (id)

打开 ID 的面板；已经开着就关掉它。

**语义。** 交互调用且没有 ID 时在已注册的应用里选。打开会挂载整个应用，所以 `etaf-posframe-app-repeat-delay` 秒之内的重复调用会被忽略；这条保护是必要的，否则按住键会让应用每个重复挂载一次，把 Emacs 卡住。没有 `:keep-alive` 的应用关掉面板即停止，再打开是全新的会话。

**返回。** 打开时返回面板，关闭时返回 nil。

**参见。** `etaf-posframe-app-quit`、`etaf-posframe-app-repeat-delay`。

#### Function: etaf-posframe-app-quit (id)

停止应用 ID。

**语义。** 它隐藏面板、用会话调用应用的 `:on-stop`、再丢掉会话，所以 `:keep-alive` 的应用会真正退出。这就是关窗口与退出的区别：关闭是隐藏，退出是释放。对没在开着的应用调用也安全。

**返回。** 停掉了应用时返回非 nil。

**参见。** `etaf-posframe-register-app`、`etaf-posframe-app`。

#### Variable: etaf-posframe-app-repeat-delay

忽略重复应用开关的秒数，默认 0.3。

**语义。** 打开面板会挂载整个应用，否则按住键会每个重复挂载一次，把 Emacs 卡住。调大它，按住键时更慢才会切第二次；调小它，有意连按两次能更快切回来。

## 快捷键与轮转

<!-- index: 面板快捷键; etaf-posframe-app-prefix; etaf-posframe-cycle; etaf-posframe-app-map -->

注册里的 `:shortcut` 是键字符串，一个绑定就能开出全部：`etaf-posframe-app-prefix` 读一个键，打开绑定到它的那个已注册应用，所以每个注册的快捷键都生效，调用方不必重建 keymap。想直接绑 keymap 的调用方绑 `etaf-posframe-app-map`，里面每个注册快捷键一个绑定。

#### Function: etaf-posframe-app-prefix ()

读一个键，打开绑定到它的已注册应用。

**语义。** 绑一次，之后每个注册的 `:shortcut` 都能用。它和 `etaf-posframe-app` 共用同一条重复保护，按住前缀键不会连着挂载一串应用。

**返回。** 打开时返回面板，否则 nil。

**参见。** `etaf-posframe-app-map`、`etaf-posframe-app`。

#### Function: etaf-posframe-cycle ()

把输入焦点移到下一个打开的面板，从最后一个再回到它所属的 frame。

**语义。** 当前没有聚焦任何面板时，它聚焦最近的那个。它只在接受键盘的面板之间走，所以轮转永远不会停在用户打不进字的面板上。把它绑到一个键，就得到一条在打开的应用与背后 buffer 之间来回的键盘路径。

**返回。** 拿到焦点的面板；焦点回到 buffer 自己的 frame 时返回 nil。

**参见。** `etaf-posframe-panels`、`etaf-posframe-panel-keys`。

#### Variable: etaf-posframe-app-map

每个注册快捷键一个绑定的 keymap。

**语义。** 注册应用时填充，所以调用方绑一次这个 map，而不是为每个应用绑一个键。它是 `etaf-posframe-app-prefix` 的直接形式：同样的快捷键，以前缀 map 的方式可达。

**参见。** `etaf-posframe-app-prefix`、`etaf-posframe-apps`。

#### Variable: etaf-posframe-apps

已注册应用，按注册顺序排列的 `(ID . PLIST)` 记录。

**语义。** `etaf-posframe-app` 读这些记录来挂载应用；列应用列表的启动器读同一份，而不是自己再存一份副本。再次注册会在原位替换记录。

**参见。** `etaf-posframe-register-app`、`etaf-posframe-app-map`。

## 一份完整的注册

<!-- index: 面板应用示例 -->

应用的三部分——建会话、渲染、注册——可以放在一处，面板按键、快捷键与退出路径都由注册表给出：

```elisp
(defun my-clock-create ()
  "Return a fresh session for the clock."
  (list :now (etaf-ref (current-time)) :timer (run-at-time 1 1 #'my-clock-tick)))

(defun my-clock-view (session)
  "Return SESSION's View."
  (etaf-view (text (format-time-string "%H:%M" (etaf-value (plist-get session :now))))))

(etaf-posframe-register-app
 'clock :title "Clock" :shortcut "c"
 :create #'my-clock-create :view #'my-clock-view
 :require 'my-clock
 :keep-alive t :on-stop (lambda (session) (cancel-timer (plist-get session :timer)))
 :theme 'dark :draggable t)

(global-set-key (kbd "C-c e") #'etaf-posframe-app-prefix)
```
