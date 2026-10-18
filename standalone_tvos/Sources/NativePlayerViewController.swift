import AVFoundation
import CoreImage
import ImageIO
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

/// A thin white indicator of frames actually written to thumbnail disk cache.
/// Keep this independent from the current-time progress fill: cached regions
/// may be before or after the playhead.
private final class CachedTimelineOverlay: UIView {
    var durationSeconds = 0.0
    var frameSlots: [Int] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { return nil }

    override func draw(_ rect: CGRect) {
        guard durationSeconds > 0, rect.width > 0, !frameSlots.isEmpty else { return }
        UIColor.white.withAlphaComponent(0.98).setFill()
        let widthPerBucket = CGFloat(2.0 / durationSeconds) * rect.width
        let tickWidth = max(1.3, widthPerBucket)
        let coverage = UIBezierPath()
        for second in frameSlots {
            let start = CGFloat(Double(second) / durationSeconds) * rect.width
            guard start >= 0, start < rect.width else { continue }
            coverage.append(UIBezierPath(rect: CGRect(x: start, y: 0,
                width: min(tickWidth, rect.width - start),
                height: rect.height)))
        }
        coverage.fill()
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
    private let persistentSubtitlesKey = "Nuvio.PermanentlyDisableSubtitles"
    private var permanentlyDisableSubtitles: Bool {
        UserDefaults.standard.bool(forKey: persistentSubtitlesKey)
    }
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
    private var lastCaptureDuration = 0.0
    private var backgroundCaptureFailures = 0
    // Fallback uses the active mpv decoder, not a second network stream.
    private var backgroundNeedsSoftwareSnapshot = false
    private var backgroundSnapshotRequestID = 0
    private var lastPlaybackCapturedBucket: Int?
    private var lastCacheLookupBucket: Int?
    private var backgroundSnapshotsUnavailable = false
    private var playbackSnapshotInFlight = false
    // Only one small CoreImage output is created at a time. This captures
    // the already-presented Apple video frame without opening another codec.
    private let thumbnailImageContext = CIContext(options: [
        .useSoftwareRenderer: false
    ])
    private var lastConfirmedPauseAt: Date?
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
    // Holding an arrow while a touchpad thumbnail preview is already open
    // should scrub that preview only, never switch into locked transport.
    private var previewArrowPress = false
    private var previewArrowHoldStarted = false
    private var previewArrowRepeatTimer: Timer?
    private var explicitChromeHidden = false

    private var targetSeconds: Double?
    private var currentSeconds: Double = 0
    private var totalSeconds: Double = 0
    private var zoom: CGFloat = 1
    private var verticalStretch: CGFloat = 1
    // Saturation, contrast and brightness share the existing SDR-only
    // lutyuv filter. The neutral values preserve native HDR / DV playback.
    private var colorSaturation = 1.0
    private var colorContrast = 1.0
    private var colorBrightness = 1.0
    private var dvTrimSaturation = 1.0
    private var dvTrimContrast = 1.0
    private var dvTrimBrightness = 1.0
    private var dvTrimEnabled = false
    private var sourceColorMetadataReady = false
    private var sourceIsHDR = true
    private var sourceIsDolbyVision = false
    private var configuredNativeP5Preview = false
    // Sticky once seen for this movie. Video filters can temporarily change
    // decoded color metadata, but the original DV file must NEVER be allowed
    // to fall into an expensive 4K CPU-copy color adjustment path.
    private var originalIsDolbyVision = false
    private var requiresNativeDolbyVision: Bool {
        originalIsDolbyVision || sourceIsDolbyVision || (core?.doviProfile ?? 0) > 0
    }
    // Explicit per-video opt-in: never auto-apply an experimental filter to
    // Dolby Vision or HDR during startup or across separate movies.
    private var experimentalHDRColorBoost = false
    private var colorFilterInFlight = false
    private var colorCopyMode = false
    // Switching to CPU-accessible decoded frames can be expensive, so no
    // color processing starts automatically when a movie first opens.
    private var colorEffectRequestedForVideo = false
    private var colorFilterVerified = false
    private var colorFilterActive = false
    private var colorFilterOperation = 0
    private var colorFilterTimer: Timer?
    private var colorFilterFailed = false
    private var lastDVProbeUIUpdate = Date.distantPast
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
    // Reuse the single native mpv decoder for non-AVFoundation formats.
    // A screenshot of the original position stays over the movie while
    // the main decoder briefly visits the independently selected target.
    private let frozenVideo = UIImageView()
    private var mainFramePreviewOrigin: Double?
    private var mainFramePreviewBusy = false
    private var mainFramePreviewAwaitingSeek = false
    private var mainFramePreviewTarget: Int?
    private var mainFramePreviewPending: Int?
    private var mainFramePreviewGeneration = 0
    private var mainFramePreviewUnsupported = false
    private var mainFramePreviewRestoreTarget: Double?
    private var mainFramePreviewResumeAfterRestore = false
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
    private let cachedTimeline = CachedTimelineOverlay()
    // Compact vertical playhead: slightly taller than the 5-point track.
    // Its center tracks the selected thumbnail or current playback position.
    private let playbackPositionMarker = UIView()
    private var playbackMarkerXConstraint: NSLayoutConstraint?
    private let cacheRateLabel = UILabel()
    private var lastCacheUIUpdate = Date.distantPast
    // Actual media-network rate, independent of JPEG thumbnail writes.
    private var videoInputRateMbps: Double?
    private var videoDiskCacheBytes: Double?
    private var lastVideoDiskCacheSampleAt: Date?
    private var videoDiskWriteRateMBps: Double?
    private var lastRangeCacheBytesWritten: UInt64?
    private var lastRangeCacheSampleAt: Date?
    private var rangeCacheWriteRateMBps = 0.0
    private var frameTapInstalled = false
    private let currentLabel = UILabel()
    private let endLabel = UILabel()
    private let filmStrip = UIStackView()
    // The floating preview tracks the played/scrubbed fraction of the
    // *actual laid-out* progress bar, not the width of the full screen.
    // Constrain the entire window inside the screen at timeline endpoints.
    private let seekPreviewWidth: CGFloat = 604 // 575 × 1.05 ≈ 604
    private var thumbnailCenterXConstraint: NSLayoutConstraint?
    private var frameViews: [UIImageView] = []
    private let instructionsLabel = UILabel()
    private let picturePanel = UIView()
    private let zoomLabel = UILabel()
    private let stretchLabel = UILabel()
    private let saturationLabel = UILabel()
    private let contrastLabel = UILabel()
    private let brightnessLabel = UILabel()
    private let hdrBoostLabel = UILabel()
    private let colorStatusLabel = UILabel()
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Progress-bar geometry depends on Safe Area and the trailing tools.
        // Read it after Auto Layout, including after display-mode changes.
        updateThumbnailHorizontalPosition()
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
        // Turn off the old renderer hook before its core is disposed.
        NuvioFrameTapStop()
        frameTapInstalled = false
        stopPreviewArrowHold()
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
        lastCacheUIUpdate = .distantPast
        videoInputRateMbps = nil
        videoDiskCacheBytes = nil
        lastVideoDiskCacheSampleAt = nil
        videoDiskWriteRateMBps = nil
        lastRangeCacheBytesWritten = nil
        lastRangeCacheSampleAt = nil
        rangeCacheWriteRateMBps = 0
        cachedTimeline.frameSlots = []
        cachedTimeline.durationSeconds = 0
        cachedTimeline.setNeedsDisplay()
        cacheRateLabel.text = "VIDEO — Mb/s  ·  DISK — MB/s"
        explicitChromeHidden = false
        lastCaptureDuration = 0
        backgroundCaptureFailures = 0
        backgroundNeedsSoftwareSnapshot = false
        backgroundSnapshotRequestID += 1
        lastPlaybackCapturedBucket = nil
        lastCacheLookupBucket = nil
        backgroundSnapshotsUnavailable = false
        playbackSnapshotInFlight = false
        lastConfirmedPauseAt = nil
        mainFramePreviewOrigin = nil
        mainFramePreviewBusy = false
        mainFramePreviewAwaitingSeek = false
        mainFramePreviewTarget = nil
        mainFramePreviewPending = nil
        mainFramePreviewGeneration += 1
        mainFramePreviewUnsupported = false
        mainFramePreviewRestoreTarget = nil
        frozenVideo.isHidden = true
        frozenVideo.image = nil
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
        // Restore previous adjustments without modifying media until
        // SDR/HDR metadata has been checked for this new stream.
        colorSaturation = (UserDefaults.standard.object(forKey: "Nuvio.ColorSaturation") as? Double)
            .map { min(1.50, max(0.60, $0)) } ?? 1.0
        colorContrast = (UserDefaults.standard.object(forKey: "Nuvio.ColorContrast") as? Double)
            .map { min(1.40, max(0.70, $0)) } ?? 1.0
        colorBrightness = (UserDefaults.standard.object(forKey: "Nuvio.ColorBrightness") as? Double)
            .map { min(1.50, max(0.70, $0)) } ?? 1.0
        dvTrimEnabled = false
        dvTrimSaturation = 1
        dvTrimContrast = 1
        dvTrimBrightness = 1
        NuvioDVTrimSet(false, 1, 1, 1)
        sourceColorMetadataReady = false
        sourceIsHDR = true
        sourceIsDolbyVision = false
        configuredNativeP5Preview = false
        originalIsDolbyVision = false
        experimentalHDRColorBoost = false
        colorFilterActive = false
        colorFilterInFlight = false
        colorCopyMode = false
        colorEffectRequestedForVideo = false
        colorFilterVerified = false
        colorFilterFailed = false
        colorFilterOperation += 1
        colorFilterTimer?.invalidate()
        colorFilterTimer = nil
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
        // Prevent mpv from automatically choosing embedded subtitle tracks.
        if permanentlyDisableSubtitles { newCore.setProperty("sid", value: "no") }
        core = newCore
        // Observe the AVFoundation renderer's *input* samples, not its
        // displayedPixelBuffer() output (nil on some tvOS hardware paths).
        // This takes an occasional already-decoded SDR/HDR/DV frame without
        // a second FFmpeg decoder or a second download.
        if #available(tvOS 17.0, *),
           let layer = newCore.videoLayer {
            let renderer = layer.sampleBufferRenderer
            frameTapInstalled = NuvioFrameTapStart(layer, renderer) {
                [weak self, weak newCore] image, second in
                guard let self, let newCore,
                      self.playbackGeneration == generation,
                      self.core === newCore else { return }
                self.thumbs.cachePlaybackFrame(image, second: Int(second))
            }
        }
        if !frameTapInstalled {
            NSLog("[NuvioCache] Cannot intercept AVFoundation video renderer")
        }
        // mpv's default screenshot path expects a GPU VO; our tvOS video
        // renders through AVSampleBufferDisplayLayer. A software screenshot
        // fallback is required whenever no displayed CVPixelBuffer is
        // exposed (e.g. certain compressed/HDR presentation paths).
        newCore.setProperty("screenshot-sw", value: "yes")
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
                    // Arm decoded-frame capture immediately when mpv begins
                    // playback. Do not wait for a UI chrome/clock refresh.
                    NuvioFrameTapSetPaused(false)
                    NuvioFrameTapSetPlaybackSecond(Int64(max(0, core.timePos)))
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
                    if self.permanentlyDisableSubtitles {
                        core.setProperty("sid", value: "no")
                    } else {
                        self.attachInitialSubtitleIfAvailable()
                    }
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
        guard !permanentlyDisableSubtitles,
              !subtitleAlreadyRequested, let subtitleURLToLoad, let core else { return }
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
                // Mpv's decoded-frame clock is independent of the Siri Remote
                // seek UI. Feed the renderer hook directly from mpv progress
                // events; the hook extrapolates between events using monotonic
                // host time if the tvOS UI timer becomes delayed.
                if self.frameTapInstalled,
                   let n = value as? NSNumber,
                   n.doubleValue.isFinite && n.doubleValue >= 0 {
                    NuvioFrameTapSetPlaybackSecond(Int64(n.doubleValue))
                }
            case "pause":
                if let n = value as? NSNumber { self.playing = !n.boolValue }
                else if let s = value as? String { self.playing = s != "yes" }
                // A paused renderer has no advancing movie clock. Stop
                // extrapolating until mpv confirms normal playback again.
                // UI timer ticks cannot inadvertently reactivate it.
                NuvioFrameTapSetPaused(!self.playing)
                if self.playing, let playingCore = self.core {
                    NuvioFrameTapSetPlaybackSecond(
                        Int64(max(0, playingCore.timePos)))
                }
                // This is the observed mpv state, rather than the optimistic
                // pause intent cached as soon as setProperty was issued.
                if self.playing {
                    self.lastConfirmedPauseAt = nil
                } else {
                    self.lastConfirmedPauseAt = Date()
                }
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
                // Read color metadata only after playback-restart, when mpv
                // has decoded a frame and populated DV/HDR signal caches.
            case "playback-restart":
                // Native single-decoder preview frame is now ready. Do not
                // pull an image before mpv has actually decoded the target.
                if self.mainFramePreviewAwaitingSeek,
                   let target = self.mainFramePreviewTarget {
                    let measured = (data?["positionSeconds"] as? NSNumber)?.doubleValue
                        ?? self.core?.timePos ?? -1
                    if measured.isFinite && abs(measured - Double(target)) <= 5 {
                        self.mainFramePreviewAwaitingSeek = false
                        // mpv's playback-restart can precede the actual
                        // AVSampleBufferDisplayLayer presentation. Allow
                        // the hardware renderer to publish the new frame,
                        // otherwise a previous GOP image is captured.
                        let generation = self.mainFramePreviewGeneration
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                            guard let self, generation == self.mainFramePreviewGeneration,
                                  self.mainFramePreviewBusy,
                                  self.mainFramePreviewTarget == target else { return }
                            self.captureNativePreviewTarget(target, generation: generation)
                        }
                    }
                }
                if let restore = self.mainFramePreviewRestoreTarget {
                    let measured = (data?["positionSeconds"] as? NSNumber)?.doubleValue
                        ?? self.core?.timePos ?? -1
                    if measured.isFinite && abs(measured - restore) <= 5 {
                        self.finishNativePreviewRestore()
                    }
                }
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
                    self.checkColorSourceMetadata()
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

        // Covers the actual video only while taking previews through mpv.
        // The unchanged movie frame stays visible behind the scrub UI.
        frozenVideo.frame = view.bounds
        frozenVideo.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        frozenVideo.contentMode = .scaleAspectFit
        frozenVideo.backgroundColor = .black
        frozenVideo.isUserInteractionEnabled = false
        frozenVideo.isHidden = true
        view.insertSubview(frozenVideo, aboveSubview: remote)

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
        // Blue = played portion, white = actual saved thumbnail frames.
        progress.progressTintColor = UIColor(red: 0.36, green: 0.72,
                                             blue: 1.0, alpha: 1)
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.25)
        progress.layer.cornerRadius = 2
        progress.clipsToBounds = true
        panel.addSubview(progress)
        cachedTimeline.translatesAutoresizingMaskIntoConstraints = false
        cachedTimeline.layer.cornerRadius = 2
        cachedTimeline.clipsToBounds = true
        panel.addSubview(cachedTimeline)
        playbackPositionMarker.translatesAutoresizingMaskIntoConstraints = false
        playbackPositionMarker.backgroundColor = UIColor.white
        playbackPositionMarker.layer.cornerRadius = 3
        playbackPositionMarker.isUserInteractionEnabled = false
        // Draw over the progress fill and white cached sections so the
        // current playhead remains discernible even on a fully cached bar.
        panel.addSubview(playbackPositionMarker)
        cacheRateLabel.translatesAutoresizingMaskIntoConstraints = false
        cacheRateLabel.text = "VIDEO — Mb/s  ·  DISK — MB/s"
        cacheRateLabel.textColor = UIColor.white.withAlphaComponent(0.88)
        cacheRateLabel.font = .monospacedDigitSystemFont(
            ofSize: 15, weight: .medium)
        cacheRateLabel.textAlignment = .right
        cacheRateLabel.isUserInteractionEnabled = false
        // Always visible at the lower right during playback, not only when
        // the pause/seek panel is shown. No debug counters are displayed.
        cacheRateLabel.isHidden = true
        view.addSubview(cacheRateLabel)

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
        // Clean edge: no white stroke around the floating thumbnail.
        preview.layer.borderWidth = 0
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
        for label in [zoomLabel, stretchLabel, saturationLabel, contrastLabel, brightnessLabel, hdrBoostLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
            label.textColor = .white
            picturePanel.addSubview(label)
        }
        colorStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        colorStatusLabel.font = .systemFont(ofSize: 17, weight: .medium)
        colorStatusLabel.textColor = .white.withAlphaComponent(0.75)
        colorStatusLabel.numberOfLines = 4
        picturePanel.addSubview(colorStatusLabel)
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
        for _ in 0..<8 {
            let label = UILabel()
            label.font = .systemFont(ofSize: 19)
            label.textColor = .white
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.75
            label.heightAnchor.constraint(equalToConstant: 35).isActive = true
            trackLabels.append(label)
            rows.addArrangedSubview(label)
        }
        let movableThumbnailX = filmStrip.centerXAnchor.constraint(
            equalTo: view.leadingAnchor, constant: view.bounds.midX)
        thumbnailCenterXConstraint = movableThumbnailX

        let movablePlayheadX = playbackPositionMarker.centerXAnchor.constraint(
            equalTo: progress.leadingAnchor)
        playbackMarkerXConstraint = movablePlayheadX
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
            // Bring the entire bottom transport row close to the screen edge.
            // Unlike the floating seek thumbnail, only this control container
            // moves; its internal arrangement and seek behavior stay unchanged.
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            panel.heightAnchor.constraint(equalToConstant: 54),
            currentLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 4),
            currentLabel.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            currentLabel.widthAnchor.constraint(equalToConstant: 105),
            progress.leadingAnchor.constraint(equalTo: currentLabel.trailingAnchor, constant: 12),
            progress.trailingAnchor.constraint(equalTo: endLabel.leadingAnchor, constant: -12),
            progress.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            progress.heightAnchor.constraint(equalToConstant: 5),
            cachedTimeline.leadingAnchor.constraint(equalTo: progress.leadingAnchor),
            cachedTimeline.trailingAnchor.constraint(equalTo: progress.trailingAnchor),
            cachedTimeline.centerYAnchor.constraint(equalTo: progress.centerYAnchor),
            cachedTimeline.heightAnchor.constraint(equalTo: progress.heightAnchor),
            // A 6 x 17-point white pill extends 6 points above and below
            // the 5-point timeline without becoming a tall divider.
            playbackPositionMarker.centerYAnchor.constraint(equalTo: progress.centerYAnchor),
            playbackPositionMarker.widthAnchor.constraint(equalToConstant: 6),
            playbackPositionMarker.heightAnchor.constraint(equalToConstant: 17),
            movablePlayheadX,
            cacheRateLabel.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            cacheRateLabel.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -6),
            cacheRateLabel.widthAnchor.constraint(equalToConstant: 485),
            cacheRateLabel.heightAnchor.constraint(equalToConstant: 20),
            endLabel.trailingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: -17),
            endLabel.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            endLabel.widthAnchor.constraint(equalToConstant: 105),
            toolbar.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            toolbar.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            // Increase the previous 548 × 296 preview by another 5%
            // on both axes. Move its bottom edge up 5% of screen height.
            filmStrip.widthAnchor.constraint(equalToConstant: seekPreviewWidth),
            filmStrip.heightAnchor.constraint(equalToConstant: 311),
            movableThumbnailX,
            // Bottom edge at 65% down from top (previously 70%).
            NSLayoutConstraint(item: filmStrip, attribute: .bottom,
                relatedBy: .equal, toItem: view, attribute: .bottom,
                multiplier: 0.65, constant: 0),
            seekTimeLabel.centerXAnchor.constraint(equalTo: filmStrip.centerXAnchor),
            seekTimeLabel.bottomAnchor.constraint(equalTo: filmStrip.topAnchor, constant: -10),
            previewStatusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            previewStatusLabel.bottomAnchor.constraint(equalTo: seekTimeLabel.topAnchor, constant: -16),
            previewStatusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.9),
            picturePanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            picturePanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -45),
            picturePanel.widthAnchor.constraint(equalToConstant: 535),
            zoomLabel.topAnchor.constraint(equalTo: picturePanel.topAnchor, constant: 23),
            zoomLabel.leadingAnchor.constraint(equalTo: picturePanel.leadingAnchor, constant: 22),
            zoomLabel.trailingAnchor.constraint(equalTo: picturePanel.trailingAnchor, constant: -22),
            stretchLabel.topAnchor.constraint(equalTo: zoomLabel.bottomAnchor, constant: 15),
            stretchLabel.leadingAnchor.constraint(equalTo: zoomLabel.leadingAnchor),
            stretchLabel.trailingAnchor.constraint(equalTo: zoomLabel.trailingAnchor),
            saturationLabel.topAnchor.constraint(equalTo: stretchLabel.bottomAnchor, constant: 15),
            saturationLabel.leadingAnchor.constraint(equalTo: zoomLabel.leadingAnchor),
            saturationLabel.trailingAnchor.constraint(equalTo: zoomLabel.trailingAnchor),
            contrastLabel.topAnchor.constraint(equalTo: saturationLabel.bottomAnchor, constant: 15),
            contrastLabel.leadingAnchor.constraint(equalTo: zoomLabel.leadingAnchor),
            contrastLabel.trailingAnchor.constraint(equalTo: zoomLabel.trailingAnchor),
            brightnessLabel.topAnchor.constraint(equalTo: contrastLabel.bottomAnchor, constant: 15),
            brightnessLabel.leadingAnchor.constraint(equalTo: zoomLabel.leadingAnchor),
            brightnessLabel.trailingAnchor.constraint(equalTo: zoomLabel.trailingAnchor),
            hdrBoostLabel.topAnchor.constraint(equalTo: brightnessLabel.bottomAnchor, constant: 15),
            hdrBoostLabel.leadingAnchor.constraint(equalTo: zoomLabel.leadingAnchor),
            hdrBoostLabel.trailingAnchor.constraint(equalTo: zoomLabel.trailingAnchor),
            colorStatusLabel.topAnchor.constraint(equalTo: hdrBoostLabel.bottomAnchor, constant: 15),
            colorStatusLabel.leadingAnchor.constraint(equalTo: zoomLabel.leadingAnchor),
            colorStatusLabel.trailingAnchor.constraint(equalTo: zoomLabel.trailingAnchor),
            colorStatusLabel.bottomAnchor.constraint(equalTo: picturePanel.bottomAnchor, constant: -20),
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
        view.bringSubviewToFront(cacheRateLabel)
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
        let sat = requiresNativeDolbyVision ? dvTrimSaturation : colorSaturation
        let con = requiresNativeDolbyVision ? dvTrimContrast : colorContrast
        let bri = requiresNativeDolbyVision ? dvTrimBrightness : colorBrightness
        saturationLabel.text = "\(selectedPictureControl == 2 ? "▶ " : "   ")Saturation: \(Int((sat * 100).rounded()))%"
        contrastLabel.text = "\(selectedPictureControl == 3 ? "▶ " : "   ")Contrast: \(Int((con * 100).rounded()))%"
        brightnessLabel.text = "\(selectedPictureControl == 4 ? "▶ " : "   ")Brightness: \(Int((bri * 100).rounded()))%"
        hdrBoostLabel.text = requiresNativeDolbyVision
            ? "\(selectedPictureControl == 5 ? "▶ " : "   ")DV safe saturation test: \(dvTrimEnabled ? "ON" : "OFF")"
            : "\(selectedPictureControl == 5 ? "▶ " : "   ")HDR boost (test): \(experimentalHDRColorBoost ? "ON" : "OFF")"
        zoomLabel.textColor = selectedPictureControl == 0 ? .white : .lightGray
        stretchLabel.textColor = selectedPictureControl == 1 ? .white : .lightGray
        let sdrHdrAvailable = sourceColorMetadataReady && !requiresNativeDolbyVision
            && (!sourceIsHDR || experimentalHDRColorBoost) && !colorFilterFailed
        saturationLabel.textColor = (sdrHdrAvailable || (requiresNativeDolbyVision && dvTrimEnabled))
            ? (selectedPictureControl == 2 ? .white : .lightGray) : .gray
        // v2 DV test isolates saturation; contrast/brightness edits are
        // disabled until metadata target mapping can be calibrated safely.
        contrastLabel.textColor = sdrHdrAvailable
            ? (selectedPictureControl == 3 ? .white : .lightGray) : .gray
        brightnessLabel.textColor = sdrHdrAvailable
            ? (selectedPictureControl == 4 ? .white : .lightGray) : .gray
        hdrBoostLabel.textColor = requiresNativeDolbyVision
            || (sourceColorMetadataReady && sourceIsHDR)
            ? (selectedPictureControl == 5 ? .white : .lightGray) : .gray
        if requiresNativeDolbyVision {
            // An experimental, read-only check for Dolby's post-decode
            // metadata. Never present these numbers as functional picture
            // controls: no RPU rewriting is active.
            let sampled = NuvioDVProbeSampleCount()
            let tagged = NuvioDVProbeTaggedSampleCount()
            let frameBytes = NuvioDVProbeFrameMetadataBytes()
            let sequenceBytes = NuvioDVProbeSequenceMetadataBytes()
            let edited = NuvioDVTrimEditedCount()
            let skipped = NuvioDVTrimUneditableCount()
            if dvTrimEnabled {
                colorStatusLabel.text = "DV SAT-ONLY TEST: edited \(edited) · skipped \(skipped)\n\(NuvioDVTrimIsEnabled() ? "one subtle trim target" : "neutral/fail-safe off") · contrast/brightness locked"
            } else if sampled == 0 {
                colorStatusLabel.text = "DV RPU: awaiting samples\nTurn test ON then adjust a value"
            } else if tagged > 0 {
                colorStatusLabel.text = "DV RPU: \(frameBytes) B per frame\nOriginal metadata · safer saturation test available"
            } else {
                colorStatusLabel.text = "DV RPU unavailable\nNative Dolby Vision protected"
            }
        } else if !sourceColorMetadataReady {
            colorStatusLabel.text = "Checking source color format…"
        } else if colorFilterInFlight {
            colorStatusLabel.text = "Configuring color processing…"
        } else if colorFilterFailed {
            colorStatusLabel.text = "Video filter failed or HDR mode changed.\nBoost disabled; reset to try again."
        } else if sourceIsHDR && !experimentalHDRColorBoost {
            colorStatusLabel.text = "Native HDR protected.\nTurn boost ON to test color changes."
        } else if sourceIsHDR {
            colorStatusLabel.text = "EXPERIMENTAL HDR: verify TV still shows HDR.\n\(colorFilterVerified ? "Filter loaded" : "Verify picture changes") • OFF restores original."
        } else {
            colorStatusLabel.text = colorEffectRequestedForVideo
                ? "SDR: \(colorFilterVerified ? "filter listed" : "testing processing")\n100% is original • Select resets all"
                : "SDR native picture • adjust a value to enable\n100% is original • Select resets all"
        }
    }


    private func applyPictureTransform() {
        guard let layer = core?.sampleBufferDisplayLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(zoom, zoom * verticalStretch, 1)
        CATransaction.commit()
    }

    private func updateExperimentalDVTrims() {
        NuvioDVTrimSet(dvTrimEnabled, dvTrimSaturation, dvTrimContrast, dvTrimBrightness)
    }

    private func changePictureValue(_ direction: Int) {
        switch selectedPictureControl {
        case 0:
            zoom = max(1, min(2.5, zoom + CGFloat(direction) * 0.05))
            applyPictureTransform()
        case 1:
            verticalStretch = max(0.75, min(1.7, verticalStretch + CGFloat(direction) * 0.05))
            applyPictureTransform()
        case 2 where requiresNativeDolbyVision && dvTrimEnabled:
            // One conservative, independently verifiable saturation trim.
            // 95–105% test range; no more aggressive multi-target edits.
            dvTrimSaturation = min(1.05, max(0.95,
                (dvTrimSaturation * 100 + Double(direction) * 5).rounded() / 100))
            updateExperimentalDVTrims()
        case 2 where sourceColorMetadataReady && !requiresNativeDolbyVision
            && (!sourceIsHDR || experimentalHDRColorBoost) && !colorFilterFailed:
            colorSaturation = min(1.50, max(0.60,
                (colorSaturation * 100 + Double(direction) * 5).rounded() / 100))
            UserDefaults.standard.set(colorSaturation, forKey: "Nuvio.ColorSaturation")
            colorEffectRequestedForVideo = true
            scheduleColorFilterUpdate()
        case 3 where sourceColorMetadataReady && !requiresNativeDolbyVision
            && (!sourceIsHDR || experimentalHDRColorBoost) && !colorFilterFailed:
            colorContrast = min(1.40, max(0.70,
                (colorContrast * 100 + Double(direction) * 5).rounded() / 100))
            UserDefaults.standard.set(colorContrast, forKey: "Nuvio.ColorContrast")
            colorEffectRequestedForVideo = true
            scheduleColorFilterUpdate()
        case 4 where sourceColorMetadataReady && !requiresNativeDolbyVision
            && (!sourceIsHDR || experimentalHDRColorBoost) && !colorFilterFailed:
            // A small luma-plane offset lifts a dark SDR picture without
            // changing the video geometry or invoking a second filter path.
            colorBrightness = min(1.50, max(0.70,
                (colorBrightness * 100 + Double(direction) * 5).rounded() / 100))
            UserDefaults.standard.set(colorBrightness, forKey: "Nuvio.ColorBrightness")
            colorEffectRequestedForVideo = true
            scheduleColorFilterUpdate()
        case 5 where requiresNativeDolbyVision:
            dvTrimEnabled = direction > 0
            if !dvTrimEnabled {
                dvTrimSaturation = 1
                dvTrimContrast = 1
                dvTrimBrightness = 1
            }
            updateExperimentalDVTrims()
        case 5 where sourceColorMetadataReady && sourceIsHDR && !requiresNativeDolbyVision:
            // HDR10 remains a per-movie experiment. Dolby Vision MUST NOT
            // use this path; copying its 4K 10-bit frames caused extreme lag.
            experimentalHDRColorBoost = direction > 0
            colorEffectRequestedForVideo = experimentalHDRColorBoost
            if experimentalHDRColorBoost {
                // Make the opt-in visibly useful at neutral: a conservative
                // boost that users can fine-tune with the rows above.
                if abs(colorSaturation - 1.0) < 0.001
                    && abs(colorContrast - 1.0) < 0.001 {
                    colorSaturation = 1.10
                    colorContrast = 1.05
                }
            } else {
                colorFilterFailed = false
            }
            scheduleColorFilterUpdate()
        default: break
        }
        updatePictureLabels()
        showPanel()
    }

    private func resetPicture() {
        zoom = 1
        verticalStretch = 1
        colorSaturation = 1.0
        colorContrast = 1.0
        colorBrightness = 1.0
        dvTrimSaturation = 1
        dvTrimContrast = 1
        dvTrimBrightness = 1
        dvTrimEnabled = false
        NuvioDVTrimSet(false, 1, 1, 1)
        experimentalHDRColorBoost = false
        colorEffectRequestedForVideo = false
        colorFilterFailed = false
        UserDefaults.standard.set(1.0, forKey: "Nuvio.ColorSaturation")
        UserDefaults.standard.set(1.0, forKey: "Nuvio.ColorContrast")
        UserDefaults.standard.set(1.0, forKey: "Nuvio.ColorBrightness")
        applyPictureTransform()
        scheduleColorFilterUpdate()
        updatePictureLabels()
    }

    private func checkColorSourceMetadata() {
        // Some streams don't publish dimensions before their first
        // playback-restart notification. The user can open Picture later;
        // query the decoded stream's color metadata directly instead of
        // permanently refusing to initialize the controls.
        guard let playbackCore = core,
              (playbackCore.videoSize != nil || !waitingForFirstFrame) else { return }
        let generation = playbackGeneration
        playbackCore.getPropertyAsync("video-params/gamma") {
            [weak self, weak playbackCore] result in
            guard let self, let playbackCore,
                  self.playbackGeneration == generation,
                  self.core === playbackCore else { return }
            let gamma = (try? result.get())?.lowercased() ?? ""
            // The VideoToolbox/AVDisplayManager path preserves source HDR
            // metadata. Do not insert SDR lavfi processing into DV/PQ/HLG.
            let dv = playbackCore.doviProfile > 0
            let hdr = dv
                || playbackCore.lastSigPeak > 1.05
                || gamma.contains("smpte2084")
                || gamma.contains("pq")
                || gamma.contains("hlg")
                || gamma.contains("arib")
            if dv {
                self.originalIsDolbyVision = true
                self.experimentalHDRColorBoost = false
                self.colorEffectRequestedForVideo = false
            }
            if self.sourceColorMetadataReady
                && self.sourceIsHDR == hdr
                && self.sourceIsDolbyVision == dv {
                if dv { self.scheduleColorFilterUpdate() }
                return
            }
            // If an active experimental filter caused an apparent loss of
            // Dolby Vision, immediately disable and revert that filter.
            if self.sourceIsDolbyVision && !dv && self.experimentalHDRColorBoost {
                self.experimentalHDRColorBoost = false
                self.colorFilterFailed = true
            }
            self.sourceColorMetadataReady = true
            self.sourceIsHDR = hdr
            self.sourceIsDolbyVision = dv
            self.updatePictureLabels()
            self.scheduleColorFilterUpdate()
        }
    }

    private func scheduleColorFilterUpdate() {
        colorFilterOperation += 1
        let operation = colorFilterOperation
        colorFilterTimer?.invalidate()
        colorFilterTimer = Timer.scheduledTimer(withTimeInterval: 0.23,
            repeats: false) { [weak self] _ in
            guard let self, self.colorFilterOperation == operation else { return }
            self.colorFilterTimer = nil
            self.applyColorFilterNow(operation: operation)
        }
    }

    private func applyColorFilterNow(operation: Int) {
        guard let playbackCore = core, operation == colorFilterOperation,
              sourceColorMetadataReady, !colorFilterInFlight else { return }
        let generation = playbackGeneration
        let nonneutral = abs(colorSaturation - 1.0) > 0.001
            || abs(colorContrast - 1.0) > 0.001
            || abs(colorBrightness - 1.0) > 0.001
        let enabled = nonneutral && colorEffectRequestedForVideo
            && !requiresNativeDolbyVision
            && (!sourceIsHDR || experimentalHDRColorBoost)
            && !colorFilterFailed

        // Never stack two filter graphs. Changes and disable requests remove
        // the existing graph before any other decoder configuration.
        if colorFilterActive {
            colorFilterInFlight = true
            playbackCore.commandAsync(["vf", "remove", "@nuvio-color"]) {
                [weak self, weak playbackCore] _ in
                guard let self, let playbackCore, self.core === playbackCore,
                      self.playbackGeneration == generation else { return }
                self.colorFilterInFlight = false
                self.colorFilterActive = false
                self.colorFilterVerified = false
                self.scheduleColorFilterUpdate()
                self.updatePictureLabels()
            }
            return
        }

        // Restore original direct VideoToolbox as soon as effect is off.
        // This is important for native HDR/Dolby Vision metadata.
        if !enabled {
            guard colorCopyMode else {
                updatePictureLabels()
                return
            }
            colorFilterInFlight = true
            playbackCore.setPropertyAsync("hwdec", value: "videotoolbox") {
                [weak self, weak playbackCore] result in
                guard let self, let playbackCore, self.core === playbackCore,
                      self.playbackGeneration == generation else { return }
                self.colorFilterInFlight = false
                self.colorCopyMode = false
                if case .failure(let error) = result {
                    NSLog("[NuvioColor] Unable to restore direct decoder: %@",
                          error.localizedDescription)
                    self.colorFilterFailed = true
                }
                self.updatePictureLabels()
                if self.colorFilterOperation != operation {
                    self.scheduleColorFilterUpdate()
                }
            }
            return
        }

        // The enabled FFmpeg lutyuv graph cannot process opaque hardware video surfaces.
        // videotoolbox-copy supplies ordinary image frames to libavfilter.
        if !colorCopyMode {
            colorFilterInFlight = true
            colorFilterVerified = false
            updatePictureLabels()
            playbackCore.setPropertyAsync("hwdec", value: "videotoolbox-copy") {
                [weak self, weak playbackCore] result in
                guard let self, let playbackCore, self.core === playbackCore,
                      self.playbackGeneration == generation else { return }
                self.colorFilterInFlight = false
                switch result {
                case .success:
                    self.colorCopyMode = true
                    self.scheduleColorFilterUpdate()
                case .failure(let error):
                    self.colorFilterFailed = true
                    self.experimentalHDRColorBoost = false
                    NSLog("[NuvioColor] VideoToolbox copy mode rejected: %@",
                          error.localizedDescription)
                    self.scheduleColorFilterUpdate()
                }
                self.updatePictureLabels()
            }
            return
        }

        // MPVKit's pinned FFmpeg is built with --disable-filters and a
        // selective allowlist. It DOES NOT include the video 'eq' filter
        // used by previous builds. The supported 'lutyuv' filter is enabled
        // by --enable-filter=lut*. Apply contrast to the Y plane and
        // saturation to U/V around the bit-depth-correct neutral midpoint.
        // Brightness adds a modest luma offset in native sample units.
        // This expression works on both 8-bit (128) and 10-bit (512) YUV;
        // no hardcoded pixel depth or conversion to 8-bit is required.
        // IMPORTANT: HDR/Dolby Vision may still lose dynamic metadata when
        // video pixels are filtered. HDR stays explicit opt-in.
        let lumaLift = (colorBrightness - 1.0) * 0.35
        let spec = String(format:
            "@nuvio-color:lavfi=[lutyuv=y=(val-(maxval+1)/2)*%.2f+(maxval+1)/2+(maxval+1)*%.4f:u=(val-(maxval+1)/2)*%.2f+(maxval+1)/2:v=(val-(maxval+1)/2)*%.2f+(maxval+1)/2]",
            colorContrast, lumaLift, colorSaturation, colorSaturation)
        colorFilterInFlight = true
        colorFilterVerified = false
        updatePictureLabels()
        playbackCore.commandAsync(["vf", "add", spec]) {
            [weak self, weak playbackCore] result in
            guard let self, let playbackCore, self.core === playbackCore,
                  self.playbackGeneration == generation else { return }
            self.colorFilterInFlight = false
            if case .failure(let error) = result {
                self.colorFilterActive = false
                self.colorFilterFailed = true
                self.experimentalHDRColorBoost = false
                NSLog("[NuvioColor] FFmpeg lutyuv filter rejected: %@",
                      error.localizedDescription)
                self.scheduleColorFilterUpdate()
            } else {
                self.colorFilterActive = true
                // Successful addition is not proof of active processing.
                // Inspect the named runtime filter list.
                playbackCore.getPropertyAsync("vf") { [weak self, weak playbackCore] property in
                    guard let self, let playbackCore,
                          self.core === playbackCore,
                          self.playbackGeneration == generation else { return }
                    let list = (try? property.get()) ?? ""
                    self.colorFilterVerified = list.contains("nuvio-color")
                    NSLog("[NuvioColor] vf graph %@; copy decoder requested",
                          self.colorFilterVerified ? "listed" : "unverified")
                    self.updatePictureLabels()
                    // Allow mpv time to reinitialize the decoder after the
                    // runtime hwdec switch. Querying immediately could read
                    // the outgoing decoder and mistakenly disable the effect.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        [weak self, weak playbackCore] in
                        guard let self, let playbackCore,
                              self.core === playbackCore,
                              self.playbackGeneration == generation,
                              self.colorFilterActive,
                              self.colorEffectRequestedForVideo else { return }
                        playbackCore.getPropertyAsync("hwdec-current") {
                            [weak self, weak playbackCore] decoderResult in
                            guard let self, let playbackCore,
                                  self.core === playbackCore,
                                  self.playbackGeneration == generation,
                                  self.colorFilterActive else { return }
                            let actual = (try? decoderResult.get()) ?? "unknown"
                            NSLog("[NuvioColor] actual hwdec after settle=%@", actual)
                            if actual == "videotoolbox" {
                                self.colorFilterFailed = true
                                self.experimentalHDRColorBoost = false
                                self.colorEffectRequestedForVideo = false
                                self.scheduleColorFilterUpdate()
                                self.updatePictureLabels()
                            }
                        }
                    }
                }
                if self.sourceIsHDR {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        [weak self, weak playbackCore] in
                        guard let self, let playbackCore,
                              self.core === playbackCore,
                              self.playbackGeneration == generation,
                              self.experimentalHDRColorBoost else { return }
                        playbackCore.getPropertyAsync("video-out-params/gamma") {
                            [weak self] gammaResult in
                            guard let self, self.core === playbackCore,
                                  self.playbackGeneration == generation,
                                  self.experimentalHDRColorBoost else { return }
                            let gamma = (try? gammaResult.get())?.lowercased() ?? ""
                            if ["bt.1886", "srgb", "gamma2"].contains(where: gamma.contains) {
                                self.experimentalHDRColorBoost = false
                                self.colorFilterFailed = true
                                self.updatePictureLabels()
                                self.scheduleColorFilterUpdate()
                                NSLog("[NuvioColor] Reverted boost on SDR output")
                            }
                        }
                    }
                }
            }
            self.updatePictureLabels()
            if self.colorFilterOperation != operation {
                self.scheduleColorFilterUpdate()
            }
        }
    }

    func remoteBegan(_ key: UIPress.PressType) {
        // User navigation explicitly reopens chrome after a committed seek.
        // The select that confirms a preview sets this back to true below.
        if key == .upArrow || key == .downArrow || key == .playPause {
            explicitChromeHidden = false
        }
        switch key {
        case .leftArrow, .rightArrow:
            let direction = key == .rightArrow ? 1 : -1
            if toolPanel == .picture {
                changePictureValue(direction)
            } else if toolPanel == .none {
                if targetSeconds != nil || previewIsVisible || lockedSeekDirection != 0 {
                    // Preview takes priority over toolbar focus. A short click
                    // steps its playhead; holding scrubs its preview without
                    // entering the separate locked FF/RW transport.
                    beginDirectionalSeek(direction)
                } else if toolbarFocused {
                    toolbarIndex = (toolbarIndex + direction + toolbarButtons.count) % toolbarButtons.count
                    updateToolbarFocus()
                    showPanel()
                } else if !isTouchScrubbing {
                    beginDirectionalSeek(direction)
                }
            }
        case .upArrow:
            if toolPanel == .picture {
                selectedPictureControl = max(0, selectedPictureControl - 1)
                updatePictureLabels()
                showPanel()
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
                checkColorSourceMetadata()
                updatePictureLabels()
                showPanel()
            }
        case .downArrow:
            if toolPanel == .picture {
                selectedPictureControl = (selectedPictureControl + 1) % 6
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
            } else if lockedSeekDirection != 0 {
                // Seek confirmation outranks toolbar focus on the same click.
                finishLockedSeek(commit: true, resumeWhenCommitted: true)
            } else if targetSeconds != nil {
                resumeAfterLockedSeek = false
                // A single center click accepts the thumbnail and starts playback.
                commitSeek(resumeAfter: true, closeChrome: true)
            } else if toolbarFocused {
                explicitChromeHidden = false
                openToolbarSelection()
            } else {
                explicitChromeHidden = false
                togglePlayback()
            }
        case .playPause:
            if toolPanel == .none {
                if lockedSeekDirection != 0 {
                    // In the locked seek menu, Play/Pause confirms the
                    // preview just like Select and resumes from that frame.
                    finishLockedSeek(commit: true, resumeWhenCommitted: true)
                } else if targetSeconds != nil {
                    // In paused touchpad/arrow thumbnail seeking, the
                    // playback button commits the highlighted time exactly
                    // once and resumes instead of merely dismissing preview.
                    resumeAfterLockedSeek = false
                    commitSeek(resumeAfter: true, closeChrome: true)
                } else if previewIsVisible {
                    // Don't resume at a stale position if a preview has not
                    // yet established a seek target.
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
        let wasPreviewPress = previewArrowPress
        let wasPreviewHold = previewArrowHoldStarted
        stopPreviewArrowHold()
        heldDirection = 0
        holdActivationTimer?.invalidate()
        holdActivationTimer = nil
        // The original hold-to-lock transport is unchanged outside preview.
        // Releasing a preview hold merely stops its repeat timer. Releasing
        // a short preview click steps one frame position (no movie seek).
        if lockedSeekDirection == 0 {
            if wasPreviewPress {
                if !wasPreviewHold { stepSeek(direction, commitAfterIdle: false) }
            } else {
                silentSkip(direction)
            }
        }
    }

    private func stopPreviewArrowHold() {
        previewArrowRepeatTimer?.invalidate()
        previewArrowRepeatTimer = nil
        if previewArrowPress {
            holdActivationTimer?.invalidate()
            holdActivationTimer = nil
            heldDirection = 0
        }
        previewArrowPress = false
        previewArrowHoldStarted = false
    }

    private func advanceHeldThumbnail(_ direction: Int) {
        guard previewArrowPress, previewArrowHoldStarted,
              heldDirection == direction, lockedSeekDirection == 0,
              targetSeconds != nil, core != nil else {
            stopPreviewArrowHold()
            return
        }
        // Reuse the manual click's 15-second preview step. The repeated
        // UI updates never seek mpv; only Select commits to actual playback.
        stepSeek(direction, commitAfterIdle: false)
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
            // Preserve the pre-existing locked FF/RW click and speed behavior
            // after a hold initiated outside the thumbnail menu.
            let base = targetSeconds ?? currentSeconds
            let bound = totalSeconds > 0 ? totalSeconds : 86_400
            targetSeconds = max(0, min(bound,
                base + Double(direction) * lockedClickSteps[lockedSpeedIndex]))
            scheduleFrames()
            refreshLabels()
            showPanel()
            return
        }
        if targetSeconds != nil && previewIsVisible {
            // In the existing thumbnail menu, a hold repeats preview steps
            // ONLY while physically held. Never call engageLockedSeek here.
            previewArrowPress = true
            previewArrowHoldStarted = false
            holdActivationTimer?.invalidate()
            holdActivationTimer = Timer.scheduledTimer(
                withTimeInterval: 0.47, repeats: false) { [weak self] _ in
                guard let self, self.previewArrowPress,
                      self.heldDirection == direction,
                      self.targetSeconds != nil, self.lockedSeekDirection == 0 else { return }
                self.holdActivationTimer = nil
                self.previewArrowHoldStarted = true
                self.advanceHeldThumbnail(direction)
                self.previewArrowRepeatTimer?.invalidate()
                self.previewArrowRepeatTimer = Timer.scheduledTimer(
                    withTimeInterval: 0.20, repeats: true) { [weak self] _ in
                    self?.advanceHeldThumbnail(direction)
                }
            }
            return
        }
        // No preview open: preserve the original hold-to-lock feature.
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
        if commit {
            resumeAfterLockedSeek = false
            commitSeek(resumeAfter: resumeWhenCommitted ?? restorePlayback,
                       closeChrome: true)
        } else {
            // Canceling restores the original position; hide after cancelling.
            resumeAfterLockedSeek = restorePlayback
            cancelUncommittedScrub()
            showPanel()
        }
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
            lastCacheLookupBucket = nil
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
        explicitChromeHidden = true
        hideTimer?.invalidate()
        toolbarFocused = false
        controlsVisible = false
        panel.isHidden = true
        statusLabel.isHidden = true
        stopShowingThumbnail()
        updateToolbarFocus()
    }

    private func cancelUncommittedScrub() {
        stopPreviewArrowHold()
        seekCommitTimer?.invalidate()
        seekCommitTimer = nil
        targetSeconds = nil
        circularSeekActive = false
        panStartedWhilePlaying = false
        let shouldResume = resumeAfterLockedSeek
        resumeAfterLockedSeek = false
        let wasUsingMainDecoder = mainFramePreviewOrigin != nil
        stopShowingThumbnail(resumeAfterRestore: shouldResume)
        PlayerStartupDiagnostics.clear()
        if shouldResume && !wasUsingMainDecoder {
            core?.setProperty("pause", value: "no")
            playing = true
        }
        refreshLabels()
    }

    private func stopShowingThumbnail(restoreMain: Bool = true,
                                      resumeAfterRestore: Bool = false) {
        stopPreviewArrowHold()
        mainFramePreviewGeneration += 1
        mainFramePreviewBusy = false
        mainFramePreviewAwaitingSeek = false
        mainFramePreviewPending = nil
        mainFramePreviewTarget = nil
        let origin = mainFramePreviewOrigin
        mainFramePreviewOrigin = nil
        if restoreMain, let origin, let playbackCore = core {
            mainFramePreviewRestoreTarget = origin
            mainFramePreviewResumeAfterRestore = resumeAfterRestore
            playbackCore.commandAsync(["seek",
                String(format: "%.3f", origin), "absolute"]) { [weak self] _ in
                // If the backend doesn't publish a playback-restart, never
                // trap the user behind a frozen frame indefinitely.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                    guard let self,
                          self.mainFramePreviewRestoreTarget == origin else { return }
                    self.finishNativePreviewRestore()
                }
            }
        } else if !restoreMain {
            // Commit seeks retain the cover until the selected frame appears.
        } else {
            frozenVideo.isHidden = true
            frozenVideo.image = nil
        }
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
        lastCacheLookupBucket = nil
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
        if toolPanel == .subtitles && choice.id == "permanent-subtitle-toggle" {
            let disable = !permanentlyDisableSubtitles
            UserDefaults.standard.set(disable, forKey: persistentSubtitlesKey)
            // Applies immediately, and the saved preference survives every
            // stream change and future app launches.
            core.setProperty("sid", value: disable ? "no" : "auto")
            closeToolPanel()
            return
        }
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

    private func subtitleMenuPrefix(selectedOff: Bool) -> [TrackChoice] {
        [
            TrackChoice(id: "no", caption: "Off (this video)", selected: selectedOff),
            TrackChoice(id: "permanent-subtitle-toggle",
                        caption: permanentlyDisableSubtitles
                            ? "Enable automatic subtitles for all videos"
                            : "Permanently disable subtitles for all videos",
                        selected: permanentlyDisableSubtitles)
        ]
    }

    private func loadTracks(request: Int) {
        guard let core else { return }
        let wanted: TrackKind = toolPanel == .audio ? .audio : .sub
        core.getPropertyAsync("track-list/count") { [weak self, weak core] result in
            guard let self, let core, self.core === core, self.trackRefreshID == request else { return }
            let count = min(96, max(0, Int((try? result.get()) ?? "") ?? 0))
            guard count > 0 else {
                self.trackChoices = wanted == .sub
                    ? self.subtitleMenuPrefix(selectedOff: true) : []
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
                    let hasSelected = values.contains {
                        $0["type"] == "sub" && $0["selected"] == "yes"
                    }
                    choices.append(contentsOf: self.subtitleMenuPrefix(selectedOff: !hasSelected))
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
            ("HDR transfer", "video-params/gamma"),
            ("HDR primaries", "video-params/primaries"),
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
            // DV is reported separately; the HDR line identifies the transfer
            // standard for non-DV HDR10/PQ and HLG files as well.
            let dvProfile = Int(values["Dolby Vision"] ?? "") ?? Int(core.doviProfile)
            let dv = dvProfile == 7 ? "Profile 7 → 8.1"
                : (dvProfile > 0 ? "Profile \(dvProfile)" : "No")
            let gamma = (values["HDR transfer"] ?? "").lowercased()
            let primaries = (values["HDR primaries"] ?? "").lowercased()
            let hdr: String
            if gamma.contains("arib") || gamma.contains("hlg") {
                hdr = "HLG" + (primaries.contains("2020") ? " · BT.2020" : "")
            } else if gamma.contains("smpte2084") || gamma.contains("pq") {
                hdr = dvProfile > 0 ? "PQ (Dolby Vision)" : "HDR10 / PQ"
            } else if dvProfile > 0 {
                hdr = "Dolby Vision (HDR)"
            } else if self.sourceColorMetadataReady && self.sourceIsHDR {
                hdr = "HDR (transfer unknown)"
            } else {
                hdr = gamma.isEmpty ? "Unknown" : "SDR"
            }
            let bitrate: String
            if let bps = Double(values["Video bitrate"] ?? ""),
               bps.isFinite, bps > 0 {
                bitrate = String(format: "%.2f Mbps", bps / 1_000_000)
            } else {
                bitrate = "Unknown"
            }
            self.infoRows = [
                "Video   " + (values["Video codec"] ?? "Unknown"),
                "Size    " + width + " × " + height,
                "Rate    " + fps,
                "DV      " + dv,
                "HDR     " + hdr,
                "Format  " + (values["Video format"] ?? "Unknown"),
                "Audio   " + (values["Audio codec"] ?? "Unknown"),
                "Bitrate " + bitrate
            ]
            self.renderTrackPanel()
        }
    }


    private func togglePlayback() {
        guard let core else { return }
        explicitChromeHidden = false
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

    private func commitSeek(resumeAfter: Bool = false,
                            retainPreview: Bool = false,
                            closeChrome: Bool = false) {
        stopPreviewArrowHold()
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
                self?.stopShowingThumbnail(restoreMain: false)
            }
        } else {
            stopShowingThumbnail(restoreMain: false)
        }
        if frozenVideo.image != nil && !frozenVideo.isHidden {
            mainFramePreviewRestoreTarget = seconds
            mainFramePreviewResumeAfterRestore = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let self, self.mainFramePreviewRestoreTarget == seconds else { return }
                self.finishNativePreviewRestore()
            }
        }
        if retainPreview {
            PlayerStartupDiagnostics.mark("touchpad-seek-commit")
        }
        if closeChrome {
            // Hide before async seek callbacks: they must not reopen controls.
            explicitChromeHidden = true
            toolbarFocused = false
            toolPanel = .none
            picturePanel.isHidden = true
            trackPanel.isHidden = true
            hideTimer?.invalidate()
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
        explicitChromeHidden = false
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

        // The preview grid stays at twelve seconds inside the fast-forward
        // menu too. Moving the cursor within a cell must not decode more frames.
        let slot = max(0, (Int(seconds.rounded()) / 12) * 12)
        if lastCacheLookupBucket != slot {
            lastCacheLookupBucket = slot
            if let hot = thumbs.cachedImage(second: slot) {
                frameViews.first?.image = hot
                lastPreviewImageSecond = slot
            } else {
                let serial = currentPreviewSerial
                thumbs.lookupCached(second: slot) { [weak self] image, foundSlot, exact in
                    guard let self, self.previewIsVisible,
                          self.currentPreviewSerial == serial,
                          let target = self.targetSeconds,
                          max(0, (Int(target.rounded()) / 12) * 12) == slot,
                          let image, let foundSlot else { return }
                    if exact || self.lastPreviewImageSecond != slot {
                        self.frameViews.first?.image = image
                        self.lastPreviewImageSecond = foundSlot
                    }
                }
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
            // Cached frames are equally quick for SDR, HDR and DV.
            // Native uncached HDR/DV seeks remain conservative.
            let selected = max(0, Int((targetSeconds ?? currentSeconds).rounded()))
            let isCached = thumbs.cachedImage(second: selected) != nil
            let cadence: TimeInterval = isCached ? 0.20 :
                (sourceColorMetadataReady && !sourceIsHDR
                 && !requiresNativeDolbyVision ? 0.48 : 0.95)
            interval = max(0.12, cadence - max(0, sincePrevious))
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
        let slot = max(0, (Int(targetSeconds.rounded()) / 12) * 12)
        if let cached = thumbs.cachedImage(second: slot) {
            frameViews.first?.image = cached
            lastPreviewImageSecond = slot
            lastPreviewRequestedBucket = slot
            return
        }
        // Nearby disk frames are already being loaded by scheduleFrames.
        // Never refine them to an exact cursor position or seek the main video.
        if thumbs.hasCachedFrameNear(second: slot) { return }
        guard lastPreviewRequestedBucket != slot else { return }
        lastPreviewRequestedBucket = slot
        if core?.doviProfile == 5 {
            // P5 has no HDR10-compatible base layer. The FFmpeg seek worker
            // can't reproduce Dolby's IPTPQc2 + RPU color mapping. Ask the
            // existing hardware decoder for a still, while paused, rather
            // than cache a dark/magenta corrupted FFmpeg JPEG.
            requestNativePreviewTarget(slot, serial: serial)
            return
        }
        thumbs.request(url: link.url, second: slot) { [weak self] image in
            guard let self, self.previewIsVisible,
                  self.currentPreviewSerial == serial,
                  self.link?.url == link.url,
                  let current = self.targetSeconds,
                  max(0, (Int(current.rounded()) / 12) * 12) == slot else { return }
            if let image {
                self.frameViews.first?.image = image
                self.lastPreviewImageSecond = slot
                self.filmStrip.alpha = 1
            }
            // Missing frames stay on the same sparse grid. No native-player
            // seek fallback: it was filling the cache with dense exact frames.
            self.previewLoadingLabel.isHidden = true
            self.previewStatusLabel.isHidden = true
        }
    }

    // MARK: - Native mpv single-decoder preview fallback
    //
    // AVFoundation cannot read MKV reliably. Rather than create the second
    // FFmpeg decoder that repeatedly crashed tvOS, use mpv's own screenshot
    // command on the EXISTING decoder. The original frame is frozen above
    // the movie while paused mpv seeks to candidate frames.
    private func takeMpvStill(allowSoftwareFallback: Bool = true,
                              _ completion: @escaping (UIImage?) -> Void) {
        guard let previewCore = core else { completion(nil); return }
        // This native player renders into AVSampleBufferDisplayLayer, not
        // vo=gpu-next. The normal mpv screenshot command often cannot read
        // that output. Apple's renderer provides the actual displayed
        // CVPixelBuffer; capture it without another demuxer or video decoder.
        if #available(tvOS 17.4, *),
           let buffer = previewCore.videoLayer?.sampleBufferRenderer.displayedPixelBuffer() {
            let context = thumbnailImageContext
            let isHDRPreview = sourceIsHDR || requiresNativeDolbyVision
            DispatchQueue.global(qos: .utility).async {
                let frame = CIImage(cvPixelBuffer: buffer)
                let longer = max(frame.extent.width, frame.extent.height)
                guard longer > 0 else {
                    DispatchQueue.main.async { [weak self] in
                        if allowSoftwareFallback { self?.takeMpvSoftwareStill(completion) }
                        else { completion(nil) }
                    }
                    return
                }
                let scale = min(1, 720.0 / longer)
                var reduced = frame.transformed(by: CGAffineTransform(
                    scaleX: scale, y: scale))
                // Tone-map the tiny screenshot copy into a real SDR output.
                // Neither the source CVPixelBuffer nor displayed DV frame
                // is changed; this work runs off the playback thread.
                if isHDRPreview, let tone = CIFilter(name: "CIToneMapHeadroom"),
                   tone.inputKeys.contains("inputTargetHeadroom") {
                    tone.setValue(reduced, forKey: kCIInputImageKey)
                    tone.setValue(8.0, forKey: "inputSourceHeadroom")
                    tone.setValue(1.0, forKey: "inputTargetHeadroom")
                    if let result = tone.outputImage { reduced = result }
                }
                let image: UIImage?
                let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
                if let cg = context.createCGImage(reduced, from: reduced.extent,
                                                  format: .RGBA8, colorSpace: srgb) {
                    image = UIImage(cgImage: cg)
                } else {
                    image = nil
                }
                DispatchQueue.main.async { [weak self] in
                    if let image {
                        completion(image)
                    } else {
                        // Some 10-bit/DV pixel buffers cannot be converted by
                        // CIImage on all tvOS models. Do not abandon a valid
                        // movie: try mpv's software framebuffer conversion.
                        if allowSoftwareFallback { self?.takeMpvSoftwareStill(completion) }
                        else { completion(nil) }
                    }
                }
            }
            return
        }

        if allowSoftwareFallback {
            PlayerStartupDiagnostics.mark("displayed-pixel-buffer-unavailable")
            takeMpvSoftwareStill(completion)
        } else {
            // Periodic caching must not trigger expensive software screenshots
            // or a 4K CPU copy when HDR/DV uses an inaccessible video layer.
            completion(nil)
        }
    }

    // A second capture route, NOT a second video decoder. mpv converts a
    // frame from the same codec instance when a displayed pixel buffer is
    // unavailable (for example, certain HDR hardware presentation modes).
    private func takeMpvSoftwareStill(_ completion: @escaping (UIImage?) -> Void) {
        guard let previewCore = core else { completion(nil); return }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuvio-preview-\(UUID().uuidString).jpg")
        previewCore.commandAsync(["screenshot-to-file", file.path, "video"]) {
            [weak self, weak previewCore] result in
            guard let self, let previewCore, self.core === previewCore else {
                try? FileManager.default.removeItem(at: file)
                return
            }
            DispatchQueue.global(qos: .utility).async {
                var image: UIImage?
                if case .success = result,
                   let source = CGImageSourceCreateWithURL(file as CFURL, nil) {
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 720,
                        kCGImageSourceShouldCacheImmediately: false
                    ]
                    if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0,
                        options as CFDictionary) {
                        image = UIImage(cgImage: cgImage)
                    }
                }
                try? FileManager.default.removeItem(at: file)
                DispatchQueue.main.async { completion(image) }
            }
        }
    }

    private func requestNativePreviewTarget(_ second: Int, serial: Int) {
        guard serial == currentPreviewSerial, previewIsVisible, targetSeconds != nil,
              core?.isPaused == true, !mainFramePreviewUnsupported,
              !waitingForFirstFrame, !displayNegotiationPending else { return }
        mainFramePreviewPending = second
        if mainFramePreviewBusy { return }
        if mainFramePreviewOrigin == nil {
            mainFramePreviewBusy = true
            let generation = mainFramePreviewGeneration
            let position = max(0, core?.timePos ?? currentSeconds)
            takeMpvStill { [weak self] image in
                guard let self, generation == self.mainFramePreviewGeneration,
                      self.previewIsVisible, self.targetSeconds != nil else { return }
                guard let image else {
                    // If this AVSampleBuffer VO has no screenshot support,
                    // don't seek the main movie or allow a hidden video jump.
                    self.mainFramePreviewUnsupported = true
                    self.mainFramePreviewBusy = false
                    PlayerStartupDiagnostics.mark("native-screenshot-not-supported")
                    return
                }
                self.mainFramePreviewOrigin = position
                self.frozenVideo.image = image
                self.frozenVideo.isHidden = false
                self.mainFramePreviewBusy = false
                self.continueNativePreview()
            }
        } else {
            continueNativePreview()
        }
    }

    private func continueNativePreview() {
        guard !mainFramePreviewBusy, let origin = mainFramePreviewOrigin,
              let desired = mainFramePreviewPending,
              previewIsVisible, targetSeconds != nil, let previewCore = core else { return }
        mainFramePreviewPending = nil
        mainFramePreviewBusy = true
        mainFramePreviewTarget = desired
        let generation = mainFramePreviewGeneration
        if abs((previewCore.timePos) - Double(desired)) <= 1.0 {
            captureNativePreviewTarget(desired, generation: generation)
            return
        }
        mainFramePreviewAwaitingSeek = true
        previewCore.commandAsync(["seek", String(format: "%.3f", Double(desired)),
                                  "absolute"]) { [weak self] result in
            guard let self, generation == self.mainFramePreviewGeneration else { return }
            if case .failure = result {
                self.mainFramePreviewAwaitingSeek = false
                self.mainFramePreviewBusy = false
                self.mainFramePreviewPending = nil
                self.abortNativePreviewToOrigin(origin)
            }
        }
        // Network streams may never emit playback-restart for a broken seek.
        // Do not leave the frame-capture state or frozen overlay stuck.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, generation == self.mainFramePreviewGeneration,
                  self.mainFramePreviewAwaitingSeek,
                  self.mainFramePreviewTarget == desired else { return }
            self.mainFramePreviewAwaitingSeek = false
            let measured = self.core?.timePos ?? -999
            if abs(measured - Double(desired)) <= 5 {
                self.captureNativePreviewTarget(desired, generation: generation)
            } else {
                self.mainFramePreviewBusy = false
                self.abortNativePreviewToOrigin(origin)
            }
        }
    }

    private func captureNativePreviewTarget(_ desired: Int, generation: Int) {
        guard generation == mainFramePreviewGeneration,
              mainFramePreviewBusy, previewIsVisible, let link else { return }
        mainFramePreviewAwaitingSeek = false
        takeMpvStill { [weak self] image in
            guard let self, generation == self.mainFramePreviewGeneration,
                  self.previewIsVisible else { return }
            if let image {
                self.thumbs.cachePlaybackFrame(
                    image, second: desired, automatic: false)
                let selected = max(0, (Int((self.targetSeconds ?? -1).rounded()) / 12) * 12)
                if selected == desired {
                    self.frameViews.first?.image = image
                    self.lastPreviewImageSecond = desired
                    self.filmStrip.alpha = 1
                }
                PlayerStartupDiagnostics.mark("native-preview-frame-ready")
            } else {
                self.mainFramePreviewUnsupported = true
                PlayerStartupDiagnostics.mark("native-preview-capture-unavailable")
            }
            self.mainFramePreviewBusy = false
            self.mainFramePreviewTarget = nil
            if self.mainFramePreviewUnsupported {
                if let original = self.mainFramePreviewOrigin {
                    self.abortNativePreviewToOrigin(original)
                }
            } else if self.link?.url == link.url {
                self.continueNativePreview()
            }
        }
    }

    private func abortNativePreviewToOrigin(_ origin: Double) {
        // Missing snapshot / seek support should never break normal playback.
        mainFramePreviewGeneration += 1
        mainFramePreviewPending = nil
        mainFramePreviewTarget = nil
        mainFramePreviewOrigin = nil
        mainFramePreviewBusy = false
        mainFramePreviewAwaitingSeek = false
        mainFramePreviewRestoreTarget = origin
        core?.commandAsync(["seek", String(format: "%.3f", origin), "absolute"]) {
            [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self, self.mainFramePreviewRestoreTarget == origin else { return }
                self.finishNativePreviewRestore()
            }
        }
    }

    private func finishNativePreviewRestore() {
        let resume = mainFramePreviewResumeAfterRestore
        mainFramePreviewResumeAfterRestore = false
        mainFramePreviewRestoreTarget = nil
        frozenVideo.isHidden = true
        frozenVideo.image = nil
        if resume {
            core?.setProperty("pause", value: "no")
            playing = true
            showPanel()
        }
    }

    private func leavePlayback() {
        stopPreviewArrowHold()
        NuvioFrameTapStop()
        frameTapInstalled = false
        playbackGeneration += 1
        isPreparingPlayback = false
        waitingForFirstFrame = false
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        subtitleURLToLoad = nil
        subtitleAlreadyRequested = false
        PlayerStartupDiagnostics.clear()
        colorFilterTimer?.invalidate()
        colorFilterTimer = nil
        colorFilterOperation += 1
        mainFramePreviewGeneration += 1
        mainFramePreviewOrigin = nil
        mainFramePreviewPending = nil
        mainFramePreviewRestoreTarget = nil
        mainFramePreviewBusy = false
        mainFramePreviewAwaitingSeek = false
        frozenVideo.isHidden = true
        frozenVideo.image = nil
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
        if explicitChromeHidden, core != nil {
            controlsVisible = false
            panel.isHidden = true
            progress.isHidden = true
            cachedTimeline.isHidden = true
            playbackPositionMarker.isHidden = true
            cacheRateLabel.isHidden = true
            currentLabel.isHidden = true
            endLabel.isHidden = true
            statusLabel.isHidden = true
            return
        }
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
        cachedTimeline.isHidden = !showTimeline
        playbackPositionMarker.isHidden = !showTimeline
        // Network/disk numbers belong to the paused or Down-opened control
        // surface; never leave a persistent overlay during normal playback.
        let showMetrics = core != nil && (!playing || toolbarFocused ||
            toolPanel != .none || lockedSeekDirection != 0 ||
            isTouchScrubbing || targetSeconds != nil)
        cacheRateLabel.isHidden = !showMetrics
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
        if toolPanel == .picture && requiresNativeDolbyVision &&
           Date().timeIntervalSince(lastDVProbeUIUpdate) >= 1.0 {
            lastDVProbeUIUpdate = Date()
            updatePictureLabels()
        }
        if !configuredNativeP5Preview, (core?.doviProfile ?? 0) == 5 {
            configuredNativeP5Preview = true
            thumbs.setNativeDolbyVisionOnly(true)
        }
        // DV profile information can arrive after the first frame, and an
        // experimental filter could temporarily alter output tags. As soon
        // as we ever detect DV in the source, latch it for the full movie
        // and unwind the CPU-copy filter before it can cause sustained lag.
        if !originalIsDolbyVision, (core?.doviProfile ?? 0) > 0 {
            originalIsDolbyVision = true
            sourceIsDolbyVision = true
            sourceIsHDR = true
            sourceColorMetadataReady = true
            experimentalHDRColorBoost = false
            colorEffectRequestedForVideo = false
            scheduleColorFilterUpdate()
            updatePictureLabels()
            NSLog("[NuvioColor] Dolby Vision detected; native playback enforced")
        }
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
        // Feed the active media timestamp into the renderer's decoded-frame
        // tap. Conversion runs on a private GPU queue and JPEGs write on the
        // existing serial cache writer. Nothing seeks or opens another codec.
        let playbackSecond = core?.timePos ?? -1
        // Refresh the active renderer identity after HDMI mode changes and
        // AVSampleBufferDisplayLayer flushes.  The previous swizzle could
        // monitor a stale renderer and silently receive zero samples.
        if frameTapInstalled, let layer = core?.videoLayer {
            NuvioFrameTapRefreshTargets(layer, layer.sampleBufferRenderer)
        }
        // Capture is tied to the stream's decoded video samples, NEVER to
        // the seek controls, overlay visibility, loading flags or a manually
        // maintained playback flag. Any of those UI flags can remain active
        // while tvOS continues presenting a normally advancing movie.
        // A paused player emits no continuous samples, so this does not
        // spin a decoder, poll a stream or create thumbnails while idle.
        let captureAllowed = frameTapInstalled && core != nil
            && playbackSecond.isFinite && playbackSecond >= 0
        NuvioFrameTapSetPlaybackSecond(captureAllowed
            ? Int64(playbackSecond) : -1)
        refreshLabels()
        // A service-owned loop generates future previews without depending
        // on control visibility, pause flags or progress of the scrub cursor.
        // Only the actual playback timestamp anchors the forward index.
        if let media = link, let playbackCore = core,
           !isPreparingPlayback && !waitingForFirstFrame &&
           !displayNegotiationPending && committedSeekTarget == nil {
            thumbs.updateAheadIndex(url: media.url,
                playback: playbackCore.timePos, duration: totalSeconds)
        } else {
            thumbs.pauseAheadIndex()
        }
        // Sample the separate media-cache, sparse range-cache and JPEG disk
        // writers once a second. Only actual writes count toward DISK MB/s.
        if Date().timeIntervalSince(lastCacheUIUpdate) >= 1.0 {
            lastCacheUIUpdate = Date()
            // This mpv property is the INPUT/network bytes per second,
            // not the tiny thumbnail JPEG write rate.
            if let playingCore = core {
                let expectedGeneration = playbackGeneration
                playingCore.getPropertyAsync("cache-speed") {
                    [weak self, weak playingCore] result in
                    guard let self, let playingCore,
                          self.core === playingCore,
                          self.playbackGeneration == expectedGeneration else { return }
                    if case .success(let raw) = result,
                       let raw, let bytesPerSecond = Double(raw) {
                        self.videoInputRateMbps = max(0, bytesPerSecond * 8 / 1_000_000)
                    }
                }
                // Temporary compressed media bytes saved in the same mpv
                // disk cache; preview JPEGs remain separate and persistent.
                playingCore.getPropertyAsync("demuxer-cache-state/file-cache-bytes") {
                    [weak self, weak playingCore] result in
                    guard let self, let playingCore,
                          self.core === playingCore,
                          self.playbackGeneration == expectedGeneration else { return }
                    if case .success(let raw) = result,
                       let raw, let bytes = Double(raw), bytes.isFinite {
                        let now = Date()
                        let size = max(0, bytes)
                        // The disk-cache byte count is sampled each second.
                        // Its positive growth gives measured disk fill MB/s,
                        // distinct from network INPUT Mb/s and preview JPEGs.
                        if let previous = self.videoDiskCacheBytes,
                           let previousAt = self.lastVideoDiskCacheSampleAt {
                            let elapsed = now.timeIntervalSince(previousAt)
                            if elapsed > 0.25 {
                                self.videoDiskWriteRateMBps = max(0, size - previous)
                                    / elapsed / 1_000_000
                            }
                        }
                        self.videoDiskCacheBytes = size
                        self.lastVideoDiskCacheSampleAt = now
                    }
                }
            }
            let videoText = videoInputRateMbps.map {
                String(format: "%.1f", $0)
            } ?? "—"
            // The separate native sparse range cache writes compressed
            // network video segments to .range files. Account for those real
            // bytes as well as mpv's (optional) file cache and saved JPEGs.
            let rangeBytes = nuvio_range_written_bytes()
            let sampledAt = Date()
            if let lastBytes = lastRangeCacheBytesWritten,
               let previousAt = lastRangeCacheSampleAt {
                let elapsed = sampledAt.timeIntervalSince(previousAt)
                if elapsed > 0.25 {
                    let growth = rangeBytes >= lastBytes
                        ? rangeBytes - lastBytes : 0
                    rangeCacheWriteRateMBps = Double(growth)
                        / elapsed / 1_000_000
                }
            }
            lastRangeCacheBytesWritten = rangeBytes
            lastRangeCacheSampleAt = sampledAt
            let stats = thumbs.cacheStats()
            let diskRate = max(0, videoDiskWriteRateMBps ?? 0)
                + max(0, stats.writeMBPerSecond)
                + rangeCacheWriteRateMBps
            let diskText = String(format: "%.3f", diskRate)
            cacheRateLabel.text = "VIDEO \(videoText) Mb/s  ·  DISK \(diskText) MB/s"
            // Keep cached-frame highlighting; omit all capture/decode/debug
            // counters from the user-facing playback overlay.
            cachedTimeline.durationSeconds = totalSeconds
            cachedTimeline.frameSlots = stats.slots
            cachedTimeline.setNeedsDisplay()
        }
    }

    /// Keep the center of the thumbnail above the progress playhead.
    /// The preview stays hidden during ordinary playback, as before, but
    /// its position remains in sync so it appears correctly on pause or
    /// locked/circular seeking without a jump from screen center.
    private func updateThumbnailHorizontalPosition() {
        guard let center = thumbnailCenterXConstraint,
              progress.bounds.width > 1, view.bounds.width > 0 else { return }

        let seconds = targetSeconds ?? currentSeconds
        let fraction: CGFloat
        if totalSeconds > 0, totalSeconds.isFinite, seconds.isFinite {
            fraction = CGFloat(min(1, max(0, seconds / totalSeconds)))
        } else {
            fraction = 0
        }
        // Place the vertical playhead directly on the real progress track,
        // including during thumbnail scrubs. Unlike the large preview image,
        // this narrow indicator does not need endpoint clamping.
        playbackMarkerXConstraint?.constant = progress.bounds.width * fraction
        // Convert points from the actual progress track to controller space.
        // A 0% seek sits at the track's start; 100% at its end.
        let start = progress.convert(CGPoint(x: progress.bounds.minX,
                                             y: progress.bounds.midY), to: view).x
        let end = progress.convert(CGPoint(x: progress.bounds.maxX,
                                           y: progress.bounds.midY), to: view).x
        let timelineX = start + (end - start) * fraction
        // At either extreme the large 604pt preview must not be cut off.
        let margin: CGFloat = 16
        let halfWidth = seekPreviewWidth / 2
        let minimum = halfWidth + margin
        let maximum = max(minimum, view.bounds.width - halfWidth - margin)
        let centeredX = min(maximum, max(minimum, timelineX))
        if abs(center.constant - centeredX) > 0.25 {
            center.constant = centeredX
        }
    }

    private func refreshLabels() {
        let seconds = targetSeconds ?? currentSeconds
        progress.progress = Float(max(0, min(1, totalSeconds > 0 ? seconds / totalSeconds : 0)))
        updateThumbnailHorizontalPosition()
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
        NuvioFrameTapStop()
        colorFilterTimer?.invalidate()
        core?.dispose()
    }
}
