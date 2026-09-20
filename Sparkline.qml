import QtQuick
import qs.Commons

// One bar per bucket, in the order the Analytics API ranked them — oldest on
// the left. How many there are depends on the range the panel asked for: 24
// hourly buckets, or 7 or 30 daily ones. Each bar is that bucket's total
// requests; the filled portion at its foot is the share Cloudflare served from
// cache, which is the one comparison the numbers above cannot make per bucket.
//
// Bar heights are square-rooted, scaled against the busiest hour in the window
// rather than an absolute ceiling.
//
// The scale was chosen against two real shapes, because each one breaks a
// different curve:
//
//   spiky   a zone idling at 16 requests an hour took a 3,016-request crawl,
//           a 190x range. Linear puts all 23 other hours on the 1px floor —
//           including one at 18x the baseline — leaving one bar over a flat
//           line.
//   ordinary a normal day varying maybe 3x between its quiet and busy hours.
//           log1p renders that as a wall of near-identical full-height bars,
//           because it compresses 3x to 0.84. Nothing to see, every day.
//
// Square root is the one that survives both: the ordinary day keeps visible
// variation (3x becomes 0.57), and the spiky day still reads as quiet baseline,
// one medium event, one crawl. It gives up telling 15 requests from 18 at the
// bottom of the range, which is not a distinction anyone opens a bar widget to
// make. Zero stays zero and the ordering never changes.
//
// Exact magnitudes are printed above in figures and are not derived from these
// bars. Numbers are for reading; this is for glancing.
Item {
  id: root

  property var series: []
  // Which field of each bucket the filled portion represents. Zone traffic
  // fills by cache hits; a Worker fills by errors. Same shape, same reading:
  // "how much of this hour was the thing worth noticing".
  property string fillKey: "cached"
  property color foreground: Color.foreground
  property color accent: "#f6821f"
  property real barSpacing: Style.spacing.xxs
  // How present the unfilled part of a bar is. On the zone graph the fill
  // covers most of it and a ghost of a track is right; on a Worker's graph the
  // fill is the error share, which on a healthy script is nothing at all, so
  // the track *is* the chart and a ghost reads as a disabled control.
  property real trackOpacity: 0.22

  // Which bucket the pointer is over, or -1. The chart deliberately does not
  // draw the figure itself: at this width a floating label would cover the
  // bars it is describing, so the panel reads this and prints it on the line
  // below, where there is already room.
  //
  // Derived, never assigned. One MouseArea per bar, setting this on `entered`
  // and clearing it on `exited`, left the readout frozen: the panel went on
  // printing a bucket with the pointer a hundred pixels outside the card, and
  // only closing the panel cleared it. `exited` is not reliably delivered to a
  // layer-shell surface, so anything that depends on it eventually goes stale.
  // A binding cannot: the instant `containsMouse` is false this is -1 again,
  // whatever the compositor did or did not send.
  readonly property int hoveredIndex: pointer.containsMouse
                                      ? pointer.bucketAt(pointer.mouseX) : -1
  readonly property var hoveredBucket: root.hoveredIndex >= 0
                                       && root.hoveredIndex < root.series.length
                                       ? root.series[root.hoveredIndex] : null

  readonly property real peak: {
    var max = 0
    for (var i = 0; i < root.series.length; i++) {
      var n = Number(root.series[i].requests || 0)
      if (n > max) max = n
    }
    return max
  }

  implicitHeight: Style.space(38)

  Row {
    anchors.fill: parent
    spacing: root.barSpacing

    Repeater {
      model: root.series

      delegate: Item {
        id: bucket
        required property var modelData
        required property int index
        // A bucket with no traffic still occupies its slot, so the window
        // keeps its full width and a gap reads as a gap.
        width: (root.width - root.barSpacing * Math.max(0, root.series.length - 1))
               / Math.max(1, root.series.length)
        height: root.height

        readonly property real total: Number(modelData.requests || 0)
        readonly property real cached: Number(modelData[root.fillKey] || 0)
        readonly property real ratio: root.peak > 0
                                      ? Math.sqrt(total) / Math.sqrt(root.peak) : 0

        Rectangle {
          id: column
          anchors.bottom: parent.bottom
          width: parent.width
          // A non-zero hour never collapses to nothing: one pixel of bar is
          // the difference between "quiet" and "down".
          height: parent.ratio > 0
                  ? Math.max(Style.space(2), parent.ratio * parent.height)
                  : Style.space(1)
          // Capped, not just proportional. Derived from the smaller dimension
          // alone, a 7-day window's bars are wide enough that the corners eat
          // the bar and it reads as a row of lozenges instead of a chart. The
          // cap is the radius a 24-bucket bar already had, so the hourly view
          // is unchanged and the others match it.
          radius: Math.min(width, height, Style.space(15)) / 3
          // The hovered bar lifts out of the row. Without it the line below
          // names an hour the eye cannot find again among twenty-three
          // identical neighbours.
          readonly property real shade: root.hoveredIndex === bucket.index
                                        ? root.trackOpacity + 0.2
                                        : parent.ratio > 0 ? root.trackOpacity : 0.10
          color: Qt.rgba(root.foreground.r, root.foreground.g,
                         root.foreground.b, shade)

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            // Linear on purpose, unlike the bar height: this is the share of
            // the hour that came from cache, and a proportion drawn inside its
            // own bar should read as that proportion.
            height: parent.parent.total > 0
                    ? parent.height * (parent.parent.cached / parent.parent.total)
                    : 0
            radius: parent.radius
            color: root.accent
            opacity: 0.85
          }
        }
      }
    }
  }

  // One area over the whole row rather than one per bar: the index is worked
  // out from the pointer's own x, so there is no per-bar state to be left
  // behind. It covers the full height, not just the drawn bars — a quiet hour
  // is one pixel tall and would be unpointable otherwise, and a quiet hour is
  // often the one worth asking about.
  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    // The chart answers questions; it does not take clicks. Letting them
    // through keeps whatever sits beneath it reachable.
    acceptedButtons: Qt.NoButton

    // Bars are laid out by a Row, so each occupies (width + spacing) / n —
    // the trailing bar has no spacing after it, which is why the spacing is
    // added to the width before dividing rather than subtracted from it.
    function bucketAt(x: real): int {
      var n = root.series.length
      if (n <= 0 || root.width <= 0) return -1
      var slot = (root.width + root.barSpacing) / n
      var i = Math.floor(x / slot)
      return i < 0 ? -1 : (i >= n ? n - 1 : i)
    }
  }
}
