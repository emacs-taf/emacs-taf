---
title: ETAF 幻灯片
theme: auto
author: ETAF contributors
---

# 一套内容，多种投影

ETAF 把 markdown 变成放映现场。

---

## 为什么用文本做幻灯片

- 内容在一个文件里，可 diff、可提交
- 字体、主题跟着你的 Emacs
- 放映只是换一个视图，内容不搬家

::: notes
开头先问一句：你们上一次改 PPT 的版本号是什么时候？
:::

---

## 一行命令开始放映

```elisp
(etaf-slides-present "deck.markdown")
```

---

## 排版约定

| 元素 | 规则 |
| --- | --- |
| 标题 | 粗体加颜色，不放大字号 |
| 正文 | 共享 markdown 渲染器 |
| 页脚 | 页码与演示计时 |

---

## 结束

谢谢。
