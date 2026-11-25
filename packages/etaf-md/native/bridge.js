/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Host adapter for embedded QuickJS rendering in etaf-md.
 *
 * The portableSvg CSS-custom-property resolver and native CoreText/Pango
 * text-measurement bridge are adapted from LuciusChen/pele.el
 * (https://github.com/LuciusChen/pele.el, MIT License).
 * Vendored vendor/pele/pele.global.js and vendor/mathjax/mathjax-tex-svg.global.js
 * are kept unmodified.
 */
"use strict";

(() => {
  const textWidths = new Map();
  const WIDEST = 1200;

  const decode = (value) =>
    value.replace(
      /&(?:quot|apos|lt|gt|amp);/g,
      (entity) =>
        ({ "&quot;": '"', "&apos;": "'", "&lt;": "<", "&gt;": ">", "&amp;": "&" })[entity]
    );

  const escape = (value) =>
    String(value).replace(
      /[&"<>]/g,
      (character) =>
        ({ "&": "&amp;", '"': "&quot;", "<": "&lt;", ">": "&gt;" })[character]
    );

  // Pele emits presentation attributes and inline CSS, not stylesheet rules.
  // Resolve scoped custom properties statically before handing SVG to librsvg.
  function resolve(value, variables, seen = new Set()) {
    let output = "";
    let offset = 0;
    while (offset < value.length) {
      const start = value.indexOf("var(", offset);
      if (start < 0) return output + value.slice(offset);
      output += value.slice(offset, start);
      let depth = 1;
      let end = start + 4;
      let comma = -1;
      for (; end < value.length && depth; end++) {
        if (value[end] === "(") depth++;
        else if (value[end] === ")") depth--;
        else if (value[end] === "," && depth === 1 && comma < 0) comma = end;
      }
      if (depth) throw new Error("Unclosed CSS variable in generated SVG");
      const key = value.slice(start + 4, comma < 0 ? end - 1 : comma).trim();
      const fallback = comma < 0 ? "" : value.slice(comma + 1, end - 1).trim();
      const next = new Set(seen);
      const replacement =
        !seen.has(key) && Object.hasOwn(variables, key)
          ? (next.add(key), variables[key])
          : fallback;
      output += resolve(replacement, variables, next);
      offset = end;
    }
    return output;
  }

  function portableSvg(svg, theme, transparent, scaledWidth, scaledHeight) {
    const stack = [Object.assign(Object.create(null), theme)];
    return svg.replace(/<\/?[\w:-]+(?:\s[^<>]*?)?\s*\/?>/g, (tag) => {
      if (tag.startsWith("</")) {
        stack.pop();
        return tag;
      }
      const name = /^<([\w:-]+)/.exec(tag)[1];
      const attributes = [];
      for (const match of tag.matchAll(/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) {
        attributes.push([match[1], decode(match[2] ?? match[3])]);
      }
      const parent = stack[stack.length - 1];
      const variables = Object.assign(Object.create(null), parent);
      const style = attributes.find(([key]) => key === "style")?.[1] ?? "";
      const declarations = style.split(";").flatMap((declaration) => {
        const colon = declaration.indexOf(":");
        return colon < 0
          ? []
          : [[declaration.slice(0, colon).trim(), declaration.slice(colon + 1).trim()]];
      });
      for (const [key, value] of declarations) {
        if (key.startsWith("--")) variables[key] = value;
      }
      const computed = Object.assign(Object.create(null), variables);
      for (const [key] of declarations) {
        if (key.startsWith("--")) computed[key] = resolve(variables[key], variables);
      }
      const plainStyle = declarations
        .filter(([key]) => !key.startsWith("--"))
        .map(([key, value]) => [key, resolve(value, computed)]);
      const radius = plainStyle.find(([key]) => key === "rx");
      if (radius && !attributes.some(([key]) => key === "rx")) {
        attributes.push(["rx", radius[1]]);
      }
      const root = name === "svg" && stack.length === 1;
      const output = attributes.flatMap(([key, value]) => {
        if (key === "style") {
          const css = plainStyle
            .filter(([property]) => {
              if (property === "rx") return false;
              if (root && (property === "max-width" || property === "height")) return false;
              return true;
            })
            .map(([property, text]) => `${property}:${text}`)
            .join(";");
          return css ? [[key, css]] : [];
        }
        if (root && key === "width" && scaledWidth > 0) {
          return [[key, String(scaledWidth)]];
        }
        if (root && key === "height" && scaledHeight > 0) {
          return [[key, String(scaledHeight)]];
        }
        return [[key, resolve(value, computed)]];
      });
      if (root && !attributes.some(([key]) => key === "xml:space")) {
        output.push(["xml:space", "preserve"]);
      }
      if (!tag.endsWith("/>")) stack.push(computed);
      const background =
        root && !transparent
          ? `<rect class="pele-background" width="100%" height="100%" fill="${escape(
              resolve("var(--_bg)", computed)
            )}"/>`
          : "";
      return `<${name}${output
        .map(([key, value]) => ` ${key}="${escape(value)}"`)
        .join("")}${tag.endsWith("/>") ? "/>" : ">"}${background}`;
    });
  }

  function renderMermaid(source, options) {
    const theme = options.theme ?? {};
    const transparent = options.transparentBackground !== false;
    const pixelScale = Math.max(1, Number(options.scale) || 2);
    const widest = Math.max(100, Number(options.widest) || WIDEST);
    const nativeText =
      options.measureText !== false && typeof __etafMdMeasureText === "function";
    const peleOptions = Object.assign({}, options);
    delete peleOptions.measureText;
    delete peleOptions.theme;
    delete peleOptions.transparentBackground;
    delete peleOptions.scale;
    delete peleOptions.widest;

    if (nativeText) {
      peleOptions.measurer = {
        width(text, size, style) {
          const family =
            (style & 4 ? peleOptions.fontFamilyMono : peleOptions.fontFamily) ?? "sans-serif";
          const effectiveSize = style & (8 | 16) ? size / 1.2 : size;
          const key = JSON.stringify([family, effectiveSize, style, text]);
          let width = textWidths.get(key);
          if (width === undefined) {
            width = __etafMdMeasureText(text, effectiveSize, style, family.replace(/["']/g, ""));
            if (textWidths.size >= 10000) textWidths.clear();
            textWidths.set(key, width);
          }
          return width;
        },
      };
    }

    // Never fetch external resources or execute diagram callbacks.
    peleOptions.images = false;
    peleOptions.links = false;
    peleOptions.responsive = false;
    peleOptions.limit = Math.min(peleOptions.limit ?? 50000, 50000);
    peleOptions.outputLimit = Math.min(peleOptions.outputLimit ?? 4000000, 4000000);
    peleOptions.maxEdges = Math.min(peleOptions.maxEdges ?? 5000, 5000);

    const result = pele.render(source, peleOptions);
    const natW = Math.max(1, Number(result.width) || 1);
    const natH = Math.max(1, Number(result.height) || 1);
    const fitScale = Math.min(1, widest / natW);
    const scaledW = Math.max(1, Math.round(natW * fitScale * pixelScale));
    const scaledH = Math.max(1, Math.round(natH * fitScale * pixelScale));

    const svg = portableSvg(result.svg, theme, transparent, scaledW, scaledH);
    return {
      ok: true,
      svg,
      width: natW,
      height: natH,
      type: result.type ?? "mermaid",
      textMeasurement: nativeText ? "native" : "estimate",
    };
  }

  function renderMath(source, options) {
    if (typeof __etafMdMathJaxSvg !== "function") {
      throw new Error("MathJax TeX-to-SVG engine is not loaded");
    }
    const raw = __etafMdMathJaxSvg(source, true);
    const openMatch = /^<svg\b([^>]*)>/.exec(raw);
    const closeIndex = raw.lastIndexOf("</svg>");
    if (!openMatch || closeIndex < 0) {
      throw new Error("MathJax did not produce an SVG element");
    }
    const attrs = openMatch[1];
    const vbMatch = /\bviewBox="([^"]+)"/.exec(attrs);
    if (!vbMatch) {
      throw new Error("MathJax SVG is missing a viewBox");
    }
    const parts = vbMatch[1].trim().split(/[\s,]+/).map(Number);
    if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) {
      throw new Error("Invalid MathJax viewBox");
    }
    const [vbX, vbY, vbW, vbH] = parts;
    const ink = String(options.ink || "#000000");
    const pixels = Math.max(8, Number(options.pixels) || 16);
    const row = Math.max(1, Number(options.cell) || Math.ceil(pixels * 1.35));
    const pixelScale = Math.max(1, Number(options.scale) || 2);
    const fontFamily = String(options.fontFamily || "sans-serif");

    // In MathJax TeX SVG output, 1000 viewBox units equal 1em.
    const pxPerUnit = (pixels * 1.08) / 1000.0;
    const safeW = Math.max(1, vbW);
    const safeH = Math.max(1, vbH);
    const natW = Math.max(1, safeW * pxPerUnit);
    const natH = Math.max(1, safeH * pxPerUnit);
    const padX = 4;
    const frameW = Math.max(1, Math.ceil(natW + padX * 2));
    const frameH = Math.max(row, Math.ceil((natH + 2) / row) * row);
    const dx = (frameW - natW) / 2;
    const dy = (frameH - natH) / 2;

    let inner = raw.slice(openMatch[0].length, closeIndex);
    inner = inner.replaceAll("currentColor", escape(ink));
    inner = inner.replace(/\bfont-family="serif"/g, `font-family="${escape(fontFamily)}"`);

    const scaledW = Math.max(1, Math.round(frameW * pixelScale));
    const scaledH = Math.max(1, Math.round(frameH * pixelScale));
    const svg =
      `<svg xmlns="http://www.w3.org/2000/svg" width="${scaledW}" height="${scaledH}" ` +
      `viewBox="0 0 ${frameW} ${frameH}">` +
      `<g transform="translate(${dx.toFixed(2)},${dy.toFixed(2)}) ` +
      `scale(${pxPerUnit.toFixed(6)}) translate(${(-vbX).toFixed(2)},${(-vbY).toFixed(2)})">` +
      `${inner}</g></svg>`;

    return {
      ok: true,
      svg,
      width: frameW,
      height: frameH,
      type: "math",
    };
  }

  globalThis.__etafMdRender = (kind, source, optionsJson) => {
    try {
      const options = optionsJson ? JSON.parse(optionsJson) : {};
      const result =
        kind === "math" ? renderMath(source, options) : renderMermaid(source, options);
      return JSON.stringify(result);
    } catch (error) {
      const code = error && error.code ? String(error.code) : "render";
      const message =
        error && error.message ? String(error.message) : String(error || "render failed");
      return JSON.stringify({
        ok: false,
        error: {
          code,
          message,
          type: (error && error.type) || null,
          line: (error && error.line) || 0,
          column: (error && error.column) || 0,
          snippet: (error && error.snippet) || "",
        },
      });
    }
  };
})();
