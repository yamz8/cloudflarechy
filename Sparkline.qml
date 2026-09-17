import QtQuick
import qs.Commons

// 24 hourly buckets, one bar each, in the order the Analytics API ranked
// them — oldest on the left. Each bar is the hour's total requests; the filled
// portion at its foot is the share Cloudflare served from cache, which is the
// one comparison the numbers above cannot make hour by hour.
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
  property color foreground: Color.foreground
  property color accent: "#f6821f"
  property real barSpacing: Style.spacing.xxs

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
        required property var modelData
        // An hour with no traffic still occupies its slot, so the window stays
        // 24 hours wide and a gap reads as a gap.
        width: (root.width - root.barSpacing * Math.max(0, root.series.length - 1))
               / Math.max(1, root.series.length)
        height: root.height

        readonly property real total: Number(modelData.requests || 0)
        readonly property real cached: Number(modelData.cached || 0)
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
          radius: Math.min(width, height) / 3
          color: parent.ratio > 0 ? Qt.rgba(root.foreground.r, root.foreground.g,
                                            root.foreground.b, 0.22)
                                  : Qt.rgba(root.foreground.r, root.foreground.g,
                                            root.foreground.b, 0.10)

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
}
