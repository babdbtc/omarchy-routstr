import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Routstr popup: fuel and wiring. Walks install → onboard → start →
// fund → wire in one column, showing only the step that applies.
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against, plus the shared Service instance.
Panel {
  id: root
  moduleName: "io.github.babdbtc.routstr"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool ready: service !== null
  readonly property var topupChoices: [210, 2100, 21000]

  function open() {
    if (ready) service.refresh(true)
    root.controller.show()
  }

  function close() { root.controller.hide() }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function submitCashu() {
    if (!root.ready) return
    var token = cashuField.text
    cashuField.text = ""
    keyCatcher.forceActiveFocus()
    root.service.receiveCashu(token)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While an inline editor owns focus, keys must reach it (the
      // catcher's BeforeItem priority would eat them otherwise).
      blocked: cashuField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {}
      onActivateRequested: {}
      onTextKey: function(t) {
        if (!root.ready) return
        if (t === "t" || t === "T") root.service.toggleDaemon()
        else if (t === "r" || t === "R") root.service.refresh(true)
        else if (t === "c" || t === "C") root.service.copyInvoice()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---- Hero: state at a glance, daemon switch on the trailing edge.
          PanelHero {
            id: hero
            width: parent.width
            title: "Routstr"
            meta: root.ready ? root.service.statusText : "Loading…"
            detail: root.ready && root.service.daemonUp && root.service.balanceSats >= 0
              ? Model.formatSats(root.service.balanceSats) + " sats" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.ready && root.service.daemonUp ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: "󱐋"
                color: root.ready && root.service.lowBalance ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: powerSwitch
                visible: root.ready && root.service.installed && root.service.onboarded
                checked: root.ready && root.service.daemonActive
                busy: root.ready && root.service.refreshing
                foreground: hero.foreground
                onToggled: root.service.toggleDaemon()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: root.ready && root.service.daemonActive ? "Stop the routstrd daemon" : "Start the routstrd daemon"
                  fontFamily: hero.fontFamily
                }
              }
            }
          }

          // ---- Transient action feedback and errors.
          Text {
            visible: root.ready && (root.service.actionStatus !== "" || root.service.lastError !== "")
            width: parent.width
            text: root.ready ? (root.service.actionStatus !== "" ? root.service.actionStatus : root.service.lastError) : ""
            color: root.ready && root.service.lastError !== "" && root.service.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---- Step 1: install. Commands are shown and copied, never piped.
          Column {
            visible: root.ready && root.service.probed && !root.service.installed
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "INSTALL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            CommandRow {
              visible: root.ready && !root.service.bunInstalled
              width: parent.width
              title: "Install Bun first"
              command: "mise use -g bun@latest"
            }

            CommandRow {
              width: parent.width
              title: "Install routstrd"
              command: "bun i -g routstrd"
              runnable: root.ready && root.service.bunInstalled
              onRun: root.service.installInTerminal()
            }

            Text {
              width: parent.width
              text: "The plugin never runs installers itself. Run these in a terminal, then refresh."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---- Step 2: onboard, strictly in a terminal.
          Column {
            visible: root.ready && root.service.probed && root.service.installed && !root.service.onboarded
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "CREATE WALLET"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Button {
              text: "Onboard in terminal"
              iconText: ""
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.service.onboardInTerminal()
            }

            Text {
              width: parent.width
              text: "routstrd onboard prints your wallet mnemonic — write it down. It runs in its own terminal; the shell never sees that output."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---- Step 3: daemon down.
          Column {
            visible: root.ready && root.service.probed && root.service.installed && root.service.onboarded && !root.service.daemonUp
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "DAEMON"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Button {
              text: root.ready && root.service.daemonActive ? "Starting…" : "Start daemon"
              iconText: "󱐋"
              iconSpinning: root.ready && root.service.daemonActive
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.service.startDaemon()
            }

            CommandRow {
              width: parent.width
              title: "Start on boot"
              command: "routstrd service install"
              runnable: true
              onRun: root.service.persistInTerminal()
            }
          }

          PanelSeparator {
            visible: root.ready && root.service.daemonUp
            foreground: root.foreground
          }

          // ---- Fund: top-up chips and the Lightning QR.
          Column {
            visible: root.ready && root.service.daemonUp
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "TOP UP"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              spacing: Style.space(8)

              Repeater {
                model: root.topupChoices
                Button {
                  required property int modelData
                  text: Model.formatSats(modelData)
                  bordered: true
                  selected: root.ready && root.service.invoiceSats === modelData && root.service.invoiceText !== ""
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  tooltipText: "Lightning invoice for " + Model.formatSats(modelData) + " sats"
                  onClicked: root.service.createInvoice(modelData)
                }
              }

              Text {
                text: "sats"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Paste path: the private way in — no invoice, no metadata.
            // The field is cleared before the token is handed to the
            // service, so no QML property upstream of the request holds it.
            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: cashuField
                Layout.fillWidth: true
                password: true
                placeholderText: "Paste a Cashu token (cashuA…)"
                foreground: root.foreground
                font.family: root.fontFamily
                enabled: root.ready && !root.service.receivingCashu
                onAccepted: root.submitCashu()
                Keys.onEscapePressed: {
                  text = ""
                  keyCatcher.forceActiveFocus()
                }
              }

              Button {
                text: root.ready && root.service.receivingCashu ? "Redeeming…" : "Redeem"
                iconSpinning: root.ready && root.service.receivingCashu
                iconText: root.ready && root.service.receivingCashu ? "󰑓" : ""
                bordered: true
                enabled: root.ready && !root.service.receivingCashu && cashuField.text !== ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.submitCashu()
              }
            }

            Text {
              visible: root.ready && root.service.lowBalance
              width: parent.width
              text: "Balance is under " + Model.formatSats(root.service.lowBalanceSats)
                + " sats — the next request may not clear. Top up above."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Column {
              visible: root.ready && root.service.invoiceText !== ""
              width: parent.width
              spacing: Style.space(8)

              Rectangle {
                visible: root.ready && root.service.invoiceQrReady
                width: qrImage.width + Style.space(16)
                height: qrImage.height + Style.space(16)
                radius: Style.cornerRadius
                color: "white"
                anchors.horizontalCenter: parent.horizontalCenter

                Image {
                  id: qrImage
                  anchors.centerIn: parent
                  width: Math.min(Style.space(250), panelFlick.width - Style.space(60))
                  height: width
                  source: root.ready && root.service.invoiceQrReady
                    ? "file://" + root.service.qrPath + "?v=" + root.service.qrStamp : ""
                  sourceSize.width: 600
                  sourceSize.height: 600
                  fillMode: Image.PreserveAspectFit
                  smooth: false
                  cache: false
                }
              }

              Text {
                width: parent.width
                text: root.ready
                  ? "Pay " + Model.formatSats(root.service.invoiceSats) + " sats · waiting for payment"
                  : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                width: parent.width
                text: root.ready ? Model.elideMiddle(root.service.invoiceText, 42) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
              }

              Row {
                spacing: Style.space(8)
                anchors.horizontalCenter: parent.horizontalCenter

                Button {
                  text: "Copy invoice"
                  iconText: "󰆏"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.service.copyInvoice()
                }

                Button {
                  text: "Cancel"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.service.clearInvoice()
                }
              }
            }
          }

          PanelSeparator {
            visible: root.ready && root.service.daemonUp
            foreground: root.foreground
          }

          // ---- Wire: agents pointed at the local endpoint.
          Column {
            visible: root.ready && root.service.daemonUp
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "AGENTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            CursorSurface {
              width: parent.width
              foreground: root.foreground
              implicitHeight: opencodeRow.implicitHeight + Style.spacing.rowPaddingX

              RowLayout {
                id: opencodeRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(8)

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    Layout.fillWidth: true
                    text: "OpenCode"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    Layout.fillWidth: true
                    text: {
                      if (!root.ready) return ""
                      if (!root.service.opencodeInstalled) return "Not installed"
                      if (root.service.opencodeWired)
                        return "Connected · " + root.service.opencodeModels + " model"
                          + (root.service.opencodeModels === 1 ? "" : "s")
                      if (root.service.driftAlert) return "Provider removed from opencode.json"
                      return "Not connected"
                    }
                    color: root.ready && root.service.driftAlert ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Text {
                  visible: root.ready && root.service.opencodeWired
                  text: "󰄬"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                  Layout.alignment: Qt.AlignVCenter
                }

                Button {
                  visible: root.ready && root.service.opencodeInstalled && root.service.installed && !root.service.opencodeWired
                  text: root.ready && root.service.wiring ? "Wiring…" : (root.ready && root.service.driftAlert ? "Repair" : "Connect")
                  iconSpinning: root.ready && root.service.wiring
                  iconText: root.ready && root.service.wiring ? "󰑓" : ""
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: root.service.wireOpencode()
                }
              }
            }

            Text {
              width: parent.width
              text: "Claude Code, Pi, and others: explicit toggles land in v2. Wiring is additive — your other providers stay untouched."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---- Last request, when the daemon has one to show.
          Column {
            visible: root.ready && root.service.daemonUp && root.service.lastUsage !== null
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "LAST REQUEST"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: {
                if (!root.ready || !root.service.lastUsage) return ""
                var u = root.service.lastUsage
                var parts = []
                if (u.modelId !== "") parts.push(u.modelId)
                parts.push(u.satsCost.toFixed(3) + " sats")
                if (u.client !== "") parts.push(u.client)
                return parts.join(" · ")
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }

          // ---- Honest footer. No overclaiming.
          Text {
            width: parent.width
            text: "No account. Cashu balance trusts the mint. Providers still see your prompts."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // A titled shell command with copy — and optionally a "run in terminal"
  // action for commands the user should watch execute.
  component CommandRow: CursorSurface {
    id: commandRow
    property string title: ""
    property string command: ""
    property bool runnable: false
    signal run()

    foreground: root.foreground
    implicitHeight: commandInner.implicitHeight + Style.spacing.rowPaddingX

    RowLayout {
      id: commandInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: commandRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: commandRow.command
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "󰆏"
        tooltipText: "Copy command"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.service.copyToClipboard(commandRow.command)
      }

      PanelActionButton {
        visible: commandRow.runnable
        iconText: ""
        tooltipText: "Run in terminal"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: commandRow.run()
      }
    }
  }
}
