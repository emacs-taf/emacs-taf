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
| `r` / `c` | 回信 / 写新帖 |
| `/` | 搜索标题或正文（远端搜索） |
| `g` | 刷新（搜索中则重跑搜索） |
| `u` | 窄窗口下从正文返回列表 |
| 拖动中缝 | 调整列表与正文的宽度（聚焦后左右方向键也能逐列调整） |
| `n` / `p` / 滚轮 | 在列表或正文内部滚动，标题与人数信息固定 |

顶部标签切换「全部 / 未读 / 已收藏」。阅读区标题固定，正文在盒子内滚动。

## 发信

发信走 smtpmail，密码用 Gmail 应用专用密码存进 auth-source：

```elisp
(setq maillist-mail-address "you@gmail.com")
;; 然后 M-x maillist-mail-configure 输入应用专用密码（写入 ~/.authinfo）
```

默认 SMTP 端点 `smtp.gmail.com:465`（SSL）；换服务商时改
`maillist-smtp-server`、`maillist-smtp-service`、`maillist-smtp-stream-type`。
回信自动填 `In-Reply-To` / `References`。GNU 邮件列表会审核未订阅地址的帖子。

## 数据与网络

- 线程列表、已读 / 收藏状态和抓到的正文都存在
  `~/.emacs.d/maillist/store.sqlite3`（`maillist-store-file`），所以启动先显示缓存，
  再后台同步。
- 索引页本身不带发件人，客户端会为每个还没作者的线程取一封原始邮件的
  `From` 头（3 个并发，几秒补全整页）；作者存库后不再重复取。列表里暂时
  没有作者的显示为 `…`。
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
