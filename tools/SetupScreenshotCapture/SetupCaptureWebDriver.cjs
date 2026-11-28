// Drives the real ALM4Dataverse setup web UI with Playwright and writes the frames
// requested by Capture-SetupScreenshots.ps1. The job file is JSON:
// {
//   "url": "http://127.0.0.1:1234/?token=...",
//   "viewport": { "width": 1280, "height": 820 },
//   "deviceScaleFactor": 2,
//   "steps": [ ... ]
// }
// Steps run in order:
//   { "waitText": "text", "timeoutMs": 20000 }
//   { "waitMs": 400 }
//   { "screenshot": "/path/frame.png" }
//   { "clickText": "exact option or button text" }
//   { "clickRole": "button", "name": "Continue" }
//   { "clickSelector": "#prompt-value" }
//   { "typeText": "text", "framePattern": "/path/typed-%02d.png" }
//   { "press": "Enter" }
// Every failure writes a diagnostic screenshot beside the job file and exits non-zero.
'use strict';

const fs = require('fs');
const path = require('path');
const playwrightModulePath = process.env.SETUP_CAPTURE_PLAYWRIGHT_MODULE || 'playwright';
const { chromium } = require(playwrightModulePath);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForText(page, text, timeoutMs) {
  await page.waitForFunction(
    (expected) => document.body && document.body.innerText.includes(expected),
    text,
    { timeout: timeoutMs || 20000 }
  );
}

async function clickText(page, text) {
  const roleCandidates = [
    page.getByRole('option', { name: text, exact: true }),
    page.getByRole('button', { name: text, exact: true }),
    page.getByRole('button', { name: text }),
    page.getByRole('link', { name: text })
  ];
  for (const candidate of roleCandidates) {
    if (await candidate.count()) {
      await candidate.first().click();
      return;
    }
  }

  const byText = page.getByText(text, { exact: true });
  if (await byText.count()) {
    await byText.first().click();
    return;
  }

  const partial = page.getByText(text);
  if (await partial.count()) {
    await partial.first().click();
    return;
  }

  throw new Error(`Could not find '${text}' to click.`);
}

async function runStep(page, step) {
  if (step.waitText) {
    await waitForText(page, step.waitText, step.timeoutMs);
    return;
  }
  if (step.waitForPrompt) {
    // The shell renders a preparation card first; a prompt is ready when the stage
    // shows a real setup card instead.
    await page.waitForFunction(
      () => {
        const stage = document.getElementById('stage');
        if (!stage) {
          return false;
        }
        const heading = stage.querySelector('h1');
        return !!heading && !/Preparing your setup workspace/i.test(heading.textContent || '');
      },
      undefined,
      { timeout: step.timeoutMs || 20000 }
    );
    return;
  }
  if (step.waitMs) {
    await sleep(step.waitMs);
    return;
  }
  if (step.screenshot) {
    fs.mkdirSync(path.dirname(step.screenshot), { recursive: true });
    await page.screenshot({ path: step.screenshot });
    return;
  }
  if (step.clickText) {
    await clickText(page, step.clickText);
    return;
  }
  if (step.clickRole) {
    await page.getByRole(step.clickRole, { name: step.name, exact: !!step.exact }).first().click();
    return;
  }
  if (step.clickSelector) {
    await page.locator(step.clickSelector).first().click();
    return;
  }
  if (step.typeText !== undefined) {
    const selector = step.selector || '#prompt-value';
    await page.locator(selector).first().click();
    await page.locator(selector).first().fill('');
    let index = 0;
    for (const character of step.typeText) {
      index += 1;
      await page.keyboard.type(character);
      if (step.framePattern) {
        const framePath = step.framePattern.replace('%02d', String(index).padStart(2, '0'));
        fs.mkdirSync(path.dirname(framePath), { recursive: true });
        await page.screenshot({ path: framePath });
      }
    }
    return;
  }
  if (step.press) {
    await page.keyboard.press(step.press);
    return;
  }
  if (step.checkText) {
    const count = await page.getByText(step.checkText).count();
    if (!count) {
      throw new Error(`Expected to find '${step.checkText}' on the page.`);
    }
    return;
  }

  throw new Error(`Unsupported capture step: ${JSON.stringify(step)}`);
}

async function main() {
  const jobPath = process.argv[2];
  if (!jobPath) {
    throw new Error('Usage: SetupCaptureWebDriver.cjs <job.json>');
  }

  const job = JSON.parse(fs.readFileSync(jobPath, 'utf8'));
  const viewport = job.viewport || { width: 1280, height: 820 };
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({
      viewport,
      deviceScaleFactor: job.deviceScaleFactor || 2
    });
    const page = await context.newPage();
    page.on('pageerror', (error) => {
      console.error(`PAGE-ERROR: ${error.message}`);
    });

    await page.goto(job.url, { waitUntil: 'load', timeout: 60000 });
    for (const step of job.steps || []) {
      await runStep(page, step);
    }
  } catch (error) {
    try {
      const failurePath = path.join(path.dirname(jobPath), 'capture-failure.png');
      const pages = browser.contexts().flatMap((context) => context.pages());
      if (pages.length) {
        await pages[0].screenshot({ path: failurePath });
        const bodyText = await pages[0].evaluate(() => document.body ? document.body.innerText : '');
        fs.writeFileSync(path.join(path.dirname(jobPath), 'capture-failure.txt'), bodyText, 'utf8');
      }
      console.error(`CAPTURE-FAILURE: ${failurePath}`);
    } catch {
      // The diagnostic capture is best effort.
    }
    throw error;
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
