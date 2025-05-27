#!/usr/bin/env node

const puppeteer = require('puppeteer');
const fs = require('fs');

async function diagnose(url, options) {
    const browser = await puppeteer.launch({
        headless: true,
        args: [
            '--no-sandbox',
            '--disable-setuid-sandbox',
            '--disable-dev-shm-usage',
            '--disable-accelerated-2d-canvas',
            '--disable-gpu'
        ]
    });

    const page = await browser.newPage();

    // Set viewport
    await page.setViewport({
        width: 1920,
        height: 1080
    });

    const issues = {
        console: [],
        network: [],
        runtime: [],
        frameworkIssues: [],
        performance: {}
    };

    // Console error tracking
    if (options.checkConsole) {
        page.on('console', msg => {
            const type = msg.type();
            const text = msg.text();

            if (type === 'error') {
                // Filter out common noise
                if (!text.includes('favicon.ico') &&
                    !text.includes('Failed to load resource: net::ERR_FAILED') &&
                    !text.includes('chrome-extension://') &&
                    !text.includes('[HMR]') &&
                    !text.includes('Download the React DevTools')) {

                    issues.console.push({
                        text: text,
                        location: msg.location()
                    });
                }
            } else if (type === 'warning' && text.includes('React')) {
                // Capture React warnings
                issues.frameworkIssues.push(`React Warning: ${text}`);
            }
        });

        page.on('pageerror', error => {
            issues.runtime.push({
                message: error.message,
                stack: error.stack
            });
        });
    }

    // Network tracking
    if (options.checkNetwork) {
        const failedResources = new Map();

        page.on('requestfailed', request => {
            const url = request.url();
            const method = request.method();

            if (!url.includes('favicon.ico') &&
                !url.includes('chrome-extension://') &&
                !url.includes('googletagmanager') &&
                !url.includes('google-analytics')) {

                const key = `${method} ${url}`;
                if (!failedResources.has(key)) {
                    failedResources.set(key, {
                        url: url,
                        method: method,
                        error: request.failure().errorText
                    });
                }
            }
        });

        page.on('response', response => {
            const status = response.status();
            const url = response.url();
            const method = response.request().method();

            if (status >= 400 &&
                !url.includes('favicon.ico') &&
                !url.includes('chrome-extension://') &&
                !url.includes('googletagmanager')) {

                const key = `${method} ${url}`;
                if (!failedResources.has(key)) {
                    failedResources.set(key, {
                        url: url,
                        method: method,
                        status: status,
                        statusText: response.statusText()
                    });
                }

                // Check for CORS issues
                const headers = response.headers();
                const requestOrigin = response.request().headers()['origin'];

                if (requestOrigin && !headers['access-control-allow-origin']) {
                    issues.network.push({
                        url: url,
                        error: 'Missing CORS headers',
                        status: status
                    });
                }
            }
        });

        // Convert Map to array after navigation
        page.on('load', () => {
            issues.network.push(...Array.from(failedResources.values()));
        });
    }

    // Performance timing
    const startTime = Date.now();

    try {
        // Navigate with extended timeout
        const response = await page.goto(url, {
            waitUntil: 'networkidle2',
            timeout: 60000
        });

        // Check initial response
        if (!response.ok()) {
            issues.runtime.push({
                message: `Initial page load failed with status ${response.status()}`
            });
        }

        // Wait for dynamic content
        await page.waitForTimeout(3000);

        // Performance metrics
        if (options.checkPerformance) {
            const performanceMetrics = await page.evaluate(() => {
                const perf = window.performance;
                const navigation = perf.getEntriesByType('navigation')[0];

                return {
                    domContentLoaded: navigation.domContentLoadedEventEnd - navigation.domContentLoadedEventStart,
                    loadComplete: navigation.loadEventEnd - navigation.loadEventStart,
                    totalTime: navigation.loadEventEnd - navigation.fetchStart,
                    domInteractive: navigation.domInteractive - navigation.fetchStart,
                    firstPaint: perf.getEntriesByType('paint').find(p => p.name === 'first-paint')?.startTime || 0,
                    firstContentfulPaint: perf.getEntriesByType('paint').find(p => p.name === 'first-contentful-paint')?.startTime || 0
                };
            });

            issues.performance = performanceMetrics;

            // Add performance warnings
            if (performanceMetrics.totalTime > 10000) {
                issues.runtime.push({
                    message: `Slow page load: ${(performanceMetrics.totalTime / 1000).toFixed(2)}s total load time`
                });
            }
        }

        // Framework-specific checks
        const frameworkChecks = await page.evaluate(() => {
            const checks = [];

            // Helper to safely get text content
            const safeText = (element) => {
                return element ? element.textContent || '' : '';
            };

            // React checks
            if (window.React || window.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
                // Check for error boundaries
                const errorBoundaries = document.querySelectorAll('[class*="error-boundary"], [class*="ErrorBoundary"]');
                errorBoundaries.forEach(boundary => {
                    if (safeText(boundary).toLowerCase().includes('error')) {
                        checks.push('React ErrorBoundary triggered');
                    }
                });

                // Check for hydration errors
                const bodyText = document.body.innerHTML;
                if (bodyText.includes('Hydration failed') ||
                    bodyText.includes('did not match') ||
                    bodyText.includes('Text content does not match')) {
                    checks.push('React hydration mismatch detected');
                }

                // Check for React errors in general
                if (bodyText.includes('Uncaught Error:') && (bodyText.includes('React') || bodyText.includes('Component'))) {
                    checks.push('React runtime error detected');
                }
            }

            // Next.js checks
            if (document.querySelector('#__next')) {
                const buildError = document.querySelector('#__next-build-error');
                if (buildError) {
                    checks.push(`Next.js build error: ${safeText(buildError)}`);
                }

                // Check for 404
                const title = document.title.toLowerCase();
                const bodyText = document.body.textContent.toLowerCase();
                if (title.includes('404') || (bodyText.includes('404') && bodyText.includes('page'))) {
                    checks.push('Next.js 404 page detected');
                }

                // Check for 500 errors
                if (title.includes('500') || bodyText.includes('internal server error')) {
                    checks.push('Next.js 500 error detected');
                }
            }

            // Vue checks
            if (window.Vue || document.querySelector('#app[data-v-]') || window.__VUE__) {
                const bodyText = document.body.textContent;
                if (bodyText.includes('[Vue warn]') || bodyText.includes('Vue warning')) {
                    checks.push('Vue warnings detected in output');
                }

                // Check for Vue error overlay
                if (document.querySelector('.vue-error-overlay')) {
                    checks.push('Vue error overlay detected');
                }
            }

            // Angular checks
            if (window.ng || document.querySelector('[ng-version]') || window.getAllAngularRootElements) {
                const bodyText = document.body.textContent;
                if (bodyText.includes('Error:') && document.querySelector('ng-component')) {
                    checks.push('Angular runtime error detected');
                }

                // Check for Angular specific error classes
                if (document.querySelector('.ng-star-inserted.error')) {
                    checks.push('Angular error component detected');
                }
            }

            // General SPA checks
            const rootSelectors = ['#root', '#app', '#__next', '[ng-app]', '.app-root', '#mount'];
            const hasRoot = rootSelectors.some(sel => document.querySelector(sel));
            const bodyContent = document.body.textContent.trim();

            if (hasRoot && bodyContent.length < 100 && !bodyContent.includes('Loading')) {
                checks.push('SPA root element exists but minimal content rendered');
            }

            // Check for infinite loading
            const loadingSelectors = [
                '[class*="loading"]:not([class*="loaded"]):not([style*="display: none"])',
                '[class*="spinner"]:not([style*="display: none"])',
                '[class*="skeleton"]:not([style*="display: none"])',
                '.loader:not([style*="display: none"])',
                '[class*="progress"]:not([style*="display: none"])'
            ];

            const activeLoaders = loadingSelectors.some(sel => {
                const elements = document.querySelectorAll(sel);
                return Array.from(elements).some(el => {
                    const style = window.getComputedStyle(el);
                    const rect = el.getBoundingClientRect();
                    return style.display !== 'none' &&
                           style.visibility !== 'hidden' &&
                           style.opacity !== '0' &&
                           rect.width > 0 &&
                           rect.height > 0;
                });
            });

            if (activeLoaders) {
                checks.push('Loading indicators still visible after page load');
            }

            // Check for common error patterns in content
            const errorPatterns = [
                { pattern: 'Cannot read property', message: 'JavaScript property access error' },
                { pattern: 'undefined is not', message: 'Undefined reference error' },
                { pattern: 'NetworkError', message: 'Network error detected' },
                { pattern: 'Failed to fetch', message: 'Fetch API error' },
                { pattern: 'CORS', message: 'CORS error detected' },
                { pattern: 'Access-Control', message: 'Access control error' },
                { pattern: 'Module not found', message: 'Module loading error' },
                { pattern: 'ChunkLoadError', message: 'Webpack chunk loading error' },
                { pattern: 'SyntaxError', message: 'JavaScript syntax error' }
            ];

            const pageContent = document.body.textContent;
            errorPatterns.forEach(({ pattern, message }) => {
                if (pageContent.includes(pattern)) {
                    checks.push(message);
                }
            });

            // Check meta tags for errors
            const metaRefresh = document.querySelector('meta[http-equiv="refresh"]');
            if (metaRefresh) {
                checks.push('Meta refresh redirect detected - possible error handling');
            }

            return checks;
        });

        issues.frameworkIssues.push(...frameworkChecks);

        // Take screenshot if requested
        if (options.saveScreenshot && options.screenshotPath) {
            await page.screenshot({
                path: options.screenshotPath,
                fullPage: false
            });
        }

    } catch (error) {
        issues.runtime.push({
            message: `Navigation failed: ${error.message}`,
            error: error.toString()
        });
    }

    await browser.close();

    // Clean up issues
    return {
        console: issues.console.map(c => typeof c === 'string' ? c : c.text || JSON.stringify(c)),
        network: issues.network,
        runtime: issues.runtime.map(r => typeof r === 'string' ? r : r.message || JSON.stringify(r)),
        frameworkIssues: [...new Set(issues.frameworkIssues)], // Remove duplicates
        performance: issues.performance
    };
}

// Main execution
const args = process.argv.slice(2);

if (args.length === 0 || args.includes('-h') || args.includes('--help')) {
    console.log('Usage: node puppeteer_check.js <url> [options]');
    console.log('Options:');
    console.log('  --check-console      Check for console errors');
    console.log('  --check-network      Check for network errors');
    console.log('  --check-performance  Capture performance metrics');
    console.log('  --save-screenshot    Save a screenshot');
    console.log('  --screenshot-path    Path for screenshot file');
    process.exit(1);
}

const url = args[0];
const options = {
    checkConsole: args.includes('--check-console'),
    checkNetwork: args.includes('--check-network'),
    checkPerformance: args.includes('--check-performance'),
    saveScreenshot: args.includes('--save-screenshot'),
    screenshotPath: null
};

// Get screenshot path if provided
const screenshotIndex = args.indexOf('--screenshot-path');
if (screenshotIndex !== -1 && args[screenshotIndex + 1]) {
    options.screenshotPath = args[screenshotIndex + 1];
} else if (options.saveScreenshot) {
    options.screenshotPath = `/tmp/screenshot_${Date.now()}.png`;
}

// Run diagnosis
diagnose(url, options)
    .then(issues => {
        console.log(JSON.stringify(issues, null, 2));

        // Exit with error if issues found
        const totalIssues = Object.values(issues)
            .filter(v => Array.isArray(v))
            .reduce((sum, arr) => sum + arr.length, 0);

        process.exit(totalIssues > 0 ? 1 : 0);
    })
    .catch(error => {
        console.error(JSON.stringify({
            error: error.message,
            stack: error.stack
        }));
        process.exit(1);
    });
