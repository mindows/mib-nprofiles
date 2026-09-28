.pragma library

// Pure logic for network profiles: nmcli output parsing, validation, the
// settings shape, the nmcli arguments a profile turns into, and rule
// evaluation. No QML dependencies, so it runs under node for the tests in
// tests/.

var AUTOMATIC = "automatic"
var MAX_PROFILES = 12
var MAX_RULES = 16
var MAX_DNS = 4
var MAX_SEARCH = 6
var NAME_MAX = 40

var RULE_KINDS = [
  { value: "wifi", label: "Connected to Wi-Fi" },
  { value: "inrange", label: "Wi-Fi in range" },
  { value: "ethernet", label: "Ethernet connected" }
]

var IPV4_MODES = [
  { value: "", label: "As saved" },
  { value: "dhcp", label: "DHCP" },
  { value: "manual", label: "Manual" }
]

var IPV6_MODES = [
  { value: "", label: "As saved" },
  { value: "off", label: "Off" }
]

var DEVICE_KINDS = [
  { value: "wifi", label: "Wi-Fi" },
  { value: "ethernet", label: "Ethernet" }
]

// ------------------------------------------------------------------- text

// Anything we show that came from outside our own code (SSIDs are whatever a
// nearby access point broadcasts, connection names are user-chosen) goes
// through here. Invisible format, bidi, tag and variation-selector characters
// are deleted outright, since the soft hyphen, ZWJ and selectors sit inside
// ordinary words and emoji; control characters and line separators become
// spaces; whitespace is collapsed; the length is capped with an ellipsis,
// never splitting a surrogate pair.
var INVISIBLE = /[\u00ad\u061c\u180e\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufe00-\ufe0f\ufeff\ufff9-\ufffb\u{e0000}-\u{e007f}\u{e0100}-\u{e01ef}]/gu
var BREAKING = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g

function cleanText(value, max) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(INVISIBLE, "").replace(BREAKING, " ")
  text = text.replace(/\s+/g, " ").trim()
  var cap = max || 120
  if (text.length <= cap) return text
  var cut = text.slice(0, cap - 1)
  if (/[\ud800-\udbff]$/.test(cut)) cut = cut.slice(0, -1)
  return cut.replace(/\s+$/, "") + "\u2026"
}

// For a notification body, which Omarchy renders as StyledText.
function escapeMarkup(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

// ----------------------------------------------------------- nmcli parsing

// One line of `nmcli -t` output. Fields are split on ':', and nmcli escapes
// a literal ':' or '\' inside a value with a backslash.
function splitTerse(line) {
  var fields = []
  var current = ""
  var text = String(line || "")
  for (var i = 0; i < text.length; i++) {
    var c = text[i]
    if (c === "\\" && i + 1 < text.length) {
      current += text[i + 1]
      i++
    } else if (c === ":") {
      fields.push(current)
      current = ""
    } else {
      current += c
    }
  }
  fields.push(current)
  return fields
}

function lines(text) {
  return String(text || "").split("\n").filter(function(l) { return l !== "" })
}

// `nmcli -t -f DEVICE,TYPE,STATE,CON-UUID,CON-PATH,CONNECTION device status`
// -> connected Wi-Fi and Ethernet devices only. Everything else (loopback,
// tun devices such as tailscale0, p2p) is never ours to touch.
//
// nmcli doesn't escape a newline in the connection name, and NetworkManager
// names a new Wi-Fi connection after its SSID, so a network name can start a
// line of its own. A real row must carry a UUID and an active-connection
// path, which together don't fit in an SSID's 32 bytes, so such a line can't
// pose as a connected device (say, Ethernet, to trigger an Ethernet rule).
function parseDevices(text) {
  var out = []
  var rows = lines(text)
  for (var i = 0; i < rows.length; i++) {
    var f = splitTerse(rows[i])
    if (f.length < 6) continue
    var type = f[1]
    if (type !== "wifi" && type !== "ethernet") continue
    if (f[2] !== "connected") continue
    if (!/^[A-Za-z0-9_.:@-]{1,15}$/.test(f[0])) continue
    if (!isUuid(f[3]) || !/^\/org\/freedesktop\/NetworkManager\/ActiveConnection\/\d+$/.test(f[4])) continue
    out.push({
      device: f[0],
      type: type,
      uuid: f[3],
      path: f[4],
      connection: cleanText(f.slice(5).join(":"), NAME_MAX)
    })
  }
  return out
}

// An SSID is up to 32 arbitrary bytes, chosen by whoever runs the access
// point, and nmcli doesn't escape a newline inside one. Read as SSID-HEX, a
// hostile name can't break the line format and forge "connected to <your home
// network>". Decoded as UTF-8, or byte-for-byte when it isn't valid UTF-8.
function decodeSsidHex(hex) {
  var text = String(hex || "")
  if (!/^([0-9A-Fa-f]{2}){1,32}$/.test(text)) return ""
  var escaped = text.replace(/(..)/g, "%$1")
  var decoded
  try {
    decoded = decodeURIComponent(escaped)
  } catch (e) {
    decoded = text.replace(/(..)/g, function(pair) { return String.fromCharCode(parseInt(pair, 16)) })
  }
  return cleanText(decoded, 64)
}

// `nmcli -t -f ACTIVE,SSID-HEX device wifi list --rescan no`
// -> { connected: [ssid], visible: [ssid] }, deduplicated, hidden networks
// (empty SSID) dropped.
function parseWifiList(text) {
  var connected = []
  var visible = []
  var rows = lines(text)
  for (var i = 0; i < rows.length; i++) {
    var f = splitTerse(rows[i])
    if (f.length !== 2 || (f[0] !== "yes" && f[0] !== "no")) continue
    var ssid = decodeSsidHex(f[1])
    if (ssid === "") continue
    if (visible.indexOf(ssid) === -1) visible.push(ssid)
    if (f[0] === "yes" && connected.indexOf(ssid) === -1) connected.push(ssid)
  }
  return { connected: connected, visible: visible }
}

// `nmcli -t -f NAME,UUID,TYPE connection show`
// -> { wifi: [{name, uuid}], vpn: [{name, uuid}] }
function parseConnections(text) {
  var wifi = []
  var vpn = []
  var rows = lines(text)
  for (var i = 0; i < rows.length; i++) {
    var f = splitTerse(rows[i])
    if (f.length < 3) continue
    var type = f[f.length - 1]
    var uuid = f[f.length - 2]
    var name = cleanText(f.slice(0, f.length - 2).join(":"), NAME_MAX)
    if (!isUuid(uuid) || name === "") continue
    if (type === "802-11-wireless") wifi.push({ name: name, uuid: uuid })
    else if (type === "vpn" || type === "wireguard") vpn.push({ name: name, uuid: uuid })
  }
  var byName = function(a, b) { return a.name.localeCompare(b.name) }
  wifi.sort(byName)
  vpn.sort(byName)
  return { wifi: wifi, vpn: vpn }
}

// /etc/NetworkManager/conf.d/20-omarchy-dns.conf, as `omarchy dns` writes it.
// Servers under [global-dns-domain-*] override every connection's DNS, so a
// profile's DNS would silently do nothing. -> the server list, or "".
function globalDnsServers(text) {
  var section = ""
  var rows = String(text || "").split("\n")
  for (var i = 0; i < rows.length; i++) {
    var line = rows[i].trim()
    if (line === "" || line[0] === "#") continue
    var header = /^\[(.*)\]$/.exec(line)
    if (header) { section = header[1].trim(); continue }
    var m = /^servers\s*=\s*(.*)$/.exec(line)
    if (m && section === "global-dns-domain-*") return cleanText(m[1], 200)
  }
  return ""
}

// ------------------------------------------------------------- validation

function isUuid(value) {
  return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(String(value || ""))
}

function isIPv4(value) {
  var m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(String(value || ""))
  if (!m) return false
  for (var i = 1; i <= 4; i++) {
    if (m[i].length > 1 && m[i][0] === "0") return false
    if (parseInt(m[i], 10) > 255) return false
  }
  return true
}

function isIPv6(value) {
  var text = String(value || "")
  if (text.length < 2 || text.length > 45 || !/^[0-9a-fA-F:.]+$/.test(text)) return false
  var tail = 0
  var lastColon = text.lastIndexOf(":")
  if (text.indexOf(".") !== -1) {
    if (!isIPv4(text.slice(lastColon + 1))) return false
    text = text.slice(0, lastColon + 1) + "0:0"
  }
  var doubles = text.split("::").length - 1
  if (doubles > 1) return false
  var groups = text.split(":")
  var empty = 0
  for (var i = 0; i < groups.length; i++) {
    if (groups[i] === "") { empty++; continue }
    if (!/^[0-9a-fA-F]{1,4}$/.test(groups[i])) return false
    tail++
  }
  if (doubles === 0) return groups.length === 8 && empty === 0
  if (/^:[^:]/.test(text) || /[^:]:$/.test(text)) return false
  return tail < 8
}

// "192.168.1.50/24" -> { address, prefix } or null. A bare address gets /24,
// what almost every home and office LAN uses.
function parseCidr(value) {
  var text = String(value || "").trim()
  var m = /^([0-9.]+)(?:\/(\d{1,2}))?$/.exec(text)
  if (!m || !isIPv4(m[1])) return null
  var prefix = m[2] === undefined ? 24 : parseInt(m[2], 10)
  if (prefix < 1 || prefix > 32) return null
  return { address: m[1], prefix: prefix }
}

function splitList(value) {
  if (Array.isArray(value)) return value.map(function(v) { return String(v).trim() }).filter(function(v) { return v !== "" })
  return String(value || "").split(/[\s,;]+/).filter(function(v) { return v !== "" })
}

// -> { servers: [...], error: "" }
function parseDnsList(value) {
  var items = splitList(value)
  var servers = []
  for (var i = 0; i < items.length; i++) {
    var item = items[i]
    if (!isIPv4(item) && !isIPv6(item)) return { servers: [], error: "\u201c" + cleanText(item, 40) + "\u201d isn't an IP address." }
    if (servers.indexOf(item) === -1) servers.push(item)
  }
  if (servers.length > MAX_DNS) return { servers: [], error: "At most " + MAX_DNS + " DNS servers." }
  return { servers: servers, error: "" }
}

function isDomain(value) {
  var text = String(value || "")
  if (text.length > 253) return false
  var labels = text.split(".")
  for (var i = 0; i < labels.length; i++) {
    if (!/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(labels[i])) return false
  }
  return true
}

// -> { domains: [...], error: "" }
function parseSearchList(value) {
  var items = splitList(value)
  var domains = []
  for (var i = 0; i < items.length; i++) {
    var item = items[i].replace(/\.$/, "").toLowerCase()
    if (!isDomain(item)) return { domains: [], error: "\u201c" + cleanText(items[i], 40) + "\u201d isn't a domain name." }
    if (domains.indexOf(item) === -1) domains.push(item)
  }
  if (domains.length > MAX_SEARCH) return { domains: [], error: "At most " + MAX_SEARCH + " search domains." }
  return { domains: domains, error: "" }
}

// ---------------------------------------------------------------- profiles

function newId(existing) {
  var taken = existing || []
  for (;;) {
    var id = "p" + Math.floor(Math.random() * 0x7fffffff).toString(36)
    if (taken.indexOf(id) === -1) return id
  }
}

function isProfileId(value) {
  return /^p[0-9a-z]{1,12}$/.test(String(value || ""))
}

function automaticProfile() {
  return {
    id: AUTOMATIC, name: "Automatic",
    ipv4: { mode: "", address: "", gateway: "", device: "wifi" },
    dns: [], search: [], ipv6: "", wifi: null, vpn: null
  }
}

function normalizeConnectionRef(value) {
  if (!value || typeof value !== "object" || !isUuid(value.uuid)) return null
  return { uuid: String(value.uuid).toLowerCase(), name: cleanText(value.name, NAME_MAX) || "Saved connection" }
}

// A profile as stored, rebuilt field by field. Anything malformed in a
// hand-edited shell.json is dropped rather than passed to nmcli; returns null
// when there is nothing usable (no id or no name).
function normalizeProfile(raw) {
  if (!raw || typeof raw !== "object" || !isProfileId(raw.id)) return null
  var name = cleanText(raw.name, NAME_MAX)
  if (name === "") return null

  var v4 = raw.ipv4 && typeof raw.ipv4 === "object" ? raw.ipv4 : {}
  var ipv4 = { mode: "", address: "", gateway: "", device: v4.device === "ethernet" ? "ethernet" : "wifi" }
  if (v4.mode === "dhcp") ipv4.mode = "dhcp"
  if (v4.mode === "manual") {
    var cidr = parseCidr(v4.address)
    if (cidr) {
      ipv4.mode = "manual"
      ipv4.address = cidr.address + "/" + cidr.prefix
      ipv4.gateway = isIPv4(v4.gateway) ? String(v4.gateway) : ""
    }
  }

  var dns = parseDnsList(raw.dns)
  var search = parseSearchList(raw.search)

  return {
    id: raw.id,
    name: name,
    ipv4: ipv4,
    dns: dns.servers,
    search: search.domains,
    ipv6: raw.ipv6 === "off" ? "off" : "",
    wifi: normalizeConnectionRef(raw.wifi),
    vpn: normalizeConnectionRef(raw.vpn)
  }
}

function normalizeRule(raw, profileIds) {
  if (!raw || typeof raw !== "object") return null
  var when = raw.when
  if (when !== "wifi" && when !== "inrange" && when !== "ethernet") return null
  var profile = String(raw.profile || "")
  if (profile !== AUTOMATIC && profileIds.indexOf(profile) === -1) return null
  var ssid = when === "ethernet" ? "" : cleanText(raw.ssid, 64)
  if (when !== "ethernet" && ssid === "") return null
  return { when: when, ssid: ssid, profile: profile }
}

// The whole settings entry, normalized. Unknown profile references (a rule
// or the active profile pointing at a deleted profile) fall back to
// Automatic rather than failing.
function normalizeSettings(raw) {
  // Settings handed over by the host can be Qt list/map wrappers, for which
  // Array.isArray() is false. A JSON round trip makes them plain JS.
  var s = {}
  try { s = raw && typeof raw === "object" ? JSON.parse(JSON.stringify(raw)) : {} } catch (e) { s = {} }
  var profiles = []
  var ids = []
  var names = []
  var list = Array.isArray(s.profiles) ? s.profiles : []
  for (var i = 0; i < list.length && profiles.length < MAX_PROFILES; i++) {
    var p = normalizeProfile(list[i])
    if (!p || ids.indexOf(p.id) !== -1 || names.indexOf(p.name.toLowerCase()) !== -1) continue
    if (p.name.toLowerCase() === "automatic") continue
    ids.push(p.id)
    names.push(p.name.toLowerCase())
    profiles.push(p)
  }

  var rules = []
  var ruleList = Array.isArray(s.rules) ? s.rules : []
  for (var r = 0; r < ruleList.length && rules.length < MAX_RULES; r++) {
    var rule = normalizeRule(ruleList[r], ids)
    if (rule) rules.push(rule)
  }

  var known = function(id) { return id === AUTOMATIC || ids.indexOf(id) !== -1 }
  var active = known(s.activeProfile) ? s.activeProfile : AUTOMATIC
  var fallback = known(s.fallbackProfile) ? s.fallbackProfile : AUTOMATIC

  return {
    profiles: profiles,
    rules: rules,
    fallbackProfile: fallback,
    activeProfile: active,
    autoSwitch: s.autoSwitch !== false,
    notify: s.notify !== false,
    pinnedNetwork: typeof s.pinnedNetwork === "string" ? s.pinnedNetwork.slice(0, 1024) : ""
  }
}

function findProfile(settings, id) {
  if (id === AUTOMATIC) return automaticProfile()
  var list = settings && settings.profiles ? settings.profiles : []
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
  return null
}

// Editor form values -> { profile, error }. The form keeps text fields as
// text; this is the single place they are checked.
function profileFromForm(form, existingProfiles, editingId) {
  var name = cleanText(form.name, NAME_MAX)
  if (name === "") return { profile: null, error: "Give the profile a name." }
  if (name.toLowerCase() === "automatic") return { profile: null, error: "\u201cAutomatic\u201d is built in. Pick another name." }
  var others = existingProfiles || []
  for (var i = 0; i < others.length; i++) {
    if (others[i].id !== editingId && others[i].name.toLowerCase() === name.toLowerCase())
      return { profile: null, error: "There is already a profile called " + others[i].name + "." }
  }

  var ipv4 = { mode: "", address: "", gateway: "", device: form.ipv4Device === "ethernet" ? "ethernet" : "wifi" }
  if (form.ipv4Mode === "dhcp") ipv4.mode = "dhcp"
  if (form.ipv4Mode === "manual") {
    var cidr = parseCidr(form.ipv4Address)
    if (!cidr) return { profile: null, error: "Enter the address as 192.168.1.50/24." }
    var gateway = String(form.ipv4Gateway || "").trim()
    if (gateway !== "" && !isIPv4(gateway)) return { profile: null, error: "The gateway isn't an IPv4 address." }
    ipv4.mode = "manual"
    ipv4.address = cidr.address + "/" + cidr.prefix
    ipv4.gateway = gateway
  }

  var dns = parseDnsList(form.dns)
  if (dns.error) return { profile: null, error: dns.error }
  var search = parseSearchList(form.search)
  if (search.error) return { profile: null, error: search.error }

  var ids = others.map(function(p) { return p.id })
  var profile = normalizeProfile({
    id: editingId || newId(ids),
    name: name,
    ipv4: ipv4,
    dns: dns.servers,
    search: search.domains,
    ipv6: form.ipv6 === "off" ? "off" : "",
    wifi: form.wifi || null,
    vpn: form.vpn || null
  })
  return { profile: profile, error: profile ? "" : "That profile couldn't be saved." }
}

function formFromProfile(profile) {
  var p = profile || automaticProfile()
  return {
    name: p.id === AUTOMATIC ? "" : p.name,
    ipv4Mode: p.ipv4.mode,
    ipv4Address: p.ipv4.address,
    ipv4Gateway: p.ipv4.gateway,
    ipv4Device: p.ipv4.device,
    dns: p.dns.join(", "),
    search: p.search.join(", "),
    ipv6: p.ipv6,
    wifi: p.wifi,
    vpn: p.vpn
  }
}

// One line describing what a profile changes, for the list rows.
function profileSummary(profile) {
  if (!profile || profile.id === AUTOMATIC) return "Settings from each network"
  var parts = []
  if (profile.ipv4.mode === "manual") parts.push(profile.ipv4.address + " on " + (profile.ipv4.device === "ethernet" ? "Ethernet" : "Wi-Fi"))
  else if (profile.ipv4.mode === "dhcp") parts.push("DHCP")
  if (profile.dns.length > 0) parts.push("DNS " + profile.dns.slice(0, 2).join(", ") + (profile.dns.length > 2 ? "\u2026" : ""))
  if (profile.search.length > 0) parts.push("search " + profile.search[0] + (profile.search.length > 1 ? "\u2026" : ""))
  if (profile.ipv6 === "off") parts.push("IPv6 off")
  if (profile.wifi) parts.push("joins " + profile.wifi.name)
  if (profile.vpn) parts.push("VPN " + profile.vpn.name)
  return parts.length > 0 ? parts.join(" \u00b7 ") : "No changes"
}

// -------------------------------------------------------------- nmcli args

// The `nmcli device modify <dev>` property/value pairs a profile needs on one
// device, or [] when it changes nothing there. Every value is a separate argv
// element; nothing here is ever joined into a shell string.
function modifyArgs(profile, deviceType) {
  if (!profile || profile.id === AUTOMATIC) return []
  var args = []

  if (profile.ipv4.mode === "dhcp") {
    args.push("ipv4.method", "auto", "ipv4.addresses", "", "ipv4.gateway", "")
  } else if (profile.ipv4.mode === "manual" && profile.ipv4.device === deviceType) {
    args.push("ipv4.method", "manual", "ipv4.addresses", profile.ipv4.address, "ipv4.gateway", profile.ipv4.gateway)
  }

  var ipv6Off = profile.ipv6 === "off"
  if (ipv6Off) args.push("ipv6.method", "disabled")

  if (profile.dns.length > 0) {
    var v4 = profile.dns.filter(isIPv4)
    var v6 = profile.dns.filter(function(s) { return !isIPv4(s) })
    // Ignore the network's own DNS on both families, or a router advertising
    // an IPv6 resolver would keep answering alongside ours.
    args.push("ipv4.ignore-auto-dns", "yes", "ipv4.dns", v4.join(","))
    if (!ipv6Off) args.push("ipv6.ignore-auto-dns", "yes", "ipv6.dns", v6.join(","))
  }
  if (profile.search.length > 0) args.push("ipv4.dns-search", profile.search.join(","))

  return args
}

// `nmcli -t -f IP4.ADDRESS,IP4.DNS,IP6.ADDRESS,IP6.DNS device show <dev>`
// -> the live values. Split at the first ':' only, since IPv6 values carry
// their own colons (older nmcli escapes them, newer doesn't).
function parseDeviceShow(text) {
  var state = { ip4Address: [], ip4Dns: [], ip6Address: [], ip6Dns: [] }
  var keys = { "IP4.ADDRESS": "ip4Address", "IP4.DNS": "ip4Dns", "IP6.ADDRESS": "ip6Address", "IP6.DNS": "ip6Dns" }
  var rows = lines(text)
  for (var i = 0; i < rows.length; i++) {
    var colon = rows[i].indexOf(":")
    if (colon < 0) continue
    var key = rows[i].slice(0, colon).replace(/\[\d+\]$/, "")
    var value = rows[i].slice(colon + 1).replace(/\\(.)/g, "$1").trim()
    if (keys[key] && value !== "") state[keys[key]].push(value)
  }
  return state
}

// Does a device still carry what the profile set? Nothing tells us when
// something else resets a device (`omarchy dns` reapplies every connection,
// for one), so the live values are compared on each refresh. Only what can be
// read back reliably is compared: IPv4 DNS, IPv6 being off, a manual
// address. Anything else counts as still applied.
function deviceMatchesProfile(profile, deviceType, state) {
  if (modifyArgs(profile, deviceType).length === 0) return true
  var v4 = profile.dns.filter(isIPv4)
  if (v4.length > 0 && state.ip4Dns.join(",") !== v4.join(",")) return false
  if (profile.ipv6 === "off" && state.ip6Address.length > 0) return false
  if (profile.ipv4.mode === "manual" && profile.ipv4.device === deviceType
      && state.ip4Address.indexOf(profile.ipv4.address) === -1) return false
  return true
}

// Identifies what a profile does to one device type, so re-applying the same
// thing after an unrelated NetworkManager event is skipped.
function applySignature(profile, deviceType) {
  return JSON.stringify(modifyArgs(profile, deviceType))
}

// ------------------------------------------------------------------- rules

// Which networks we're on, as one comparable string. A manual pick holds
// until this changes.
function networkFingerprint(network) {
  var wifi = (network && network.wifi ? network.wifi : []).slice().sort()
  var parts = wifi.map(function(s) { return "wifi:" + s })
  if (network && network.ethernet) parts.push("ethernet")
  return parts.join("\n")
}

function ruleMatches(rule, network) {
  var wifi = network.wifi || []
  if (rule.when === "wifi") return wifi.indexOf(rule.ssid) !== -1
  if (rule.when === "inrange") return wifi.indexOf(rule.ssid) !== -1 || (network.inRange || []).indexOf(rule.ssid) !== -1
  if (rule.when === "ethernet") return network.ethernet === true
  return false
}

// -> { profile: id, rule: index or -1 for the fallback }
function evaluateRules(settings, network) {
  var rules = settings.rules || []
  for (var i = 0; i < rules.length; i++) {
    if (ruleMatches(rules[i], network)) return { profile: rules[i].profile, rule: i }
  }
  return { profile: settings.fallbackProfile || AUTOMATIC, rule: -1 }
}

// In-range readings flicker at the edge of reception. An SSID enters the
// stable set only after two consecutive scans have seen it, and leaves only
// after two consecutive scans have missed it.
function stabilize(stable, previous, current) {
  var next = []
  var i
  for (i = 0; i < stable.length; i++) {
    var s = stable[i]
    if (current.indexOf(s) !== -1 || previous.indexOf(s) !== -1) next.push(s)
  }
  for (i = 0; i < current.length; i++) {
    var c = current[i]
    if (next.indexOf(c) === -1 && previous.indexOf(c) !== -1) next.push(c)
  }
  return next
}

function hasInRangeRule(settings) {
  var rules = settings.rules || []
  for (var i = 0; i < rules.length; i++) if (rules[i].when === "inrange") return true
  return false
}

function ruleLabel(rule, profileName) {
  var when = rule.when === "ethernet" ? "Ethernet connected"
    : (rule.when === "inrange" ? rule.ssid + " in range" : "On " + rule.ssid)
  return when + " \u2192 " + profileName
}

// "wlp61s0: Name resolution failed" style nmcli errors, trimmed to one line.
function errorLine(stderr) {
  var text = cleanText(String(stderr || "").replace(/^Error:\s*/i, ""), 160)
  return text === "" ? "nmcli failed" : text
}

if (typeof module !== "undefined") {
  module.exports = {
    AUTOMATIC: AUTOMATIC, MAX_PROFILES: MAX_PROFILES, MAX_RULES: MAX_RULES,
    cleanText: cleanText, escapeMarkup: escapeMarkup,
    splitTerse: splitTerse, parseDevices: parseDevices, parseWifiList: parseWifiList, decodeSsidHex: decodeSsidHex,
    parseConnections: parseConnections, globalDnsServers: globalDnsServers,
    isUuid: isUuid, isIPv4: isIPv4, isIPv6: isIPv6, parseCidr: parseCidr,
    parseDnsList: parseDnsList, parseSearchList: parseSearchList, isDomain: isDomain,
    newId: newId, isProfileId: isProfileId, automaticProfile: automaticProfile,
    normalizeProfile: normalizeProfile, normalizeRule: normalizeRule, normalizeSettings: normalizeSettings,
    findProfile: findProfile, profileFromForm: profileFromForm, formFromProfile: formFromProfile,
    profileSummary: profileSummary, modifyArgs: modifyArgs, applySignature: applySignature,
    parseDeviceShow: parseDeviceShow, deviceMatchesProfile: deviceMatchesProfile,
    networkFingerprint: networkFingerprint, ruleMatches: ruleMatches, evaluateRules: evaluateRules,
    stabilize: stabilize, hasInRangeRule: hasInRangeRule, ruleLabel: ruleLabel, errorLine: errorLine
  }
}
