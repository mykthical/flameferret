// Evaluated natively in a JavaScriptCore context to turn scriptlet rules into page code.
import { scriptlets } from '@adguard/scriptlets';

globalThis.__flameferretScriptletCode = (name, args) => {
    try {
        return scriptlets.invoke({
            engine: 'safari-extension',
            name,
            args: args || [],
            version: '4.3.1',
            verbose: false,
        }) || '';
    } catch (e) {
        return '';
    }
};
