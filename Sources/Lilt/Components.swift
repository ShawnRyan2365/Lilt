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
    static func age(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚更新" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前更新" }
        return "\(Int(seconds / 3600)) 小时前更新"
    }
}
/// What a reading means for the user right now, in words as well as colour.
enum UsageState {
    case reached, low, stale
    var text: String { switch self { case .reached: "已到阈值"; case .low: "偏低"; case .stale: "已过期" } }
    var tone: Tone { switch self { case .reached: .danger; case .low: .warning; case .stale: .neutral } }
    /// `fresh` is the value relay rules may use; `shown` may be an older reading kept on screen for reference.
    init?(fresh: Double?, shown: Double?, threshold: Double) {
        if let fresh { if fresh <= threshold + 0.000001 { self = .reached } else if fresh <= 10 { self = .low } else { return nil } }
        else if shown != nil { self = .stale } else { return nil }
    }
}
/// One quota window of an account, drawn with the design layer's readout.
struct UsageMeter: View {
    /// "5 小时" or "7 天".
    let title: String
    let window: UsageWindow?
    let snapshot: UsageSnapshot?
    var threshold: Double = 1
    /// The credential is known not to be able to read quota (a long-lived token): say so instead of "not fetched yet".
    var unreadable = false
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = max(context.date, .now)
            let fresh = snapshot?.validRemaining(window, at: now)
            let shown = fresh ?? snapshot?.lastKnownRemaining(window, at: now)
            let state = UsageState(fresh: fresh, shown: shown, threshold: threshold)
            let reset = Wording.reset(window?.resetsAt, now: now)
            QuotaReadout(title: title, remaining: shown, threshold: threshold, stale: state == .stale,
                         placeholder: snapshot == nil ? (unreadable ? "读不到" : "未获取") : "未知",
                         footnote: reset ?? (snapshot == nil ? (unreadable ? "此凭据没有额度权限" : "尚未获取额度") : shown == nil ? "需重新查询" : "重置时间未知"),
                         compact: compact)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(shown: shown, state: state, reset: reset))
        }
    }
    private func spoken(shown: Double?, state: UsageState?, reset: String?) -> String {
        let name = "\(title)窗口"
        guard let shown else { return "\(name)，\(snapshot == nil ? (unreadable ? "此凭据没有额度权限" : "尚未获取额度") : "额度未知，需重新查询")" }
        let reading = state == .stale ? "上次读数剩余 \(Wording.percent(shown))，数据已过期" : "剩余 \(Wording.percent(shown))"
        return ([name, reading] + (state == .stale ? [] : [state?.text]).compactMap { $0 } + [reset].compactMap { $0 }).joined(separator: "，")
    }
}
/// An account's quota in a few characters. Only the tighter window is named in `note`, since that is the one that runs out first.
struct QuotaSummary {
    /// "72%", "8% 偏低", "已到阈值", "54% 过期", "未知".
    var note: String
    var tone: Tone = .neutral
    /// Both windows, for a row that has room: "5 小时 72% · 7 天 54%".
    var both: String
    var spoken: String
    /// The same state as an expression for the account's sprite.
    var mood: Mood = .idle
    init(snapshot: UsageSnapshot?, threshold: Double, now: Date) {
        guard let snapshot else { note = "未获取"; both = "尚未获取额度"; spoken = "尚未获取额度"; return }
        let entries = [("5 小时", snapshot.fiveHour), ("7 天", snapshot.sevenDay)].compactMap { name, window in
            snapshot.lastKnownRemaining(window, at: now).map { (name: name, value: $0, fresh: snapshot.validRemaining(window, at: now)) }
        }
        guard let tight = entries.min(by: { $0.value < $1.value }) else { note = "未知"; both = "需重新查询"; spoken = "额度未知，需重新查询"; return }
        let state = UsageState(fresh: tight.fresh, shown: tight.value, threshold: threshold)
        // Short enough to sit under an orb.
        switch state {
        case .reached: note = "已到阈值"
        case .low: note = Wording.percent(tight.value) + " 偏低"
        case .stale: note = Wording.percent(tight.value) + " 过期"
        case nil: note = Wording.percent(tight.value)
        }
        tone = state?.tone ?? .neutral
        mood = state == .reached ? .asleep : state == .low ? .drowsy : .idle
        both = entries.map { "\($0.name) \(Wording.percent($0.value))" }.joined(separator: " · ") + (state.map { " · " + $0.text } ?? "")
        spoken = entries.map { "\($0.name)剩余 \(Wording.percent($0.value))" }.joined(separator: "，") + (state.map { "，" + $0.text } ?? "")
    }
}
extension AppModel {
    /// The relay queue as the track draws it, in priority order.
    var runners: [Runner] {
        let now = max(clock, .now)
        let slots = spriteSlots
        return accounts.map { account in
            let summary = QuotaSummary(snapshot: account.usage, threshold: threshold, now: now)
            let note = !account.enabled ? "已停用" : account.usage == nil && account.usageCapability == .unavailable ? "读不到额度" : summary.note
            return Runner(id: account.id, slot: slots[account.id] ?? 0, name: account.label, note: note, noteTone: account.enabled ? summary.tone : .neutral, stopped: !account.enabled, mood: summary.mood)
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
/// One account on the accounts page: who, what it can do, how much is left, and the actions.
struct AccountRow: View {
    @Bindable var model: AppModel
    let account: Account
    let index: Int
    var onRename: () -> Void
    var onDelete: () -> Void
    private var active: Bool { account.id == model.library.activeID }
    private var canSwitch: Bool { !active && account.enabled && !model.busy && !model.loading }
    private var capabilities: String {
        let usage = account.usageCapability == .verified ? "可读取额度" : account.usageCapability == .unavailable ? "额度权限不足" : "额度待验证"
        return [account.kind.title, usage, model.demo ? "演示能力" : "热切换待验证"].joined(separator: " · ")
    }
    var body: some View {
        let summary = QuotaSummary(snapshot: account.usage, threshold: model.threshold, now: max(model.clock, .now))
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .medium)).foregroundStyle(Tokens.faint)
                .frame(width: 14).help("拖动调整接力顺序").accessibilityHidden(true)
            HStack(spacing: 12) {
                Sprite(slot: model.spriteSlot(account.id), size: 34, mood: summary.mood, muted: !account.enabled)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(account.label).font(Typo.label).lineLimit(1)
                        if active { Pill(text: "使用中", style: .ink) }
                        if !account.enabled { Pill(text: "已停用") }
                    }
                    Text(capabilities).font(Typo.caption).foregroundStyle(Tokens.muted).lineLimit(1)
                    if let issue = account.issue {
                        Label(issue, systemImage: "exclamationmark.circle").font(Typo.caption).foregroundStyle(Tone.danger.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(account.usage == nil && account.usageCapability == .unavailable ? "读不到额度" : summary.both).font(Typo.captionStrong).monospacedDigit()
                    .foregroundStyle(summary.tone == .neutral ? AnyShapeStyle(Tokens.muted) : summary.tone.text)
                    .accessibilityLabel(summary.spoken)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("优先级 \(index + 1)，\(account.label)\(active ? "，使用中" : "")\(account.enabled ? "" : "，已停用")，\(capabilities)，\(summary.spoken)\(account.issue.map { "，" + $0 } ?? "")")
            if !active {
                Button("切换") { Task { await model.apply(account.id) } }
                    .buttonStyle(.lilt(.secondary, size: .small)).disabled(!canSwitch)
                    .help("把此账号的凭据写入 Lilt 作用域").accessibilityLabel("切换到 \(account.label)")
            }
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
                    .frame(width: 30, height: 30).contentShape(Circle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(model.busy || model.loading).help("更多").accessibilityLabel("\(account.label) 的更多操作")
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 12)
        .object(radius: 18)
    }
}
