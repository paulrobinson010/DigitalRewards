// Renders each SVG given on the command line to a 1024x1024 PNG next to it.
const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 } });
  for (const file of process.argv.slice(2)) {
    const svg = fs.readFileSync(file, 'utf8');
    await page.setContent(`<html><body style="margin:0">${svg.replace('<svg ', '<svg width="1024" height="1024" ')}</body></html>`);
    await page.screenshot({ path: file.replace(/\.svg$/, '.png'), clip: { x: 0, y: 0, width: 1024, height: 1024 } });
  }
  await browser.close();
})();
