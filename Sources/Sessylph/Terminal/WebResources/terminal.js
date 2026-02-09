// terminal.js — xterm.js bridge for Sessylph
// Communicates with Swift via window.webkit.messageHandlers

let term;
let fitAddon;
let canvasAddon;
let webLinksAddon;
let unicode11Addon;
let lastBracketedPasteMode = false;
let pendingWrites = [];
let writeScheduled = false;

// xterm.js measures character dimensions via Canvas measureText(), but some fonts
// report different advance widths through Canvas API vs CSS/DOM layout. This causes
// the grid cell width to not match actual rendered character width (visible as gaps
// between characters). This function replaces the Canvas-based measurement strategy
// with a DOM-based one to ensure consistency.
function fixCharSizeMismatch() {
    var core = term._core;
    var cs = core && core._charSizeService;
    if (!cs || !cs._measureStrategy) return;

    var strategy = cs._measureStrategy;

    // Replace the measure method with DOM-based measurement
    strategy.measure = function() {
        var opts = term.options;
        var span = document.createElement('span');
        span.style.display = 'inline-block';
        span.style.position = 'absolute';
        span.style.visibility = 'hidden';
        span.style.whiteSpace = 'pre';
        span.style.fontKerning = 'none';
        span.style.fontFamily = opts.fontFamily;
        span.style.fontSize = opts.fontSize + 'px';
        span.textContent = 'W'.repeat(32);
        document.body.appendChild(span);
        var rect = span.getBoundingClientRect();
        var w = rect.width / 32;
        var h = rect.height;
        document.body.removeChild(span);

        // Update the cached result
        if (strategy._result) {
            strategy._result.width = w;
            strategy._result.height = h;
        }
        return { width: w, height: h };
    };
}

// Ensures font family names with spaces are properly quoted for Canvas API.
// Canvas ctx.font uses CSS font shorthand where unquoted multi-word names fail.
function quoteFontFamily(family) {
    if (!family) return 'monospace';
    // Split on commas, quote each part if needed, rejoin
    return family.split(',').map(function(f) {
        f = f.trim();
        if (!f) return '';
        // Already quoted or a generic keyword — leave as-is
        if (/^["']/.test(f) || /^(monospace|sans-serif|serif|cursive|fantasy|system-ui)$/i.test(f)) {
            return f;
        }
        return '"' + f + '"';
    }).filter(Boolean).join(', ');
}

function initTerminal(config) {
    var fontFamily = quoteFontFamily(config.fontFamily);
    term = new Terminal({
        fontFamily: fontFamily,
        fontSize: config.fontSize || 13,
        fontWeight: 'normal',
        fontWeightBold: 'bold',
        letterSpacing: 0,
        lineHeight: 1,
        theme: {
            background: config.background || '#ffffff',
            foreground: config.foreground || '#000000',
            cursor: config.cursor || '#000000',
            selectionBackground: 'rgba(0, 120, 215, 0.3)',
        },
        allowProposedApi: true,
        macOptionIsMeta: true,
        scrollback: 10000,
        convertEol: false,
        cursorBlink: true,
    });

    // Fit addon — auto-resize to container
    fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);

    // Web links addon — clickable URLs
    webLinksAddon = new WebLinksAddon.WebLinksAddon(function(_event, uri) {
        window.webkit.messageHandlers.openURL.postMessage(uri);
    });
    term.loadAddon(webLinksAddon);

    // Unicode 11 addon — better CJK/emoji widths
    unicode11Addon = new Unicode11Addon.Unicode11Addon();
    term.loadAddon(unicode11Addon);
    term.unicode.activeVersion = '11';

    // Open terminal in the DOM
    term.open(document.getElementById('terminal'));

    // Try GPU-accelerated renderers for customGlyphs support (draws powerline
    // symbols U+E0B0–E0B7 as vector graphics regardless of font support).
    // WebGL > Canvas > DOM renderer fallback chain.
    var gpuRenderer = false;
    try {
        var wgl = new WebglAddon.WebglAddon();
        wgl.onContextLoss(function() { wgl.dispose(); });
        term.loadAddon(wgl);
        gpuRenderer = true;
    } catch (e) {
        try {
            canvasAddon = new CanvasAddon.CanvasAddon();
            term.loadAddon(canvasAddon);
            gpuRenderer = true;
        } catch (e2) {
            // Falls back to DOM renderer
        }
    }

    // Fix Canvas vs DOM font measurement mismatch.
    // xterm.js charSizeService uses Canvas measureText() for cell width, but some fonts
    // (e.g. Comic Code) report different advance widths via Canvas API vs DOM layout.
    // Patch to use DOM-measured values so the grid cell width matches actual rendering.
    fixCharSizeMismatch();

    fitAddon.fit();

    // Wire up events to Swift
    term.onData(function(data) {
        window.webkit.messageHandlers.ptyInput.postMessage(data);
    });

    term.onBinary(function(data) {
        window.webkit.messageHandlers.ptyBinary.postMessage(btoa(data));
    });

    term.onTitleChange(function(title) {
        window.webkit.messageHandlers.titleChange.postMessage(title);
    });

    term.onResize(function(size) {
        window.webkit.messageHandlers.resize.postMessage({
            cols: size.cols,
            rows: size.rows
        });
    });

    // Auto-copy on selection
    term.onSelectionChange(function() {
        if (term.hasSelection()) {
            var text = term.getSelection();
            window.webkit.messageHandlers.selectionCopy.postMessage(text);
        }
    });

    // Track bracketed paste mode changes
    term.onWriteParsed(function() {
        var mode = term.modes.bracketedPasteMode;
        if (mode !== lastBracketedPasteMode) {
            lastBracketedPasteMode = mode;
            window.webkit.messageHandlers.modeChange.postMessage({
                bracketedPaste: mode
            });
        }
    });

    // Resize observer for container size changes
    new ResizeObserver(function() {
        fitAddon.fit();
    }).observe(document.getElementById('terminal'));

    // Focus
    term.focus();

    // Report ready
    window.webkit.messageHandlers.ready.postMessage({
        cols: term.cols,
        rows: term.rows
    });
}

// Called from Swift to write PTY output data (base64 encoded)
function writePtyData(base64) {
    var binary = atob(base64);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
    }
    term.write(bytes);
}

// Called from Swift to update theme
function updateTheme(theme) {
    term.options.theme = theme;
    document.body.style.background = theme.background || '#ffffff';
    document.getElementById('terminal').style.background = theme.background || '#ffffff';
}

// Called from Swift to update font
function updateFont(family, size) {
    term.options.fontFamily = quoteFontFamily(family);
    term.options.fontSize = size;
    setTimeout(function() { fitAddon.fit(); }, 0);
}

// Called from Swift to scroll to bottom
function scrollToBottom() {
    term.scrollToBottom();
}

// Called from Swift to feed text directly (e.g. error messages before pty starts)
function feedText(text) {
    term.write(text);
}

// Called from Swift to focus the terminal
function focusTerminal() {
    term.focus();
}

// Called from Swift to get bracketed paste mode
function getBracketedPasteMode() {
    return term.modes.bracketedPasteMode;
}
