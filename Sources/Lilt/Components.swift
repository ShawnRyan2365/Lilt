import SwiftUI
import LiltCore

/// Shared phrasing for quota figures, so the window, the panel and VoiceOver say the same thing.
enum Wording {
    static func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) + "%" }
    /// nil once the reset moment has passed: the old reading no longer describes the window.
    static func reset(_ date: Date?, now: Date) -> String? {
        guard let date, date > now else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds < 3600 { return "\(max(1, Int(seconds / 60))) 分钟后重置" }
        if seconds < 86400 { return "\(Int((seconds / 3600).rounded())) 小时后重置" }
        return "\(Int((seconds / 86400).rounded())) 天后重置"
    }
    /// How long until a window refreshes, without the trailing “重置”. Nil after that moment.
    static func resetAmount(_ date: Date?, now: Date) -> String? {
        guard let date, date > now else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds < 3600 { return "\(max(1, Int(seconds / 60))) 分钟" }
        if seconds < 86400 { return "\(Int((seconds / 3600).rounded())) 小时" }
        return "\(Int((seconds / 86400).rounded())) 天"
    }
    static func age(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚更新" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前更新" }
        return "\(Int(seconds / 3600)) 小时前更新"
    }
}
/// What a reading means for the user right now, in words as well as colour.
/// Readings are taken every few minutes, so a reading of a few minutes is current. Only one that is over an hour old
/// is called out, by its age; nothing here ever says "expired", which reads as if the account had run out.
enum UsageState: Equatable {
    case reached, low, old(String)
    static let oldAfter: TimeInterval = 3600
    var text: String { switch self { case .reached: "已到阈值"; case .low: "偏低"; case .old(let age): age } }
    var tone: Tone { switch self { case .reached: .danger; case .low: .warning; case .old: .neutral } }
    var isOld: Bool { if case .old = self { true } else { false } }
    init?(shown: Double?, sampledAt: Date?, threshold: Double, now: Date) {
        guard let shown else { return nil }
        if let sampledAt, now.timeIntervalSince(sampledAt) > Self.oldAfter {
            self = .old(Wording.age(sampledAt, now: now).replacingOccurrences(of: "更新", with: "的读数")); return
        }
        if shown <= threshold + 0.000001 { self = .reached } else if shown <= 10 { self = .low } else { return nil }
    }
}
/// One quota window of an account, drawn with the design layer's readout.
/// The two quota windows. Each keeps one colour wherever it is drawn, so a ring, a clock hand, a ruler
/// and a legend dot of the same window match without reading.
enum QuotaWindowKind: CaseIterable, Sendable {
    case fiveHour, sevenDay
    var title: String { self == .fiveHour ? "5 小时" : "7 天" }
    var length: TimeInterval { self == .fiveHour ? 5 * 3600 : 7 * 86400 }
    var series: Paint { self == .fiveHour ? Tokens.fiveHour : Tokens.sevenDay }
    func window(in snapshot: UsageSnapshot?) -> UsageWindow? { self == .fiveHour ? snapshot?.fiveHour : snapshot?.sevenDay }
}
struct UsageMeter: View {
    let kind: QuotaWindowKind
    let snapshot: UsageSnapshot?
    private var title: String { kind.title }
    private var window: UsageWindow? { kind.window(in: snapshot) }
    var threshold: Double = 1
    /// The credential is known not to be able to read quota (a long-lived token): say so instead of "not fetched yet".
    var unreadable = false
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = max(context.date, .now)
            let shown = snapshot?.lastKnownRemaining(window, at: now)
            let state = UsageState(shown: shown, sampledAt: snapshot?.sampledAt, threshold: threshold, now: now)
            let reset = Wording.reset(window?.resetsAt, now: now)
            QuotaReadout(title: title, remaining: shown, threshold: threshold, staleNote: state?.isOld == true ? state?.text : nil,
                         placeholder: snapshot == nil ? (unreadable ? "读不到" : "未获取") : "未知",
                         footnote: reset ?? (snapshot == nil ? (unreadable ? "此凭据没有额度权限" : "尚未获取额度") : shown == nil ? "需重新查询" : "重置时间未知"),
                         series: kind.series, compact: compact)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(shown: shown, state: state, reset: reset))
        }
    }
    private func spoken(shown: Double?, state: UsageState?, reset: String?) -> String {
        let name = "\(title)窗口"
        guard let shown else { return "\(name)，\(snapshot == nil ? (unreadable ? "此凭据没有额度权限" : "尚未获取额度") : "额度未知，需重新查询")" }
        return ([name, "剩余 \(Wording.percent(shown))", state?.text, reset].compactMap { $0 }).joined(separator: "，")
    }
}
/// One quota window worded for a small cell: what is left, and when the window refreshes.
struct WindowGlance: Equatable {
    var kind: QuotaWindowKind
    /// "5 小时" or "7 天".
    var name: String { kind.title }
    /// What is left, or nil when it is not known.
    var remaining: Double?
    var level: QuotaLevel
    /// "3 小时后", "时间未知", "待刷新", or nil when there is nothing worth saying: a full window that has not started has no clock.
    var caption: String?
    var resetsAt: Date?
    /// How far the window has run, 0...1, for the clock hand. A full window with no reset time has not
    /// started, and one past its reset is back at the start; otherwise an unknown reset time leaves it nil.
    var elapsed: Double?

    init(kind: QuotaWindowKind, snapshot: UsageSnapshot, threshold: Double, now: Date) {
        self.kind = kind
        let window = kind.window(in: snapshot)
        remaining = snapshot.lastKnownRemaining(window, at: now)
        level = QuotaLevel(remaining: remaining, threshold: threshold)
        resetsAt = window?.resetsAt
        if let reset = window?.resetsAt {
            elapsed = reset <= now ? 0 : min(1, max(0, 1 - reset.timeIntervalSince(now) / kind.length))
        } else if let remaining, remaining >= 100 {
            elapsed = 0
        }
        if let remaining {
            caption = Wording.resetAmount(window?.resetsAt, now: now).map { "\($0)后" } ?? (remaining >= 100 ? nil : "时间未知")
        } else if window?.resetsAt.map({ $0 <= now }) == true {
            // The window refreshed after this reading. It is read again rather than assumed full (PRD).
            caption = "待刷新"
        } else {
            caption = nil
        }
    }
    var figure: String { remaining.map(Wording.percent) ?? "未知" }
    var spoken: String {
        guard let remaining else { return "\(name)额度未知" + (caption.map { "，\($0)" } ?? "") }
        return "\(name)剩余 \(Wording.percent(remaining))" + (caption.map { $0 == "时间未知" ? "，重置时间未知" : "，\($0)重置" } ?? "")
    }
}
/// An account's quota for the places that show it small: the track, the accounts list, VoiceOver.
struct QuotaSummary {
    /// Both windows, 5-hour first. Empty when nothing has been read.
    var windows: [WindowGlance] = []
    /// The state of the window with the least left: it runs out first, and it is the one the relay rule acts on.
    var state: UsageState?
    var spoken: String
    /// The same state as an expression for the account's sprite.
    var mood: Mood = .idle
    var stale: Bool { state?.isOld == true }

    init(snapshot: UsageSnapshot?, threshold: Double, now: Date) {
        guard let snapshot else { spoken = "尚未获取额度"; return }
        windows = QuotaWindowKind.allCases.map { WindowGlance(kind: $0, snapshot: snapshot, threshold: threshold, now: now) }
        spoken = windows.map(\.spoken).joined(separator: "，")
        guard let tight = windows.compactMap(\.remaining).min() else { return }
        state = UsageState(shown: tight, sampledAt: snapshot.sampledAt, threshold: threshold, now: now)
        mood = state == .reached ? .asleep : state == .low ? .drowsy : .idle
        if let state { spoken += "，" + state.text }
    }
}
/// The key to the relay track, said once above it: each window's colour, and on hover what the rings and hands mean.
struct QuotaLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(QuotaWindowKind.allCases, id: \.self) { kind in
                HStack(spacing: 5) { SeriesDot(series: kind.series); Text(kind.title) }
            }
        }
        .font(Typo.caption).foregroundStyle(Tokens.muted)
        .contentShape(Rectangle())
        .help("外圈和长针是 5 小时窗口，内圈和短针是 7 天窗口。圈上亮的部分是剩余额度；指针顺时针走，回到顶端时这个窗口重置。")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("图例：蓝色外圈和长针是 5 小时窗口，绿色内圈和短针是 7 天窗口")
    }
}
extension AppModel {
    /// The relay queue as the track draws it, in priority order.
    var runners: [Runner] {
        let now = max(clock, .now)
        let slots = spriteSlots
        return accounts.map { account in
            let summary = QuotaSummary(snapshot: account.usage, threshold: threshold, now: now)
            let blocked = !account.enabled ? "已停用" : account.usage == nil && account.usageCapability == .unavailable ? "读不到" : nil
            let stale = summary.stale ? summary.state?.text : nil
            func reading(_ kind: QuotaWindowKind) -> RingReading {
                guard let glance = summary.windows.first(where: { $0.kind == kind }) else { return RingReading() }
                // An old reading is not flagged as low or used up; its rings only recede.
                return RingReading(remaining: glance.remaining, level: stale != nil && glance.remaining != nil ? .healthy : glance.level, elapsed: glance.elapsed)
            }
            return Runner(id: account.id, slot: slots[account.id] ?? 0, name: account.label,
                          fiveHour: reading(.fiveHour), sevenDay: reading(.sevenDay),
                          note: blocked ?? (account.usage == nil ? "未获取" : nil), stale: stale,
                          detail: blocked.map { $0 == "读不到" ? "此凭据读不到额度" : $0 } ?? summary.spoken,
                          stopped: !account.enabled, mood: summary.mood)
        }
    }
    /// Each account's sprite silhouette.
    var spriteSlots: [UUID: Int] { Sprite.slots(for: accounts.map(\.id)) }
    func spriteSlot(_ id: UUID) -> Int { spriteSlots[id] ?? Sprite.slot(for: id) }
    func mood(of account: Account) -> Mood { QuotaSummary(snapshot: account.usage, threshold: threshold, now: max(clock, .now)).mood }
}
struct FreshnessText: View {
    let date: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            // Swapped in place: without this, a change that lands during a layout animation leaves the old
            // words drifting beside the new ones.
            Text(Wording.age(date, now: max(context.date, .now))).contentTransition(.opacity)
                .help("采样于 \(date.formatted(date: .omitted, time: .standard))")
        }
        .transaction { $0.animation = nil }
    }
}
/// State, reason and next step for the applied account, as the one island on a screen.
/// It is absent when there is nothing to say, so it leaves no gap; the parent animates it in and out.
struct NoticeIsland: View {
    @Bindable var model: AppModel
    var onNeedsWindow: (() -> Void)?
    /// Leaves out "no account in use" where a setup step is already asking for the same thing.
    var hidesNoActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let _ = model.clock // re-evaluated on every monitor tick, since staleness and backoff depend on time
        if let notice = model.notice(), !(hidesNoActive && model.active == nil && !notice.warning) {
            Island(symbol: notice.symbol, tone: notice.warning ? .warning : .neutral, text: notice.text, detail: notice.detail) {
                if model.apiModeDetected {
                    if !model.keepsAPIMode {
                        Button("保留 API") { model.keepAPI() }.buttonStyle(IslandButtonStyle()).disabled(model.busy)
                    }
                    if let active = model.active {
                        Button("切回订阅") { Task { await model.apply(active.id) } }
                            .buttonStyle(IslandButtonStyle()).disabled(model.busy || model.loading)
                    }
                }
                if let action = notice.action {
                    Button(action.title) { model.perform(action); if action.needsWindow { onNeedsWindow?() } }
                        .buttonStyle(IslandButtonStyle()).disabled(model.busy || model.loading)
                }
            }
            .transition(.liltReveal(reduceMotion: reduceMotion))
        }
    }
}
/// A shell command: one line at rest (its start and its end), the whole thing on request, copied in its single-line form.
struct CommandBlock: View {
    let display: String
    let command: String
    var onCopy: (() -> Void)?
    @State private var copied = Transient()
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if expanded {
                    Text(display).font(Typo.mono).textSelection(.enabled).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(command).font(Typo.mono).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                }
                if expanded {
                    Button("收起") { expanded = false }.buttonStyle(.lilt(.ghost, size: .small)).padding(.leading, -11)
                }
            }
            if !expanded {
                Button { expanded = true } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.liltIcon(.ghost, diameter: 32)).help("显示完整命令").accessibilityLabel("显示完整命令")
            }
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
                copied.flash(for: 2); onCopy?()
            } label: {
                Image(systemName: copied.shown ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.liltIcon(.ink, diameter: 32))
            .help(copied.shown ? "已复制" : "复制启动命令")
            .accessibilityLabel(copied.shown ? "已复制启动命令" : "复制启动命令")
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 10).well()
        .animation(reduceMotion ? Motion.fade : Motion.expoOut(), value: expanded)
    }
}
/// The accounts page with nothing in it: one line, one action.
struct EmptyAccounts: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Text("还没有账号").font(Typo.title)
            HStack(spacing: 8) {
                Button("登录添加") { model.requestAdd(.oauth) }.buttonStyle(.lilt(.primary, size: .large))
                Button("粘贴 Token") { model.requestAdd(.setupToken) }.buttonStyle(.lilt(.secondary, size: .large))
            }.disabled(!model.canAdd)
            if !model.demo { Button("先看看演示") { model.startDemo() }.buttonStyle(.lilt(.ghost, size: .small)) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44).object()
    }
}
/// Fixed widths on the accounts page, shared by the rows and the column labels above them, so the quota
/// rulers line up down the list whatever the row's name or state.
enum AccountColumns {
    static let cell: CGFloat = 132
    static let cellGap: CGFloat = 22
    /// Holds 切换, or the 使用中 pill on the account in use, so the columns never shift.
    static let action: CGFloat = 60
    static let menu: CGFloat = 30
    static let spacing: CGFloat = 12
    static let trailing: CGFloat = 10
}
/// The two column labels, said once above the list instead of on every row.
struct AccountColumnLabels: View {
    var body: some View {
        HStack(spacing: AccountColumns.spacing) {
            Spacer(minLength: 0)
            HStack(spacing: AccountColumns.cellGap) {
                ForEach(QuotaWindowKind.allCases, id: \.self) { kind in
                    HStack(spacing: 5) { SeriesDot(series: kind.series); Text(kind.title) }
                        .frame(width: AccountColumns.cell, alignment: .leading)
                }
            }
            Color.clear.frame(width: AccountColumns.action, height: 1)
            Color.clear.frame(width: AccountColumns.menu, height: 1)
        }
        .font(Typo.caption).foregroundStyle(Tokens.muted)
        .padding(.trailing, AccountColumns.trailing)
        .accessibilityHidden(true)
    }
}
/// One account on the accounts page: who, what it can do, how much is left in each window, and the actions.
struct AccountRow: View {
    @Bindable var model: AppModel
    let account: Account
    let index: Int
    /// Shared by the rows so the 使用中 pill travels to the account that takes over (Icon bar).
    let selection: Namespace.ID
    var onRename: () -> Void
    var onDelete: () -> Void
    private var active: Bool { account.id == model.displayedActiveID }
    private var canSwitch: Bool { !active && account.enabled && !model.busy && !model.loading }
    private var capabilities: String {
        let usage = account.usageCapability == .verified ? "可读取额度" : account.usageCapability == .unavailable ? "额度权限不足" : "额度待验证"
        return [account.kind.title, usage, model.demo ? "演示能力" : "热切换待验证"].joined(separator: " · ")
    }
    var body: some View {
        let summary = QuotaSummary(snapshot: account.usage, threshold: model.threshold, now: max(model.clock, .now))
        HStack(spacing: AccountColumns.spacing) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .medium)).foregroundStyle(Tokens.faint)
                .frame(width: 14).help("拖动调整接力顺序").accessibilityHidden(true)
            HStack(spacing: AccountColumns.spacing) {
                Sprite(slot: model.spriteSlot(account.id), size: 34, mood: summary.mood, muted: !account.enabled)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(account.label).font(Typo.label).lineLimit(1)
                        if !account.enabled { Pill(text: "已停用") }
                        // An old reading stays on screen, receded, and says how old it is.
                        if summary.stale, let age = summary.state?.text { Pill(text: age) }
                    }
                    Text(capabilities).font(Typo.caption).foregroundStyle(Tokens.muted).lineLimit(1)
                    if let issue = account.issue {
                        Label(issue, systemImage: "exclamationmark.circle").font(Typo.caption).foregroundStyle(Tone.danger.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                cells(summary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("优先级 \(index + 1)，\(account.label)\(active ? "，使用中" : "")\(account.enabled ? "" : "，已停用")，\(capabilities)，\(summary.spoken)\(account.issue.map { "，" + $0 } ?? "")")
            ZStack {
                if active {
                    Pill(text: "使用中", style: .ink)
                        .matchedGeometryEffect(id: "in-use", in: selection)
                        .accessibilityHidden(true)
                } else {
                    Button("切换") { Task { await model.apply(account.id) } }
                        .buttonStyle(.lilt(.secondary, size: .small)).disabled(!canSwitch)
                        .help("切换到此账号").accessibilityLabel("切换到 \(account.label)")
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: AccountColumns.action)
            Menu {
                Button("刷新额度") { Task { await model.refresh(account.id) } }
                Button("修改备注", action: onRename)
                Button(account.enabled ? "停用" : "启用") { model.update(account.id) { $0.enabled.toggle() } }
                Button("上移") { model.move(account.id, by: -1) }.disabled(index == 0)
                Button("下移") { model.move(account.id, by: 1) }.disabled(index == model.accounts.count - 1)
                Divider()
                Button("重新授权 / 替换 Token") { model.requestAdd(replacing: account.id) }.disabled(!model.canAdd)
                Button(active ? "删除（需先切换到其他账号）" : "删除…", role: .destructive, action: onDelete).disabled(active)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Tokens.ink)
                    .frame(width: AccountColumns.menu, height: 30).contentShape(Circle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(model.busy || model.loading).help("更多").accessibilityLabel("\(account.label) 的更多操作")
        }
        .padding(.leading, 12).padding(.trailing, AccountColumns.trailing).padding(.vertical, 12)
        .object(radius: 18)
    }
    /// The two windows in fixed columns. A credential that cannot read quota, or one not read yet, still
    /// takes both columns, as dots, so the rows keep their rhythm.
    @ViewBuilder private func cells(_ summary: QuotaSummary) -> some View {
        let unreadable = account.usage == nil && account.usageCapability == .unavailable
        let dimmed = !account.enabled || summary.stale
        HStack(spacing: AccountColumns.cellGap) {
            if summary.windows.isEmpty {
                QuotaCell(remaining: nil, placeholder: unreadable ? "读不到" : "未获取", caption: unreadable ? "无额度权限" : nil, dimmed: dimmed)
                    .frame(width: AccountColumns.cell)
                QuotaCell(remaining: nil, placeholder: unreadable ? "读不到" : "未获取", dimmed: dimmed)
                    .frame(width: AccountColumns.cell)
            } else {
                ForEach(summary.windows, id: \.name) { window in
                    QuotaCell(remaining: window.remaining, caption: window.caption, threshold: model.threshold, series: window.kind.series, dimmed: dimmed)
                        .frame(width: AccountColumns.cell)
                        .help(window.spoken)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.spoken)
    }
}
