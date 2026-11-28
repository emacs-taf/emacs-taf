# etaf-ncm 开发指南

在这个仓库改代码、跑门禁、提交之前看这里。

## 分层：先确定改动落在哪一层

| 文件 | 职责 |
| --- | --- |
| `backends/netease/scripts/netease-api.mjs` | 取数：直连接口，收参数出 JSON，不认识状态目录 |
| `backends/netease/scripts/mpv-ctl.mjs` | 播放：常驻 mpv 的 IPC 桥，走 unix socket |
| `backends/netease/scripts/netease-cli.mjs` | 编排：跨平台 Node 入口，登录走这里，不需要 shell |
| `backends/netease/scripts/lib/queue.mjs` | 队列模型：`queue.json` + `queue.m3u8` + `urls.txt` 三份文件的读写与歌曲映射 |
| `backends/netease/scripts/refresh-urls.mjs` | 地址保活：直链约 5 分钟过期，按 `urls_at` 重取未播的地址并让 mpv 原地换行 |
| `backends/netease/scripts/netease-music.sh` | POSIX 编排：下载、下载列表、队列快照、`check`、`watch` 仍在这层 |

改取数只碰 `netease-api.mjs`。要加跨平台的新能力，先放 `netease-cli.mjs`。

## 平台矩阵：Windows 上哪些能用

- 所有平台可用：浏览、搜索、歌词、账号、短信登录、播放、播放控制（切歌/音量/拖动/随机/循环/跳转）、队列、封面、喜欢。走 `netease-api.mjs` 与 `netease-cli.mjs`，全程不经 shell。
- 仅 POSIX：下载、下载列表、队列快照（`queue-save` / `queue-load`）、`check`、`watch`，走 `netease-music.sh`。
- Windows 上后者由 `lisp/etaf-ncm-service.el` 的 `etaf-ncm--script` 明确报错 `Windows has no shell backend`，不会失败成 exit 127。

## 坑位

- `song/enhance/player/url/v1` 不带 `immerseType: 'c51'` 时对每首歌回 `code: 404`、`url: null`，现象是「所有歌都报可能要 VIP 或没有版权」。
- mpv 的 IPC 管道名在 Windows 上按 `path.resolve(状态目录)` 小写后哈希；用原始字符串哈希会让 Emacs 传来的 `c:/...` 和 CLI 算出的 `C:\...` 得到两个管道名，于是起两个 mpv，播放和状态落在不同进程。
- `urls.txt` 必须和 `queue.json`、`queue.m3u8` 一起落盘：status 靠它把 mpv 在放的条目对回歌曲，保活靠它知道哪些地址要换。

## 门禁与验证（Windows 上）

```powershell
# 编译后加载，byte-compile-error-on-warn 开着，返回 0 才算过
make compile EMACS="C:/Users/26289/Apps/emacs-30.1/bin/emacs.exe"

# 结构检查，不加 PYTHONUTF8 会因 cp936 解码报 UnicodeDecodeError
PYTHONUTF8=1 python3 scripts/check-repository.py

# 测试
emacs -Q --batch -L . -L lisp -L tests -L ../../core/packages/etaf -L ../../core/packages/etaf-ui -L ../../core/packages/ebox -L ../../core/packages/ecss -L ../../core/packages/etaf-db -l tests/etaf-ncm-tests.el --eval '(ert-run-tests-batch-and-exit)'
```

测试共 107 个用例。已知 Windows 既有失败 3 个，和本机平台有关，改动前后都在挂，不要当成自己的回归：

- `etaf-ncm-tests-library-snapshot-survives-restart`：文件权限位 600 与 666 不一致
- `etaf-ncm-tests-embedded-letters-and-layered-return`：焦点
- `etaf-ncm-tests-sidebar-entry-click-switches-library`：侧栏宽度

另有 6 个 POSIX-only 用例在 Windows 上 skip（`etaf-ncm-tests--shell-entry-p`）。

## 提交纪律：这个工作区是 CRLF 脏树

整棵工作区是 CRLF 脏树，`git status` 会显示几乎全部文件被改，`git ls-files --eol` 显示 `w/crlf`。这是历史状态，不是你的改动。

提交前对要提交的文件逐个恢复 LF，再只加这些路径：

```bash
sed -i 's/\r$//' <文件>
git add <文件>
git diff --cached --stat   # 核对只有真实改动
```

不要 `git checkout -- .`，会抹掉别人的未提交改动。
