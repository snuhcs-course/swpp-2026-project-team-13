import Foundation

// Display-only crops. Exported handwriting and persisted normalized coordinates stay unchanged.
struct AnswerSystemCrop: Identifiable, Equatable {
    var id: Int
    var bounds: BBox
    static func strips(layout: SheetLayout) -> [AnswerSystemCrop] {
        let width = Double(layout.logicalWidth), height = Double(layout.logicalHeight)
        guard width > 0, height > 0 else { return [] }
        return layout.systems.compactMap { system in
            guard let top = system.staffLineY.min(), let bottom = system.staffLineY.max() else { return nil }
            let y = max(0,top-80), end = min(height,bottom+80)
            return AnswerSystemCrop(id:system.index,bounds:BBox(x:0,y:y/height,width:1,height:(end-y)/height))
        }
    }
    func project(_ box: BBox) -> BBox? {
        guard bounds.isValid, box.isValid else { return nil }
        let left = max(box.x,bounds.x), right = min(box.x+box.width,bounds.x+bounds.width)
        let top = max(box.y,bounds.y), bottom = min(box.y+box.height,bounds.y+bounds.height)
        guard right > left, bottom > top else { return nil }
        return BBox(x:(left-bounds.x)/bounds.width,y:(top-bounds.y)/bounds.height,width:(right-left)/bounds.width,height:(bottom-top)/bounds.height)
    }
}
