import Foundation

public final class StudioColorPipeline: @unchecked Sendable {
    public static let workingSpace = "ACEScg"

    private let engine: StudioColorEngine

    public init(engine: StudioColorEngine = try! .bundled()) {
        self.engine = engine
    }

    /// Converts one complete decoded, encoded straight/premultiplied RGBA frame
    /// into premultiplied scene-linear ACEScg without selecting any policy.
    public func prepareInput(
        width: Int,
        height: Int,
        encodedRGBA: [Float],
        input: StudioColorInputTransform,
        alpha: StudioColorAlphaAssociation
    ) throws -> StudioColorLinearFrame {
        guard width > 0, height > 0, encodedRGBA.count == width * height * 4 else {
            throw StudioColorError.invalidPixelBuffer
        }
        var values = encodedRGBA
        for offset in stride(from: 0, to: values.count, by: 4) {
            switch alpha {
            case .ignore:
                values[offset + 3] = 1
            case .straight:
                break
            case .premultiplied:
                let a = values[offset + 3]
                if a > 0 {
                    values[offset] /= a
                    values[offset + 1] /= a
                    values[offset + 2] /= a
                } else {
                    values[offset] = 0
                    values[offset + 1] = 0
                    values[offset + 2] = 0
                }
            }
        }
        let processor = try inputProcessor(input)
        try processor.apply(toRGBA: &values)
        for offset in stride(from: 0, to: values.count, by: 4) {
            let a = values[offset + 3]
            values[offset] *= a
            values[offset + 1] *= a
            values[offset + 2] *= a
        }
        return try StudioColorLinearFrame(
            width: width,
            height: height,
            premultipliedRGBA: values
        )
    }

    private func inputProcessor(
        _ input: StudioColorInputTransform
    ) throws -> StudioColorProcessor {
        switch input.processor {
        case let .colorSpace(source):
            try engine.cachedColorSpaceProcessor(
                source: source, destination: Self.workingSpace
            )
        case let .inverseDisplay(display, view):
            try engine.cachedInverseDisplayProcessor(
                destination: Self.workingSpace, display: display, view: view
            )
        }
    }

    public func cpuOracleRGBA8(
        _ frame: StudioColorLinearFrame,
        output: StudioColorOutputTransform
    ) throws -> [UInt8] {
        var values = frame.premultipliedRGBA
        for offset in stride(from: 0, to: values.count, by: 4) {
            let a = values[offset + 3]
            if a > 0 {
                values[offset] /= a
                values[offset + 1] /= a
                values[offset + 2] /= a
            }
        }
        let processor = try engine.cachedDisplayProcessor(
            source: Self.workingSpace,
            display: output.display,
            view: output.view
        )
        try processor.apply(toRGBA: &values)
        return values.enumerated().map { index, value in
            if index.isMultiple(of: 4) || index % 4 == 1 || index % 4 == 2 {
                let a = values[index - index % 4 + 3]
                return UInt8((value * a).clamped(to: 0 ... 1) * 255 + 0.5)
            }
            return UInt8(value.clamped(to: 0 ... 1) * 255 + 0.5)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}

public enum StudioColorBuildIdentity {
    public static let abiVersion: UInt32 = 1
    public static let ocioVersion = "2.5.2"
    public static let acesConfigVersion = "4.0.0 / ACES 2.0"
    public static let sourceRepository = "CREDITOS-HDR"
    public static let sourceCommit = "150ef31ffa69fec562a017d2165006f7b2913520"
    public static let nativeBridgeSHA256 = "680eef3911af83b3579d7b7dbe27c9970d273859edd3b5fbdc0a2cc8968ee67f"
    public static let configurationSHA256 = "ebe2293968975e3540c6b32cfbee2ca1274b5bf3c9ff610235abb07b65da970b"
}
