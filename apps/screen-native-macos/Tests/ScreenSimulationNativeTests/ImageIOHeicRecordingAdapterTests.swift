import Foundation
import Testing
@testable import ScreenSimulationNative

@Test func imageIOHeicAdapterExecutesOneRealIntraRoundTrip() throws {
    let width = 320
    let height = 192
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let offset = (y * width + x) * 4
            let block = ((x / 16) + (y / 16)) & 1
            rgba[offset] = block == 0 ? UInt8(x * 255 / (width - 1)) : 12
            rgba[offset + 1] = block == 0 ? UInt8(y * 255 / (height - 1)) : 220
            rgba[offset + 2] = block == 0 ? 230 : UInt8((x + y) & 255)
        }
    }
    let result = try ImageIOHeicRecordingAdapter.roundTrip(ImageIOHeicStillRequest(
        profileID: "iphone-heic-photo-v1",
        width: width,
        height: height,
        quality: 0.82,
        colorSpace: .displayP3D65,
        rgba8: rgba
    ))
    #expect(result.profileID == "iphone-heic-photo-v1")
    #expect(result.width == width)
    #expect(result.height == height)
    #expect(result.rgba8.count == rgba.count)
    #expect(result.encodedBytes > 0)
    #expect(result.encodedSHA256.count == 32)
    #expect(result.rgba8 != rgba)
    #expect(stride(from: 3, to: result.rgba8.count, by: 4).allSatisfy {
        result.rgba8[$0] == 255
    })
}

@Test func imageIOHeicAdapterRejectsNonOpaqueInput() {
    #expect(throws: ImageIOHeicRecordingError.nonOpaqueInput) {
        try ImageIOHeicRecordingAdapter.roundTrip(ImageIOHeicStillRequest(
            profileID: "iphone-heic-photo-v1",
            width: 1,
            height: 1,
            quality: 0.82,
            colorSpace: .displayP3D65,
            rgba8: [1, 2, 3, 254]
        ))
    }
}

@Test func imageIOHeicAdapterRejectsInvalidQualityAndRaster() {
    #expect(throws: ImageIOHeicRecordingError.invalidRequest) {
        try ImageIOHeicRecordingAdapter.roundTrip(ImageIOHeicStillRequest(
            profileID: "iphone-heic-photo-v1",
            width: 2,
            height: 1,
            quality: 1.1,
            colorSpace: .displayP3D65,
            rgba8: [0, 0, 0, 255]
        ))
    }
}
