import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import org.kde.kwin

Item {
    id: root

    readonly property int maximizeArea: 2
    property var pending: null
    property bool ignoreTile: false
    property var pointerSnapIds: ({})

    DBusCall {
        id: tabBoxCall
        service: "org.kde.kglobalaccel"
        path: "/component/kwin"
        dbusInterface: "org.kde.kglobalaccel.Component"
        method: "invokeShortcut"
        arguments: ["Walk Through Windows"]
        onFailed: console.log("snap-assist: TabBox D-Bus call failed")
    }

    Timer {
        id: pickerTimer
        interval: 200
        repeat: false
        onTriggered: root.showPicker()
    }

    Timer {
        id: refocusTimer
        interval: 50
        repeat: false
        property var target: null
        onTriggered: {
            root.focusWindow(target);
            root.ignoreTile = false;
        }
    }

    Timer {
        id: pickerDiagnosticsTimer
        interval: 100
        repeat: false
        onTriggered: root.logPickerState("after 100 ms")
    }

    function windowId(window) {
        return String(window.internalId);
    }

    function allWindows() {
        return Workspace.stackingOrder;
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
        const area = Workspace.clientArea(root.maximizeArea, window);
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
        const current = Workspace.currentDesktop;
        for (let i = 0; i < desktops.length; i++) {
            if (desktops[i] === current) {
                return true;
            }
        }
        return false;
    }

    function collectCandidates(source) {
        const result = [];
        const windows = allWindows();
        for (let i = windows.length - 1; i >= 0; i--) {
            const window = windows[i];
            if (window !== source && isCandidate(window) && isOnCurrentDesktop(window)) {
                result.push(window);
            }
        }
        return result;
    }

    function focusWindow(window) {
        if (!window || window.deleted) {
            return;
        }
        Workspace.raiseWindow(window);
        Workspace.activeWindow = window;
    }

    function hidePicker() {
        pickerTimer.stop();
        pickerDiagnosticsTimer.stop();
        picker.hide();
        picker.candidates = [];
    }

    function logPickerState(stage) {
        const screenName = picker.screen ? picker.screen.name : "<none>";
        console.log("snap-assist: picker state", stage,
                    "visible=" + picker.visible,
                    "visibility=" + picker.visibility,
                    "active=" + picker.active,
                    "screen=" + screenName,
                    "geometry=" + picker.x + "," + picker.y + " "
                        + picker.width + "x" + picker.height,
                    "candidates=" + picker.candidates.length);
    }

    function cancelPending() {
        root.pending = null;
        hidePicker();
    }

    function tileSelected(window) {
        if (!root.pending || !window) {
            return;
        }
        const source = root.pending.source;
        const opposite = root.pending.side === "left" ? "right" : "left";
        root.pending = null;
        hidePicker();

        if (source && source.output && window.output !== source.output) {
            window.output = source.output;
        }

        root.ignoreTile = true;
        if (window.minimized) {
            window.minimized = false;
        }
        focusWindow(window);
        if (opposite === "left") {
            Workspace.slotWindowQuickTileLeft();
        } else {
            Workspace.slotWindowQuickTileRight();
        }
        focusWindow(window);
        console.log("snap-assist: tiled opposite", opposite, window.caption);
        refocusTimer.target = window;
        refocusTimer.restart();
    }

    function showPicker() {
        if (!root.pending) {
            return;
        }
        const source = root.pending.source;
        const side = root.pending.side;
        const candidates = collectCandidates(source);
        if (candidates.length === 0) {
            console.log("snap-assist: no other windows after tiling", source.caption);
            cancelPending();
            return;
        }

        const area = Workspace.clientArea(root.maximizeArea, source);
        const halfWidth = area.width / 2;
        picker.candidates = candidates;
        picker.x = side === "left" ? area.x + halfWidth : area.x;
        picker.y = area.y;
        picker.width = halfWidth;
        picker.height = area.height;
        picker.showNormal();
        picker.requestActivate();
        console.log("snap-assist: picker", side, candidates.length,
                    Qt.rect(picker.x, picker.y, picker.width, picker.height));
        logPickerState("immediate");
        pickerDiagnosticsTimer.restart();
    }

    function startAssist(window, side, fromPointer) {
        const already = root.pending && root.pending.source === window && root.pending.side === side;
        if (already && fromPointer) {
            if (!picker.visible && !pickerTimer.running) {
                pickerTimer.restart();
            }
            return;
        }
        if (already) {
            return;
        }

        const candidates = collectCandidates(window);
        if (candidates.length === 0) {
            console.log("snap-assist: no other windows after tiling", window.caption);
            cancelPending();
            return;
        }

        root.pending = { source: window, side: side };
        console.log("snap-assist: start", side, fromPointer ? "pointer" : "keyboard", window.caption);

        if (fromPointer) {
            pickerTimer.restart();
        } else {
            hidePicker();
            tabBoxCall.call();
        }
    }

    function onHalfTile(window, fromPointer) {
        if (root.ignoreTile || !window || window.deleted || !window.normalWindow) {
            return;
        }
        const side = halfSide(window);
        if (!side) {
            if (root.pending && root.pending.source === window) {
                cancelPending();
            }
            return;
        }
        startAssist(window, side, fromPointer);
    }

    Instantiator {
        model: WindowModel {}
        delegate: Item {
            id: windowTracker

            required property var window

            Timer {
                id: geometryFallbackTimer
                interval: 120
                repeat: false
                onTriggered: {
                    const trackedWindow = windowTracker.window;
                    if (!trackedWindow) {
                        return;
                    }
                    const id = root.windowId(trackedWindow);
                    if (!root.pointerSnapIds[id] || trackedWindow.move || trackedWindow.resize) {
                        return;
                    }
                    console.log("snap-assist: frameGeometryChanged fallback", trackedWindow.caption);
                    root.onHalfTile(trackedWindow, true);
                    delete root.pointerSnapIds[id];
                }
            }

            Connections {
                target: windowTracker.window
                ignoreUnknownSignals: true

                function onInteractiveMoveResizeStarted() {
                    const trackedWindow = windowTracker.window;
                    if (!trackedWindow) {
                        return;
                    }
                    geometryFallbackTimer.stop();
                    root.pointerSnapIds[root.windowId(trackedWindow)] = true;
                    console.log("snap-assist: move started", trackedWindow.caption);
                }

                function onFrameGeometryChanged() {
                    const trackedWindow = windowTracker.window;
                    if (!trackedWindow || trackedWindow.move || trackedWindow.resize) {
                        return;
                    }
                    if (root.pointerSnapIds[root.windowId(trackedWindow)]) {
                        geometryFallbackTimer.restart();
                    }
                }

                function onTileChanged() {
                    const trackedWindow = windowTracker.window;
                    if (!trackedWindow || trackedWindow.move || trackedWindow.resize) {
                        return;
                    }
                    const id = root.windowId(trackedWindow);
                    const fromPointer = !!root.pointerSnapIds[id];
                    geometryFallbackTimer.stop();
                    delete root.pointerSnapIds[id];
                    console.log("snap-assist: tileChanged", trackedWindow.caption, fromPointer ? "pointer" : "keyboard");
                    root.onHalfTile(trackedWindow, fromPointer);
                }

                function onInteractiveMoveResizeFinished() {
                    const trackedWindow = windowTracker.window;
                    if (!trackedWindow) {
                        return;
                    }
                    console.log("snap-assist: move finished", trackedWindow.caption);
                    geometryFallbackTimer.restart();
                }

                function onClosed() {
                    geometryFallbackTimer.stop();
                    const trackedWindow = windowTracker.window;
                    if (trackedWindow) {
                        delete root.pointerSnapIds[root.windowId(trackedWindow)];
                    }
                    if (root.pending && root.pending.source === trackedWindow) {
                        root.cancelPending();
                    }
                }
            }
        }
    }

    Connections {
        target: Workspace
        function onWindowActivated(window) {
            if (!root.pending || !window || window === root.pending.source) {
                return;
            }
            if (picker.visible) {
                return;
            }
            if (!isCandidate(window) || !isOnCurrentDesktop(window)) {
                return;
            }
            if (halfSide(window) === (root.pending.side === "left" ? "right" : "left")) {
                cancelPending();
                return;
            }
            console.log("snap-assist: activated", window.caption);
            tileSelected(window);
        }
        function onWindowRemoved(window) {
            if (root.pending && root.pending.source === window) {
                cancelPending();
            }
        }
    }

    Window {
        id: picker
        flags: Qt.FramelessWindowHint | Qt.X11BypassWindowManagerHint
        color: "#e01d1d1d"
        visible: false
        title: "Snap Assist"

        onVisibleChanged: root.logPickerState("visibleChanged")
        onVisibilityChanged: root.logPickerState("visibilityChanged")
        onActiveChanged: root.logPickerState("activeChanged")
        onScreenChanged: root.logPickerState("screenChanged")

        property var candidates: []

        SystemPalette {
            id: palette
            colorGroup: SystemPalette.Active
        }

        Shortcut {
            sequence: "Escape"
            enabled: picker.visible
            onActivated: root.cancelPending()
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.cancelPending()
        }

        GridView {
            id: grid
            anchors.fill: parent
            anchors.margins: 24
            clip: true
            cellWidth: Math.max(220, (width - 12) / 2)
            cellHeight: Math.max(160, cellWidth * 0.7)
            model: picker.candidates

            delegate: Item {
                width: grid.cellWidth - 12
                height: grid.cellHeight - 12

                property var clientWindow: modelData

                Rectangle {
                    anchors.fill: parent
                    color: cardMouse.containsMouse ? "#55ffffff" : "#33ffffff"
                    radius: 10
                    border.color: palette.highlight
                    border.width: cardMouse.containsMouse ? 2 : 0

                    Column {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 8

                        Row {
                            width: parent.width
                            spacing: 8
                            Text {
                                text: clientWindow ? clientWindow.caption : ""
                                color: "white"
                                elide: Text.ElideRight
                                width: parent.width
                                font.pixelSize: 13
                            }
                        }

                        WindowThumbnail {
                            width: parent.width
                            height: parent.height - 28
                            client: clientWindow
                        }
                    }

                    MouseArea {
                        id: cardMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.tileSelected(clientWindow)
                    }
                }
            }
        }
    }

    Component.onCompleted: {
        console.log("snap-assist: loaded (qml)");
    }
}
