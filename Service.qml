import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The one engine behind every bar icon. A bar widget exists once per monitor,
// so anything that acts (watching NetworkManager, evaluating rules, applying
// a profile, notifying) lives here, in the plugin's single service instance.
//
// Profiles are applied with `nmcli device modify`: runtime-only settings on
// the device, which need no root and never touch saved connections. They last
// until the device reconnects, so every NetworkManager event re-reads the
// state and re-applies whatever the active profile should be. Applying is
// idempotent: a device that already carries the right settings for its
// current activation is left alone, so our own changes don't loop.
Item {
  id: root

  // Injected by the shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.mindows.mib-nprofiles"

  // ------------------------------------------------------------- settings

  // The widget's entry in shell.json. Bar widgets push theirs as it changes;
  // until one does, the shell's snapshot of the bar config is the source.
  property var pushedSettings: null
  readonly property var snapshotSettings: {
    var bar = shell ? shell.barConfig : null
    var layout = bar && bar.layout ? bar.layout : null
    if (!layout) return null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]] || []
      for (var i = 0; i < list.length; i++) if (list[i] && list[i].id === pluginId) return list[i]
    }
    return null
  }
  readonly property var rawSettings: pushedSettings || snapshotSettings
  readonly property bool settingsKnown: rawSettings !== null

  // Which profile is active and whether it was a manual pick are this
  // service's own running state. They are read from shell.json once, at
  // startup, and after that only written: every write comes back through the
  // shell's file watcher, and an echo of an earlier write can land after a
  // later one. Letting that echo move the active profile back would undo a
  // switch the user just made.
  property bool stateLoaded: false
  property string activeId: Model.AUTOMATIC
  property string pinnedNet: ""

  readonly property var config: {
    var c = Model.normalizeSettings(rawSettings)
    if (stateLoaded) {
      c.activeProfile = Model.findProfile(c, activeId) ? activeId : Model.AUTOMATIC
      c.pinnedNetwork = pinnedNet
    }
    return c
  }

  readonly property var activeProfile: Model.findProfile(config, config.activeProfile) || Model.automaticProfile()
  readonly property var profiles: [Model.automaticProfile()].concat(config.profiles)

  // The same echo problem for everything else: for a few seconds after our
  // own write, a pushed entry that differs from it is a stale copy of an
  // earlier write, not a new edit.
  property string _lastWrite: ""
  property double _lastWriteMs: 0

  function pushSettings(values) {
    if (!values || typeof values !== "object") return
    var incoming = JSON.stringify(Model.normalizeSettings(values))
    if (pushedSettings && JSON.stringify(Model.normalizeSettings(pushedSettings)) === incoming) return
    if (Date.now() - _lastWriteMs < 3000 && incoming !== _lastWrite) return
    pushedSettings = values
    Qt.callLater(root.evaluate)
  }

  // Applied locally first so every icon redraws at once; the shell.json write
  // comes back through the widgets as the same value.
  function persist(values) {
    if (values.activeProfile !== undefined) activeId = values.activeProfile
    if (values.pinnedNetwork !== undefined) pinnedNet = values.pinnedNetwork
    var entry = { id: pluginId }
    var current = rawSettings || {}
    for (var key in current) if (key !== "id") entry[key] = current[key]
    for (var k in values) entry[k] = values[k]
    if (stateLoaded) {
      entry.activeProfile = activeId
      entry.pinnedNetwork = pinnedNet
    }
    pushedSettings = entry
    _lastWrite = JSON.stringify(Model.normalizeSettings(entry))
    _lastWriteMs = Date.now()
    if (shell && typeof shell.updateEntryInline === "function") shell.updateEntryInline(pluginId, entry)
  }

  function loadState() {
    if (stateLoaded || !settingsKnown) return
    var c = Model.normalizeSettings(rawSettings)
    activeId = c.activeProfile
    pinnedNet = c.pinnedNetwork
    stateLoaded = true
    Qt.callLater(root.evaluate)
  }

  // ---------------------------------------------------------- network state

  property bool ready: false
  property var devices: []
  property var wifiConnected: []
  property var wifiVisible: []
  property var activeUuids: []
  property var connections: ({ wifi: [], vpn: [] })
  property var inRangeStable: []
  property var _inRangePrevious: []

  readonly property bool ethernetConnected: devices.some(function(d) { return d.type === "ethernet" })
  readonly property var network: ({ wifi: wifiConnected, ethernet: ethernetConnected, inRange: inRangeStable })
  readonly property string fingerprint: Model.networkFingerprint(network)
  readonly property bool pinned: config.autoSwitch && config.pinnedNetwork !== ""

  // What the rules would pick right now, for the popup.
  readonly property var ruleResult: Model.evaluateRules(config, network)

  // One line for the popup header: which networks we're on.
  readonly property string networkText: {
    var parts = []
    for (var i = 0; i < wifiConnected.length; i++) parts.push(wifiConnected[i])
    if (ethernetConnected) parts.push("Ethernet")
    if (!ready) return "Reading network state…"
    return parts.length > 0 ? parts.join(" · ") : "Not connected"
  }

  property string globalDns: ""
  property string lastError: ""
  property bool busy: actions.busy

  // device -> { path, sig, failed } for what we last applied, keyed by the
  // active connection's D-Bus path. A reconnect gets a new path, which is how
  // we know the runtime settings are gone and need applying again.
  property var applied: ({})
  // At startup we can't know whether an earlier shell left runtime settings
  // behind, so the first apply of a non-Automatic profile resets first.
  property bool _startup: true
  // The VPN this service brought up, which is the only one it takes down.
  property string startedVpn: ""
  property double lastJoinMs: 0

  // ------------------------------------------------------------- reading

  property bool _refreshing: false
  property bool _refreshAgain: false
  property bool _scanPending: false

  function refresh(scan) {
    if (scan) _scanPending = true
    if (_refreshing) { _refreshAgain = true; return }
    _refreshing = true
    var scanRead = _scanPending
    _scanPending = false

    reads.run(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CON-UUID,CON-PATH,CONNECTION", "device", "status"], function(code, out) {
      if (code !== 0) return
      root.devices = Model.parseDevices(out)
      // Queued behind the rest of this refresh, so they report after it.
      for (var i = 0; i < root.devices.length; i++) root.verify(root.devices[i])
    })
    reads.run(["nmcli", "-t", "-f", "UUID", "connection", "show", "--active"], function(code, out) {
      if (code === 0) root.activeUuids = String(out).split("\n").filter(Model.isUuid).map(function(u) { return u.toLowerCase() })
    })
    reads.run(["nmcli", "-t", "-f", "ACTIVE,SSID-HEX", "device", "wifi", "list", "--rescan", "no"], function(code, out) {
      if (code !== 0) return
      var list = Model.parseWifiList(out)
      root.wifiConnected = list.connected
      root.wifiVisible = list.visible
      // Only the steady in-range timer moves the stable set, so a burst of
      // NetworkManager events can't count as two separate scans.
      if (scanRead) {
        root.inRangeStable = Model.stabilize(root.inRangeStable, root._inRangePrevious, list.visible)
        root._inRangePrevious = list.visible
      }
    })
    reads.run(["nmcli", "-t", "-f", "NAME,UUID,TYPE", "connection", "show"], function(code, out) {
      if (code === 0) root.connections = Model.parseConnections(out)
      root.ready = true
      root._refreshing = false
      root.evaluate()
      if (root._refreshAgain) {
        root._refreshAgain = false
        refreshDebounce.restart()
      }
    })
  }

  // Nothing reports it when something else resets a device (`omarchy dns`
  // reapplies every connection, for one), so read the live values back and
  // re-apply when the profile's settings are gone. Skipped for a few seconds
  // after our own apply, while the device settles.
  function verify(device) {
    var entry = applied[device.device]
    if (!entry || entry.failed || entry.path !== device.path || Date.now() - entry.at < 10000) return
    reads.run(["nmcli", "-t", "-f", "IP4.ADDRESS,IP4.DNS,IP6.ADDRESS,IP6.DNS", "device", "show", device.device], function(code, out) {
      if (code !== 0 || root.applied[device.device] !== entry) return
      var profile = Model.findProfile(root.config, root.config.activeProfile)
      if (!profile || Model.applySignature(profile, device.type) !== entry.sig) return
      if (Model.deviceMatchesProfile(profile, device.type, Model.parseDeviceShow(out))) return
      console.info("mib-nprofiles: " + device.device + " lost the " + profile.name + " settings, applying again")
      entry.sig = ""
      root.evaluate()
    })
  }

  // ------------------------------------------------------------ deciding

  function evaluate() {
    if (!ready || !stateLoaded) return
    var cfg = config
    var fp = fingerprint

    // A manual pick holds until the set of connected networks changes. Being
    // briefly offline (sleep, a roam) is not a change of place.
    if (cfg.pinnedNetwork !== "" && fp !== "" && cfg.pinnedNetwork !== fp) {
      persist({ pinnedNetwork: "" })
      return
    }

    var target = cfg.activeProfile
    var result = null
    if (cfg.autoSwitch && cfg.pinnedNetwork === "") {
      result = Model.evaluateRules(cfg, network)
      // Offline, only a matching rule (an in-range one) may switch. Falling
      // back to the default every time the lid closes would mean two toasts
      // per sleep.
      if (fp !== "" || result.rule >= 0) target = result.profile
    }

    if (target !== cfg.activeProfile) activate(target, { auto: true, rule: result ? result.rule : -1 })
    else applyToDevices(Model.findProfile(cfg, target) || Model.automaticProfile())
  }

  // ------------------------------------------------------------- acting

  // Switch profiles. opts.auto marks a rule-driven switch (notifies, may not
  // join twice in a row). opts.pin marks the user's own pick, which holds
  // until the network changes.
  function activate(id, opts) {
    var options = opts || {}
    var cfg = config
    var next = Model.findProfile(cfg, id)
    if (!next) return false
    lastError = ""

    persist({
      activeProfile: next.id,
      pinnedNetwork: options.pin === true && cfg.autoSwitch ? fingerprint : ""
    })

    // VPN: take down only one we started, and only if the new profile doesn't
    // want the same one.
    if (startedVpn !== "" && (!next.vpn || next.vpn.uuid !== startedVpn)) {
      var down = startedVpn
      startedVpn = ""
      if (activeUuids.indexOf(down) !== -1)
        runAction(["nmcli", "connection", "down", "uuid", down], "Couldn't stop the VPN")
    }
    if (next.vpn && activeUuids.indexOf(next.vpn.uuid) === -1) {
      startedVpn = next.vpn.uuid
      runAction(["nmcli", "--wait", "30", "connection", "up", "uuid", next.vpn.uuid], "Couldn't start " + next.vpn.name)
    }

    // Wi-Fi: at most one join per switch. The join changes the network,
    // which re-runs the rules; a rule-driven switch within a minute of a join
    // applies its settings but doesn't join again, so two profiles that join
    // each other's networks can't ping-pong.
    if (next.wifi && activeUuids.indexOf(next.wifi.uuid) === -1) {
      if (!options.auto || Date.now() - lastJoinMs > 60000) {
        lastJoinMs = Date.now()
        join(next.wifi)
      }
    }

    applyToDevices(next)

    if (options.auto && cfg.notify) notifySwitch(next, options.rule)
    return true
  }

  // Only join a network that is actually in range: asking NetworkManager for
  // one that isn't can drop the current Wi-Fi while it tries. The SSID is
  // read from the saved connection at join time, since the connection's name
  // needn't match it.
  function join(ref) {
    reads.run(["nmcli", "-t", "-f", "802-11-wireless.ssid", "connection", "show", "uuid", ref.uuid], function(code, out) {
      var ssid = code === 0 ? Model.cleanText(String(out).replace(/^[^:]*:/, "").replace(/\\(.)/g, "$1"), 64) : ""
      if (ssid === "") {
        root.reportError("Couldn't join " + ref.name + ": the saved connection is gone")
        return
      }
      if (root.wifiVisible.indexOf(ssid) === -1) {
        root.reportError("Didn't join " + ref.name + ": " + ssid + " isn't in range")
        return
      }
      root.runAction(["nmcli", "--wait", "30", "connection", "up", "uuid", ref.uuid], "Couldn't join " + ref.name)
    })
  }

  function applyToDevices(profile) {
    var nextApplied = ({})
    for (var i = 0; i < devices.length; i++) {
      var d = devices[i]
      var sig = Model.applySignature(profile, d.type)
      var args = Model.modifyArgs(profile, d.type)
      var previous = applied[d.device]
      var samePath = previous && previous.path === d.path

      if (samePath && previous.sig === sig) {
        nextApplied[d.device] = previous
        continue
      }

      // Runtime settings from an earlier profile on this same activation are
      // cleared first, so a profile only ever adds to the saved connection.
      var reset = samePath || (_startup && args.length > 0)
      if (reset) runAction(["nmcli", "device", "reapply", d.device], "Couldn't reset " + d.device)
      if (args.length > 0) {
        var entry = { path: d.path, sig: sig, failed: false, at: Date.now() }
        nextApplied[d.device] = entry
        runAction(["nmcli", "device", "modify", d.device].concat(args), "Couldn't apply " + profile.name + " to " + d.device, entry)
      }
    }
    applied = nextApplied
    _startup = false
  }

  // A failed apply is recorded, not retried on every event: the next retry
  // is the next reconnect or profile switch.
  function runAction(argv, failure, entry) {
    actions.run(argv, function(code, out, err) {
      if (code === 0) return
      if (entry) entry.failed = true
      console.warn("mib-nprofiles: " + argv.join(" ") + " -> " + code + " " + err)
      root.reportError(failure + ": " + Model.errorLine(err))
    })
  }

  function reportError(message) {
    lastError = message
    if (config.notify) notify("󰾲", "normal", "Network profile", message)
  }

  // ----------------------------------------------------------- notifying

  function notifySwitch(profile, ruleIndex) {
    var rule = ruleIndex >= 0 ? config.rules[ruleIndex] : null
    var why = "No rule matched"
    if (rule && rule.when === "wifi") why = "Connected to " + rule.ssid
    else if (rule && rule.when === "inrange") why = rule.ssid + " is in range"
    else if (rule && rule.when === "ethernet") why = "Ethernet connected"
    notify("󰾲", "low", "Network profile: " + profile.name, why)
  }

  // argv, never a shell string; the body is markup-escaped because Omarchy
  // renders it as StyledText and it can carry an SSID from the air.
  property var _notifyQueue: []
  function notify(glyph, urgency, summary, body) {
    _notifyQueue.push([
      "omarchy-notification-send", "-g", glyph, "-u", urgency, "-t", "6000",
      "--app-name", "mib-nprofiles", Model.cleanText(summary, 120), Model.escapeMarkup(Model.cleanText(body, 240))
    ])
    if (!notifyProc.running) drainNotify()
  }
  function drainNotify() {
    if (_notifyQueue.length === 0) return
    notifyProc.command = _notifyQueue.shift()
    notifyProc.running = true
  }

  // ----------------------------------------------------------- public API

  function profileNamed(text) {
    var needle = Model.cleanText(text, 60).toLowerCase()
    for (var i = 0; i < profiles.length; i++) if (profiles[i].name.toLowerCase() === needle) return profiles[i]
    return null
  }

  function saveProfile(profile) {
    var list = config.profiles.slice()
    var found = false
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === profile.id) { list[i] = profile; found = true }
    }
    if (!found) {
      if (list.length >= Model.MAX_PROFILES) return false
      list.push(profile)
    }
    persist({ profiles: list })
    // Editing the active profile re-applies it on the spot.
    if (profile.id === config.activeProfile) Qt.callLater(root.evaluate)
    return true
  }

  function deleteProfile(id) {
    var cfg = config
    var list = cfg.profiles.filter(function(p) { return p.id !== id })
    var rules = cfg.rules.filter(function(r) { return r.profile !== id })
    var values = { profiles: list, rules: rules }
    if (cfg.fallbackProfile === id) values.fallbackProfile = Model.AUTOMATIC
    var wasActive = cfg.activeProfile === id
    persist(values)
    // Back to Automatic without pinning it, then let the rules decide.
    if (wasActive) {
      activate(Model.AUTOMATIC, {})
      Qt.callLater(root.evaluate)
    }
  }

  function saveRules(rules) {
    persist({ rules: rules.slice(0, Model.MAX_RULES) })
    Qt.callLater(root.evaluate)
  }

  function setAutoSwitch(on) {
    persist({ autoSwitch: on === true, pinnedNetwork: "" })
    Qt.callLater(root.evaluate)
  }

  function setFallback(id) {
    persist({ fallbackProfile: id })
    Qt.callLater(root.evaluate)
  }

  // Hand control back to the rules now, without waiting for a network change.
  function resumeAuto() {
    persist({ pinnedNetwork: "" })
    Qt.callLater(root.evaluate)
  }

  // ------------------------------------------------------------ plumbing

  Runner { id: reads; timeoutMs: 15000 }
  Runner { id: actions; timeoutMs: 45000 }

  Process {
    id: notifyProc
    onExited: root.drainNotify()
  }

  // One long-lived `nmcli monitor`: any line means something changed. The
  // burst of lines a reconnect produces collapses into one refresh.
  Process {
    id: monitor
    command: ["nmcli", "monitor"]
    environment: ({ LC_ALL: "C" })
    running: true
    stdout: SplitParser { onRead: function(line) { refreshDebounce.restart() } }
    onExited: monitorRestart.restart()
  }

  Timer {
    id: monitorRestart
    interval: 5000
    onTriggered: monitor.running = true
  }

  Timer {
    id: refreshDebounce
    interval: 600
    onTriggered: root.refresh(false)
  }

  // Catches what `nmcli monitor` doesn't report: missed events, and a device
  // reset behind our back (see verify()).
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.refresh(false)
  }

  // In-range rules: read the scan list steadily, and ask for a fresh scan
  // every fourth tick (two minutes). Idle when no rule needs it.
  property int _scanTick: 0
  Timer {
    interval: 30000
    running: root.ready && Model.hasInRangeRule(root.config)
    repeat: true
    onTriggered: {
      root._scanTick = (root._scanTick + 1) % 4
      if (root._scanTick === 0) actions.run(["nmcli", "device", "wifi", "rescan"], null)
      root.refresh(true)
    }
  }

  FileView {
    path: "/etc/NetworkManager/conf.d/20-omarchy-dns.conf"
    watchChanges: true
    printErrors: false
    onLoaded: root.globalDns = Model.globalDnsServers(text())
    onLoadFailed: root.globalDns = ""
    onFileChanged: reload()
  }

  onSettingsKnownChanged: loadState()
  Component.onCompleted: {
    loadState()
    refresh(true)
  }

  // --------------------------------------------------------------- IPC

  IpcHandler {
    target: root.pluginId

    function list(): string {
      var out = []
      for (var i = 0; i < root.profiles.length; i++) {
        var p = root.profiles[i]
        out.push((p.id === root.config.activeProfile ? "* " : "  ") + p.name + " — " + Model.profileSummary(p))
      }
      return out.join("\n")
    }
    function current(): string { return root.activeProfile.name }
    // `use Home` switches like a click in the popup.
    function use(name: string): string {
      var p = root.profileNamed(name)
      if (!p) return "no profile called " + name
      root.activate(p.id, { pin: true })
      return "using " + p.name
    }
    function auto(state: string): string {
      var s = String(state || "").toLowerCase()
      if (s === "on" || s === "true") root.setAutoSwitch(true)
      else if (s === "off" || s === "false") root.setAutoSwitch(false)
      else if (s === "resume") root.resumeAuto()
      return root.config.autoSwitch ? (root.pinned ? "on (paused until the network changes)" : "on") : "off"
    }
    function state(): string {
      var lines = [
        "profile: " + root.activeProfile.name,
        "auto-switch: " + (root.config.autoSwitch ? (root.pinned ? "paused" : "on") : "off"),
        "network: " + root.networkText
      ]
      for (var i = 0; i < root.devices.length; i++) {
        var d = root.devices[i]
        var a = root.applied[d.device]
        lines.push(d.device + ": " + d.connection + (a ? (a.failed ? " (apply failed)" : " (profile applied)") : ""))
      }
      lines.push("settings: " + (root.pushedSettings ? "from widget" : (root.snapshotSettings ? "from bar config" : "not found"))
        + (root.shell ? "" : " (no shell)") + (root.shell && root.shell.barConfig && root.shell.barConfig.layout ? "" : " (no layout)"))
      if (root.globalDns !== "") lines.push("omarchy dns override: " + root.globalDns)
      if (root.lastError !== "") lines.push("last error: " + root.lastError)
      return lines.join("\n")
    }
    function refresh(): string { root.refresh(true); return "ok" }
  }
}
