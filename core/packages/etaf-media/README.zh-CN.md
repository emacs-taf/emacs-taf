# etaf-media

[English](README.md)

[ETAF](https://github.com/emacs-taf/etaf) 原生视频播放引擎与 `etaf-video` 组件。支持本地文件、HTTP(S) 媒体流、音视频分流、硬件 GPU 原生视频层（基于 `libmpv` 的 macOS Metal/CAOpenGL、Windows Win32/WGL、Linux X11/Wayland EGL）、Kitty 终端图形协议、纯 Emacs 图像帧管线与 ASCII / 真彩半块渲染模式。

## 前置条件

- Emacs 29.1 或更高版本
- `etaf`、`ebox`、`ecss`
- 可选：`libmpv`（配合 `native/manifest.json` 预编译模块启用硬件 GPU / libmpv 播放）、`ffmpeg` / `ffprobe` / `ffplay`（用于降级解码、探测与音频伴随进程）

## 安装

通过 `M-x etaf-install` 安装 `etaf-media`，或从 [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf) 源码检出加载：

```elisp
(dolist (pkg '("ecss" "ebox" "etaf" "etaf-media"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(require 'etaf-media)
```

## 最小示例

```elisp
(require 'etaf)
(require 'etaf-media)

(etaf-mount (get-buffer-create "*ETAF Video*")
            (etaf-view
             (etaf-video :src nil :mode 'ascii :columns 40 :rows 12
                         :handle 'demo :autoplay nil)))
```

## 文档

- 公开 API 清单：[etaf-media.el](etaf-media.el) Commentary
- 原生视频手册章节：[ETAF 参考手册](https://etaf.top/zh-cn/native-video/)
- 架构说明：[docs/architecture.md](docs/architecture.md)
- 变更记录：[CHANGELOG.md](CHANGELOG.md)

## 验证

```sh
make -C core/packages/etaf-media check
```
