import SwiftUI
import UIKit
import VisionKit

/// The camera, for “Take Photo”. Not offered where there's no camera, as in the simulator.
struct CameraPicker: UIViewControllerRepresentable {
    var onFinish: (UIImage?) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}

/// VisionKit's document camera, for “Scan Document”. Hands back the pages, or none when
/// cancelled.
struct DocumentScanner: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: VNDocumentCameraViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        var onFinish: ([UIImage]) -> Void

        init(onFinish: @escaping ([UIImage]) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map(scan.imageOfPage(at:)))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish([])
        }
    }
}

/// Turns what the camera captured into files to attach, off the main actor: a 12-megapixel
/// photo takes a noticeable moment to encode.
enum CapturedMedia {
    @concurrent
    static func jpeg(_ image: UIImage) async -> Data? {
        image.jpegData(compressionQuality: 0.9)
    }

    /// Scanned pages as one PDF, each page US Letter wide and as tall as its scan.
    @concurrent
    static func pdf(_ pages: [UIImage]) async -> Data {
        let width: CGFloat = 612
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: 792))
        return renderer.pdfData { context in
            for page in pages {
                let bounds = CGRect(x: 0, y: 0, width: width, height: width * page.size.height / max(page.size.width, 1))
                context.beginPage(withBounds: bounds, pageInfo: [:])
                // Drawn from JPEG data, so the PDF can keep the pages compressed instead of as
                // full bitmaps.
                let compressed = page.jpegData(compressionQuality: 0.8).flatMap(UIImage.init(data:)) ?? page
                compressed.draw(in: bounds)
            }
        }
    }
}
