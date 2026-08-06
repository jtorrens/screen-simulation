import Foundation

enum PreviewNavigationMath {
    static func anchoredPan(
        previous: CGSize,
        anchor: CGPoint,
        viewportCenter: CGPoint,
        scaleRatio: CGFloat
    ) -> CGSize {
        let offsetX = anchor.x - viewportCenter.x
        let offsetY = anchor.y - viewportCenter.y
        return CGSize(
            width: previous.width * scaleRatio + offsetX * (1 - scaleRatio),
            height: previous.height * scaleRatio + offsetY * (scaleRatio - 1)
        )
    }

    static func clampedPan(
        _ proposed: CGSize,
        viewport: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let maximumX = max(0, (viewport.width * scale - viewport.width) / 2)
        let maximumY = max(0, (viewport.height * scale - viewport.height) / 2)
        return CGSize(
            width: min(maximumX, max(-maximumX, proposed.width)),
            height: min(maximumY, max(-maximumY, proposed.height))
        )
    }
}
