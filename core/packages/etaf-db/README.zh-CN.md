# ETAF DB

[English](README.md)

`etaf-db` 为 ETAF 框架提供数据库后端，目前只实现 SQLite。它将 Emacs 内置
SQLite 能力适配为 `etaf-data-source`；Data Controller 和响应式状态仍由 ETAF
核心管理。

## 安装与使用

需要支持 SQLite 的 Emacs 29.1 或更高版本，以及 ETAF 0.2.1 或更高版本。
使用源码 checkout 时，将本仓库根目录和 ETAF 依赖的根目录加入 `load-path`，
然后使用 `(require 'etaf-db)`。安装归档应同时包含根入口与 `lisp/`。
[`etaf-db.el`](etaf-db.el) 维护支持的公共 API。SQLite 专用构造函数保留
`etaf-sqlite-*` 前缀，因为其 schema 和存储参数描述的是该后端。

```elisp
(require 'etaf-db)

(let* ((table (etaf-sqlite-table
               'items
               (list (etaf-sqlite-column :id "id" :type 'integer :primary t)
                     (etaf-sqlite-column :name "name" :type 'text))
               :id))
       (database (etaf-sqlite-database "~/items.sqlite" table)))
  (etaf-sqlite-initialize database)
  (let ((controller (etaf-data-controller
                     (etaf-sqlite-source database) :auto-load t)))
    (unwind-protect
        (message "%S" (etaf-value (etaf-data-items controller)))
      (etaf-data-stop controller))))
```

SQLite 后端负责 schema 校验、短连接、分页、查询和同步写入。数据源使用既有的
ETAF Data Source 契约，不增加数据库专用 Controller、ORM 或后端分派协议。
非数据库集成可以独立实现同一个数据源契约。

支持的查询、写入、生命周期以及可选的 `:mutate-v2 t` 数据源能力见
ETAF 参考手册的 [SQLite 后端一章](https://etaf.top/zh-cn/sqlite-backend/)。

## 开发

克隆后运行 `make setup-hooks`。`make structure-check` 是快速的结构和 API 边界
门禁。`make check EMACS=/path/to/emacs` 还会编译、验证入口，并运行
[tests/acceptance.json](tests/acceptance.json) 中的公共场景。`make test` 运行
同一套正确性场景。GUI 与性能验收使用消费示例的独立流程。
