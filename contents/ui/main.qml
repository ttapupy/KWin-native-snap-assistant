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
    property var trackedIds: ({})

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
        picker.visible = false;
        picker.candidates = [];
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
        picker.visible = true;
        picker.requestActivate();
        console.log("snap-assist: picker", side, candidates.length);
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

    function trackWindow(window) {
        if (!window || window.deleted) {
            return;
        }
        const id = windowId(window);
        if (root.trackedIds[id]) {
            return;
        }
        root.trackedIds[id] = true;

        window.interactiveMoveResizeStarted.connect(function () {
            root.pointerSnapIds[id] = true;
        });
        window.tileChanged.connect(function () {
            if (window.move || window.resize) {
                return;
            }
            const fromPointer = !!root.pointerSnapIds[id];
            delete root.pointerSnapIds[id];
            onHalfTile(window, fromPointer);
        });
        window.interactiveMoveResizeFinished.connect(function () {
            onHalfTile(window, true);
            delete root.pointerSnapIds[id];
        });
        window.closed.connect(function () {
            if (root.pending && root.pending.source === window) {
                cancelPending();
            }
        });
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
            tileSelected(window);
        }
        function onWindowAdded(window) {
            trackWindow(window);
        }
        function onWindowRemoved(window) {
            if (root.pending && root.pending.source === window) {
                cancelPending();
            }
        }
    }

    Window {
        id: picker
        flags: Qt.FramelessWindowHint | Qt.BypassWindowManagerHint | Qt.WindowStaysOnTopHint | Qt.Tool
        color: "#e01d1d1d"
        visible: false
        title: "Snap Assist"

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
        const windows = allWindows();
        for (let i = 0; i < windows.length; i++) {
            trackWindow(windows[i]);
        }
        console.log("snap-assist: loaded (qml), tracking", windows.length, "windows");
    }
}
