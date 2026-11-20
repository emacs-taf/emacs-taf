# 许可

框架各包是自由软件：你可以在 GNU 通用公共许可证第 3 版或更新版本的条款下再分发和修改它们。每个包的入口都带有 SPDX 标识 `GPL-3.0-or-later`，随包附带许可证全文的包以 `LICENSE` 或 `COPYING` 提供。手册及其阅读器采用同一许可。

<!-- index: 许可; GPL; 第三方数据 -->

## 各包

| 包 | 许可 | 条款所在 |
| --- | --- | --- |
| `ecss` | `GPL-3.0-or-later` | 入口的 SPDX 头与 `LICENSE` |
| `ekp` | `GPL-3.0-or-later` | 入口的版权声明与 `COPYING` |
| `ebox` | `GPL-3.0-or-later` | 入口的 SPDX 头与 `LICENSE` |
| `etaf` | `GPL-3.0-or-later` | 入口的 SPDX 头 |
| `etaf-ui` | `GPL-3.0-or-later` | 入口的 SPDX 头 |
| `etaf-db` | `GPL-3.0-or-later` | 入口的 SPDX 头 |
| `etaf-manual` | `GPL-3.0-or-later` | 入口的 SPDX 头 |

## 第三方资源

- **EKP 断字字典。** `dictionaries/` 下随包的字典是第三方数据，不单独由 EKP 的 `COPYING` 覆盖。`dictionaries/MANIFEST.tsv` 与 `dictionaries/LICENSES.md` 记录每个文件的来源、许可证据与校验和，并固定到一个 LibreOffice 字典快照；遗留文件 `hyph_eu.dic` 保留自己的随包声明。梵文字典未随包提供，因为固定的上游数据对它没有权威许可声明。
- **字体与图标。** 目录的图标要么取自用户系统安装的字体（`nerd`、`fa`、`material`、`octicons` 与 `sys` 集），要么取自 `etaf-ui` 源码中定义的 SVG 图形。包不附带字体文件，安装的字体保留自己的许可。
- **彩色 emoji。** Ebox 的 macOS 彩色 emoji 辅助程序 `ebox/native/emoji/emoji-render.swift` 用 `swiftc` 在本地编译；它属于 Ebox，按同一许可分发。

## 手册

`book/` 下的各章及其可运行示例属于 `etaf-manual`，按与包相同的 `GPL-3.0-or-later` 条款发布。
