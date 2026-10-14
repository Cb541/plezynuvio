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

/// Canvas-drawn transport symbols remain visible on sideloaded tvOS,
/// without depending on UIButton-disabled imagery or SF Symbol fonts.
private final class PlayerToolGlyph: UIView {
    enum Kind { case waveform, subtitles, info }
    let kind: Kind
    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { return nil }
    override func draw(_ rect: CGRect) {
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        context?.translateBy(x: rect.midX - 20, y: rect.midY - 20)
        UIColor.white.setFill()
        UIColor.white.setStroke()
        switch kind {
        case .waveform:
            for (index, height) in [12, 22, 32, 22, 12].enumerated() {
                let h = CGFloat(height)
                UIBezierPath(roundedRect: CGRect(x: CGFloat(4 + index * 7),
                    y: 20 - h / 2, width: 4.5, height: h),
                    cornerRadius: 2.25).fill()
            }
        case .subtitles:
            let outline = UIBezierPath(roundedRect: CGRect(x: 3, y: 7, width: 34, height: 26),
                                       cornerRadius: 4)
            outline.lineWidth = 2.8
            outline.stroke()
            let lines = UIBezierPath()
            lines.move(to: CGPoint(x: 9, y: 18))
            lines.addLine(to: CGPoint(x: 18, y: 18))
            lines.move(to: CGPoint(x: 23, y: 18))
            lines.addLine(to: CGPoint(x: 31, y: 18))
            lines.move(to: CGPoint(x: 9, y: 25))
            lines.addLine(to: CGPoint(x: 22, y: 25))
            lines.move(to: CGPoint(x: 27, y: 25))
            lines.addLine(to: CGPoint(x: 31, y: 25))
            lines.lineWidth = 2.8
            lines.stroke()
        case .info:
            let ring = UIBezierPath(ovalIn: CGRect(x: 4, y: 4, width: 32, height: 32))
            ring.lineWidth = 2.8
            ring.stroke()
            UIBezierPath(ovalIn: CGRect(x: 18, y: 11, width: 4, height: 4)).fill()
            UIBezierPath(roundedRect: CGRect(x: 18.3, y: 19, width: 3.5, height: 11),
                         cornerRadius: 1.7).fill()
        }
        context?.restoreGState()
    }
}

/// Native TV player. The existing AVSampleBufferDisplayLayer/libmpv core owns
/// hardware decoding, DV P7->P8.1 conversion and matching the HDMI output.
/// UIView/CALayer transforms provide zoom + independent vertical stretch
/// without forcing DV content down mpv's tone-mapped video-zoom path.
final class NativePlayerViewController: UIViewController, MpvPlayerDelegate, UIGestureRecognizerDelegate {
    private var core: MpvPlayerCore?
    private let thumbs = SeekFrameService()
    private var pendingLink: NativeStreamLink?
    private var hasAppeared = false
    private var playbackGeneration = 0
    private var isPreparingPlayback = false
    private var waitingForFirstFrame = false
    private var displayNegotiationPending = false
    private var firstFrameTimeout: DispatchWorkItem?
    private var subtitleURLToLoad: URL?
    private var subtitleAlreadyRequested = false
    private var link: NativeStreamLink?
    private var clock: Timer?
    private var repeatTimer: Timer?
    private var thumbTimer: Timer?
    private var hideTimer: Timer?
    private var heldDirection = 0
    private var holdTickCount = 0
    private var isTouchScrubbing = false
    // Reuse cached images during touchpad motion, avoiding continuous
    // competing remote HEVC decodes while tvOS displays DV video.
    private var touchpadPreviewMode = false
    // Limit preview requests to roughly one per second during active
    // scrubbing. Unlike cache-only motion, this produces real live images;
    // unlike unrestricted per-pan decoding, it bounds decoder pressure.
    private var lastLiveTouchpadRequest = Date.distantPast
    private var lastBackgroundPreviewAttempt = Date.distantPast
    // Locked transport is engaged by holding the left/right edge once.
    // Release keeps it running; further clicks cycle speed and direction.
    private var lockedSeekDirection = 0
    private var lockedSpeedIndex = 0
    private let lockedSeekSpeeds: [Double] = [8, 20, 50, 110, 240]
    private let lockedClickSteps: [Double] = [20, 50, 120, 240, 480]
    // Freeze the actual movie while an independent windowed preview moves.
    // Restore its earlier play state only when the target is committed/cancelled.
    private var resumeAfterLockedSeek = false
    private var holdActivationTimer: Timer?
    private var explicitChromeHidden = false

    private var targetSeconds: Double?
    private var currentSeconds: Double = 0
    private var totalSeconds: Double = 0
    private var zoom: CGFloat = 1
    private var verticalStretch: CGFloat = 1
    private var panOriginSeconds: Double = 0
    // Detect actual turning of the touchpad pan path. A regular left/right
    // swipe has a steady heading; tracing a circle rotates that heading.
    private var panLastTranslation: CGPoint = .zero
    private var panLastHeading: Double?
    private var panTravelPoints: Double = 0
    private var panTurnRadians: Double = 0
    private var circularSeekActive = false
    private var panStartedWhilePlaying = false
    private var circularSeekOrigin = 0.0
    private var circularTurnOrigin = 0.0
    private var hasSelectedPreferredAudio = false
    private var currentPreviewSerial = 0
    private var lastPreviewRequestedBucket: Int?
    private var lastPreviewImageSecond: Int?
    private var seekCommitOperationID = 0
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
    private var toolbarButtons: [PlayerToolGlyph] = []
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
    private let previewLoadingLabel = UILabel()
    private let previewStatusLabel = UILabel()

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
        // Pan handles paused scrub; swipe gestures handle silent 15-second
        // navigation while playing (and a larger thumbnail scrub if paused).
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(touchScrub(_:)))
        panGesture.cancelsTouchesInView = false
        panGesture.delegate = self
        remote.addGestureRecognizer(panGesture)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(remoteSwipe(_:)))
            swipe.direction = direction
            swipe.cancelsTouchesInView = false
            swipe.delegate = self
            // Do not also deliver a paused swipe after a pan scrub.
            swipe.require(toFail: panGesture)
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
        heldDirection = 0
        lockedSeekDirection = 0
        lockedSpeedIndex = 0
        resumeAfterLockedSeek = false
        holdActivationTimer?.invalidate()
        holdActivationTimer = nil
        holdTickCount = 0
        isTouchScrubbing = false
        touchpadPreviewMode = false
        lastLiveTouchpadRequest = .distantPast
        lastBackgroundPreviewAttempt = .distantPast
        circularSeekActive = false
        panStartedWhilePlaying = false
        hasSelectedPreferredAudio = false
        seekCommitOperationID += 1
        displayNegotiationPending = false
        lastPreviewRequestedBucket = nil
        lastPreviewImageSecond = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        waitingForFirstFrame = true
        subtitleAlreadyRequested = false
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        playbackGeneration += 1
        let generation = playbackGeneration
        PlayerStartupDiagnostics.mark("handoff-received")

        // New stream gets its own persistent disk-cache namespace.
        // The previous file's thumbnails remain available on disk.
        thumbs.prepare(url: media.url)
        previewHideTimer?.invalidate()
        previewIsVisible = false
        filmStrip.alpha = 0
        seekTimeLabel.alpha = 0
        link = media
        frameViews.first?.image = nil
        previewStatusLabel.isHidden = true
        previewLoadingLabel.isHidden = true
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
        displayNegotiationPending = true
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
                    self.displayNegotiationPending = false
                    self.playing = true
                    PlayerStartupDiagnostics.mark("mpv-unpaused-after-display-switch")
                    // This is a startup breadcrumb, not a permanent error.
                    // Once playback settles, clear it so a later tvOS
                    // termination is not falsely blamed on the HDMI switch.
                    let startedCore = core
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self, weak startedCore] in
                        guard let self, let startedCore,
                              self.core === startedCore,
                              self.playbackGeneration == generation,
                              !self.waitingForFirstFrame else { return }
                        PlayerStartupDiagnostics.clear()
                    }
                    self.statusLabel.text = ""
                    self.showPanel()
                    // Defer subtitles until after the video is running.
                    self.attachInitialSubtitleIfAvailable()
                    self.schedulePreferredEnglishAudioSelection()
                    self.showPanel()
                case .failure(let error):
                    self.displayNegotiationPending = false
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
                // MPV only emits playback-restart after it has decoded at
                // the new position. It is the authoritative point to release
                // our temporary seek pin, even with a nearby keyframe seek.
                if let destination = self.committedSeekTarget,
                   let measured = (data?["positionSeconds"] as? NSNumber)?.doubleValue,
                   measured.isFinite,
                   abs(measured - destination) <= 4.5 {
                    // Multiple 15s clicks can queue several MPV seeks. Do
                    // not release the target pin for an older restart event;
                    // that's what made later clicks jump toward 0 again.
                    self.committedSeekTarget = nil
                    self.committedSeekDate = nil
                    self.currentSeconds = max(0, measured)
                    self.refreshLabels()
                }
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
                // Real mpv END_FILE is different from tvOS terminating the
                // app. Surface the reason even if this was mid-movie, rather
                // than displaying only the stale startup breadcrumb.
                let reason = (data?["reason"] as? NSNumber)?.intValue ?? -1
                let message = data?["message"] as? String
                if self.previewIsVisible || self.targetSeconds != nil {
                    PlayerStartupDiagnostics.mark("mpv-end-file-during-preview-reason-\(reason)")
                    self.statusLabel.text = message.map { "Playback stopped: \($0)" } ??
                        "Playback stopped during seeking (mpv reason \(reason))"
                    self.repeatTimer?.invalidate()
                    self.repeatTimer = nil
                    self.lockedSeekDirection = 0
                    self.targetSeconds = nil
                    self.stopShowingThumbnail()
                    self.playing = false
                    self.showPanel()
                } else if self.currentSeconds < 2 {
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
        currentLabel.translatesAutoresizingMaskIntoConstraints = false
        endLabel.translatesAutoresizingMaskIntoConstraints = false
        currentLabel.textColor = .white
        endLabel.textColor = .white
        currentLabel.text = "0:00"
        endLabel.text = "--:--"
        currentLabel.font = .monospacedDigitSystemFont(ofSize: 21, weight: .medium)
        endLabel.font = .monospacedDigitSystemFont(ofSize: 21, weight: .medium)
        currentLabel.textAlignment = .left
        endLabel.textAlignment = .right
        panel.addSubview(currentLabel)
        panel.addSubview(endLabel)
        progress.progressTintColor = .white
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.35)
        progress.layer.cornerRadius = 2
        progress.clipsToBounds = true
        panel.addSubview(progress)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.axis = .horizontal
        toolbar.alignment = .center
        toolbar.spacing = 11
        toolbar.distribution = .fill
        // Text-based controls are intentionally used rather than SF Symbols:
        // the assetless sideloaded tvOS app returned nil for some of the
        // requested system icons, leaving three invisible buttons.
        // Circles use genuine Liquid Glass; each symbol is drawn with a
        // vector path so tvOS cannot silently omit the icon.
        for (name, kind) in [
            ("Audio", PlayerToolGlyph.Kind.waveform),
            ("Subtitles", .subtitles),
            ("Info", .info)
        ] {
            let circle = UIView()
            circle.translatesAutoresizingMaskIntoConstraints = false
            circle.layer.cornerRadius = 29
            circle.clipsToBounds = true
            circle.isUserInteractionEnabled = false
            addGlassBackdrop(to: circle, radius: 29)
            let glyph = PlayerToolGlyph(kind: kind)
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyph.accessibilityLabel = name
            circle.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
                glyph.widthAnchor.constraint(equalToConstant: 40),
                glyph.heightAnchor.constraint(equalToConstant: 40),
                circle.widthAnchor.constraint(equalToConstant: 58),
                circle.heightAnchor.constraint(equalToConstant: 58)
            ])
            toolbarButtons.append(glyph)
            toolbar.addArrangedSubview(circle)
        }
        panel.addSubview(toolbar)

        filmStrip.translatesAutoresizingMaskIntoConstraints = false
        // Infuse-style SINGLE thumbnail above the scrub bar, not a
        // five-picture strip. Keep the previous decoded frame while seeking.
        filmStrip.axis = .horizontal
        filmStrip.spacing = 0
        filmStrip.distribution = .fill
        filmStrip.alignment = .fill
        filmStrip.isUserInteractionEnabled = false
        filmStrip.clipsToBounds = true
        view.addSubview(filmStrip)
        let preview = UIImageView()
        preview.contentMode = .scaleAspectFill
        // Floating, independently decoded seek thumbnail, 20% larger
        // than the original 360 × 204 pt preview. Never cover the movie.
        // Aspect fill crops to the preview window; the FFmpeg decoder
        // also trims source-encoded black letterboxing.
        preview.backgroundColor = .black
        preview.layer.cornerRadius = 16
        preview.layer.borderColor = UIColor.white.withAlphaComponent(0.38).cgColor
        preview.layer.borderWidth = 1
        preview.clipsToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        frameViews.append(preview)
        filmStrip.addArrangedSubview(preview)

        previewLoadingLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLoadingLabel.text = ""
        previewLoadingLabel.font = .systemFont(ofSize: 18, weight: .medium)
        previewLoadingLabel.textColor = .white.withAlphaComponent(0.78)
        previewLoadingLabel.textAlignment = .center
        previewLoadingLabel.isHidden = true
        preview.addSubview(previewLoadingLabel)
        NSLayoutConstraint.activate([
            previewLoadingLabel.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 6),
            previewLoadingLabel.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -6),
            previewLoadingLabel.centerYAnchor.constraint(equalTo: preview.centerYAnchor)
        ])
        filmStrip.alpha = 0
        seekTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        seekTimeLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        seekTimeLabel.textColor = .white
        seekTimeLabel.textAlignment = .center
        seekTimeLabel.alpha = 0
        view.addSubview(seekTimeLabel)
        // A separate status label remains visible while the windowed
        // thumbnail stays hidden until FFmpeg produces a real frame.
        previewStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        previewStatusLabel.text = "Preparing thumbnail…"
        previewStatusLabel.textAlignment = .center
        previewStatusLabel.textColor = .white
        previewStatusLabel.font = .systemFont(ofSize: 21, weight: .medium)
        previewStatusLabel.layer.shadowColor = UIColor.black.cgColor
        previewStatusLabel.layer.shadowRadius = 5
        previewStatusLabel.layer.shadowOpacity = 0.85
        previewStatusLabel.isHidden = true
        view.addSubview(previewStatusLabel)

        // Retain the proven picture-controls panel.
        picturePanel.translatesAutoresizingMaskIntoConstraints = false
        picturePanel.backgroundColor = .clear
        picturePanel.layer.cornerRadius = 18
        picturePanel.isHidden = true
        picturePanel.isUserInteractionEnabled = false
        view.addSubview(picturePanel)
        addGlassBackdrop(to: picturePanel, radius: 18)
        for label in [zoomLabel, stretchLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
            label.textColor = .white
            picturePanel.addSubview(label)
        }
        updatePictureLabels()

        // Audio/subtitle/info menu shares the zoom panel's simple vertical layout.
        trackPanel.translatesAutoresizingMaskIntoConstraints = false
        trackPanel.backgroundColor = .clear
        trackPanel.layer.cornerRadius = 18
        trackPanel.isUserInteractionEnabled = false
        trackPanel.isHidden = true
        view.addSubview(trackPanel)
        addGlassBackdrop(to: trackPanel, radius: 18)
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
            panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -2),
            panel.heightAnchor.constraint(equalToConstant: 54),
            currentLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 4),
            currentLabel.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            currentLabel.widthAnchor.constraint(equalToConstant: 105),
            progress.leadingAnchor.constraint(equalTo: currentLabel.trailingAnchor, constant: 12),
            progress.trailingAnchor.constraint(equalTo: endLabel.leadingAnchor, constant: -12),
            progress.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            progress.heightAnchor.constraint(equalToConstant: 5),
            endLabel.trailingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: -17),
            endLabel.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            endLabel.widthAnchor.constraint(equalToConstant: 105),
            toolbar.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            toolbar.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            filmStrip.widthAnchor.constraint(equalToConstant: 432),
            filmStrip.heightAnchor.constraint(equalToConstant: 245),
            filmStrip.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // Exactly one quarter down from the TOP of the video. Not
            // one quarter above the bottom: comfortable when reclining.
            NSLayoutConstraint(item: filmStrip, attribute: .centerY,
                relatedBy: .equal, toItem: view, attribute: .bottom,
                multiplier: 0.25, constant: 0),
            seekTimeLabel.centerXAnchor.constraint(equalTo: filmStrip.centerXAnchor),
            seekTimeLabel.bottomAnchor.constraint(equalTo: filmStrip.topAnchor, constant: -10),
            previewStatusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            previewStatusLabel.bottomAnchor.constraint(equalTo: seekTimeLabel.topAnchor, constant: -16),
            previewStatusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.9),
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
        // The floating preview remains beneath the progress/time labels,
        // tools and picture menus. It's non-interactive, so the Siri Remote
        // surface beneath it continues to receive presses and gestures.
        view.bringSubviewToFront(panel)
        view.bringSubviewToFront(seekTimeLabel)
        view.bringSubviewToFront(previewStatusLabel)
        view.bringSubviewToFront(picturePanel)
        view.bringSubviewToFront(trackPanel)
        view.bringSubviewToFront(statusLabel)
        panel.isHidden = true
        updateToolbarFocus()
    }

    private func addGlassBackdrop(to target: UIView, radius: CGFloat) {
        let effect: UIVisualEffect
        if #available(tvOS 26.0, *) {
            effect = UIGlassEffect(style: .regular)
        } else {
            effect = UIBlurEffect(style: .dark)
        }
        let background = UIVisualEffectView(effect: effect)
        background.translatesAutoresizingMaskIntoConstraints = false
        background.isUserInteractionEnabled = false
        background.layer.cornerRadius = radius
        background.clipsToBounds = true
        target.insertSubview(background, at: 0)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: target.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: target.trailingAnchor),
            background.topAnchor.constraint(equalTo: target.topAnchor),
            background.bottomAnchor.constraint(equalTo: target.bottomAnchor)
        ])
    }

    private func updateToolbarFocus() {
        for (index, icon) in toolbarButtons.enumerated() {
            let selected = toolbarFocused && toolPanel == .none && index == toolbarIndex
            icon.superview?.layer.borderWidth = selected ? 2.4 : 0
            icon.superview?.layer.borderColor = UIColor.white.withAlphaComponent(0.95).cgColor
            icon.superview?.backgroundColor = selected
                ? UIColor.white.withAlphaComponent(0.17)
                : .clear
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
                } else if !isTouchScrubbing {
                    beginDirectionalSeek(direction)
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
                // A preview is confirmed only by the center button.
                if previewIsVisible || targetSeconds != nil { showPanel(); return }
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
                if previewIsVisible || targetSeconds != nil { showPanel(); return }
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
            } else if lockedSeekDirection != 0 {
                finishLockedSeek(commit: true)
            } else if targetSeconds != nil {
                // Preserve whichever playback state existed before seeking.
                let shouldResume = resumeAfterLockedSeek
                resumeAfterLockedSeek = false
                commitSeek(resumeAfter: shouldResume)
            } else {
                togglePlayback()
            }
        case .playPause:
            if toolPanel == .none {
                if previewIsVisible || targetSeconds != nil || lockedSeekDirection != 0 {
                    // Only the center Select button confirms preview seeking.
                    // Play/Pause must not silently commit or dismiss it.
                    showPanel()
                } else {
                    togglePlayback()
                }
            }
        case .menu:
            if toolPanel != .none {
                closeToolPanel()
            } else if lockedSeekDirection != 0 {
                finishLockedSeek(commit: false)
                hidePlaybackChrome()
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
        guard key == .leftArrow || key == .rightArrow else { return }
        let direction = key == .rightArrow ? 1 : -1
        guard heldDirection == direction else { return }
        heldDirection = 0
        holdActivationTimer?.invalidate()
        holdActivationTimer = nil
        // A real hold locks the transport even after release. The next
        // left/right click changes speed without closing the thumbnail.
        if lockedSeekDirection == 0 {
            silentSkip(direction)
        }
    }

    private func beginDirectionalSeek(_ direction: Int) {
        // HDMI/first-frame startup must complete before seeking. Otherwise
        // heavy preview decode competes with the initial display transition.
        guard core != nil, !waitingForFirstFrame, !displayNegotiationPending,
              !isPreparingPlayback, heldDirection == 0 else { return }
        // Assign on press-began even in a locked transport. UIKit may
        // resend began callbacks for a held button; don't accelerate
        // multiple times from one physical press.
        heldDirection = direction
        if lockedSeekDirection != 0 {
            if direction == lockedSeekDirection {
                lockedSpeedIndex = min(lockedSeekSpeeds.count - 1, lockedSpeedIndex + 1)
            } else {
                lockedSeekDirection = direction
                lockedSpeedIndex = 0
            }
            // Each click moves the preview immediately, as well as raising
            // the locked fast-forward/rewind rate.
            let base = targetSeconds ?? currentSeconds
            let bound = totalSeconds > 0 ? totalSeconds : 86_400
            targetSeconds = max(0, min(bound,
                base + Double(direction) * lockedClickSteps[lockedSpeedIndex]))
            scheduleFrames()
            refreshLabels()
            showPanel()
            return
        }
        holdActivationTimer?.invalidate()
        holdActivationTimer = Timer.scheduledTimer(withTimeInterval: 0.47, repeats: false) {
            [weak self] _ in
            guard let self, self.heldDirection == direction, self.core != nil else { return }
            self.engageLockedSeek(direction)
        }
    }

    private func engageLockedSeek(_ direction: Int) {
        guard lockedSeekDirection == 0, heldDirection == direction,
              core != nil, !waitingForFirstFrame else { return }
        resumeAfterLockedSeek = playing
        if playing {
            // Hold the last real video frame. No native full-screen seeking
            // or second moving timeline while the preview window updates.
            core?.setProperty("pause", value: "yes")
            playing = false
        }
        lockedSeekDirection = direction
        lockedSpeedIndex = 0
        holdActivationTimer?.invalidate()
        holdActivationTimer = nil
        seekCommitTimer?.invalidate()
        seekCommitTimer = nil
        // The movie stays at its current playback position while the
        // independent preview playhead advances. One seek commits on Select.
        targetSeconds = committedSeekTarget ?? currentSeconds
        advanceLockedSeek(elapsed: 0.4)
        hideTimer?.invalidate()
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) {
            [weak self] _ in self?.advanceLockedSeek(elapsed: 0.35)
        }
    }

    private func advanceLockedSeek(elapsed: Double) {
        guard lockedSeekDirection != 0 else { return }
        let direction = lockedSeekDirection
        let base = targetSeconds ?? currentSeconds
        let bound = totalSeconds > 0 ? totalSeconds : 86_400
        targetSeconds = max(0, min(bound,
            base + Double(direction) * elapsed * lockedSeekSpeeds[lockedSpeedIndex]))
        scheduleFrames()
        refreshLabels()
        showPanel()
    }

    private func finishLockedSeek(commit: Bool, resumeWhenCommitted: Bool? = nil) {
        repeatTimer?.invalidate()
        repeatTimer = nil
        holdActivationTimer?.invalidate()
        holdActivationTimer = nil
        heldDirection = 0
        lockedSeekDirection = 0
        lockedSpeedIndex = 0
        let restorePlayback = resumeAfterLockedSeek
        resumeAfterLockedSeek = false
        if commit {
            commitSeek(resumeAfter: resumeWhenCommitted ?? restorePlayback)
        } else {
            cancelUncommittedScrub()
            if restorePlayback {
                core?.setProperty("pause", value: "no")
                playing = true
            }
        }
        stopShowingThumbnail()
        showPanel()
    }

    private func silentSkip(_ direction: Int) {
        guard let core, !waitingForFirstFrame, !displayNegotiationPending else { return }
        // Crucially: NO progress bar and NO thumbnails for a quick click
        // or swipe, whether the film is currently playing or paused.
        let base = committedSeekTarget ?? max(0, core.timePos, currentSeconds)
        let maxTime = totalSeconds > 0 ? totalSeconds : 86_400
        let dest = max(0, min(maxTime, base + 15.0 * Double(direction)))
        currentSeconds = dest
        committedSeekTarget = dest
        committedSeekDate = Date()
        core.command(["seek", String(format: "%.3f", dest), "absolute"])
        refreshLabels()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard core != nil, toolPanel == .none, !toolbarFocused,
              !waitingForFirstFrame, !displayNegotiationPending,
              !isPreparingPlayback else { return false }
        // A pan can begin while playing as a circular-seek candidate.
        // A normal straight swipe still performs the regular silent skip.
        if gestureRecognizer is UIPanGestureRecognizer { return true }
        if gestureRecognizer is UISwipeGestureRecognizer {
            return lockedSeekDirection == 0 && !previewIsVisible
        }
        return true
    }

    @objc private func remoteSwipe(_ recognizer: UISwipeGestureRecognizer) {
        guard recognizer.state == .ended, core != nil,
              toolPanel == .none, !toolbarFocused,
              !waitingForFirstFrame, !displayNegotiationPending,
              lockedSeekDirection == 0, !isTouchScrubbing else { return }
        let direction = recognizer.direction == .right ? 1 : -1
        if playing {
            silentSkip(direction)
        } else {
            // Touchpad preview is sticky until Select, even after a flick.
            let base = targetSeconds ?? currentSeconds
            let bound = totalSeconds > 0 ? totalSeconds : 86_400
            targetSeconds = max(0, min(bound,
                base + Double(direction) * 15.0))
            scheduleFrames()
            refreshLabels()
            showPanel()
        }
    }

    @objc private func touchScrub(_ gesture: UIPanGestureRecognizer) {
        guard core != nil, toolPanel == .none, !toolbarFocused,
              !waitingForFirstFrame, !displayNegotiationPending,
              !isPreparingPlayback else { return }
        switch gesture.state {
        case .began:
            guard heldDirection == 0 else { return }
            seekCommitOperationID += 1
            isTouchScrubbing = true
            // A new pan cancels any outstanding remote preview decode.
            thumbTimer?.invalidate()
            thumbTimer = nil
            thumbs.cancel()
            currentPreviewSerial += 1
            lastPreviewRequestedBucket = nil
            lastLiveTouchpadRequest = .distantPast
            panLastTranslation = .zero
            panLastHeading = nil
            panTravelPoints = 0
            panTurnRadians = 0
            circularSeekActive = false
            seekCommitTimer?.invalidate()
            seekCommitTimer = nil

            if lockedSeekDirection != 0 {
                // Enter circular/linear touch browsing from a locked FF/RW
                // without losing its original resume-after-commit intent.
                repeatTimer?.invalidate()
                repeatTimer = nil
                lockedSeekDirection = 0
                lockedSpeedIndex = 0
            }
            panStartedWhilePlaying = playing && targetSeconds == nil
            if !panStartedWhilePlaying {
                touchpadPreviewMode = true
                panOriginSeconds = targetSeconds ?? currentSeconds
                targetSeconds = panOriginSeconds
                PlayerStartupDiagnostics.mark("touchpad-preview-active")
                scheduleFrames()
                refreshLabels()
                showPanel()
            }
        case .changed:
            guard isTouchScrubbing else { return }
            let translation = gesture.translation(in: remote)
            let deltaX = Double(translation.x - panLastTranslation.x)
            let deltaY = Double(translation.y - panLastTranslation.y)
            panLastTranslation = translation
            let length = hypot(deltaX, deltaY)
            if length >= 2.0 {
                let heading = atan2(deltaY, deltaX)
                if let previous = panLastHeading {
                    var turn = heading - previous
                    if turn > .pi { turn -= 2 * .pi }
                    if turn < -.pi { turn += 2 * .pi }
                    // Ignore implausible jumps produced by sparse UIKit
                    // touch updates instead of mistaking them for a circle.
                    if abs(turn) < 1.1 { panTurnRadians += turn }
                }
                panLastHeading = heading
                panTravelPoints += length
            }
            let bound = totalSeconds > 0 ? totalSeconds : 86_400
            if !circularSeekActive &&
                panTravelPoints > 34 && abs(panTurnRadians) > 0.85 {
                circularSeekActive = true
                if panStartedWhilePlaying {
                    // A straight swipe skips silently. Only after genuine
                    // curvature do we freeze video and enter thumbnail mode.
                    panStartedWhilePlaying = false
                    touchpadPreviewMode = true
                    resumeAfterLockedSeek = true
                    core?.setProperty("pause", value: "yes")
                    playing = false
                    targetSeconds = committedSeekTarget ?? currentSeconds
                    PlayerStartupDiagnostics.mark("touchpad-circular-preview")
                }
                circularSeekOrigin = targetSeconds ?? currentSeconds
                circularTurnOrigin = panTurnRadians
            }
            if circularSeekActive {
                // Fine control: a full rotation moves 24 seconds instead
                // of 90-600 seconds. Clockwise adds; counterclockwise subtracts.
                let turnSeconds = 24.0
                let revolutions = (panTurnRadians - circularTurnOrigin) / (2.0 * .pi)
                targetSeconds = max(0, min(bound,
                    circularSeekOrigin + revolutions * turnSeconds))
            } else if !panStartedWhilePlaying {
                // Preserve the existing, gentle straight-line scrubbing.
                let sensitivity = max(0.08, min(0.24, bound / 48_000.0))
                targetSeconds = max(0, min(bound,
                    panOriginSeconds + Double(translation.x) * sensitivity))
            }
            if !panStartedWhilePlaying {
                scheduleFrames()
                refreshLabels()
                showPanel()
            }
        case .ended:
            guard isTouchScrubbing else { return }
            isTouchScrubbing = false
            if panStartedWhilePlaying {
                // A normal straight flick keeps the previous 15-second
                // no-thumbnail seek behavior while the video is running.
                let translation = gesture.translation(in: remote)
                if abs(translation.x) >= 35 &&
                    abs(translation.x) > abs(translation.y) * 1.2 {
                    silentSkip(translation.x > 0 ? 1 : -1)
                }
                panStartedWhilePlaying = false
                return
            }
            // Release NEVER commits or dismisses a seek preview.
            // Trigger the latest selected frame rather than waiting for
            // a live-motion throttle timer after the finger lifts.
            thumbTimer?.invalidate()
            thumbTimer = nil
            scheduleFrames()
            refreshLabels()
            showPanel()
        case .cancelled, .failed:
            guard isTouchScrubbing else { return }
            isTouchScrubbing = false
            panStartedWhilePlaying = false
            // A cancelled gesture does not silently commit; Select remains
            // the only way to accept the indicated target.
            if targetSeconds != nil {
                scheduleFrames()
                showPanel()
            }
        default: break
        }
    }

    private func hidePlaybackChrome() {
        hideTimer?.invalidate()
        toolbarFocused = false
        controlsVisible = false
        panel.isHidden = true
        statusLabel.isHidden = true
        stopShowingThumbnail()
        updateToolbarFocus()
    }

    private func cancelUncommittedScrub() {
        seekCommitTimer?.invalidate()
        seekCommitTimer = nil
        targetSeconds = nil
        circularSeekActive = false
        panStartedWhilePlaying = false
        let shouldResume = resumeAfterLockedSeek
        resumeAfterLockedSeek = false
        stopShowingThumbnail()
        PlayerStartupDiagnostics.clear()
        if shouldResume {
            core?.setProperty("pause", value: "no")
            playing = true
        }
        refreshLabels()
    }

    private func stopShowingThumbnail() {
        touchpadPreviewMode = false
        thumbTimer?.invalidate()
        thumbTimer = nil
        previewHideTimer?.invalidate()
        previewHideTimer = nil
        previewIsVisible = false
        filmStrip.alpha = 0
        seekTimeLabel.alpha = 0
        previewLoadingLabel.isHidden = true
        previewStatusLabel.isHidden = true
        frameViews.first?.image = nil
        lastPreviewRequestedBucket = nil
        lastPreviewImageSecond = nil
        thumbs.cancel()
        currentPreviewSerial += 1
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
        if toolPanel == .audio { hasSelectedPreferredAudio = true }
        core.setProperty(property, value: choice.id)
        closeToolPanel()
    }

    // Select only once per opened file, after the HDMI startup gate finishes.
    // Keep manual selection authoritative; don't override a later user choice.
    private func schedulePreferredEnglishAudioSelection() {
        guard !hasSelectedPreferredAudio, let audioCore = core else { return }
        let generation = playbackGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak audioCore] in
            guard let self, let audioCore, self.core === audioCore,
                  self.playbackGeneration == generation,
                  !self.hasSelectedPreferredAudio else { return }
            audioCore.getPropertyAsync("track-list/count") { [weak self, weak audioCore] result in
                guard let self, let audioCore, self.core === audioCore,
                      self.playbackGeneration == generation,
                      !self.hasSelectedPreferredAudio else { return }
                let count = min(96, max(0, Int((try? result.get()) ?? "") ?? 0))
                guard count > 0 else { return }
                let keys = ["type", "id", "lang", "title", "codec", "audio-channels"]
                var tracks = Array(repeating: [String: String](), count: count)
                let group = DispatchGroup()
                for index in 0..<count {
                    for key in keys {
                        group.enter()
                        audioCore.getPropertyAsync("track-list/\(index)/\(key)") { result in
                            if case .success(let value) = result, let value {
                                tracks[index][key] = value
                            }
                            group.leave()
                        }
                    }
                }
                group.notify(queue: .main) { [weak self, weak audioCore] in
                    guard let self, let audioCore, self.core === audioCore,
                          self.playbackGeneration == generation,
                          !self.hasSelectedPreferredAudio else { return }
                    var bestID: String?
                    var bestScore = Int.min
                    for track in tracks where track["type"] == "audio" {
                        guard let id = track["id"], !id.isEmpty else { continue }
                        let language = (track["lang"] ?? "").trimmingCharacters(
                            in: .whitespacesAndNewlines).lowercased()
                        let title = (track["title"] ?? "").lowercased()
                        let english = language == "en" || language == "eng" ||
                            language == "english" || language.hasPrefix("en-") ||
                            language.hasPrefix("en_") || title.contains("english")
                        guard english else { continue }
                        let codec = (track["codec"] ?? "").lowercased()
                        let channelText = ((track["audio-channels"] ?? "") + " " + title).lowercased()
                        let surround51 = channelText.contains("5.1") ||
                            channelText.contains("6 channels") ||
                            channelText.contains("6ch") ||
                            channelText.contains("5.1(side)")
                        let trueHD = codec.contains("truehd") || title.contains("truehd") ||
                            title.contains("true hd")
                        let commentary = title.contains("commentary") ||
                            title.contains("audio description") ||
                            title.contains("descriptive") || title.contains("director")
                        // English 5.1 > English TrueHD > remaining English.
                        // Among 5.1 tracks prefer lossless TrueHD; avoid commentary.
                        let score = (surround51 ? 300 : (trueHD ? 200 : 100)) +
                            (surround51 && trueHD ? 20 : 0) -
                            (commentary ? 500 : 0)
                        if score > bestScore {
                            bestScore = score
                            bestID = id
                        }
                    }
                    self.hasSelectedPreferredAudio = true
                    // With no English audio, preserve the source's existing default.
                    if let bestID {
                        audioCore.setProperty("aid", value: bestID)
                    }
                }
            }
        }
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

    private func stepSeek(_ direction: Int, commitAfterIdle: Bool) {
        guard core != nil else { return }
        let base = targetSeconds ?? max(0, currentSeconds)
        let bound = totalSeconds > 0 ? totalSeconds : 86_400
        targetSeconds = max(0, min(bound, base + Double(direction) * 15))
        scheduleFrames()
        refreshLabels()
        showPanel()
        seekCommitTimer?.invalidate()
        seekCommitTimer = nil
        if commitAfterIdle {
            seekCommitTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                self?.commitSeek()
            }
        }
    }

    private func commitSeek(resumeAfter: Bool = false, retainPreview: Bool = false) {
        seekCommitTimer?.invalidate()
        seekCommitTimer = nil
        guard let seconds = targetSeconds, let seekCore = core else { return }

        currentSeconds = seconds
        committedSeekTarget = seconds
        committedSeekDate = Date()
        targetSeconds = nil
        circularSeekActive = false
        panStartedWhilePlaying = false
        seekCommitOperationID += 1
        let operation = seekCommitOperationID

        // Stop independent FFmpeg reads before making the main hardware
        // decoder seek. tvOS was sometimes terminating during overlapping
        // touchpad-preview decode and mpv seek/display recovery.
        thumbTimer?.invalidate()
        thumbTimer = nil
        thumbs.cancel()
        if retainPreview && frameViews.first?.image != nil {
            // Keep only the already decoded still briefly while the main
            // player lands at the target. Do not decode more background frames.
            previewHideTimer?.invalidate()
            previewHideTimer = Timer.scheduledTimer(withTimeInterval: 1.1,
                repeats: false) { [weak self] _ in
                self?.stopShowingThumbnail()
            }
        } else {
            stopShowingThumbnail()
        }
        if retainPreview {
            PlayerStartupDiagnostics.mark("touchpad-seek-commit")
        }
        showPanel()

        // Never overlap an FFmpeg thumbnail decode with the main mpv seek.
        // The previous fixed 180ms grace period was insufficient for 4K
        // HEVC, which can keep CPU and decoder buffers busy for seconds.
        // Serial cancellation also releases the thumbnail demux/codec RAM.
        thumbs.cancelAndDrain { [weak self, weak seekCore] in
            guard let self, let seekCore, self.core === seekCore,
                  operation == self.seekCommitOperationID else { return }
            seekCore.commandAsync(["seek", String(format: "%.3f", seconds), "absolute"]) {
                [weak self, weak seekCore] result in
                guard let self, let seekCore, self.core === seekCore,
                      operation == self.seekCommitOperationID else { return }
                if case .failure = result {
                    self.statusLabel.text = "Seek failed; playback can continue"
                }
                // An acknowledged mpv seek is not an unfinished
                // thumbnail operation; don't leave a false crash marker.
                PlayerStartupDiagnostics.clear()
                if resumeAfter {
                    seekCore.setProperty("pause", value: "no")
                    self.playing = true
                    self.showPanel()
                }
            }
        }
    }

    private func scheduleFrames() {
        guard let seconds = targetSeconds else { return }
        previewIsVisible = true
        filmStrip.alpha = 1
        previewLoadingLabel.isHidden = true
        previewStatusLabel.isHidden = true
        seekTimeLabel.alpha = 1
        previewHideTimer?.invalidate()
        previewHideTimer = nil
        if let previous = lastPreviewImageSecond,
           abs(seconds - Double(previous)) > 75 {
            frameViews.first?.image = nil
            lastPreviewImageSecond = nil
        }

        if touchpadPreviewMode && isTouchScrubbing {
            // Cache gives immediate feedback on repeat visits to a time.
            // Critically, it is not the *only* source: fresh thumbnails
            // must be requested during continuous circular motion.
            if let cached = thumbs.cachedImage(second: Int(seconds.rounded())) {
                frameViews.first?.image = cached
                lastPreviewImageSecond = (Int(seconds.rounded()) / 5) * 5
            }
        }

        // One concurrent decoding worker, with a capped live-request rate.
        // Don't reset this timer on each touch update (that would prevent
        // it from firing). It always requests the latest target position.
        guard thumbTimer == nil else { return }
        let serial = currentPreviewSerial
        let interval: TimeInterval
        if touchpadPreviewMode && isTouchScrubbing {
            let sincePrevious = Date().timeIntervalSince(lastLiveTouchpadRequest)
            interval = max(0.12, 0.95 - max(0, sincePrevious))
        } else {
            interval = touchpadPreviewMode ? 0.20 : 0.12
        }
        thumbTimer = Timer.scheduledTimer(withTimeInterval: interval,
            repeats: false) { [weak self] _ in
            guard let self else { return }
            self.thumbTimer = nil
            self.loadFrames(serial: serial)
        }
    }

    private func loadFrames(serial: Int) {
        guard previewIsVisible, let link, let targetSeconds,
              serial == currentPreviewSerial else { return }
        guard core?.isPaused == true else {
            // Only decode when the native player has ACKNOWLEDGED Pause.
            // A touchpad circular gesture may have paused it milliseconds
            // earlier; racing a second 4K decode can terminate tvOS playback.
            guard thumbTimer == nil else { return }
            thumbTimer = Timer.scheduledTimer(withTimeInterval: 0.3,
                repeats: false) { [weak self] _ in
                guard let self else { return }
                self.thumbTimer = nil
                self.loadFrames(serial: serial)
            }
            return
        }
        let second = max(0, Int(targetSeconds.rounded()))
        let bucket = (second / 5) * 5
        guard lastPreviewRequestedBucket != bucket else { return }
        lastPreviewRequestedBucket = bucket
        if touchpadPreviewMode && isTouchScrubbing {
            lastLiveTouchpadRequest = Date()
        }
        if touchpadPreviewMode {
            PlayerStartupDiagnostics.mark("touchpad-thumbnail-decode")
        }
        thumbs.request(url: link.url, second: second) { [weak self] image in
            guard let self, self.previewIsVisible,
                  self.currentPreviewSerial == serial,
                  self.link?.url == link.url else { return }
            if let image {
                // One latest available preview, with no status message.
                self.frameViews.first?.image = image
                self.lastPreviewImageSecond = bucket
                self.filmStrip.alpha = 1
                if self.touchpadPreviewMode {
                    PlayerStartupDiagnostics.mark("touchpad-thumbnail-ready")
                }
            } else {
                // A failed position must not be permanently blacklisted.
                // Revisit it after a later touch movement (e.g. another
                // seek region or once a remote connection is ready).
                self.lastPreviewRequestedBucket = nil
                PlayerStartupDiagnostics.mark("thumbnail-decoder-returned-no-frame")
            }
            self.previewLoadingLabel.isHidden = true
            self.previewStatusLabel.isHidden = true
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
        holdActivationTimer?.invalidate()
        holdActivationTimer = nil
        lockedSeekDirection = 0
        lockedSpeedIndex = 0
        resumeAfterLockedSeek = false
        circularSeekActive = false
        panStartedWhilePlaying = false
        touchpadPreviewMode = false
        seekCommitOperationID += 1
        displayNegotiationPending = false
        frameViews.first?.image = nil
        previewLoadingLabel.text = ""
        previewLoadingLabel.isHidden = true
        heldDirection = 0
        holdTickCount = 0
        isTouchScrubbing = false
        repeatTimer?.invalidate()
        repeatTimer = nil
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
        hideTimer?.invalidate()
        let hasPlayerControls = core != nil && (
            !playing || lockedSeekDirection != 0 ||
            isTouchScrubbing || targetSeconds != nil ||
            toolbarFocused || toolPanel != .none
        )
        // During normal playback, Down may reveal Audio / CC / Info, but
        // the timeline remains hidden. Progress is ONLY visible when paused
        // or in a locked/paused-scrub state.
        let showTimeline = core != nil && (!playing ||
            lockedSeekDirection != 0 || isTouchScrubbing)
        controlsVisible = hasPlayerControls
        panel.isHidden = !hasPlayerControls
        progress.isHidden = !showTimeline
        currentLabel.isHidden = !showTimeline
        endLabel.isHidden = !showTimeline
        statusLabel.isHidden = core != nil && playing && !waitingForFirstFrame
        updateToolbarFocus()
        // No timeout while the FF/RW lock is running or a finger is moving
        // across the touch surface. Only genuine inactivity can hide chrome.
        if hasPlayerControls && lockedSeekDirection == 0 &&
           !previewIsVisible && !isTouchScrubbing &&
           targetSeconds == nil && toolPanel == .none {
            hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0,
                repeats: false) { [weak self] _ in
                guard let self, self.lockedSeekDirection == 0,
                      !self.previewIsVisible, !self.isTouchScrubbing,
                      self.targetSeconds == nil,
                      self.toolPanel == .none else { return }
                self.hidePlaybackChrome()
            }
        }
    }

    @objc private func refreshClock() {
        totalSeconds = max(0, core?.duration ?? totalSeconds)
        if targetSeconds == nil {
            let actual = max(0, core?.timePos ?? currentSeconds)
            if let pin = committedSeekTarget {
                // Long remote remux seeks can take multiple seconds. Do not
                // let stale mpv time-pos suddenly move the timeline back.
                let aged = Date().timeIntervalSince(committedSeekDate ?? .distantPast) > 12.0
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
        // Progressively fill the on-device, uncapped disk cache while
        // playback runs. One low-priority preview about every 18 seconds,
        // slightly ahead of the playhead, not a parallel decoder flood.
        // Foreground seeking cancels/deprioritizes these requests.
        if playing, core?.isPaused == false, !isPreparingPlayback,
           !waitingForFirstFrame, !displayNegotiationPending,
           lockedSeekDirection == 0, !isTouchScrubbing,
           !previewIsVisible, targetSeconds == nil,
           let link, totalSeconds > 0, currentSeconds.isFinite,
           Date().timeIntervalSince(lastBackgroundPreviewAttempt) >= 18 {
            lastBackgroundPreviewAttempt = Date()
            let next = max(0, min(totalSeconds - 0.25, currentSeconds + 9))
            thumbs.prefetch(url: link.url, second: Int(next))
        }
        refreshLabels()
    }

    private func refreshLabels() {
        let seconds = targetSeconds ?? currentSeconds
        progress.progress = Float(max(0, min(1, totalSeconds > 0 ? seconds / totalSeconds : 0)))
        currentLabel.text = clockString(seconds)
        endLabel.text = totalSeconds > 0 ? clockString(totalSeconds) : "--:--"
        seekTimeLabel.text = lockedSeekDirection != 0
            ? (lockedSeekDirection > 0 ? "FAST FORWARD" : "REWIND") +
              "  ·  " + ["8×", "20×", "50×", "110×", "240×"][lockedSpeedIndex] +
              "  ·  " + clockString(seconds)
            : clockString(seconds)
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
        holdActivationTimer?.invalidate()
        thumbTimer?.invalidate()
        seekCommitTimer?.invalidate()
        previewHideTimer?.invalidate()
        hideTimer?.invalidate()
        core?.dispose()
    }
}
