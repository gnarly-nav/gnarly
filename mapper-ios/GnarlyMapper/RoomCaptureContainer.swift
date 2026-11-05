import ARKit
import RoomPlan
import SwiftUI
import UIKit

struct RoomCaptureContainer: UIViewRepresentable {
    @ObservedObject var mapper: MapperViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(mapper: mapper)
    }

    func makeUIView(context: Context) -> RoomCaptureView {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        
        // Explicitly enable LiDAR depth for better surface color occlusion checking
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = .sceneDepth
        }
        
        // Enable scene reconstruction mesh for textured mesh generation
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        
        mapper.arSession.run(configuration)

        let view = RoomCaptureView(frame: .zero, arSession: mapper.arSession)
        view.captureSession.delegate = context.coordinator
        mapper.configure(captureView: view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}

    final class Coordinator: NSObject, RoomCaptureSessionDelegate {
        private let mapper: MapperViewModel

        init(mapper: MapperViewModel) {
            self.mapper = mapper
        }

        func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
            Task { @MainActor in
                mapper.noteRoomUpdate(room)
            }
        }

        func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
            Task { @MainActor in
                mapper.noteCaptureInstruction(instruction)
            }
        }

        func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
            Task { @MainActor in
                mapper.didFinishCapture(data: data, error: error)
            }
        }
    }
}
