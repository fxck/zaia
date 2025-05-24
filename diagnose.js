#!/usr/bin/env node

const puppeteer = require('puppeteer');
const fs = require('fs');

async function diagnoseWebPage(url, options = {}) {
  const results = {
    url,
    timestamp: new Date().toISOString(),
    errors: [],
    warnings: [],
    networkIssues: [],
    loadingProblems: [],
    performance: {},
    pageInfo: {}
  };

  let browser;
  try {
    browser = await puppeteer.launch({
      executablePath: process.env.PUPPETEER_EXECUTABLE_PATH,
      headless: true,
      args: ['--no-sandbox', '--disable-setuid-sandbox']
    });

    const page = await browser.newPage();

    // Capture console errors
    page.on('console', msg => {
      const type = msg.type();
      if (type === 'error') {
        results.errors.push({
          type: 'console_error',
          message: msg.text(),
          location: msg.location()
        });
      } else if (type === 'warning') {
        results.warnings.push({
          type: 'console_warning',
          message: msg.text()
        });
      }
    });

    // Capture page errors
    page.on('pageerror', error => {
      results.errors.push({
        type: 'page_error',
        message: error.message,
        stack: error.stack
      });
    });

    // Network failures
    page.on('requestfailed', request => {
      results.networkIssues.push({
        type: 'request_failed',
        url: request.url(),
        error: request.failure().errorText,
        resourceType: request.resourceType()
      });
    });

    // HTTP errors
    page.on('response', response => {
      if (response.status() >= 400) {
        results.networkIssues.push({
          type: 'http_error',
          url: response.url(),
          status: response.status(),
          statusText: response.statusText()
        });
      }
    });

    // Performance timing
    const startTime = Date.now();

    // Navigate
    try {
      await page.goto(url, { 
        waitUntil: 'networkidle2',
        timeout: options.timeout || 30000 
      });
    } catch (error) {
      results.errors.push({
        type: 'navigation_error',
        message: error.message
      });
      return results;
    }

    results.performance.loadTime = Date.now() - startTime;

    // Get page info
    results.pageInfo.title = await page.title();
    results.pageInfo.url = page.url();
    
    // Check selectors
    if (options.checkSelectors) {
      results.pageInfo.selectorChecks = {};
      for (const selector of options.checkSelectors) {
        const exists = !!(await page.$(selector));
        results.pageInfo.selectorChecks[selector] = exists;
        if (!exists) {
          results.loadingProblems.push({
            type: 'missing_element',
            selector: selector
          });
        }
      }
    }

    // Check page content
    const content = await page.evaluate(() => ({
      hasContent: document.body.textContent.trim().length > 100,
      hasLoaders: document.querySelectorAll('[class*="loading"]').length > 0,
      errorElements: document.querySelectorAll('[class*="error"]').length
    }));
    
    if (!content.hasContent) {
      results.loadingProblems.push({
        type: 'minimal_content',
        message: 'Page has very little content'
      });
    }

    if (content.hasLoaders) {
      results.loadingProblems.push({
        type: 'persistent_loading',
        message: 'Loading indicators still visible'
      });
    }

    // Performance metrics
    if (options.performance) {
      const metrics = await page.metrics();
      results.performance.metrics = metrics;
    }

    // Screenshots
    if (options.screenshots) {
      const screenshotPath = `/tmp/screenshot_${Date.now()}.png`;
      await page.screenshot({ path: screenshotPath });
      results.pageInfo.screenshot = screenshotPath;
    }

  } finally {
    if (browser) await browser.close();
  }

  return results;
}

// CLI
async function main() {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    console.log('Usage: node diagnose.js <url> [options]');
    console.log('Options:');
    console.log('  --check-selector <sel>  Check for CSS selector');
    console.log('  --timeout <ms>          Set timeout');
    console.log('  --performance           Capture performance metrics');
    console.log('  --screenshots           Take screenshots');
    console.log('  --output <file>         Save results to file');
    console.log('  --quiet                 Minimal output');
    process.exit(1);
  }

  const url = args[0];
  const options = {};
  
  for (let i = 1; i < args.length; i++) {
    switch (args[i]) {
      case '--check-selector':
        if (!options.checkSelectors) options.checkSelectors = [];
        options.checkSelectors.push(args[++i]);
        break;
      case '--timeout':
        options.timeout = parseInt(args[++i]);
        break;
      case '--performance':
        options.performance = true;
        break;
      case '--screenshots':
        options.screenshots = true;
        break;
      case '--output':
        options.outputFile = args[++i];
        break;
      case '--quiet':
        options.quiet = true;
        break;
    }
  }

  console.log(`🔍 Diagnosing: ${url}`);
  const results = await diagnoseWebPage(url, options);
  
  if (options.outputFile) {
    fs.writeFileSync(options.outputFile, JSON.stringify(results, null, 2));
    console.log(`📄 Results saved to: ${options.outputFile}`);
  }

  if (!options.quiet) {
    console.log(`📊 Page Info:`, results.pageInfo);
    if (results.performance.loadTime) {
      console.log(`⏱️  Load time: ${results.performance.loadTime}ms`);
    }
  }

  if (results.errors.length > 0) {
    console.log(`❌ Errors (${results.errors.length}):`);
    results.errors.forEach(e => console.log(`  • ${e.type}: ${e.message}`));
  }

  if (results.networkIssues.length > 0) {
    console.log(`🌐 Network Issues (${results.networkIssues.length}):`);
    results.networkIssues.forEach(i => console.log(`  • ${i.type}: ${i.url}`));
  }

  if (results.loadingProblems.length > 0) {
    console.log(`⏳ Loading Problems:`)
    results.loadingProblems.forEach(p => console.log(`  • ${p.type}: ${p.message || p.selector}`));
  }

  if (results.errors.length === 0 && results.networkIssues.length === 0) {
    console.log('✅ No issues detected!');
  }

  process.exit(results.errors.length > 0 ? 1 : 0);
}

if (require.main === module) {
  main().catch(console.error);
}

module.exports = { diagnoseWebPage };
