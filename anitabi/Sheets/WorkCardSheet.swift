//
//  WorkCardSheet.swift
//  anitabi
//
//  作品カード（設計稿 1c / 2b）。档で変わるのは頭部だけ —— 一段式は**身份条**（標題＋副題＋
//  「全部点位」＋✕ の 1 行）にして残りを地図に譲り、两段式以上は標題ブロックに戻る。
//  「全部点位」が一段式だけなのは、中/大档では地図が隠れていて押しても何も見えないから。
//
//  点数の多い作品（600 点超）を開いたときに画面全体が固まらないよう、このカードは 2 つの約束を
//  守る —— **一覧は行単位で `LazyVStack` に載せる**（`WorkListElement`）ことと、**分组を body で
//  組み直さない**こと（`listing`）。どちらも「1 行ぶんの仕事 × 600」を毎フレーム走らせないため。
//

import SwiftUI

struct WorkCardSheet: View {

    let store: AnitabiStore
    let workID: Int
    /// `store` のデータ世代。**視図の値として持つ**のが肝 —— 名前・劇照は点数を変えずに後から
    /// 合流するので、これが無いと下の `==` が「変わっていない」と誤判定してカードが古いまま固まる。
    let dataGeneration: Int
    /// 現在开いている地標カードの id。同じ作品内の点なら一覧行をハイライトする。
    var selectedPointID: String?
    /// 最小档に落ちているか（設計稿 2b 一段式の身份条へ切り替える）。
    var isMinimized = false
    /// 一覧から地標を選んだ経路。地図からの選択とは違い、呼び出し側が镜头を寄せる。
    var onSelectPoint: (ScenePoint) -> Void
    var onClose: () -> Void
    /// 一段式の「全部点位」＝ RootView に fitWork を再発行してもらう（近接レベルの通常選択では画角を変えない）。
    var onRefit: () -> Void

    /// 全作品で共有する分组方式。作品を跨いでも前回の選択を覚えておく（web 版のタブ記憶と同じ）。
    @AppStorage("workGroupMode") private var groupMode: WorkGroupingMode = .folder
    @Environment(\.sheetBottomInset) private var sheetBottomInset

    @State private var collapsedGroupIDs: Set<String> = []
    @State private var listing = WorkListing()
    /// 外链胶囊は router を介さず、このカード自身で開閉する。
    @State private var safariItem: SafariItem?

    private var bangumi: BangumiLite? { store.bangumi(id: workID) }

    // MARK: - 分组の計算結果（body では組み直さない）

    /// 一覧まわりの派生値。**すべて `rebuild()` でしか作らない** —— 素直に computed property に
    /// すると 1 回の body 評価で 600 点の全量分组が 3〜4 回走り、sheet を拖动する間それが
    /// 毎フレームになる（拖动中は `RootView` の中身の高さが毎フレーム変わるため）。
    private struct WorkListing {
        var groups: [PointGroup] = []
        /// 行単位まで平らにした一覧（`LazyVStack` の直接の子になる粒度）。
        var elements: [WorkListElement] = []
        /// 組頭と分组控件を出すか。folder 组数が 2 以上、または ep を持つ点が 1 つでもあるとき。
        /// 両方とも無ければ（＝単一フォルダで話数も無い）平铺一覧に落とす。
        var showsGroupingControls = false
        var hasAnyEpisode = false
        var pointCount = 0
        var name = ""
        var themeColor: Color = .anitabiNeutralTheme
    }

    /// これが変わったときだけ組み直す。
    private struct RebuildKey: Equatable {
        var workID: Int
        var mode: WorkGroupingMode
        var generation: Int
    }

    private var rebuildKey: RebuildKey {
        RebuildKey(workID: workID, mode: groupMode, generation: dataGeneration)
    }

    /// 分组を 1 回だけ回して派生値を全部作る。`groupedPoints` は**多くとも 1 回**しか呼ばない。
    private func rebuild() {
        let points = store.pointsByBangumi[workID] ?? []
        let hasAnyEpisode = points.contains { $0.ep?.nilIfBlank != nil }

        var next = WorkListing()
        next.hasAnyEpisode = hasAnyEpisode
        next.pointCount = points.count
        next.name = store.name(forBangumi: workID)
        next.themeColor = store.color(forBangumi: workID)

        // ep が 1 つも無い作品では `groupMode` が過去に「話数」を指していても folder に落とす
        // （@AppStorage は全作品共有なので、ここを書き換えて次の作品の選択を壊さないようにする）。
        if hasAnyEpisode, groupMode == .episode {
            next.groups = store.groupedPoints(for: workID, mode: .episode)
            // 話数モードに入れている時点で ep はある＝控件は必ず出る。
            next.showsGroupingControls = true
        } else {
            next.groups = store.groupedPoints(for: workID, mode: .folder)
            next.showsGroupingControls = next.groups.count > 1 || hasAnyEpisode
        }

        // 初期状態は常に全展开（折叠は「全部折叠」ボタンから明示的に行う）。
        collapsedGroupIDs = []
        next.elements = WorkListElement.flatten(
            next.groups,
            showsHeaders: next.showsGroupingControls,
            collapsedGroupIDs: []
        )
        listing = next
    }

    /// 折り畳みの変更は**同じトランザクションで**一覧も組み直す —— `onChange` に回すと
    /// 別トランザクションになって、行の出入りがバネに乗らない。
    private func setCollapsed(_ ids: Set<String>) {
        withAnimation(.anitabiSpring) {
            collapsedGroupIDs = ids
            listing.elements = WorkListElement.flatten(
                listing.groups,
                showsHeaders: listing.showsGroupingControls,
                collapsedGroupIDs: ids
            )
        }
    }

    private var isFullyExpanded: Bool { collapsedGroupIDs.isEmpty }

    /// データ完走前にこのカードへ深链で入った場合だけ骨架屏を出す。`geometryOnly` は点数こそ
    /// あるが作品名・点名が空文字なので、実物の一覧を出すと白紙の行が並ぶ —— 名前が来るまで骨架。
    private var isLoadingSkeleton: Bool {
        guard listing.pointCount == 0 || listing.name.isEmpty else { return false }
        switch store.phase {
        case .empty, .geometryOnly: return true
        case .complete, .failed: return false
        }
    }

    // MARK: - 本体

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(isCompact: isMinimized)
                    // 最小档は**一段式の身份条の実高**。中/大档では頭部の余白と部品が変わるので、
                    // 一段式の姿の複製を隠して置き、常にそちらを測る。
                    .overlay(alignment: .top) { header(isCompact: true).compactHeightProbe(.work) }

                if isLoadingSkeleton {
                    WorkCardSkeleton()
                        .collapsedInCompactStage(isMinimized ? .compact : .medium)
                        .transition(.opacity)
                } else {
                    workCardBody
                        .transition(.opacity)
                }
            }
            .scenePadding(.horizontal)
            .sheetScrollBottomPadding(sheetBottomInset)
            .animatesSheetStage(isMinimized ? .compact : .medium)
            .animation(.anitabiSpring, value: isLoadingSkeleton)
        }
        .onChange(of: rebuildKey, initial: true) { _, _ in rebuild() }
        .sheet(item: $safariItem) { item in SafariSheet(url: item.url) }
    }

    // **`spacing: 0`** ―― 子には一覧の行も直接混ざるので、節と節の間隔は
    // 各要素が自分で持つ。ここに器を 1 枚でも挟むと惰性化が効かなくなる。
    private var workCardBody: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            infoCard
                .padding(.bottom, SheetMetrics.sectionSpacing)

            if listing.showsGroupingControls {
                groupingControlsRow
                    .padding(.bottom, SheetMetrics.sectionSpacing)
            }

            // 一覧の本体。組で束ねず 1 行 1 要素で渡すので、視口に入った行しか作られない。
            ForEach(listing.elements) { element in
                switch element {
                case .header(let groupHeader):
                    WorkPointGroupHeader(header: groupHeader) {
                        toggleGroup(groupHeader.id)
                    }
                case .row(let row):
                    WorkPointCell(
                        store: store,
                        row: row,
                        selectedPointID: selectedPointID,
                        themeColor: listing.themeColor,
                        onSelect: onSelectPoint
                    )
                }
            }

            externalLinksRow
                .padding(.top, SheetMetrics.sectionSpacing)
            contributorRow
                .padding(.top, SheetMetrics.sectionSpacing)
        }
        .collapsedInCompactStage(isMinimized ? .compact : .medium)
    }

    private func toggleGroup(_ id: String) {
        var ids = collapsedGroupIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        setCollapsed(ids)
    }

    // MARK: 1. 頭部（設計稿 2b）

    /// **1 つの容器のまま档を跨ぐ**頭部（一段式＝設計稿 2b 身份条、中/大档＝標題ブロック）。
    /// 位移感の要は器を入れ替えないこと —— 行揃え・行距・余白は数値のまま切り替え、バネが
    /// その差を補間するので、標題・副題・✕ が同じ視図のまま新しい位置へ滑る。入れ替わるのは
    /// 避けようがない葉だけ（跑马灯 ↔ 2 行標題、「全部点位」↔ 共有）で、それらは原位で淡換する。
    private func header(isCompact: Bool) -> some View {
        HStack(
            alignment: isCompact ? .center : .top,
            spacing: SheetMetrics.circleButtonGap
        ) {
            VStack(
                alignment: .leading,
                spacing: isCompact ? SheetMetrics.rowTitleGap : SheetMetrics.titleSubtitleGap
            ) {
                // 標題の槽。一段式は 1 行で横に流し（`MarqueeText`）、中/大档は 2 行で折る ——
                // この 2 つだけは同じ視図にできないので、槽の中で原位淡換する
                // （槽そのものは行揃え・余白の補間に乗って滑る）。
                ZStack(alignment: .topLeading) {
                    if isLoadingSkeleton {
                        SkeletonBar(width: 160, height: isCompact ? 13 : 14)
                            .anitabiSkeletonShimmer()
                            .transition(.opacity)
                    } else if isCompact {
                        MarqueeText(text: listing.name, font: SheetFont.titleCompactWork)
                            .transition(.opacity)
                    } else {
                        Text(listing.name)
                            .font(SheetFont.titleLarge)
                            .foregroundStyle(Color.anitabiInk)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                if isLoadingSkeleton {
                    SkeletonBar(width: 110, height: 9)
                        .anitabiSkeletonShimmer()
                        .transition(.opacity)
                } else {
                    subtitleRow(includesScreenshots: !isCompact)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 行末の連れ合いだけが入れ替わる（一段式は地図が見えているから「全部点位」、
            // 中/大档は共有）。✕ は同じ視図のまま余白の補間に乗って滑る。
            if isCompact {
                // 隣の ✕ と同じ背丈（`barChip`）。行末に並ぶコントロールは高さを揃える。
                Button("全部点位", action: onRefit)
                    .buttonStyle(AnitabiCapsuleStyle(kind: .primary, size: .barChip))
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                ShareLink(item: shareURL, subject: shareSubject) {
                    CardCircleLabel(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("分享")
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            CardCloseButton(action: onClose)
        }
        .stageHeaderFrame(isCompact: isCompact)
    }

    /// 設計稿の副題：主題色点 ＋ `{cat} · {city} · {N 个点位}`（中/大档はさらに `{M 张截图}`）。
    private func subtitleRow(includesScreenshots: Bool) -> some View {
        HStack(spacing: SheetMetrics.scaled(5)) {
            ThemeDot(color: listing.themeColor, size: SheetMetrics.dotSize)
            Text(subtitleText(includesScreenshots: includesScreenshots))
                .lineLimit(1)
                // 档で末尾の「N 张截图」が付いたり落ちたりする。字は原位で淡換して、
                // 行そのものは頭部の余白補間に乗って滑る。
                .contentTransition(.opacity)
        }
        .font(SheetFont.rowMeta)
        .foregroundStyle(Color.anitabiInkSecondary)
    }

    private func subtitleText(includesScreenshots: Bool) -> String {
        var parts: [String] = []
        if let cat = bangumi?.cat?.nilIfBlank { parts.append(cat) }
        if let city = bangumi?.city?.nilIfBlank { parts.append(city) }
        parts.append(String(localized: "\(listing.pointCount) 个点位"))
        if includesScreenshots {
            let screenshotCount = store.screenshotCount(forBangumi: workID)
            if screenshotCount > 0 { parts.append(String(localized: "\(screenshotCount) 张截图")) }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 2. 情報カード（設計稿 2b の `44×60 封面 ＋ 原名/© ＋ 更新日`）

    private var infoCard: some View {
        SheetGroupCard {
            HStack(alignment: .center, spacing: SheetMetrics.thumbnailGap) {
                RoundedRectangle(cornerRadius: SheetMetrics.infoCoverRadius, style: .continuous)
                    .fill(listing.themeColor.anitabiThemeGradient)
                    .overlay {
                        if let url = headerCoverURL {
                            RemoteImage(url: url) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFill()
                                }
                            }
                        }
                    }
                    .frame(width: SheetMetrics.infoCoverSize.width, height: SheetMetrics.infoCoverSize.height)
                    .clipShape(.rect(cornerRadius: SheetMetrics.infoCoverRadius, style: .continuous))

                VStack(alignment: .leading, spacing: SheetMetrics.scaled(3)) {
                    if let title = bangumi?.title?.nilIfBlank {
                        Text("© \(title)")
                            .font(SheetFont.rowMeta)
                            .foregroundStyle(Color.anitabiInkSecondary)
                            .lineLimit(2)
                    }
                    if let modified = store.modified(forBangumi: workID) {
                        Text("更新于 \(Self.dateFormatter.string(from: modified))")
                            .font(SheetFont.meta)
                            .foregroundStyle(Color.anitabiInkTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// 剧照 CDN の 512×288 上限（`image.anitabi.cn`）とは別枠——封面は `/images/bangumi/` 経由の
    /// 別 plan 群を持つので、44×60 の器に見合う h360 を明示指定する。
    private var headerCoverURL: URL? {
        AnitabiImage.url(path: bangumi?.cover, plan: "h360")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    private var shareURL: URL {
        URL(string: "https://anitabi.cn/map?bangumiId=\(workID)")!
    }

    private var shareSubject: Text {
        Text("《\(listing.name)》的巡礼地图")
    }

    // MARK: 3. 分组控件行（設計稿 2b：分段控件 ＋ 「全部展开」カプセル）

    private var groupingControlsRow: some View {
        HStack(spacing: SheetMetrics.itemSpacing) {
            AnitabiSegmentedPicker(
                selection: $groupMode,
                options: listing.hasAnyEpisode
                    ? [AnitabiSegment(.folder, "按分组"), AnitabiSegment(.episode, "按话数")]
                    : [AnitabiSegment(.folder, "按分组")]
            )
            Button(isFullyExpanded ? "全部折叠" : "全部展开") {
                setCollapsed(isFullyExpanded ? Set(listing.groups.map(\.id)) : [])
            }
            .buttonStyle(AnitabiCapsuleStyle(kind: .secondary, size: .rowChip))
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: 4. 外链（設計稿 2b：白い薄膜のカプセルを折り返して並べる）

    private var externalLinksRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SheetMetrics.itemSpacing) {
                ForEach(externalLinks, id: \.title) { link in
                    Button {
                        safariItem = SafariItem(url: link.url)
                    } label: {
                        HStack(spacing: SheetMetrics.scaled(4)) {
                            Text(link.title)
                            Image(systemName: "arrow.up.right")
                                .font(SheetFont.meta)
                        }
                    }
                    .buttonStyle(AnitabiCapsuleStyle(kind: .secondary, size: .chip))
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }

    /// 外链胶囊の並び。中国語圏の百科・Google 検索は非 ASCII を含むので必ずパーセントエンコードする。
    private var externalLinks: [(title: String, url: URL)] {
        guard let bangumi else { return [] }
        var links: [(String, URL)] = [
            ("Bangumi", URL(string: "https://bgm.tv/subject/\(bangumi.id)")!)
        ]

        let cnQuery = bangumi.cn?.nilIfBlank ?? bangumi.displayName
        if !cnQuery.isEmpty {
            if let encoded = cnQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "https://zh.wikipedia.org/w/index.php?search=\(encoded)") {
                links.append((String(localized: "维基百科"), url))
            }
            if let encoded = cnQuery.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let url = URL(string: "https://zh.moegirl.org.cn/\(encoded)") {
                links.append((String(localized: "萌娘百科"), url))
            }
        }

        let googleQuery = (bangumi.title?.nilIfBlank ?? bangumi.cn?.nilIfBlank ?? bangumi.displayName) + " 聖地巡礼"
        if let encoded = googleQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            links.append((String(localized: "Google 圣地巡礼"), url))
        }

        return links
    }

    // MARK: 5. 貢献者（設計稿 2b：22pt の丸を 8pt 重ねて並べ、右に人数と授权）

    @ViewBuilder
    private var contributorRow: some View {
        let summary = store.contributorSummary(forBangumi: workID)
        HStack(spacing: SheetMetrics.itemSpacing) {
            if let summary, !summary.top.isEmpty {
                // 設計稿は色違いの丸 3 つ。貢献者ごとの画像は API に無いので、
                // 記号（人）＋作品の主題色で「人が居る」ことだけを示す（字の代替は置かない——硬約束）。
                HStack(spacing: -SheetMetrics.scaled(8)) {
                    ForEach(Array(summary.top.prefix(3).enumerated()), id: \.offset) { index, _ in
                        Image(systemName: "person.fill")
                            .font(SheetFont.meta)
                            .foregroundStyle(Color.anitabiOnAccent)
                            .frame(width: SheetMetrics.contributorAvatarDiameter, height: SheetMetrics.contributorAvatarDiameter)
                            .background(listing.themeColor.opacity(1 - Double(index) * 0.2), in: .circle)
                            .overlay { Circle().strokeBorder(Color.anitabiRaisedStroke, lineWidth: SheetMetrics.shape(2)) }
                    }
                }
            }
            // 授权表記は設計稿どおり同じ 1 行の末尾に付ける。翻訳キーを増やさないため、
            // 既存キーの訳文へ `verbatim` で連結する（`CC BY-NC-SA 4.0` は 3 言語共通の固有名）。
            Text(verbatim: summary.map { "\(contributorText($0)) · CC BY-NC-SA 4.0" }
                 ?? String(localized: "数据由 anitabi.cn 社区贡献 · CC BY-NC-SA 4.0"))
                .font(SheetFont.meta)
                .foregroundStyle(Color.anitabiInkTertiary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    /// total ≤2 なら「等」を省いた自然な語順にする。
    private func contributorText(_ summary: (top: [String], total: Int)) -> String {
        let names = summary.top.map { "@\($0)" }
        guard !names.isEmpty else {
            return String(localized: "由 \(summary.total) 位贡献者收集")
        }
        let joined = names.joined(separator: "、")
        if summary.total <= 2 {
            return String(localized: "由 \(joined) 收集")
        }
        return String(localized: "由 \(joined) 等 \(summary.total) 位贡献者收集")
    }
}

// MARK: - 再評価の遮断

/// `RootView` は sheet を拖动する間、中身の高さを毎フレーム `@State` に書く。そのままだと
/// このカードの body も毎フレーム走り、点数の多い作品では一覧の再構築がそこにぶら下がる。
/// **値が変わっていなければ body ごと飛ばす**ためだけの `Equatable`。
///
/// 閉包（`onSelectPoint` など）を比較から外しても古い挙動には固まらない —— 中で読んでいる
/// `RootView` の `@State` はどれも箱への参照なので、古い `self` を捕まえた閉包から読んでも
/// 現在値が返る。**データの世代（`dataGeneration`）だけは値として持つ**必要があるので、
/// それは上で明示的に受け取っている。
extension WorkCardSheet: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store
            && lhs.workID == rhs.workID
            && lhs.dataGeneration == rhs.dataGeneration
            && lhs.selectedPointID == rhs.selectedPointID
            && lhs.isMinimized == rhs.isMinimized
    }
}
