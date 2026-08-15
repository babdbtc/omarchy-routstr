import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar entry: a lightning glyph plus sats remaining, red under the
// low-balance threshold, dimmed while the daemon is down. Left click opens
// the panel; middle/right click refreshes. The panel itself lives in
// Panel.qml, clock-style.
BarWidget {
  id: root
  moduleName: "io.github.babdbtc.routstr"

  readonly property string glyph: "󱐋"
  readonly property bool showBalance: service.daemonUp && !service.hideBalance && service.balanceSats >= 0 && !vertical
  readonly property string displayText: showBalance ? glyph + " " + Model.formatSats(service.balanceSats) : glyph

  function refresh() {
    service.refresh(true)
  }

  // ---- Popup plumbing. Shape contract for shell summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = service
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Service {
    id: service
    settings: root.settings
  }

  Binding {
    target: service
    property: "panelOpen"
    value: root.opened
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "routstr"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.broadcast("refresh") }
    function status(): string { return service.statusText }
    function topup(sats: string): string {
      var n = parseInt(sats, 10)
      if (!isFinite(n) || n <= 0) return "usage: topup <sats>"
      service.createInvoice(n)
      return "requested a Lightning invoice for " + n + " sats"
    }
    function wire(): string {
      service.wireOpencode()
      return "wiring OpenCode via routstrd clients add"
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayText
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    dimmed: !service.daemonUp
    active: service.alert
    tooltipText: service.statusText

    onPressed: function(b) {
      if (b === Qt.MiddleButton || b === Qt.RightButton) root.refresh()
      else root.togglePanel()
    }
  }
}
