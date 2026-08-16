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

  function submitTopup() {
    if (!root.ready) return
    // Clears only once an invoice is actually out: a rejected amount stays
    // put so the error line reads against what was typed.
    if (root.service.createInvoice(amountField.text) > 0) amountField.text = ""
    keyCatcher.forceActiveFocus()
  }

  function submitCashu() {
    if (!root.ready) return
    var token = cashuField.text
    cashuField.text = ""
    keyCatcher.forceActiveFocus()
    root.service.receiveCashu(token)
  }

  function submitMint() {
    if (!root.ready) return
    var url = mintField.text
    mintField.text = ""
    keyCatcher.forceActiveFocus()
    root.service.addMint(url)
  }

  property bool providersExpanded: false

  // ---- Connect confirmation. Claude Code replaces the Anthropic login;
  // OpenClaw gets its default model overwritten. Neither happens on a
  // bare click.
  property string confirmClientId: ""
  readonly property bool confirmOpen: confirmClientId !== ""

  function requestConnect(clientId) {
    if (!root.ready) return
    if (clientId === "claude-code" || clientId === "openclaw") {
      confirmDialog.selectedIndex = 1
      confirmClientId = clientId
    } else {
      root.service.wireClient(clientId)
    }
  }

  function confirmAccept() {
    var id = confirmClientId
    confirmClientId = ""
    if (id !== "") root.service.wireClient(id)
  }

  function confirmCancel() {
    confirmClientId = ""
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
      blocked: cashuField.activeFocus || mintField.activeFocus || amountField.activeFocus || modelDropdown.popupOpen
      onCloseRequested: {
        if (root.confirmOpen) root.confirmCancel()
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.confirmOpen) confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
        else root.switchPanel(direction)
      }
      onMoveRequested: function(dx, dy) {
        if (root.confirmOpen) {
          if (dx !== 0)
            confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
          return
        }
        // No cursor model in this panel; vertical motion scrolls the column
        // so content past the height cap stays reachable by keyboard.
        if (dy !== 0) {
          var limit = Math.max(0, panelFlick.contentHeight - panelFlick.height)
          panelFlick.contentY = Math.max(0, Math.min(limit, panelFlick.contentY + dy * Style.space(64)))
        }
      }
      onActivateRequested: {
        if (root.confirmOpen) {
          if (confirmDialog.selectedIndex === 1) root.confirmAccept()
          else root.confirmCancel()
        }
      }
      onTextKey: function(t) {
        if (!root.ready || root.confirmOpen) return
        if (t === "t" || t === "T") root.service.toggleDaemon()
        else if (t === "r" || t === "R") root.service.refresh(true)
        else if (t === "c" || t === "C") root.service.copyInvoice()
        else if (t === "p" || t === "P") root.providersExpanded = !root.providersExpanded
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

            // Reference chip: never shown, only measured. The three labels
            // carry different digit counts, so they measure differently;
            // pinning every chip to the widest keeps the row uniform. It is
            // declared `selected` because Button bolds its label in that
            // state — a no-op in the monospace default, but it stops a
            // proportional theme font from resizing a chip the moment its
            // invoice goes out. The height pin is belt-and-braces: labels
            // measure the same height now that formatSats groups with a
            // glyph the font actually has (see Model.formatSats), and this
            // keeps the row honest if one ever pulls a fallback again.
            Button {
              id: chipSizer
              visible: false
              text: Model.formatSats(Math.max.apply(Math, root.topupChoices))
              bordered: true
              selected: true
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
                  width: Math.max(chipSizer.implicitWidth, implicitWidth)
                  height: Math.max(chipSizer.implicitHeight, implicitHeight)
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

            // Anything the chips do not cover. Model bounds the amount; the
            // mint still decides what it will actually issue.
            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: amountField
                Layout.fillWidth: true
                placeholderText: "Custom amount (sats)"
                inputMethodHints: Qt.ImhDigitsOnly
                foreground: root.foreground
                font.family: root.fontFamily
                enabled: root.ready && !root.service.creatingInvoice
                onAccepted: root.submitTopup()
                Keys.onEscapePressed: {
                  text = ""
                  keyCatcher.forceActiveFocus()
                }
              }

              Button {
                text: root.ready && root.service.creatingInvoice ? "Creating…" : "Get invoice"
                iconSpinning: root.ready && root.service.creatingInvoice
                iconText: root.ready && root.service.creatingInvoice ? "󰑓" : ""
                bordered: true
                enabled: root.ready && !root.service.creatingInvoice && amountField.text !== ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.submitTopup()
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

          // ---- Mint: where the sats actually live. Cashu is mint trust;
          // say so instead of hiding it. There is no set-default surface in
          // routstrd — the one real choice is which mint invoices mint
          // into, so rows become selectable only once there is a choice.
          // Visible whenever the daemon is up: a zero-mint wallet still
          // needs the add field.
          Column {
            visible: root.ready && root.service.daemonUp
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "MINT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.ready ? root.service.mintRows : []

              CursorSurface {
                id: mintRow
                required property var modelData
                readonly property bool selectable: root.service.mintRows.length > 1
                readonly property string effectiveTopup: root.service.topupMintUrl !== ""
                  ? root.service.topupMintUrl : root.service.activeMint
                readonly property bool topupTarget: selectable && modelData.url === effectiveTopup

                width: parent.width
                foreground: root.foreground
                hasCursor: selectable && mintRowMouse.containsMouse
                implicitHeight: mintRowInner.implicitHeight + Style.spacing.rowPaddingX

                MouseArea {
                  id: mintRowMouse
                  anchors.fill: parent
                  enabled: mintRow.selectable
                  hoverEnabled: mintRow.selectable
                  cursorShape: mintRow.selectable ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.service.selectTopupMint(mintRow.modelData.url)
                }

                RowLayout {
                  id: mintRowInner
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
                      text: mintRow.modelData.host
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Text {
                      Layout.fillWidth: true
                      text: {
                        var parts = [Model.formatSats(mintRow.modelData.sats) + " sats"]
                        if (mintRow.modelData.active) parts.push("active mint")
                        if (mintRow.topupTarget) parts.push("top-ups land here")
                        return parts.join(" · ")
                      }
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Text {
                    visible: mintRow.topupTarget
                    text: "󰄬"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                    Layout.alignment: Qt.AlignVCenter
                  }
                }
              }
            }

            Text {
              visible: root.ready && root.service.mintRows.length > 1
              width: parent.width
              text: "Click a mint to choose where Lightning top-ups land. The active mint is fixed by the wallet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: mintField
                Layout.fillWidth: true
                placeholderText: "Add a mint (https://…)"
                foreground: root.foreground
                font.family: root.fontFamily
                enabled: root.ready && !root.service.addingMint
                onAccepted: root.submitMint()
                Keys.onEscapePressed: {
                  text = ""
                  keyCatcher.forceActiveFocus()
                }
              }

              Button {
                text: root.ready && root.service.addingMint ? "Adding…" : "Add"
                iconSpinning: root.ready && root.service.addingMint
                iconText: root.ready && root.service.addingMint ? "󰑓" : ""
                bordered: true
                enabled: root.ready && !root.service.addingMint && mintField.text !== ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.submitMint()
              }
            }

            Text {
              width: parent.width
              text: "Your balance is IOUs from the mint that issued it — trust the mint before parking sats there."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
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
                        return "Connected · " + Model.countLabel(root.service.opencodeModels, "model")
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

            AgentRow {
              visible: root.ready && root.service.claudeInstalled
              width: parent.width
              clientId: "claude-code"
              title: "Claude Code"
              subtitle: root.ready && root.service.claudeWired
                ? "Routing through Routstr — Anthropic login bypassed"
                : "Using its own Anthropic login"
              wired: root.ready && root.service.claudeWired
            }

            AgentRow {
              visible: root.ready && root.service.piInstalled
              width: parent.width
              clientId: "pi-agent"
              title: "Pi"
              subtitle: {
                if (!root.ready || !root.service.piWired) return "Not connected"
                return "Connected · " + Model.countLabel(root.service.piModels, "model")
              }
              wired: root.ready && root.service.piWired
            }

            AgentRow {
              visible: root.ready && root.service.openclawInstalled
              width: parent.width
              clientId: "openclaw"
              title: "OpenClaw"
              subtitle: {
                if (!root.ready || !root.service.openclawWired) return "Not connected"
                var s = "Connected · " + Model.countLabel(root.service.openclawModels, "model")
                if (root.service.openclawDefaultIsRoutstr) s += " · default model set"
                return s
              }
              wired: root.ready && root.service.openclawWired
            }

            Text {
              width: parent.width
              text: "Wiring is additive, except Claude Code: connecting it replaces the Anthropic login until you disconnect. Disconnect removes only Routstr's keys — anything it overwrote lives in the .bak-routstr backup beside each config."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---- Models: what to type in an agent config. There is no
          // default-model surface in routstrd (small_model and the Claude
          // env models are hardcoded or positional), so this is a copy
          // affordance, not a picker that would fight the daemon's own
          // 21-minute integration rewrites.
          Column {
            visible: root.ready && root.service.daemonUp && root.service.modelOptions.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "MODELS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            SearchableDropdown {
              id: modelDropdown
              width: parent.width
              options: root.ready ? root.service.modelOptions : []
              value: ""
              triggerLabel: "Copy a model id…"
              placeholderText: "Search models…"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(v) {
                root.service.copyModelRef(v)
                value = ""
              }
            }

            Text {
              width: parent.width
              text: "Agent configs reference models as routstr/<id>. Picking one copies that."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---- Providers: who actually serves the requests. Disable is
          // the only lever routstrd offers; routing skips disabled nodes.
          Column {
            visible: root.ready && root.service.daemonUp && root.service.providerRows.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "PROVIDERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            CursorSurface {
              id: providersHeader
              width: parent.width
              foreground: root.foreground
              hasCursor: providersHeaderMouse.containsMouse
              implicitHeight: providersHeaderInner.implicitHeight + Style.spacing.rowPaddingX

              MouseArea {
                id: providersHeaderMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.providersExpanded = !root.providersExpanded
              }

              RowLayout {
                id: providersHeaderInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(8)

                Text {
                  Layout.fillWidth: true
                  text: root.ready ? Model.providerSummary(root.service.providerRows) : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  text: root.providersExpanded ? "󰅃" : "󰅀"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                  Layout.alignment: Qt.AlignVCenter
                }
              }
            }

            Repeater {
              model: root.ready && root.providersExpanded ? root.service.providerRows : []

              CursorSurface {
                id: providerRow
                required property var modelData
                readonly property bool rowBusy: root.service.providerBusyUrl === modelData.url

                width: parent.width
                foreground: root.foreground
                implicitHeight: providerRowInner.implicitHeight + Style.spacing.rowPaddingX

                RowLayout {
                  id: providerRowInner
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(8)

                  Text {
                    Layout.fillWidth: true
                    text: providerRow.modelData.host
                    color: providerRow.modelData.disabled ? root.dim : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  ToggleSwitch {
                    checked: !providerRow.modelData.disabled
                    busy: providerRow.rowBusy
                    foreground: root.foreground
                    Layout.alignment: Qt.AlignVCenter
                    onToggled: root.service.toggleProvider(providerRow.modelData.url, !providerRow.modelData.disabled)
                  }
                }
              }
            }

            Text {
              visible: root.providersExpanded
              width: parent.width
              text: "Requests route around disabled providers. Discovery may renumber or re-add providers over time."
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

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        message: root.confirmClientId === "claude-code"
          ? "Route Claude Code through Routstr? Its Anthropic login is replaced until you disconnect."
          : "Connect OpenClaw? Its default model is switched to a Routstr model."
        confirmText: "Connect"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.confirmCancel()
        onConfirmed: root.confirmAccept()
      }
    }
  }

  // One explicitly-toggled agent: name, wiring state, Connect/Disconnect.
  // Connect may route through the confirm dialog (root.requestConnect
  // decides); Disconnect deletes the daemon client and surgically cleans
  // the agent's config.
  component AgentRow: CursorSurface {
    id: agentRow
    property string clientId: ""
    property string title: ""
    property string subtitle: ""
    property bool wired: false
    readonly property bool rowBusy: root.ready && root.service.clientBusyId === clientId

    foreground: root.foreground
    implicitHeight: agentRowInner.implicitHeight + Style.spacing.rowPaddingX

    RowLayout {
      id: agentRowInner
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
          text: agentRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: agentRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Button {
        text: agentRow.rowBusy
          ? (agentRow.wired ? "Removing…" : "Wiring…")
          : (agentRow.wired ? "Disconnect" : "Connect")
        iconSpinning: agentRow.rowBusy
        iconText: agentRow.rowBusy ? "󰑓" : ""
        bordered: true
        enabled: root.ready && !agentRow.rowBusy && root.service.clientBusyId === "" && root.service.installed
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: agentRow.wired
          ? root.service.disconnectClient(agentRow.clientId)
          : root.requestConnect(agentRow.clientId)
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
