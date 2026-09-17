import QtQuick
import qs.Commons

// 24 hourly buckets, one bar each, in the order the Analytics API ranked
// them — oldest on the left. Each bar is the hour's total requests; the filled
// portion at its foot is the share Cloudflare served from cache, which is the
// one comparison the numbers above cannot make hour by hour.
//
// Bars are scaled against the busiest hour in the window, not against an
// absolute ceiling: a zone doing forty requests an hour deserves a shape too.
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
        readonly property real ratio: root.peak > 0 ? total / root.peak : 0

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
