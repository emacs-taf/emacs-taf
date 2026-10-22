# maillist

[ETAF](https://github.com/emacs-taf/etaf) 文本邮件列表客户端：读 public-inbox
档案（线程列表、会话正文），并把「已读 / 收藏」存在本地；回信与新帖用
`message-mode` + smtpmail 发出。

## 要求

- Emacs 29.1 或更新版本（需要内置 SQLite）。
- 提供者检出：`etaf`、`etaf-ui`、`ebox`、`ecss`、`etaf-db`。放在本仓库旁边
  （`../etaf` 等），或放进工作区的上级目录（`../../etaf` 等）。

## 安装与运行

把本仓库根和提供者的仓库根加进 `load-path`，然后：

```elisp
(require 'maillist)
M-x maillist-open
```

## 用法

| 按键 | 作用 |
| --- | --- |
| `j` / `k` | 下一 / 上一线程 |
| `RET` 或点击 | 打开线程 |
| `s` | 收藏或取消收藏 |
| `e` | 展开更早的邮件（长线程先显示最新 20 封） |
| `r` / `C-u r` | 回信到列表 / 私回最后一封的作者 |
| `c` | 写新帖 |
| `/` | 搜索（档案字段、日期、本地已读与收藏） |
| `g` | 刷新（搜索中则重跑搜索） |
| `u` | 窄窗口下从正文返回列表 |
| 拖动中缝 | 调整列表与正文的宽度（聚焦后左右方向键也能逐列调整） |
| `n` / `p` / 滚轮 | 在列表或正文内部滚动，标题与人数信息固定 |

顶部标签切换「全部 / 未读 / 已收藏」。阅读区标题固定，正文在盒子内滚动。

## 搜索语法

搜索框认这几个前缀，剩下的词和 `"带空格的短语"` 按普通全文条件发出：

| 写法 | 作用 |
| --- | --- |
| `from:` `to:` `subject:` `body:` `message:` | 交给档案搜对应字段 |
| `after:2026-10-01` `before:2026-10-10` | 日期范围 |
| `is:unread` `is:starred` | 用本地已读、收藏筛选，不发请求 |

只写 `is:unread` 这类本地条件时，筛的是当前列表，不会联网；`g` 重跑当前
搜索，`is:` 条件继续生效。正在阅读的那一条会留在列表里，读完不消失，方便
接着按 `j` 往下走。

## 发信

发信走 smtpmail，密码用 Gmail 应用专用密码存进 auth-source：

```elisp
(setq maillist-mail-address "you@gmail.com")
;; 然后 M-x maillist-mail-configure 输入应用专用密码（写入 ~/.authinfo）
```

默认 SMTP 端点 `smtp.gmail.com:465`（SSL）；换服务商时改
`maillist-smtp-server`、`maillist-smtp-service`、`maillist-smtp-stream-type`。
回信自动填 `In-Reply-To` / `References`。GNU 邮件列表会审核未订阅地址的帖子。
密码只在发送时读取：没配密码也能先把回信写完，发不出去时再运行
`M-x maillist-mail-configure`。`C-u r` 私回最后一封的作者，不进列表。

## 数据与网络

- 线程列表、已读 / 收藏状态和抓到的正文都存在
  `~/.emacs.d/maillist/store.sqlite3`（`maillist-store-file`），所以启动先显示缓存，
  再后台同步。线程按邮件列表分开存，换一个列表不会看到上一个列表的线程；
  已读与收藏单独一张表，刷新档案缓存不会碰它们。
- 刷新会把档案首页合并进列表，不会整页替换：首页只列最近的线程，更早的
  线程留在列表里，不会因为一次 `g` 消失。
- 只有正文真的显示出来才标记已读；抓失败、超时或只是按 `j` 扫过去，线程
  仍然保持未读。
- 缓存文件来自不兼容的旧版本时，启动会把它移到同目录的 `.rebuild-<时间>`
  文件旁并重建，而不是静默失去持久化；提示里会写出那个文件名。
- 索引页本身不带发件人，客户端会为每个还没作者的线程取一封原始邮件的
  `From` 头（3 个并发，几秒补全整页）；作者存库后不再重复取。列表里暂时
  没有作者的显示为 `…`。
- 搜索结果是另一份视图，不会写回档案缓存：在搜索结果里打开线程，不会把
  搜索页的日期、人数或标题存成线程的事实。
- 网络默认先直连，失败才用环境里的代理（`maillist-network-route`）。

## 开发

```sh
make check     # 结构 + 字节编译 + 验收场景
make test      # 只跑验收场景
make clean
```

验收场景用 `tests/fixtures/archive` 里的本地镜像（`file:` URL）跑完整同步，
不需要联网。界面改动必须真实 GUI 验收；清单与做法见
`pi-skill etaf-app-dev guide verify`。
