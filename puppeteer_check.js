#!/usr/bin/env node

const puppeteer = require('puppeteer');

async function diagnose(url, options) {
    const browser = await puppeteer.launch({
        headless: true,
        args: ['--no-sandbox', '--disable-setuid-sandbox']
    });

    const page = await browser.newPage();
    const issues = {console: [], network: [], runtime: []};

    if (options.checkConsole) {
        page.on('console', msg => {
            if (msg.type() === 'error') {
                const text = msg.text();
                // Filter out common noise
                if (!text.includes('favicon.ico') &&
                    !text.includes('Failed to load resource: net::ERR_FAILED')) {
                    issues.console.push(text);
                }
            }
        });

        page.on('pageerror', error => {
            issues.runtime.push(error.message);
        });
    }

    if (options.checkNetwork) {
        page.on('requestfailed', request => {
            const url = request.url();
            // Filter out common non-issues
            if (!url.includes('favicon.ico')) {
                issues.network.push({
                    url: url,
                    error: request.failure().errorText
                });
            }
        });

        page.on('response', response => {
            if (response.status() >= 400) {
                const url = response.url();
                if (!url.includes('favicon.ico')) {
                    issues.network.push({
                        url: url,
                        status: response.status()
                    });
                }
            }
        });
    }

    try {
        await page.goto(url, {waitUntil: 'networkidle2', timeout: 30000});

        // Check for common frontend framework issues
        const pageIssues = await page.evaluate(() => {
            const checks = [];

            // React error boundary
            if (document.querySelector('#react-error-overlay') ||
                document.querySelector('.react-error-overlay')) {
                checks.push('React error overlay detected');
            }

            // Next.js error
            if (document.querySelector('#__next-build-error')) {
                checks.push('Next.js build error detected');
            }

            // Vue error
            if (document.body.textContent.includes('Vue warn:') ||
                document.body.textContent.includes('[Vue warn]')) {
                checks.push('Vue warnings detected');
            }

            // Angular error
            if (document.querySelector('ng-component') &&
                document.body.textContent.includes('Error:')) {
                checks.push('Angular error detected');
            }

            // Empty content (but not if it's a SPA still loading)
            const hasContent = document.body.textContent.trim().length > 50;
            const hasRootDiv = document.querySelector('#root, #app, #__next, [ng-app]');
            if (!hasContent && !hasRootDiv) {
                checks.push('Page has minimal content and no SPA root element');
            }

            // Loading indicators still visible after load
            const loadingSelectors = [
                '[class*="loading"]', '[class*="spinner"]',
                '[class*="skeleton"]', '.loader'
            ];
            const hasLoaders = loadingSelectors.some(sel =>
                document.querySelectorAll(sel).length > 0
            );
            if (hasLoaders) {
                checks.push('Loading indicators still visible after page load');
            }

            // Check for hydration errors
            if (window.__REACT_DEVTOOLS_GLOBAL_HOOK__ &&
                document.body.innerHTML.includes('Hydration failed')) {
                checks.push('React hydration error detected');
            }

            return checks;
        });

        issues.runtime.push(...pageIssues);

    } catch (error) {
        issues.runtime.push(`Navigation failed: ${error.message}`);
    }

    await browser.close();
    return issues;
}

// Execute
const url = process.argv[2];
const options = {
    checkConsole: process.argv.includes('--check-console'),
    checkNetwork: process.argv.includes('--check-network')
};

diagnose(url, options).then(issues => {
    console.log(JSON.stringify(issues, null, 2));
    process.exit(issues.console.length + issues.network.length + issues.runtime.length > 0 ? 1 : 0);
}).catch(error => {
    console.error(`Error: ${error.message}`);
    process.exit(1);
});
