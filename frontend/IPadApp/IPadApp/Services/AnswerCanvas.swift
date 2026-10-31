import SwiftUI
import PencilKit
import ImageIO
import UniformTypeIdentifiers

@MainActor final class DrawingController: ObservableObject {
    let canvas = PKCanvasView()
    let pencilInteraction = UIPencilInteraction()
    @Published var erasing = false { didSet { updateTool() } }
    @Published var penWidth: CGFloat = 2 { didSet { updateTool() } }
    @Published var fingerDrawing = false { didSet { canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly } }
    @Published var revision = 0
    var onChange: ((PKDrawing) -> Void)?
    init() {
        canvas.backgroundColor = .clear; canvas.isOpaque = false; canvas.overrideUserInterfaceStyle = .light
        canvas.contentSize = CGSize(width: 1330, height: 846); canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly; canvas.addInteraction(pencilInteraction); updateTool()
    }
    func updateTool() { canvas.tool = erasing ? PKEraserTool(.vector) : PKInkingTool(.pen, color: .black, width: penWidth) }
    func undo() { canvas.undoManager?.undo() }
    func redo() { canvas.undoManager?.redo() }
    func load(_ drawing: PKDrawing) { canvas.drawing = drawing; canvas.undoManager?.removeAllActions(); revision += 1 }
    func freeze(_ value: Bool) { canvas.isUserInteractionEnabled = !value }
}

struct PencilSurface: UIViewRepresentable {
    @ObservedObject var drawing: DrawingController
    func makeCoordinator() -> Coordinator { Coordinator(drawing) }
    func makeUIView(context: Context) -> PKCanvasView { drawing.canvas.delegate = context.coordinator; drawing.pencilInteraction.delegate = context.coordinator; return drawing.canvas }
    func updateUIView(_ uiView: PKCanvasView, context: Context) { }
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        let controller: DrawingController
        init(_ controller: DrawingController) { self.controller = controller }
        private func handleDoubleTap() {
            guard controller.canvas.isUserInteractionEnabled else { return }
            switch UIPencilInteraction.preferredTapAction {
            case .switchEraser, .switchPrevious: controller.erasing.toggle()
            default: break
            }
        }
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) { handleDoubleTap() }
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) { handleDoubleTap() }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { controller.revision += 1; controller.onChange?(canvasView.drawing) }
    }
}

struct AnswerCanvas: View {
    let template: UIImage
    @ObservedObject var drawing: DrawingController
    var layout: SheetLayout? = nil
    var body: some View {
        GeometryReader { proxy in
            let ratio = proxy.size.width / 1330
            ZStack(alignment: .topLeading) {
                Image(uiImage: template).resizable().frame(width: 1330, height: 846)
                PencilSurface(drawing: drawing).frame(width: 1330, height: 846)
            }
            .frame(width: 1330, height: 846).scaleEffect(ratio, anchor: .topLeading)
        }
        // Keep canonical PencilKit/export coordinates. The new sheet only
        // crops its unused bottom margin from the interactive presentation.
        .aspectRatio(1330.0 / Double(layout?.displayHeight ?? 846), contentMode: .fit)
        .contentShape(Rectangle())
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("8마디 답안 오선, Apple Pencil로 필기하세요")
    }
}

enum AnswerExporter {
    @MainActor static func png(template: UIImage, drawing: PKDrawing, layout: SheetLayout) throws -> Data {
        try layout.validate()
        let rect = CGRect(x: 0, y: 0, width: layout.logicalWidth, height: layout.logicalHeight)
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { c in
            UIColor.white.setFill(); c.fill(rect)
            template.draw(in: rect)
            drawing.image(from: rect, scale: 2).draw(in: rect)
        }
        // An explicit sRGB, 8-bit, opaque bitmap avoids device gamut and renderer format changes.
        guard let source = image.cgImage, let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 2660, height: 1692, bitsPerComponent: 8, bytesPerRow: 2660*4, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw SORIError.storage("답안 이미지를 만들지 못했습니다.") }
        context.draw(source, in: CGRect(x: 0, y: 0, width: 2660, height: 1692))
        let output = NSMutableData()
        guard let rgb = context.makeImage(), let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw SORIError.storage("PNG를 만들지 못했습니다.") }
        CGImageDestinationAddImage(dest, rgb, nil)
        guard CGImageDestinationFinalize(dest), output.length <= 10_485_760 else { throw SORIError.storage("답안 PNG 용량이 제한을 초과했습니다.") }
        return output as Data
    }
    static func validateTemplate(_ data: Data, layout: SheetLayout) throws -> UIImage {
        guard data.sha256 == layout.templateSha256, let image = UIImage(data: data),
              image.cgImage?.width == layout.pixelWidth, image.cgImage?.height == layout.pixelHeight else { throw SORIError.invalidScore("오선 템플릿의 해시 또는 크기가 다릅니다.") }; return image
    }
}
