import { build } from 'esbuild';

const common = {
    bundle: true,
    format: 'iife',
    minify: true,
    target: ['safari15'],
    legalComments: 'none',
    logLevel: 'info',
    // Only ContentScript is used; the background-page polyfill is never called.
    alias: { 'webextension-polyfill': './polyfill-stub.js' },
};

await build({ ...common, entryPoints: ['content.js'], outfile: 'dist/adguard-content.js' });
await build({ ...common, entryPoints: ['scriptlets.js'], outfile: 'dist/adguard-scriptlets.js' });
