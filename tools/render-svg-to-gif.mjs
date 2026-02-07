import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = process.cwd();
const inputSvg = process.env.INPUT_SVG || path.join(repoRoot, 'assets', 'super-install-demo.svg');
const outDir = process.env.OUT_DIR || path.join(repoRoot, 'assets', 'renders');
const durationMs = Number(process.env.DURATION_MS || 16000);
const width = Number(process.env.WIDTH || 1200);
const height = Number(process.env.HEIGHT || 700);
const fps = Number(process.env.FPS || 20);

fs.mkdirSync(outDir, { recursive: true });

const fileUrl = new URL('file://' + inputSvg);

const browser = await chromium.launch();
const context = await browser.newContext({
  viewport: { width, height },
  recordVideo: { dir: outDir, size: { width, height } },
});

const page = await context.newPage();
await page.goto(fileUrl.toString());

// Give it a moment to settle fonts/layout.
await page.waitForTimeout(500);

// For SVG animations we can only "wait"; the SVG contains its own timers.
await page.waitForTimeout(durationMs);

await context.close();
await browser.close();

// Find newest webm.
const files = fs.readdirSync(outDir).filter(f => f.endsWith('.webm'));
if (!files.length) {
  console.error('No webm produced in', outDir);
  process.exit(2);
}

let newest = files[0];
let newestMtime = 0;
for (const f of files) {
  const st = fs.statSync(path.join(outDir, f));
  if (st.mtimeMs > newestMtime) {
    newestMtime = st.mtimeMs;
    newest = f;
  }
}

const webmPath = path.join(outDir, newest);
const outWebm = path.join(repoRoot, 'assets', 'super-install-demo.webm');
fs.copyFileSync(webmPath, outWebm);

console.log(JSON.stringify({
  inputSvg,
  outWebm,
  durationMs,
  width,
  height,
  fps,
}, null, 2));
