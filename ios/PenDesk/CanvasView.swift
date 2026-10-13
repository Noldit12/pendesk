import UIKit

/// Zeigt das PC-Bild und wandelt Apple-Pencil-Eingaben in Stift-Samples um.
/// Finger werden ignoriert (Handballen kann aufliegen).
final class CanvasView: UIView {
    var link: Link?

    // Vom ViewController gesetzt
    var rightClickOnce = false
    var eraser = false
    var gamma: CGFloat = 1.0
    var onStrokeEnded: (() -> Void)?

    let imageLayer = CALayer()
    private let cursor = CAShapeLayer()
    private var down = false
    private var strokeRight = false
    private var leaveWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor(white: 0.07, alpha: 1)
        isMultipleTouchEnabled = true
        clipsToBounds = true
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(imageLayer)

        cursor.path = UIBezierPath(ovalIn: CGRect(x: -9, y: -9, width: 18, height: 18)).cgPath
        cursor.strokeColor = UIColor(red: 1, green: 0.48, blue: 0.1, alpha: 1).cgColor
        cursor.fillColor = UIColor.clear.cgColor
        cursor.lineWidth = 2
        cursor.isHidden = true
        cursor.actions = ["position": NSNull(), "hidden": NSNull(), "fillColor": NSNull()]
        layer.addSublayer(cursor)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageLayer.frame = bounds
    }

    func showImage(_ img: CGImage?) {
        imageLayer.contents = img
    }

    // MARK: Pencil

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first(where: { $0.type == .pencil }) else { return }
        leaveWork?.cancel()
        down = true
        strokeRight = rightClickOnce
        send([sample(t, contact: true)], at: t)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard down, let t = touches.first(where: { $0.type == .pencil }) else { return }
        let samples = event?.coalescedTouches(for: t) ?? [t]
        send(samples.map { sample($0, contact: true) }, at: t)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        guard down, let t = touches.first(where: { $0.type == .pencil }) else { return }
        down = false
        send([sample(t, contact: false)], at: t)
        if strokeRight {
            rightClickOnce = false
            onStrokeEnded?()
        }
        strokeRight = false
        // Stift "verlässt" den Bildschirm kurz danach (kein Schweben beim iPad Pro M1)
        let w = DispatchWorkItem { [weak self] in
            self?.link?.sendJSON(.pen, [["l"]])
            self?.cursor.isHidden = true
        }
        leaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    private func send(_ msgs: [[Any]], at t: UITouch) {
        link?.sendJSON(.pen, msgs)
        let p = t.preciseLocation(in: self)
        cursor.position = p
        cursor.fillColor = down ? UIColor(red: 1, green: 0.48, blue: 0.1, alpha: 0.35).cgColor : UIColor.clear.cgColor
        cursor.isHidden = false
    }

    private func sample(_ s: UITouch, contact: Bool) -> [Any] {
        let p = s.preciseLocation(in: self)
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        let x = min(max(p.x / w, 0), 1)
        let y = min(max(p.y / h, 0), 1)
        var pressure: CGFloat = 0
        if contact {
            let raw = s.maximumPossibleForce > 0 ? s.force / s.maximumPossibleForce : 0.5
            pressure = raw <= 0 ? 0 : min(1, pow(raw, gamma))
        }
        let (tx, ty) = tilt(s)
        return ["p", round5(x), round5(y), round5(pressure), tx, ty,
                contact ? 1 : 0, strokeRight ? 1 : 0, eraser ? 1 : 0]
    }

    private func round5(_ v: CGFloat) -> Double {
        (Double(v) * 100_000).rounded() / 100_000
    }

    /// Neigung im Windows-Format (Grad, -90...90)
    private func tilt(_ s: UITouch) -> (Int, Int) {
        let alt = Double(s.altitudeAngle)          // pi/2 = senkrecht
        guard alt < .pi / 2 - 0.001 else { return (0, 0) }
        let az = Double(s.azimuthAngle(in: self))
        let t = tan(alt)
        let tx = atan(cos(az) / t) * 180 / .pi
        let ty = atan(sin(az) / t) * 180 / .pi
        return (Int(tx.rounded()), Int(ty.rounded()))
    }
}
