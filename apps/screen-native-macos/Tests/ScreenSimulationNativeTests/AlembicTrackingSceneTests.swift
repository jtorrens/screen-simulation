import Foundation
import Testing
@testable import ScreenSimulationNative

@Test func usdaTrackingSubsetKeepsCameraPointGroupsAndGeometrySeparate() throws {
    let usda = #"""
    #usda 1.0
    (
        upAxis = "Y"
    )
    def Xform "ShotCamera"
    {
        matrix4d xformOp:transform.timeSamples = {
            0: ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 2, 10, 1) ),
            0.96: ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (1, 2, 10, 1) ),
        }
        def Camera "ShotCameraData"
        {
            float focalLength.timeSamples = { 0: 40, }
            float horizontalAperture.timeSamples = { 0: 24, }
            float verticalAperture.timeSamples = { 0: 13.5, }
        }
    }
    def Xform "SolvedPoints"
    {
        def Mesh "P1"
        {
            matrix4d xformOp:transform.timeSamples = {
                0: ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (1, 2, 3, 1) ),
            }
        }
        def Mesh "P2"
        {
            matrix4d xformOp:transform.timeSamples = {
                0: ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (4, 6, 3, 1) ),
            }
        }
    }
    def Mesh "Plane"
    {
        int[] faceVertexCounts.timeSamples = { 0: [4], }
        int[] faceVertexIndices.timeSamples = { 0: [0, 1, 2, 3], }
        point3f[] points.timeSamples = { 0: [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0)], }
    }
    """#
    let scene = try AlembicTrackingImporter().parse(usda, sourceFileName: "shot.abc")
    #expect(scene.cameras.count == 1)
    #expect(scene.cameras[0].frameRateNumerator == 25)
    #expect(scene.cameras[0].frameRateDenominator == 1)
    #expect(scene.cameras[0].samples[1].sourcePosition.x == 1)
    #expect(scene.pointGroups.count == 1)
    #expect(scene.pointGroups[0].points.map(\.label) == ["P1", "P2"])
    #expect(scene.meshes.count == 1)
    #expect(scene.meshes[0].triangleIndices.count == 6)
}

@Test func actualSynthEyesAlembicCanBeInspectedWhenRequested() throws {
    guard let path = ProcessInfo.processInfo.environment["SCREEN_SYNTH_EYES_ALEMBIC"] else { return }
    let scene = try AlembicTrackingImporter().load(URL(fileURLWithPath: path))
    #expect(scene.cameras.count == 1)
    #expect(scene.pointGroups.contains { $0.points.count == 15 })
    #expect(scene.meshes.contains { $0.label == "Plane01" })
}
