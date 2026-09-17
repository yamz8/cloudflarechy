import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One zone's Cloudflare edge, in the bar.
//
// The question this answers is the one you would otherwise open a browser tab
// for: is traffic normal, is the cache doing its job, is anything switched into
// a state I meant to be temporary. Those last two — Development Mode and Under
// Attack — are the reason the bar icon carries a dot at all. Both are meant to
// be short-lived, both are invisible from the desktop, and both are routinely
// left on for days.
//
// Everything shown comes from the Cloudflare API through bin/cloudflarechy;
// nothing is computed here that the API did not report, except the cache ratio,
// which is cached ÷ total over the same 24 hours.
//
// Deliberately absent: DNS records, firewall rules, R2, Pages. Those are
// editing surfaces, and editing them from a popup you opened by accident is a
// bad idea. The Dashboard button is one click away from all of them.
Panel {
  id: root
  moduleName: "cloudflarechy"
  ipcTarget: "cloudflarechy"
  manageIpc: false

  // The bar sizes a widget from its implicit size, and Ui.Panel is a bare Item
  // with none — without this the widget occupies 0x0 and draws nothing.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // --- settings ------------------------------------------------------------
  // `zone` is a name, not an id: ids are what the API speaks and names are
  // what a person can type into shell.json. Empty means "whichever zone the
  // account lists first".
  readonly property string preferredZone: String(root.setting("zone", "")).trim()
  readonly property int refreshSeconds: Math.max(60, Number(root.setting("refreshSeconds", 300)))
  readonly property bool showTunnels: root.setting("showTunnels", true) === true
  readonly property bool showWorkers: root.setting("showWorkers", true) === true
  readonly property bool attentionDot: root.setting("attentionDot", true) === true

  // --- what came back ------------------------------------------------------
  property var zones: []
  property string zoneId: ""
  property var overview: null
  property var tunnels: []
  property var workers: []

  property bool tokenPresent: true
  property string tokenSource: ""
  property string tokenMessage: ""

  // Which credential answered, and what it is allowed to do. Wrangler's OAuth
  // grant reads everything this panel shows and can write none of it — the
  // whole scope catalogue it can request holds one zone scope, `zone:read`.
  // So the switches are not disabled here out of caution; they are disabled
  // because Cloudflare will not issue the permission to enable them.
  property string tokenKind: ""
  property string tokenExpiresAt: ""
  property bool readOnly: false

  property string error: ""
  property string hint: ""
  property string tunnelsError: ""
  property string workersError: ""

  // The last write this panel asked for, and what came of it. Kept separate
  // from `error`, which is about reading: a purge that failed should not blank
  // the traffic that loaded fine.
  property string busyAction: ""
  property string actionStatus: ""
  property bool actionFailed: false

  property var updatedAt: null
  property bool purgeConfirmOpen: false

  // --- connecting ----------------------------------------------------------
  // The panel used to answer "no token" with a paragraph telling you to go
  // somewhere else and do something. This is that somewhere else.
  property var setupInfo: null
  property bool showSetup: false
  property string setupStatus: ""
  property bool setupFailed: false
  property bool savingToken: false

  // Shown on demand, and unavoidably when there is nothing to show without it.
  readonly property bool setupVisible: root.showSetup || !root.tokenPresent

  readonly property bool loading: bridge.busy

  readonly property var zone: root.overview ? root.overview.zone : root.zoneById(root.zoneId)
  readonly property var analytics: root.overview ? root.overview.analytics : null
  readonly property string analyticsError: root.overview ? (root.overview.analytics_error || "") : ""
  readonly property string accountId: root.zone ? (root.zone.account_id || "") : ""
  readonly property string accountName: root.zone ? (root.zone.account_name || "") : ""

  // `development_mode` is seconds remaining, not a flag: Cloudflare turns it
  // off by itself after three hours. Reading it once gives a deadline, and the
  // countdown then runs against the local clock — polling the API every minute
  // to watch a number go down would be the same answer, billed.
  property double devDeadlineMs: 0
  property double clockMs: 0
  readonly property int devModeSeconds: root.devDeadlineMs > 0
    ? Math.max(0, Math.round((root.devDeadlineMs - root.clockMs) / 1000)) : 0
  readonly property bool devMode: root.devModeSeconds > 0
  readonly property bool underAttack: root.overview ? root.overview.under_attack === true : false
  readonly property bool securityReadable: root.overview
    ? String(root.overview.security_level || "") !== "" : false

  readonly property int troubledTunnels: {
    var n = 0
    for (var i = 0; i < root.tunnels.length; i++) {
      var s = String(root.tunnels[i].status || "")
      if (s === "down" || s === "degraded") n++
    }
    return n
  }

  // What the dot on the bar icon means: something is switched on that was
  // meant to be temporary, or a tunnel is not carrying traffic.
  readonly property bool attention: root.devMode || root.underAttack
                                    || root.troubledTunnels > 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color brand: "#f6821f"
  readonly property int panelContentWidth: Style.space(460)

  // One number and what it counts. Five of these share a row, so the value
  // carries the weight and the label stays out of its way.
  component Stat: Column {
    id: stat
    property string value: ""
    property string label: ""
    property color valueColor: root.foreground
    spacing: 0

    Text {
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      color: stat.valueColor
      textFormat: Text.PlainText
      text: stat.value
    }

    Text {
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      color: root.foreground
      opacity: 0.5
      textFormat: Text.PlainText
      text: stat.label
    }
  }

  // --- reading -------------------------------------------------------------
  function zoneById(id) {
    for (var i = 0; i < root.zones.length; i++)
      if (root.zones[i].id === id) return root.zones[i]
    return null
  }

  // `fresh` bypasses the script's read cache. Background polls do not: the
  // cache is what keeps a 5-minute poll from being 5 API calls a minute when
  // several widgets share a zone.
  function refresh(fresh) {
    bridge.call(["status"], function(payload) {
      if (!payload) return
      root.tokenPresent = payload.token === true
      root.tokenSource = payload.token_source || ""
      root.tokenKind = payload.token_kind || ""
      root.tokenExpiresAt = payload.expires_at || ""
      root.readOnly = payload.read_only === true
      root.tokenMessage = payload.valid === true ? "" : (payload.message || "")
      if (!root.tokenPresent) {
        root.error = payload.message || "no API token"
        root.hint = payload.hint || ""
      }
    }, fresh)

    bridge.call(["zones"], function(payload) { root.applyZones(payload, fresh) }, fresh)
  }

  function applyZones(payload, fresh) {
    if (!payload) return
    if (payload.error) {
      root.error = payload.error
      root.hint = payload.hint || ""
      root.zones = []
      root.overview = null
      return
    }
    root.error = ""
    root.hint = ""
    root.zones = payload.zones || []

    var pick = ""
    if (root.preferredZone !== "") {
      for (var i = 0; i < root.zones.length; i++)
        if (root.zones[i].name === root.preferredZone) { pick = root.zones[i].id; break }
    }
    // A zone chosen in the picker outlives a refresh, but only while the
    // account still lists it.
    if (pick === "" && root.zoneId !== "" && root.zoneById(root.zoneId)) pick = root.zoneId
    if (pick === "" && root.zones.length > 0) pick = root.zones[0].id

    var changed = pick !== root.zoneId
    root.zoneId = pick
    if (changed) root.overview = null
    root.loadZone(fresh)
  }

  function loadZone(fresh) {
    if (root.zoneId === "") return

    bridge.call(["overview", root.zoneId], function(payload) {
      if (!payload) return
      if (payload.error) {
        root.error = payload.error
        root.hint = payload.hint || ""
        return
      }
      root.error = ""
      root.hint = ""
      root.overview = payload
      root.updatedAt = new Date()
      var remaining = Number((payload.zone && payload.zone.development_mode) || 0)
      root.clockMs = Date.now()
      root.devDeadlineMs = remaining > 0 ? root.clockMs + remaining * 1000 : 0
    }, fresh)

    var account = root.accountId
    if (account === "") {
      var z = root.zoneById(root.zoneId)
      account = z ? (z.account_id || "") : ""
    }
    if (account === "") return

    if (root.showTunnels) {
      bridge.call(["tunnels", account], function(payload) {
        if (!payload) return
        root.tunnels = payload.tunnels || []
        root.tunnelsError = payload.error || ""
      }, fresh)
    }
    if (root.showWorkers) {
      bridge.call(["workers", account], function(payload) {
        if (!payload) return
        root.workers = payload.workers || []
        root.workersError = payload.error || ""
      }, fresh)
    }
  }

  function selectZone(id) {
    if (!id || id === root.zoneId) return
    root.zoneId = id
    root.overview = null
    root.tunnels = []
    root.workers = []
    root.actionStatus = ""
    root.loadZone(false)
  }

  function cycleZone(step) {
    if (root.zones.length < 2) return
    var index = 0
    for (var i = 0; i < root.zones.length; i++)
      if (root.zones[i].id === root.zoneId) { index = i; break }
    var next = (index + step + root.zones.length) % root.zones.length
    root.selectZone(root.zones[next].id)
  }

  // --- writing -------------------------------------------------------------
  // Every write re-reads the zone rather than assuming it landed: Cloudflare
  // decides what `development_mode` and `security_level` actually end up as,
  // and this panel's job is to show that, not its own optimism.
  function runAction(action, args, successText) {
    if (root.zoneId === "" || root.busyAction !== "") return
    root.busyAction = action
    root.actionStatus = ""
    root.actionFailed = false
    bridge.call([action].concat(args), function(payload) {
      root.busyAction = ""
      if (!payload || payload.error) {
        root.actionFailed = true
        // Kept with the action that failed. `hint` belongs to the credential
        // and read errors above; borrowing it here parked a purge's advice
        // under an unrelated message and left it there.
        root.actionStatus = payload && payload.error ? payload.error : "request failed"
        if (payload && payload.hint) root.actionStatus += " — " + payload.hint
        return
      }
      root.actionFailed = false
      root.actionStatus = successText
      root.loadZone(true)
    }, true)
  }

  function toggleDevMode() {
    if (root.zone === null) return
    root.runAction("devmode", [root.zoneId, root.devMode ? "off" : "on"],
                   root.devMode ? "Development Mode off" : "Development Mode on — expires in 3 hours")
  }

  function toggleAttack() {
    if (root.zone === null) return
    root.runAction("attack", [root.zoneId, root.underAttack ? "off" : "on"],
                   root.underAttack ? "Security level restored" : "Under Attack Mode on")
  }

  function purgeEverything() {
    root.purgeConfirmOpen = false
    root.runAction("purge", [root.zoneId], "Cache purged")
  }

  function loadSetup() {
    bridge.call(["setup"], function(payload) {
      if (payload && !payload.error) root.setupInfo = payload
    }, true)
  }

  function openSetup() {
    root.showSetup = true
    root.setupStatus = ""
    root.setupFailed = false
    root.loadSetup()
  }

  function closeSetup() { root.showSetup = false }

  // wrangler login is a browser round trip with a prompt at the end of it, so
  // it belongs in a terminal the user can see, not in a Process this panel
  // would have to babysit. We launch it and then wait to be told to look again.
  function startWranglerLogin() {
    var command = root.setupInfo ? (root.setupInfo.wrangler_command || "") : ""
    if (command === "" || !root.bar) return
    root.setupFailed = false
    root.setupStatus = "Finishing in the terminal — reopen this when the browser is done."
    root.bar.run("omarchy-launch-floating-terminal-with-presentation '" + command + "'")
  }

  function saveToken(value) {
    var token = String(value || "").trim()
    if (token === "" || root.savingToken) return
    root.savingToken = true
    root.setupStatus = "Checking the token…"
    root.setupFailed = false
    tokenSaver.secret = token
    tokenSaver.running = true
  }

  function forgetToken() {
    bridge.call(["forget-token"], function(payload) {
      root.setupFailed = false
      root.setupStatus = payload && payload.warning ? payload.warning
                       : "Saved token removed"
      root.loadSetup()
      root.refresh(true)
    }, true)
  }

  function openTokenPage() {
    var url = root.setupInfo && root.setupInfo.token_url
              ? root.setupInfo.token_url
              : "https://dash.cloudflare.com/profile/api-tokens"
    root.openUrl(url)
  }

  function openDashboard() {
    if (!root.zone) return
    var url = "https://dash.cloudflare.com/" + (root.accountId || "")
            + "/" + (root.zone.name || "")
    root.openUrl(url)
  }

  function openTunnelsDashboard() {
    if (root.accountId === "") return
    root.openUrl("https://one.dash.cloudflare.com/" + root.accountId + "/networks/tunnels")
  }

  function openWorkersDashboard() {
    if (root.accountId === "") return
    root.openUrl("https://dash.cloudflare.com/" + root.accountId + "/workers/services")
  }

  function openUrl(url) {
    root.close()
    if (root.bar) root.bar.run("omarchy-launch-browser '" + url + "'")
  }

  // --- formatting ----------------------------------------------------------
  // Counts are compacted because the panel is 460px wide and "1,284,993"
  // crowds out the label that says what it counts.
  function compact(value) {
    var n = Number(value || 0)
    if (!isFinite(n)) return "0"
    if (n >= 1e9) return (n / 1e9).toFixed(n >= 1e10 ? 0 : 1) + "B"
    if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1) + "M"
    if (n >= 1e3) return (n / 1e3).toFixed(n >= 1e4 ? 0 : 1) + "K"
    return String(Math.round(n))
  }

  // Cloudflare reports bytes, and bills in the decimal units the dashboard
  // shows, so this divides by 1000 rather than 1024.
  function bytes(value) {
    var n = Number(value || 0)
    if (!isFinite(n) || n <= 0) return "0 B"
    var units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var i = 0
    while (n >= 1000 && i < units.length - 1) { n /= 1000; i++ }
    return (i === 0 ? String(Math.round(n)) : n.toFixed(n >= 100 ? 0 : 1)) + " " + units[i]
  }

  function percent(ratio) {
    var n = Number(ratio || 0)
    if (!isFinite(n)) return "0%"
    return Math.round(n * 100) + "%"
  }

  function shortDuration(seconds) {
    var n = Math.max(0, Math.round(Number(seconds || 0)))
    if (n >= 3600) return Math.floor(n / 3600) + "h " + Math.floor((n % 3600) / 60) + "m"
    if (n >= 60) return Math.floor(n / 60) + "m"
    return n + "s"
  }

  function ago(iso) {
    if (!iso) return ""
    var then = new Date(iso)
    if (isNaN(then.getTime())) return ""
    var seconds = Math.max(0, (Date.now() - then.getTime()) / 1000)
    if (seconds < 90) return "just now"
    if (seconds < 3600) return Math.round(seconds / 60) + "m ago"
    if (seconds < 86400) return Math.round(seconds / 3600) + "h ago"
    return Math.round(seconds / 86400) + "d ago"
  }

  // Wrangler's token lasts about an hour and only it can renew one, so the
  // footer prints the deadline rather than pretending the panel will keep
  // working. Local time, because that is the clock the reader is looking at.
  function localTime(iso) {
    if (!iso) return ""
    var when = new Date(iso)
    if (isNaN(when.getTime())) return ""
    return Qt.formatDateTime(when, "HH:mm")
  }

  readonly property string tokenLabel: {
    if (root.tokenSource === "") return ""
    var label = "token: " + root.tokenSource
    var expiry = root.localTime(root.tokenExpiresAt)
    if (expiry !== "") label += " until " + expiry
    return label
  }

  function tunnelColor(status) {
    if (status === "healthy") return "#4ca64c"
    if (status === "degraded") return root.brand
    if (status === "down") return Color.urgent
    return root.dim
  }

  // --- lifecycle -----------------------------------------------------------
  Component.onCompleted: root.refresh(false)

  onOpenedChanged: {
    if (root.opened) {
      // Cached on the script side, so opening the panel repeatedly costs
      // nothing until the cache ages out.
      root.refresh(false)
      root.loadSetup()
    } else {
      root.purgeConfirmOpen = false
      root.actionStatus = ""
      root.showSetup = false
      root.setupStatus = ""
    }
  }

  // The dot on the bar has to be true while the panel is closed, which is the
  // only reason this polls in the background at all.
  Timer {
    interval: root.refreshSeconds * 1000
    running: true
    repeat: true
    onTriggered: root.refresh(false)
  }

  // Moves the countdown, and re-reads the zone once — when the deadline passes
  // — so the panel stops claiming Development Mode is on after Cloudflare has
  // already turned it off.
  Timer {
    interval: 30000
    running: root.devDeadlineMs > 0
    repeat: true
    onTriggered: {
      root.clockMs = Date.now()
      if (root.devModeSeconds <= 0) root.loadZone(true)
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(true); return "ok" }
    function zone(): string { return root.zone ? root.zone.name : "" }
    function status(): string {
      if (root.error !== "") return root.error
      if (!root.zone) return "no zone"
      var bits = [root.zone.name]
      if (root.devMode) bits.push("dev mode " + root.shortDuration(root.devModeSeconds))
      if (root.underAttack) bits.push("under attack")
      if (root.troubledTunnels > 0)
        bits.push(root.troubledTunnels
                  + (root.troubledTunnels === 1 ? " tunnel needs attention"
                                                : " tunnels need attention"))
      return bits.join(" · ")
    }
  }

  Bridge { id: bridge }

  // The token goes over stdin, never argv: anything in a command line is
  // readable out of the process list for as long as the process lives.
  Process {
    id: tokenSaver
    property string secret: ""
    property string collected: ""
    command: [bridge.script, "save-token"]
    stdinEnabled: true

    onStarted: {
      write(tokenSaver.secret + "\n")
      tokenSaver.secret = ""
    }

    stdout: SplitParser {
      onRead: function(line) { tokenSaver.collected += String(line || "") }
    }

    onExited: function(code) {
      var payload = null
      try { payload = JSON.parse(tokenSaver.collected) } catch (e) { payload = null }
      tokenSaver.collected = ""
      root.savingToken = false

      if (!payload || payload.error) {
        root.setupFailed = true
        root.setupStatus = payload && payload.error ? payload.error : "could not save the token"
        if (payload && payload.hint) root.setupStatus += " — " + payload.hint
        return
      }
      root.setupFailed = false
      root.setupStatus = payload.warning ? payload.warning : "Token saved"
      // Straight to the thing they came for.
      root.showSetup = false
      root.refresh(true)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    iconComponent: Component {
      Item {
        CloudMark {
          anchors.centerIn: parent
          size: Style.bar.iconCanvas
          color: root.foreground
          opacity: root.error !== "" ? 0.45 : 1.0
        }

        // Small, and only when something is on that should not stay on.
        Rectangle {
          visible: root.attentionDot && root.attention
          width: Style.space(5)
          height: width
          radius: width / 2
          color: root.troubledTunnels > 0 ? Color.urgent : root.brand
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.rightMargin: -Style.space(1)
          anchors.topMargin: -Style.space(1)
        }
      }
    }

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.refresh(true)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.setupVisible ? tokenInput : keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelContentWidth)
    contentHeight: panel.fittedContentHeight(
                     root.setupVisible
                       ? Math.max(column.implicitHeight, setupContent.implicitHeight)
                       : column.implicitHeight,
                     Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the token field owns the keyboard, every keystroke belongs to it
      // — including the letters that are shortcuts everywhere else.
      blocked: tokenInput.activeFocus

      // Left/Right walk the zones; with the purge dialog up they walk its two
      // buttons instead, which is the only cursor this panel has.
      onMoveRequested: function(dx, dy) {
        if (root.purgeConfirmOpen) {
          if (dx !== 0) purgeConfirm.selectedIndex = dx > 0 ? 1 : 0
          return
        }
        if (dx !== 0) root.cycleZone(dx)
      }
      onActivateRequested: {
        if (root.purgeConfirmOpen) {
          if (purgeConfirm.selectedIndex === 1) root.purgeEverything()
          else root.purgeConfirmOpen = false
          return
        }
        root.openDashboard()
      }
      onCloseRequested: {
        if (root.purgeConfirmOpen) root.purgeConfirmOpen = false
        // Escape backs out of the setup screen, unless backing out would leave
        // nothing behind it.
        else if (root.showSetup && root.tokenPresent) root.closeSetup()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.purgeConfirmOpen) return
        var key = t.toLowerCase()
        // Handled before the guard that silences the other shortcuts, so this
        // still works while the screen is up — but only when the token field
        // has not taken the keyboard, which it does whenever the screen opens.
        // In practice this opens; Escape is what closes. The toggle is here for
        // the case where focus sits elsewhere, not as the advertised way out.
        if (key === "c") {
          root.showSetup ? root.closeSetup() : root.openSetup()
          return
        }
        if (root.setupVisible) return
        if (key === "r") root.refresh(true)
        else if (root.readOnly) return
        else if (key === "d") root.toggleDevMode()
        else if (key === "u") root.toggleAttack()
        else if (key === "p" && root.zoneId !== "") root.purgeConfirmOpen = true
      }

      Flickable {
        id: flick
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
          width: flick.width
          spacing: Style.space(10)

          // ---- which zone -----------------------------------------------
          Item {
            width: parent.width
            height: Math.max(mark.height, zonePicker.height, zoneLabel.implicitHeight,
                             dashboardButton.height, refreshButton.height)

            CloudMark {
              id: mark
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              size: Style.space(24)
              brandColors: true
            }

            Dropdown {
              id: zonePicker
              anchors.left: mark.right
              anchors.leftMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - mark.width - refreshButton.width
                     - (credentialButton.visible ? credentialButton.width + Style.spacing.sm : 0)
                     - (dashboardButton.visible ? dashboardButton.width + Style.spacing.sm : 0)
                     - Style.spacing.sm * 2
              visible: root.zones.length > 1
              showLabel: false
              value: root.zoneId
              foreground: root.foreground
              options: {
                var out = []
                for (var i = 0; i < root.zones.length; i++)
                  out.push({ value: root.zones[i].id, label: root.zones[i].name })
                return out
              }
              onChanged: function(v) { root.selectZone(v) }
            }

            Text {
              id: zoneLabel
              anchors.left: mark.right
              anchors.leftMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - mark.width - refreshButton.width
                     - (credentialButton.visible ? credentialButton.width + Style.spacing.sm : 0)
                     - (dashboardButton.visible ? dashboardButton.width + Style.spacing.sm : 0)
                     - Style.spacing.sm * 2
              visible: root.zones.length <= 1
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              color: root.foreground
              elide: Text.ElideRight
              textFormat: Text.PlainText
              // Three different nothings, and the difference matters: still
              // asking, never asked because there is no token, or asked and the
              // token cannot see a single zone.
              text: root.zone ? root.zone.name
                  : root.loading ? "loading…"
                  : !root.tokenPresent ? "not connected"
                  : "no zones on this token"
              opacity: root.zone ? 1.0 : 0.55
            }

            // The "add a token later" route, and the only way back to the
            // setup screen once a credential is working.
            PanelActionButton {
              id: credentialButton
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰌋"
              visible: root.tokenPresent
              tooltipText: root.readOnly
                           ? "Read-only session — add an API token (c)"
                           : "Credential (c)"
              foreground: root.readOnly ? root.brand : root.foreground
              onClicked: root.showSetup ? root.closeSetup() : root.openSetup()
            }

            PanelActionButton {
              id: refreshButton
              anchors.right: dashboardButton.visible ? dashboardButton.left : parent.right
              anchors.rightMargin: dashboardButton.visible ? Style.spacing.sm : 0
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑐"
              tooltipText: "Refresh (r)"
              foreground: root.foreground
              opacity: root.loading ? 0.5 : 1.0
              onClicked: root.refresh(true)
            }

            Button {
              id: dashboardButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Dashboard"
              tooltipText: root.zone ? "dash.cloudflare.com → " + root.zone.name : ""
              visible: root.zone !== null
              foreground: root.foreground
              onClicked: root.openDashboard()
            }
          }

          // ---- why there is nothing to show -------------------------------
          Column {
            width: parent.width
            spacing: Style.spacing.labelGap
            // Credential problems are handled by the setup screen, which is
            // already covering this. Everything else still reports here.
            visible: root.error !== "" && !root.setupVisible

            Text {
              width: parent.width
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: Color.urgent
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.error
            }

            // Cloudflare's permission errors name a scope, not a fix, so the
            // script attaches the scope this plugin actually needs.
            Text {
              width: parent.width
              visible: root.hint !== ""
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.foreground
              opacity: 0.55
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.hint
            }
          }

          // ---- 24 hours ---------------------------------------------------
          PanelSectionHeader {
            width: parent.width
            visible: root.zone !== null
            foreground: root.foreground
            fontFamily: root.fontFamily
            textFormat: Text.PlainText
            text: root.analyticsError !== "" ? "LAST 24 HOURS  ·  UNAVAILABLE"
                : root.analytics ? "LAST 24 HOURS"
                : "LAST 24 HOURS  ·  LOADING"
          }

          Row {
            width: parent.width
            visible: root.zone !== null && root.analytics !== null
            spacing: Style.spacing.sm

            Stat {
              width: (parent.width - Style.spacing.sm * 4) / 5
              value: root.analytics ? root.compact(root.analytics.requests) : "—"
              label: "requests"
            }

            Stat {
              width: (parent.width - Style.spacing.sm * 4) / 5
              value: root.analytics ? root.percent(root.analytics.cache_ratio) : "—"
              label: "cached"
              valueColor: root.brand
            }

            Stat {
              width: (parent.width - Style.spacing.sm * 4) / 5
              value: root.analytics ? root.bytes(root.analytics.bytes) : "—"
              label: "served"
            }

            // Uniques are not readable on every plan, and a hard 0 would read
            // as "nobody came" rather than "not measured here".
            Stat {
              width: (parent.width - Style.spacing.sm * 4) / 5
              value: root.analytics
                     ? (root.analytics.uniques_known ? root.compact(root.analytics.uniques) : "—")
                     : "—"
              label: "visitors"
            }

            Stat {
              width: (parent.width - Style.spacing.sm * 4) / 5
              value: root.analytics ? root.compact(root.analytics.threats) : "—"
              label: "threats"
              valueColor: root.analytics && Number(root.analytics.threats) > 0
                          ? Color.urgent : root.foreground
            }
          }

          Sparkline {
            width: parent.width
            visible: root.analytics !== null
                     && root.analytics.series !== undefined
                     && root.analytics.series.length > 0
            series: root.analytics ? (root.analytics.series || []) : []
            foreground: root.foreground
            accent: root.brand
          }

          Text {
            width: parent.width
            visible: root.analyticsError !== ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.55
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            // The traffic graph is the one part that needs its own scope, so
            // losing it should not look like the zone is idle.
            text: root.analyticsError
                  + " — the token needs Zone → Analytics → Read for the traffic graph."
          }

          PanelSeparator {
            width: parent.width
            visible: root.zone !== null
            foreground: root.foreground
          }

          // ---- the two switches, and the blunt instrument ------------------
          PanelSectionHeader {
            width: parent.width
            visible: root.zone !== null
            foreground: root.foreground
            fontFamily: root.fontFamily
            textFormat: Text.PlainText
            text: {
              if (!root.zone) return "ZONE"
              var bits = []
              if (root.zone.plan) bits.push(String(root.zone.plan).toUpperCase())
              if (root.zone.status && root.zone.status !== "active")
                bits.push(String(root.zone.status).toUpperCase())
              if (root.zone.paused) bits.push("PAUSED")
              if (root.readOnly) bits.push("READ-ONLY")
              return bits.length > 0 ? "ZONE  ·  " + bits.join("  ·  ") : "ZONE"
            }
          }

          Row {
            width: parent.width
            visible: root.zone !== null
            spacing: Style.spacing.sm

            Button {
              // Development Mode bypasses the cache entirely, so leaving it on
              // is the difference between a CDN and a very long cable. The
              // countdown is the point of showing it here.
              text: root.devMode ? "Dev mode  " + root.shortDuration(root.devModeSeconds)
                                 : "Dev mode"
              tooltipText: root.readOnly
                           ? "Needs an API token — wrangler can only be granted zone:read"
                           : root.devMode
                           ? "Cache bypassed — turns itself off in "
                             + root.shortDuration(root.devModeSeconds) + " (d)"
                           : "Bypass the cache for 3 hours (d)"
              active: root.devMode
              enabled: root.busyAction === "" && !root.readOnly
              foreground: root.devMode ? root.brand : root.foreground
              accent: root.brand
              bordered: true
              onClicked: root.toggleDevMode()
            }

            Button {
              text: root.underAttack ? "Under attack  on" : "Under attack"
              tooltipText: root.readOnly
                           ? "Needs an API token — wrangler can only be granted zone:read"
                           : root.securityReadable
                           ? (root.underAttack
                              ? "Interstitial on every visitor — restores the previous security level (u)"
                              : "Challenge every visitor (u)")
                           : "Needs Zone → Zone Settings → Read"
              active: root.underAttack
              enabled: root.busyAction === "" && root.securityReadable && !root.readOnly
              foreground: root.underAttack ? Color.urgent : root.foreground
              accent: Color.urgent
              bordered: true
              onClicked: root.toggleAttack()
            }

            Button {
              text: "Purge cache"
              tooltipText: root.readOnly
                           ? "Needs an API token — no cache-purge scope exists for wrangler to request"
                           : "Purge everything for this zone (p)"
              enabled: root.busyAction === "" && !root.readOnly
              foreground: root.foreground
              bordered: true
              onClicked: root.purgeConfirmOpen = true
            }
          }

          Text {
            width: parent.width
            visible: root.actionStatus !== "" || root.busyAction !== ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.actionFailed ? Color.urgent : root.foreground
            opacity: root.actionFailed ? 1.0 : 0.6
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.busyAction !== "" ? "working…" : root.actionStatus
          }

          // ---- tunnels ----------------------------------------------------
          PanelSeparator {
            width: parent.width
            visible: root.showTunnels && (root.tunnels.length > 0 || root.tunnelsError !== "")
            foreground: root.foreground
          }

          PanelSectionHeader {
            width: parent.width
            visible: root.showTunnels && (root.tunnels.length > 0 || root.tunnelsError !== "")
            foreground: root.foreground
            fontFamily: root.fontFamily
            textFormat: Text.PlainText
            text: root.troubledTunnels > 0
                  ? "TUNNELS  ·  " + root.troubledTunnels
                    + (root.troubledTunnels === 1 ? " NEEDS ATTENTION" : " NEED ATTENTION")
                  : "TUNNELS  ·  " + root.tunnels.length
          }

          Column {
            width: parent.width
            visible: root.showTunnels && root.tunnels.length > 0
            spacing: 0

            Repeater {
              model: root.tunnels

              delegate: Rectangle {
                required property var modelData
                width: parent.width
                height: Style.space(26)
                radius: Style.cornerRadius / 2
                color: tunnelHover.containsMouse ? Color.menu.selectedBackground : "transparent"

                MouseArea {
                  id: tunnelHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openTunnelsDashboard()
                }

                Rectangle {
                  id: statusDot
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.rowPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(6)
                  height: width
                  radius: width / 2
                  color: root.tunnelColor(String(parent.modelData.status || ""))
                }

                Text {
                  anchors.left: statusDot.right
                  anchors.leftMargin: Style.spacing.sm
                  anchors.right: tunnelMeta.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  color: root.foreground
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: parent.modelData.name || parent.modelData.id || ""
                }

                Text {
                  id: tunnelMeta
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                  opacity: 0.55
                  textFormat: Text.PlainText
                  // Connection count is what separates "healthy" from
                  // "healthy, on one leg".
                  text: {
                    var t = parent.modelData
                    var n = Number(t.connections || 0)
                    return String(t.status || "") + (n > 0 ? "  ·  " + n + " conn" : "")
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.showTunnels && root.tunnelsError !== ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.55
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.tunnelsError
          }

          // ---- workers ----------------------------------------------------
          PanelSeparator {
            width: parent.width
            visible: root.showWorkers && root.workers.length > 0
            foreground: root.foreground
          }

          PanelSectionHeader {
            width: parent.width
            visible: root.showWorkers && root.workers.length > 0
            foreground: root.foreground
            fontFamily: root.fontFamily
            textFormat: Text.PlainText
            text: "WORKERS  ·  " + root.workers.length
          }

          Column {
            width: parent.width
            visible: root.showWorkers && root.workers.length > 0
            spacing: 0

            Repeater {
              // Newest deploys first, capped: this is a "what did I ship
              // lately" list, not a directory.
              model: root.workers.slice(0, 5)

              delegate: Rectangle {
                required property var modelData
                width: parent.width
                height: Style.space(24)
                radius: Style.cornerRadius / 2
                color: workerHover.containsMouse ? Color.menu.selectedBackground : "transparent"

                MouseArea {
                  id: workerHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openWorkersDashboard()
                }

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.rowPaddingX
                  anchors.right: workerMeta.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  color: root.foreground
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: parent.modelData.name || ""
                }

                Text {
                  id: workerMeta
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                  opacity: 0.5
                  textFormat: Text.PlainText
                  text: root.ago(parent.modelData.modified_on)
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // ---- where this came from ---------------------------------------
          Text {
            width: parent.width
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.45
            elide: Text.ElideRight
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: {
              var bits = []
              if (root.accountName !== "") bits.push(root.accountName)
              if (root.tokenLabel !== "") bits.push(root.tokenLabel)
              if (root.tokenMessage !== "") bits.push(root.tokenMessage)
              if (root.updatedAt) bits.push("updated " + Qt.formatDateTime(root.updatedAt, "HH:mm"))
              return bits.join("  ·  ")
            }
          }
        }
      }

      // ---- connecting --------------------------------------------------
      // Covers the panel rather than sitting inside it: when there is no
      // credential there is nothing behind it worth seeing, and when there is
      // one, this is a modal errand you came here to finish.
      Rectangle {
        id: setupView
        anchors.fill: parent
        z: 15
        visible: root.setupVisible
        color: Color.popups.background

        // The panel only primes focus when it opens, so a setup screen summoned
        // mid-session has to claim the keyboard itself — and hand it back, or
        // closing the screen would leave every key going to a hidden field.
        onVisibleChanged: {
          if (setupView.visible) {
            tokenInput.text = ""
            tokenInput.forceActiveFocus()
          } else {
            tokenInput.text = ""
            keyCatcher.forceActiveFocus()
          }
        }

        readonly property var info: root.setupInfo
        readonly property string session: setupView.info
          ? String(setupView.info.wrangler_session || "none") : "none"
        readonly property bool wranglerReady: setupView.info
          ? setupView.info.wrangler_available === true : false
        readonly property bool hasSavedToken: setupView.info
          ? setupView.info.token_file_present === true : false
        readonly property string envVar: setupView.info
          ? String(setupView.info.env_var || "") : ""

        // Nothing behind this should react to a click aimed at it.
        MouseArea { anchors.fill: parent; hoverEnabled: true }

        Column {
          id: setupContent
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(10)

          Item {
            width: parent.width
            height: Math.max(setupMark.height, setupTitle.implicitHeight, setupClose.height)

            CloudMark {
              id: setupMark
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              size: Style.space(24)
              brandColors: true
            }

            Text {
              id: setupTitle
              anchors.left: setupMark.right
              anchors.leftMargin: Style.spacing.sm
              anchors.right: setupClose.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              color: root.foreground
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.tokenPresent ? "Credential" : "Connect to Cloudflare"
            }

            // Only offered when there is something to go back to.
            PanelActionButton {
              id: setupClose
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.tokenPresent
              iconText: "󰅖"
              tooltipText: "Back"
              foreground: root.foreground
              onClicked: root.closeSetup()
            }
          }

          // ---- the no-setup route ----------------------------------------
          PanelSectionHeader {
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            textFormat: Text.PlainText
            text: "SIGN IN WITH WRANGLER"
          }

          Text {
            width: parent.width
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.55
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            // The honest pitch: free, instant, and limited in two ways that
            // will matter later.
            text: setupView.wranglerReady
                  ? "Reads traffic, tunnels and Workers. It cannot switch anything — wrangler can only be granted zone:read — and its session lasts about an hour."
                  : "Needs wrangler, or npx to run it. Neither is on PATH."
          }

          Item {
            width: parent.width
            height: Math.max(wranglerButton.height, wranglerState.implicitHeight)

            Button {
              id: wranglerButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: setupView.session === "active" ? "Sign in again" : "Sign in with wrangler"
              tooltipText: setupView.info ? String(setupView.info.wrangler_command || "") : ""
              enabled: setupView.wranglerReady
              foreground: root.foreground
              bordered: true
              onClicked: root.startWranglerLogin()
            }

            Text {
              id: wranglerState
              anchors.left: wranglerButton.right
              anchors.leftMargin: Style.spacing.md
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: setupView.session === "expired" ? root.brand : root.foreground
              opacity: setupView.session === "expired" ? 1.0 : 0.5
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: setupView.session === "active"
                    ? ("signed in until "
                       + root.localTime(setupView.info ? setupView.info.wrangler_expires_at : ""))
                  : setupView.session === "expired" ? "session expired"
                  : ""
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // ---- the full-power route --------------------------------------
          PanelSectionHeader {
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            textFormat: Text.PlainText
            text: root.tokenPresent && !root.readOnly ? "API TOKEN  ·  IN USE" : "OR PASTE AN API TOKEN"
          }

          Text {
            width: parent.width
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.55
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Zone → Zone → Read plus Zone → Analytics → Read shows everything above. Add Zone Settings → Edit and Cache Purge → Purge for the switches. Checked before it is saved."
          }

          Item {
            width: parent.width
            height: Math.max(tokenInput.height, saveTokenButton.height)

            TextField {
              id: tokenInput
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - saveTokenButton.width - Style.spacing.sm
              password: true
              placeholderText: "Paste a token"
              foreground: root.foreground
              enabled: !root.savingToken
              onAccepted: root.saveToken(tokenInput.text)

              // The key catcher is blocked while this field has focus, so the
              // way out has to live here too.
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  if (root.tokenPresent) root.closeSetup()
                  else root.close()
                  event.accepted = true
                }
              }
            }

            Button {
              id: saveTokenButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.savingToken ? "Checking…" : "Save"
              enabled: !root.savingToken && tokenInput.text.trim() !== ""
              foreground: root.foreground
              bordered: true
              onClicked: root.saveToken(tokenInput.text)
            }
          }

          Item {
            width: parent.width
            height: Math.max(tokenPageButton.height, forgetTokenButton.height)

            Button {
              id: tokenPageButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Create a token"
              tooltipText: "dash.cloudflare.com/profile/api-tokens"
              foreground: root.foreground
              onClicked: root.openTokenPage()
            }

            Button {
              id: forgetTokenButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: setupView.hasSavedToken
              text: "Forget saved token"
              tooltipText: setupView.info ? String(setupView.info.token_file || "") : ""
              foreground: root.foreground
              onClicked: root.forgetToken()
            }
          }

          Text {
            width: parent.width
            visible: root.setupStatus !== ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.setupFailed ? Color.urgent : root.foreground
            opacity: root.setupFailed ? 1.0 : 0.6
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.setupStatus
          }

          // An exported variable beats the file silently, which is a horrible
          // thing to debug by guesswork.
          Text {
            width: parent.width
            visible: setupView.envVar !== ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.brand
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: setupView.envVar + " is set in the environment and takes precedence over anything saved here."
          }
        }
      }

      // Purging everything is not undoable and every miss goes to the origin,
      // so it asks — and the keyboard path asks too.
      ConfirmDialog {
        id: purgeConfirm
        anchors.fill: parent
        z: 20
        opened: root.purgeConfirmOpen
        message: root.zone
                 ? "Purge the entire cache for " + root.zone.name + "?"
                 : "Purge the entire cache?"
        confirmText: "Purge"
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.purgeConfirmOpen = false
        onConfirmed: root.purgeEverything()
      }
    }
  }
}
