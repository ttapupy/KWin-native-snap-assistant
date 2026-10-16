import QtQuick
import QtQuick.Window
import org.kde.kwin
import org.kde.kirigami as Kirigami

Item {
    id: root

    // ═══════════════════════════════════════════════════════════════════════
    //  CONSTANTS & TIMINGS
    // ═══════════════════════════════════════════════════════════════════════

    readonly property int maximizeArea:              2
    readonly property int pointerPickerDelayMs:      200
    readonly property int keyboardPickerDelayMs:     120
    readonly property int refocusDelayMs:            60
    readonly property int chainDelayMs:              320
    readonly property int pointerGeometryDebounceMs: 120
    readonly property real zoneTolerance:            0.08
    readonly property real geoMatchTolerance:        0.06

    // Canonical zone templates for geometry matching fallback
    readonly property var knownZones: [
        // ── Full-height vertical splits ──
        { x: 0,     y: 0, width: 0.5,   height: 1.0 },   // left half
        { x: 0.5,   y: 0, width: 0.5,   height: 1.0 },   // right half
        // Thirds (ultrawide / 3-column)
        { x: 0,     y: 0, width: 0.333, height: 1.0 },   // left third
        { x: 0.333, y: 0, width: 0.334, height: 1.0 },   // center third
        { x: 0.667, y: 0, width: 0.333, height: 1.0 },   // right third
        // Asymmetric splits (70/30, 2/3 + 1/3)
        { x: 0,     y: 0, width: 0.667, height: 1.0 },   // left 2/3
        { x: 0.667, y: 0, width: 0.333, height: 1.0 },   // right 1/3
        { x: 0,     y: 0, width: 0.333, height: 1.0 },   // left 1/3
        { x: 0.333, y: 0, width: 0.667, height: 1.0 },   // right 2/3
        // Center focus (25 / 50 / 25)
        { x: 0,     y: 0, width: 0.25,  height: 1.0 },
        { x: 0.25,  y: 0, width: 0.50,  height: 1.0 },
        { x: 0.75,  y: 0, width: 0.25,  height: 1.0 },

        // ── Full-width horizontal splits (portrait screens) ──
        { x: 0, y: 0,     width: 1.0, height: 0.5 },     // top half
        { x: 0, y: 0.5,   width: 1.0, height: 0.5 },     // bottom half
        { x: 0, y: 0,     width: 1.0, height: 0.333 },   // top third
        { x: 0, y: 0.333, width: 1.0, height: 0.334 },   // middle third
        { x: 0, y: 0.667, width: 1.0, height: 0.333 },   // bottom third

        // ── Quarters (4 quadrants) ──
        { x: 0,   y: 0,   width: 0.5, height: 0.5 },     // top-left
        { x: 0.5, y: 0,   width: 0.5, height: 0.5 },     // top-right
        { x: 0,   y: 0.5, width: 0.5, height: 0.5 },     // bottom-left
        { x: 0.5, y: 0.5, width: 0.5, height: 0.5 }      // bottom-right
    ]

    // ═══════════════════════════════════════════════════════════════════════
    //  STATE & CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════

    // pending: { source: Window, sourceZone: rect, currentZone: rect, emptyZones: [], totalZones: int }
    property var pending: null
    property bool ignoreTile: false
    property var pointerSnapIds: ({})

    property var config: ({
        skipPickerOnKeyboardSnap:    false,
        closePickerOnClickOutside:   true,
        suppressPickerWhenAllFilled: true,
        enableMultiZoneChaining:     true,
        autoSelectSingleCandidate:   false,
        showNumberShortcuts:         true,
        showWindowIcons:             true,
        showCloseButtonOnHover:      true,
        animationSpeedMs:            220
    })

    // ═══════════════════════════════════════════════════════════════════════
    //  TIMERS
    // ═══════════════════════════════════════════════════════════════════════

    Timer {
        id: pickerTimer
        interval: root.pointerPickerDelayMs
        repeat: false
        onTriggered: root.showPicker()
    }

    Timer {
        id: keyboardPickerTimer
        interval: root.keyboardPickerDelayMs
        repeat: false
        onTriggered: root.showPicker()
    }

    Timer {
        id: refocusTimer
        interval: root.refocusDelayMs
        repeat: false
        property var target: null
        onTriggered: {
            root.focusWindow(target);
            root.ignoreTile = false;
        }
    }

    Timer {
        id: chainTimer
        interval: root.chainDelayMs
        repeat: false
        onTriggered: root.chainNextZone()
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  UTILITIES & CANDIDATE MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    function windowId(w)        { return String(w ? w.internalId : ""); }
    function hasPointerSnap(w)  { return !!w && !!root.pointerSnapIds[windowId(w)]; }
    function markPointerSnap(w) { if (w) root.pointerSnapIds[windowId(w)] = true; }
    function clearPointerSnap(w){ if (w) delete root.pointerSnapIds[windowId(w)]; }
    function approx(a, b, eps)  { return Math.abs(a - b) <= eps; }
    function allWindows()       { return Workspace.stackingOrder; }

    function focusWindow(w) {
        if (!w || w.deleted) return;
        Workspace.raiseWindow(w);
        Workspace.activeWindow = w;
    }

    function isCandidate(w) {
        return w && !w.deleted && w.normalWindow
            && !w.skipSwitcher && !w.fullScreen;
    }

    function isOnCurrentDesktop(w) {
        if (w.onAllDesktops) return true;
        var desktops = w.desktops;
        if (!desktops || desktops.length === 0) return true;
        var current = Workspace.currentDesktop;
        for (var i = 0; i < desktops.length; i++) {
            if (desktops[i] === current) return true;
        }
        return false;
    }

    function isPartialZone(zone) {
        return zone && (zone.width * zone.height) < 0.92;
    }

    function sameZone(z1, z2) {
        if (!z1 || !z2) return false;
        var eps = 0.03;
        return approx(z1.x, z2.x, eps) &&
               approx(z1.y, z2.y, eps) &&
               approx(z1.width, z2.width, eps) &&
               approx(z1.height, z2.height, eps);
    }

    function zoneLabel(zone) {
        if (!zone) return "Zone";
        var t = root.zoneTolerance;
        // Full height
        if (approx(zone.height, 1.0, t)) {
            if (approx(zone.width, 0.5, t))
                return approx(zone.x, 0, t) ? "Left Half" : "Right Half";
            if (approx(zone.width, 0.333, 0.05)) {
                if (approx(zone.x, 0, t)) return "Left Third";
                if (approx(zone.x, 0.333, 0.05)) return "Center Third";
                return "Right Third";
            }
            if (approx(zone.width, 0.667, 0.05))
                return approx(zone.x, 0, t) ? "Left ⅔" : "Right ⅔";
            if (approx(zone.width, 0.25, 0.05))
                return approx(zone.x, 0, t) ? "Left Column" : "Right Column";
            if (approx(zone.width, 0.5, 0.05))
                return "Center Column";
        }
        // Full width (portrait)
        if (approx(zone.width, 1.0, t)) {
            if (approx(zone.height, 0.5, t))
                return approx(zone.y, 0, t) ? "Top Half" : "Bottom Half";
            if (approx(zone.height, 0.333, 0.05)) {
                if (approx(zone.y, 0, t)) return "Top Third";
                if (approx(zone.y, 0.333, 0.05)) return "Middle Third";
                return "Bottom Third";
            }
        }
        // Quarters
        if (approx(zone.width, 0.5, t) && approx(zone.height, 0.5, t)) {
            var v = approx(zone.y, 0, t) ? "Top" : "Bottom";
            var h = approx(zone.x, 0, t) ? "Left" : "Right";
            return v + "-" + h + " Quarter";
        }
        return Math.round(zone.width * 100) + "% × " + Math.round(zone.height * 100) + "%";
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ZONE DETECTION
    // ═══════════════════════════════════════════════════════════════════════

    function detectWindowZone(w) {
        if (!w) return null;

        // 1. KWin native tile
        var tile = w.tile;
        if (tile && tile.relativeGeometry) {
            var r = tile.relativeGeometry;
            return { x: r.x, y: r.y, width: r.width, height: r.height };
        }

        // 2. Geometry matching fallback
        var area = Workspace.clientArea(root.maximizeArea, w);
        var geo  = w.frameGeometry;
        if (!area || !geo || area.width <= 0 || area.height <= 0) return null;

        var relX = (geo.x - area.x) / area.width;
        var relY = (geo.y - area.y) / area.height;
        var relW = geo.width  / area.width;
        var relH = geo.height / area.height;

        var bestZone = null;
        var bestDist = Infinity;
        var maxTol   = root.geoMatchTolerance;

        for (var i = 0; i < knownZones.length; i++) {
            var z  = knownZones[i];
            var dx = Math.abs(relX - z.x);
            var dy = Math.abs(relY - z.y);
            var dw = Math.abs(relW - z.width);
            var dh = Math.abs(relH - z.height);
            if (dx > maxTol || dy > maxTol || dw > maxTol || dh > maxTol)
                continue;
            var dist = dx + dy + dw + dh;
            if (dist < bestDist) {
                bestDist = dist;
                bestZone = z;
            }
        }
        return bestZone;
    }

    function findOccupiedZones(refWindow) {
        var result  = [];
        var windows = allWindows();
        for (var i = 0; i < windows.length; i++) {
            var w = windows[i];
            if (!w || w.deleted || w.minimized) continue;
            if (!w.normalWindow || w.skipSwitcher || w.fullScreen) continue;
            if (!isOnCurrentDesktop(w)) continue;
            if (refWindow && refWindow.output && w.output && w.output !== refWindow.output)
                continue;

            var zone = detectWindowZone(w);
            if (zone && isPartialZone(zone)) {
                result.push({ window: w, zone: zone });
            }
        }
        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  EMPTY ZONE CALCULATION (Sweep-line Complement)
    // ═══════════════════════════════════════════════════════════════════════

    function computeEmptyZones(occupied) {
        if (occupied.length === 0) {
            return [{ x: 0, y: 0, width: 1.0, height: 1.0 }];
        }
        var eps = 0.01;

        // Unique x-coordinates in integer fixed-point
        var xSet = {};
        xSet[0] = true;
        xSet[10000] = true;
        for (var i = 0; i < occupied.length; i++) {
            var left  = Math.max(0, Math.min(10000, Math.round(occupied[i].x * 10000)));
            var right = Math.max(0, Math.min(10000, Math.round((occupied[i].x + occupied[i].width) * 10000)));
            xSet[left]  = true;
            xSet[right] = true;
        }
        var xs = Object.keys(xSet).map(Number).sort(function(a, b) { return a - b; });

        var rects = [];

        // For each vertical strip, find unoccupied y intervals
        for (var xi = 0; xi < xs.length - 1; xi++) {
            var x1 = xs[xi] / 10000;
            var x2 = xs[xi + 1] / 10000;
            if (x2 - x1 < eps) continue;

            var yRanges = [];
            for (var j = 0; j < occupied.length; j++) {
                var oz = occupied[j];
                if (oz.x < x2 - eps && oz.x + oz.width > x1 + eps) {
                    yRanges.push({ y1: oz.y, y2: oz.y + oz.height });
                }
            }
            yRanges.sort(function(a, b) { return a.y1 - b.y1; });

            // Merge overlapping intervals
            var merged = [];
            for (var m = 0; m < yRanges.length; m++) {
                if (merged.length > 0 && yRanges[m].y1 <= merged[merged.length - 1].y2 + eps) {
                    merged[merged.length - 1].y2 = Math.max(merged[merged.length - 1].y2, yRanges[m].y2);
                } else {
                    merged.push({ y1: yRanges[m].y1, y2: yRanges[m].y2 });
                }
            }

            // Gaps
            var cy = 0;
            for (var g = 0; g < merged.length; g++) {
                if (merged[g].y1 > cy + eps) {
                    rects.push({ x: x1, y: cy, width: x2 - x1, height: merged[g].y1 - cy });
                }
                cy = Math.max(cy, merged[g].y2);
            }
            if (cy < 1.0 - eps) {
                rects.push({ x: x1, y: cy, width: x2 - x1, height: 1.0 - cy });
            }
        }

        return mergeAdjacentRects(rects);
    }

    function mergeAdjacentRects(rects) {
        if (rects.length <= 1) return rects;
        var eps = 0.015;
        var changed = true;
        while (changed) {
            changed = false;
            for (var i = 0; i < rects.length && !changed; i++) {
                for (var j = i + 1; j < rects.length && !changed; j++) {
                    var a = rects[i], b = rects[j];

                    // Vertically adjacent (same column width)
                    if (approx(a.x, b.x, eps) && approx(a.width, b.width, eps)) {
                        if (approx(a.y + a.height, b.y, eps)) {
                            rects[i] = { x: a.x, y: a.y, width: a.width, height: a.height + b.height };
                            rects.splice(j, 1);
                            changed = true;
                        } else if (approx(b.y + b.height, a.y, eps)) {
                            rects[i] = { x: a.x, y: b.y, width: a.width, height: a.height + b.height };
                            rects.splice(j, 1);
                            changed = true;
                        }
                    }

                    // Horizontally adjacent (same row height)
                    if (!changed && approx(a.y, b.y, eps) && approx(a.height, b.height, eps)) {
                        if (approx(a.x + a.width, b.x, eps)) {
                            rects[i] = { x: a.x, y: a.y, width: a.width + b.width, height: a.height };
                            rects.splice(j, 1);
                            changed = true;
                        } else if (approx(b.x + b.width, a.x, eps)) {
                            rects[i] = { x: b.x, y: a.y, width: a.width + b.width, height: a.height };
                            rects.splice(j, 1);
                            changed = true;
                        }
                    }
                }
            }
        }

        // Sort descending by area so primary large zones appear first
        rects.sort(function(a, b) {
            return (b.width * b.height) - (a.width * a.height);
        });
        return rects;
    }

    function collectCandidates(source, excludeList) {
        var excl = excludeList || [];
        var result = [];
        var windows = allWindows();

        // Stacking order descending (most recently active first)
        for (var i = windows.length - 1; i >= 0; i--) {
            var w = windows[i];
            if (!w || w === source || !isCandidate(w) || !isOnCurrentDesktop(w))
                continue;
            if (source && source.output && w.output && w.output !== source.output)
                continue;

            var excluded = false;
            for (var j = 0; j < excl.length; j++) {
                if (excl[j] === w) { excluded = true; break; }
            }
            if (excluded) continue;

            result.push(w);
        }
        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  CONFIG LOADER
    // ═══════════════════════════════════════════════════════════════════════

    function loadConfig() {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 200 || xhr.status === 0) {
                    try {
                        var parsed = JSON.parse(xhr.responseText);
                        var keys = Object.keys(parsed);
                        for (var i = 0; i < keys.length; i++) {
                            var k = keys[i];
                            if (root.config[k] !== undefined) {
                                root.config[k] = parsed[k];
                            }
                        }
                        console.log("snap-assist: config loaded successfully");
                    } catch (e) {
                        console.log("snap-assist: config parse error:", e);
                    }
                }
            }
        };
        try {
            xhr.open("GET", Qt.resolvedUrl("../config/config.json"));
            xhr.send();
        } catch (e) {
            console.log("snap-assist: config xhr error:", e);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ASSIST FLOW CONTROLLER
    // ═══════════════════════════════════════════════════════════════════════

    function cancelPending() {
        root.pending = null;
        hidePicker();
        chainTimer.stop();
        pickerTimer.stop();
        keyboardPickerTimer.stop();
        root.ignoreTile = false;
    }

    function hidePicker() {
        pickerTimer.stop();
        keyboardPickerTimer.stop();
        picker.hide();
        picker.selectedIndex = -1;
        picker.candidates = [];
    }

    function onWindowSnapped(window, fromPointer) {
        if (root.ignoreTile || !window || window.deleted || !window.normalWindow)
            return;

        var zone = detectWindowZone(window);
        if (!zone || !isPartialZone(zone)) {
            if (root.pending && root.pending.source === window) {
                cancelPending();
            }
            return;
        }

        startAssist(window, zone, fromPointer);
    }

    function startAssist(window, sourceZone, fromPointer) {
        // If already assisting for this window in the EXACT same zone, don't restart
        if (root.pending && root.pending.source === window && sameZone(root.pending.sourceZone, sourceZone)) {
            if (fromPointer && !picker.visible && !pickerTimer.running) {
                pickerTimer.restart();
            }
            return;
        }

        // If window moved to a DIFFERENT zone while assist was open, restart assist for the new zone
        if (root.pending && root.pending.source === window && !sameZone(root.pending.sourceZone, sourceZone)) {
            hidePicker();
            root.pending = null;
        }

        var occupiedData    = findOccupiedZones(window);
        var occupiedZones   = occupiedData.map(function(o) { return o.zone; });
        var occupiedWindows = occupiedData.map(function(o) { return o.window; });

        var emptyZones = computeEmptyZones(occupiedZones);

        if (emptyZones.length === 0 && root.config.suppressPickerWhenAllFilled) {
            console.log("snap-assist: all zones filled on display, skipping assist");
            cancelPending();
            return;
        }

        var candidates = collectCandidates(window, occupiedWindows);
        if (candidates.length === 0) {
            console.log("snap-assist: no candidate windows available");
            cancelPending();
            return;
        }

        var targetZone = emptyZones.length > 0 ? emptyZones[0] : null;
        root.pending = {
            source:      window,
            sourceZone:  sourceZone,
            currentZone: targetZone,
            emptyZones:  emptyZones,
            totalZones:  emptyZones.length,
            fromPointer: fromPointer
        };

        console.log("snap-assist: triggered for", window.caption,
                    "target zone:", zoneLabel(targetZone),
                    "candidates:", candidates.length);

        if (root.config.autoSelectSingleCandidate && candidates.length === 1 && emptyZones.length === 1) {
            console.log("snap-assist: auto-selecting single candidate", candidates[0].caption);
            tileSelected(candidates[0]);
            return;
        }

        if (fromPointer) {
            pickerTimer.restart();
        } else {
            if (root.config.skipPickerOnKeyboardSnap) {
                cancelPending();
                return;
            }
            keyboardPickerTimer.restart();
        }
    }

    function showPicker() {
        if (!root.pending || !root.pending.currentZone) {
            cancelPending();
            return;
        }

        var source = root.pending.source;
        var occupiedData    = findOccupiedZones(source);
        var occupiedZones   = occupiedData.map(function(o) { return o.zone; });
        var occupiedWindows = occupiedData.map(function(o) { return o.window; });
        var emptyZones      = computeEmptyZones(occupiedZones);

        if (emptyZones.length === 0 && root.config.suppressPickerWhenAllFilled) {
            cancelPending();
            return;
        }

        var candidates = collectCandidates(source, occupiedWindows);
        if (candidates.length === 0) {
            cancelPending();
            return;
        }

        var targetZone = emptyZones.length > 0 ? emptyZones[0] : root.pending.currentZone;
        root.pending.currentZone = targetZone;
        root.pending.emptyZones  = emptyZones;

        // Position picker window over the source window's display work area
        var area = Workspace.clientArea(root.maximizeArea, source);

        // Align picker with physical screen
        if (source && source.output) {
            var screens = Qt.application.screens;
            for (var s = 0; s < screens.length; s++) {
                if (screens[s].name === source.output.name) {
                    picker.screen = screens[s];
                    break;
                }
            }
        }

        picker.x      = area.x;
        picker.y      = area.y;
        picker.width  = area.width;
        picker.height = area.height;

        picker.panelRelX      = targetZone.x;
        picker.panelRelY      = targetZone.y;
        picker.panelRelWidth  = targetZone.width;
        picker.panelRelHeight = targetZone.height;

        picker.candidates     = candidates;
        picker.selectedIndex  = 0;
        picker.zoneText       = zoneLabel(targetZone);
        picker.remainingZones = emptyZones.length;

        picker.showNormal();
        picker.requestActivate();

        console.log("snap-assist: picker active for", picker.zoneText);
    }

    function tileSelected(window) {
        if (!root.pending || !window) return;

        var source       = root.pending.source;
        var targetZone   = root.pending.currentZone;
        var chainEnabled = root.config.enableMultiZoneChaining;

        hidePicker();

        if (!targetZone) { cancelPending(); return; }

        if (source && source.output && window.output !== source.output) {
            window.output = source.output;
        }

        tileWindowToZone(window, targetZone);

        console.log("snap-assist: tiled window", window.caption, "into", zoneLabel(targetZone));

        if (chainEnabled) {
            chainTimer.restart();
        } else {
            root.pending = null;
            refocusTimer.target = window;
            refocusTimer.restart();
        }
    }

    function chainNextZone() {
        if (!root.pending) return;

        var source          = root.pending.source;
        var occupiedData    = findOccupiedZones(source);
        var occupiedZones   = occupiedData.map(function(o) { return o.zone; });
        var occupiedWindows = occupiedData.map(function(o) { return o.window; });
        var emptyZones      = computeEmptyZones(occupiedZones);

        if (emptyZones.length === 0) {
            console.log("snap-assist: all zones filled, sequence complete");
            root.pending    = null;
            root.ignoreTile = false;
            return;
        }

        var candidates = collectCandidates(source, occupiedWindows);
        if (candidates.length === 0) {
            console.log("snap-assist: no remaining candidates for sequence");
            root.pending    = null;
            root.ignoreTile = false;
            return;
        }

        if (root.config.autoSelectSingleCandidate && candidates.length === 1 && emptyZones.length === 1) {
            root.pending.currentZone = emptyZones[0];
            root.pending.emptyZones  = emptyZones;
            tileSelected(candidates[0]);
            return;
        }

        root.pending.currentZone = emptyZones[0];
        root.pending.emptyZones  = emptyZones;
        showPicker();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  TILING EXECUTION
    // ═══════════════════════════════════════════════════════════════════════

    function tileWindowToZone(window, zone) {
        var area = Workspace.clientArea(root.maximizeArea, window);
        var t    = root.zoneTolerance;

        root.ignoreTile = true;

        if (window.minimized) {
            window.minimized = false;
        }
        focusWindow(window);

        var tiled = false;

        // 1. Standard quick-tile shortcuts for halves
        if (!tiled && approx(zone.y, 0, t) && approx(zone.height, 1.0, t)) {
            if (approx(zone.x, 0, t) && approx(zone.width, 0.5, t)) {
                Workspace.slotWindowQuickTileLeft();
                tiled = true;
            } else if (approx(zone.x, 0.5, t) && approx(zone.width, 0.5, t)) {
                Workspace.slotWindowQuickTileRight();
                tiled = true;
            }
        }

        // Horizontal halves (top / bottom)
        if (!tiled && approx(zone.x, 0, t) && approx(zone.width, 1.0, t)) {
            if (approx(zone.y, 0, t) && approx(zone.height, 0.5, t)) {
                Workspace.slotWindowQuickTileTop();
                tiled = true;
            } else if (approx(zone.y, 0.5, t) && approx(zone.height, 0.5, t)) {
                Workspace.slotWindowQuickTileBottom();
                tiled = true;
            }
        }

        // Quarters
        if (!tiled && approx(zone.width, 0.5, t) && approx(zone.height, 0.5, t)) {
            if (approx(zone.x, 0, t) && approx(zone.y, 0, t)) {
                Workspace.slotWindowQuickTileTopLeft();
                tiled = true;
            } else if (approx(zone.x, 0.5, t) && approx(zone.y, 0, t)) {
                Workspace.slotWindowQuickTileTopRight();
                tiled = true;
            } else if (approx(zone.x, 0, t) && approx(zone.y, 0.5, t)) {
                Workspace.slotWindowQuickTileBottomLeft();
                tiled = true;
            } else if (approx(zone.x, 0.5, t) && approx(zone.y, 0.5, t)) {
                Workspace.slotWindowQuickTileBottomRight();
                tiled = true;
            }
        }

        // 2. KWin native custom tile matching (if Meta+T layouts defined)
        if (!tiled) {
            try {
                var rootTile = Workspace.rootTile(window.output, Workspace.currentDesktop);
                if (rootTile) {
                    var matchingTile = findMatchingTile(rootTile, zone);
                    if (matchingTile && typeof matchingTile.manage === "function") {
                        matchingTile.manage(window);
                        tiled = true;
                    }
                }
            } catch (e) {
                // Not supported on this KWin version or no tile layout
            }
        }

        // 3. Frame geometry fallback (thirds, asymmetric columns, arbitrary zones)
        if (!tiled) {
            window.frameGeometry = Qt.rect(
                Math.round(area.x + zone.x * area.width),
                Math.round(area.y + zone.y * area.height),
                Math.round(zone.width * area.width),
                Math.round(zone.height * area.height)
            );
        }

        focusWindow(window);
    }

    function findMatchingTile(tileNode, targetZone) {
        if (!tileNode) return null;
        if (tileNode.tiles && tileNode.tiles.length > 0) {
            for (var i = 0; i < tileNode.tiles.length; i++) {
                var found = findMatchingTile(tileNode.tiles[i], targetZone);
                if (found) return found;
            }
            return null;
        }
        if (tileNode.relativeGeometry && sameZone(tileNode.relativeGeometry, targetZone)) {
            return tileNode;
        }
        return null;
    }

    function closeCandidateWindow(w) {
        if (!w || !picker.visible) return;
        w.closeWindow();
        var updated = [];
        for (var i = 0; i < picker.candidates.length; i++) {
            if (picker.candidates[i] !== w) {
                updated.push(picker.candidates[i]);
            }
        }
        picker.candidates = updated;
        if (picker.candidates.length === 0) {
            cancelPending();
        } else if (picker.selectedIndex >= picker.candidates.length) {
            picker.selectedIndex = picker.candidates.length - 1;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  PER-WINDOW TRACKER
    // ═══════════════════════════════════════════════════════════════════════

    Instantiator {
        model: WindowModel {}
        delegate: Item {
            id: windowTracker
            required property var window

            function scheduleGeometryFallback() {
                if (root.hasPointerSnap(windowTracker.window)) {
                    geometryFallbackTimer.restart();
                }
            }

            Timer {
                id: geometryFallbackTimer
                interval: root.pointerGeometryDebounceMs
                repeat: false
                onTriggered: {
                    var w = windowTracker.window;
                    if (!w) return;
                    if (!root.hasPointerSnap(w) || w.move || w.resize) return;
                    console.log("snap-assist: geometry fallback", w.caption);
                    root.onWindowSnapped(w, true);
                    root.clearPointerSnap(w);
                }
            }

            Connections {
                target: windowTracker.window
                ignoreUnknownSignals: true

                function onInteractiveMoveResizeStarted() {
                    var w = windowTracker.window;
                    if (!w) return;
                    geometryFallbackTimer.stop();

                    // If user moves/resizes while picker is up, cleanly cancel
                    if (picker.visible || pickerTimer.running || keyboardPickerTimer.running) {
                        root.cancelPending();
                    }

                    root.markPointerSnap(w);
                }

                function onFrameGeometryChanged() {
                    var w = windowTracker.window;
                    if (!w || w.move || w.resize) return;
                    windowTracker.scheduleGeometryFallback();
                }

                function onTileChanged() {
                    var w = windowTracker.window;
                    if (!w || w.move || w.resize) return;
                    var fromPointer = root.hasPointerSnap(w);
                    geometryFallbackTimer.stop();
                    root.clearPointerSnap(w);
                    root.onWindowSnapped(w, fromPointer);
                }

                function onInteractiveMoveResizeFinished() {
                    var w = windowTracker.window;
                    if (!w) return;
                    windowTracker.scheduleGeometryFallback();
                }

                function onClosed() {
                    geometryFallbackTimer.stop();
                    var w = windowTracker.window;
                    root.clearPointerSnap(w);
                    if (root.pending && root.pending.source === w) {
                        root.cancelPending();
                    }
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  WORKSPACE EVENT HANDLING
    // ═══════════════════════════════════════════════════════════════════════

    Connections {
        target: Workspace

        function onWindowActivated(window) {
            if (!root.pending || root.ignoreTile) return;
            if (picker.visible) {
                if (root.config.closePickerOnClickOutside && window !== root.pending.source) {
                    root.cancelPending();
                }
            }
        }

        function onWindowRemoved(window) {
            if (root.pending && root.pending.source === window) {
                root.cancelPending();
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  WINDOWS 11 STYLE SNAP ASSIST OVERLAY
    // ═══════════════════════════════════════════════════════════════════════

    Window {
        id: picker
        flags: Qt.FramelessWindowHint | Qt.X11BypassWindowManagerHint
        color: "transparent"
        visible: false
        title: "Snap Assist"

        property var    candidates:     []
        property int    selectedIndex:  0
        property real   panelRelX:      0.5
        property real   panelRelY:      0
        property real   panelRelWidth:  0.5
        property real   panelRelHeight: 1.0
        property string zoneText:       ""
        property int    remainingZones: 1

        onVisibleChanged: {
            if (visible) {
                panel.opacity = 0;
                panel.scale   = 0.97;
                entranceAnim.start();
            }
        }

        SystemPalette { id: palette; colorGroup: SystemPalette.Active }

        Shortcut {
            sequence: "Escape"
            enabled: picker.visible
            onActivated: root.cancelPending()
        }

        // Full-screen backdrop click catcher
        MouseArea {
            id: scrimMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {
                if (root.config.closePickerOnClickOutside) {
                    root.cancelPending();
                }
            }
        }

        // Floating acrylic panel inside the vacant zone
        Rectangle {
            id: panel

            // Smooth position/dimension transitions between chained zones
            Behavior on x      { NumberAnimation { duration: root.config.animationSpeedMs; easing.type: Easing.OutCubic } }
            Behavior on y      { NumberAnimation { duration: root.config.animationSpeedMs; easing.type: Easing.OutCubic } }
            Behavior on width  { NumberAnimation { duration: root.config.animationSpeedMs; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: root.config.animationSpeedMs; easing.type: Easing.OutCubic } }

            x:      Math.round(picker.panelRelX * picker.width + 8)
            y:      Math.round(picker.panelRelY * picker.height + 8)
            width:  Math.max(260, Math.round(picker.panelRelWidth * picker.width - 16))
            height: Math.max(200, Math.round(picker.panelRelHeight * picker.height - 16))

            radius: 12
            color:  "#e8181822"
            border.color: "#28ffffff"
            border.width: 1
            clip: true

            // Entrance animation
            ParallelAnimation {
                id: entranceAnim
                NumberAnimation {
                    target: panel; property: "opacity"
                    from: 0; to: 1; duration: root.config.animationSpeedMs
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: panel; property: "scale"
                    from: 0.97; to: 1.0; duration: root.config.animationSpeedMs
                    easing.type: Easing.OutCubic
                }
            }

            // Top gradient sheen (Acrylic reflection effect)
            Rectangle {
                anchors { top: parent.top; left: parent.left; right: parent.right }
                height: 100
                radius: parent.radius
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#14ffffff" }
                    GradientStop { position: 0.8; color: "#04ffffff" }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }

            // ────────── Header ──────────
            Rectangle {
                id: header
                anchors {
                    top: parent.top
                    left: parent.left
                    right: parent.right
                    margins: 14
                }
                height: 58
                radius: 8
                color: "#18ffffff"
                border.color: "#16ffffff"
                border.width: 1

                Row {
                    anchors {
                        left: parent.left
                        right: closePickerBtn.left
                        verticalCenter: parent.verticalCenter
                        leftMargin: 12
                        rightMargin: 8
                    }
                    spacing: 10

                    // Accent icon indicator
                    Rectangle {
                        width: 4
                        height: 28
                        radius: 2
                        color: palette.highlight
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        spacing: 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 14

                        Row {
                            spacing: 8
                            Text {
                                text: "Snap Assist"
                                color: "white"
                                font.pixelSize: 15
                                font.bold: true
                            }

                            // Zone Badge
                            Rectangle {
                                height: 18
                                width: zoneBadgeText.implicitWidth + 12
                                radius: 4
                                color: "#28ffffff"
                                anchors.verticalCenter: parent.verticalCenter

                                Text {
                                    id: zoneBadgeText
                                    anchors.centerIn: parent
                                    text: picker.zoneText
                                    color: "#f0f0f0"
                                    font.pixelSize: 10
                                    font.bold: true
                                }
                            }

                            // Step badge if multi-zone chaining
                            Rectangle {
                                height: 18
                                width: stepBadgeText.implicitWidth + 10
                                radius: 4
                                color: palette.highlight
                                opacity: 0.85
                                visible: picker.remainingZones > 1
                                anchors.verticalCenter: parent.verticalCenter

                                Text {
                                    id: stepBadgeText
                                    anchors.centerIn: parent
                                    text: picker.remainingZones + " zones left"
                                    color: "white"
                                    font.pixelSize: 10
                                    font.bold: true
                                }
                            }
                        }

                        Text {
                            text: "Select a window to fill this area  •  1–9 / Enter  •  Esc cancels"
                            color: "#99ffffff"
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            width: parent.width
                        }
                    }
                }

                // Header close button
                Rectangle {
                    id: closePickerBtn
                    anchors {
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                        rightMargin: 10
                    }
                    width: 28
                    height: 28
                    radius: 6
                    color: closePickerMouse.containsMouse ? "#2affffff" : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: "✕"
                        color: closePickerMouse.containsMouse ? "white" : "#aaffffff"
                        font.pixelSize: 12
                    }

                    MouseArea {
                        id: closePickerMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.cancelPending()
                    }
                }
            }

            // ────────── Candidate Grid ──────────
            GridView {
                id: grid
                anchors {
                    top: header.bottom
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                    margins: 14
                    topMargin: 10
                }
                focus: picker.visible
                clip: true

                // Dynamic columns based on available panel width
                property int columns: Math.max(1, Math.floor((width - 12) / 220))
                cellWidth:  Math.floor((width - 8) / columns)
                cellHeight: Math.min(220, Math.max(135, cellWidth * 0.65))

                model: picker.candidates
                currentIndex: 0
                keyNavigationWraps: true

                onCurrentIndexChanged: picker.selectedIndex = currentIndex
                onModelChanged: currentIndex = 0

                Keys.onEscapePressed: root.cancelPending()
                Keys.onReturnPressed: if (grid.currentItem) root.tileSelected(grid.currentItem.clientWindow)
                Keys.onEnterPressed:  if (grid.currentItem) root.tileSelected(grid.currentItem.clientWindow)
                Keys.onSpacePressed:  if (grid.currentItem) root.tileSelected(grid.currentItem.clientWindow)

                // Quick number shortcuts 1-9
                Keys.onPressed: function(event) {
                    if (root.config.showNumberShortcuts && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
                        var numIdx = event.key - Qt.Key_1;
                        if (numIdx < picker.candidates.length) {
                            root.tileSelected(picker.candidates[numIdx]);
                            event.accepted = true;
                        }
                    }
                }

                // ────────── Candidate Card Delegate ──────────
                delegate: Item {
                    id: cardWrapper
                    width:  grid.cellWidth
                    height: grid.cellHeight

                    property var  clientWindow: modelData
                    property bool isSelected:   index === grid.currentIndex
                    property bool isHovered:    cardMouse.containsMouse
                    property bool isHighlighted: isSelected || isHovered

                    Rectangle {
                        id: card
                        anchors.fill: parent
                        anchors.margins: 6
                        radius: 8

                        color: cardWrapper.isHighlighted ? "#24ffffff" : "#0dffffff"
                        border.color: cardWrapper.isHighlighted ? palette.highlight : "#16ffffff"
                        border.width: cardWrapper.isHighlighted ? 2 : 1

                        scale: cardWrapper.isHighlighted ? 1.02 : 1.0
                        transformOrigin: Item.Center

                        Behavior on color        { ColorAnimation { duration: 120 } }
                        Behavior on border.color { ColorAnimation { duration: 120 } }
                        Behavior on scale        { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

                        Column {
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 6

                            // Card Title Row
                            Row {
                                width: parent.width
                                height: 22
                                spacing: 6

                                // Number badge for fast shortcut
                                Rectangle {
                                    width: 18
                                    height: 18
                                    radius: 4
                                    color: cardWrapper.isHighlighted ? palette.highlight : "#24ffffff"
                                    visible: root.config.showNumberShortcuts && index < 9
                                    anchors.verticalCenter: parent.verticalCenter

                                    Text {
                                        anchors.centerIn: parent
                                        text: String(index + 1)
                                        color: "white"
                                        font.pixelSize: 10
                                        font.bold: true
                                    }
                                }

                                // App Icon
                                Kirigami.Icon {
                                    width: 18
                                    height: 18
                                    anchors.verticalCenter: parent.verticalCenter
                                    source: cardWrapper.clientWindow && cardWrapper.clientWindow.icon
                                                ? cardWrapper.clientWindow.icon
                                                : "preferences-system-windows"
                                    visible: root.config.showWindowIcons
                                }

                                // Window Caption Title
                                Text {
                                    text: cardWrapper.clientWindow ? cardWrapper.clientWindow.caption : ""
                                    color: "white"
                                    elide: Text.ElideRight
                                    font.pixelSize: 11
                                    font.bold: cardWrapper.isHighlighted
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - (root.config.showNumberShortcuts && index < 9 ? 24 : 0)
                                                        - (root.config.showWindowIcons ? 24 : 0)
                                                        - (root.config.showCloseButtonOnHover ? 22 : 0)
                                }
                            }

                            // Live Window Thumbnail
                            Rectangle {
                                width: parent.width
                                height: parent.height - 28
                                radius: 6
                                color: "#06000000"
                                clip: true

                                WindowThumbnail {
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    client: cardWrapper.clientWindow
                                }
                            }
                        }

                        // Close button on card hover (Windows 11 feature)
                        Rectangle {
                            id: cardCloseBtn
                            anchors {
                                top: parent.top
                                right: parent.right
                                margins: 4
                            }
                            width: 20
                            height: 20
                            radius: 4
                            visible: root.config.showCloseButtonOnHover && (cardMouse.containsMouse || closeBtnMouse.containsMouse)
                            color: closeBtnMouse.containsMouse ? "#e81123" : "#33000000"

                            Text {
                                anchors.centerIn: parent
                                text: "✕"
                                color: "white"
                                font.pixelSize: 10
                            }

                            MouseArea {
                                id: closeBtnMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.closeCandidateWindow(cardWrapper.clientWindow)
                            }
                        }

                        // Card Selection Mouse Area
                        MouseArea {
                            id: cardMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: grid.currentIndex = index
                            onClicked: {
                                grid.currentIndex = index;
                                root.tileSelected(cardWrapper.clientWindow);
                            }
                        }
                    }
                }
            }
        } // panel
    } // picker

    // ═══════════════════════════════════════════════════════════════════════
    //  INIT
    // ═══════════════════════════════════════════════════════════════════════

    Component.onCompleted: {
        root.loadConfig();
        console.log("snap-assist: initialized v2.0 (Windows 11-style multi-zone assist)");
    }
}
