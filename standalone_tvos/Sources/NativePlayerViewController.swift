import AVFoundation
import QuartzCore
import UIKit

private final class RemoteSurface: UIView {
    weak var receiver: NativePlayerViewController?

    override var canBecomeFocused: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { receiver?.remoteBegan(press.type) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { receiver?.remoteEnded(press.type) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { receiver?.remoteEnded(press.type) }
    }
}

/// Native TV player. The existing AVSampleBufferDisplayLayer/libmpv core owns
/// hardware decoding, DV P7->P8.1 conversion and matching the HDMI output.
/// UIView/CALayer transforms provide zoom + independent vertical stretch
/// without forcing DV content down mpv's tone-mapped video-zoom path.
final class NativePlayerViewController: UIViewController, MpvPlayerDelegate {
    private var core: MpvPlayerCore?
    private let thumbs = SeekFrameService()
    private var pendingLink: NativeStreamLink?
    private var hasAppeared = false
    private var playbackGeneration = 0
    private var isPreparingPlayback = false
    private var waitingForFirstFrame = false
    private var firstFrameTimeout: DispatchWorkItem?
    private var subtitleURLToLoad: URL?
    private var subtitleAlreadyRequested = false
    private var link: NativeStreamLink?
    private var clock: Timer?
    private var repeatTimer: Timer?
    private var thumbTimer: Timer?
    private var hideTimer: Timer?
    private var heldDirection = 0

    private var targetSeconds: Double?
    private var currentSeconds: Double = 0
    private var totalSeconds: Double = 0
    private var zoom: CGFloat = 1
    private var verticalStretch: CGFloat = 1
    private var panOriginSeconds: Double = 0
    private var currentPreviewSerial = 0
    private var playing = false
    private var showSettings = false
    private var selectedPictureControl = 0
    private var controlsVisible = true

    private let remote = RemoteSurface()
    private let panel = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let currentLabel = UILabel()
    private let endLabel = UILabel()
    private let filmStrip = UIStackView()
    private var frameViews: [UIImageView] = []
    private let instructionsLabel = UILabel()
    private let picturePanel = UIView()
    private let zoomLabel = UILabel()
    private let stretchLabel = UILabel()
    private let idleLabel = UILabel()
    private let seekTimeLabel = UILabel()

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [remote] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        buildUI()
        // If a previous launch died in the decoder, tell the user WHICH stage
        // was reached. Never persist, display or log the signed media URL.
        if let unfinished = PlayerStartupDiagnostics.unfinishedPhase {
            idleLabel.text = "NUVIO PLAYER\n\nLast playback stopped during: \(unfinished)\n\nTry opening a stream again. If the app closes, reopen it from the Home Screen to see the last stage."
            statusLabel.text = "Diagnostics: \(unfinished)"
        }
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        gesture.cancelsTouchesInView = false
        remote.addGestureRecognizer(gesture)
        clock = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(refreshClock),
                                     userInfo: nil, repeats: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        // Don't initialize a new AVSampleBufferDisplayLayer / mpv VO while
        // tvOS is still attaching the root controller to a scene window.
        if let pendingLink {
            self.pendingLink = nil
            DispatchQueue.main.async { [weak self] in self?.open(pendingLink) }
        }
    }

    /// The scene delegate may receive the deep link before the first on-screen
    /// frame. Hold it until viewDidAppear and avoid launching two MPV contexts
    /// simultaneously if tvOS repeats the same URL callback.
    func open(_ media: NativeStreamLink) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.open(media) }
            return
        }
        guard hasAppeared, isViewLoaded, view.window != nil else {
            pendingLink = media
            loadViewIfNeeded()
            return
        }
        pendingLink = nil
        guard !isPreparingPlayback else {
            // Store the newest link for when startup completes instead of
            // tearing down a partially initialized native decoder.
            pendingLink = media
            return
        }
        isPreparingPlayback = true
        waitingForFirstFrame = true
        subtitleAlreadyRequested = false
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        playbackGeneration += 1
        let generation = playbackGeneration
        PlayerStartupDiagnostics.mark("handoff-received")

        thumbs.clear()
        link = media
        titleLabel.text = media.title
        idleLabel.isHidden = true
        showSettings = false
        picturePanel.isHidden = true
        zoom = 1
        verticalStretch = 1
        targetSeconds = nil
        currentSeconds = 0
        totalSeconds = 0
        statusLabel.text = "Preparing video decoder…"
        showPanel()

        // A short delay gives the scene's window and display link a chance
        // to attach before the native AVFoundation renderer initializes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.preparePlayback(media, generation: generation)
        }
    }

    private func preparePlayback(_ media: NativeStreamLink, generation: Int) {
        guard playbackGeneration == generation, let window = view.window else {
            isPreparingPlayback = false
            showHandoffError("TV window is not ready for playback")
            return
        }
        core?.dispose()
        core = nil

        PlayerStartupDiagnostics.mark("mpv-core-creation")
        let newCore = MpvPlayerCore()
        newCore.delegate = self

        // P7 -> P8.1 mode is applied before MPV initializes.
        // auto also preserves the patched profile conversion behavior;
        // defer display criteria changes until the stream is decoded.
        newCore.setDvConversionMode("dv81")

        PlayerStartupDiagnostics.mark("mpv-initialize")
        guard newCore.initialize(in: window) else {
            isPreparingPlayback = false
            PlayerStartupDiagnostics.clear()
            showHandoffError("Native MPV video decoder failed to initialize")
            return
        }

        PlayerStartupDiagnostics.mark("mpv-initialized")
        core = newCore
        newCore.setVisible(true)
        newCore.updateFrame()
        applyPictureTransform()
        playing = false
        isPreparingPlayback = false
        subtitleURLToLoad = media.subtitle
        statusLabel.text = "Opening paused; waiting for the first frame…"
        showPanel()

        // The original Plezy tvOS flow opens paused, displays one decoded
        // frame, allows AVDisplayManager's format/rate switch to settle, then
        // resumes. Running audio/video through the HDMI blank at open was
        // not safe; do not bypass that first-frame gate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self, weak newCore] in
            guard let self,
                  self.playbackGeneration == generation,
                  self.core === newCore,
                  let newCore else { return }
            PlayerStartupDiagnostics.mark("mpv-pause-before-load")
            newCore.setPropertyAsync("pause", value: "yes") { [weak self, weak newCore] result in
                guard let self,
                      self.playbackGeneration == generation,
                      self.core === newCore,
                      let newCore else { return }
                if case .failure(let error) = result {
                    self.waitingForFirstFrame = false
                    self.showHandoffError("Could not prepare paused playback: \(error.localizedDescription)")
                    return
                }
                self.loadInitialMedia(media, core: newCore, generation: generation)
            }
        }
    }


    private func loadInitialMedia(_ media: NativeStreamLink, core: MpvPlayerCore, generation: Int) {
        guard playbackGeneration == generation, self.core === core else { return }
        PlayerStartupDiagnostics.mark("mpv-loadfile-request-paused")
        let watchdog = DispatchWorkItem { [weak self, weak core] in
            guard let self, let core,
                  self.playbackGeneration == generation,
                  self.core === core, self.waitingForFirstFrame else { return }
            // A file that never publishes a first frame must not be held
            // indefinitely. The viewer can attempt manual Play to test it.
            self.statusLabel.text = "Waiting for video frame timed out. Press Play to try resuming."
            PlayerStartupDiagnostics.mark("mpv-first-frame-timeout")
            self.showPanel()
        }
        firstFrameTimeout?.cancel()
        firstFrameTimeout = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: watchdog)
        core.commandAsync(["loadfile", media.url.absoluteString, "replace"]) { [weak self] result in
            guard let self, self.playbackGeneration == generation else { return }
            switch result {
            case .success:
                // This confirms only that mpv accepted the file command.
                // It is not proof the decoder has presented a frame.
                if self.waitingForFirstFrame {
                    PlayerStartupDiagnostics.mark("mpv-loadfile-accepted-paused")
                }
            case .failure(let error):
                self.firstFrameTimeout?.cancel()
                self.waitingForFirstFrame = false
                PlayerStartupDiagnostics.clear()
                self.showHandoffError("Unable to open the video: \(error.localizedDescription)")
            }
        }
    }

    private func finishDisplayNegotiation() {
        guard waitingForFirstFrame, let core else { return }
        waitingForFirstFrame = false
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        let generation = playbackGeneration
        PlayerStartupDiagnostics.mark("mpv-waiting-for-hdmi-switch")
        statusLabel.text = "Matching display and settling HDMI…"
        showPanel()

        // The native MPV core updates AVDisplayManager from the decoded
        // frame in MPV_EVENT_PLAYBACK_RESTART. Let its display-mode switch
        // finish before unpausing. This mirrors Plezy's Dart startup gate.
        core.awaitDisplayModeSwitch(extraDelayMs: 250) { [weak self, weak core] in
            guard let self, let core,
                  self.playbackGeneration == generation, self.core === core else { return }
            PlayerStartupDiagnostics.mark("mpv-display-matched")
            self.statusLabel.text = "Starting playback…"
            core.setPropertyAsync("pause", value: "no") { [weak self] result in
                guard let self, self.playbackGeneration == generation else { return }
                switch result {
                case .success:
                    self.playing = true
                    PlayerStartupDiagnostics.mark("mpv-unpaused-after-display-switch")
                    self.statusLabel.text = "Left/Right: seek  ·  Up: picture  ·  Menu: close"
                    self.showPanel()
                    // Defer subtitles until after the video is running.
                    self.attachInitialSubtitleIfAvailable()
                case .failure(let error):
                    self.showHandoffError("Playback could not resume: \(error.localizedDescription)")
                }
            }
        }
    }

    private func attachInitialSubtitleIfAvailable() {
        guard !subtitleAlreadyRequested, let subtitleURLToLoad, let core else { return }
        subtitleAlreadyRequested = true
        let generation = playbackGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak core] in
            guard let self, let core,
                  self.playbackGeneration == generation, self.core === core else { return }
            core.commandAsync(["sub-add", subtitleURLToLoad.absoluteString, "select"]) { [weak self] result in
                guard let self, self.playbackGeneration == generation else { return }
                if case .failure = result {
                    self.statusLabel.text = "Playing (external subtitles could not load)"
                }
            }
        }
    }

    func showHandoffError(_ text: String) {
        statusLabel.text = text
        idleLabel.isHidden = true
        panel.isHidden = false
        showPanel()
        NSLog("[NuvioNative] Playback error (URL redacted)")
    }

    func onPropertyChange(name: String, value: Any?, sourceId: Int64?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch name {
            case "duration":
                if let n = value as? NSNumber { self.totalSeconds = max(0, n.doubleValue) }
            case "time-pos":
                if self.targetSeconds == nil, let n = value as? NSNumber {
                    self.currentSeconds = max(0, n.doubleValue)
                }
            case "pause":
                if let n = value as? NSNumber { self.playing = !n.boolValue }
                else if let s = value as? String { self.playing = s != "yes" }
            default: break
            }
        }
    }

    func onEvent(name: String, data: [String: Any]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch name {
            case "start-file":
                PlayerStartupDiagnostics.mark("mpv-start-file")
                self.statusLabel.text = "Opening media container…"
            case "file-loaded":
                PlayerStartupDiagnostics.mark("mpv-file-loaded-paused")
                self.statusLabel.text = "Video loaded; waiting for first frame…"
            case "playback-restart":
                if self.waitingForFirstFrame {
                    PlayerStartupDiagnostics.mark("mpv-first-frame-ready")
                    self.applyPictureTransform()
                    self.finishDisplayNegotiation()
                } else {
                    // Subsequent playback-restart events also occur after
                    // seeking. Do not restart the initial-display gate.
                    self.applyPictureTransform()
                }
            case "end-file":
                if self.waitingForFirstFrame {
                    self.waitingForFirstFrame = false
                    self.firstFrameTimeout?.cancel()
                }
                if self.currentSeconds < 2 {
                    self.statusLabel.text = "The stream ended or could not load"
                    self.showPanel()
                }
            default: break
            }
        }
    }

    private func buildUI() {
        remote.translatesAutoresizingMaskIntoConstraints = false
        remote.backgroundColor = .clear
        remote.receiver = self
        view.addSubview(remote)

        let center = UIView()
        center.translatesAutoresizingMaskIntoConstraints = false
        center.isUserInteractionEnabled = false
        center.backgroundColor = .clear
        view.addSubview(center)

        idleLabel.translatesAutoresizingMaskIntoConstraints = false
        idleLabel.text = "NUVIO PLAYER\n\nOpen a video in Nuvio and select Nuvio Player."
        idleLabel.font = .systemFont(ofSize: 32, weight: .medium)
        idleLabel.textAlignment = .center
        idleLabel.numberOfLines = 0
        idleLabel.textColor = .white
        center.addSubview(idleLabel)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = UIColor(white: 0.03, alpha: 0.86)
        panel.layer.cornerRadius = 24
        panel.clipsToBounds = true
        view.addSubview(panel)

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 29, weight: .semibold)
        titleLabel.text = "Nuvio Player"
        titleLabel.lineBreakMode = .byTruncatingTail

        statusLabel.textColor = .white.withAlphaComponent(0.66)
        statusLabel.font = .systemFont(ofSize: 17, weight: .regular)
        statusLabel.text = "Choose a stream from Nuvio"

        seekTimeLabel.textColor = .white
        seekTimeLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        seekTimeLabel.textAlignment = .center
        seekTimeLabel.isHidden = false

        filmStrip.axis = .horizontal
        filmStrip.spacing = 11
        filmStrip.distribution = .fillEqually
        for i in 0..<5 {
            let image = UIImageView()
            image.contentMode = .scaleAspectFit
            image.backgroundColor = UIColor(white: 0.15, alpha: 1)
            image.layer.cornerRadius = 11
            image.clipsToBounds = true
            image.layer.borderColor = UIColor.white.withAlphaComponent(i == 2 ? 0.95 : 0.15).cgColor
            image.layer.borderWidth = i == 2 ? 3 : 1
            frameViews.append(image)
            filmStrip.addArrangedSubview(image)
        }
        filmStrip.isHidden = false

        currentLabel.textColor = .white
        currentLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        currentLabel.text = "0:00"
        endLabel.textColor = .white
        endLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        endLabel.text = "0:00"
        endLabel.textAlignment = .right
        progress.progressTintColor = .white
        progress.trackTintColor = UIColor(white: 0.4, alpha: 0.6)

        instructionsLabel.text = "Touch remote: scrub    ·    Select: pause/play    ·    ↑ Picture controls"
        instructionsLabel.textColor = .white.withAlphaComponent(0.74)
        instructionsLabel.font = .systemFont(ofSize: 16)
        instructionsLabel.textAlignment = .center

        for item in [titleLabel, statusLabel, seekTimeLabel, filmStrip, currentLabel,
                     endLabel, progress, instructionsLabel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(item)
        }

        picturePanel.translatesAutoresizingMaskIntoConstraints = false
        picturePanel.backgroundColor = UIColor(white: 0.07, alpha: 0.94)
        picturePanel.layer.cornerRadius = 18
        picturePanel.isHidden = true
        picturePanel.isUserInteractionEnabled = false
        view.addSubview(picturePanel)

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
        stretchLabel.font = .monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
        zoomLabel.textColor = .white
        stretchLabel.textColor = .white
        for label in [zoomLabel, stretchLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            picturePanel.addSubview(label)
        }
        updatePictureLabels()

        NSLayoutConstraint.activate([
            remote.topAnchor.constraint(equalTo: view.topAnchor),
            remote.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            remote.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            remote.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            center.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            center.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.85),
            idleLabel.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            idleLabel.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            idleLabel.centerYAnchor.constraint(equalTo: center.centerYAnchor),

            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 68),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -68),
            panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -42),

            titleLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -28),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            seekTimeLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 9),
            seekTimeLabel.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            filmStrip.topAnchor.constraint(equalTo: seekTimeLabel.bottomAnchor, constant: 10),
            filmStrip.heightAnchor.constraint(equalToConstant: 105),
            filmStrip.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28),
            filmStrip.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -28),

            progress.topAnchor.constraint(equalTo: filmStrip.bottomAnchor, constant: 21),
            progress.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28),
            progress.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -28),
            progress.heightAnchor.constraint(equalToConstant: 7),

            currentLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 8),
            currentLabel.leadingAnchor.constraint(equalTo: progress.leadingAnchor),
            endLabel.topAnchor.constraint(equalTo: currentLabel.topAnchor),
            endLabel.trailingAnchor.constraint(equalTo: progress.trailingAnchor),

            instructionsLabel.topAnchor.constraint(equalTo: currentLabel.bottomAnchor, constant: 11),
            instructionsLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            instructionsLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -22),
            instructionsLabel.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -20),

            picturePanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            picturePanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -75),
            picturePanel.widthAnchor.constraint(equalToConstant: 435),
            zoomLabel.topAnchor.constraint(equalTo: picturePanel.topAnchor, constant: 23),
            zoomLabel.leadingAnchor.constraint(equalTo: picturePanel.leadingAnchor, constant: 22),
            zoomLabel.trailingAnchor.constraint(equalTo: picturePanel.trailingAnchor, constant: -22),
            stretchLabel.topAnchor.constraint(equalTo: zoomLabel.bottomAnchor, constant: 18),
            stretchLabel.leadingAnchor.constraint(equalTo: zoomLabel.leadingAnchor),
            stretchLabel.trailingAnchor.constraint(equalTo: zoomLabel.trailingAnchor),
            stretchLabel.bottomAnchor.constraint(equalTo: picturePanel.bottomAnchor, constant: -24)
        ])
        // Hide imagery by alpha instead of isHidden, which would collapse the
        // filmstrip's timeline geometry while seeking.
        filmStrip.alpha = 0
        seekTimeLabel.alpha = 0
        panel.isHidden = false
    }

    private func updatePictureLabels() {
        zoomLabel.text = "\(selectedPictureControl == 0 ? "▶ " : "   ")Zoom: \(Int(zoom * 100))%"
        stretchLabel.text = "\(selectedPictureControl == 1 ? "▶ " : "   ")Vertical stretch: \(Int(verticalStretch * 100))%"
        zoomLabel.textColor = selectedPictureControl == 0 ? .white : .lightGray
        stretchLabel.textColor = selectedPictureControl == 1 ? .white : .lightGray
    }

    private func applyPictureTransform() {
        guard let layer = core?.sampleBufferDisplayLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(zoom, zoom * verticalStretch, 1)
        CATransaction.commit()
    }

    private func changePictureValue(_ direction: Int) {
        if selectedPictureControl == 0 {
            zoom = max(1, min(2.5, zoom + CGFloat(direction) * 0.05))
        } else {
            verticalStretch = max(0.75, min(1.7, verticalStretch + CGFloat(direction) * 0.05))
        }
        applyPictureTransform()
        updatePictureLabels()
        showPanel()
    }

    private func resetPicture() {
        zoom = 1
        verticalStretch = 1
        applyPictureTransform()
        updatePictureLabels()
    }

    func remoteBegan(_ key: UIPress.PressType) {
        switch key {
        case .leftArrow, .rightArrow:
            let direction = key == .rightArrow ? 1 : -1
            if showSettings {
                changePictureValue(direction)
            } else {
                heldDirection = direction
                stepSeek(direction)
                repeatTimer?.invalidate()
                repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.23, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.stepSeek(self.heldDirection)
                }
            }
        case .upArrow:
            showSettings = true
            picturePanel.isHidden = false
            selectedPictureControl = 0
            updatePictureLabels()
            showPanel()
        case .downArrow:
            if showSettings {
                selectedPictureControl = (selectedPictureControl + 1) % 2
                updatePictureLabels()
                showPanel()
            } else { showPanel() }
        case .playPause:
            togglePlayback()
        case .menu:
            if showSettings {
                showSettings = false
                picturePanel.isHidden = true
            } else {
                leavePlayback()
            }
        case .select:
            if showSettings { resetPicture() }
            else if targetSeconds == nil { togglePlayback() }
        default: break
        }
    }

    func remoteEnded(_ key: UIPress.PressType) {
        if key == .leftArrow || key == .rightArrow {
            repeatTimer?.invalidate()
            repeatTimer = nil
            heldDirection = 0
            if !showSettings { commitSeek() }
        }
    }

    private func togglePlayback() {
        guard let core else { return }
        if waitingForFirstFrame {
            // Deliberate user override for sources that never report a frame.
            waitingForFirstFrame = false
            firstFrameTimeout?.cancel()
            PlayerStartupDiagnostics.mark("mpv-manual-unpause")
            core.setProperty("pause", value: "no")
            playing = true
            showPanel()
            return
        }
        playing.toggle()
        core.setProperty("pause", value: playing ? "no" : "yes")
        showPanel()
    }

    private func stepSeek(_ dir: Int) {
        guard core != nil else { return }
        let next = (targetSeconds ?? core?.timePos ?? currentSeconds) + Double(dir) * 10
        targetSeconds = max(0, min(totalSeconds > 0 ? totalSeconds : 86_400, next))
        scheduleFrames()
        refreshLabels()
        showPanel()
    }

    private func commitSeek() {
        guard let seconds = targetSeconds else { return }
        core?.command(["seek", String(format: "%.3f", seconds), "absolute+exact"])
        currentSeconds = seconds
        targetSeconds = nil
        filmStrip.alpha = 0
        seekTimeLabel.alpha = 0
        thumbs.cancel()
        currentPreviewSerial += 1
        showPanel()
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard core != nil, !showSettings else { return }
        switch gesture.state {
        case .began:
            panOriginSeconds = targetSeconds ?? core?.timePos ?? 0
            showPanel()
        case .changed:
            let translation = gesture.translation(in: remote)
            let bound = totalSeconds > 0 ? totalSeconds : 86_400
            targetSeconds = max(0, min(bound, panOriginSeconds + Double(translation.x) * 0.4))
            scheduleFrames()
            refreshLabels()
        case .ended, .cancelled, .failed:
            commitSeek()
        default: break
        }
    }

    private func scheduleFrames() {
        guard targetSeconds != nil else { return }
        filmStrip.alpha = 1
        seekTimeLabel.alpha = 1
        thumbTimer?.invalidate()
        currentPreviewSerial += 1
        let serial = currentPreviewSerial
        for cell in frameViews { cell.image = nil }
        thumbTimer = Timer.scheduledTimer(withTimeInterval: 0.17, repeats: false) { [weak self] _ in
            self?.loadFrames(serial: serial)
        }
    }

    private func loadFrames(serial: Int) {
        guard let link, let targetSeconds else { return }
        thumbs.cancel()
        let center = Int(targetSeconds)
        for index in [2, 1, 3, 0, 4] {
            let second = max(0, center + (index - 2) * 10)
            thumbs.request(url: link.url, second: second) { [weak self] image in
                guard let self, self.currentPreviewSerial == serial, self.targetSeconds != nil else { return }
                self.frameViews[index].image = image
            }
        }
    }

    private func leavePlayback() {
        playbackGeneration += 1
        isPreparingPlayback = false
        waitingForFirstFrame = false
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        subtitleURLToLoad = nil
        subtitleAlreadyRequested = false
        PlayerStartupDiagnostics.clear()
        thumbs.clear()
        thumbTimer?.invalidate()
        core?.setVisible(false)
        core?.dispose()
        core = nil
        link = nil
        targetSeconds = nil
        playing = false
        picturePanel.isHidden = true
        idleLabel.isHidden = false
        statusLabel.text = "Choose a stream from Nuvio"
        titleLabel.text = "Nuvio Player"
        filmStrip.alpha = 0
        seekTimeLabel.alpha = 0
        showPanel()
    }

    private func showPanel() {
        controlsVisible = true
        panel.isHidden = false
        hideTimer?.invalidate()
        if core != nil && targetSeconds == nil && !showSettings {
            hideTimer = Timer.scheduledTimer(withTimeInterval: 7, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.controlsVisible = false
                self.panel.isHidden = true
            }
        }
    }

    @objc private func refreshClock() {
        if targetSeconds == nil {
            currentSeconds = max(0, core?.timePos ?? currentSeconds)
            totalSeconds = max(0, core?.duration ?? totalSeconds)
        }
        refreshLabels()
    }

    private func refreshLabels() {
        let t = targetSeconds ?? currentSeconds
        currentLabel.text = clockString(t)
        endLabel.text = totalSeconds > 0 ? clockString(totalSeconds) : "--:--"
        progress.progress = Float(max(0, min(1, totalSeconds > 0 ? t / totalSeconds : 0)))
        seekTimeLabel.text = "Seek to " + clockString(t)
    }

    private func clockString(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let whole = Int(max(0, seconds))
        let hours = whole / 3600, minutes = (whole / 60) % 60, secs = whole % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    deinit {
        clock?.invalidate()
        firstFrameTimeout?.cancel()
        repeatTimer?.invalidate()
        thumbTimer?.invalidate()
        hideTimer?.invalidate()
        core?.dispose()
    }
}
