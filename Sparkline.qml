import QtQuick
import qs.Commons

// 24 hourly buckets, one bar each, in the order the Analytics API ranked
// them — oldest on the left. Each bar is the hour's total requests; the filled
// portion at its foot is the share Cloudflare served from cache, which is the
// one comparison the numbers above cannot make hour by hour.
//
// Bar heights are logarithmic, scaled against the busiest hour in the window
// rather than an absolute ceiling.
//
// Real traffic forced this. A zone idling at 16 requests an hour took a
// 3,016-request crawl at 07:00 — a 190x range. Linear scaling put every other
// hour of the day on the 1px floor, including one at 18x the baseline, and a
// square root only got the quiet hours to 7% of the height, which still draws
// as a dash. What the reader needs from 24 bars in a popup is the shape: was
// there a spike, was there a gap, is the rhythm normal. Linear answers only
// the first question, and only when the answer is yes.
//
// log1p keeps zero at zero and preserves the ordering, so the spike is still
// the tallest bar. It does flatten magnitude — 16 against 3,016 reads as a
// third rather than a two-hundredth — which is why the exact figures sit
// directly above this and are not derived from it. Numbers are for reading;
// this is for glancing.
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
                                      ? Math.log1p(total) / Math.log1p(root.peak) : 0

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
