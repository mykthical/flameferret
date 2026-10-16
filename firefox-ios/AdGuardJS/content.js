// Runs in Flameferret's isolated "flameferret-adguard" world in every frame at document start.
// Applies AdGuard cosmetic rules (CSS and Extended CSS). Scriptlets and JS rules are injected
// natively into the page world so they bypass the site's Content Security Policy.
import { ContentScript, setupDelayedEventDispatcher } from '@adguard/safari-extension';

const contentScript = new ContentScript();
let applied = false;

function applyCosmetics(configuration) {
    if (applied || !configuration) {
        return;
    }
    applied = true;
    contentScript.applyConfiguration({
        css: configuration.css || [],
        extendedCss: configuration.extendedCss || [],
        js: [],
        scriptlets: [],
        engineTimestamp: configuration.engineTimestamp || 0,
    });
}

globalThis.__flameferretAdguard = { applyCosmetics };

const bridge = globalThis.webkit && globalThis.webkit.messageHandlers
    && globalThis.webkit.messageHandlers.flameferretAdguard;
const isTopFrame = window === window.top;

if (bridge && !isTopFrame && /^(https?|about|data|blob):/.test(location.href)) {
    const releaseEvents = setupDelayedEventDispatcher(1000);
    bridge.postMessage({ type: 'lookup', url: String(location.href) })
        .then((configuration) => applyCosmetics(configuration))
        .catch(() => {})
        .finally(() => releaseEvents());
}
