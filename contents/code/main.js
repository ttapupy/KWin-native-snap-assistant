const MAXIMIZE_AREA = (typeof KWin !== "undefined" && KWin.MaximizeArea !== undefined)
    ? KWin.MaximizeArea
    : 2;

let pending = null;
let ignoreTile = false;
let overviewRequested = false;
const pointerSnapIds = {};

function windowId(window) {
    return String(window.internalId);
}

function markPointerSnap(window) {
    pointerSnapIds[windowId(window)] = true;
}

function consumePointerSnap(window) {
    const id = windowId(window);
    if (!pointerSnapIds[id]) {
        return false;
    }
    delete pointerSnapIds[id];
    return true;
}

function isPointerSnap(window) {
    return !!pointerSnapIds[windowId(window)];
}

function approx(a, b, epsilon) {
    return Math.abs(a - b) <= epsilon;
}

function halfSideFromTile(window) {
    const tile = window.tile;
    if (!tile || !tile.relativeGeometry) {
        return null;
    }
    const r = tile.relativeGeometry;
    if (!approx(r.width, 0.5, 0.08) || !approx(r.height, 1.0, 0.08)) {
        return null;
    }
    if (approx(r.x, 0, 0.08)) {
        return "left";
    }
    if (approx(r.x, 0.5, 0.08)) {
        return "right";
    }
    return null;
}

function halfSideFromGeometry(window) {
    const area = workspace.clientArea(MAXIMIZE_AREA, window);
    const geo = window.frameGeometry;
    if (!area || !geo) {
        return null;
    }
    const halfWidth = area.width / 2;
    if (!approx(geo.y, area.y, 24) || !approx(geo.height, area.height, 24)) {
        return null;
    }
    if (!approx(geo.width, halfWidth, 48)) {
        return null;
    }
    if (approx(geo.x, area.x, 24)) {
        return "left";
    }
    if (approx(geo.x, area.x + halfWidth, 24)) {
        return "right";
    }
    return null;
}

function halfSide(window) {
    return halfSideFromTile(window) || halfSideFromGeometry(window);
}

function isCandidate(window) {
    return window
        && !window.deleted
        && window.normalWindow
        && !window.skipSwitcher
        && !window.minimized
        && !window.fullScreen;
}

function isOnCurrentDesktop(window) {
    if (window.onAllDesktops) {
        return true;
    }
    const desktops = window.desktops;
    if (!desktops || desktops.length === 0) {
        return true;
    }
    const current = workspace.currentDesktop;
    for (let i = 0; i < desktops.length; i++) {
        if (desktops[i] === current) {
            return true;
        }
    }
    return false;
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
    invokeKWinShortcut("Walk Through Windows");
}

function invokeKWinShortcut(name) {
    callDBus(
        "org.kde.kglobalaccel",
        "/component/kwin",
        "org.kde.kglobalaccel.Component",
        "invokeShortcut",
        name
    );
}

function openOverview() {
    if (overviewRequested) {
        return;
    }
    if (workspace.isEffectActive && workspace.isEffectActive("overview")) {
        overviewRequested = true;
        return;
    }
    overviewRequested = true;
    print("snap-assist: opening overview");
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
    overviewRequested = false;
}

function startAssist(window, side, fromPointer) {
    const alreadyPending = pending && pending.source === window && pending.side === side;
    if (!alreadyPending) {
        if (!hasOtherWindows(window)) {
            print("snap-assist: no other windows after tiling", window.caption);
            cancelPending();
            return;
        }
        pending = { source: window, side: side };
        print("snap-assist: start", side, fromPointer ? "pointer" : "keyboard", window.caption);
        if (!fromPointer) {
            openTabBox();
        }
    }

    if (fromPointer) {
        openOverview();
    }
}

function onHalfTile(window, fromPointer) {
    if (ignoreTile || !window || window.deleted || !window.normalWindow) {
        return;
    }

    const side = halfSide(window);
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

    print("snap-assist: tiled opposite", opposite, window.caption);

    if (workspace.isEffectActive && workspace.isEffectActive("overview")) {
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
    if (!isCandidate(window) || !isOnCurrentDesktop(window)) {
        return;
    }
    if (halfSide(window) === (pending.side === "left" ? "right" : "left")) {
        cancelPending();
        return;
    }
    tileSelected(window);
}

function trackWindow(window) {
    if (!window || window.deleted) {
        return;
    }

    window.interactiveMoveResizeStarted.connect(function () {
        markPointerSnap(window);
    });
    window.tileChanged.connect(function () {
        if (window.move || window.resize) {
            return;
        }
        onHalfTile(window, isPointerSnap(window));
        consumePointerSnap(window);
    });
    window.interactiveMoveResizeFinished.connect(function () {
        onHalfTile(window, true);
        consumePointerSnap(window);
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

print("snap-assist: loaded, tracking", existing.length, "windows");
