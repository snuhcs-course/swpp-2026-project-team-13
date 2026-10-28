import SwiftUI
import UIKit

struct MelodyPianoView: UIViewRepresentable {
    var range: ClosedRange<Int>
    var enabled: Bool
    var onDown: (Int) -> Void
    var onUp: (Int) -> Void
    func makeUIView(context: Context) -> MelodyPianoKeyboard {
        let view = MelodyPianoKeyboard()
        view.configure(range:range,enabled:enabled,onDown:onDown,onUp:onUp)
        return view
    }
    func updateUIView(_ view: MelodyPianoKeyboard, context: Context) {
        view.configure(range:range,enabled:enabled,onDown:onDown,onUp:onUp)
    }
    static func dismantleUIView(_ uiView: MelodyPianoKeyboard, coordinator: ()) { uiView.releaseAll() }
}

final class MelodyPianoKeyboard: UIView {
    private var range = 60...84
    private var geometry = PianoGeometry(range:60...84)
    private var fingers: [UITouch:Int] = [:]
    private var counts: [Int:Int] = [:]
    private var onDown: (Int)->Void = { _ in }
    private var onUp: (Int)->Void = { _ in }
    private var enabled = true
    override init(frame: CGRect) {
        super.init(frame:frame)
        isMultipleTouchEnabled = true; isExclusiveTouch = true
        backgroundColor = UIColor(SORITheme.ink)
        layer.cornerRadius = 14; clipsToBounds = true
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(range: ClosedRange<Int>, enabled: Bool, onDown: @escaping (Int)->Void, onUp: @escaping (Int)->Void) {
        if self.range != range || self.enabled != enabled { releaseAll() }
        self.onDown = onDown; self.onUp = onUp; self.enabled = enabled
        isUserInteractionEnabled = enabled
        if self.range != range { self.range = range; geometry = PianoGeometry(range:range); setNeedsDisplay() }
        alpha = enabled ? 1 : 0.55
    }
    override func layoutSubviews() { super.layoutSubviews(); buildAccessibility(); setNeedsDisplay() }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { releaseAll() } }
    private func rect(_ key: PianoKeyGeometry) -> CGRect {
        CGRect(x:key.x*Double(bounds.width),y:0,width:key.width*Double(bounds.width),height:key.height*Double(bounds.height))
    }
    override func draw(_ rect: CGRect) {
        for key in geometry.keys {
            let frame = self.rect(key).insetBy(dx:key.black ? 0 : 1,dy:1)
            let active = counts[key.midi,default:0] > 0
            let color: UIColor = active ? UIColor(key.black ? SORITheme.violet : SORITheme.soft) : key.black ? UIColor(red:0.12,green:0.14,blue:0.21,alpha:1) : .white
            color.setFill(); UIBezierPath(roundedRect:frame,cornerRadius:key.black ? 6 : 7).fill()
            let label = MelodyRound.noteName(key.midi)
            let font = UIFont.systemFont(ofSize:key.black ? 12 : 15,weight:key.midi % 12 == 0 ? .bold : .medium)
            let attributes: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:key.black ? UIColor.white.withAlphaComponent(0.75) : UIColor.darkGray]
            let size = label.size(withAttributes:attributes)
            label.draw(at:CGPoint(x:frame.midX-size.width/2,y:frame.maxY-size.height-14),withAttributes:attributes)
            if !key.black {
                UIColor(SORITheme.violet).withAlphaComponent(active ? 1 : 0.12).setFill()
                UIBezierPath(roundedRect:CGRect(x:frame.minX+6,y:frame.maxY-6,width:frame.width-12,height:3),cornerRadius:1.5).fill()
            }
        }
    }
    private func hit(_ touch: UITouch) -> Int? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let point = touch.location(in:self)
        return geometry.key(x:Double(point.x/bounds.width),y:Double(point.y/bounds.height))
    }
    private func down(_ midi: Int) { counts[midi,default:0] += 1; onDown(midi); setNeedsDisplay() }
    private func up(_ midi: Int) { counts[midi] = max(0,counts[midi,default:1]-1); onUp(midi); setNeedsDisplay() }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Deterministic ordering for genuinely simultaneous fingers; every touch is retained.
        for touch in touches.sorted(by: { $0.timestamp == $1.timestamp ? $0.location(in:self).x < $1.location(in:self).x : $0.timestamp < $1.timestamp }) {
            if let midi = hit(touch) { fingers[touch] = midi; down(midi) }
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let previous = fingers[touch], next = hit(touch)
            guard previous != next else { continue }
            if let previous { up(previous) }; fingers[touch] = next
            if let next { down(next) }
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { if let midi = fingers.removeValue(forKey:touch) { up(midi) } }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches,with:event) }
    func releaseAll() {
        for midi in fingers.values { onUp(midi) }
        fingers.removeAll(); counts.removeAll(); setNeedsDisplay()
    }
    private func buildAccessibility() {
        accessibilityElements = geometry.keys.sorted { $0.midi < $1.midi }.map { key in
            let element = MelodyPianoAccessibleKey(accessibilityContainer:self)
            element.accessibilityLabel = MelodyRound.noteName(key.midi)
            element.accessibilityTraits = .button
            // White-key accessibility targets occupy their unobscured lower region.
            var frame = rect(key)
            if !key.black { frame.origin.y = bounds.height*0.62; frame.size.height = bounds.height*0.38 }
            element.accessibilityFrameInContainerSpace = frame
            element.activate = { [weak self] in
                guard let self, self.enabled else { return false }
                self.down(key.midi)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for:.milliseconds(120)); self?.up(key.midi)
                }
                return true
            }
            return element
        }
    }
}
private final class MelodyPianoAccessibleKey: UIAccessibilityElement {
    var activate: ()->Bool = { false }
    override func accessibilityActivate() -> Bool { activate() }
}
