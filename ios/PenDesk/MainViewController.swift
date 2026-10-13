import UIKit
import ImageIO

final class MainViewController: UIViewController, UIPencilInteractionDelegate {
    private let link = Link()
    private let canvas = CanvasView()
    private let bar = UIStackView()
    private let barBG = UIView()
    private let dot = UIView()
    private let statusLabel = UILabel()
    private let statsLabel = UILabel()
    private let waitLabel = UILabel()
    private let showBarButton = UIButton(type: .system)
    private var rightButton: UIButton!
    private var eraserButton: UIButton!
    private var screenButton: UIButton!

    // Zustand
    private var connected = false
    private var monitors: [[String: Any]] = []
    private var monIndex = 0
    private var monW: CGFloat = 4, monH: CGFloat = 3
    private var barVisible = true

    // Einstellungen (bleiben gespeichert)
    private let defaults = UserDefaults.standard
    private var screenOn: Bool { get { defaults.object(forKey: "screen") as? Bool ?? true } set { defaults.set(newValue, forKey: "screen") } }
    private var scale: Double { get { defaults.object(forKey: "scale") as? Double ?? 0.75 } set { defaults.set(newValue, forKey: "scale") } }
    private var quality: Int { get { defaults.object(forKey: "quality") as? Int ?? 60 } set { defaults.set(newValue, forKey: "quality") } }
    private var gamma: Double { get { defaults.object(forKey: "gamma") as? Double ?? 1.0 } set { defaults.set(newValue, forKey: "gamma") } }
    private var savedMonitor: Int? { get { defaults.object(forKey: "monitor") as? Int } set { defaults.set(newValue, forKey: "monitor") } }

    // Bild: nur das neueste Bild dekodieren, 2 Anfragen gleichzeitig unterwegs
    private let frameQueue = DispatchQueue(label: "pendesk.frames", qos: .userInteractive)
    private var decoding = false          // nur auf frameQueue
    private var pendingFrame: Data?       // nur auf frameQueue
    private var requestTimes: [CFTimeInterval] = []   // nur auf main
    private var latency: Double = 0
    private var frameCount = 0
    private var inFlight = 0

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()

        canvas.link = link
        canvas.gamma = CGFloat(gamma)
        canvas.onStrokeEnded = { [weak self] in self?.updateButtons() }

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

        link.onConnected = { [weak self] on in self?.connectionChanged(on) }
        link.onHello = { [weak self] hello in self?.gotHello(hello) }
        link.onFrame = { [weak self] data in self?.gotFrame(data) }
        link.onRejected = { [weak self] who in
            self?.waitLabel.text = "Verbindung aus dem Netzwerk abgelehnt (\(who)).\nNur USB ist erlaubt."
        }
        link.start()

        _ = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.link.ensureListening()
        }
        _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickStats() }
        connectionChanged(false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    // MARK: UI

    private func makeButton(_ title: String, _ action: Selector) -> UIButton {
        var cfg = UIButton.Configuration.gray()
        cfg.title = title
        cfg.baseForegroundColor = .white
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        let b = UIButton(configuration: cfg)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func setOn(_ b: UIButton, _ on: Bool) {
        var cfg = on ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        cfg.title = b.configuration?.title
        cfg.baseBackgroundColor = on ? UIColor(red: 1, green: 0.48, blue: 0.1, alpha: 1) : nil
        cfg.baseForegroundColor = on ? .black : .white
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        b.configuration = cfg
    }

    private func buildUI() {
        barBG.backgroundColor = UIColor(white: 0.08, alpha: 1)
        view.addSubview(barBG)
        view.addSubview(canvas)

        let brand = UILabel()
        let att = NSMutableAttributedString(string: "Pen", attributes: [.foregroundColor: UIColor.white])
        att.append(NSAttributedString(string: "Desk", attributes: [.foregroundColor: UIColor(red: 1, green: 0.48, blue: 0.1, alpha: 1)]))
        brand.attributedText = att
        brand.font = .boldSystemFont(ofSize: 16)

        dot.layer.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textColor = .white
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statsLabel.textColor = .lightGray

        rightButton = makeButton("Rechtsklick", #selector(toggleRight))
        eraserButton = makeButton("Radierer", #selector(toggleEraser))
        screenButton = makeButton("Bild", #selector(toggleScreen))
        let monButton = makeButton("Monitor", #selector(pickMonitor))
        let qualButton = makeButton("Qualität", #selector(pickQuality))
        let penButton = makeButton("Druck", #selector(pickPressure))
        let hideButton = makeButton("▴", #selector(hideBar))

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for v in [brand, dot, statusLabel, statsLabel, spacer, rightButton!, eraserButton!, screenButton!,
                  monButton, qualButton, penButton, hideButton] {
            bar.addArrangedSubview(v)
        }
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 8
        bar.setCustomSpacing(16, after: brand)
        bar.setCustomSpacing(6, after: dot)
        bar.setCustomSpacing(12, after: statusLabel)
        view.addSubview(bar)

        var cfg = UIButton.Configuration.gray()
        cfg.title = "▾"
        cfg.baseForegroundColor = .white
        showBarButton.configuration = cfg
        showBarButton.alpha = 0.6
        showBarButton.isHidden = true
        showBarButton.addTarget(self, action: #selector(showBar), for: .touchUpInside)
        view.addSubview(showBarButton)

        waitLabel.numberOfLines = 0
        waitLabel.textAlignment = .center
        waitLabel.textColor = .lightGray
        waitLabel.font = .systemFont(ofSize: 17)
        view.addSubview(waitLabel)
        updateButtons()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let barH: CGFloat = barVisible ? 52 : 0
        barBG.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: safe.minY + barH)
        barBG.isHidden = !barVisible
        bar.isHidden = !barVisible
        bar.frame = CGRect(x: safe.minX + 12, y: safe.minY, width: safe.width - 24, height: barH)
        showBarButton.frame = CGRect(x: safe.maxX - 54, y: safe.minY + 6, width: 46, height: 36)

        let area = CGRect(x: safe.minX, y: safe.minY + barH, width: safe.width, height: safe.height - barH)
        let r = monW / monH
        var w = area.width, h = area.width / r
        if h > area.height { h = area.height; w = h * r }
        canvas.frame = CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h).integral
        waitLabel.frame = area.insetBy(dx: 40, dy: 40)
    }

    private func updateButtons() {
        setOn(rightButton, canvas.rightClickOnce)
        setOn(eraserButton, canvas.eraser)
        setOn(screenButton, screenOn)
    }

    @objc private func toggleRight() { canvas.rightClickOnce.toggle(); updateButtons() }
    @objc private func toggleEraser() { canvas.eraser.toggle(); updateButtons() }
    @objc private func hideBar() { barVisible = false; showBarButton.isHidden = false; view.setNeedsLayout() }
    @objc private func showBar() { barVisible = true; showBarButton.isHidden = true; view.setNeedsLayout() }

    @objc private func toggleScreen() {
        screenOn.toggle()
        updateButtons()
        if screenOn { startFrames() } else { canvas.showImage(nil) }
    }

    // Apple Pencil 2: Doppeltippen = Radierer an/aus
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        toggleEraser()
    }

    private func sheet(_ title: String, from sender: Any?, _ items: [(String, Bool, () -> Void)]) {
        let a = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (name, current, action) in items {
            a.addAction(UIAlertAction(title: current ? "✓ " + name : name, style: .default) { _ in action() })
        }
        a.addAction(UIAlertAction(title: "Abbrechen", style: .cancel))
        if let pop = a.popoverPresentationController {
            if let v = sender as? UIView { pop.sourceView = v; pop.sourceRect = v.bounds }
            else { pop.sourceView = view; pop.sourceRect = CGRect(x: view.bounds.midX, y: 60, width: 1, height: 1) }
        }
        present(a, animated: true)
    }

    @objc private func pickMonitor(_ sender: UIButton) {
        guard !monitors.isEmpty else { return }
        var items: [(String, Bool, () -> Void)] = []
        for i in 0..<monitors.count {
            let m = monitors[i]
            let w = m["w"] as? Int ?? 0
            let h = m["h"] as? Int ?? 0
            let primary = (m["primary"] as? Bool ?? false) ? " (Haupt)" : ""
            items.append(("Monitor \(i + 1): \(w)×\(h)\(primary)", i == monIndex, { [weak self] in self?.selectMonitor(i) }))
        }
        sheet("Monitor", from: sender, items)
    }

    @objc private func pickQuality(_ sender: UIButton) {
        let presets: [(String, Double, Int)] = [("Schnell", 0.5, 50), ("Ausgewogen", 0.75, 60), ("Scharf", 1.0, 75)]
        var items: [(String, Bool, () -> Void)] = []
        for preset in presets {
            let (name, s, q) = preset
            items.append((name, screenOn && scale == s && quality == q, { [weak self] in
                guard let self else { return }
                self.scale = s
                self.quality = q
                if !self.screenOn { self.toggleScreen() }
            }))
        }
        items.append(("Bild aus (geringste Verzögerung)", !screenOn, { [weak self] in
            guard let self, self.screenOn else { return }
            self.toggleScreen()
        }))
        sheet("Bildqualität", from: sender, items)
    }

    @objc private func pickPressure(_ sender: UIButton) {
        let presets: [(String, Double)] = [("Weich (leichter Druck reicht)", 0.6), ("Normal", 1.0), ("Hart", 1.6)]
        var items: [(String, Bool, () -> Void)] = []
        for preset in presets {
            let (name, g) = preset
            items.append((name, abs(gamma - g) < 0.01, { [weak self] in
                self?.gamma = g
                self?.canvas.gamma = CGFloat(g)
            }))
        }
        sheet("Druckkurve", from: sender, items)
    }

    // MARK: Verbindung

    private func connectionChanged(_ on: Bool) {
        connected = on
        dot.backgroundColor = on ? UIColor(red: 0.24, green: 0.81, blue: 0.48, alpha: 1) : UIColor(red: 1, green: 0.3, blue: 0.3, alpha: 1)
        statusLabel.text = on ? "Verbunden (USB)" : "Warte auf PC …"
        waitLabel.isHidden = on
        if !on {
            waitLabel.text = "iPad per USB-C mit dem PC verbinden\nund am PC PenDesk starten."
            canvas.showImage(nil)
            requestTimes.removeAll()
            inFlight = 0
        }
    }

    private func gotHello(_ hello: [String: Any]) {
        monitors = hello["mons"] as? [[String: Any]] ?? []
        let def = hello["def"] as? Int ?? 0
        if let s = savedMonitor, s < monitors.count { monIndex = s } else { monIndex = def }
        applyMonitor()
        if let mode = hello["mode"] as? String { statusLabel.text = "Verbunden (USB) · \(mode)" }
        if screenOn { startFrames() }
    }

    private func selectMonitor(_ i: Int) {
        monIndex = i
        savedMonitor = i
        applyMonitor()
    }

    private func applyMonitor() {
        if monIndex < monitors.count {
            let m = monitors[monIndex]
            monW = CGFloat(m["w"] as? Int ?? 4)
            monH = CGFloat(m["h"] as? Int ?? 3)
        }
        view.setNeedsLayout()
        link.sendJSON(.config, ["mon": monIndex])
    }

    // MARK: Bild

    private func startFrames() {
        guard connected, screenOn else { return }
        while inFlight < 2 { requestFrame() }
    }

    private func requestFrame() {
        inFlight += 1
        requestTimes.append(CACurrentMediaTime())
        link.sendJSON(.request, ["m": monIndex, "s": scale, "q": quality])
    }

    /// Läuft auf der Link-Queue
    private func gotFrame(_ data: Data) {
        DispatchQueue.main.async {
            if !self.requestTimes.isEmpty {
                let d = (CACurrentMediaTime() - self.requestTimes.removeFirst()) * 1000
                self.latency = self.latency == 0 ? d : self.latency * 0.85 + d * 0.15
            }
            self.inFlight = max(0, self.inFlight - 1)
            if self.connected && self.screenOn { self.startFrames() }
        }
        frameQueue.async {
            if self.decoding { self.pendingFrame = data; return }
            self.decoding = true
            self.decode(data)
        }
    }

    /// Läuft auf frameQueue
    private func decode(_ data: Data) {
        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, opts) {
            DispatchQueue.main.async {
                if self.connected && self.screenOn {
                    self.canvas.showImage(img)
                    self.frameCount += 1
                }
            }
        }
        if let next = pendingFrame {
            pendingFrame = nil
            decode(next)
        } else {
            decoding = false
        }
    }

    private func tickStats() {
        if connected {
            statsLabel.text = screenOn ? "\(frameCount) fps · \(Int(latency)) ms" : "Tablett-Modus"
        } else {
            statsLabel.text = ""
        }
        frameCount = 0
    }
}
