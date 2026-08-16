import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar entry: a lightning glyph plus sats remaining, badged on any
// keep-alive break (low balance, provider drift, empty model list), dimmed
// while the daemon is down. Left click opens the panel; middle click
// refreshes; right click stays reserved for the spec's later daemon menu.
// The panel itself lives in Panel.qml, clock-style.
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
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.broadcast("refresh") }
    function status(): string { return service.statusText }
    function topup(sats: string): string {
      if (!service.daemonUp) return "routstrd is not answering on 127.0.0.1:8008"
      var asked = String(sats).trim() === "" ? service.defaultTopupSats : sats
      var n = service.createInvoice(asked)
      return n > 0 ? "requested a Lightning invoice for " + n + " sats" : "usage: topup [sats]"
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
      // Right click is deliberately unbound — the spec reserves it for a
      // later start/stop/new-invoice menu.
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.LeftButton) root.togglePanel()
    }
  }
}
