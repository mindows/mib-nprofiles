import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon plus popup. The popup has three views: the profile list (click to
// switch), settings (profiles, rules, fallback, toggles) and the profile
// editor. Everything that acts on the network lives in Service.qml; this
// widget exists once per monitor and only displays it and forwards clicks.
Panel {
  id: root
  moduleName: "io.github.mindows.mib-nprofiles"
  // Opening from a keybind goes through the shell, which picks the widget on
  // the focused monitor: omarchy-shell shell toggle io.github.mindows.mib-nprofiles
  // Every other command is on the service's IPC target.
  manageIpc: false

  readonly property var svc: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  readonly property var cfg: svc ? svc.config : Model.normalizeSettings(settings)
  readonly property var profiles: svc ? svc.profiles : [Model.automaticProfile()]
  readonly property var activeProfile: svc ? svc.activeProfile : Model.automaticProfile()

  onSettingsChanged: if (svc) svc.pushSettings(settings)
  onSvcChanged: if (svc) svc.pushSettings(settings)

  // "list", "settings" or "edit".
  property string view: "list"
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string glyph: "󰾲"

  readonly property string autoText: {
    if (!cfg.autoSwitch) return "Auto-switch off"
    if (svc && svc.pinned) return "Manual pick · auto-switch resumes on a new network"
    return "Auto-switch on"
  }

  // A profile's DNS can't win against `omarchy dns`'s global override.
  readonly property bool dnsOverridden: svc !== null && svc.globalDns !== "" && activeProfile.dns.length > 0

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function showView(name) {
    view = name
    cursorActive = false
    if (panelFlick) panelFlick.contentY = 0
    if (name !== "edit") Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function use(profileId) {
    if (svc) svc.activate(profileId, { pin: true })
  }

  function moveCursor(dy) {
    if (!cursorActive) { cursorActive = true; return }
    cursorIndex = Math.max(0, Math.min(profiles.length - 1, cursorIndex + dy))
  }

  onOpenedChanged: if (opened) {
    view = "list"
    cursorActive = false
    var index = 0
    for (var i = 0; i < profiles.length; i++) if (profiles[i].id === activeProfile.id) index = i
    cursorIndex = index
    if (svc) svc.refresh(false)
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // --------------------------------------------------------------- editor

  // The profile being edited ("" for a new one) and the editor's choices
  // that aren't plain text fields.
  property string editingId: ""
  property string editError: ""
  property string formIpv4Mode: ""
  property string formIpv4Device: "wifi"
  property string formIpv6: ""
  property string formWifi: ""
  property string formVpn: ""

  function editProfile(profileId) {
    var profile = profileId ? Model.findProfile(cfg, profileId) : null
    var form = Model.formFromProfile(profile)
    editingId = profile ? profile.id : ""
    editError = ""
    nameField.text = form.name
    formIpv4Mode = form.ipv4Mode
    formIpv4Device = form.ipv4Device
    addressField.text = form.ipv4Address
    gatewayField.text = form.ipv4Gateway
    dnsField.text = form.dns
    searchField.text = form.search
    formIpv6 = form.ipv6
    formWifi = form.wifi ? form.wifi.uuid : ""
    formVpn = form.vpn ? form.vpn.uuid : ""
    showView("edit")
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function connectionRef(list, uuid) {
    if (uuid === "") return null
    for (var i = 0; i < list.length; i++) if (list[i].uuid === uuid) return list[i]
    // A connection deleted since the profile was saved: keep the reference.
    var existing = Model.findProfile(cfg, editingId)
    if (existing && existing.wifi && existing.wifi.uuid === uuid) return existing.wifi
    if (existing && existing.vpn && existing.vpn.uuid === uuid) return existing.vpn
    return null
  }

  function saveEdit() {
    if (!svc) return
    var connections = svc.connections
    var result = Model.profileFromForm({
      name: nameField.text,
      ipv4Mode: formIpv4Mode,
      ipv4Device: formIpv4Device,
      ipv4Address: addressField.text,
      ipv4Gateway: gatewayField.text,
      dns: dnsField.text,
      search: searchField.text,
      ipv6: formIpv6,
      wifi: connectionRef(connections.wifi, formWifi),
      vpn: connectionRef(connections.vpn, formVpn)
    }, cfg.profiles, editingId)
    if (result.error) { editError = result.error; return }
    if (!svc.saveProfile(result.profile)) { editError = "You have the maximum of " + Model.MAX_PROFILES + " profiles."; return }
    showView("settings")
  }

  function connectionOptions(list, current) {
    var options = [{ value: "", label: "None" }]
    var seen = false
    for (var i = 0; i < list.length; i++) {
      options.push({ value: list[i].uuid, label: list[i].name })
      if (list[i].uuid === current) seen = true
    }
    if (current !== "" && !seen) options.push({ value: current, label: "(deleted connection)" })
    return options
  }

  // ---------------------------------------------------------------- rules

  property string ruleWhen: "wifi"
  property string ruleProfile: ""

  function profileName(id) {
    var p = Model.findProfile(cfg, id)
    return p ? p.name : "?"
  }

  function addRule() {
    if (!svc) return
    var ssid = Model.cleanText(ssidField.text, 64)
    if (ruleWhen !== "ethernet" && ssid === "") { ruleError = "Enter the Wi-Fi network name."; return }
    var profile = ruleProfile || (cfg.profiles.length > 0 ? cfg.profiles[0].id : Model.AUTOMATIC)
    var rules = cfg.rules.slice()
    if (rules.length >= Model.MAX_RULES) { ruleError = "That's the maximum of " + Model.MAX_RULES + " rules."; return }
    rules.push({ when: ruleWhen, ssid: ruleWhen === "ethernet" ? "" : ssid, profile: profile })
    svc.saveRules(rules)
    ssidField.text = ""
    ruleError = ""
  }
  property string ruleError: ""

  function moveRule(index, delta) {
    var rules = cfg.rules.slice()
    var target = index + delta
    if (target < 0 || target >= rules.length) return
    var item = rules[index]
    rules[index] = rules[target]
    rules[target] = item
    svc.saveRules(rules)
  }

  function removeRule(index) {
    var rules = cfg.rules.slice()
    rules.splice(index, 1)
    svc.saveRules(rules)
  }

  readonly property var profileOptions: {
    var options = []
    for (var i = 0; i < profiles.length; i++) options.push({ value: profiles[i].id, label: profiles[i].name })
    return options
  }

  // Bar widgets aren't handed their manifest, so the footer reads the
  // version out of it directly.
  readonly property string sourceUrl: "https://github.com/mindows/mib-nprofiles"
  property var manifest: null
  FileView {
    path: decodeURIComponent(String(Qt.resolvedUrl("manifest.json")).replace(/^file:\/\//, ""))
    printErrors: false
    onLoaded: {
      try { root.manifest = JSON.parse(text()) } catch (e) { root.manifest = null }
    }
  }

  // ------------------------------------------------------------ bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    foreground: barForeground
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.opened ? "" : "Network profile: " + root.activeProfile.name
      + (root.svc && root.svc.pinned ? " (manual)" : "")

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) { root.open(); root.showView("settings") }
      else root.toggle()
    }
  }

  // ----------------------------------------------------------------- popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.view === "edit"
        || ssidField.activeFocus
        || fallbackPicker.popupOpen || whenPicker.popupOpen || ruleProfilePicker.popupOpen
      onMoveRequested: function(dx, dy) { if (root.view === "list") root.moveCursor(dy) }
      onActivateRequested: {
        if (root.view === "list" && root.cursorActive && root.profiles[root.cursorIndex])
          root.use(root.profiles[root.cursorIndex].id)
      }
      onCloseRequested: root.view === "list" ? root.close() : root.showView("list")
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") root.showView(root.view === "list" ? "settings" : "list")
        else if ((t === "a" || t === "A") && root.svc) root.svc.setAutoSwitch(!root.cfg.autoSwitch)
        else if ((t === "n" || t === "N") && root.view === "settings" && root.cfg.profiles.length < Model.MAX_PROFILES) root.editProfile("")
        else if (t >= "1" && t <= "9") {
          var i = parseInt(t, 10) - 1
          if (root.view === "list" && root.profiles[i]) root.use(root.profiles[i].id)
        }
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

          PanelHero {
            width: parent.width
            title: root.view === "edit" ? (root.editingId === "" ? "New profile" : "Edit profile")
              : (root.view === "settings" ? "Profile settings" : root.activeProfile.name)
            meta: root.view === "list" ? (root.svc ? root.svc.networkText : "Loading…") : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.view === "list" ? root.glyph : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------------ list view

          Column {
            visible: root.view === "list"
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              visible: root.dnsOverridden
              width: parent.width
              text: "`omarchy dns` is set to " + (root.svc ? root.svc.globalDns : "")
                + " for the whole system, which overrides this profile's DNS. Run `omarchy dns DHCP` to let profiles choose."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: root.svc !== null && root.svc.lastError !== ""
              width: parent.width
              text: root.svc ? root.svc.lastError : ""
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.profiles
              ProfileRow {
                required property var modelData
                required property int index
                width: parent.width
                profile: modelData
                rowIndex: index
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.profiles.length === 1
              width: parent.width
              text: "Only Automatic so far. Open settings to make a profile, such as Home with its own DNS."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // -------------------------------------------------- settings view

          Column {
            visible: root.view === "settings"
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "PROFILES · " + root.cfg.profiles.length + " OF " + Model.MAX_PROFILES
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.cfg.profiles
              RowLayout {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: Model.profileSummary(modelData)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                PanelActionButton {
                  iconText: "󰏫"
                  tooltipText: "Edit " + modelData.name
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: root.editProfile(modelData.id)
                }
              }
            }

            Button {
              text: "New profile (n)"
              iconText: "󰐕"
              bordered: true
              enabled: root.cfg.profiles.length < Model.MAX_PROFILES
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.editProfile("")
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "AUTO-SWITCH RULES · FIRST MATCH WINS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Toggle {
              width: parent.width
              label: "Switch automatically"
              description: "Follow the rules below. A profile you pick by hand holds until the network changes."
              checked: root.cfg.autoSwitch
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: if (root.svc) root.svc.setAutoSwitch(!root.cfg.autoSwitch)
            }

            Repeater {
              model: root.cfg.rules
              RowLayout {
                required property var modelData
                required property int index
                width: parent.width
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: (index + 1) + ". " + Model.ruleLabel(modelData, root.profileName(modelData.profile))
                  color: root.svc && root.svc.ruleResult.rule === index ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: root.svc !== null && root.svc.ruleResult.rule === index
                  elide: Text.ElideRight
                }
                PanelActionButton {
                  iconText: "󰅃"
                  tooltipText: "Move up"
                  enabled: index > 0
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.moveRule(index, -1)
                }
                PanelActionButton {
                  iconText: "󰅀"
                  tooltipText: "Move down"
                  enabled: index < root.cfg.rules.length - 1
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.moveRule(index, 1)
                }
                PanelActionButton {
                  iconText: "󰅖"
                  tooltipText: "Remove rule"
                  foreground: root.foreground
                  hoverColor: root.urgent
                  fontFamily: root.fontFamily
                  onClicked: root.removeRule(index)
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.cfg.rules.length === 0
              width: parent.width
              text: "No rules yet. Add one below, e.g. connected to your home Wi-Fi → Home."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Add a rule: when, which network, which profile.
            FieldLabel { text: "ADD A RULE" }

            Dropdown {
              id: whenPicker
              width: parent.width
              showLabel: false
              options: Model.RULE_KINDS
              value: root.ruleWhen
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(value) { root.ruleWhen = value }
            }

            TextField {
              id: ssidField
              visible: root.ruleWhen !== "ethernet"
              width: parent.width
              placeholderText: root.svc && root.svc.wifiConnected.length > 0
                ? "Wi-Fi name, e.g. " + root.svc.wifiConnected[0] : "Wi-Fi name (SSID)"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              onAccepted: root.addRule()
              Keys.onEscapePressed: function(event) {
                ssidField.focus = false
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              Text {
                textFormat: Text.PlainText
                text: "Use"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                Layout.alignment: Qt.AlignVCenter
              }
              Dropdown {
                id: ruleProfilePicker
                Layout.fillWidth: true
                showLabel: false
                options: root.profileOptions
                value: root.ruleProfile || (root.cfg.profiles.length > 0 ? root.cfg.profiles[0].id : Model.AUTOMATIC)
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function(value) { root.ruleProfile = value }
              }
              PanelActionButton {
                iconText: "󰐕"
                tooltipText: "Add rule"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.addRule()
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.ruleError !== ""
              width: parent.width
              text: root.ruleError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              Text {
                textFormat: Text.PlainText
                text: "Anywhere else"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                Layout.alignment: Qt.AlignVCenter
              }
              Dropdown {
                id: fallbackPicker
                Layout.fillWidth: true
                showLabel: false
                options: root.profileOptions
                value: root.cfg.fallbackProfile
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function(value) { if (root.svc) root.svc.setFallback(value) }
              }
            }

            PanelSeparator { foreground: root.foreground }

            Toggle {
              width: parent.width
              label: "Notify on automatic switches"
              description: "One toast when a rule changes the profile"
              checked: root.cfg.notify
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: if (root.svc) root.svc.persist({ notify: !root.cfg.notify })
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: [
                root.manifest && root.manifest.name ? root.manifest.name : "MIB Network Profiles",
                root.manifest && root.manifest.version ? root.manifest.version : ""
              ].join(" ").trim()
                + (root.manifest && root.manifest.license ? " · " + root.manifest.license : "")
                + " · Source ↗"
              color: sourceArea.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight

              MouseArea {
                id: sourceArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Quickshell.execDetached(["xdg-open", root.sourceUrl])
              }
            }
          }

          // ------------------------------------------------------ edit view

          Column {
            visible: root.view === "edit"
            width: parent.width
            spacing: Style.space(10)

            FieldLabel { text: "NAME" }
            TextField {
              id: nameField
              width: parent.width
              placeholderText: "Home, Work, Café…"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              maximumLength: 40
              onAccepted: root.saveEdit()
            }

            FieldLabel { text: "IPV4" }
            ButtonGroup {
              width: parent.width
              options: Model.IPV4_MODES
              value: root.formIpv4Mode
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onChanged: function(value) { root.formIpv4Mode = value }
            }
            Column {
              visible: root.formIpv4Mode === "manual"
              width: parent.width
              spacing: Style.space(6)
              ButtonGroup {
                width: parent.width
                options: Model.DEVICE_KINDS
                value: root.formIpv4Device
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onChanged: function(value) { root.formIpv4Device = value }
              }
              TextField {
                id: addressField
                width: parent.width
                placeholderText: "Address, e.g. 192.168.1.50/24"
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                onAccepted: root.saveEdit()
              }
              TextField {
                id: gatewayField
                width: parent.width
                placeholderText: "Gateway, e.g. 192.168.1.1"
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                onAccepted: root.saveEdit()
              }
            }
            Hint {
              text: root.formIpv4Mode === "manual"
                ? "Applies to " + (root.formIpv4Device === "ethernet" ? "Ethernet" : "Wi-Fi") + " only. Add DNS servers below, since a manual address gets none from the network."
                : (root.formIpv4Mode === "dhcp" ? "Ask the network for an address, even where the saved connection is static." : "Keep what each saved connection says.")
            }

            FieldLabel { text: "DNS" }
            TextField {
              id: dnsField
              width: parent.width
              placeholderText: "e.g. 1.1.1.1, 9.9.9.9 (blank keeps the network's)"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              onAccepted: root.saveEdit()
            }
            TextField {
              id: searchField
              width: parent.width
              placeholderText: "Search domains, e.g. corp.example.com"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              onAccepted: root.saveEdit()
            }

            FieldLabel { text: "IPV6" }
            ButtonGroup {
              width: parent.width
              options: Model.IPV6_MODES
              value: root.formIpv6
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onChanged: function(value) { root.formIpv6 = value }
            }

            FieldLabel { text: "JOIN WI-FI" }
            Dropdown {
              width: parent.width
              showLabel: false
              options: root.connectionOptions(root.svc ? root.svc.connections.wifi : [], root.formWifi)
              value: root.formWifi
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(value) { root.formWifi = value }
            }

            FieldLabel { text: "VPN" }
            Dropdown {
              width: parent.width
              visible: root.svc !== null && (root.svc.connections.vpn.length > 0 || root.formVpn !== "")
              showLabel: false
              options: root.connectionOptions(root.svc ? root.svc.connections.vpn : [], root.formVpn)
              value: root.formVpn
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(value) { root.formVpn = value }
            }
            Hint {
              text: root.svc !== null && root.svc.connections.vpn.length === 0 && root.formVpn === ""
                ? "No VPN or WireGuard connections in NetworkManager yet."
                : "Brought up when you switch to this profile, and taken down when you switch away."
            }

            Text {
              textFormat: Text.PlainText
              visible: root.editError !== ""
              width: parent.width
              text: root.editError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              Button {
                text: "Save"
                iconText: "󰄬"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.saveEdit()
              }
              Button {
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.showView("settings")
              }
              Item { Layout.fillWidth: true }
              Button {
                visible: root.editingId !== ""
                text: "Delete"
                iconText: "󰆴"
                foreground: root.urgent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: {
                  if (root.svc) root.svc.deleteProfile(root.editingId)
                  root.showView("settings")
                }
              }
            }
          }

          // ---------------------------------------------------------- footer

          PanelSeparator { foreground: root.foreground; visible: root.view !== "edit" }

          RowLayout {
            visible: root.view !== "edit"
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.view === "settings" ? "Saved as you change it" : root.autoText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            PanelActionButton {
              visible: root.view === "list" && root.svc !== null && root.svc.pinned
              iconText: "󰑐"
              tooltipText: "Let the rules pick again"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.svc.resumeAuto()
            }

            PanelActionButton {
              iconText: root.view === "settings" ? "󰁍" : "󰒓"
              tooltipText: root.view === "settings" ? "Back (s)" : "Settings (s)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.showView(root.view === "settings" ? "list" : "settings")
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component FieldLabel: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
  }

  component Hint: Text {
    textFormat: Text.PlainText
    width: parent ? parent.width : 0
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // One profile: a check on the active one, its name, and what it changes.
  component ProfileRow: CursorSurface {
    id: profileRow
    required property var profile
    required property int rowIndex
    readonly property bool active: root.activeProfile.id === profile.id

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    current: active
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursorIndex = profileRow.rowIndex }
      onClicked: root.use(profileRow.profile.id)
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: profileRow.active ? "󰐾" : "󰐽"
        color: root.foreground
        opacity: profileRow.active ? 1.0 : 0.4
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: profileRow.profile.name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: profileRow.active
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: Model.profileSummary(profileRow.profile)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: profileRow.rowIndex < 9
        text: String(profileRow.rowIndex + 1)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
}
