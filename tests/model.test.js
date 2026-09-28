// Run with: node --test tests/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

// Model.js starts with QML's `.pragma library`, which isn't JavaScript.
const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const module_ = { exports: {} }
new Function("module", source)(module_)
const M = module_.exports

const AUTO = "automatic"

test("splitTerse unescapes colons and backslashes", () => {
  assert.deepEqual(M.splitTerse("yes:my\\:net"), ["yes", "my:net"])
  assert.deepEqual(M.splitTerse("a\\\\:b"), ["a\\", "b"])
  assert.deepEqual(M.splitTerse("enp0s31f6:ethernet:unavailable:::"), ["enp0s31f6", "ethernet", "unavailable", "", "", ""])
})

test("parseDevices keeps only connected Wi-Fi and Ethernet", () => {
  const text = [
    "wlp61s0:wifi:connected:4fe5425c-cf89-4d55-9e64-4a2521acbaff:/org/freedesktop/NetworkManager/ActiveConnection/8:mk",
    "tailscale0:tun:connected (externally):f5eed271-9044-4fb8-834e-e6f980e65480:/org/freedesktop/NetworkManager/ActiveConnection/5:tailscale0",
    "lo:loopback:connected (externally):17bb8e9f-0d3a-4719-8e4b-693ca7981547:/org/freedesktop/NetworkManager/ActiveConnection/1:lo",
    "p2p-dev-wlp61s0:wifi-p2p:disconnected:::",
    "enp0s31f6:ethernet:unavailable:::",
    "enp1:ethernet:connected:18693139-2949-3488-be64-6bd741437d7c:/org/freedesktop/NetworkManager/ActiveConnection/9:Wired\\: dock",
  ].join("\n")
  const devices = M.parseDevices(text)
  assert.equal(devices.length, 2)
  assert.deepEqual(devices[0], {
    device: "wlp61s0", type: "wifi", uuid: "4fe5425c-cf89-4d55-9e64-4a2521acbaff",
    path: "/org/freedesktop/NetworkManager/ActiveConnection/8", connection: "mk",
  })
  assert.equal(devices[1].connection, "Wired: dock")
})

test("a connection name with a newline can't forge a device", () => {
  // NetworkManager names a new Wi-Fi connection after the SSID, and nmcli
  // leaves a newline in it unescaped. 23 bytes, so it fits in an SSID.
  const forged = "x:ethernet:connected:::"
  const text = "wlp61s0:wifi:connected:4fe5425c-cf89-4d55-9e64-4a2521acbaff:/org/freedesktop/NetworkManager/ActiveConnection/8:cafe\n" + forged
  const devices = M.parseDevices(text)
  assert.deepEqual(devices.map((d) => d.type), ["wifi"])
})

test("parseWifiList decodes SSID-HEX and separates connected from visible", () => {
  const hex = (s) => Buffer.from(s, "utf8").toString("hex").toUpperCase()
  const text = ["yes:" + hex("mk"), "no:" + hex("work:5G"), "no:", "no:" + hex("mk"), "no:" + hex("caf\u00e9 \u202eevil"), "no:ZZ", "maybe:" + hex("x")].join("\n")
  const list = M.parseWifiList(text)
  assert.deepEqual(list.connected, ["mk"])
  assert.deepEqual(list.visible, ["mk", "work:5G", "caf\u00e9 evil"])
  // Not valid UTF-8: kept byte for byte.
  assert.equal(M.decodeSsidHex("FF41"), "\u00ffA")
  assert.equal(M.decodeSsidHex("41".repeat(33)), "")
})

test("a hostile SSID can't forge a connected network", () => {
  // Broadcast name "x\nyes:mk". Hex keeps it on one line and decodes to
  // text that is not "mk", and nothing marks it connected.
  const hostile = Buffer.from("x\nyes:mk", "utf8").toString("hex").toUpperCase()
  const list = M.parseWifiList("no:" + hostile + "\nyes:" + Buffer.from("cafe").toString("hex"))
  assert.deepEqual(list.connected, ["cafe"])
  assert.deepEqual(list.visible, ["x yes:mk", "cafe"])
  const settings = M.normalizeSettings({ profiles: [{ id: "ph", name: "Home" }], rules: [{ when: "wifi", ssid: "mk", profile: "ph" }] })
  assert.equal(M.evaluateRules(settings, { wifi: list.connected, ethernet: false, inRange: list.visible }).profile, "automatic")
  // Under the old plain-SSID parsing the same broadcast produced a
  // separate "yes:mk" line, i.e. a forged connection to mk.
  const plain = "no:x\nyes:mk\nyes:cafe"
  assert.ok(plain.split("\n").includes("yes:mk"))
})

test("parseConnections picks Wi-Fi and VPN / WireGuard", () => {
  const text = [
    "mk:4fe5425c-cf89-4d55-9e64-4a2521acbaff:802-11-wireless",
    "tailscale0:f5eed271-9044-4fb8-834e-e6f980e65480:tun",
    "Office\\: VPN:0a0a0a0a-0000-4000-8000-000000000001:vpn",
    "wg0:0a0a0a0a-0000-4000-8000-000000000002:wireguard",
    "Wired connection 1:18693139-2949-3488-be64-6bd741437d7c:802-3-ethernet",
  ].join("\n")
  const c = M.parseConnections(text)
  assert.deepEqual(c.wifi.map((x) => x.name), ["mk"])
  assert.deepEqual(c.vpn.map((x) => x.name), ["Office: VPN", "wg0"])
})

test("globalDnsServers reads the omarchy dns override", () => {
  const conf = "# written by omarchy-dns\n[global-dns]\n\n[global-dns-domain-*]\nservers=1.1.1.1,1.0.0.1\n"
  assert.equal(M.globalDnsServers(conf), "1.1.1.1,1.0.0.1")
  assert.equal(M.globalDnsServers("[main]\nservers=9.9.9.9\n"), "")
  assert.equal(M.globalDnsServers(""), "")
})

test("address validation", () => {
  assert.ok(M.isIPv4("192.168.1.1"))
  assert.ok(!M.isIPv4("192.168.1.256"))
  assert.ok(!M.isIPv4("01.2.3.4"))
  assert.ok(!M.isIPv4("1.2.3"))
  for (const ok of ["::1", "2606:4700:4700::1111", "fe80::1", "2001:db8::", "::ffff:1.2.3.4", "1:2:3:4:5:6:7:8"])
    assert.ok(M.isIPv6(ok), ok)
  for (const bad of ["1::2::3", ":1", "1:", "12345::", "1:2:3:4:5:6:7:8:9", "g::1", "-1::"])
    assert.ok(!M.isIPv6(bad), bad)
  assert.deepEqual(M.parseCidr("10.0.0.5"), { address: "10.0.0.5", prefix: 24 })
  assert.deepEqual(M.parseCidr(" 10.0.0.5/16 "), { address: "10.0.0.5", prefix: 16 })
  assert.equal(M.parseCidr("10.0.0.5/33"), null)
  assert.equal(M.parseCidr("-10.0.0.5"), null)
})

test("DNS and search lists", () => {
  assert.deepEqual(M.parseDnsList("1.1.1.1, 2606:4700:4700::1111;1.1.1.1"), { servers: ["1.1.1.1", "2606:4700:4700::1111"], error: "" })
  assert.match(M.parseDnsList("1.1.1.1 --help").error, /isn't an IP address/)
  assert.match(M.parseDnsList("1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9").error, /At most/)
  assert.deepEqual(M.parseSearchList("Corp.Example.com. lan").domains, ["corp.example.com", "lan"])
  assert.match(M.parseSearchList("bad_domain").error, /isn't a domain/)
})

test("normalizeSettings drops malformed entries and dangling references", () => {
  const s = M.normalizeSettings({
    profiles: [
      { id: "pa", name: "Home", dns: ["1.1.1.1", "nope"], ipv6: "off" },
      { id: "pa", name: "Duplicate id" },
      { id: "pb", name: "home" },
      { id: "bad id", name: "X" },
      { id: "pc", name: "Automatic" },
      { id: "pd", name: "Work", ipv4: { mode: "manual", address: "10.1.2.3/8", gateway: "10.0.0.1", device: "ethernet" } },
      { id: "pe", name: "Broken static", ipv4: { mode: "manual", address: "garbage" } },
    ],
    rules: [
      { when: "wifi", ssid: "mk", profile: "pa" },
      { when: "wifi", ssid: "", profile: "pa" },
      { when: "inrange", ssid: "work", profile: "gone" },
      { when: "ethernet", ssid: "ignored", profile: "pd" },
      { when: "bogus", profile: "pa" },
    ],
    activeProfile: "gone",
    fallbackProfile: "pd",
  })
  assert.deepEqual(s.profiles.map((p) => p.name), ["Home", "Work", "Broken static"])
  // A whole-list DNS entry with a bad value is dropped, not partially kept.
  assert.deepEqual(s.profiles[0].dns, [])
  assert.equal(s.profiles[0].ipv6, "off")
  assert.deepEqual(s.profiles[1].ipv4, { mode: "manual", address: "10.1.2.3/8", gateway: "10.0.0.1", device: "ethernet" })
  assert.equal(s.profiles[2].ipv4.mode, "")
  assert.deepEqual(s.rules, [
    { when: "wifi", ssid: "mk", profile: "pa" },
    { when: "ethernet", ssid: "", profile: "pd" },
  ])
  assert.equal(s.activeProfile, AUTO)
  assert.equal(s.fallbackProfile, "pd")
  assert.equal(s.autoSwitch, true)
  assert.equal(s.notify, true)
})

test("profileFromForm validates and builds", () => {
  const existing = [{ id: "pa", name: "Home" }]
  assert.match(M.profileFromForm({ name: " " }, existing).error, /name/)
  assert.match(M.profileFromForm({ name: "home" }, existing).error, /already/)
  assert.equal(M.profileFromForm({ name: "home" }, existing, "pa").error, "")
  assert.match(M.profileFromForm({ name: "automatic" }, existing).error, /built in/)
  assert.match(M.profileFromForm({ name: "W", ipv4Mode: "manual", ipv4Address: "x" }, existing).error, /192\.168/)
  assert.match(M.profileFromForm({ name: "W", ipv4Mode: "manual", ipv4Address: "10.0.0.2", ipv4Gateway: "x" }, existing).error, /gateway/)

  const r = M.profileFromForm({
    name: "Work", ipv4Mode: "manual", ipv4Address: "10.0.0.2", ipv4Gateway: "10.0.0.1", ipv4Device: "ethernet",
    dns: "10.0.0.53", search: "corp.lan", ipv6: "off",
    vpn: { uuid: "0A0A0A0A-0000-4000-8000-000000000001", name: "Office" },
  }, existing)
  assert.equal(r.error, "")
  assert.ok(M.isProfileId(r.profile.id))
  assert.notEqual(r.profile.id, "pa")
  assert.equal(r.profile.ipv4.address, "10.0.0.2/24")
  assert.equal(r.profile.vpn.uuid, "0a0a0a0a-0000-4000-8000-000000000001")

  // Round trip through the form keeps everything.
  const again = M.profileFromForm(M.formFromProfile(r.profile), existing, r.profile.id)
  assert.deepEqual(again.profile, r.profile)
})

test("modifyArgs", () => {
  assert.deepEqual(M.modifyArgs(M.automaticProfile(), "wifi"), [])
  const p = M.normalizeProfile({
    id: "pa", name: "Home", dns: ["1.1.1.1", "2606:4700:4700::1111"], search: ["lan"],
  })
  assert.deepEqual(M.modifyArgs(p, "wifi"), [
    "ipv4.ignore-auto-dns", "yes", "ipv4.dns", "1.1.1.1",
    "ipv6.ignore-auto-dns", "yes", "ipv6.dns", "2606:4700:4700::1111",
    "ipv4.dns-search", "lan",
  ])

  const off = M.normalizeProfile({ id: "pb", name: "Off", dns: ["9.9.9.9"], ipv6: "off" })
  assert.deepEqual(M.modifyArgs(off, "wifi"), ["ipv6.method", "disabled", "ipv4.ignore-auto-dns", "yes", "ipv4.dns", "9.9.9.9"])

  const stat = M.normalizeProfile({ id: "pc", name: "Static", ipv4: { mode: "manual", address: "10.0.0.2/24", gateway: "10.0.0.1", device: "ethernet" } })
  assert.deepEqual(M.modifyArgs(stat, "wifi"), [])
  assert.deepEqual(M.modifyArgs(stat, "ethernet"), ["ipv4.method", "manual", "ipv4.addresses", "10.0.0.2/24", "ipv4.gateway", "10.0.0.1"])

  const dhcp = M.normalizeProfile({ id: "pd", name: "DHCP", ipv4: { mode: "dhcp" } })
  assert.deepEqual(M.modifyArgs(dhcp, "ethernet"), ["ipv4.method", "auto", "ipv4.addresses", "", "ipv4.gateway", ""])

  const vpnOnly = M.normalizeProfile({ id: "pe", name: "VPN", vpn: { uuid: "0a0a0a0a-0000-4000-8000-000000000001", name: "x" } })
  assert.deepEqual(M.modifyArgs(vpnOnly, "wifi"), [])
})

test("deviceMatchesProfile reads back what was applied", () => {
  const quad9 = M.normalizeProfile({ id: "pq", name: "Quad9", dns: ["9.9.9.9", "2620:fe::fe"] })
  const applied = M.parseDeviceShow("IP4.ADDRESS[1]:192.168.55.11/24\nIP4.DNS[1]:9.9.9.9\nIP6.ADDRESS[1]:fe80::1/64\nIP6.DNS[1]:2620:fe::fe\n")
  assert.deepEqual(applied.ip6Dns, ["2620:fe::fe"])
  assert.ok(M.deviceMatchesProfile(quad9, "wifi", applied))
  const reset = M.parseDeviceShow("IP4.ADDRESS[1]:192.168.55.11/24\nIP4.DNS[1]:192.168.55.1\nIP6.DNS[1]:2601\\:647\\:\\:1\n")
  assert.deepEqual(reset.ip6Dns, ["2601:647::1"])
  assert.ok(!M.deviceMatchesProfile(quad9, "wifi", reset))

  const off = M.normalizeProfile({ id: "po", name: "Off", ipv6: "off" })
  assert.ok(M.deviceMatchesProfile(off, "wifi", M.parseDeviceShow("IP4.DNS[1]:1.1.1.1\n")))
  assert.ok(!M.deviceMatchesProfile(off, "wifi", applied))

  const stat = M.normalizeProfile({ id: "ps", name: "S", ipv4: { mode: "manual", address: "10.0.0.2/24", device: "ethernet" } })
  assert.ok(M.deviceMatchesProfile(stat, "wifi", reset), "manual IPv4 on Ethernet says nothing about Wi-Fi")
  assert.ok(!M.deviceMatchesProfile(stat, "ethernet", reset))
  assert.ok(M.deviceMatchesProfile(stat, "ethernet", M.parseDeviceShow("IP4.ADDRESS[1]:10.0.0.2/24\n")))
  assert.ok(M.deviceMatchesProfile(M.automaticProfile(), "wifi", reset))
})

test("rules: first match wins, fallback otherwise", () => {
  const settings = M.normalizeSettings({
    profiles: [{ id: "ph", name: "Home" }, { id: "pw", name: "Work" }, { id: "pe", name: "Desk" }],
    rules: [
      { when: "wifi", ssid: "mk", profile: "ph" },
      { when: "ethernet", profile: "pe" },
      { when: "inrange", ssid: "work", profile: "pw" },
    ],
    fallbackProfile: "automatic",
  })
  const at = (network) => M.evaluateRules(settings, network)
  assert.deepEqual(at({ wifi: ["mk"], ethernet: true, inRange: ["work"] }), { profile: "ph", rule: 0 })
  assert.deepEqual(at({ wifi: [], ethernet: true, inRange: [] }), { profile: "pe", rule: 1 })
  assert.deepEqual(at({ wifi: ["cafe"], ethernet: false, inRange: ["work"] }), { profile: "pw", rule: 2 })
  // Being connected counts as in range.
  assert.deepEqual(at({ wifi: ["work"], ethernet: false, inRange: [] }), { profile: "pw", rule: 2 })
  assert.deepEqual(at({ wifi: ["cafe"], ethernet: false, inRange: [] }), { profile: AUTO, rule: -1 })
  assert.ok(M.hasInRangeRule(settings))
})

test("networkFingerprint ignores order and in-range networks", () => {
  const a = M.networkFingerprint({ wifi: ["b", "a"], ethernet: true, inRange: ["x"] })
  const b = M.networkFingerprint({ wifi: ["a", "b"], ethernet: true, inRange: [] })
  assert.equal(a, b)
  assert.notEqual(a, M.networkFingerprint({ wifi: ["a", "b"], ethernet: false }))
})

test("stabilize needs two scans to add or drop", () => {
  let stable = [], prev = []
  const step = (current) => { stable = M.stabilize(stable, prev, current); prev = current; return stable }
  assert.deepEqual(step(["work"]), [])
  assert.deepEqual(step(["work"]), ["work"])
  assert.deepEqual(step([]), ["work"])
  assert.deepEqual(step(["work"]), ["work"])
  assert.deepEqual(step([]), ["work"])
  assert.deepEqual(step([]), [])
})

test("text hygiene", () => {
  assert.equal(M.cleanText("a\u200b\u202eb\n\tc  d"), "ab c d")
  assert.equal(M.cleanText("x".repeat(200)).length, 120)
  assert.equal(M.cleanText("x".repeat(200)).slice(-1), "\u2026")
  // Invisible characters inside words are deleted, not spaced.
  assert.equal(M.cleanText("in\u00advisible zw\u200dj"), "invisible zwj")
  assert.equal(M.cleanText("a" + String.fromCodePoint(0xe0041, 0xe007f) + "b\ufe0f"), "ab")
  // A cap never cuts a surrogate pair in half.
  const capped = M.cleanText("ab" + String.fromCodePoint(0x1f600).repeat(3), 4)
  assert.equal(capped, "ab\u2026")
  assert.equal(M.escapeMarkup('<a href="x">&</a>'), "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;")
  assert.equal(M.errorLine("Error: Connection activation failed.\n"), "Connection activation failed.")
})
