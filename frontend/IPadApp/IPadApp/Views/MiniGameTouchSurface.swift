import SwiftUI
import UIKit

// Direct touch/Pencil input: no long-press delay, one terminal tap OR drag action.
struct MiniGameTouchSurface: UIViewRepresentable {
    var tapOnly = false
    var moved: (CGPoint, CGPoint) -> Void = { _,_ in }
    var ended: (CGPoint, CGPoint, Bool) -> Void
    var cancelled: () -> Void = {}
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear
        let gesture = MiniGameDirectGesture(target:nil,action:nil)
        gesture.cancelsTouchesInView = true; view.addGestureRecognizer(gesture)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        guard let gesture = view.gestureRecognizers?.first as? MiniGameDirectGesture else { return }
        gesture.tapOnly = tapOnly; gesture.moved = moved; gesture.ended = ended; gesture.cancelled = cancelled
    }
}

private final class MiniGameDirectGesture: UIGestureRecognizer {
    var tapOnly = false
    var moved: (CGPoint, CGPoint) -> Void = { _,_ in }
    var ended: (CGPoint, CGPoint, Bool) -> Void = { _,_,_ in }
    var cancelled: () -> Void = {}
    private var touch: UITouch?
    private var origin = CGPoint.zero
    private var maximumDistance = 0.0
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, touches.count == 1, let first = touches.first else { state = .cancelled; return }
        touch = first; origin = first.location(in:view); maximumDistance = 0
        if !tapOnly { state = .began }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch else { return }
        let point = touch.location(in:view)
        maximumDistance = max(maximumDistance,Double(hypot(point.x-origin.x,point.y-origin.y)))
        if tapOnly {
            if !MiniGameGesture.isTap(maximumDistance:maximumDistance,pencil:touch.type == .pencil) { state = .failed }
            return
        }
        moved(origin,point); state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch else { return }
        let point = touch.location(in:view)
        maximumDistance = max(maximumDistance,Double(hypot(point.x-origin.x,point.y-origin.y)))
        ended(origin,point,MiniGameGesture.isTap(maximumDistance:maximumDistance,pencil:touch.type == .pencil))
        state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { cancelled(); state = .cancelled }
    override func reset() { touch = nil; maximumDistance = 0; super.reset() }
}
