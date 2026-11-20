import SwiftUI

struct ResultView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.session?.attempt.studyMode == .practice { PracticeResultView(model:model) }
        else { ExamResultView(model:model) }
    }
}

func annotationColor(_ annotation: Annotation) -> Color {
    switch annotation.type {
    case "notation_suggestion": return .teal
    case "notation_error", "recognition_uncertain": return .orange
    default: return .red
    }
}
struct CompactAnswerView: View {
    let image: UIImage
    let layout: SheetLayout
    let annotation: Annotation?
    var measureErrors: [MeasureError] = []
    var reviewMode = false
    var selectedMeasure: Int? = nil
    var onMeasureTap: ((Int) -> Void)? = nil
    var body: some View {
        VStack(spacing:8) {
            ForEach(AnswerSystemCrop.strips(layout:layout)) { crop in
                if let source = image.cgImage,
                   let row = source.cropping(to:CGRect(x:0,y:CGFloat(crop.bounds.y)*CGFloat(source.height),width:CGFloat(source.width),height:CGFloat(crop.bounds.height)*CGFloat(source.height)).integral) {
                    Image(uiImage:UIImage(cgImage:row)).resizable().scaledToFit()
                        .overlay { GeometryReader { proxy in
                            if let annotation, let box = annotation.bbox, let projected = crop.project(box) {
                                RoundedRectangle(cornerRadius:5).stroke(annotationColor(annotation),lineWidth:2)
                                    .background(annotationColor(annotation).opacity(0.06))
                                    .frame(width:CGFloat(projected.width)*proxy.size.width,height:CGFloat(projected.height)*proxy.size.height)
                                    .position(x:CGFloat(projected.x+projected.width/2)*proxy.size.width,y:CGFloat(projected.y+projected.height/2)*proxy.size.height)
                                    .accessibilityLabel(annotation.message)
                            }
                            if reviewMode {
                                ForEach(crop.measureRegions(layout:layout)) { region in
                                    let error = measureErrors.first(where: { $0.measure == region.id })
                                    let color: Color = selectedMeasure == region.id ? SolfegeTheme.violet : error == nil ? .gray : .red
                                    Button { onMeasureTap?(region.id) } label: {
                                        RoundedRectangle(cornerRadius:5).fill(color.opacity(error == nil ? 0.02 : 0.07))
                                            .overlay(RoundedRectangle(cornerRadius:5).stroke(color.opacity(error == nil ? 0.35 : 0.85),lineWidth:error == nil ? 1 : 2))
                                            .overlay(alignment:.topLeading) {
                                                Text("\(region.id)" + (error.map { " · " + $0.label } ?? ""))
                                                    .font(.caption2.weight(.semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.65)
                                                    .padding(4).background(.white.opacity(0.9),in:RoundedRectangle(cornerRadius:4)).padding(3)
                                            }
                                    }.buttonStyle(.plain).disabled(onMeasureTap == nil)
                                        .frame(width:CGFloat(region.bounds.width)*proxy.size.width,height:CGFloat(region.bounds.height)*proxy.size.height)
                                        .position(x:CGFloat(region.bounds.x+region.bounds.width/2)*proxy.size.width,y:CGFloat(region.bounds.y+region.bounds.height/2)*proxy.size.height)
                                        .accessibilityLabel("\(region.id)마디 · " + (error?.label ?? "오류 미표시"))
                                        .accessibilityIdentifier("self-assess-measure-\(region.id)")
                                }
                            }
                        } }
                }
            }
        }.background(.white)
    }
}
