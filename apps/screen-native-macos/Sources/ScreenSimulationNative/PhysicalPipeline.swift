import Foundation
import ScreenPhysicalBridge
import StudioColor

final class PhysicalPipeline: @unchecked Sendable {
    private let reference: ScreenPhysicalPipelineRef

    init() {
        guard let reference = screen_physical_pipeline_create() else {
            fatalError("No se ha podido crear PhysicalPipeline(identity)")
        }
        self.reference = reference
    }

    deinit { screen_physical_pipeline_release(reference) }

    func process(_ frame: StudioColorLinearFrame) throws -> StudioColorLinearFrame {
        var result = frame
        var message: UnsafePointer<CChar>?
        let succeeded = result.premultipliedRGBA.withUnsafeMutableBufferPointer { buffer in
            screen_physical_pipeline_process_rgba32f(
                reference,
                buffer.baseAddress,
                result.width * result.height,
                &message
            )
        }
        guard succeeded else {
            throw NSError(
                domain: "ScreenPhysicalPipeline",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message.map(String.init(cString:)) ?? "PhysicalPipeline(identity) ha fallado."]
            )
        }
        return result
    }
}

