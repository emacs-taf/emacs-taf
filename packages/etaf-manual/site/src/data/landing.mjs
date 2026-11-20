// Content of the landing page in both languages.  src/components/Landing.astro
// renders it; src/pages/index.astro and src/pages/zh-cn/index.astro choose
// the language.  Screenshots live in public/shots/ and share one capture
// frame (3100x1980), so the page can give every tile the same ratio.

const github = 'https://github.com/emacs-taf';
const repo = (name) => `${github}/${name}`;

const features = {
  en: [
    ['Declarative components',
     'Compose reusable Components with named bindings and reactive state; the runtime owns re-rendering, identity and lifecycle.'],
    ['Cascade and computed styles',
     'Style subjects through selectors, specificity and cascade, and read the computed result back instead of setting faces by hand.'],
    ['Box, Flex and Grid layout',
     'Lay text out with the box model, normal flow, flex and grid, measured down to the pixel.'],
    ['Incremental updates',
     'Retained rendering publishes only what changed, so an update costs what it changed instead of a full redraw.'],
  ],
  zh: [
    ['声明式组件',
     '用命名绑定与响应式状态组合可复用组件，重渲染、身份和生命周期由运行时负责。'],
    ['级联与计算样式',
     '用选择器、优先级和级联给主体写样式，再读回计算样式，而不是手工设置 face。'],
    ['Box、Flex 与 Grid 布局',
     '用盒模型、常规流、Flex 与 Grid 排布文本，精确到像素。'],
    ['增量更新',
     '保留式渲染只发布变化的部分，更新的代价取决于改动的大小，而不是整屏重绘。'],
  ],
};

// [name, English caption, English alt, Chinese caption, Chinese alt]; every
// application capture is 1600x1022.
const apps = [
  ['etaf-video-player', 'video as sharp image frames with sound', 'Video player in Emacs',
   '清晰图像帧加声音播放视频', 'Emacs 里的视频播放器'],
  ['etaf-ncm', 'liked songs, lyrics and the queue', 'NetEase Cloud Music player in Emacs',
   '我喜欢的音乐、歌词与播放队列', 'Emacs 里的网易云音乐播放器'],
  ['etaf-weread', "the shelf and a book's progress, contents and notes", 'WeChat Reading client in Emacs',
   '书架，以及选中书的进度、目录与笔记', 'Emacs 里的微信读书客户端'],
  ['etaf-md-preview', 'the source beside the rendered view', 'Markdown reading view beside its source in Emacs',
   '左边原文，右边渲染', 'Emacs 里并排显示 Markdown 原文与渲染'],
  ['etaf-telega', "chats beside a channel's live messages", 'Telegram client in Emacs',
   '会话列表与频道的实时消息', 'Emacs 里的 Telegram 客户端'],
  ['etaf-desktop', 'windows, workspaces and a launcher', 'ETAF Desktop window manager',
   '窗口、工作区与启动器', 'ETAF Desktop 窗口管理器'],
  ['etaf-ascii-video', 'video rendered as characters', 'ASCII video in Emacs',
   '把视频渲染成字符', 'Emacs 里的字符视频'],
];

// [name, width, height, ...as above]: games keep their own proportions.
const games = [
  ['etaf-solitaire', 1600, 1404, 'Verdant, K+ Klondike solitaire', 'Verdant solitaire in Emacs',
   'Verdant，K+ Klondike 纸牌接龙', 'Emacs 里的纸牌接龙'],
  ['etaf-xiangqi', 1479, 1600, 'Chinese chess on a native vector board', 'Chu He xiangqi',
   '矢量棋盘上的中国象棋', '楚河中国象棋'],
  ['etaf-tanks', 1600, 1220, 'Iron Tide, real-time tank battle', 'Iron Tide tank battle',
   'Iron Tide 实时坦克战', '钢铁洪流坦克战'],
  ['etaf-salvage', 1600, 913, 'Salvage Station, real-time exploration', 'Salvage Station game',
   'Salvage Station 实时探索与回收', 'Salvage Station 游戏'],
];

const shots = (list, zh) => list.map((row) => {
  const [name, width, height, en, enAlt, zhCaption, zhAlt] =
    typeof row[1] === 'number' ? row : [row[0], 1600, 1022, ...row.slice(1)];
  return {
  name,
  width,
  height,
  href: repo(name),
  image: `/shots/${name}.webp`,
  caption: zh ? zhCaption : en,
  alt: zh ? zhAlt : enAlt,
  };
});

const guide = {
  en: [
    ['Introduction', 'introduction'],
    ['Style Properties', 'style-properties'],
    ['UI Overview', 'ui-overview'],
    ['Glossary', 'glossary'],
    ['Symbol Index', 'symbol-index'],
  ],
  zh: [
    ['引言', 'introduction'],
    ['样式属性参考', 'style-properties'],
    ['UI 总论', 'ui-overview'],
    ['术语表', 'glossary'],
    ['符号索引', 'symbol-index'],
  ],
};

const text = {
  en: {
    lang: 'en',
    base: '/',
    title: 'ETAF',
    fullName: 'Emacs Text Application Framework',
    gloss: '',
    description: 'ETAF, the Emacs Text Application Framework, builds complete text applications in Emacs with a web-style model.',
    headline: 'Build complete text applications in Emacs',
    tagline: 'with a web-style model: declarative components, cascade styling and incremental updates.',
    install: { label: 'Install ETAF', href: '/introduction/#installation' },
    nav: { manual: 'Manual', apps: 'Applications', games: 'Games' },
    built: 'Built with ETAF',
    applications: 'Applications',
    gamesTitle: 'Games',
    manualTitle: 'ETAF Reference Manual',
    manualLead: 'This manual documents every public interface of ecss, ekp, ebox, etaf, etaf-ui and etaf-db, with the mechanisms behind them. Read the Introduction first, or jump to a reference.',
    other: { label: '简体中文', href: '/zh-cn/' },
    contact: {
      telegram: { label: 'Telegram group', href: 'https://t.me/+4X48uOJC0KBkOWY1' },
      archive: { label: 'Package archive', href: '/packages/' },
    },
    theme: 'Switch color theme',
    close: 'Close',
  },
  zh: {
    lang: 'zh-CN',
    base: '/zh-cn/',
    title: 'ETAF',
    fullName: 'Emacs Text Application Framework',
    gloss: 'Emacs 文本应用框架',
    description: 'ETAF（Emacs Text Application Framework，Emacs 文本应用框架）用 Web 的方式在 Emacs 里构建完整的文本应用。',
    headline: '在 Emacs 里构建完整的文本应用',
    tagline: '声明式组件、级联样式与增量更新。',
    install: { label: '安装 ETAF', href: '/zh-cn/introduction/#安装' },
    nav: { manual: '手册', apps: '应用', games: '游戏' },
    built: '用 ETAF 构建的应用',
    applications: '应用',
    gamesTitle: '游戏',
    manualTitle: 'ETAF 参考手册',
    manualLead: '这里收录 ecss、ekp、ebox、etaf、etaf-ui 与 etaf-db 的全部公共接口，以及它们背后的机制。先读引言，也可以直接跳到参考章节。',
    other: { label: 'English', href: '/' },
    contact: {
      telegram: { label: 'Telegram 群组', href: 'https://t.me/+4X48uOJC0KBkOWY1' },
      archive: { label: '包归档', href: '/packages/' },
    },
    theme: '切换配色',
    close: '关闭',
  },
};

export function landing(language) {
  const zh = language === 'zh';
  const t = text[language];
  return {
    ...t,
    github,
    features: features[language].map(([title, body]) => ({ title, body })),
    apps: shots(apps, zh),
    games: shots(games, zh),
    guide: guide[language].map(([label, slug]) => ({ label, href: `${t.base}${slug}/` })),
  };
}
