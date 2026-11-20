# 标准钩子

钩子是框架在确定时刻运行的观察点。这些钩子都是 abnormal hook：值是一列函数；设置了缓冲区局部值时，该值在这个缓冲区里替代全局列表。每行链接到记录参数、时机与错误处理的条目。

<!-- index: 钩子; abnormal hook; 观察点 -->

| 钩子 | 运行时机 | 调用参数 | 错误 |
| --- | --- | --- | --- |
| [`ebox-unmount-functions`](ebox-mount-lifecycle.md#hook-ebox-unmount-functions) | `ebox-unmount-buffer` 释放挂载时，在挂载被摘下、显示设置被恢复之前，所以缓冲区此时仍能回答 `ebox-buffer-mount`。 | 缓冲区 | 出错会从 `ebox-unmount-buffer` 向外抛出、中止释放，挂载保持存活。 |
| [`ebox-focus-change-functions`](focus.md#hook-ebox-focus-change-functions) | `ebox-focus` 移动了挂载的焦点；焦点未变时不运行，且在焦点操作内部运行，因此挂载已经报告新焦点。 | 之前的焦点节点（或 nil）与新的焦点节点（或 nil） | 错误从运行该钩子的焦点操作向外传播。 |
| [`ebox-after-flush-functions`](incremental-updates-and-publication.md#hook-ebox-after-flush-functions) | 一次 flush 真正发布之后，在观察者与后台同步之后；缓冲区已显示新输出，几何已确定。 | 缓冲区 | 一个函数出错不影响其余函数运行。 |
| [`ebox-viewport-change-functions`](viewport.md#hook-ebox-viewport-change-functions) | 视口尺寸变化后——窗口缩放或 `ebox-mount-set-viewport`——新尺寸的重排完成时。 | 缓冲区 | 一个函数出错不阻止其余函数。 |
| [`ebox-display-change-functions`](viewport.md#hook-ebox-display-change-functions) | 缓冲区文本缩放稳定且保留树完成重新测量后，固定尺寸视口也会收到通知。 | 缓冲区 | 回调错误由视口任务报告；中断后未开始的工作留在队列里。 |
| [`ebox-display-window-change-functions`](viewport.md#hook-ebox-display-window-change-functions) | 窗口变化稳定且挂载已 refit，窗口刚成为缓冲区的显示窗口或其正文像素尺寸变了；固定视口也会收到，借走的行不算。 | 缓冲区和它的显示窗口 | 出错会中止该 frame 这一批的剩余工作，由视口任务报告。 |

## 说明

- `ebox-unmount-functions` 是显式释放的钩子。kill 缓冲区时，挂载经缓冲区的 kill 钩子释放，不会运行它。
- 钩子在挂载的缓冲区里运行。只属于某个应用缓冲区的函数用缓冲区局部注册，`(add-hook 'HOOK FUNCTION nil t)`；属于整个进程的用全局列表。
- `:on-focus-enter` 建立在 `ebox-focus-change-functions` 上：ETAF 计算前后两个节点之间的 Host，从最近的开始逐个派发回调。
