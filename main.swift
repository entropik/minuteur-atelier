// Minuteur Atelier — Panneau flottant macOS (Minuteur, Chrono, Pomodoro)
// Copyright (C) 2026 ooblik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.

import AppKit
import UserNotifications

// MARK: - Modèle (3 compteurs indépendants et persistants en parallèle)

final class MinuteurModel {
    enum Mode: Int, CaseIterable {
        case countdown = 0
        case stopwatch = 1
        case pomodoro = 2
    }

    enum PomodoroPhase: Int {
        case work = 0
        case shortBreak = 1
        case longBreak = 2
    }

    struct Pomodoro {
        static let work: TimeInterval = 25 * 60
        static let shortBreak: TimeInterval = 5 * 60
        static let longBreak: TimeInterval = 15 * 60
        static let cycles = 4
    }

    /// État indépendant d'un des 3 modes (Minuteur, Chrono ou Tomate).
    private struct TrackState {
        var running = false
        var stored: TimeInterval
        var anchor: Date?
        var sessionStart: Date?

        func currentValue(isCountdown: Bool, now: Date = Date()) -> TimeInterval {
            guard running, let anchor else { return stored }
            let delta = now.timeIntervalSince(anchor)
            return isCountdown ? max(0, stored - delta) : stored + delta
        }
    }

    private(set) var mode: Mode = .countdown
    private(set) var countdownDuration: TimeInterval = 10 * 60
    private(set) var pomodoroPhase: PomodoroPhase = .work
    /// Pomodoros terminés dans le cycle en cours (remis à zéro après la pause longue).
    private(set) var pomodoroCount = 0

    /// Libellé de séance saisi par l'utilisateur, tracé dans les relevés.
    var taskLabel: String = ""

    private let pomodoroWork: TimeInterval
    private let pomodoroShortBreak: TimeInterval
    private let pomodoroLongBreak: TimeInterval
    private let persistsState: Bool

    private var tracks: [Mode: TrackState]

    init(
        pomodoroWork: TimeInterval = Pomodoro.work,
        pomodoroShortBreak: TimeInterval = Pomodoro.shortBreak,
        pomodoroLongBreak: TimeInterval = Pomodoro.longBreak,
        persistsState: Bool = false
    ) {
        self.pomodoroWork = pomodoroWork
        self.pomodoroShortBreak = pomodoroShortBreak
        self.pomodoroLongBreak = pomodoroLongBreak
        self.persistsState = persistsState
        self.tracks = [
            .countdown: TrackState(stored: 10 * 60),
            .stopwatch: TrackState(stored: 0),
            .pomodoro: TrackState(stored: pomodoroWork),
        ]
        if persistsState {
            restoreFromDefaults()
        }
    }

    var running: Bool { tracks[mode]?.running ?? false }

    var value: TimeInterval { value(for: mode) }

    func value(for target: Mode) -> TimeInterval {
        tracks[target]?.currentValue(isCountdown: target != .stopwatch) ?? 0
    }

    func isRunning(_ target: Mode) -> Bool {
        tracks[target]?.running ?? false
    }

    var isFinished: Bool { mode != .stopwatch && value <= 0 }

    /// Bascule l'affichage sur un mode SANS arrêter ni réinitialiser les autres modes en cours.
    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        saveToDefaults()
    }

    func setPreset(minutes: Double) {
        stopAndReset(target: .countdown)
        mode = .countdown
        countdownDuration = minutes * 60
        tracks[.countdown]?.stored = countdownDuration
        saveToDefaults()
    }

    /// Ajuste la durée du Minuteur (uniquement quand il est à l'arrêt) par incrément de `deltaSeconds`.
    func adjustCountdown(bySeconds deltaSeconds: TimeInterval) {
        guard mode == .countdown, !(tracks[.countdown]?.running ?? false) else { return }
        let current = tracks[.countdown]?.stored ?? countdownDuration
        let base = current > 0 ? current : countdownDuration
        let clamped = min(max(10, base + deltaSeconds), 12 * 3600)
        countdownDuration = clamped
        tracks[.countdown]?.stored = clamped
        saveToDefaults()
    }

    func start() {
        start(target: mode)
    }

    func start(target: Mode) {
        guard var track = tracks[target], !track.running else { return }
        if target != .stopwatch, track.stored <= 0 {
            track.stored = startValue(for: target)
        }
        let now = Date()
        track.anchor = now
        track.sessionStart = now
        track.running = true
        tracks[target] = track
        saveToDefaults()
    }

    func pause() {
        pause(target: mode)
    }

    func pause(target: Mode) {
        // Méthode Pomodoro stricte : un Pomodoro est indivisible, pas de pause en mode Tomate.
        guard target != .pomodoro else { return }
        guard var track = tracks[target], track.running else { return }
        let now = Date()
        track.stored = track.currentValue(isCountdown: target != .stopwatch, now: now)
        track.running = false
        track.anchor = nil
        let startedAt = track.sessionStart
        track.sessionStart = nil
        tracks[target] = track
        logSession(target: target, start: startedAt, end: now)
        saveToDefaults()
    }

    func toggle() {
        if mode == .pomodoro {
            if !running { start() }
            return
        }
        running ? pause() : start()
    }

    func reset() {
        stopAndReset(target: mode)
    }

    /// Arrête la course du mode ciblé et remet son compteur à son départ.
    /// En Minuteur et Chrono, journalise le temps mesuré.
    /// En Tomate, une interruption avec `↺` annule le Pomodoro (indivisible -> non compté).
    func stopAndReset(target: Mode? = nil) {
        let m = target ?? mode
        guard var track = tracks[m] else { return }
        let now = Date()
        if track.running {
            track.stored = track.currentValue(isCountdown: m != .stopwatch, now: now)
            track.running = false
            track.anchor = nil
        }
        let startedAt = track.sessionStart
        track.sessionStart = nil
        if m == .pomodoro {
            pomodoroPhase = .work
        } else {
            logSession(target: m, start: startedAt, end: now)
        }
        track.stored = startValue(for: m)
        tracks[m] = track
        saveToDefaults()
    }

    /// Événement de fin de compte à rebours détecté par `tick()`.
    struct TickEvent {
        let title: String
        let body: String
    }

    /// Appelée par le rafraîchissement : fait avancer TOUS les compteurs actifs en parallèle
    /// (Minuteur et Tomate continuent même quand on consulte un autre onglet).
    /// Retourne vrai si au moins un compte à rebours vient de finir.
    private(set) var lastTickEvents: [TickEvent] = []

    func tick() -> Bool {
        lastTickEvents.removeAll()
        let now = Date()

        // 1. Minuteur classique
        if var cd = tracks[.countdown], cd.running, cd.currentValue(isCountdown: true, now: now) <= 0 {
            cd.running = false
            cd.anchor = nil
            cd.stored = 0
            let startedAt = cd.sessionStart
            cd.sessionStart = nil
            tracks[.countdown] = cd
            logSession(target: .countdown, start: startedAt, end: now)
            lastTickEvents.append(TickEvent(title: "Minuteur terminé", body: "Le compte à rebours est arrivé à zéro."))
        }

        // 2. Tomate (Pomodoro) — tourne et enchaîne ses phases même en arrière-plan
        if var pm = tracks[.pomodoro], pm.running, pm.currentValue(isCountdown: true, now: now) <= 0 {
            let finishedWork = (pomodoroPhase == .work)
            pm.running = false
            pm.anchor = nil
            pm.stored = 0
            let startedAt = pm.sessionStart
            pm.sessionStart = nil
            tracks[.pomodoro] = pm
            logSession(target: .pomodoro, start: startedAt, end: now)
            advancePomodoroPhase(at: now)
            if finishedWork {
                let breakDesc = pomodoroPhase == .longBreak ? "Pause longue (15 min)" : "Pause courte (5 min)"
                let suffix = taskLabel.isEmpty ? "" : " · \(taskLabel)"
                lastTickEvents.append(TickEvent(
                    title: "Tomate \(pomodoroCount)/\(Pomodoro.cycles) terminée\(suffix)",
                    body: "\(breakDesc) démarrée automatiquement."
                ))
            } else {
                lastTickEvents.append(TickEvent(
                    title: "Pause terminée",
                    body: "Prêt pour la prochaine Tomate (25 min) — clique sur ▶︎."
                ))
            }
        }

        if !lastTickEvents.isEmpty {
            saveToDefaults()
        }
        return !lastTickEvents.isEmpty
    }

    private func advancePomodoroPhase(at now: Date) {
        if pomodoroPhase == .work {
            // Fin d'un Pomodoro de 25 min : la pause (5 ou 15 min) démarre automatiquement.
            pomodoroCount += 1
            pomodoroPhase = pomodoroCount % Pomodoro.cycles == 0 ? .longBreak : .shortBreak
            tracks[.pomodoro] = TrackState(
                running: true,
                stored: startValue(for: .pomodoro),
                anchor: now,
                sessionStart: now
            )
        } else {
            // Fin de la pause : le prochain Pomodoro de 25 min s'arme à l'arrêt et attend le clic ▶︎.
            if pomodoroPhase == .longBreak { pomodoroCount = 0 }
            pomodoroPhase = .work
            tracks[.pomodoro] = TrackState(
                running: false,
                stored: startValue(for: .pomodoro),
                anchor: nil,
                sessionStart: nil
            )
        }
    }

    /// Valeur de départ du compteur pour un mode donné.
    private func startValue(for target: Mode) -> TimeInterval {
        switch target {
        case .countdown: return countdownDuration
        case .stopwatch: return 0
        case .pomodoro:
            switch pomodoroPhase {
            case .work: return pomodoroWork
            case .shortBreak: return pomodoroShortBreak
            case .longBreak: return pomodoroLongBreak
            }
        }
    }

    /// Étiquette inscrite dans les relevés pour le mode courant.
    var sessionKind: String {
        sessionKind(for: mode)
    }

    private func sessionKind(for target: Mode) -> String {
        switch target {
        case .countdown: return "minuteur"
        case .stopwatch: return "chrono"
        case .pomodoro: return pomodoroPhase == .work ? "tomate" : "pause"
        }
    }

    private func logSession(target: Mode, start: Date?, end: Date) {
        guard let start else { return }
        let duration = end.timeIntervalSince(start)
        guard duration >= 1 else { return }
        SessionLog.append(kind: sessionKind(for: target), task: taskLabel, start: start, duration: duration)
    }

    // MARK: Persistance de l'état des 3 modes

    private static let stateKey = "tracksStateV1"

    func saveToDefaults() {
        guard persistsState else { return }
        var dict: [String: Any] = [
            "mode": mode.rawValue,
            "countdownDuration": countdownDuration,
            "pomodoroPhase": pomodoroPhase.rawValue,
            "pomodoroCount": pomodoroCount,
        ]
        for m in Mode.allCases {
            guard let t = tracks[m] else { continue }
            let prefix = "track_\(m.rawValue)_"
            dict[prefix + "running"] = t.running
            dict[prefix + "stored"] = t.stored
            if let anchor = t.anchor {
                dict[prefix + "anchor"] = anchor.timeIntervalSince1970
            }
            if let sessionStart = t.sessionStart {
                dict[prefix + "sessionStart"] = sessionStart.timeIntervalSince1970
            }
        }
        UserDefaults.standard.set(dict, forKey: Self.stateKey)
    }

    private func restoreFromDefaults() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.stateKey) else { return }
        if let rawMode = dict["mode"] as? Int, let savedMode = Mode(rawValue: rawMode) {
            mode = savedMode
        }
        if let cd = dict["countdownDuration"] as? TimeInterval, cd > 0 {
            countdownDuration = cd
        }
        if let rawPhase = dict["pomodoroPhase"] as? Int, let savedPhase = PomodoroPhase(rawValue: rawPhase) {
            pomodoroPhase = savedPhase
        }
        if let count = dict["pomodoroCount"] as? Int {
            pomodoroCount = count
        }
        for m in Mode.allCases {
            let prefix = "track_\(m.rawValue)_"
            let running = dict[prefix + "running"] as? Bool ?? false
            let stored = dict[prefix + "stored"] as? TimeInterval ?? startValue(for: m)
            let anchor = (dict[prefix + "anchor"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
            let sessionStart = (dict[prefix + "sessionStart"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
            tracks[m] = TrackState(running: running, stored: stored, anchor: anchor, sessionStart: sessionStart)
        }
    }
}

// MARK: - Relevés

enum SessionLog {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MinuteurAtelier", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("sessions.csv") }

    static func append(kind: String, task: String, start: Date, duration: TimeInterval) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let isNew = !manager.fileExists(atPath: fileURL.path)
        let stamp = ISO8601DateFormatter()
        var line = ""
        if isNew { line += "fin,mode,duree_s,tache\n" }
        line += "\(stamp.string(from: Date())),\(kind),\(String(format: "%.1f", duration)),\(csv(task))\n"

        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Échappe une valeur pour CSV (guillemets si virgule, guillemet ou saut de ligne).
    private static func csv(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    struct DailyStats {
        var tomatoCount: Int = 0
        var tomatoSeconds: TimeInterval = 0
        var otherSeconds: TimeInterval = 0
        var taskBreakdown: [(task: String, tomatoes: Int, seconds: TimeInterval)] = []

        var menuHeadline: String {
            let tLabel = tomatoCount == 1 ? "1 tomate" : "\(tomatoCount) tomates"
            let total = tomatoSeconds + otherSeconds
            return "Aujourd'hui : \(tLabel) · \(Self.formatHM(total))"
        }

        var clipboardReport: String {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            var lines = ["Résumé Minuteur Atelier (\(df.string(from: Date()))) — \(menuHeadline)"]
            for item in taskBreakdown {
                let name = item.task.isEmpty ? "(sans description)" : item.task
                let tPart = item.tomatoes > 0 ? " (\(item.tomatoes) 🍅)" : ""
                lines.append("- \(name)\(tPart) : \(Self.formatHM(item.seconds))")
            }
            return lines.joined(separator: "\n")
        }

        static func formatHM(_ seconds: TimeInterval) -> String {
            let totalMinutes = Int(round(seconds / 60))
            let h = totalMinutes / 60
            let m = totalMinutes % 60
            return h > 0 ? String(format: "%dh%02d", h, m) : "\(m) min"
        }
    }

    static func todayStats(now: Date = Date()) -> DailyStats {
        var stats = DailyStats()
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return stats }
        let iso = ISO8601DateFormatter()
        let cal = Calendar.current
        var byTask: [String: (tomatoes: Int, seconds: TimeInterval)] = [:]
        var taskOrder: [String] = []

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("fin,") { continue }
            let cols = parseCSVRow(line)
            guard cols.count >= 3,
                  let date = iso.date(from: cols[0]),
                  cal.isDate(date, inSameDayAs: now),
                  let dur = Double(cols[2]) else { continue }
            let kind = cols[1]
            let task = cols.count >= 4 ? cols[3] : ""
            if kind == "tomate" {
                stats.tomatoCount += 1
                stats.tomatoSeconds += dur
                if byTask[task] == nil { taskOrder.append(task) }
                let cur = byTask[task] ?? (0, 0)
                byTask[task] = (cur.tomatoes + 1, cur.seconds + dur)
            } else if kind == "minuteur" || kind == "chrono" {
                stats.otherSeconds += dur
                if byTask[task] == nil { taskOrder.append(task) }
                let cur = byTask[task] ?? (0, 0)
                byTask[task] = (cur.tomatoes, cur.seconds + dur)
            }
        }
        stats.taskBreakdown = taskOrder.compactMap { key in
            guard let v = byTask[key] else { return nil }
            return (task: key, tomatoes: v.tomatoes, seconds: v.seconds)
        }
        return stats
    }

    private static func parseCSVRow(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            if inQuotes {
                if ch == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { current.append("\"") }
                        else if next == "," { result.append(current); current = ""; inQuotes = false }
                        else { current.append(next); inQuotes = false }
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else {
                if ch == "\"" { inQuotes = true }
                else if ch == "," { result.append(current); current = "" }
                else { current.append(ch) }
            }
        }
        result.append(current)
        return result
    }
}

// MARK: - Affichage de l'heure

/// Zone du temps, positionnée à la main : le groupe entier
/// (chiffres + millisecondes) est centré sur le milieu de la vue,
/// quel que soit l'état. Aucune contrainte Auto Layout à l'intérieur.
final class TimeDisplayView: NSView {
    private let digitsLabel = NSTextField(labelWithString: "00:10:00")
    private let millisecondsLabel = NSTextField(labelWithString: ".000")
    private let gap: CGFloat = 1
    private var scrollAccumulator: CGFloat = 0

    /// Appelée quand l'utilisateur fait défiler à la molette/trackpad sur l'affichage du temps.
    /// `(steps, optionPressed)`
    var onScrollAdjust: ((Int, Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        digitsLabel.font = .monospacedDigitSystemFont(ofSize: 52, weight: .medium)
        millisecondsLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        // Sans cette ligne, Auto Layout génère des contraintes qui écrasent
        // les frames posées à la main dans relayout().
        for label in [digitsLabel, millisecondsLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(digitsLabel)
        addSubview(millisecondsLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 14.0 : event.scrollingDeltaY
        scrollAccumulator += dy
        let steps = Int(scrollAccumulator)
        if steps != 0 {
            scrollAccumulator -= CGFloat(steps)
            let optionPressed = event.modifierFlags.contains(.option)
            onScrollAdjust?(steps, optionPressed)
        }
    }

    override func layout() {
        super.layout()
        relayout()
    }

    func setFonts(digitsSize: CGFloat, millisecondsSize: CGFloat) {
        digitsLabel.font = .monospacedDigitSystemFont(ofSize: digitsSize, weight: .medium)
        millisecondsLabel.font = .monospacedDigitSystemFont(
            ofSize: millisecondsSize, weight: .medium
        )
        relayout()
    }

    func update(
        digits: String,
        milliseconds: String,
        showsMilliseconds: Bool
    ) {
        digitsLabel.stringValue = digits
        millisecondsLabel.stringValue = milliseconds
        millisecondsLabel.isHidden = !showsMilliseconds
        // Typo toujours blanche : la couleur d'état vit dans le fond du panneau.
        digitsLabel.textColor = .white.withAlphaComponent(0.95)
        millisecondsLabel.textColor = .white.withAlphaComponent(0.72)
        relayout()
    }

    /// Positionne les deux libellés pour que le groupe complet soit centré.
    private func relayout() {
        guard bounds.width > 0 else { return }

        let digitsSize = cellSize(of: digitsLabel)
        let msSize = cellSize(of: millisecondsLabel)
        let msWidth = millisecondsLabel.isHidden ? 0 : msSize.width + gap
        let total = digitsSize.width + msWidth
        let originX = bounds.midX - total / 2

        let digitsY = bounds.midY - digitsSize.height / 2
        digitsLabel.frame = NSRect(
            x: originX, y: digitsY, width: digitsSize.width, height: digitsSize.height
        )

        let msDescent = -millisecondsLabel.font!.descender
        let digitsDescent = -digitsLabel.font!.descender
        millisecondsLabel.frame = NSRect(
            x: originX + digitsSize.width + gap,
            y: digitsY + digitsDescent - msDescent,
            width: msSize.width,
            height: msSize.height
        )
    }

    private func cellSize(of label: NSTextField) -> NSSize {
        guard let cell = label.cell as? NSTextFieldCell else { return label.fittingSize }
        let infinite = CGFloat.greatestFiniteMagnitude
        return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: infinite, height: infinite))
    }
}

/// Témoin visuel discret des 4 Tomates du cycle (`● ● ○ ○`).
final class PomodoroDotsView: NSView {
    private var completed: Int = 0
    private var inWorkRunning: Bool = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: 38, height: 12)
    }

    func update(completed: Int, inWorkRunning: Bool) {
        if self.completed != completed || self.inWorkRunning != inWorkRunning {
            self.completed = completed
            self.inWorkRunning = inWorkRunning
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let count = MinuteurModel.Pomodoro.cycles
        let dotDiameter: CGFloat = 6
        let spacing: CGFloat = 4
        let totalW = CGFloat(count) * dotDiameter + CGFloat(count - 1) * spacing
        var x = (bounds.width - totalW) / 2
        let y = (bounds.height - dotDiameter) / 2

        for i in 0..<count {
            let rect = NSRect(x: x, y: y, width: dotDiameter, height: dotDiameter)
            let path = NSBezierPath(ovalIn: rect)
            if i < completed {
                NSColor.white.withAlphaComponent(0.92).setFill()
                path.fill()
            } else if i == completed && inWorkRunning {
                NSColor.white.withAlphaComponent(0.55).setFill()
                path.fill()
            } else {
                NSColor.white.withAlphaComponent(0.24).setFill()
                path.fill()
            }
            x += dotDiameter + spacing
        }
    }
}

// MARK: - Panneau flottant et champ de saisie

/// Panneau sans bordure qui accepte quand même le focus clavier pour le champ de séance.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Champ de saisie pour la séance Tomate : ne déclenche pas le glisser-déposer de la fenêtre
/// et prend immédiatement le focus clavier au clic.
final class TaskInputField: NSTextField {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
    }
}

// MARK: - Interface

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let model = MinuteurModel(persistsState: true)

    private let originKey = "panelOrigin"
    private let millisecondsKey = "showMilliseconds"

    private var panel: FloatingPanel!
    private var timeDisplay: TimeDisplayView!
    private var taskField: TaskInputField!
    private var taskBox: NSView!
    private var pomodoroDots: PomodoroDotsView!
    private var tintView: NSView!
    private var presetsStack: NSStackView!
    private var millisecondsButton: NSButton!
    private var millisecondsMenuItem: NSMenuItem!
    private var dailyHeadlineMenuItem: NSMenuItem!
    private var playButton: NSButton!
    private var modeControl: NSSegmentedControl!
    private var statusItem: NSStatusItem!
    private var ticker: Timer?
    private var showMilliseconds = false
    private var lastRunning = false
    private var flashUntil = Date.distantPast
    private var lastTint: TintKind = .none
    private var lastStatusTitle: String = ""

    // MARK: Cycle de vie

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupNotifications()
        showMilliseconds = UserDefaults.standard.bool(forKey: millisecondsKey)
        let savedTask = (UserDefaults.standard.string(forKey: "taskLabel") ?? "").trimmingCharacters(in: .whitespaces)
        model.taskLabel = savedTask
        buildStatusItem()
        buildPanel()
        taskField.stringValue = savedTask
        modeControl.selectedSegment = model.mode.rawValue
        startTicker()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveToDefaults()
    }

    // MARK: Panneau

    private func buildPanel() {
        let size = NSSize(width: 320, height: 170)
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // hasShadow = false supprime la bordure noire ("rim") dessinée par macOS 15/26 autour des fenêtres HUD.
        panel.hasShadow = false

        let container = NSView(frame: NSRect(origin: .zero, size: size))

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.roundedMaskImage(size: size, radius: 18)
        blur.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(blur)

        // Teinte « rouge léger » posée sur le flou pendant les pomodoros.
        // Le texte reste toujours blanc : seule la couleur de fond signale le mode.
        tintView = NSView()
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor(
            srgbRed: 0.86, green: 0.24, blue: 0.16, alpha: 0.24
        ).cgColor
        tintView.layer?.cornerRadius = 18
        tintView.layer?.masksToBounds = true
        tintView.isHidden = true
        tintView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tintView)

        // Ligne du haut : mode et option millisecondes
        modeControl = NSSegmentedControl(
            labels: ["Minuteur", "Chrono", "Tomate"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged(_:))
        )
        modeControl.selectedSegment = 0
        modeControl.controlSize = .small
        modeControl.segmentStyle = .texturedRounded

        millisecondsButton = NSButton(
            title: "ms", target: self, action: #selector(toggleMilliseconds(_:))
        )
        millisecondsButton.setButtonType(.toggle)
        millisecondsButton.bezelStyle = .rounded
        millisecondsButton.controlSize = .small
        millisecondsButton.toolTip = "Afficher les millisecondes"

        let topSpacer = NSView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let topRow = NSStackView(views: [modeControl, topSpacer, millisecondsButton])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.alignment = .centerY

        // Grand affichage : H:MM:SS (+ .mmm à la demande), groupe centré.
        // Le clic sur les chiffres bascule lecture/pause en Minuteur et Chrono (inactif en Tomate).
        // La molette / trackpad sur les chiffres ajuste la durée du Minuteur quand il est à l'arrêt.
        timeDisplay = TimeDisplayView()
        timeDisplay.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(timeDisplayClicked(_:)))
        )
        timeDisplay.onScrollAdjust = { [weak self] steps, optionPressed in
            guard let self else { return }
            let unit: TimeInterval = optionPressed ? 5 : 60
            self.model.adjustCountdown(bySeconds: TimeInterval(steps) * unit)
            self.refresh()
        }

        // Ligne du bas : lecture / remise à zéro + préréglages (Minuteur)
        // OU témoin 4 Tomates + champ de description de la séance (Tomate).
        playButton = symbolButton("play.fill", action: #selector(toggle(_:)))
        let resetButton = symbolButton("arrow.counterclockwise", action: #selector(reset(_:)))

        presetsStack = NSStackView()
        presetsStack.orientation = .horizontal
        presetsStack.spacing = 8
        for minutes in [1, 5, 10, 25] {
            let button = NSButton(title: "\(minutes)", target: self, action: #selector(presetPressed(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = minutes
            button.toolTip = "Minuteur de \(minutes) minute\(minutes > 1 ? "s" : "")"
            presetsStack.addArrangedSubview(button)
        }

        // Témoin des 4 Tomates du cycle (`● ● ○ ○`)
        pomodoroDots = PomodoroDotsView()
        pomodoroDots.toolTip = "Progression du cycle de 4 Tomates avant la pause longue"
        pomodoroDots.isHidden = true

        // Champ éditable Tomate (dans un fond capsule discret à droite des boutons)
        taskBox = NSView()
        taskBox.wantsLayer = true
        taskBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        taskBox.layer?.cornerRadius = 6
        taskBox.layer?.masksToBounds = true
        taskBox.isHidden = true

        taskField = TaskInputField(string: "")
        taskField.font = .systemFont(ofSize: 12, weight: .medium)
        taskField.textColor = .white
        taskField.backgroundColor = .clear
        taskField.drawsBackground = false
        taskField.isBordered = false
        taskField.isBezeled = false
        taskField.isEditable = true
        taskField.isSelectable = true
        taskField.usesSingleLineMode = true
        taskField.alignment = .left
        taskField.focusRingType = .none
        (taskField.cell as? NSTextFieldCell)?.drawsBackground = false
        (taskField.cell as? NSTextFieldCell)?.backgroundColor = .clear
        taskField.delegate = self
        setPlaceholder("Séance…")
        taskField.translatesAutoresizingMaskIntoConstraints = false
        taskBox.addSubview(taskField)

        NSLayoutConstraint.activate([
            taskField.leadingAnchor.constraint(equalTo: taskBox.leadingAnchor, constant: 8),
            taskField.trailingAnchor.constraint(equalTo: taskBox.trailingAnchor, constant: -8),
            taskField.centerYAnchor.constraint(equalTo: taskBox.centerYAnchor),
            taskBox.widthAnchor.constraint(equalToConstant: 150),
            taskBox.heightAnchor.constraint(equalToConstant: 22),
            pomodoroDots.widthAnchor.constraint(equalToConstant: 38),
            pomodoroDots.heightAnchor.constraint(equalToConstant: 14),
        ])

        let spacerLeft = NSView()
        spacerLeft.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let controls = NSStackView(views: [playButton, resetButton, spacerLeft, presetsStack, pomodoroDots, taskBox])
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.alignment = .centerY

        // Disposition verticale explicite, 3 rangées seulement (aucune ligne au milieu) :
        // 14 + [sélecteur 24] + 10 + [temps 74] + 10 + [boutons 24] + 14 = 170
        topRow.translatesAutoresizingMaskIntoConstraints = false
        timeDisplay.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topRow)
        container.addSubview(timeDisplay)
        container.addSubview(controls)
        panel.contentView = container

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: container.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            topRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            topRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            topRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            topRow.heightAnchor.constraint(equalToConstant: 24),

            timeDisplay.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            timeDisplay.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            timeDisplay.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 10),
            timeDisplay.heightAnchor.constraint(equalToConstant: 74),

            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            controls.topAnchor.constraint(equalTo: timeDisplay.bottomAnchor, constant: 10),
            controls.heightAnchor.constraint(equalToConstant: 24),
        ])

        applyMillisecondsOption()

        panel.delegate = self
        let stored = UserDefaults.standard.array(forKey: originKey) as? [Double] ?? []
        let restored = stored.count == 2 ? NSPoint(x: stored[0], y: stored[1]) : nil
        if let restored, NSScreen.screens.contains(where: { $0.visibleFrame.contains(restored) }) {
            panel.setFrameOrigin(restored)
        } else if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width - 40,
                y: visible.maxY - size.height - 60
            ))
        }

        panel.orderFrontRegardless()
        panel.makeFirstResponder(nil)
    }

    private static func roundedMaskImage(size: NSSize, radius: CGFloat) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: radius, yRadius: radius).fill()
        img.unlockFocus()
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        return img
    }

    private func symbolButton(_ name: String, action: Selector) -> NSButton {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .white
        button.setButtonType(.momentaryChange)
        return button
    }

    // MARK: Barre de menus et notifications

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func playChimeAndNotify(events: [MinuteurModel.TickEvent]) {
        if let chime = NSSound(named: NSSound.Name("Glass")) ?? NSSound(named: NSSound.Name("Hero")) {
            chime.play()
        } else {
            NSSound.beep()
        }
        let center = UNUserNotificationCenter.current()
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(req, withCompletionHandler: nil)
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "timer", accessibilityDescription: "Minuteur")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.toolTip = "Minuteur atelier"

        let menu = NSMenu()
        menu.delegate = self

        dailyHeadlineMenuItem = NSMenuItem(title: "Aujourd'hui : 0 tomate · 0 min", action: nil, keyEquivalent: "")
        dailyHeadlineMenuItem.isEnabled = false
        menu.addItem(dailyHeadlineMenuItem)

        let copyItem = NSMenuItem(
            title: "Copier le résumé du jour",
            action: #selector(copyDailySummary(_:)),
            keyEquivalent: "c"
        )
        copyItem.target = self
        menu.addItem(copyItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Afficher / masquer le panneau",
                     action: #selector(togglePanel(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        for minutes in [1, 5, 10, 25] {
            let item = NSMenuItem(title: "Minuteur \(minutes) min",
                                  action: #selector(menuPreset(_:)), keyEquivalent: "")
            item.tag = minutes
            item.target = self
            menu.addItem(item)
        }
        let chrono = NSMenuItem(title: "Chrono", action: #selector(menuChrono(_:)), keyEquivalent: "")
        chrono.target = self
        menu.addItem(chrono)

        let tomate = NSMenuItem(
            title: "Tomate (pomodoro 25/5)", action: #selector(menuPomodoro(_:)), keyEquivalent: ""
        )
        tomate.target = self
        menu.addItem(tomate)

        millisecondsMenuItem = NSMenuItem(
            title: "Afficher les millisecondes",
            action: #selector(toggleMilliseconds(_:)),
            keyEquivalent: ""
        )
        millisecondsMenuItem.target = self
        millisecondsMenuItem.state = showMilliseconds ? .on : .off
        menu.addItem(millisecondsMenuItem)
        menu.addItem(.separator())
        let reveal = NSMenuItem(title: "Ouvrir les relevés", action: #selector(revealLogs(_:)), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        dailyHeadlineMenuItem.title = SessionLog.todayStats().menuHeadline
    }

    @objc private func copyDailySummary(_ sender: Any?) {
        let report = SessionLog.todayStats().clipboardReport
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)
    }

    // MARK: Position mémorisée

    func windowDidMove(_ notification: Notification) {
        let origin = panel.frame.origin
        UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: originKey)
    }

    // MARK: Boucle

    private func startTicker() {
        ticker?.invalidate()
        let interval: TimeInterval = showMilliseconds ? 1 / 60 : 0.05
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func refresh() {
        if model.tick() {
            flashUntil = Date().addingTimeInterval(2.5)
            playChimeAndNotify(events: model.lastTickEvents)
        }

        let display = formatted(model.value)

        let isTomate = model.mode == .pomodoro
        let showPauseIcon = model.running && !isTomate
        playButton.image = NSImage(
            systemSymbolName: showPauseIcon ? "pause.fill" : "play.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        playButton.isEnabled = !(isTomate && model.running)
        playButton.alphaValue = (isTomate && model.running) ? 0.32 : 1.0
        lastRunning = model.running

        // Typo toujours blanche : la couleur d'état vit dans le fond du panneau.
        timeDisplay.update(
            digits: display.main,
            milliseconds: display.ms,
            showsMilliseconds: showMilliseconds
        )

        presetsStack.isHidden = model.mode != .countdown
        pomodoroDots.isHidden = !isTomate
        taskBox.isHidden = !isTomate
        pomodoroDots.update(
            completed: model.pomodoroCount % MinuteurModel.Pomodoro.cycles,
            inWorkRunning: model.pomodoroPhase == .work && model.isRunning(.pomodoro)
        )
        updateTint()
        updateStatusBarTitle()
    }

    private func updateStatusBarTitle() {
        // Affiche le temps à côté de ⏱ dans la barre de menus quand le panneau est masqué
        // ou lorsqu'une Tomate / un Minuteur tourne en arrière-plan.
        var title = ""
        if !panel.isVisible {
            let activeMode: MinuteurModel.Mode = model.isRunning(.pomodoro) ? .pomodoro : model.mode
            title = " " + shortFormatted(model.value(for: activeMode), isCountdown: activeMode != .stopwatch)
        } else if model.mode != .pomodoro, model.isRunning(.pomodoro) {
            title = " " + shortFormatted(model.value(for: .pomodoro), isCountdown: true)
        } else if model.mode != .countdown, model.isRunning(.countdown) {
            title = " " + shortFormatted(model.value(for: .countdown), isCountdown: true)
        }
        if title != lastStatusTitle {
            lastStatusTitle = title
            statusItem.button?.title = title
        }
    }

    private func shortFormatted(_ value: TimeInterval, isCountdown: Bool) -> String {
        let totalSecs = Int(isCountdown ? ceil(value) : floor(value))
        let h = totalSecs / 3600
        let m = (totalSecs % 3600) / 60
        let s = totalSecs % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: Description de séance et teinte de fond

    /// Couleur de fond du panneau, porte unique de l'état.
    private enum TintKind: Equatable {
        case none, red, orange

        var color: CGColor? {
            switch self {
            case .none: return nil
            case .red: return NSColor(srgbRed: 0.86, green: 0.24, blue: 0.16, alpha: 0.24).cgColor
            case .orange: return NSColor(srgbRed: 0.95, green: 0.55, blue: 0.10, alpha: 0.22).cgColor
            }
        }
    }

    /// Indication pâle (gris clair) quand le champ est vide.
    private func setPlaceholder(_ text: String) {
        taskField.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.45),
            ]
        )
    }

    private func updateTint() {
        let kind: TintKind
        if Date() < flashUntil {
            kind = .red
        } else if model.mode == .pomodoro {
            kind = model.pomodoroPhase == .work ? .red : .none
        } else if model.mode != .stopwatch && model.running && model.value < 60 {
            kind = .orange
        } else {
            kind = .none
        }
        if kind != lastTint {
            lastTint = kind
            tintView.isHidden = kind == .none
            tintView.layer?.backgroundColor = kind.color
        }
    }

    /// Enregistre le texte saisi comme description de séance (en direct et à la fin d'édition).
    private func commitTaskField() {
        let text = taskField.stringValue.trimmingCharacters(in: .whitespaces)
        model.taskLabel = text
        UserDefaults.standard.set(text, forKey: "taskLabel")
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === taskField else { return }
        commitTaskField()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === taskField else { return }
        commitTaskField()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitTaskField()
            panel.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func formatted(_ value: TimeInterval) -> (main: String, ms: String) {
        let roundingUp = model.mode != .stopwatch
        let millis = Int(roundingUp ? ceil(value * 1000) : floor(value * 1000))
        let hours = millis / 3_600_000
        let minutes = (millis % 3_600_000) / 60_000
        let seconds = (millis % 60_000) / 1000
        let fraction = millis % 1000
        return (
            String(format: "%02d:%02d:%02d", hours, minutes, seconds),
            String(format: ".%03d", fraction)
        )
    }

    // MARK: Actions

    @objc private func toggle(_ sender: Any?) {
        panel.makeFirstResponder(nil)
        model.toggle()
        refresh()
    }

    @objc private func timeDisplayClicked(_ sender: Any?) {
        guard model.mode != .pomodoro else { return }
        toggle(sender)
    }

    @objc private func reset(_ sender: Any?) {
        model.reset()
        refresh()
    }

    @objc private func toggleMilliseconds(_ sender: Any?) {
        showMilliseconds.toggle()
        UserDefaults.standard.set(showMilliseconds, forKey: millisecondsKey)
        applyMillisecondsOption()
        startTicker()
        refresh()
    }

    private func applyMillisecondsOption() {
        millisecondsButton.state = showMilliseconds ? .on : .off
        millisecondsMenuItem.state = showMilliseconds ? .on : .off
        timeDisplay.setFonts(digitsSize: showMilliseconds ? 42 : 52, millisecondsSize: 20)
    }

    @objc private func presetPressed(_ sender: NSButton) {
        model.setPreset(minutes: Double(sender.tag))
        modeControl.selectedSegment = 0
        model.start()
        refresh()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        panel.makeFirstResponder(nil)
        switch sender.selectedSegment {
        case 1: model.setMode(.stopwatch)
        case 2: model.setMode(.pomodoro)
        default: model.setMode(.countdown)
        }
        refresh()
    }

    @objc private func menuPomodoro(_ sender: Any?) {
        model.setMode(.pomodoro)
        modeControl.selectedSegment = 2
        model.start()
        panel.orderFrontRegardless()
        refresh()
    }

    @objc private func menuPreset(_ sender: NSMenuItem) {
        model.setPreset(minutes: Double(sender.tag))
        modeControl.selectedSegment = 0
        model.start()
        panel.orderFrontRegardless()
        refresh()
    }

    @objc private func menuChrono(_ sender: Any?) {
        model.setMode(.stopwatch)
        modeControl.selectedSegment = 1
        model.start()
        panel.orderFrontRegardless()
        refresh()
    }

    @objc private func togglePanel(_ sender: Any?) {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func revealLogs(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: SessionLog.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(SessionLog.directory)
    }
}

// MARK: - Lancement

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
