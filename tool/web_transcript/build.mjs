import { createHash } from "node:crypto";
import {
  copyFile,
  mkdir,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const projectDir = path.dirname(fileURLToPath(import.meta.url));
const outputDir = path.resolve(projectDir, "../../assets/web_transcript");
const fontsDir = path.join(outputDir, "fonts");
const bundledLicenses = [
  ["markdown-it 14.3.0", "markdown-it/LICENSE"],
  ["markdown-it-task-lists 2.1.1", "markdown-it-task-lists/LICENSE"],
  [
    "@vscode/markdown-it-katex 1.1.2",
    "@vscode/markdown-it-katex/LICENSE",
  ],
  ["katex 0.16.22", "katex/LICENSE"],
  ["highlight.js 11.12.0", "highlight.js/LICENSE"],
  ["dompurify 3.4.13 (Apache-2.0)", "dompurify/LICENSE"],
];

await rm(outputDir, { recursive: true, force: true });
await mkdir(fontsDir, { recursive: true });

await build({
  entryPoints: [path.join(projectDir, "src/main.js")],
  outfile: path.join(outputDir, "app.js"),
  bundle: true,
  charset: "utf8",
  format: "iife",
  legalComments: "none",
  minify: true,
  sourcemap: false,
  supported: { "template-literal": false },
  target: ["es2020"],
});

await copyFile(
  path.join(projectDir, "src/index.html"),
  path.join(outputDir, "index.html"),
);

const katexCssPath = path.join(
  projectDir,
  "node_modules/katex/dist/katex.min.css",
);
let katexCss = await readFile(katexCssPath, "utf8");
const fontFiles = new Set();
katexCss = katexCss.replace(/@font-face\{[^}]+\}/g, (fontFace) => {
  const match = fontFace.match(/url\(fonts\/([^)]+\.woff2)\)/);
  if (!match) {
    throw new Error(`KaTeX font face has no WOFF2 source: ${fontFace}`);
  }
  fontFiles.add(match[1]);
  return fontFace.replace(
    /src:[^;}]+/,
    `src:url(fonts/${match[1]}) format("woff2")`,
  );
});

for (const fontFile of [...fontFiles].sort()) {
  await copyFile(
    path.join(projectDir, "node_modules/katex/dist/fonts", fontFile),
    path.join(fontsDir, fontFile),
  );
}

const [highlightCss, appCss] = await Promise.all([
  readFile(
    path.join(projectDir, "node_modules/highlight.js/styles/github.min.css"),
    "utf8",
  ),
  readFile(path.join(projectDir, "src/app.css"), "utf8"),
]);
await writeFile(
  path.join(outputDir, "app.css"),
  `${katexCss}\n${highlightCss}\n${appCss}`,
);

const notices = [];
for (const [label, licensePath] of bundledLicenses) {
  const text = await readFile(
    path.join(projectDir, "node_modules", licensePath),
    "utf8",
  );
  const normalizedText = text.replace(/[ \t]+$/gmu, "").trim();
  notices.push(
    `${"=".repeat(72)}\n${label}\n${"=".repeat(72)}\n${normalizedText}`,
  );
}
await writeFile(
  path.join(outputDir, "THIRD_PARTY_NOTICES.txt"),
  `${notices.join("\n\n")}\n`,
);

const [runtimeHtml, runtimeCss] = await Promise.all([
  readFile(path.join(outputDir, "index.html"), "utf8"),
  readFile(path.join(outputDir, "app.css"), "utf8"),
]);
if (/\b(?:src|href)=["']https?:/iu.test(runtimeHtml)) {
  throw new Error("Web transcript HTML contains a remote runtime asset");
}
if (/url\(\s*["']?https?:/iu.test(runtimeCss)) {
  throw new Error("Web transcript CSS contains a remote runtime asset");
}
if (!runtimeHtml.includes("connect-src 'none'")) {
  throw new Error("Web transcript CSP must disable network connections");
}

async function collectFiles(directory, prefix = "") {
  const files = [];
  const entries = await readdir(directory, { withFileTypes: true });
  for (const entry of entries.sort((a, b) =>
    a.name < b.name ? -1 : a.name > b.name ? 1 : 0,
  )) {
    const relativePath = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      files.push(
        ...(await collectFiles(path.join(directory, entry.name), relativePath)),
      );
    } else if (!relativePath.startsWith("manifest.")) {
      files.push(relativePath);
    }
  }
  return files;
}

const files = {};
for (const relativePath of await collectFiles(outputDir)) {
  const contents = await readFile(path.join(outputDir, relativePath));
  files[relativePath] = {
    bytes: contents.length,
    sha256: createHash("sha256").update(contents).digest("hex"),
  };
}

const manifest = `${JSON.stringify(
  {
    formatVersion: 1,
    protocolVersion: 1,
    files,
  },
  null,
  2,
)}\n`;
await writeFile(path.join(outputDir, "manifest.json"), manifest);
await writeFile(
  path.join(outputDir, "manifest.sha256"),
  `${createHash("sha256").update(manifest).digest("hex")}  manifest.json\n`,
);
