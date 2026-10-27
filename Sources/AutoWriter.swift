import AppKit
import ApplicationServices
import Carbon
import SwiftUI

private let ink = Color(red: 0.13, green: 0.16, blue: 0.18)
private let accent = Color(red: 0.84, green: 0.29, blue: 0.16)
private let muted = Color(red: 0.46, green: 0.48, blue: 0.49)
private let canvas = Color(red: 0.96, green: 0.955, blue: 0.94)

enum WriterPhase { case ready, countdown, writing, paused, finished }

private struct CorrectionAnchor {
    let pid: pid_t
    let element: AXUIElement?
    var expectedLocation: Int
}

final class WriterModel: ObservableObject {
    @Published var text = "" { didSet { refreshSynonyms() } }
    @Published var speed = UserDefaults.standard.object(forKey: "speed") as? Double ?? 70 { didSet { saveSettings() } }
    @Published var delay = UserDefaults.standard.object(forKey: "delay") as? Int ?? 5 { didSet { saveSettings() } }
    @Published var varied = UserDefaults.standard.object(forKey: "varied") as? Bool ?? true { didSet { saveSettings() } }
    @Published var typosEnabled = UserDefaults.standard.object(forKey: "typosEnabled") as? Bool ?? false { didSet { saveSettings() } }
    @Published var typoFrequency = UserDefaults.standard.object(forKey: "typoFrequency") as? Double ?? 2 { didSet { saveSettings() } }
    @Published var synonymsEnabled = UserDefaults.standard.object(forKey: "synonymsEnabled") as? Bool ?? false {
        didSet { refreshSynonyms(); saveSettings() }
    }
    @Published var synonymPercent = UserDefaults.standard.object(forKey: "synonymPercent") as? Double ?? 2 {
        didSet { refreshSynonyms(); saveSettings() }
    }
    @Published private(set) var synonymResult = SynonymResult.empty
    @Published var expandTabs = UserDefaults.standard.object(forKey: "expandTabs") as? Bool ?? true { didSet { saveSettings() } }
    @Published var lineBreak = LineBreakMode(rawValue: UserDefaults.standard.string(forKey: "lineBreak") ?? "") ?? .soft { didSet { saveSettings() } }
    @Published var phase: WriterPhase = .ready
    @Published var status = "Paste your text to get started."
    @Published var countdown = 0
    @Published var sent = 0
    @Published var total = 0
    @Published var hasPermission = AXIsProcessTrusted()

    private var cursor: WritingCursor?
    private var timer: Timer?
    private var generation = 0
    private var targetPID: pid_t?
    private var targetElement: AXUIElement?
    private var correctionAnchor: CorrectionAnchor?
    private var practice = false
    private var practiceWindow: NSWindow?
    private var practiceTextView: NSTextView?
    private let eventSource = CGEventSource(stateID: .privateState)
    private var synonymSeed = UInt64.random(in: UInt64.min...UInt64.max)

    var active: Bool { phase == .countdown || phase == .writing || phase == .paused }
    var running: Bool { phase == .countdown || phase == .writing }
    var progress: Double { total == 0 ? 0 : Double(sent) / Double(total) }
    var words: Int { synonymResult.wordCount }
    var typingText: String { synonymsEnabled ? synonymResult.text : text }
    var synonymSummary: String {
        if text.isEmpty { return "Paste some English text to preview word swaps." }
        if synonymPercent == 0 { return "0% selected. Your words will stay unchanged." }
        if synonymResult.requestedCount == 0 { return "This passage is too short for a swap at \(Int(synonymPercent))%." }
        if synonymResult.changes.isEmpty { return "No suitable synonyms found. Your words will stay unchanged." }
        let count = synonymResult.changes.count
        let summary = "\(count) of \(words) words will change (\(synonymResult.actualPercentage.formatted(.number.precision(.fractionLength(1))))%)."
        return count < synonymResult.requestedCount ? summary + " Fewer suitable words than the target." : summary
    }

    private func refreshSynonyms() {
        synonymResult = SynonymEngine.rewrite(text, percentage: synonymsEnabled ? synonymPercent : 0, seed: synonymSeed)
        if phase == .finished {
            phase = .ready
            sent = 0
            total = 0
            status = "Text updated. Ready when you are."
        }
    }

    func shuffleSynonyms() {
        guard !active else { return }
        synonymSeed = UInt64.random(in: UInt64.min...UInt64.max)
        refreshSynonyms()
    }

    var estimatedSeconds: Int {
        let plan = WritingPlan(text: typingText, expandTabs: expandTabs)
        let correctionTime = typosEnabled ? Double(plan.tokens.filter {
            NearbyKeyTypo.replacement(for: $0, choice: 0) != nil
        }.count) * typoFrequency / 100 * 0.45 : 0
        return Int(ceil(Double(plan.tokens.count) * WritingPlan.interval(wordsPerMinute: speed, varied: false, randomUnit: 0.5) + correctionTime))
    }

    func refreshPermission() { hasPermission = AXIsProcessTrusted() }

    func enablePermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        hasPermission = AXIsProcessTrustedWithOptions(options)
        if !hasPermission {
            status = "Enable Auto Writer in Accessibility, then come back."
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(speed, forKey: "speed")
        defaults.set(delay, forKey: "delay")
        defaults.set(varied, forKey: "varied")
        defaults.set(typosEnabled, forKey: "typosEnabled")
        defaults.set(typoFrequency, forKey: "typoFrequency")
        defaults.set(synonymsEnabled, forKey: "synonymsEnabled")
        defaults.set(synonymPercent, forKey: "synonymPercent")
        defaults.set(expandTabs, forKey: "expandTabs")
        defaults.set(lineBreak.rawValue, forKey: "lineBreak")
    }

    func start(inPractice: Bool = false) {
        guard !running else { return }
        refreshPermission()
        guard hasPermission else {
            status = "Allow Accessibility below so Auto Writer can type."
            return
        }
        guard !text.isEmpty else { status = "Paste or enter some text first."; return }
        saveSettings()
        practice = inPractice
        correctionAnchor = nil
        cursor = WritingCursor(plan: WritingPlan(text: typingText, expandTabs: expandTabs))
        sent = 0
        total = cursor?.plan.tokens.count ?? 0
        if inPractice { showPractice() }
        beginCountdown()
    }

    func togglePause() {
        if running { pause("Paused. Resume when you’re ready.") }
        else if phase == .paused {
            refreshPermission()
            guard hasPermission else { stop(message: "Accessibility permission is needed to continue."); return }
            cursor?.resume()
            if practice { showPractice() }
            beginCountdown()
        }
    }

    func stop(message: String? = nil) {
        let interruptedCorrection = cursor?.correction != nil
        invalidateTimer()
        cursor?.stop()
        phase = .ready
        countdown = 0
        targetPID = nil
        targetElement = nil
        correctionAnchor = nil
        status = message ?? (interruptedCorrection ? "Stopped during a correction. Check the last letter in your destination." : "Stopped. You can start again anytime.")
    }

    private func pause(_ message: String) {
        invalidateTimer()
        cursor?.pause()
        phase = .paused
        countdown = 0
        status = message
    }

    private func invalidateTimer() {
        generation += 1
        timer?.invalidate()
        timer = nil
    }

    private func schedule(after interval: TimeInterval, action: @escaping () -> Void) {
        let expectedGeneration = generation
        let nextTimer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, self.generation == expectedGeneration else { return }
            action()
        }
        timer = nextTimer
        RunLoop.main.add(nextTimer, forMode: .common)
    }

    private func beginCountdown() {
        invalidateTimer()
        targetPID = nil
        targetElement = nil
        countdown = delay
        phase = .countdown
        let deadline = Date().addingTimeInterval(Double(delay))
        status = practice ? "Click in the practice area. Typing starts shortly." : "Switch to your app and click where you want to type."
        countdownTick(deadline)
    }

    private func countdownTick(_ deadline: Date) {
        countdown = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
        if countdown == 0 { captureTarget(); return }
        schedule(after: 0.1) { [weak self] in self?.countdownTick(deadline) }
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private func isSecure(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
        return role as? String == "AXSecureTextField"
    }

    private func correctPracticeFocus() -> Bool {
        guard let window = practiceWindow, let view = practiceTextView else { return false }
        return NSApp.keyWindow === window && window.firstResponder === view
    }

    private func selectionRange() -> NSRange? {
        if practice { return correctPracticeFocus() ? practiceTextView?.selectedRange() : nil }
        guard let element = targetElement else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func matchesCorrectionTarget() -> Bool {
        guard let anchor = correctionAnchor else { return true }
        guard targetPID == anchor.pid else { return false }
        if practice { return correctPracticeFocus() }
        guard let original = anchor.element, let current = targetElement else { return false }
        return CFEqual(original, current)
    }

    private func captureTarget() {
        guard let app = NSWorkspace.shared.frontmostApplication else { pause("Choose a destination app, then resume."); return }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier && !(practice && correctPracticeFocus()) {
            pause("Choose another app, then resume. Or stop and try the practice area.")
            return
        }
        if practice && !correctPracticeFocus() { pause("Click the practice text area, then resume."); return }
        targetPID = app.processIdentifier
        targetElement = practice ? nil : focusedElement(pid: app.processIdentifier)
        guard matchesCorrectionTarget() else {
            pause("Return to the original text field, then resume to finish the correction.")
            return
        }
        guard !isSecure(targetElement) else { pause("Choose a regular text field, then resume."); return }
        phase = .writing
        status = "Typing into \(practice ? "the practice area" : app.localizedName ?? "your app")…"
        typeNext()
    }

    private func typeNext() {
        guard phase == .writing, cursor?.next != nil else { return }
        guard AXIsProcessTrusted() else { stop(message: "Accessibility permission was removed. Enable it to continue."); refreshPermission(); return }
        guard let targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            pause("App changed. Paused to keep your text in the right place."); return
        }
        if practice {
            guard correctPracticeFocus() else { pause("Practice focus changed. Resume to continue."); return }
        } else {
            let currentElement = focusedElement(pid: targetPID)
            if isSecure(currentElement) { pause("Typing paused in a password field."); return }
            if let original = targetElement, currentElement.map({ !CFEqual(original, $0) }) ?? true {
                pause("Text field changed. Resume to choose your destination again."); return
            }
        }
        let selection = selectionRange()
        if let anchor = correctionAnchor {
            guard matchesCorrectionTarget(), let selection,
                  selection.length == 0, selection.location == anchor.expectedLocation else {
                stop(message: "Cursor moved during a correction. Check the last letter before starting again.")
                return
            }
        }
        guard let action = cursor?.nextAction(typosEnabled: typosEnabled && selection != nil,
                                               errorRate: typoFrequency / 100,
                                               chance: Double.random(in: 0..<1),
                                               neighborChoice: Double.random(in: 0..<1)) else { return }
        guard post(action.token) else { stop(message: "Couldn’t create a keyboard event. Please start again."); return }
        cursor?.delivered(action)
        switch action {
        case .mistype:
            if let selection {
                correctionAnchor = CorrectionAnchor(pid: targetPID, element: targetElement, expectedLocation: selection.location + 1)
            }
        case .backspace: correctionAnchor?.expectedLocation -= 1
        case .write: correctionAnchor = nil
        }
        sent = cursor?.position ?? 0
        if cursor?.isComplete == true {
            invalidateTimer()
            phase = .finished
            status = "All done. \(sent.formatted()) characters typed."
            NSSound(named: .init("Pop"))?.play()
        } else {
            let interval: TimeInterval
            switch action {
            case .mistype: interval = Double.random(in: 0.25...0.55)
            case .backspace: interval = Double.random(in: 0.05...0.10)
            case .write: interval = WritingPlan.interval(wordsPerMinute: speed, varied: varied, randomUnit: Double.random(in: 0...1))
            }
            schedule(after: interval) { [weak self] in self?.typeNext() }
        }
    }

    private func post(_ token: WritingToken) -> Bool {
        let key: CGKeyCode
        let flags: CGEventFlags
        switch token {
        case .lineBreak: key = 36; flags = lineBreak == .soft ? .maskShift : []
        case .tab: key = 48; flags = []
        case .backspace: key = 51; flags = []
        case .text: key = 0; flags = []
        }
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        if case .text(let units) = token {
            units.withUnsafeBufferPointer { buffer in
                if let address = buffer.baseAddress {
                    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: address)
                    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: address)
                }
            }
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    func paste() {
        if let value = NSPasteboard.general.string(forType: .string) { text = value; status = "Text pasted. Choose your pace, then start." }
        else { status = "Your clipboard doesn’t contain text." }
    }

    func showPractice() {
        if practiceWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 380),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Auto Writer · Practice area"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 400, height: 260)
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            let view = NSTextView(frame: scroll.bounds)
            view.isRichText = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
            view.textContainerInset = NSSize(width: 24, height: 24)
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            scroll.documentView = view
            window.contentView?.addSubview(scroll)
            window.center()
            practiceWindow = window
            practiceTextView = view
        }
        practiceWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        practiceWindow?.makeFirstResponder(practiceTextView)
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(24).background(.white).clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(ink.opacity(0.07), lineWidth: 1))
    }
}

struct AutoWriterView: View {
    @ObservedObject var model: WriterModel
    @State private var showClearConfirmation = false
    @State private var showSynonymPreview = false

    private var duration: String {
        let seconds = model.estimatedSeconds
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
    private var phaseLabel: String {
        switch model.phase {
        case .ready: return "Ready when you are"
        case .countdown: return "Starting in \(model.countdown)s"
        case .writing: return "Writing in progress"
        case .paused: return "Paused"
        case .finished: return "Writing complete"
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 13) {
                Image(systemName: "character.cursor.ibeam").font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.white).frame(width: 52, height: 52)
                    .background(accent, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto Writer").font(.system(size: 25, weight: .semibold, design: .rounded)).foregroundStyle(ink)
                    Text("Your words, at your pace.").font(.system(size: 13)).foregroundStyle(muted)
                }
                Spacer()
                HStack(spacing: 7) {
                    Circle().fill(model.hasPermission ? Color.green.opacity(0.8) : accent).frame(width: 7, height: 7)
                    Text(model.hasPermission ? "Ready to type" : "Setup needed").font(.system(size: 12, weight: .medium))
                }.padding(.horizontal, 12).padding(.vertical, 9).background(.white.opacity(0.8), in: Capsule())
            }
            HStack(alignment: .top, spacing: 20) {
                Panel {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text("Your text").font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                            Spacer()
                            if model.synonymsEnabled {
                                Button { showSynonymPreview = true } label: {
                                    Label("Preview swaps", systemImage: "arrow.left.arrow.right")
                                }.buttonStyle(.bordered).disabled(model.active)
                            }
                            Button { model.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                                .buttonStyle(.bordered).disabled(model.active).help("Paste text from your clipboard")
                            Button { showClearConfirmation = true } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).foregroundStyle(muted)
                                .disabled(model.active || model.text.isEmpty).help("Clear text")
                        }
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $model.text)
                                .font(.system(size: 15, design: .monospaced))
                                .lineSpacing(5).scrollContentBackground(.hidden)
                                .padding(12).disabled(model.active)
                                .accessibilityLabel("Text to type")
                            if model.text.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Drop your words here.").font(.system(size: 20, weight: .medium, design: .rounded)).foregroundStyle(ink.opacity(0.55))
                                    Text("Paste a message, a paragraph, or a whole document.\nAuto Writer will type it into the app you choose.")
                                        .font(.system(size: 13)).lineSpacing(5).foregroundStyle(muted)
                                }.padding(20).allowsHitTesting(false)
                            }
                        }
                        .frame(minHeight: 260, maxHeight: .infinity)
                        .background(canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ink.opacity(0.06)))
                        HStack(spacing: 18) {
                            Text("\(model.text.count.formatted()) characters")
                            Text("\(model.words.formatted()) words")
                            Spacer()
                            Label("~\(duration)", systemImage: "clock")
                        }.font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                        if model.synonymsEnabled {
                            Text(model.synonymSummary).font(.system(size: 11)).foregroundStyle(accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider().opacity(0.5)
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: model.phase == .finished ? "checkmark.circle.fill" : model.phase == .paused ? "pause.circle.fill" : "arrow.up.forward.app")
                                .font(.system(size: 20)).foregroundStyle(accent).frame(width: 25)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(phaseLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                                Text(model.status).font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            if model.active || model.phase == .finished {
                                Text("\(Int(model.progress * 100))%")
                                    .font(.system(size: 17, weight: .medium, design: .monospaced)).foregroundStyle(accent)
                            }
                        }.frame(minHeight: 47, alignment: .top)
                        if model.active || model.phase == .finished {
                            ProgressView(value: model.progress).tint(accent).accessibilityLabel("Typing progress")
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 16) {
                    Panel {
                        ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Make it your pace").font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .firstTextBaseline, spacing: 5) {
                                    Text("\(Int(model.speed))").font(.system(size: 38, weight: .medium, design: .rounded)).foregroundStyle(ink)
                                    Text("words / min").font(.system(size: 12)).foregroundStyle(muted)
                                }
                                Slider(value: $model.speed, in: 20...240, step: 5).tint(accent).accessibilityLabel("Typing speed")
                                HStack(spacing: 7) {
                                    paceButton("Relaxed", speed: 35)
                                    paceButton("Steady", speed: 70)
                                    paceButton("Quick", speed: 140)
                                }
                            }
                            Divider().opacity(0.5)
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label("Start delay", systemImage: "timer").font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Picker("Start delay", selection: $model.delay) {
                                        ForEach([3, 5, 10, 15], id: \.self) { Text("\($0) seconds").tag($0) }
                                    }.labelsHidden().frame(width: 105)
                                }
                                Text("Time to switch apps and place your cursor.").font(.system(size: 11)).foregroundStyle(muted)
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Swap similar words", isOn: $model.synonymsEnabled)
                                    .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
                                if model.synonymsEnabled {
                                    HStack {
                                        Text("\(Int(model.synonymPercent))% of words")
                                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                                        Spacer()
                                        Stepper("Word swap percentage", value: $model.synonymPercent, in: 0...20, step: 1)
                                            .labelsHidden().controlSize(.small)
                                    }
                                    Slider(value: $model.synonymPercent, in: 0...20, step: 1)
                                        .accessibilityLabel("Percentage of words to swap").tint(accent)
                                    Text("English synonyms. Review the meaning in Preview swaps.")
                                        .font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Toggle("Vary the rhythm", isOn: $model.varied).font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Make & correct typos", isOn: $model.typosEnabled)
                                    .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
                                if model.typosEnabled {
                                    HStack {
                                        Text("Frequency").font(.system(size: 11)).foregroundStyle(muted)
                                        Spacer()
                                        Picker("Typo frequency", selection: $model.typoFrequency) {
                                            Text("Rare · 1%").tag(1.0)
                                            Text("Occasional · 2%").tag(2.0)
                                            Text("Frequent · 5%").tag(5.0)
                                        }.labelsHidden().frame(width: 165)
                                    }
                                    Text("A nearby wrong letter, then backspace and a quick correction.")
                                        .font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Toggle("Turn tabs into 4 spaces", isOn: $model.expandTabs).font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Line breaks").font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Picker("Line breaks", selection: $model.lineBreak) {
                                        ForEach(LineBreakMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                    }.labelsHidden().frame(width: 130)
                                }
                                Text(model.lineBreak == .soft ? "Shift + Return adds a line in most chat apps." : "Return may send a message in chat apps.")
                                    .font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }.disabled(model.active)
                        }
                    }
                    Button {
                        if model.active { model.togglePause() } else { model.start() }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: model.running ? "pause.fill" : "play.fill")
                            Text(model.running ? "Pause writing" : model.phase == .paused ? "Resume writing" : "Start writing")
                        }.font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 15)
                    }.buttonStyle(.plain).foregroundStyle(.white).background(accent, in: RoundedRectangle(cornerRadius: 12))
                        .disabled(!model.active && model.text.isEmpty).opacity(!model.active && model.text.isEmpty ? 0.5 : 1)
                    if model.active {
                        Button { model.stop() } label: { Label("Stop writing", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).controlSize(.large)
                    } else {
                        Button { model.start(inPractice: true) } label: { Label("Try in practice area", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                            .disabled(model.text.isEmpty)
                    }
                }.frame(width: 300)
            }
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").font(.system(size: 12))
                Text("Private by design. Your text stays on this Mac.")
                Spacer()
                Text("Pause / resume  ⌃⌥P").padding(.trailing, 12)
                Text("Stop anytime  ⌃⌥Esc").foregroundStyle(ink)
            }.font(.system(size: 11)).foregroundStyle(muted)
            if !model.hasPermission {
                HStack(spacing: 12) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("One quick setup").font(.system(size: 12, weight: .semibold))
                        Text("macOS needs your permission to type into other apps.").font(.system(size: 11)).foregroundStyle(muted)
                    }
                    Spacer()
                    Button("Enable Accessibility") { model.enablePermission() }.buttonStyle(.borderedProminent).tint(accent)
                }.padding(14).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(28).background(canvas).frame(minWidth: 920, minHeight: 690)
        .preferredColorScheme(.light).tint(accent)
        .sheet(isPresented: $showSynonymPreview) { SynonymPreviewView(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermission() }
        .confirmationDialog("Clear your text?", isPresented: $showClearConfirmation) {
            Button("Clear text", role: .destructive) { model.text = ""; model.stop(message: "Paste your text to get started.") }
        } message: { Text("This removes the text from Auto Writer.") }
    }

    private func paceButton(_ title: String, speed: Double) -> some View {
        Button { model.speed = speed } label: {
            Text(title).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(model.speed == speed ? accent.opacity(0.1) : canvas, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(model.speed == speed ? accent : muted)
        }.buttonStyle(.plain)
    }
}

struct SynonymPreviewView: View {
    @ObservedObject var model: WriterModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preview word swaps").font(.system(size: 23, weight: .semibold, design: .rounded)).foregroundStyle(ink)
            Text("Suggested synonyms can differ in context. Check the meaning before typing.")
                .font(.system(size: 12)).foregroundStyle(muted)
            Text(model.synonymSummary).font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Text that will be typed").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                    ScrollView {
                        Text(model.typingText.isEmpty ? "Your preview will appear here." : model.typingText)
                            .font(.system(size: 14, design: .monospaced)).lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Changes").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if model.synonymResult.changes.isEmpty {
                                Text("No changes to review.").font(.system(size: 12)).foregroundStyle(muted)
                            }
                            ForEach(model.synonymResult.changes) { change in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(change.original).strikethrough().foregroundStyle(muted)
                                    Label(change.replacement, systemImage: "arrow.turn.down.right").foregroundStyle(accent)
                                }.font(.system(size: 12))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }.frame(maxHeight: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }.frame(width: 185)
            }.frame(maxHeight: .infinity)
            HStack {
                Text("Your original stays unchanged. Typing uses this exact preview.").font(.system(size: 11)).foregroundStyle(muted)
                Spacer()
                Button("Shuffle swaps") { model.shuffleSynonyms() }
                    .disabled(model.active || model.synonymResult.changes.isEmpty)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 760, height: 590).background(canvas).preferredColorScheme(.light)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = WriterModel()
    private var window: NSWindow?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let content = NSHostingView(rootView: AutoWriterView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Auto Writer"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.96, green: 0.955, blue: 0.94, alpha: 1)
        window.contentView = content
        window.minSize = NSSize(width: 920, height: 740)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        installMenus()
        installHotKeys()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Auto Writer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Auto Writer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = menu

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Auto Writer")
        let statusMenu = NSMenu()
        let show = statusMenu.addItem(withTitle: "Show Auto Writer", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        let pause = statusMenu.addItem(withTitle: "Pause / Resume     ⌃⌥P", action: #selector(pauseWriting), keyEquivalent: "")
        pause.target = self
        let stop = statusMenu.addItem(withTitle: "Stop writing     ⌃⌥Esc", action: #selector(stopWriting), keyEquivalent: "")
        stop.target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit Auto Writer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = statusMenu
        statusItem = item
    }

    private func installHotKeys() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let app = Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue()
            if id.id == 1 { app.model.stop() }
            else if id.id == 2 { app.model.togglePause() }
            return noErr
        }, 1, &type, pointer, &eventHandler)
        for (id, key) in [(UInt32(1), UInt32(kVK_Escape)), (UInt32(2), UInt32(kVK_ANSI_P))] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(key, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x41575452, id: id),
                                             GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { hotKeyRefs.append(reference) }
            else { model.status = "A shortcut is already in use. Stop is also available in the menu bar." }
        }
    }

    @objc private func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func pauseWriting() { model.togglePause() }
    @objc private func stopWriting() { model.stop() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.stop(message: "Stopped when the window closed.")
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        for reference in hotKeyRefs { UnregisterEventHotKey(reference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

@main
struct AutoWriterMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
