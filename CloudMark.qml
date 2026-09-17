import QtQuick
import QtQuick.Shapes
import qs.Commons

// A cloud silhouette, drawn here rather than shipped as Cloudflare's logo
// file: the trademarked mark is not ours to vendor into a plugin, and the bar
// wants a themed monochrome glyph anyway.
//
// One filled path, not a pile of circles. Overlapping opaque shapes look like
// a single silhouette only until you zoom in: each shape's antialiased edge
// composites over the one beneath it and leaves a seam through the middle,
// which at 16px in the bar is most of the icon. A single ShapePath has no
// interior edges to seam.
//
// The outline is two lobes over a flat base, expressed in a 32-unit box:
//
//   left lobe   centre (12,17) r8      right lobe  centre (22,19) r6
//   base        y = 23                 lobes meet at (17.43,13.66)
//
// Those meeting points are the real circle intersections, so the arcs join
// tangentially and the join does not show.
Item {
  id: root

  property real size: 18
  property color color: Color.foreground
  property bool brandColors: false

  readonly property color fill: brandColors ? "#f6821f" : root.color

  implicitWidth: size
  implicitHeight: size

  // A cloud is wider than it is tall, so the drawing is scaled to fill the
  // width of its slot rather than the square it sits in — at bar size the
  // difference is between a cloud and a smudge.
  readonly property real u: root.size / 26
  readonly property real offsetX: (root.size - 24 * u) / 2 - 4 * u
  readonly property real offsetY: (root.size - 14 * u) / 2 - 9 * u

  Shape {
    anchors.fill: parent
    antialiasing: true
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.fill
      strokeWidth: 0
      strokeColor: "transparent"
      capStyle: ShapePath.RoundCap

      startX: root.offsetX + 6.71 * root.u
      startY: root.offsetY + 23 * root.u

      // Up the left side, over the top of the big lobe, to where the two
      // lobes cross. More than half the circle, hence the large arc.
      PathArc {
        x: root.offsetX + 17.43 * root.u
        y: root.offsetY + 13.66 * root.u
        radiusX: 8 * root.u
        radiusY: 8 * root.u
        direction: PathArc.Clockwise
        useLargeArc: true
      }

      // Over the small lobe and down its right side.
      PathArc {
        x: root.offsetX + 26.47 * root.u
        y: root.offsetY + 23 * root.u
        radiusX: 6 * root.u
        radiusY: 6 * root.u
        direction: PathArc.Clockwise
        useLargeArc: false
      }

      // The flat base, which is what makes it a cloud sitting on a line
      // rather than a pair of balloons.
      PathLine {
        x: root.offsetX + 6.71 * root.u
        y: root.offsetY + 23 * root.u
      }
    }
  }
}
