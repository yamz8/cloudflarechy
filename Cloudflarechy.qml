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
  // Percent of requests answering 5xx before the bar says so. The agents
  // widget draws the same line at 90% of a token limit: one threshold, one
  // colour, no gradient nobody can read at 16px.
  readonly property real errorThreshold: Math.max(0, Number(root.setting("errorPercent", 5))) / 100

  // --- what came back ------------------------------------------------------
  property var zones: []
  property string zoneId: ""
  // Which traffic window the zone section shows. Held here rather than in
  // settings: it is a question you ask once while looking, not a preference.
  property string range: "24h"
  readonly property var ranges: root.overview && root.overview.ranges
                                ? root.overview.ranges : ["24h", "7d", "30d"]
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
  property string workersMetricsError: ""

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
  // One Worker, opened from its row. Replaces the panel rather than expanding
  // under the row: the credential screen already established that shape here,
  // and a list that grows a nested panel in the middle of itself reads badly
  // at this width.
  property string workerDetailName: ""
  property var workerDetail: null
  property bool workerDetailLoading: false
  readonly property bool workerDetailVisible: root.workerDetailName !== ""
  // Tunnels and Workers belong to the account, not to the zone in the picker,
  // and putting them under it said otherwise. They get their own screen; the
  // zone panel keeps one line about them, because a tunnel going down is one
  // of the things that lights the bar icon and a panel that cannot say why is
  // not worth opening.
  property bool accountViewOpen: false
  readonly property bool accountViewVisible: root.accountViewOpen
                                             && root.accountSectionVisible

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

  // Tunnels and Workers are account-scoped — Cloudflare files them under
  // Networking and Compute, not under a domain — so they sit below a scope
  // break rather than under the zone picker, which governs only the zone
  // sections above it. Switching zones leaves these lists alone, and saying
  // so is cheaper than letting the layout imply otherwise.
  readonly property bool tunnelsSectionVisible: root.showTunnels
    && (root.tunnels.length > 0 || root.tunnelsError !== "")
  readonly property bool workersSectionVisible: root.showWorkers && root.workers.length > 0
  readonly property bool accountSectionVisible: root.tunnelsSectionVisible
    || root.workersSectionVisible

  // How many rows a list section will show before it starts summarising. The
  // panel is capped at the same height as every other first-party popup, and
  // three sections that each grow without limit do not fit in it — an account
  // with twenty Workers used to render twenty rows, most of them below the
  // fold and reachable only by wheel.
  //
  // What gets cut matters more than how much. Each list is ranked so the rows
  // worth opening the panel for are the ones that survive: a tunnel that is
  // down, a Worker that is throwing. The count in the heading stays the true
  // total either way.
  readonly property int listCap: 3

  function tunnelRank(t) {
    var status = String((t && t.status) || "")
    if (status === "down") return 2
    if (status === "degraded") return 1
    return 0
  }

  // A Worker throwing ten exceptions in two and a half thousand invocations is
  // not the same as one that fails every time, and painting both the same red
  // spends the loudest thing on the panel on a rounding error. The line is the
  // one the bar icon already uses for a zone's 5xx rate, so the panel alarms
  // about Workers and zones at the same place. Invocations that all failed are
  // alarming whatever the count.
  function workerAlarming(w) {
    if (!w) return false
    var errs = Number(w.errors || 0)
    if (errs <= 0) return false
    var reqs = Number(w.requests || 0)
    return reqs <= 0 ? true : (errs / reqs) >= root.errorThreshold
  }

  function workerRank(w) {
    if (!w) return -1
    if (Number(w.errors || 0) > 0) return 2
    if (Number(w.requests || 0) > 0) return 1
    return 0
  }

  function routeRank(r) {
    return r && String(r.script || "") !== "" ? 1 : 0
  }

  // Decorated with the original position so equal ranks keep the order the API
  // gave them, which is already sorted by name or pattern. Array.sort is not
  // required to be stable and QV4 does not promise it, so the tie-break is
  // carried explicitly rather than hoped for.
  function rankedBy(items, rank) {
    var all = items || []
    var marked = []
    for (var i = 0; i < all.length; i++)
      marked.push({ item: all[i], at: i, rank: rank(all[i]) })
    marked.sort(function(a, b) {
      return b.rank !== a.rank ? b.rank - a.rank : a.at - b.at
    })
    var out = []
    for (var j = 0; j < marked.length; j++) out.push(marked[j].item)
    return out
  }

  // One hidden row is not worth hiding: "+1 more" costs the same line the row
  // itself would have.
  function capList(items) {
    var all = items || []
    return all.length <= root.listCap + 1 ? all : all.slice(0, root.listCap)
  }

  function hiddenCount(items) {
    var all = items || []
    return all.length <= root.listCap + 1 ? 0 : all.length - root.listCap
  }

  // The account screen has room for all of them; the summary line on the zone
  // panel is what the cap used to be for.
  readonly property var rankedTunnels: root.rankedBy(root.tunnels, root.tunnelRank)
  readonly property var rankedWorkers: root.rankedBy(root.workers, root.workerRank)

  readonly property var shownTunnels: root.capList(root.rankedBy(root.tunnels, root.tunnelRank))
  readonly property int hiddenTunnels: root.hiddenCount(root.tunnels)
  readonly property var shownWorkers: root.capList(root.rankedBy(root.workers, root.workerRank))
  readonly property int hiddenWorkers: root.hiddenCount(root.workers)
  readonly property var shownRoutes: root.capList(root.rankedBy(root.routes, root.routeRank))
  readonly property int hiddenRoutes: root.hiddenCount(root.routes)

  // The one Workers view that genuinely belongs under a zone picker: which
  // scripts run on this domain. The account-wide script list lives below the
  // scope break with the tunnels.
  readonly property var routes: root.overview && root.overview.routes
                                ? root.overview.routes : []
  // Routes sit behind their own scope, so "this zone has no routes" and "this
  // token may not look" arrive as the same empty list. Told apart, because
  // they call for opposite responses: one is nothing to do, the other is a
  // scope to add. Tunnels and Workers already say so when they are refused;
  // this section used to drop the refusal and simply not appear.
  readonly property string routesError: root.overview && root.overview.routes_error
                                        ? String(root.overview.routes_error) : ""
  readonly property bool routesSectionVisible: root.showWorkers
                                               && (root.routes.length > 0
                                                   || root.routesError !== "")

  // A zone can be failing without anything being switched on, and that is
  // worth opening the panel for too. Guarded by an absolute floor as well as a
  // rate: three 5xx out of four requests at 4am is a true 75% and not news.
  readonly property bool errorRateAlarming: {
    // Zero is off, not "light on anything". A zone that is known to be failing
    // and not being fixed today would otherwise hold the icon lit forever, and
    // a permanently coloured icon is just a differently coloured icon — the
    // signal stops being a signal. The switch and tunnel triggers stay.
    if (root.errorThreshold <= 0) return false
    if (!root.analytics || root.analytics.statuses_known !== true) return false
    var errors = Number(root.analytics.server_errors || 0)
    if (errors < 20) return false
    return Number(root.analytics.error_ratio || 0) >= root.errorThreshold
  }

  // What the bar icon's colour means: something is switched on that was meant
  // to be temporary, a tunnel is not carrying traffic, or the zone is serving
  // errors at a rate worth looking at.
  readonly property bool attention: root.devMode || root.underAttack
                                    || root.troubledTunnels > 0
                                    || root.errorRateAlarming

  // The bar's own alert colour, which themes set and the first-party widgets
  // use — network turns its glyph this colour when pings drop. A plugin that
  // invented its own orange would be the only thing in the row not following
  // the theme.
  readonly property color barAttention: bar ? bar.urgent : Color.urgent

  // The whole mark carries the signal, not just a dot on the corner of it.
  // This widget's entire argument is that the bar tells you a temporary switch
  // is still on; five pixels in the corner is not telling you.
  // `attentionDot` governs the whole signal, not just the dot. Someone who
  // turns it off wants a quiet bar, and a red cloud with no dot on it would be
  // the setting doing half of what it says.
  readonly property color barIconColor: root.attention && root.attentionDot
                                        ? root.barAttention : root.foreground

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color brand: "#f6821f"
  // The width every first-party popup uses — bluetooth, network, audio,
  // monitor, power, tailscale, agents, dropbox. The clock is wider because a
  // month grid needs it; nothing here does, and a bar full of popups that
  // each pick their own width looks like an accident.
  readonly property int panelContentWidth: Style.space(380)

  // The tail of a capped list. Says how many rows it is standing in for and
  // opens the place where all of them live, so the cap never becomes a dead
  // end.
  component MoreRow: Rectangle {
    id: more
    property int count: 0
    property string destination: ""
    signal activated

    width: parent ? parent.width : 0
    height: more.count > 0 ? Style.space(22) : 0
    visible: more.count > 0
    radius: Style.cornerRadius / 2
    color: moreHover.containsMouse ? Color.menu.selectedBackground : "transparent"

    MouseArea {
      id: moreHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: more.activated()
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      color: root.foreground
      opacity: moreHover.containsMouse ? 0.8 : 0.45
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: more.count + " more" + (more.destination !== "" ? "  \u00b7  " + more.destination : "")
    }
  }

  // One number, what it counts, and how it compares. Three of these share a
  // row, so the value carries the weight and the rest stays out of its way.
  component Stat: Column {
    id: stat
    property string value: ""
    property string label: ""
    property string delta: ""
    property color valueColor: root.foreground
    spacing: 0

    // Both bound to the slot and elided. A Column does not clip its children,
    // so a value wider than its share used to draw straight over the stat
    // beside it — invisible until some zone reported a number long enough to
    // do it.
    Text {
      width: stat.width
      elide: Text.ElideRight
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      color: stat.valueColor
      textFormat: Text.PlainText
      text: stat.value
    }

    Text {
      width: stat.width
      elide: Text.ElideRight
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      color: root.foreground
      opacity: 0.5
      textFormat: Text.PlainText
      text: stat.label
    }

    // Its own line rather than beside the value: at a third of 380px there is
    // no room for both, and stacking keeps the three deltas aligned with each
    // other. Deliberately uncoloured — more requests can be growth or an
    // attack, and the panel should not claim to know which. Colour stays with
    // the states that are unambiguous.
    Text {
      width: stat.width
      visible: stat.delta !== ""
      elide: Text.ElideRight
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      color: root.foreground
      opacity: 0.45
      textFormat: Text.PlainText
      text: stat.delta
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

  function setRange(next) {
    if (next === root.range || root.ranges.indexOf(next) < 0) return
    root.range = next
    // The old window is dropped rather than left on screen: its label would
    // now read as the new range's, which is the one mistake this selector
    // could make.
    root.overview = null
    root.loadZone(false)
  }

  function cycleRange(step) {
    var at = root.ranges.indexOf(root.range)
    if (at < 0) at = 0
    var n = root.ranges.length
    root.setRange(root.ranges[((at + step) % n + n) % n])
  }

  function rangeLabel(id) {
    return String(id || "").toUpperCase()
  }

  function loadZone(fresh) {
    if (root.zoneId === "") return

    bridge.call(["overview", root.zoneId, root.range], function(payload) {
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
        root.workersMetricsError = payload.metrics_error || ""
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

  function openWorkerDetail(name) {
    if (!name || root.accountId === "") return
    root.workerDetailName = name
    root.workerDetail = null
    root.workerDetailLoading = true
    bridge.call(["worker", root.accountId, name], function(payload) {
      root.workerDetailLoading = false
      // A late answer for a Worker the user has already navigated away from
      // must not paint over the one they are looking at now.
      if (root.workerDetailName !== name) return
      root.workerDetail = payload || null
    }, false)
  }

  function openAccountView() {
    if (!root.accountSectionVisible) return
    root.closeWorkerDetail()
    root.accountViewOpen = true
  }

  function closeAccountView() { root.accountViewOpen = false }

  function closeWorkerDetail() {
    root.workerDetailName = ""
    root.workerDetail = null
    root.workerDetailLoading = false
  }

  function openWorker(name) {
    if (root.accountId === "" || !name) { root.openWorkersDashboard(); return }
    root.openUrl("https://dash.cloudflare.com/" + root.accountId
                 + "/workers/services/view/" + name + "/production/metrics")
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

  // Never rounds up to a clean 100%: a Worker at 99.62% success is not a
  // Worker with no failures, and this screen exists to show the difference.
  function percentExact(ratio) {
    var n = Number(ratio || 0)
    if (!isFinite(n)) return "0%"
    if (n >= 1) return "100%"
    var shown = Math.floor(n * 1000) / 10
    if (shown >= 100) shown = 99.9
    return (shown >= 99 ? shown.toFixed(1) : String(Math.round(shown))) + "%"
  }

  function percent(ratio) {
    var n = Number(ratio || 0)
    if (!isFinite(n)) return "0%"
    return Math.round(n * 100) + "%"
  }

  // Hourly buckets arrive as an instant and daily ones as a calendar day, and
  // the two need different handling: `new Date("2026-09-12")` is parsed as UTC
  // midnight, which in a western timezone renders as the 11th. A day is a day
  // wherever you are reading it, so it is built locally from its parts.
  function bucketLabel(stamp) {
    var t = String(stamp || "")
    if (t === "") return ""
    if (t.indexOf("T") >= 0) return Qt.formatDateTime(new Date(t), "HH:00")
    var bits = t.split("-")
    if (bits.length !== 3) return t
    return Qt.formatDate(new Date(Number(bits[0]), Number(bits[1]) - 1, Number(bits[2])),
                         "d MMM")
  }

  // Period-over-period change, as a share of the earlier value. That is what
  // Cloudflare's own cards report — their cache-hit-rate card reads 0.97% with
  // a 56.3% fall, which is impossible as a difference in points and exact as a
  // relative one.
  //
  // A null arrives when there was no earlier period to compare against, and
  // null is not zero: "unchanged" and "nothing to compare" are different
  // answers, so one draws nothing at all.
  function deltaText(value) {
    if (value === null || value === undefined || value === "") return ""
    var n = Number(value)
    if (!isFinite(n)) return ""
    var pct = n * 100
    var size = Math.abs(pct)
    // Under a twentieth of a percent an arrow would claim a direction the
    // measurement does not support.
    if (size < 0.05) return "flat"
    // One decimal throughout, so three deltas sitting in a row are read at a
    // glance instead of compared digit by digit. Past a tenfold change the
    // decimal is noise and the number is the headline anyway.
    var shown = size >= 1000 ? String(Math.round(size)) : size.toFixed(1)
    return (pct > 0 ? "\u2197 " : "\u2198 ") + shown + "%"
  }

  // Worker CPU arrives in microseconds. A p50 of 8644 is 8.6ms, and printing
  // it raw would be six digits of noise in a column that has room for five
  // characters.
  function cpuTime(microseconds) {
    var n = Number(microseconds || 0)
    if (!isFinite(n) || n <= 0) return ""
    if (n >= 1e6) return (n / 1e6).toFixed(1) + "s"
    if (n >= 1000) return (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "ms"
    return Math.round(n) + "µs"
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

  // Which credential is answering, in as few words as say it. The footer is
  // one line of provenance under a panel of numbers, and the full path of the
  // token file wrapped it onto two — the credential screen already prints the
  // path in full, and that is where you go when you want to change it. What
  // matters here is only which of the four sources is in use.
  readonly property string tokenLabel: {
    if (root.tokenSource === "") return ""
    var source = root.tokenSource
    if (source === "wrangler") source = "wrangler"
    else if (source.indexOf("/") >= 0) source = "saved token"
    else source = "$" + source
    var expiry = root.localTime(root.tokenExpiresAt)
    return expiry !== "" ? source + " until " + expiry : source
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
      root.closeWorkerDetail()
      root.closeAccountView()
      // The bar dot reads its error rate from whichever window is loaded, and
      // the background poll keeps loading whatever was left selected. Leaving
      // the panel on 30 days would quietly redefine what lights the icon: a
      // bad afternoon averaged over a month stops looking like anything. So
      // the range is a question asked while looking, and closing ends it.
      root.range = "24h"
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
    function worker(name: string): string {
      if (!name) { root.closeWorkerDetail(); return "closed" }
      root.open()
      root.openWorkerDetail(name)
      return name
    }
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
          color: root.barIconColor
          opacity: root.error !== "" ? 0.45 : 1.0

          // Colour alone cannot be the whole signal: a theme is free to set
          // bar.urgent close to its foreground, and some people cannot tell
          // the two apart at all. The dot below is the shape cue that does not
          // depend on either.
          Behavior on color {
            enabled: root.bar ? root.bar.foregroundAnimationEnabled : false
            ColorAnimation { duration: 220 }
          }
        }

        // The dot is the shape cue, so it has to read as a separate shape.
        // Drawn in the alert colour on a mark already in the alert colour it
        // merged into the cloud's own silhouette and became a bump on the
        // corner — the redundant encoding for anyone who cannot see the colour
        // change, doing nothing for exactly the people it is there for. The
        // gap in the bar's own background is what separates them.
        Rectangle {
          visible: root.attentionDot && root.attention
          width: Style.space(7)
          height: width
          radius: width / 2
          color: root.bar && !root.bar.transparent ? root.bar.background : "transparent"
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.rightMargin: -Style.space(2)
          anchors.topMargin: -Style.space(2)

          Rectangle {
            anchors.centerIn: parent
            width: Style.space(5)
            height: width
            radius: width / 2
            color: root.barAttention
          }
        }
      }
    }

    tooltipText: {
      if (!root.attention) return ""
      var reasons = []
      if (root.devMode) reasons.push("Development Mode on, " + root.shortDuration(root.devModeSeconds) + " left")
      if (root.underAttack) reasons.push("Under Attack Mode on")
      if (root.troubledTunnels > 0)
        reasons.push(root.troubledTunnels
                     + (root.troubledTunnels === 1 ? " tunnel needs attention" : " tunnels need attention"))
      if (root.errorRateAlarming)
        reasons.push(root.percent(root.analytics.error_ratio) + " of requests are 5xx")
      return reasons.join("  ·  ")
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
    // No fixed cap. The agents panel caps at 640 because its content is a
    // known size; this one carries three lists that grow with the account, and
    // the first-party panel of that shape — network — lets the screen be the
    // limit instead. A cap here just moved rows below a fold with nothing to
    // say they were there. The per-list cap above is what keeps it sane.
    contentHeight: panel.fittedContentHeight(
                     root.setupVisible ? setupContent.implicitHeight
                     : root.workerDetailVisible ? workerContent.implicitHeight
                     : root.accountViewVisible ? accountContent.implicitHeight
                     : column.implicitHeight)

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
        else if (root.workerDetailVisible) root.closeWorkerDetail()
        else if (root.accountViewVisible) root.closeAccountView()
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
        if (root.setupVisible || root.workerDetailVisible) return
        // The account screen is a place, not a mode: `a` opens it and Escape
        // leaves, the same way a Worker does.
        if (key === "a") {
          root.accountViewVisible ? root.closeAccountView() : root.openAccountView()
          return
        }
        if (root.accountViewVisible) return
        if (key === "r") root.refresh(true)
        // Widening the window reads nothing it could not already read, so it
        // stays available on a read-only credential.
        else if (key === "t") root.cycleRange(1)
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

          // ---- traffic ----------------------------------------------------
          // The range moved out of the heading and into a control, so the
          // heading says what the section is and the control says how wide a
          // window it is showing — which is how the zone page reads.
          Item {
            width: parent.width
            visible: root.zone !== null
            height: Math.max(trafficHeading.implicitHeight, rangePicker.implicitHeight)

            PanelSectionHeader {
              id: trafficHeading
              anchors.left: parent.left
              anchors.right: rangePicker.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.foreground
              fontFamily: root.fontFamily
              textFormat: Text.PlainText
              // The arrows are meaningless without their baseline, so the
              // heading names it rather than leaving it to a tooltip the bar
              // has no room for.
              text: {
                if (root.analyticsError !== "") return "TRAFFIC  ·  UNAVAILABLE"
                if (!root.analytics) return "TRAFFIC  ·  LOADING"
                return root.analytics.comparison ? "TRAFFIC  ·  VS PREVIOUS" : "TRAFFIC"
              }
            }

            Row {
              id: rangePicker
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              Repeater {
                model: root.ranges

                delegate: Text {
                  required property var modelData
                  readonly property bool current: modelData === root.range
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                  // The unselected ranges stay legible rather than becoming
                  // decoration: they are the control, not a caption.
                  opacity: current ? 1.0 : (rangeHover.containsMouse ? 0.8 : 0.45)
                  textFormat: Text.PlainText
                  text: root.rangeLabel(modelData)

                  MouseArea {
                    id: rangeHover
                    anchors.fill: parent
                    anchors.margins: -Style.spacing.xxs
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setRange(parent.modelData)
                  }
                }
              }
            }
          }

          // Three slots, not five. At this width five stats leave 76px each,
          // which is not enough to carry a number and a period-over-period
          // delta beside it — and these three are the ones Cloudflare's own
          // zone page leads with.
          Row {
            width: parent.width
            visible: root.zone !== null && root.analytics !== null
            spacing: Style.spacing.sm

            Stat {
              width: (parent.width - Style.spacing.sm * 2) / 3
              value: root.analytics ? root.compact(root.analytics.requests) : "—"
              label: "requests"
              delta: root.analytics ? root.deltaText(root.analytics.requests_delta) : ""
            }

            Stat {
              width: (parent.width - Style.spacing.sm * 2) / 3
              value: root.analytics ? root.percent(root.analytics.cache_ratio) : "—"
              label: "cached"
              delta: root.analytics ? root.deltaText(root.analytics.cache_ratio_delta) : ""
              valueColor: root.brand
            }

            Stat {
              width: (parent.width - Style.spacing.sm * 2) / 3
              value: root.analytics ? root.bytes(root.analytics.bytes) : "—"
              label: "served"
              delta: root.analytics ? root.deltaText(root.analytics.bytes_delta) : ""
            }
          }

          Sparkline {
            id: zoneGraph
            width: parent.width
            visible: root.analytics !== null
                     && root.analytics.series !== undefined
                     && root.analytics.series.length > 0
            series: root.analytics ? (root.analytics.series || []) : []
            foreground: root.foreground
            accent: root.brand
          }

          // 5xx and threats are zero on most zones most of the time, and a
          // headline slot is the wrong weight for an answer that is usually
          // "nothing happened". They keep their own line, and earn colour only
          // when the count is non-zero. 4xx stays out of it: a 403 or a 404 is
          // often the zone working exactly as told.
          //
          // A zone serving nothing but 5xx reports the same request count as a
          // healthy one, so dropping these entirely would render a failing zone
          // as a quiet one.
          Row {
            width: parent.width
            // Yields the line to the pointer. Hovering a bar is a question
            // about that bar, and the answer belongs where you are already
            // looking rather than in a label floating over the bars it
            // describes. Nothing moves, because the two share the row.
            visible: root.zone !== null && root.analytics !== null
                     && zoneGraph.hoveredBucket === null
            spacing: Style.spacing.sm

            readonly property bool statusesKnown: root.analytics
              ? root.analytics.statuses_known === true : false
            readonly property int serverErrors: root.analytics
              ? Number(root.analytics.server_errors || 0) : 0
            readonly property int threatCount: root.analytics
              ? Number(root.analytics.threats || 0) : 0

            Text {
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
              color: parent.serverErrors > 0 ? Color.urgent : root.foreground
              opacity: parent.serverErrors > 0 ? 1.0 : 0.55
              text: parent.statusesKnown
                    ? root.compact(parent.serverErrors) + " 5xx"
                    : "5xx unavailable"
            }

            Text {
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.3
              text: "·"
            }

            Text {
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
              color: parent.threatCount > 0 ? Color.urgent : root.foreground
              opacity: parent.threatCount > 0 ? 1.0 : 0.55
              text: root.compact(parent.threatCount) + " threats"
            }
          }

          Text {
            width: parent.width
            visible: zoneGraph.hoveredBucket !== null
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.7
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: {
              var b = zoneGraph.hoveredBucket
              if (!b) return ""
              var requests = Number(b.requests || 0)
              var cached = Number(b.cached || 0)
              var bits = [root.bucketLabel(b.t), root.compact(requests) + " req"]
              // A bucket that served nothing has no cache share to report, and
              // "0% cached" would read as a cache that failed rather than one
              // that was never asked.
              if (requests > 0) bits.push(root.percent(cached / requests) + " cached")
              if (Number(b.threats || 0) > 0)
                bits.push(root.compact(b.threats) + " threats")
              return bits.join("  \u00b7  ")
            }
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
              // The plan only earns its place when it is not the one almost
              // everybody is on. "ZONE · FREE WEBSITE" told a reader on the
              // free plan nothing they did not know, while sitting where the
              // exceptional states — paused, read-only — need to be noticed.
              var plan = String(root.zone.plan || "")
              if (plan !== "" && !/^free\b/i.test(plan)) bits.push(plan.toUpperCase())
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

          // ---- routes -----------------------------------------------------
          PanelSeparator {
            width: parent.width
            visible: root.routesSectionVisible
            foreground: root.foreground
          }

          PanelSectionHeader {
            width: parent.width
            visible: root.routesSectionVisible
            foreground: root.foreground
            fontFamily: root.fontFamily
            textFormat: Text.PlainText
            text: root.routesError !== "" ? "ROUTES"
                                          : "ROUTES  ·  " + root.routes.length
          }

          Column {
            width: parent.width
            visible: root.routesSectionVisible
            spacing: 0

            Repeater {
              model: root.shownRoutes

              delegate: Rectangle {
                required property var modelData
                readonly property string script: String(modelData.script || "")
                // A route can exist with nothing behind it. Saying so is more
                // use than a row that looks clickable and answers nothing.
                readonly property bool runnable: script !== "" && root.accountId !== ""

                width: parent.width
                height: Style.space(26)
                radius: Style.cornerRadius / 2
                color: routeHover.containsMouse && runnable
                       ? Color.menu.selectedBackground : "transparent"

                MouseArea {
                  id: routeHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: parent.runnable ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: if (parent.runnable) root.openWorkerDetail(parent.script)
                }

                // The script name takes the room it needs before the pattern
                // gets any. It is the identifier on this row — the thing you
                // click and the thing the Worker sections call it — and when
                // the two shared the width evenly both ended up elided, so a
                // row read `edge-personalisati…  …y-long-path-segment/deeper-1/*`
                // and named nothing at all.
                Text {
                  id: routeScript
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.rowPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(implicitWidth, parent.width * 0.62)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  color: root.foreground
                  opacity: parent.runnable ? 1.0 : 0.55
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: parent.runnable ? parent.script : "no Worker"
                }

                // Elided in the middle rather than from the left. A pattern
                // has two informative ends — the host says which site, the
                // tail says which route — and cutting from the left threw the
                // host away to save a path segment nobody reads.
                Text {
                  id: routePattern
                  anchors.left: routeScript.right
                  anchors.leftMargin: Style.spacing.sm
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                  opacity: 0.55
                  elide: Text.ElideMiddle
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: String(parent.modelData.pattern || "")
                }
              }
            }

            MoreRow {
              count: root.hiddenRoutes
              destination: "Dashboard"
              onActivated: root.openDashboard()
            }
          }

          // Said in the same voice the tunnels and Workers sections use when
          // they are refused, and naming the scope that would fix it — the
          // refusal Cloudflare returns is about resources, not about scopes.
          Text {
            width: parent.width
            visible: root.routesSectionVisible && root.routesError !== ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.55
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.routesError + " — add Zone → Workers Routes → Read"
          }

          // ---- what the account is doing ----------------------------------
          // One line, and a way in. The lists themselves moved to their own
          // screen because they do not belong to the zone in the picker, but
          // a tunnel that is down is one of the four things that turns the bar
          // icon its alert colour — so the panel you open to ask "why?" still
          // answers without a second keystroke.
          PanelSeparator {
            width: parent.width
            visible: root.accountSectionVisible
            foreground: root.foreground
          }

          Rectangle {
            width: parent.width
            visible: root.accountSectionVisible
            height: Style.space(28)
            radius: Style.cornerRadius / 2
            color: accountHover.containsMouse ? Color.menu.selectedBackground : "transparent"

            MouseArea {
              id: accountHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openAccountView()
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.right: accountState.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: root.foreground
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.accountName !== "" ? root.accountName : "Account"
            }

            // The trouble first and in the colour it deserves, the counts
            // beside it in the colour a count deserves. One Text for the pair
            // would have painted "3 Workers" red because a tunnel was down.
            Row {
              id: accountState
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.troubledTunnels > 0 ? Color.urgent : root.foreground
                opacity: root.troubledTunnels > 0 ? 1.0 : 0.5
                textFormat: Text.PlainText
                text: root.troubledTunnels > 0
                      ? root.troubledTunnels
                        + (root.troubledTunnels === 1 ? " tunnel down" : " tunnels down")
                      : root.tunnelsSectionVisible
                        ? root.tunnels.length
                          + (root.tunnels.length === 1 ? " tunnel" : " tunnels")
                        : ""
              }

              Text {
                visible: root.workersSectionVisible && root.tunnelsSectionVisible
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: 0.5
                textFormat: Text.PlainText
                text: "  ·  "
              }

              Text {
                visible: root.workersSectionVisible
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: 0.5
                textFormat: Text.PlainText
                text: root.workers.length
                      + (root.workers.length === 1 ? " Worker" : " Workers")
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
              // Only when nothing above has said it. With the account sections
              // on screen the kicker above already names the account, and the
              // footer was repeating it two sections later.
              if (root.accountName !== "" && !root.accountSectionVisible)
                bits.push(root.accountName)
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
              // The command this runs is printed below the button instead of
              // hung off it as a tooltip. The tooltip drew upward, straight
              // through the paragraph above, and its left edge landed outside
              // the panel — and a button that shells out has no business
              // hiding what it will run behind a hover anyway.
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

          // Said plainly, in the terminal's own voice: this is the line that
          // will run, and a browser will open on it.
          Text {
            width: parent.width
            visible: setupView.wranglerReady && text !== ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.4
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: setupView.info ? String(setupView.info.wrangler_command || "") : ""
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

      // ---- the account --------------------------------------------------
      // Tunnels and Workers, at the scope they actually have. The zone picker
      // is not on this screen because nothing here answers to it: switching
      // zones changes none of these rows, which is exactly what made them
      // confusing sitting underneath it.
      Rectangle {
        id: accountView
        anchors.fill: parent
        z: 13
        visible: root.accountViewVisible
        color: Color.popups.background

        MouseArea { anchors.fill: parent; hoverEnabled: true }

        Flickable {
          id: accountFlick
          anchors.fill: parent
          contentWidth: width
          contentHeight: accountContent.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: accountContent
            width: accountFlick.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              height: Math.max(accountBack.height, accountTitle.implicitHeight,
                               accountOpen.height)

              PanelActionButton {
                id: accountBack
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰁍"
                tooltipText: "Back (Esc)"
                foreground: root.foreground
                onClicked: root.closeAccountView()
              }

              Text {
                id: accountTitle
                anchors.left: accountBack.right
                anchors.leftMargin: Style.spacing.sm
                anchors.right: accountOpen.left
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                color: root.foreground
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.accountName !== "" ? root.accountName : "Account"
              }

              Button {
                id: accountOpen
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Dashboard"
                tooltipText: "This account on the dashboard"
                foreground: root.foreground
                onClicked: root.openWorkersDashboard()
              }
            }

          // ---- tunnels ----------------------------------------------------
          PanelSectionHeader {
            width: parent.width
            visible: root.tunnelsSectionVisible
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
            visible: root.tunnelsSectionVisible && root.tunnels.length > 0
            spacing: 0

            Repeater {
              model: root.rankedTunnels

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
            visible: root.workersSectionVisible && root.tunnelsSectionVisible
            foreground: root.foreground
          }

          PanelSectionHeader {
            width: parent.width
            visible: root.workersSectionVisible
            foreground: root.foreground
            fontFamily: root.fontFamily
            textFormat: Text.PlainText
            text: "WORKERS  ·  " + root.workers.length
          }

          Column {
            width: parent.width
            visible: root.workersSectionVisible
            spacing: 0

            Repeater {
              // Newest deploys first, capped: this is a "what did I ship
              // lately" list, not a directory.
              model: root.rankedWorkers

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
                  onClicked: root.openWorkerDetail(parent.modelData.name)
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

                // Split rather than one string, because only one of these
                // figures is ever the bad news. A single coloured line made a
                // Worker's request count and its CPU time look like symptoms.
                Row {
                  id: workerMeta
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 0

                  readonly property var w: parent.modelData
                  // A Worker with no invocations in the window has no metrics
                  // row at all, which is not the same as one that ran zero
                  // times and reported it — so that case falls back to saying
                  // when it was last deployed.
                  readonly property bool idle: !w || w.requests === undefined
                                               || w.requests === null
                  readonly property real errs: Number(w && w.errors || 0)
                  readonly property string cpu: root.cpuTime(w && w.cpu_p50_us)

                  Text {
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    opacity: 0.5
                    textFormat: Text.PlainText
                    text: workerMeta.idle
                          ? root.ago(workerMeta.w && workerMeta.w.modified_on)
                          : root.compact(workerMeta.w.requests) + " req"
                  }

                  Text {
                    visible: !workerMeta.idle && workerMeta.errs > 0
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    opacity: 0.5
                    textFormat: Text.PlainText
                    text: "  ·  "
                  }

                  Text {
                    visible: !workerMeta.idle && workerMeta.errs > 0
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    // Urgent above the threshold, the brand amber below it: a
                    // handful of failures is worth seeing and not worth
                    // shouting, and amber is already what the panel uses for a
                    // number that wants a second look.
                    color: root.workerAlarming(workerMeta.w) ? Color.urgent : root.brand
                    opacity: 1.0
                    textFormat: Text.PlainText
                    text: root.compact(workerMeta.errs) + " err"
                  }

                  Text {
                    visible: !workerMeta.idle && workerMeta.cpu !== ""
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    opacity: 0.5
                    textFormat: Text.PlainText
                    text: "  ·  " + workerMeta.cpu
                  }
                }
              }
            }

          }

          Text {
            width: parent.width
            visible: root.showWorkers && root.workersMetricsError !== ""
                     && root.workers.length > 0
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.5
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Showing deploy dates — Workers traffic needs Account → Account Analytics → Read."
          }
          }
        }
      }

      // ---- one Worker ---------------------------------------------------
      Rectangle {
        id: workerView
        anchors.fill: parent
        z: 14
        visible: root.workerDetailVisible
        color: Color.popups.background

        readonly property var detail: root.workerDetail
        readonly property var summary: workerView.detail ? workerView.detail.worker : null
        readonly property string failure: workerView.detail
          ? String(workerView.detail.error || "") : ""
        // A Worker nobody called in this window is not a Worker that failed,
        // and every figure on this screen is about to be zero. Which zero it
        // is decides how the screen should read.
        readonly property bool idle: workerView.summary !== null
          && Number(workerView.summary.requests || 0) === 0

        MouseArea { anchors.fill: parent; hoverEnabled: true }

        Column {
          id: workerContent
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(10)

          Item {
            width: parent.width
            height: Math.max(workerBack.height, workerTitle.implicitHeight, workerOpen.height)

            PanelActionButton {
              id: workerBack
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰁍"
              tooltipText: "Back (Esc)"
              foreground: root.foreground
              onClicked: root.closeWorkerDetail()
            }

            Text {
              id: workerTitle
              anchors.left: workerBack.right
              anchors.leftMargin: Style.spacing.sm
              anchors.right: workerOpen.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              color: root.foreground
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.workerDetailName
            }

            Button {
              id: workerOpen
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Dashboard"
              tooltipText: "This Worker's metrics tab"
              foreground: root.foreground
              onClicked: root.openWorker(root.workerDetailName)
            }
          }

          PanelSectionHeader {
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            textFormat: Text.PlainText
            // Always the last 24 hours, whatever window the zone is showing.
            // Invocation analytics are not retained far enough back to offer
            // the week and the month the traffic graph offers, so rather than
            // a selector with two options that would often be empty, the
            // window is fixed — and said out loud when it differs from the
            // one you arrived from, because otherwise drilling into a Worker
            // silently changes the question being asked.
            text: root.workerDetailLoading ? "LAST 24 HOURS  ·  LOADING"
                : workerView.failure !== "" ? "LAST 24 HOURS  ·  UNAVAILABLE"
                : root.range !== "24h" ? "LAST 24 HOURS  ·  ZONE SHOWS "
                                         + root.rangeLabel(root.range)
                : "LAST 24 HOURS"
          }

          // Three, not five. The zone view was cut to three for legibility and
          // this one kept cramming five across the same width, which left
          // `p50 cpu` and `p99 cpu` set in a size that had to be leaned into.
          // The two that lost their pedestal are the two nobody opens the
          // panel to read; they are still here, on the line below.
          Row {
            width: parent.width
            visible: workerView.summary !== null
            spacing: Style.spacing.sm

            Stat {
              width: (parent.width - Style.spacing.sm * 2) / 3
              value: workerView.summary ? root.compact(workerView.summary.requests) : "—"
              label: "requests"
            }

            Stat {
              width: (parent.width - Style.spacing.sm * 2) / 3
              // 0% against no invocations would read as total failure. There
              // is no success rate for a Worker nothing asked for.
              value: workerView.summary && !workerView.idle
                     ? root.percentExact(workerView.summary.success_ratio) : "—"
              label: "success"
              // The same line the Workers list draws, so a script that is red
              // in the list is red when you open it and amber stays amber.
              valueColor: workerView.summary && !workerView.idle
                          && Number(workerView.summary.success_ratio) < 1 - root.errorThreshold
                          ? Color.urgent : root.foreground
            }

            Stat {
              width: (parent.width - Style.spacing.sm * 2) / 3
              value: workerView.summary ? root.cpuTime(workerView.summary.cpu_p50_us) : "—"
              label: "p50 cpu"
            }
          }

          Text {
            width: parent.width
            visible: workerView.summary !== null
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.5
            textFormat: Text.PlainText
            text: {
              if (!workerView.summary) return ""
              var bits = []
              var p99 = root.cpuTime(workerView.summary.cpu_p99_us)
              if (p99 !== "") bits.push("p99 " + p99)
              bits.push(root.compact(workerView.summary.subrequests) + " subrequests")
              return bits.join("  ·  ")
            }
          }

          // Same bars as the zone graph, filled by errors rather than cache
          // hits — in both cases the fill is the part of the hour worth
          // noticing.
          Sparkline {
            id: workerGraph
            width: parent.width
            // A Worker at 99.5% success has almost no fill, so the bars carry
            // this chart on their own and need the weight to do it.
            trackOpacity: 0.34
            visible: workerView.detail !== null
                     && (workerView.detail.series || []).length > 0
            series: workerView.detail ? (workerView.detail.series || []) : []
            fillKey: "errors"
            foreground: root.foreground
            accent: Color.urgent
          }

          // No line to share with here, so this one is inserted on hover
          // rather than reserved: an empty band under the graph is a worse
          // trade than the separator below it moving by a line. It cannot
          // flicker, because it appears underneath the graph and so never
          // moves the bars out from under the pointer.
          Text {
            width: parent.width
            visible: workerGraph.hoveredBucket !== null
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: workerGraph.hoveredBucket
                   && Number(workerGraph.hoveredBucket.errors || 0) > 0
                   ? Color.urgent : root.foreground
            opacity: 0.85
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: {
              var b = workerGraph.hoveredBucket
              if (!b) return ""
              var bits = [root.bucketLabel(b.t),
                          root.compact(Number(b.requests || 0)) + " req"]
              var errors = Number(b.errors || 0)
              if (errors > 0) bits.push(root.compact(errors) + " err")
              return bits.join("  \u00b7  ")
            }
          }

          PanelSeparator {
            width: parent.width
            visible: workerView.detail !== null
            foreground: root.foreground
          }

          PanelSectionHeader {
            width: parent.width
            visible: workerView.detail !== null
                     && (workerView.detail.statuses || []).length > 0
            foreground: root.foreground
            fontFamily: root.fontFamily
            textFormat: Text.PlainText
            text: "INVOCATION STATUS"
          }

          Column {
            width: parent.width
            visible: workerView.detail !== null
            spacing: 0

            Repeater {
              model: workerView.detail ? (workerView.detail.statuses || []) : []

              delegate: Item {
                required property var modelData
                width: parent.width
                height: Style.space(26)

                readonly property bool bad: String(modelData.status || "") !== "success"
                                            && Number(modelData.requests || 0) > 0

                Rectangle {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(6)
                  height: width
                  radius: width / 2
                  color: parent.bad ? root.brand : "#4ca64c"
                  opacity: Number(parent.modelData.errors || 0) > 0 ? 1.0 : 0.7
                  id: statusDotMark
                }

                Text {
                  anchors.left: statusDotMark.right
                  anchors.leftMargin: Style.spacing.sm
                  anchors.right: statusMeta.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  color: Number(parent.modelData.errors || 0) > 0
                         ? Color.urgent : root.foreground
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  // Cloudflare spells these in camelCase; a space reads better
                  // in a column than responseStreamDisconnected does.
                  text: String(parent.modelData.status || "")
                        .replace(/([A-Z])/g, " $1").toLowerCase().trim()
                }

                Text {
                  id: statusMeta
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                  opacity: 0.55
                  textFormat: Text.PlainText
                  text: {
                    var row = parent.modelData
                    var bits = [root.compact(row.requests) + " req"]
                    if (Number(row.errors) > 0) bits.push(root.compact(row.errors) + " err")
                    var cpu = root.cpuTime(row.cpu_p50_us)
                    if (cpu !== "") bits.push(cpu)
                    return bits.join("  ·  ")
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: workerView.failure !== ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: Color.urgent
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: workerView.failure
          }

          Text {
            width: parent.width
            visible: workerView.detail !== null && workerView.failure === ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.45
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            // The one number on this screen that is not a total, said plainly
            // rather than left to be assumed. With nothing to take quantiles
            // of, the screen owes an explanation instead of a caveat.
            text: workerView.idle
                  ? "No invocations in this window. The Worker is deployed; nothing called it."
                  : "CPU figures are quantiles of the busiest status, not averages."
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
