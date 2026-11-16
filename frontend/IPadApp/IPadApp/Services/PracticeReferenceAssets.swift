import UIKit

// A new engraving is a display artifact of the same hash-pinned MusicXML.
// Historical handwriting is always drawn from its original submitted PNG.
@MainActor enum PracticeReferenceAssets {
    struct Entry: Decodable {
        var resource: String
        var sha256: String
        var sizeBytes: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var geometry: PracticeReviewGeometry
    }
    private struct Manifest: Decodable { var scores: [String:Entry] }
    private static let manifest: Manifest? = try? Bundled.decode("practice-layout-v2")
    private static let cache = NSCache<NSString,UIImage>()
    static func reference(for question: Question) -> (image: UIImage, geometry: PracticeReviewGeometry)? {
        guard let entry = manifest?.scores[question.scoreAssets.main.sha256], entry.geometry.isValid else { return nil }
        if let image = cache.object(forKey:entry.sha256 as NSString) { return (image,entry.geometry) }
        guard let bytes = try? Bundled.data(entry.resource,ext:"png"), bytes.count == entry.sizeBytes,
              bytes.sha256 == entry.sha256, let image = UIImage(data:bytes),
              image.cgImage?.width == entry.pixelWidth, image.cgImage?.height == entry.pixelHeight else { return nil }
        cache.setObject(image,forKey:entry.sha256 as NSString,cost:entry.pixelWidth*entry.pixelHeight*4)
        cache.totalCostLimit = 32*1024*1024
        return (image,entry.geometry)
    }
}
