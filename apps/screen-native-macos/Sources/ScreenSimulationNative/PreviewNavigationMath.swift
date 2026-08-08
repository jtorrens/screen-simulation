import Foundation

enum PreviewNavigationMath {
    static func fittedScale(texture: CGSize, viewport: CGSize) -> CGFloat {
        guard texture.width > 0, texture.height > 0,
              viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / texture.width, viewport.height / texture.height)
    }

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
            height: previous.height * scaleRatio + offsetY * (1 - scaleRatio)
        )
    }

    static func clampedPan(
        _ proposed: CGSize,
        viewport: CGSize,
        fittedContent: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let maximumX = max(0, (fittedContent.width * scale - viewport.width) / 2)
        let maximumY = max(0, (fittedContent.height * scale - viewport.height) / 2)
        return CGSize(
            width: min(maximumX, max(-maximumX, proposed.width)),
            height: min(maximumY, max(-maximumY, proposed.height))
        )
    }
}
