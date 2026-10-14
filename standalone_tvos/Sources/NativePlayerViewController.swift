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
    private enum ToolPanel { case none, picture, audio, subtitles, info }
    private enum TrackKind: String { case audio, sub }
    private struct TrackChoice {
        let id: String
        let caption: String
        let selected: Bool
    }
    private var toolPanel: ToolPanel = .none
    private var toolbarFocused = false
    private var toolbarIndex = 0
    private var trackChoices: [TrackChoice] = []
    private var choiceIndex = 0
    private var trackRefreshID = 0
    private var infoRows: [String] = []
    private var seekCommitTimer: Timer?
    // MPV takes time to acknowledge a remote keyframe seek. Pin the most
    // recently committed target while it catches up so another swipe cannot
    // accidentally start from the old playback position.
    private var committedSeekTarget: Double?
    private var committedSeekDate: Date?
    private var previewHideTimer: Timer?
    private var previewIsVisible = false
    private let toolbar = UIStackView()
    private var toolbarButtons: [UIButton] = []
    private let trackPanel = UIView()
    private let trackTitle = UILabel()
    private var trackLabels: [UILabel] = []

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
        // One directional swipe = one 15 second step, regardless of swipe velocity.
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(remoteSwipe(_:)))
            swipe.direction = direction
            swipe.cancelsTouchesInView = true
            remote.addGestureRecognizer(swipe)
        }
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
        previewHideTimer?.invalidate()
        previewIsVisible = false
        filmStrip.alpha = 0
        seekTimeLabel.alpha = 0
        link = media
        titleLabel.text = ""
        idleLabel.isHidden = true
        showSettings = false
        picturePanel.isHidden = true
        zoom = 1
        verticalStretch = 1
        toolPanel = .none
        toolbarFocused = false
        trackPanel.isHidden = true
        toolbarIndex = 0
        targetSeconds = nil
        committedSeekTarget = nil
        committedSeekDate = nil
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
        // Required for MpvPlayerCore's cached timePos/duration. Unlike Plezy
        // Flutter's player plugin, this standalone app never subscribed.
        // Without these observers both caches permanently read 0, so every
        // seek calculates from the start of the movie. This is the root cause.
        newCore.observeProperty("time-pos", format: "double")
        newCore.observeProperty("duration", format: "double")
        newCore.observeProperty("pause", format: "flag")
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
                    self.statusLabel.text = ""
                    self.showPanel()
                    // Defer subtitles until after the video is running.
                    self.attachInitialSubtitleIfAvailable()
                    self.showPanel()
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
                if self.targetSeconds == nil, self.committedSeekTarget == nil,
                   let n = value as? NSNumber {
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

        idleLabel.translatesAutoresizingMaskIntoConstraints = false
        idleLabel.text = "NUVIO PLAYER\n\nChoose a stream in Nuvio"
        idleLabel.font = .systemFont(ofSize: 30, weight: .medium)
        idleLabel.textAlignment = .center
        idleLabel.numberOfLines = 0
        idleLabel.textColor = .white
        view.addSubview(idleLabel)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Choose a stream in Nuvio"
        statusLabel.textColor = .white.withAlphaComponent(0.88)
        statusLabel.font = .systemFont(ofSize: 17)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        view.addSubview(statusLabel)

        // A transparent, one-line timeline replaces the large black transport box.
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = .clear
        panel.isUserInteractionEnabled = false
        view.addSubview(panel)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = .white
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.35)
        progress.layer.cornerRadius = 2
        progress.clipsToBounds = true
        panel.addSubview(progress)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.axis = .horizontal
        toolbar.alignment = .center
        toolbar.spacing = 12
        toolbar.distribution = .fillEqually
        // Text-based controls are intentionally used rather than SF Symbols:
        // the assetless sideloaded tvOS app returned nil for some of the
        // requested system icons, leaving three invisible buttons.
        for (name, label) in [("Audio", "AUDIO"), ("Subtitles", "CC"), ("Info", "INFO")] {
            let button = UIButton(type: .system)
            button.setTitle(label, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
            button.setTitleColor(.white, for: .normal)
            button.backgroundColor = UIColor.white.withAlphaComponent(0.14)
            button.layer.cornerRadius = 13
            button.isUserInteractionEnabled = false
            button.accessibilityLabel = name
            toolbarButtons.append(button)
            toolbar.addArrangedSubview(button)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: name == "Audio" ? 90 : (name == "Info" ? 75 : 58)).isActive = true
            button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        }
        panel.addSubview(toolbar)

        filmStrip.translatesAutoresizingMaskIntoConstraints = false
        filmStrip.axis = .horizontal
        filmStrip.spacing = 9
        filmStrip.distribution = .fillEqually
        filmStrip.alignment = .fill
        filmStrip.isUserInteractionEnabled = false
        view.addSubview(filmStrip)
        for i in 0..<5 {
            let image = UIImageView()
            image.contentMode = .scaleAspectFill
            image.backgroundColor = UIColor(white: 0.15, alpha: 0.65)
            image.layer.cornerRadius = 9
            image.layer.borderColor = UIColor.white.withAlphaComponent(i == 2 ? 0.96 : 0.15).cgColor
            image.layer.borderWidth = i == 2 ? 3 : 1
            image.clipsToBounds = true
            image.isUserInteractionEnabled = false
            frameViews.append(image)
            filmStrip.addArrangedSubview(image)
        }
        filmStrip.alpha = 0
        seekTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        seekTimeLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        seekTimeLabel.textColor = .white
        seekTimeLabel.textAlignment = .center
        seekTimeLabel.alpha = 0
        view.addSubview(seekTimeLabel)

        // Retain the proven picture-controls panel.
        picturePanel.translatesAutoresizingMaskIntoConstraints = false
        picturePanel.backgroundColor = UIColor(white: 0.075, alpha: 0.94)
        picturePanel.layer.cornerRadius = 18
        picturePanel.isHidden = true
        picturePanel.isUserInteractionEnabled = false
        view.addSubview(picturePanel)
        for label in [zoomLabel, stretchLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
            label.textColor = .white
            picturePanel.addSubview(label)
        }
        updatePictureLabels()

        // Audio/subtitle/info menu shares the zoom panel's simple vertical layout.
        trackPanel.translatesAutoresizingMaskIntoConstraints = false
        trackPanel.backgroundColor = UIColor(white: 0.075, alpha: 0.94)
        trackPanel.layer.cornerRadius = 18
        trackPanel.isUserInteractionEnabled = false
        trackPanel.isHidden = true
        view.addSubview(trackPanel)
        let rows = UIStackView()
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.axis = .vertical
        rows.spacing = 9
        trackPanel.addSubview(rows)
        trackTitle.font = .systemFont(ofSize: 23, weight: .semibold)
        trackTitle.textColor = .white
        rows.addArrangedSubview(trackTitle)
        trackTitle.heightAnchor.constraint(equalToConstant: 40).isActive = true
        for _ in 0..<7 {
            let label = UILabel()
            label.font = .systemFont(ofSize: 19)
            label.textColor = .white
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.75
            label.heightAnchor.constraint(equalToConstant: 35).isActive = true
            trackLabels.append(label)
            rows.addArrangedSubview(label)
        }
        NSLayoutConstraint.activate([
            remote.topAnchor.constraint(equalTo: view.topAnchor),
            remote.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            remote.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            remote.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            idleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            idleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            idleLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.85),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -20),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.85),
            panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -19),
            panel.heightAnchor.constraint(equalToConstant: 56),
            progress.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            progress.trailingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: -26),
            progress.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            progress.heightAnchor.constraint(equalToConstant: 5),
            toolbar.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            toolbar.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            filmStrip.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 140),
            filmStrip.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -140),
            filmStrip.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -22),
            filmStrip.heightAnchor.constraint(equalToConstant: 115),
            seekTimeLabel.centerXAnchor.constraint(equalTo: filmStrip.centerXAnchor),
            seekTimeLabel.bottomAnchor.constraint(equalTo: filmStrip.topAnchor, constant: -10),
            picturePanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            picturePanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -45),
            picturePanel.widthAnchor.constraint(equalToConstant: 440),
            zoomLabel.topAnchor.constraint(equalTo: picturePanel.topAnchor, constant: 23),
            zoomLabel.leadingAnchor.constraint(equalTo: picturePanel.leadingAnchor, constant: 22),
            zoomLabel.trailingAnchor.constraint(equalTo: picturePanel.trailingAnchor, constant: -22),
            stretchLabel.topAnchor.constraint(equalTo: zoomLabel.bottomAnchor, constant: 18),
            stretchLabel.leadingAnchor.constraint(equalTo: zoomLabel.leadingAnchor),
            stretchLabel.trailingAnchor.constraint(equalTo: zoomLabel.trailingAnchor),
            stretchLabel.bottomAnchor.constraint(equalTo: picturePanel.bottomAnchor, constant: -24),
            trackPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -35),
            trackPanel.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -22),
            trackPanel.widthAnchor.constraint(equalToConstant: 550),
            rows.leadingAnchor.constraint(equalTo: trackPanel.leadingAnchor, constant: 23),
            rows.trailingAnchor.constraint(equalTo: trackPanel.trailingAnchor, constant: -23),
            rows.topAnchor.constraint(equalTo: trackPanel.topAnchor, constant: 20),
            rows.bottomAnchor.constraint(equalTo: trackPanel.bottomAnchor, constant: -20)
        ])
        panel.isHidden = true
        updateToolbarFocus()
    }

    private func updateToolbarFocus() {
        for (index, button) in toolbarButtons.enumerated() {
            let selected = toolbarFocused && toolPanel == .none && index == toolbarIndex
            button.layer.borderWidth = selected ? 2.2 : 0
            button.layer.borderColor = UIColor.white.cgColor
            button.backgroundColor = selected
                ? UIColor.white.withAlphaComponent(0.30)
                : UIColor.white.withAlphaComponent(0.12)
        }
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
            if toolPanel == .picture {
                changePictureValue(direction)
            } else if toolPanel == .none {
                if toolbarFocused {
                    toolbarIndex = (toolbarIndex + direction + toolbarButtons.count) % toolbarButtons.count
                    updateToolbarFocus()
                    showPanel()
                } else {
                    stepSeek(direction)
                }
            }
        case .upArrow:
            if toolPanel == .picture {
                selectedPictureControl = 0
                updatePictureLabels()
            } else if toolPanel == .audio || toolPanel == .subtitles {
                choiceIndex = max(0, choiceIndex - 1)
                renderTrackPanel()
            } else if toolPanel == .none {
                toolbarFocused = false
                updateToolbarFocus()
                toolPanel = .picture
                picturePanel.isHidden = false
                selectedPictureControl = 0
                updatePictureLabels()
                showPanel()
            }
        case .downArrow:
            if toolPanel == .picture {
                selectedPictureControl = (selectedPictureControl + 1) % 2
                updatePictureLabels()
                showPanel()
            } else if toolPanel == .audio || toolPanel == .subtitles {
                choiceIndex = min(max(0, trackChoices.count - 1), choiceIndex + 1)
                renderTrackPanel()
            } else if toolPanel == .none {
                toolbarFocused = true
                updateToolbarFocus()
                showPanel()
            }
        case .select:
            if toolPanel == .picture {
                resetPicture()
                showPanel()
            } else if toolPanel == .audio || toolPanel == .subtitles {
                chooseSelectedTrack()
            } else if toolPanel == .info {
                closeToolPanel()
            } else if toolbarFocused {
                openToolbarSelection()
            } else if targetSeconds != nil {
                commitSeek()
            } else {
                togglePlayback()
            }
        case .playPause:
            if toolPanel == .none { togglePlayback() }
        case .menu:
            if toolPanel != .none {
                closeToolPanel()
            } else if targetSeconds != nil {
                cancelUncommittedScrub()
                hidePlaybackChrome()
            } else if !panel.isHidden || previewIsVisible || toolbarFocused {
                hidePlaybackChrome()
            } else {
                confirmExit()
            }
        default: break
        }
    }

    func remoteEnded(_ key: UIPress.PressType) {
        // Directional click release does NOT commit a seek; repeated clicks
        // add to the same target before the short idle debounce completes.
    }

    @objc private func remoteSwipe(_ recognizer: UISwipeGestureRecognizer) {
        guard recognizer.state == .ended, core != nil, toolPanel == .none else { return }
        toolbarFocused = false
        updateToolbarFocus()
        stepSeek(recognizer.direction == .right ? 1 : -1)
    }

    private func hidePlaybackChrome() {
        hideTimer?.invalidate()
        toolbarFocused = false
        controlsVisible = false
        panel.isHidden = true
        statusLabel.isHidden = true
        filmStrip.alpha = 0
        seekTimeLabel.alpha = 0
        previewHideTimer?.invalidate()
        previewIsVisible = false
        thumbs.cancel()
        updateToolbarFocus()
    }

    private func cancelUncommittedScrub() {
        seekCommitTimer?.invalidate()
        seekCommitTimer = nil
        targetSeconds = nil
        thumbTimer?.invalidate()
        currentPreviewSerial += 1
        refreshLabels()
    }

    private func confirmExit() {
        guard link != nil else { return }
        let alert = UIAlertController(title: "Stop watching?",
            message: "Exit the current video?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Watching", style: .cancel) { [weak self] _ in
            self?.showPanel()
        })
        alert.addAction(UIAlertAction(title: "Exit Video", style: .destructive) { [weak self] _ in
            self?.leavePlayback()
        })
        present(alert, animated: true)
    }

    private func closeToolPanel() {
        toolPanel = .none
        picturePanel.isHidden = true
        trackPanel.isHidden = true
        toolbarFocused = true
        updateToolbarFocus()
        showPanel()
    }

    private func openToolbarSelection() {
        guard core != nil else { return }
        trackRefreshID += 1
        let request = trackRefreshID
        if toolbarIndex == 2 {
            toolPanel = .info
            infoRows = ["Reading file properties…"]
            renderTrackPanel()
            loadMediaInfo(request: request)
        } else {
            toolPanel = toolbarIndex == 0 ? .audio : .subtitles
            trackChoices = []
            choiceIndex = 0
            renderTrackPanel()
            loadTracks(request: request)
        }
        toolbarFocused = false
        updateToolbarFocus()
        showPanel()
    }

    private func renderTrackPanel() {
        picturePanel.isHidden = true
        trackPanel.isHidden = false
        if toolPanel == .info {
            trackTitle.text = "FILE INFORMATION"
            for i in trackLabels.indices {
                trackLabels[i].text = i < infoRows.count ? infoRows[i] : ""
                trackLabels[i].textColor = .white.withAlphaComponent(0.86)
            }
        } else {
            trackTitle.text = toolPanel == .audio ? "AUDIO TRACKS" : "SUBTITLES"
            if trackChoices.isEmpty {
                trackLabels[0].text = "No tracks found (or still loading)…"
                for i in 1..<trackLabels.count { trackLabels[i].text = "" }
            } else {
                let top = max(0, min(choiceIndex - 3, max(0, trackChoices.count - trackLabels.count)))
                for row in trackLabels.indices {
                    let index = top + row
                    if index < trackChoices.count {
                        let track = trackChoices[index]
                        let prefix = choiceIndex == index ? "▶  " : "    "
                        let suffix = track.selected ? "  ✓" : ""
                        trackLabels[row].text = prefix + track.caption + suffix
                        trackLabels[row].textColor = choiceIndex == index ? .white : .lightGray
                    } else { trackLabels[row].text = "" }
                }
            }
        }
    }

    private func chooseSelectedTrack() {
        guard let core, trackChoices.indices.contains(choiceIndex) else { return }
        let choice = trackChoices[choiceIndex]
        let property = toolPanel == .audio ? "aid" : "sid"
        core.setProperty(property, value: choice.id)
        closeToolPanel()
    }

    private func loadTracks(request: Int) {
        guard let core else { return }
        let wanted: TrackKind = toolPanel == .audio ? .audio : .sub
        core.getPropertyAsync("track-list/count") { [weak self, weak core] result in
            guard let self, let core, self.core === core, self.trackRefreshID == request else { return }
            let count = min(96, max(0, Int((try? result.get()) ?? "") ?? 0))
            guard count > 0 else {
                self.trackChoices = wanted == .sub
                    ? [TrackChoice(id: "no", caption: "Off", selected: false)] : []
                self.renderTrackPanel()
                return
            }
            let keys = ["type", "id", "lang", "title", "codec", "selected", "audio-channels"]
            var values = Array(repeating: [String: String](), count: count)
            let group = DispatchGroup()
            for index in 0..<count {
                for key in keys {
                    group.enter()
                    core.getPropertyAsync("track-list/\(index)/\(key)") { result in
                        if case .success(let value) = result, let value {
                            values[index][key] = value
                        }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { [weak self, weak core] in
                guard let self, let core, self.core === core,
                      self.trackRefreshID == request else { return }
                var choices: [TrackChoice] = []
                if wanted == .sub {
                    choices.append(TrackChoice(id: "no", caption: "Off", selected: false))
                }
                var ordinal = 0
                for value in values where value["type"] == wanted.rawValue {
                    ordinal += 1
                    guard let id = value["id"], !id.isEmpty else { continue }
                    let lang = value["lang"]?.isEmpty == false ? value["lang"]! : "Unknown"
                    let title = value["title"] ?? ""
                    let codec = (value["codec"] ?? "").uppercased()
                    let channels = value["audio-channels"] ?? ""
                    let details = [lang, title, codec, channels].filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    choices.append(TrackChoice(id: id, caption: "\(ordinal). \(details)",
                                               selected: value["selected"] == "yes"))
                }
                self.trackChoices = choices
                self.choiceIndex = max(0, choices.firstIndex(where: { $0.selected }) ?? 0)
                self.renderTrackPanel()
            }
        }
    }

    private func loadMediaInfo(request: Int) {
        guard let core else { return }
        let keys: [(String, String)] = [
            ("Video codec", "video-codec"),
            ("Video format", "video-format"),
            ("Width", "video-params/w"),
            ("Height", "video-params/h"),
            ("Frame rate", "container-fps"),
            ("Audio codec", "audio-codec-name"),
            ("Dolby Vision", "current-tracks/video/dolby-vision-profile"),
            ("Video bitrate", "video-bitrate")
        ]
        var values = [String: String]()
        let group = DispatchGroup()
        for (label, property) in keys {
            group.enter()
            core.getPropertyAsync(property) { result in
                if case .success(let value) = result, let value {
                    values[label] = value
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self, weak core] in
            guard let self, let core, self.core === core,
                  self.trackRefreshID == request, self.toolPanel == .info else { return }
            let width = values["Width"] ?? "?"
            let height = values["Height"] ?? "?"
            let fps = Double(values["Frame rate"] ?? "").map { String(format: "%.3f fps", $0) } ?? "Unknown"
            let dv = Int(values["Dolby Vision"] ?? "").map {
                $0 == 7 ? "Profile 7 → 8.1" : ($0 > 0 ? "Profile \($0)" : "No")
            } ?? "Unknown"
            self.infoRows = [
                "Video   " + (values["Video codec"] ?? "Unknown"),
                "Size    " + width + " × " + height,
                "Rate    " + fps,
                "DV      " + dv,
                "Format  " + (values["Video format"] ?? "Unknown"),
                "Audio   " + (values["Audio codec"] ?? "Unknown"),
                "Bitrate " + (values["Video bitrate"] ?? "Unknown") + " bps"
            ]
            self.renderTrackPanel()
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

    private func stepSeek(_ direction: Int) {
        guard core != nil else { return }
        let base = targetSeconds ?? max(0, currentSeconds)
        let bound = totalSeconds > 0 ? totalSeconds : 86_400
        targetSeconds = max(0, min(bound, base + Double(direction) * 15))
        scheduleFrames()
        refreshLabels()
        showPanel()
        seekCommitTimer?.invalidate()
        // Short, consistent delay allows several consecutive remote swipes
        // to accumulate, instead of seeking back to a stale mpv time-pos.
        seekCommitTimer = Timer.scheduledTimer(withTimeInterval: 0.82, repeats: false) { [weak self] _ in
            self?.commitSeek()
        }
    }

    private func commitSeek() {
        seekCommitTimer?.invalidate()
        seekCommitTimer = nil
        guard let seconds = targetSeconds else { return }
        // Keyframe seek decodes substantially faster than +exact on remote MKV.
        // The target remains pinned until the asynchronous seek has been sent.
        core?.command(["seek", String(format: "%.3f", seconds), "absolute"])
        currentSeconds = seconds
        committedSeekTarget = seconds
        committedSeekDate = Date()
        targetSeconds = nil
        // Keep the preview on-screen long enough for remote MKV/4K decode.
        // Cancelling here used to discard every picture before it arrived.
        previewHideTimer?.invalidate()
        previewHideTimer = Timer.scheduledTimer(withTimeInterval: 4.8, repeats: false) { [weak self] _ in
            guard let self, self.targetSeconds == nil else { return }
            self.filmStrip.alpha = 0
            self.seekTimeLabel.alpha = 0
            self.previewIsVisible = false
            self.thumbs.cancel()
            self.currentPreviewSerial += 1
            self.showPanel()
        }
        showPanel()
    }

    private func scheduleFrames() {
        guard targetSeconds != nil else { return }
        filmStrip.alpha = 1
        seekTimeLabel.alpha = 1
        thumbTimer?.invalidate()
        previewHideTimer?.invalidate()
        previewIsVisible = true
        currentPreviewSerial += 1
        let serial = currentPreviewSerial
        // Leave cached images visible while another seek batch is queued.
        thumbTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            self?.loadFrames(serial: serial)
        }
    }

    private func loadFrames(serial: Int) {
        guard let link, let targetSeconds else { return }
        let center = Int(targetSeconds)
        thumbs.cancel()
        for index in [2, 1, 3, 0, 4] {
            let second = max(0, center + (index - 2) * 15)
            thumbs.request(url: link.url, second: second) { [weak self] image in
                guard let self, self.currentPreviewSerial == serial,
                      self.previewIsVisible else { return }
                if let image { self.frameViews[index].image = image }
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
        previewHideTimer?.invalidate()
        previewIsVisible = false
        seekCommitTimer?.invalidate()
        seekCommitTimer = nil
        toolPanel = .none
        toolbarFocused = false
        trackPanel.isHidden = true
        trackRefreshID += 1
        core?.setVisible(false)
        core?.dispose()
        core = nil
        link = nil
        targetSeconds = nil
        committedSeekTarget = nil
        committedSeekDate = nil
        playing = false
        picturePanel.isHidden = true
        statusLabel.isHidden = false
        idleLabel.isHidden = false
        statusLabel.text = "Choose a stream from Nuvio"
        titleLabel.text = ""
        filmStrip.alpha = 0
        seekTimeLabel.alpha = 0
        showPanel()
    }

    private func showPanel() {
        controlsVisible = true
        panel.isHidden = core == nil
        statusLabel.isHidden = core != nil && playing && !waitingForFirstFrame
        updateToolbarFocus()
        hideTimer?.invalidate()
        if core != nil && targetSeconds == nil && toolPanel == .none {
            // Both paused and playing timelines hide after 3 seconds of
            // inactivity. Leaving a menu open intentionally suspends timeout.
            hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                guard let self, self.toolPanel == .none, self.targetSeconds == nil else { return }
                self.hidePlaybackChrome()
            }
        }
    }

    @objc private func refreshClock() {
        totalSeconds = max(0, core?.duration ?? totalSeconds)
        if targetSeconds == nil {
            let actual = max(0, core?.timePos ?? currentSeconds)
            if let pin = committedSeekTarget {
                let aged = Date().timeIntervalSince(committedSeekDate ?? .distantPast) > 3.0
                if abs(actual - pin) <= 3.0 || aged {
                    committedSeekTarget = nil
                    committedSeekDate = nil
                    currentSeconds = actual
                } else {
                    currentSeconds = pin
                }
            } else {
                currentSeconds = actual
            }
        }
        refreshLabels()
    }

    private func refreshLabels() {
        let seconds = targetSeconds ?? currentSeconds
        progress.progress = Float(max(0, min(1, totalSeconds > 0 ? seconds / totalSeconds : 0)))
        seekTimeLabel.text = clockString(seconds) + "  /  " +
            (totalSeconds > 0 ? clockString(totalSeconds) : "--:--")
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
        seekCommitTimer?.invalidate()
        previewHideTimer?.invalidate()
        hideTimer?.invalidate()
        core?.dispose()
    }
}
