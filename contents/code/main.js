const QUICK_TILE_NONE = 0;
const QUICK_TILE_LEFT = 1;
const QUICK_TILE_RIGHT = 2;

let pending = null;
let ignoreTile = false;

function halfSide(mode) {
    const value = Number(mode);
    if (value === QUICK_TILE_LEFT) {
        return "left";
    }
    if (value === QUICK_TILE_RIGHT) {
        return "right";
    }
    return null;
}

function isCandidate(window) {
    return window
        && window.normalWindow
        && !window.specialWindow
        && !window.skipSwitcher
        && !window.minimized
        && !window.fullScreen;
}

function isOnCurrentDesktop(window) {
    if (!window.desktops || window.desktops.length === 0) {
        return true;
    }
    return window.desktops.indexOf(workspace.currentDesktop) !== -1;
}

function hasOtherWindows(source) {
    const windows = workspace.windowList();
    for (let i = 0; i < windows.length; i++) {
        const window = windows[i];
        if (window !== source && isCandidate(window) && isOnCurrentDesktop(window)) {
            return true;
        }
    }
    return false;
}

function openTabBox() {
    // Plasma 6: TabBox is not a Workspace scripting slot. The supported way
    // to invoke the same "Walk Through Windows" action as Alt+Tab/Meta+Tab is
    // KGlobalAccel on the kwin component. KWin only *shows* TabBox when a
    // modifier from that shortcut is currently held; otherwise it activates
    // the next window immediately (KDEOneStepThroughWindows).
    callDBus(
        "org.kde.kglobalaccel",
        "/component/kwin",
        "org.kde.kglobalaccel.Component",
        "invokeShortcut",
        "Walk Through Windows"
    );
}

function openOverview() {
    if (workspace.isEffectActive("overview")) {
        return;
    }
    callDBus(
        "org.kde.KWin",
        "/Effects",
        "org.kde.kwin.Effects",
        "toggleEffect",
        "overview"
    );
}

function cancelPending() {
    pending = null;
}

function startAssist(window, side, fromPointer) {
    if (pending && pending.source === window && pending.side === side) {
        return;
    }
    if (!hasOtherWindows(window)) {
        cancelPending();
        return;
    }

    pending = { source: window, side: side };

    if (fromPointer) {
        // Mouse snap: modifiers are not held, so TabBox will not stay open.
        openOverview();
    } else {
        openTabBox();
    }
}

function onHalfTile(window, fromPointer) {
    if (ignoreTile || !isCandidate(window)) {
        return;
    }

    const side = halfSide(window.quickTileMode);
    if (!side) {
        if (pending && pending.source === window) {
            cancelPending();
        }
        return;
    }

    startAssist(window, side, fromPointer);
}

function tileSelected(window) {
    const source = pending.source;
    const opposite = pending.side === "left" ? "right" : "left";
    cancelPending();

    if (source && source.output && window.output !== source.output) {
        window.output = source.output;
    }

    ignoreTile = true;
    workspace.activeWindow = window;
    if (opposite === "left") {
        workspace.slotWindowQuickTileLeft();
    } else {
        workspace.slotWindowQuickTileRight();
    }
    ignoreTile = false;

    if (workspace.isEffectActive("overview")) {
        callDBus(
            "org.kde.KWin",
            "/Effects",
            "org.kde.kwin.Effects",
            "toggleEffect",
            "overview"
        );
    }
}

function onWindowActivated(window) {
    if (!pending || !window || window === pending.source) {
        return;
    }
    if (!isCandidate(window)) {
        return;
    }
    if (halfSide(window.quickTileMode) === (pending.side === "left" ? "right" : "left")) {
        cancelPending();
        return;
    }
    tileSelected(window);
}

function trackWindow(window) {
    window.quickTileModeChanged.connect(function () {
        if (window.move || window.resize) {
            return;
        }
        onHalfTile(window, false);
    });
    window.interactiveMoveResizeFinished.connect(function () {
        onHalfTile(window, true);
    });
    window.closed.connect(function () {
        if (pending && pending.source === window) {
            cancelPending();
        }
    });
}

workspace.windowActivated.connect(onWindowActivated);
workspace.windowAdded.connect(trackWindow);

const existing = workspace.windowList();
for (let i = 0; i < existing.length; i++) {
    trackWindow(existing[i]);
}

print("snap-assist: loaded");
