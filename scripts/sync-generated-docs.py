#!/usr/bin/env python3
"""Layer-0 deterministic documentation generator and drift checker.

Reads authoritative workspace metadata (`workspace.json`, `release-dependencies.json`,
`<pkg>/<pkg>.el` headers, `core/packages/etaf-manual/book/book.json`,
`.github/workflows/*.yml`, and `scripts/doc-catalog.json`) and synchronizes
fenced `<!-- BEGIN:GENERATED:<id> -->` ... `<!-- END:GENERATED:<id> -->` regions
across:

  - README.md and README.zh-CN.md
  - core/README.md and core/README.zh-CN.md
  - core/packages/etaf-manual/book/{en,zh-CN}/introduction.md
  - core/packages/etaf-manual/book/{en,zh-CN}/versions-and-migration.md
  - apps/*/README*.md and games/*/README*.md (standard install snippets)
"""
from __future__ import annotations

import argparse
import difflib
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import workspace_layout  # noqa: E402

ROOT = SCRIPT_DIR.parent
FENCE_RE = re.compile(
    r"(<!-- BEGIN:GENERATED:([A-Za-z0-9_.:-]+) -->\n)(.*?)(<!-- END:GENERATED:\2 -->)",
    re.S,
)
VERSION_RE = re.compile(r"^;; Version:\s*(\S+)", re.M)
REQUIRES_RE = re.compile(r"^;; Package-Requires:\s*(.+)$", re.M)
REQ_ITEM_RE = re.compile(r'\(([a-z][a-z0-9-]*)\s+"([^"]+)"\)')
SUMMARY_RE = re.compile(r"^;;;\s+[a-z0-9-]+\.el\s+---\s+(.+?)(?:\s+-\*-.*)?$", re.M)
WORKFLOW_NAME_RE = re.compile(r"^name:\s*(.+?)\s*$", re.M)

# Display order for transitive load-path snippets (providers before consumers).
CORE_LOAD_ORDER = (
    "ecss",
    "ekp",
    "ebox",
    "etaf",
    "etaf-media",
    "etaf-ui",
    "etaf-db",
    "etaf-posframe",
    "etaf-ext",
    "etaf-gamekit",
)
EXTERNAL_DISPLAY_NAMES = {
    "emacs": "Emacs",
    "posframe": "Posframe",
    "telega": "Telega",
}


def load_json(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def parse_entry_metadata(entry: Path) -> dict:
    text = entry.read_text(encoding="utf-8", errors="replace")
    ver_m = VERSION_RE.search(text)
    req_m = REQUIRES_RE.search(text)
    sum_m = SUMMARY_RE.search(text)
    reqs = REQ_ITEM_RE.findall(req_m.group(1)) if req_m else []
    return {
        "version": ver_m.group(1) if ver_m else "0.0.0",
        "requirements": reqs,
        "summary": sum_m.group(1).strip() if sum_m else entry.stem,
    }


def collect_workspace_facts(root: Path) -> dict:
    ws = workspace_layout.load_workspace(root)
    rel_sel = load_json(root / "release-dependencies.json")
    catalog = load_json(root / "scripts" / "doc-catalog.json")
    book = load_json(root / "core" / "packages" / "etaf-manual" / "book" / "book.json")
    packages_ws = ws.get("packages") or {}
    pkg_meta: dict[str, dict] = {}
    for name, meta in sorted(packages_ws.items()):
        pkg_dir = root / meta["path"]
        entry = pkg_dir / f"{name}.el"
        parsed = parse_entry_metadata(entry) if entry.is_file() else {
            "version": "0.0.0",
            "requirements": [],
            "summary": name,
        }
        pkg_meta[name] = {
            **meta,
            "name": name,
            "dir": pkg_dir,
            "incubating": workspace_layout.is_incubating(meta),
            **parsed,
        }
    release_pkgs = set((rel_sel.get("packages") or {}).keys()) | {"etaf-install"}
    workflows = []
    wf_dir = root / ".github" / "workflows"
    if wf_dir.is_dir():
        for fname in ("structure.yml", "installation.yml", "affected-tests.yml"):
            wf_path = wf_dir / fname
            if wf_path.is_file():
                text = wf_path.read_text(encoding="utf-8", errors="replace")
                nm = WORKFLOW_NAME_RE.search(text)
                workflows.append((fname, nm.group(1).strip().strip('"\'') if nm else fname))
    return {
        "root": root,
        "ws": ws,
        "packages": pkg_meta,
        "release_packages": release_pkgs,
        "catalog": catalog,
        "book": book,
        "workflows": workflows,
    }


def ordered_names(names: list[str], preferred: list[str]) -> list[str]:
    rank = {n: i for i, n in enumerate(preferred)}
    return sorted(names, key=lambda n: (rank.get(n, len(preferred)), n))


def transitive_monorepo_deps(facts: dict, pkg_name: str) -> list[str]:
    """Return monorepo dependencies of PKG_NAME in load-path order (providers first)."""
    pkgs = facts["packages"]
    visited: set[str] = set()
    order: list[str] = []

    def visit(name: str) -> None:
        info = pkgs.get(name)
        if not info:
            return
        for dep, _ver in info["requirements"]:
            if dep in pkgs and dep != pkg_name and dep not in visited:
                visited.add(dep)
                visit(dep)
                order.append(dep)

    visit(pkg_name)
    core_rank = {n: i for i, n in enumerate(CORE_LOAD_ORDER)}
    return sorted(order, key=lambda n: (0 if n in core_rank else 1, core_rank.get(n, 999), n))


def direct_monorepo_deps(facts: dict, pkg_name: str) -> list[str]:
    pkgs = facts["packages"]
    info = pkgs[pkg_name]
    return [dep for dep, _ver in info["requirements"] if dep in pkgs]


def format_deps(facts: dict, pkg_name: str, lang: str) -> str:
    cat = (facts["catalog"].get("packages") or {}).get(pkg_name, {})
    override = cat.get(f"deps_{lang}")
    if override:
        return override
    deps = direct_monorepo_deps(facts, pkg_name)
    if not deps:
        return "None" if lang == "en" else "无"
    sep = ", " if lang == "en" else "、"
    return sep.join(deps)


def describe(facts: dict, pkg_name: str, lang: str, *, core: bool = False) -> str:
    cat = (facts["catalog"].get("packages") or {}).get(pkg_name, {})
    if core and cat.get(f"core_{lang}"):
        return cat[f"core_{lang}"]
    if cat.get(lang):
        return cat[lang]
    return facts["packages"][pkg_name]["summary"]


def render_badges(facts: dict) -> str:
    lines = []
    for fname, label in facts["workflows"]:
        url = f"https://github.com/emacs-taf/emacs-taf/actions/workflows/{fname}"
        lines.append(f"[![{label}]({url}/badge.svg)]({url})")
    return "\n".join(lines)


def _layer_buckets(facts: dict) -> dict[str, list[str]]:
    pkgs = facts["packages"]
    cat = facts["catalog"]
    core_fw = [n for n, m in pkgs.items() if m["path"].startswith("core/packages/") and m.get("role") == "framework"]
    core_ext = [n for n, m in pkgs.items() if m["path"].startswith("core/packages/") and m.get("role") == "extension"]
    apps = [n for n, m in pkgs.items() if m["path"].startswith("apps/")]
    games = [n for n, m in pkgs.items() if m["path"].startswith("games/")]
    return {
        "core_fw": ordered_names(core_fw, cat.get("core_order", [])),
        "core_ext": ordered_names(core_ext, cat.get("extension_order", [])),
        "apps": ordered_names(apps, cat.get("app_order", [])),
        "games": ordered_names(games, cat.get("game_order", [])),
    }


def render_root_overview(facts: dict, lang: str) -> str:
    b = _layer_buckets(facts)
    pkgs = facts["packages"]
    core_all = b["core_fw"] + b["core_ext"]
    core_active = [n for n in core_all if not pkgs[n]["incubating"]]
    core_inc = [n for n in core_all if pkgs[n]["incubating"]]
    apps_active = [n for n in b["apps"] if not pkgs[n]["incubating"]]
    apps_inc = [n for n in b["apps"] if pkgs[n]["incubating"]]
    games_active = [n for n in b["games"] if not pkgs[n]["incubating"]]
    games_inc = [n for n in b["games"] if pkgs[n]["incubating"]]
    total = len(pkgs)

    if lang == "en":
        core_part = (
            f"{len(core_active)} core framework, extension, installer and reference-manual packages"
            + (f" plus {len(core_inc)} incubating" if core_inc else "")
        )
        apps_part = f"{len(apps_active)} applications" + (f" plus {len(apps_inc)} incubating" if apps_inc else "")
        games_part = f"{len(games_active)} games" + (f" plus {len(games_inc)} incubating" if games_inc else "")
        return (
            "This repository (`https://github.com/emacs-taf/emacs-taf`) is the **official Emacs TAF monorepo** "
            f"and canonical home for development, pull requests and CI across all {total} packages in the ecosystem. "
            f"Packages are organized into three layers: `core/packages/` ({core_part}, projected together to "
            "[emacs-taf/etaf](https://github.com/emacs-taf/etaf)), "
            f"`apps/` ({apps_part}) and `games/` ({games_part}), where published products project individually to "
            "`https://github.com/emacs-taf/<package>`."
        )
    core_part = f"{len(core_active)} 个核心框架、通用扩展、安装器与参考手册包" + (f"及 {len(core_inc)} 个孵化包" if core_inc else "")
    apps_part = f"{len(apps_active)} 个应用" + (f"及 {len(apps_inc)} 个孵化应用" if apps_inc else "")
    games_part = f"{len(games_active)} 款游戏" + (f"及 {len(games_inc)} 款孵化游戏" if games_inc else "")
    return (
        "本仓库（`https://github.com/emacs-taf/emacs-taf`）是 **Emacs TAF 官方 Monorepo**，"
        f"也是整个生态全部 {total} 个包统一的源码、Pull Request 与 CI 入口。"
        f"各包按产品边界分为三层：`core/packages/`（{core_part}，整目录自动投影到 "
        "[emacs-taf/etaf](https://github.com/emacs-taf/etaf)）、"
        f"`apps/`（{apps_part}）与 `games/`（{games_part}），"
        "已对外发布的应用与游戏各自自动投影到 `https://github.com/emacs-taf/<包名>`。"
    )


def _pkg_link(meta: dict) -> str:
    if meta.get("repo") and not meta["incubating"]:
        return f"[{meta['name']}](https://github.com/{meta['repo']})"
    return f"[{meta['name']}]({meta['path']})"


def render_root_packages(facts: dict, lang: str) -> str:
    b = _layer_buckets(facts)
    pkgs = facts["packages"]
    rel = facts["release_packages"]
    cat = facts["catalog"].get("packages") or {}

    unarchived_apps = sorted(n for n in b["apps"] if n not in rel)
    unarchived_games = sorted(n for n in b["games"] if n not in rel)
    incubating = sorted(n for n, m in pkgs.items() if m["incubating"])

    lines: list[str] = []
    if lang == "en":
        lines += [
            "### Core Framework (`core/packages/` → [emacs-taf/etaf](https://github.com/emacs-taf/etaf))",
            "",
            "| Package | Responsibility | Monorepo dependencies |",
            "| --- | --- | --- |",
        ]
        for n in b["core_fw"]:
            lines.append(f"| [{n}]({pkgs[n]['path']}) | {describe(facts, n, 'en')} | {format_deps(facts, n, 'en')} |")
        lines += [
            "",
            "### Extensions (`core/packages/` → [emacs-taf/etaf](https://github.com/emacs-taf/etaf))",
            "",
            "Built on [etaf-ext](core/packages/etaf-ext) to attach cross-cutting capabilities to any ETAF buffer or application:",
            "",
            "| Extension | Responsibility | Framework dependencies |",
            "| --- | --- | --- |",
        ]
        for n in b["core_ext"]:
            lines.append(f"| [{n}]({pkgs[n]['path']}) | {describe(facts, n, 'en')} | {format_deps(facts, n, 'en')} |")
        lines += [
            "",
            "### Applications (`apps/`)",
            "",
            "| Application | Responsibility | Framework dependencies |",
            "| --- | --- | --- |",
        ]
        for n in b["apps"]:
            lines.append(f"| {_pkg_link(pkgs[n])} | {describe(facts, n, 'en')} | {format_deps(facts, n, 'en')} |")
        if unarchived_apps:
            listed = ", ".join(f"`{n}`" for n in unarchived_apps[:-1]) + f" and `{unarchived_apps[-1]}`" if len(unarchived_apps) > 1 else f"`{unarchived_apps[0]}`"
            lines += [
                "",
                f"> **Archive status:** {listed} live in this monorepo and are not published to the ELPA archive yet (`M-x etaf-install` does not list them).",
            ]
        lines += [
            "",
            "### Games (`games/`)",
            "",
            "Games build on [etaf-gamekit](core/packages/etaf-gamekit) or pure ETAF UI and keep their rules, presentation and assets in their own package directories:",
            "",
            "| Game | Description | Backend |",
            "| --- | --- | --- |",
        ]
        for n in b["games"]:
            backend = (cat.get(n) or {}).get("backend", "ETAF")
            lines.append(f"| {_pkg_link(pkgs[n])} | {describe(facts, n, 'en')} | {backend} |")
        if unarchived_games or incubating:
            notes = []
            if unarchived_games:
                notes.append("Not yet in the ELPA archive: " + ", ".join(f"`{n}`" for n in unarchived_games))
            if incubating:
                notes.append("Incubating (monorepo-only, excluded from standalone projections and releases): " + ", ".join(f"`{n}`" for n in incubating))
            lines += ["", "> " + ". ".join(notes) + "."]
        return "\n".join(lines)

    lines += [
        "### 框架核心（`core/packages/` → [emacs-taf/etaf](https://github.com/emacs-taf/etaf)）",
        "",
        "| 包名 | 职责 | 本 Monorepo 依赖 |",
        "| --- | --- | --- |",
    ]
    for n in b["core_fw"]:
        lines.append(f"| [{n}]({pkgs[n]['path']}) | {describe(facts, n, 'zh')} | {format_deps(facts, n, 'zh')} |")
    lines += [
        "",
        "### 通用扩展（`core/packages/` → [emacs-taf/etaf](https://github.com/emacs-taf/etaf)）",
        "",
        "构建在 [etaf-ext](core/packages/etaf-ext) 之上，为任意 ETAF 视图与应用提供通用增强能力：",
        "",
        "| 扩展 | 职责 | 框架依赖 |",
        "| --- | --- | --- |",
    ]
    for n in b["core_ext"]:
        lines.append(f"| [{n}]({pkgs[n]['path']}) | {describe(facts, n, 'zh')} | {format_deps(facts, n, 'zh')} |")
    lines += [
        "",
        "### 应用（`apps/`）",
        "",
        "| 应用 | 职责 | 框架依赖 |",
        "| --- | --- | --- |",
    ]
    for n in b["apps"]:
        lines.append(f"| {_pkg_link(pkgs[n])} | {describe(facts, n, 'zh')} | {format_deps(facts, n, 'zh')} |")
    if unarchived_apps:
        listed = "、".join(f"`{n}`" for n in unarchived_apps)
        lines += [
            "",
            f"> **归档状态**：{listed} 位于本 Monorepo 中，尚未进入官方 ELPA 归档（`M-x etaf-install` 暂不列出）。",
        ]
    lines += [
        "",
        "### 游戏（`games/`）",
        "",
        "游戏基于 [etaf-gamekit](core/packages/etaf-gamekit) 或纯 ETAF UI 构建，规则、呈现与素材保存在各自包目录：",
        "",
        "| 游戏 | 说明 | 后端 |",
        "| --- | --- | --- |",
    ]
    for n in b["games"]:
        backend = (cat.get(n) or {}).get("backend", "ETAF")
        lines.append(f"| {_pkg_link(pkgs[n])} | {describe(facts, n, 'zh')} | {backend} |")
    if unarchived_games or incubating:
        notes = []
        if unarchived_games:
            notes.append("暂未进入 ELPA 归档：" + "、".join(f"`{n}`" for n in unarchived_games))
        if incubating:
            notes.append("孵化中（仅保留在 Monorepo，不对外投影与发版）：" + "、".join(f"`{n}`" for n in incubating))
        lines += ["", "> " + "；".join(notes) + "。"]
    return "\n".join(lines)


def render_root_layout(facts: dict, lang: str) -> str:
    b = _layer_buckets(facts)
    core_n = len(b["core_fw"]) + len(b["core_ext"])
    apps_n = len(b["apps"])
    games_n = len(b["games"])
    if lang == "en":
        return "\n".join([
            "```text",
            "emacs-taf/",
            f"├── core/                     # Core projection (→ emacs-taf/etaf): README + packages/<{core_n} core/ext/manual pkgs>",
            f"├── apps/                     # {apps_n} end-user applications (published apps project individually → emacs-taf/<app>)",
            f"├── games/                    # {games_n} games (published games project individually → emacs-taf/<game>)",
            "├── scripts/                  # Shared build, structure/API/doc checks, refscope, release and media publishing tools",
            "├── docs/                     # Monorepo tool manual, ecosystem architecture and keyboard navigation contracts",
            "├── tests/tools/              # Unit and regression tests for shared monorepo tooling and installer flows",
            "├── workspace.json            # Package registry, paths, roles, status and projection targets (schema 3)",
            "├── release-dependencies.json # Official ELPA archive package selection and runtime resources",
            "├── doc-coupling.json         # Architectural code-to-doc impact coupling rules",
            "└── Makefile                  # Dependency-ordered monorepo orchestration targets",
            "```",
        ])
    return "\n".join([
        "```text",
        "emacs-taf/",
        f"├── core/                     # 核心投影目录（→ emacs-taf/etaf）：README + packages/<{core_n} 个框架/扩展/手册包>",
        f"├── apps/                     # {apps_n} 个终端应用（已发布应用各自投影 → emacs-taf/<app>）",
        f"├── games/                    # {games_n} 款游戏（已发布游戏各自投影 → emacs-taf/<game>）",
        "├── scripts/                  # 共用构建、结构/API/文档门禁、影响面分析（refscope）、发布与媒体托管脚本",
        "├── docs/                     # Monorepo 工具手册、生态架构规范与键盘导航契约",
        "├── tests/tools/              # 共享工具与安装器回归测试",
        "├── workspace.json            # Monorepo 包注册表、路径、角色、状态与投影声明（schema 3）",
        "├── release-dependencies.json # 官方 ELPA 归档选包与随包运行资源清单",
        "├── doc-coupling.json         # 核心架构代码与文档的联动耦合清单",
        "└── Makefile                  # 按依赖拓扑编排的统一验证入口",
        "```",
    ])


def render_core_overview(facts: dict, lang: str) -> str:
    b = _layer_buckets(facts)
    pkgs = facts["packages"]
    core_all = b["core_fw"] + b["core_ext"]
    active = [n for n in core_all if not pkgs[n]["incubating"]]
    inc = [n for n in core_all if pkgs[n]["incubating"]]
    if lang == "en":
        extra = f" (plus {len(inc)} incubating package(s) in `packages/`)" if inc else ""
        return (
            f"> **Read-only core projection.** This repository aggregates all {len(active)} published ETAF core framework "
            f"packages, universal extensions, the official installer and the bilingual reference manual{extra} from "
            "[`core/`](https://github.com/emacs-taf/emacs-taf/tree/main/core) in the "
            "**[Emacs TAF Monorepo](https://github.com/emacs-taf/emacs-taf)**.\n>\n"
            "> Please submit all pull requests to **[emacs-taf/emacs-taf](https://github.com/emacs-taf/emacs-taf/pulls)**."
        )
    extra = f"（另含 {len(inc)} 个孵化包）" if inc else ""
    return (
        "> **只读核心聚合投影仓。** 本仓库由 **[Emacs TAF Monorepo](https://github.com/emacs-taf/emacs-taf)** 的 "
        f"[`core/`](https://github.com/emacs-taf/emacs-taf/tree/main/core) 目录自动同步生成，"
        f"汇集全部 {len(active)} 个已发布的核心框架包、通用扩展、官方安装器与中英双语参考手册{extra}。\n>\n"
        "> 提交代码与 Pull Request 请统一前往 **[emacs-taf/emacs-taf](https://github.com/emacs-taf/emacs-taf/pulls)**。"
    )


def render_core_packages(facts: dict, lang: str) -> str:
    b = _layer_buckets(facts)
    pkgs = facts["packages"]
    fw_only = [n for n in b["core_fw"] if n != "etaf-manual" and not pkgs[n]["incubating"]]
    ext_only = [n for n in b["core_ext"] if not pkgs[n]["incubating"]]
    manual_only = [n for n in b["core_fw"] if n == "etaf-manual"]
    inc_core = [n for n in b["core_fw"] + b["core_ext"] if pkgs[n]["incubating"]]

    lines: list[str] = []
    if lang == "en":
        lines += [
            "### Core Framework",
            "",
            "| Package | Role |",
            "| --- | --- |",
        ]
        for n in fw_only:
            lines.append(f"| [`{n}`](packages/{n}) | {describe(facts, n, 'en', core=True)} |")
        lines += [
            "",
            "### Universal Extensions",
            "",
            "| Extension | Description |",
            "| --- | --- |",
        ]
        for n in ext_only:
            lines.append(f"| [`{n}`](packages/{n}) | {describe(facts, n, 'en', core=True)} |")
        lines += [
            "",
            "### Documentation & Reference Manual",
            "",
            "| Package | Description |",
            "| --- | --- |",
        ]
        for n in manual_only:
            lines.append(f"| [`{n}`](packages/{n}) | {describe(facts, n, 'en', core=True)} |")
        if inc_core:
            lines += [
                "",
                "### Incubating",
                "",
                "| Package | Description |",
                "| --- | --- |",
            ]
            for n in inc_core:
                lines.append(f"| [`{n}`](packages/{n}) | {describe(facts, n, 'en', core=True)} |")
        return "\n".join(lines)

    lines += [
        "### 核心框架",
        "",
        "| 包名 | 职责 |",
        "| --- | --- |",
    ]
    for n in fw_only:
        lines.append(f"| [`{n}`](packages/{n}) | {describe(facts, n, 'zh', core=True)} |")
    lines += [
        "",
        "### 通用扩展",
        "",
        "| 扩展名 | 说明 |",
        "| --- | --- |",
    ]
    for n in ext_only:
        lines.append(f"| [`{n}`](packages/{n}) | {describe(facts, n, 'zh', core=True)} |")
    lines += [
        "",
        "### 文档与参考手册",
        "",
        "| 包名 | 说明 |",
        "| --- | --- |",
    ]
    for n in manual_only:
        lines.append(f"| [`{n}`](packages/{n}) | {describe(facts, n, 'zh', core=True)} |")
    if inc_core:
        lines += [
            "",
            "### 孵化包",
            "",
            "| 包名 | 说明 |",
            "| --- | --- |",
        ]
        for n in inc_core:
            lines.append(f"| [`{n}`](packages/{n}) | {describe(facts, n, 'zh', core=True)} |")
    return "\n".join(lines)


def render_manual_versions_intro(facts: dict, lang: str) -> str:
    book_pkgs = facts["book"].get("packages") or []
    pkgs = facts["packages"]
    items = [f"`{p} {pkgs[p]['version']}`" for p in book_pkgs if p in pkgs]
    if lang == "en":
        listed = ", ".join(items[:-1]) + f" and {items[-1]}" if len(items) > 1 else "".join(items)
        return (
            f"This edition describes {listed}. "
            "The manual is maintained together with the code: a build check fails when a public interface "
            "of a package the manual covers has no entry, when a signature differs from the code, when the "
            "text names a symbol that is not public, or when a version above differs from the package."
        )
    listed = "、".join(items[:-1]) + f" 和 {items[-1]}" if len(items) > 1 else "".join(items)
    return (
        f"本版描述 {listed}。"
        "本书与代码一同维护：本书已覆盖的包有公共接口缺少条目、签名与代码不符、正文点名了非公共符号，"
        "或上面的版本与包不符时，构建检查都会失败。"
    )


def render_manual_version_table(facts: dict, lang: str) -> str:
    book_pkgs = list(facts["book"].get("packages") or []) + list(facts["book"].get("references") or [])
    pkgs = facts["packages"]
    sep = ", " if lang == "en" else "、"
    header = "| Package | Version | Documented with |" if lang == "en" else "| 包 | 版本 | 配套版本 |"
    lines = [header, "| --- | --- | --- |"]
    for name in book_pkgs:
        if name not in pkgs:
            continue
        info = pkgs[name]
        req_parts = []
        for dep, min_ver in info["requirements"]:
            if dep in EXTERNAL_DISPLAY_NAMES:
                req_parts.append(f"{EXTERNAL_DISPLAY_NAMES[dep]} {min_ver}")
            elif dep in pkgs:
                req_parts.append(f"`{dep} {pkgs[dep]['version']}`")
            else:
                req_parts.append(f"`{dep} {min_ver}`")
        lines.append(f"| `{name}` | {info['version']} | {sep.join(req_parts)} |")
    return "\n".join(lines)


def render_pkg_install(facts: dict, pkg_name: str, lang: str) -> str:
    pkgs = facts["packages"]
    info = pkgs[pkg_name]
    in_archive = pkg_name in facts["release_packages"]
    deps = transitive_monorepo_deps(facts, pkg_name)
    core_deps = [d for d in deps if pkgs[d]["path"].startswith("core/packages/")]
    other_deps = [d for d in deps if not pkgs[d]["path"].startswith("core/packages/")]
    core_list = " ".join(f'"{d}"' for d in core_deps)

    lines: list[str] = []
    if lang == "en":
        if in_archive:
            lines += [
                "### From the ETAF package archive (recommended)",
                "",
                "```elisp",
                "(require 'package)",
                '(add-to-list \'package-archives \'("etaf" . "https://etaf.top/packages/"))',
                "(package-initialize)",
                "(package-refresh-contents)",
                "(package-install 'etaf-install)",
                f"(etaf-install-ensure '({pkg_name}))",
                "```",
                "",
                f"Or run `M-x etaf-install` and select `{pkg_name}` interactively.",
                "",
                "### From a source checkout",
                "",
                "All core framework packages live in [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf):",
                "",
                "```sh",
                "git clone https://github.com/emacs-taf/etaf.git",
            ]
            if info.get("repo"):
                lines.append(f"git clone https://github.com/{info['repo']}.git")
            lines += ["```", "", "```elisp"]
        else:
            status_note = (
                "currently incubating in the monorepo"
                if info["incubating"]
                else "maintained in the monorepo (not yet published to the ELPA archive)"
            )
            lines += [
                f"> `{pkg_name}` is {status_note}. Install from a source checkout of [`emacs-taf/emacs-taf`](https://github.com/emacs-taf/emacs-taf) (or [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf) + this package):",
                "",
                "```elisp",
            ]
        if core_deps:
            lines += [
                f"(dolist (pkg '({core_list}))",
                '  (add-to-list \'load-path (expand-file-name pkg "/path/to/etaf/packages")))',
            ]
        for dep in other_deps:
            lines.append(f'(add-to-list \'load-path "/path/to/{dep}")')
        lines += [
            f'(add-to-list \'load-path "/path/to/{pkg_name}")',
            f"(require '{pkg_name})",
            "```",
        ]
        return "\n".join(lines)

    # Chinese
    if in_archive:
        lines += [
            "### 通过 ETAF 包归档安装（推荐）",
            "",
            "```elisp",
            "(require 'package)",
            '(add-to-list \'package-archives \'("etaf" . "https://etaf.top/packages/"))',
            "(package-initialize)",
            "(package-refresh-contents)",
            "(package-install 'etaf-install)",
            f"(etaf-install-ensure '({pkg_name}))",
            "```",
            "",
            f"或运行 `M-x etaf-install` 并在菜单中选择 `{pkg_name}`。",
            "",
            "### 从源码检出安装",
            "",
            "全部核心框架包位于 [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf)：",
            "",
            "```sh",
            "git clone https://github.com/emacs-taf/etaf.git",
        ]
        if info.get("repo"):
            lines.append(f"git clone https://github.com/{info['repo']}.git")
        lines += ["```", "", "```elisp"]
    else:
        status_note = (
            "当前为 Monorepo 孵化包"
            if info["incubating"]
            else "当前位于 Monorepo（尚未进入官方 ELPA 归档）"
        )
        lines += [
            f"> `{pkg_name}` {status_note}，请从 [`emacs-taf/emacs-taf`](https://github.com/emacs-taf/emacs-taf) 源码检出加载：",
            "",
            "```elisp",
        ]
    if core_deps:
        lines += [
            f"(dolist (pkg '({core_list}))",
            '  (add-to-list \'load-path (expand-file-name pkg "/path/to/etaf/packages")))',
        ]
    for dep in other_deps:
        lines.append(f'(add-to-list \'load-path "/path/to/{dep}")')
    lines += [
        f'(add-to-list \'load-path "/path/to/{pkg_name}")',
        f"(require '{pkg_name})",
        "```",
    ]
    return "\n".join(lines)


def render_block(facts: dict, block_id: str) -> str:
    if block_id in ("root-badges-en", "root-badges-zh"):
        return render_badges(facts)
    if block_id == "root-overview-en":
        return render_root_overview(facts, "en")
    if block_id == "root-overview-zh":
        return render_root_overview(facts, "zh")
    if block_id == "root-packages-en":
        return render_root_packages(facts, "en")
    if block_id == "root-packages-zh":
        return render_root_packages(facts, "zh")
    if block_id == "root-layout-en":
        return render_root_layout(facts, "en")
    if block_id == "root-layout-zh":
        return render_root_layout(facts, "zh")
    if block_id == "core-overview-en":
        return render_core_overview(facts, "en")
    if block_id == "core-overview-zh":
        return render_core_overview(facts, "zh")
    if block_id == "core-packages-en":
        return render_core_packages(facts, "en")
    if block_id == "core-packages-zh":
        return render_core_packages(facts, "zh")
    if block_id == "manual-versions-en":
        return render_manual_versions_intro(facts, "en")
    if block_id == "manual-versions-zh":
        return render_manual_versions_intro(facts, "zh")
    if block_id == "manual-version-table-en":
        return render_manual_version_table(facts, "en")
    if block_id == "manual-version-table-zh":
        return render_manual_version_table(facts, "zh")
    if block_id.startswith("pkg-install-en:"):
        pkg = block_id.split(":", 1)[1]
        return render_pkg_install(facts, pkg, "en")
    if block_id.startswith("pkg-install-zh:"):
        pkg = block_id.split(":", 1)[1]
        return render_pkg_install(facts, pkg, "zh")
    raise KeyError(f"Unknown generated block id: {block_id}")


def target_files(root: Path, facts: dict) -> list[Path]:
    files = [
        root / "README.md",
        root / "README.zh-CN.md",
        root / "core" / "README.md",
        root / "core" / "README.zh-CN.md",
        root / "core" / "packages" / "etaf-manual" / "book" / "en" / "introduction.md",
        root / "core" / "packages" / "etaf-manual" / "book" / "zh-CN" / "introduction.md",
        root / "core" / "packages" / "etaf-manual" / "book" / "en" / "versions-and-migration.md",
        root / "core" / "packages" / "etaf-manual" / "book" / "zh-CN" / "versions-and-migration.md",
    ]
    for name, meta in sorted(facts["packages"].items()):
        if meta["path"].startswith(("apps/", "games/")):
            for fname in ("README.md", "README.zh-CN.md"):
                candidate = root / meta["path"] / fname
                if candidate.is_file():
                    files.append(candidate)
    return [f for f in files if f.is_file()]


def required_blocks(root: Path, facts: dict) -> dict[Path, list[str]]:
    req: dict[Path, list[str]] = {
        root / "README.md": ["root-badges-en", "root-overview-en", "root-packages-en", "root-layout-en"],
        root / "README.zh-CN.md": ["root-badges-zh", "root-overview-zh", "root-packages-zh", "root-layout-zh"],
        root / "core" / "README.md": ["core-overview-en", "core-packages-en"],
        root / "core" / "README.zh-CN.md": ["core-overview-zh", "core-packages-zh"],
        root / "core" / "packages" / "etaf-manual" / "book" / "en" / "introduction.md": ["manual-versions-en"],
        root / "core" / "packages" / "etaf-manual" / "book" / "zh-CN" / "introduction.md": ["manual-versions-zh"],
        root / "core" / "packages" / "etaf-manual" / "book" / "en" / "versions-and-migration.md": ["manual-version-table-en"],
        root / "core" / "packages" / "etaf-manual" / "book" / "zh-CN" / "versions-and-migration.md": ["manual-version-table-zh"],
    }
    return {p: ids for p, ids in req.items() if p.is_file()}


def sync(root: Path, *, write: bool = False) -> tuple[list[str], list[str]]:
    """Return (changed_relpaths, error_messages)."""
    root = Path(root).resolve()
    facts = collect_workspace_facts(root)
    changed: list[str] = []
    errors: list[str] = []
    req_map = required_blocks(root, facts)

    for path in target_files(root, facts):
        rel = path.relative_to(root).as_posix()
        original = path.read_text(encoding="utf-8")
        found_ids: list[str] = []

        def repl(match: re.Match) -> str:
            prefix, block_id, _old, suffix = match.groups()
            found_ids.append(block_id)
            try:
                body = render_block(facts, block_id)
            except KeyError as exc:
                errors.append(f"{rel}: {exc}")
                return match.group(0)
            return f"{prefix}{body}\n{suffix}"

        updated = FENCE_RE.sub(repl, original)

        for expected_id in req_map.get(path, ()):
            if expected_id not in found_ids:
                errors.append(f"{rel}: missing required generated fence {expected_id}")

        # Every app/game README must carry a pkg-install fence for its package.
        parts = path.relative_to(root).parts
        if len(parts) == 3 and parts[0] in ("apps", "games") and parts[2] in ("README.md", "README.zh-CN.md"):
            pkg_name = parts[1]
            if not any(bid in (f"pkg-install-en:{pkg_name}", f"pkg-install-zh:{pkg_name}") for bid in found_ids):
                errors.append(f"{rel}: missing generated fence pkg-install-en:{pkg_name} or pkg-install-zh:{pkg_name}")

        if updated != original:
            changed.append(rel)
            if write:
                path.write_text(updated, encoding="utf-8")
            else:
                diff = "".join(difflib.unified_diff(
                    original.splitlines(keepends=True),
                    updated.splitlines(keepends=True),
                    fromfile=f"a/{rel}",
                    tofile=f"b/{rel}",
                    n=2,
                ))
                errors.append(f"{rel}: generated section is out of sync (run `make sync-docs`)\n{diff.rstrip()}")

    return changed, errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true", help="rewrite generated doc fences in place")
    mode.add_argument("--check", action="store_true", help="fail if any generated doc fence is stale or missing")
    args = parser.parse_args(argv)

    write = bool(args.write)
    changed, errors = sync(args.root, write=write)
    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        return 1
    if write:
        if changed:
            print(f"Updated {len(changed)} generated doc file(s): " + ", ".join(changed))
        else:
            print("Generated documentation is already up to date.")
    else:
        print("Generated documentation OK.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
