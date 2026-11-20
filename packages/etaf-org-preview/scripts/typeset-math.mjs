import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { execFileSync } from 'node:child_process'

const [texPath, outPath, ink = '#000000', pixels = '30', cell = '16'] =
  process.argv.slice(2)

function requireFromMermaidCli() {
  const mmdc = execFileSync('sh', ['-c', 'command -v mmdc'], { encoding: 'utf8' }).trim()
  const packageDir = path.dirname(path.dirname(fs.realpathSync(mmdc)))
  return createRequire(path.join(packageDir, 'package.json'))
}

const require = requireFromMermaidCli()
const katex = require('katex')
const puppeteer = require('puppeteer')

const latex = fs.readFileSync(texPath, 'utf8')
const markup = katex.renderToString(latex, {
  displayMode: true,
  throwOnError: true,
  output: 'html',
})

// KaTeX positions fractions, limits and scripts with its stylesheet, and its
// glyphs come from the fonts that ship beside it.
const katexDir = path.dirname(require.resolve('katex/package.json'))
const css = fs.readFileSync(path.join(katexDir, 'dist/katex.min.css'), 'utf8')

const html = `<!doctype html><html><head><meta charset="utf-8">
<base href="file://${path.join(katexDir, 'dist')}/">
<style>${css}</style><style>
  /* KaTeX sets its own base at 1.21em and a display block carries 1em margins
     above and below; both are meant for a page of running text.  A formula
     here is one line of the sentence, so the size is divided back out and the
     margins are dropped: the picture is the formula and nothing else. */
  html, body { margin: 0; background: transparent; }
  #formula { display: inline-block; padding: 1px 2px; color: ${ink};
             font-size: ${pixels / 1.21}px; }
  #formula .katex-display { margin: 0; }
  /* The page places its pictures in whole rows, and a row is the body line
     height.  The frame is a whole number of rows tall with the formula
     centred in it, so the picture is drawn at its own size and never scaled
     to fit: a formula keeps the size of the text around it. */
  #frame { display: flex; align-items: center; justify-content: center;
           background: transparent; }
</style></head><body><div id="frame"><div id="formula">${markup}</div></div></body></html>`

const browser = await puppeteer.launch({
  headless: 'shell',
  args: ['--allow-file-access-from-files'],
})
try {
  const page = await browser.newPage()
  // Twice the device pixels for the same CSS size: the page places the picture
  // by its own pixel size, so the extra resolution only sharpens the edges.
  await page.setViewport({ width: 1200, height: 800, deviceScaleFactor: 2 })
  await page.setContent(html, { waitUntil: 'load' })
  const row = Math.max(1, Number(cell) || 16)
  const size = await page.evaluate(() => {
    const box = document.getElementById('formula').getBoundingClientRect()
    return { width: box.width, height: box.height }
  })
  await page.evaluate(
    ({ width, height, row }) => {
      const frame = document.getElementById('frame')
      frame.style.width = `${Math.ceil(width)}px`
      frame.style.height = `${Math.ceil(height / row) * row}px`
    },
    { width: size.width, height: size.height, row },
  )
  const element = await page.$('#frame')
  await element.screenshot({ path: outPath, omitBackground: true })
} finally {
  await browser.close()
}
