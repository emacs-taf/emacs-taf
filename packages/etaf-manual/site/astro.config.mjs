// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { satteri } from '@astrojs/markdown-satteri';
import sidebar from './src/sidebar.mjs';

// The content under src/content/docs and the sidebar module are generated from
// `book/` by scripts/export-site.el; run `npm run export` first (the build and
// dev scripts do).
const wenkai = 'https://cdn.jsdelivr.net/npm/lxgw-wenkai-webfont@1.7.0';

export default defineConfig({
  site: 'https://etaf.top',
  // Astro's smartypants rewrites -- and quotes in headings before ids are
  // generated, which would break anchors referenced by the book sources.
  markdown: { processor: satteri({ features: { smartPunctuation: false } }) },
  integrations: [
    starlight({
      title: 'ETAF Reference Manual',
      // The exported recovery document owns /404; do not also inject a
      // competing built-in route for the same page.
      disable404Route: true,
      favicon: '/favicon.svg',
      logo: { src: './src/assets/etaf-icon.svg' },
      customCss: ['./src/styles/custom.css'],
      components: {
        ThemeSelect: './src/components/ThemeSelect.astro',
        LanguageSelect: './src/components/LanguageSelect.astro',
      },
      // Chinese text and code render in LXGW WenKai, subset by unicode-range,
      // so a page fetches only the glyph files it uses.
      head: [
        { tag: 'link', attrs: { rel: 'stylesheet', href: `${wenkai}/lxgwwenkai-regular.css` } },
        { tag: 'link', attrs: { rel: 'stylesheet', href: `${wenkai}/lxgwwenkai-bold.css` } },
        { tag: 'link', attrs: { rel: 'stylesheet', href: `${wenkai}/lxgwwenkaimono-regular.css` } },
        // Link previews for the manual: Starlight supplies the title and URL,
        // but no image or description, so a shared card fills both gaps.
        { tag: 'meta', attrs: { property: 'og:image', content: 'https://etaf.top/og/manual.png' } },
        { tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
        { tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
        { tag: 'meta', attrs: { property: 'og:image:alt', content: 'ETAF Reference Manual' } },
        { tag: 'meta', attrs: { name: 'twitter:image', content: 'https://etaf.top/og/manual.png' } },
        { tag: 'meta', attrs: { name: 'description', content: 'ETAF Reference Manual: concepts and public interfaces for building text applications in Emacs.' } },
        { tag: 'meta', attrs: { property: 'og:description', content: 'ETAF Reference Manual: concepts and public interfaces for building text applications in Emacs.' } },
      ],
      locales: {
        root: { label: 'English', lang: 'en' },
        'zh-cn': { label: '简体中文', lang: 'zh-CN' },
      },
      sidebar,
    }),
  ],
});
