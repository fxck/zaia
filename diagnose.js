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
    pageInfo: {}
  };

  let browser;
  try {
    browser = await puppeteer.launch({
      executablePath: process.env.PUPPETEER_EXECUTABLE_PATH,
      headless: true,
      args: [
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--disable-dev-shm-usage',
        '--disable-gpu'
      ]
    });

    const page = await browser.newPage();

    // Console message capture
    page.on('console', msg => {
      const type = msg.type();
      const text = msg.text();
      
      if (type === 'error') {
        results.errors.push({
          type: 'console_error',
          message: text,
          location: msg.location()
        });
      } else if (type === 'warning') {
        results.warnings.push({
          type: 'console_warning',
          message: text,
          location: msg.location()
        });
      }
    });

    // Page errors (uncaught exceptions)
    page.on('pageerror', error => {
      results.errors.push({
        type: 'page_error',
        message: error.message,
        stack: error.stack
      });
    });

    // Network request failures
    page.on('requestfailed', request => {
      results.networkIssues.push({
        type: 'request_failed',
        url: request.url(),
        error: request.failure().errorText,
        resourceType: request.resourceType()
      });
    });

    // HTTP error responses
    page.on('response', response => {
      const status = response.status();
      if (status >= 400) {
        results.networkIssues.push({
          type: 'http_error',
          url: response.url(),
          status: status,
          statusText: response.statusText(),
          resourceType: response.request().resourceType()
        });
      }
    });

    // Navigate to page with timeout
    const startTime = Date.now();
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

    const loadTime = Date.now() - startTime;
    results.pageInfo.loadTime = loadTime;

    // Get basic page info
    results.pageInfo.title = await page.title();
    results.pageInfo.url = page.url();
    
    // Check for specific loading indicators
    if (options.checkSelectors) {
      const selectorChecks = {};
      for (const selector of options.checkSelectors) {
        try {
          const element = await page.$(selector);
          selectorChecks[selector] = !!element;
          if (!element) {
            results.loadingProblems.push({
              type: 'missing_element',
              selector: selector,
              message: `Required element "${selector}" not found`
            });
          }
        } catch (error) {
          selectorChecks[selector] = false;
          results.loadingProblems.push({
            type: 'selector_error',
            selector: selector,
            message: error.message
          });
        }
      }
      results.pageInfo.selectorChecks = selectorChecks;
    }

    // Check for common loading indicators
    const commonChecks = await page.evaluate(() => {
      return {
        hasLoadingSpinners: document.querySelectorAll('[class*="loading"], [class*="spinner"]').length > 0,
        hasErrorMessages: document.querySelectorAll('[class*="error"], [id*="error"]').length > 0,
        bodyContentLength: document.body.textContent.trim().length,
        imageCount: document.images.length,
        scriptCount: document.scripts.length
      };
    });
    
    results.pageInfo = { ...results.pageInfo, ...commonChecks };

    // Check if page seems "empty" or broken
    if (commonChecks.bodyContentLength < 100) {
      results.loadingProblems.push({
        type: 'minimal_content',
        message: 'Page appears to have very little content (< 100 characters)'
      });
    }

    if (commonChecks.hasLoadingSpinners) {
      results.loadingProblems.push({
        type: 'persistent_loading',
        message: 'Loading spinners still visible, page may not have finished loading'
      });
    }

  } catch (error) {
    results.errors.push({
      type: 'script_error',
      message: error.message,
      stack: error.stack
    });
  } finally {
    if (browser) {
      await browser.close();
    }
  }

  return results;
}

// CLI Interface
async function main() {
  const args = process.argv.slice(2);
  
  if (args.length === 0) {
    console.log('Usage: node diagnose.js <url> [options]');
    console.log('Options:');
    console.log('  --timeout <ms>           Set timeout in milliseconds');
    console.log('  --check-selector <sel>   Check for specific CSS selector');
    console.log('  --output <file>          Save results to JSON file');
    console.log('  --quiet                  Only output errors and warnings');
    process.exit(1);
  }

  const url = args[0];
  const options = {};
  
  // Parse command line options
  for (let i = 1; i < args.length; i++) {
    switch (args[i]) {
      case '--timeout':
        options.timeout = parseInt(args[++i]);
        break;
      case '--check-selector':
        if (!options.checkSelectors) options.checkSelectors = [];
        options.checkSelectors.push(args[++i]);
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
  
  // Output results
  if (options.outputFile) {
    fs.writeFileSync(options.outputFile, JSON.stringify(results, null, 2));
    console.log(`📄 Results saved to: ${options.outputFile}`);
  }

  if (!options.quiet) {
    console.log(`📊 Page Info:`, results.pageInfo);
  }

  if (results.errors.length > 0) {
    console.log(`❌ Errors (${results.errors.length}):`);
    results.errors.forEach(error => {
      console.log(`  • ${error.type}: ${error.message}`);
    });
  }

  if (results.warnings.length > 0) {
    console.log(`⚠️  Warnings (${results.warnings.length}):`);
    results.warnings.forEach(warning => {
      console.log(`  • ${warning.type}: ${warning.message}`);
    });
  }

  if (results.networkIssues.length > 0) {
    console.log(`🌐 Network Issues (${results.networkIssues.length}):`);
    results.networkIssues.forEach(issue => {
      console.log(`  • ${issue.type}: ${issue.url} - ${issue.error || issue.status}`);
    });
  }

  if (results.loadingProblems.length > 0) {
    console.log(`⏳ Loading Problems (${results.loadingProblems.length}):`);
    results.loadingProblems.forEach(problem => {
      console.log(`  • ${problem.type}: ${problem.message}`);
    });
  }

  if (results.errors.length === 0 && results.networkIssues.length === 0 && results.loadingProblems.length === 0) {
    console.log('✅ No issues detected!');
  }

  // Exit with error code if issues found
  const hasIssues = results.errors.length > 0 || results.networkIssues.length > 0 || results.loadingProblems.length > 0;
  process.exit(hasIssues ? 1 : 0);
}

if (require.main === module) {
  main().catch(console.error);
}

module.exports = { diagnoseWebPage };
