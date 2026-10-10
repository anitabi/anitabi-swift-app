//
//  RootView.swift
//  anitabi
//
//  全画面の地図 ＋ **常に 1 枚だけ**の sheet（Apple マップの呈现モデル）。sheet は重ねずに
//  **中身を差し替え**、覆われた層は mount したまま档を覚えておく。档の集合と選択中の档は
//  **必ず同じトランザクション**で動かす —— 別々だと古い選択が一瞬適用されて档が跳ねる。
//

import CoreLocation
import MapKit
import SwiftUI
import UIKit

// MARK: - 常駐 sheet の生の寸法

/// `residentSheet` の中身の実寸。**sheet の内側**で測った値だけを持つ。
private struct SheetGeometry: Equatable {
    /// 中身の高さ。拖动の途中も毎フレーム更新される。
    var height: CGFloat = 0
    /// 中身に入る底部安全区。
    var bottomInset: CGFloat = 34
    /// 中身の枠の画面座標。可視カード（`SheetShapeReader` の実測）との差を出すのに使う。
    var minY: CGFloat = 0
    /// 系统が中身の**外側・上**に確保している帯（抓手ぶん）。見積もりで埋めると一段式の
    /// 下余白が必ずずれるので実測する。
    var topChrome: CGFloat = 0
}

// MARK: - RootView

struct RootView: View {

    // MARK: 呈现スタックの 1 要素

    /// 常駐 sheet に載る 1 枚ぶんの内容。`id` は**層＋対象**で決まる —— 同じ「作品カード」でも
    /// 別の作品なら別物として扱う（档の記憶も View の identity も分ける）。
    private enum SheetContent: Identifiable, Equatable {
        case home
        case work(WorkSelection)
        case point(PointSelection)
        case droppedPin(DroppedPin)

        var id: String {
            switch self {
            case .home: "home"
            case .work(let selection): "w\(selection.id)"
            case .point(let selection): "p\(selection.id)"
            case .droppedPin(let pin): "d\(pin.id)"
            }
        }

        var layer: SheetLayer {
            switch self {
            case .home: .home
            case .work: .work
            case .point: .point
            case .droppedPin: .droppedPin
            }
        }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    @State private var store = AnitabiStore()
    @State private var locationProvider = LocationProvider()
    @State private var router = AppRouter()

    @State private var dataset = MapDataset.empty
    @State private var command: MapCameraCommand?
    /// 画面全体の大きさ。カード高さぶんの下余白・上寄せ量を実測値から出すために持つ。
    @State private var windowSize: CGSize = .zero
    /// 常駐 sheet の中身の生の寸法。**sheet の内側**で測る —— 窓の底部安全区（34）と sheet の
    /// 中身に入る底部安全区（32）は別の値で、後者でないと最小档が 2pt ずれる。
    /// 高さは拖动の**途中も**毎フレーム届くので、いま何段目かの判定にもこれを使う。
    @State private var sheetGeometry = SheetGeometry()
    /// 各層が報せてきた「一段式の中身の実高」。最小档はこの実測値で組む —— 定数だと
    /// Dynamic Type・言語でズレて、身份条が余る／切れる。一度届いた値は消さずに残す。
    @State private var compactHeights: [SheetLayer: CGFloat] = [:]
    /// 各層が報せてきた「中身の実高」（两段式・三段式ぶん）。設計稿の比率を**上限**として、
    /// 中身がそこまで無いカードは档をここまで詰める。
    @State private var fittedHeights: [SheetLayer: SheetContentHeights] = [:]
    /// 上の値の反映待ち。档を跨ぐ最中は剧照が伸び縮みし切るまで毎フレーム値が変わるので、
    /// 落ち着いてから 1 回だけ档へ渡す。
    @State private var fitTask: Task<Void, Never>?
    /// 可視カードの枠（`SheetShapeReader` の実測。グローバル座標）。
    @State private var cardFrame: CGRect?
    /// 三段式より下に居るときに見たカードの上縁（window 座標）＝署名・浮控の蓋の実測値。
    @State private var restingCardTopY: CGFloat?

    // MARK: 呈现スタック（1 枚の sheet の中身）

    /// 下から順に積んだ内容。いちばん後ろ（`top`）だけが見えている。router から導けるが
    /// **@State に写して持つ**のが肝 —— 内容と档を同じ `withAnimation` で入れ替えるには
    /// 両方が @State である必要がある。
    @State private var stack: [SheetContent] = [.home]
    /// 常駐 sheet の生きている档。全層で 1 本だけ。
    @State private var detent: PresentationDetent = SheetLayout.detent(
        SheetLayer.home.initialFraction,
        screenHeight: DesignScale.screenHeight
    )
    /// 覆われた層の档の記憶。スタックから外れた層のぶんは毎回間引くので高々 3 件。
    @State private var rememberedDetents: [String: PresentationDetent] = [:]

    @AppStorage("map.baseStyle") private var baseStyle: MapBaseStyle = .standard
    @AppStorage("map.isPhotoLayerVisible") private var isPhotoLayerVisible = true

    /// 生の `MKMapView`。`MapCanvas.onMapViewReady` から 1 回もらう —— `MKCompassButton`/
    /// `MKScaleView` が `init(mapView:)` で同じインスタンスを要求するため。
    @State private var mapView: MKMapView?
    /// 定位钮の見た目だけの状態（授权＋直近にタップ）。地図を自分で動かしたら外す。
    @State private var isLocationActive = false
    /// 「随机作品」の冷却。連打で飛行が上書きされるのを防ぐ。
    @State private var isRandomCoolingDown = false

    // MARK: 作品モードの枠追従

    /// 全景へ移動した作品だけ、档の変化にも枠を追従させる。近所を見ているときの
    /// 作品選択は画角を保つ。対象 ID を持つことで、別作品へ古い追従を持ち越さない。
    @State private var workFitID: Int?
    @State private var workFitTask: Task<Void, Never>?
    /// 選んだ地標の縦位置を実測で置き直す補正の待ち（`schedulePlacement`）。
    @State private var revealTask: Task<Void, Never>?
    /// 直近のフィットで使った可視カードの上縁。帯が実質変わっていない档移動を弾くのに使う。
    @State private var lastWorkFitCardTop: CGFloat?

    // MARK: 深リンク／Handoff／状態復元

    /// `store.bootstrap()` 完走前に着いた深リンク。完走した瞬間に 1 回だけ吐き出す。
    @State private var pendingDeepLink: MapDeepLink?
    @State private var isDataReady = false
    /// 深リンクのカメラ処理済み作品。次の作品変更通知だけ通常選択の自動フィットを抑える。
    @State private var explicitWorkCameraID: Int?
    /// 欢迎页。初期値は UserDefaults を 1 回だけ読む —— `@AppStorage` にすると門と表示状態が
    /// 同じキーに縛られ、「見終わった後にもう一度見る」を表現できなくなる。
    @State private var isWelcomePresented = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    /// Handoff で運ぶ URL。`nil` の間は `.userActivity` を非アクティブにする。
    @State private var handoffURL: URL?
    @State private var handoffDebounceTask: Task<Void, Never>?

    @Environment(\.scenePhase) private var scenePhase
    /// 字級。**値そのものは使わない** —— 寸法トークンは `UITraitCollection.current` を直に読むため
    /// SwiftUI から見ると字級への依存が無く、木が作り直されない限り古い寸法で描き続ける。
    /// これを `residentSheet` の `.id` に混ぜて、字級が変わったら中身を作り直させる。
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // 呈现キューは「シーン内で同時に有効な sheet 系は 1 枚」で `.fullScreenCover` もこれを
        // 共有する。常駐 sheet は一度も dismiss されないので、常駐側の `isPresented` を
        // `!isWelcomePresented` にして欢迎页に枠を明け渡さないと、永久に順番待ちになる。
        ZStack {
            content
            AppIdentityPillOverlay()
        }
        // 設計稿の Zen Maru Gothic に最も近い系统書体。根で 1 回だけ掛けて、シート・浮控・
        // トーストを同じ書体に揃える（等幅にしたい所だけ `SheetFont` が上書きする）。
        .fontDesign(.rounded)
        .fullScreenCover(isPresented: $isWelcomePresented) {
            WelcomeView(onFinish: { isWelcomePresented = false })
        }
    }

    private var content: some View {
        mapLayer
            // 見えている地図の大きさ。一覧から選んだ点をカードの上へ逃がす量に使う。
            .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
            .sheet(isPresented: .constant(!isWelcomePresented)) { residentSheet }
            .task {
                if locationProvider.isAuthorized { locationProvider.start() }
                await store.bootstrap()
                // 名前・劇照は点数を変えずに後からマージされるので、完走後にもう一度取り込む。
                reloadDataset()
                isDataReady = true
                resolveInitialState()
            }
            .onChange(of: store.points.count) { _, _ in reloadDataset() }
            // 呈现スタックの唯一の同期点。router がどんな順で書き換わっても、
            // 落ち着いた後の姿がここに 1 回だけ届く（同一フレーム内の複数変更はまとめて 1 回）。
            .onChange(of: routerStack) { _, _ in syncStack() }
            .onChange(of: router.workCard) { _, new in didOpenWork(new) }
            // 档が吸着したら枠を置き直す（畳めば中央へゆっくり収まる）。`PresentationDetent` は
            // 吸着後にしか変わらないので、拖动の途中に镜头が付いてくることはない。
            .onChange(of: detent) { _, _ in scheduleWorkRefit() }
            .onChange(of: router.wantsWelcomeReplay) { _, wants in
                guard wants else { return }
                router.wantsWelcomeReplay = false
                isWelcomePresented = true
            }
            // Handoff（600ms 防抖）。選択状態と镜头静止のどちらも「今どこを見ているか」の
            // 一部なので、まとめて同じデバウンスに乗せる。
            .onChange(of: router.workCard) { _, _ in scheduleHandoffUpdate() }
            .onChange(of: router.pointCard) { _, _ in scheduleHandoffUpdate() }
            .onChange(of: router.selectedWorkIDs) { _, _ in scheduleHandoffUpdate() }
            .onChange(of: router.cameraState) { _, _ in scheduleHandoffUpdate() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { currentDeepLink.persist() }
            }
            .userActivity(NSUserActivityTypeBrowsingWeb, isActive: handoffURL != nil) { activity in
                activity.webpageURL = handoffURL
                activity.isEligibleForHandoff = true
            }
            .onOpenURL { url in
                guard let link = MapDeepLink(url: url) else { return }
                receive(deepLink: link)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL, let link = MapDeepLink(url: url) else { return }
                receive(deepLink: link)
            }
    }

    // MARK: 地図

    private var mapLayer: some View {
        ZStack {
            MapCanvas(
                dataset: dataset,
                command: command,
                focusedWorkID: router.focusedWorkID,
                selectedWorkIDs: router.selectedWorkIDs,
                selectedPointID: router.selectedPointID,
                isPhotoLayerVisible: isPhotoLayerVisible,
                baseStyle: baseStyle,
                attributionLift: attributionLift,
                droppedPinCoordinate: router.droppedPin?.coordinate,
                onSelectPoint: { selectPointFromMap($0) },  // 地図経由は镜头を動かさない
                onSelectWork: { router.focusWork(id: $0) },
                onTapDimRegion: { router.backToBrowse() },
                onTapBlank: { router.closePointCard() },
                onLongPress: { router.dropPin(at: $0) },
                onCameraIdle: { router.cameraState = $0 },
                onUserInteractionBegan: collapseTopSheet,
                // `makeUIView` の最中に `@State` を書き換えると「ビュー更新中に状態変更」の
                // 実行時警告になるので、必ず 1 拍遅らせる。
                onMapViewReady: { view in DispatchQueue.main.async { mapView = view } }
            )
            // 浮控列は**地図の overlay として**載せ、`.ignoresSafeArea()` は**その後**に掛ける。
            // 順番が肝：外側に付けると overlay は「広がる前」の枠（下端 ＝ 安全区の上端）に並び、
            // `mapView.bounds.maxY` を物差しにしている下余白と 34pt 食い違う。
            .overlay(alignment: .bottomTrailing) {
                if let mapView {
                    mapControls(mapView)
                        .opacity(isMapChromeHidden ? 0 : 1)
                        .animation(.anitabiSpring, value: isMapChromeHidden)
                }
            }
            // 「随机作品」は左下・Apple 署名の**上**（浮控列と対になる位置）。同じ物差しを
            // 通すため、こちらも `.ignoresSafeArea()` より内側に置く。
            .overlay(alignment: .bottomLeading) {
                if let mapView {
                    randomWorkButton(mapView)
                        .opacity(isMapChromeHidden ? 0 : 1)
                        .animation(.anitabiSpring, value: isMapChromeHidden)
                }
            }
            .ignoresSafeArea()

            // 比例尺は左上（Apple マップ同位）。こちらは安全区を尊重する側に置くので
            // Dynamic Island の下に自然に収まる。
            if let mapView {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        MapScaleView(mapView: mapView)
                            .fixedSize()
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 16)
                    Spacer(minLength: 0)
                }
                .opacity(isMapChromeHidden ? 0 : 1)
                .animation(.anitabiSpring, value: isMapChromeHidden)
            }

            VStack(spacing: 0) {
                ToastOverlayView(toast: router.toast.current)
                    .padding(.top, 8)
                Spacer(minLength: 0)
            }
        }
    }

    /// 浮控列（定位・底図・方位）。左下の署名と同じく、カードの上縁に貼り付いて拖动に追従する。
    private func mapControls(_ mapView: MKMapView) -> some View {
        MapControlStack(
            mapView: mapView,
            isLocationAuthorized: locationProvider.isAuthorized,
            isLocationActive: $isLocationActive,
            baseStyle: $baseStyle,
            isPhotoLayerVisible: $isPhotoLayerVisible,
            onLocationTap: handleLocationTap
        )
        .padding(.trailing, 16)
        .padding(.bottom, controlsBottomMargin(mapView))
    }

    /// 浮控列の下余白＝「地図の下端からカードの上縁まで」＋隙間。
    /// 持ち上げ量は**署名とまったく同じ関数から取る**（`MapAttributionLift.resolvedLift`）ので、
    /// 左下の署名と右下の浮控が別の物差しに分かれることがない。
    private func controlsBottomMargin(_ mapView: MKMapView) -> CGFloat {
        let gap = Self.controlsCardGap
        let lift = attributionLift
        // 実測が届く前（初回フレーム・欢迎页の裏）は两段式の見積もりに置いておく。
        return (lift.resolvedLift(in: mapView) ?? lift.ceiling) + gap
    }

    /// カードの上縁との隙間（Apple マップ実物と同じ「浮きぶん 8 ＋ 8」）。
    private static let controlsCardGap = SheetLayout.floatingGap + 8

    /// 「随机作品」釦（左下）。浮控列と対になる位置＝Apple 署名の真上に置く。
    private func randomWorkButton(_ mapView: MKMapView) -> some View {
        MapRandomWorkButton(isCoolingDown: isRandomCoolingDown, action: rollRandomWork)
            .padding(.leading, 16)
            .padding(.bottom, randomButtonBottomMargin(mapView))
    }

    /// 釦の下余白。持ち上げ量は署名・浮控列と同じ関数から取るので 3 つが同じ高さで動く。
    /// 違うのは足す帯だけ —— こちらは署名を**跨がねばならない**。
    private func randomButtonBottomMargin(_ mapView: MKMapView) -> CGFloat {
        let lift = attributionLift
        return (lift.resolvedLift(in: mapView) ?? lift.ceiling) + Self.attributionBand
    }

    /// 署名が持ち上げ線の上に占める帯 ＋ 釦との隙間（署名の下端は余白線の約 10pt 上、
    /// 署名そのものが約 18pt、その上へ 8pt）。
    private static let attributionBand: CGFloat = 36

    /// 三段式（設計稿 92.2%）まで持ち上がったら地図の付属品（浮控・比例尺）は退かせる。
    private var isMapChromeHidden: Bool { stage(of: top) == .expanded }

    /// 署名をカードの上へ逃がす指令。カードを持ち上げる間は貼り付いて一緒に上がるが**三段目までは
    /// 追わない**（追うと署名だけが地図の上端まで登る）ので、蓋を两段式の上縁に置く。
    /// 蓋は**実測を第一の出所にする** —— 見積もりが実物より低い端末では署名がカードの下に潜る。
    private var attributionLift: MapAttributionLift {
        let layer = top.layer
        let medium = layer.initialHeight(
            screenHeight: DesignScale.screenHeight, fitted: fittedHeights[layer]
        )
        return MapAttributionLift(
            cardTopY: cardFrame?.minY,
            restingCardTopY: restingCardTopY,
            ceiling: medium + sheetGeometry.bottomInset + SheetLayout.floatingGap
        )
    }

    /// 三段式へ持ち上げる前に見たカードの上縁を覚える＝蓋の実測値。window 座標をそのまま持つので
    /// `mapView` がまだ来ていなくても記録できる（`SheetShapeReader` は同じ枠を 2 回報せないため、
    /// 取り逃すと二度と来ない）。カードが差し替わったら忘れる。
    private func recordRestingCardTop(_ frame: CGRect?) {
        guard let frame, stage(of: top) != .expanded else { return }
        restingCardTopY = frame.minY
    }

    // MARK: 常駐 sheet（1 枚）

    /// いちばん上に乗っている内容。呈现・档・背景交互の全部がこれ 1 つから決まる。
    private var top: SheetContent { stack.last ?? .home }

    /// 新しいカードは少し下から浮き上がりつつ現れ、古いカードはその場で淡出する。
    /// カード 1 枚ぶん丸ごとスライドさせると、同時に動く档と喧嘩して見える —— Apple の実物も
    /// 大きくは滑らないので、浮き上がりは 24pt に留めて淡入淡出を主にする。
    private static let cardTransition = AnyTransition.asymmetric(
        insertion: .offset(y: 24).combined(with: .opacity),
        removal: .opacity
    )

    /// 常駐 sheet の中身。**閉じない・積まない** —— 中身だけが入れ替わる。下の層を `if` で
    /// 消さずに隠すのは、検索文字列・スクロール位置・折り畳み状態を保つため（消すと
    /// @State ごと作り直しになる）。
    private var residentSheet: some View {
        ZStack(alignment: .top) {
            ForEach(stack) { entry in
                sheetContent(entry)
                    // 隠れた層の最小高さを sheet に**伝えない** —— 潰せない首页の身份条があると、
                    // より低い他カードの一段式では ZStack の最小高さが档を超え、系统が中身を
                    // センタリングしてカードの上下へはみ出す。高さ 0 の枠に上詰めで収める。
                    .frame(maxHeight: entry.id == top.id ? .infinity : 0, alignment: .top)
                    .opacity(entry.id == top.id ? 1 : 0)
                    .allowsHitTesting(entry.id == top.id)
                    .accessibilityHidden(entry.id != top.id)
                    .transition(Self.cardTransition)
            }
        }
        // 字級が変わったらカードを作り直す（上の `dynamicTypeSize` のメモ参照）。
        .id(dynamicTypeSize)
        // 系统は中身を底部安全区の**上**に閉じ込めるので、ここで無効にして可視カードの下端まで
        // 使う（スクロールする列の末尾だけ `sheetScrollBottomPadding` で足し戻す）。
        // **必ず呈现修饰より内側に付けること** —— 外側に付けても効かない。
        .ignoresSafeArea(.container, edges: .bottom)
        // 档の集合と選択は同じ `top` から出る＝必ず同じ更新で入れ替わる。
        .presentationDetents(
            top.layer.detents(
                measured: compactHeights[top.layer],
                fitted: fittedHeights[top.layer],
                screenHeight: DesignScale.screenHeight
            ),
            selection: $detent
        )
        // 系统の material の上に設計稿の合成色を敷く（中身の面はガラスにしない）。iOS 26 の
        // 公式指針は「系统の Liquid Glass に任せる」だが**ここは意図的に外れる** —— 系统のガラスは
        // 透けすぎて地図の海・緑地・全彩の剧照標が映り込む。地色はこのアプリの identity。
        .presentationBackground {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(Color.anitabiCardGlass)
                .ignoresSafeArea()
        }
        // 半开までは地図に直接触れる。全开のときだけ sheet が地図を占有する。
        .presentationBackgroundInteraction(.enabled(upThrough: initialDetent(top.layer)))
        .presentationDragIndicator(.visible)
        // 下スワイプで閉じない（＝各層の mini 档が下限）。閉じるのは ✕ だけ。
        .interactiveDismissDisabled()
        .environment(\.sheetBottomInset, sheetGeometry.bottomInset)
        // 可視カードの枠を UIKit 側から実測する（SwiftUI の中身の枠とは一致せず、系统は API でも
        // safe area でも教えてくれない）。
        .background {
            SheetShapeReader { frame in
                cardFrame = frame
                recordRestingCardTop(frame)
            }
        }
        .environment(\.compactBarInsets, compactBarInsets)
        .onGeometryChange(for: SheetGeometry.self) { proxy in
            SheetGeometry(
                height: proxy.size.height,
                bottomInset: proxy.safeAreaInsets.bottom,
                minY: proxy.frame(in: .global).minY,
                topChrome: proxy.frame(in: .global).minY - (DesignScale.screenHeight - proxy.size.height)
            )
        } action: { sheetGeometry = $0 }
        // 身份条の実高が届いたら覚える。1pt 未満の揺れでは書き換えない —— 拖动中に @State を
        // 毎フレーム書くと档の集合が作り直されて操作が重くなる。
        .onPreferenceChange(CompactContentHeightKey.self) { measured in
            for (layer, height) in measured where height > 1 {
                let old = compactHeights[layer]
                guard abs((old ?? -1) - height) > 1 else { continue }
                compactHeights[layer] = height
                // 一段式に**居る最中**に実高が変わったら、選択中の档も同じ更新で新しい最小档へ
                // 移す。置き去りにすると古い選択が集合から消え、系统が初期档まで跳ね上げる。
                if layer == top.layer, detent == layer.minDetent(measured: old) {
                    detent = layer.minDetent(measured: height)
                }
            }
        }
        // 中身の実高。こちらは**いちばん上の層のぶんだけ**採る（隠れた層の変化で見えている档を
        // 動かす理由が無い）。可視カードは档より底部安全区ぶん高いので、その差を引く。
        .onPreferenceChange(FittedContentHeightKey.self) { measured in
            guard let content = measured[top.layer] else { return }
            let inset = sheetGeometry.bottomInset
            scheduleFit(
                layer: top.layer,
                heights: SheetContentHeights(medium: content.medium - inset, expanded: content.expanded - inset)
            )
        }
    }

    /// 档を中身の実高まで詰める。**すぐには適用しない** —— 档を跨ぐ最中は毎フレーム値が変わるので
    /// 落ち着いてから 1 回だけ渡す。待ちはカードが開くバネ（0.35s）より短くして、開いた直後の
    /// 補正がその動きに溶けるようにする。
    private func scheduleFit(layer: SheetLayer, heights: SheetContentHeights) {
        fitTask?.cancel()
        guard let old = fittedHeights[layer] else {
            // その層の初回だけは待たずに入れる（待つと開くバネの後に一段遅れて動く）。
            applyFit(layer: layer, heights: heights, old: nil)
            return
        }
        guard abs(old.medium - heights.medium) > 1 || abs(old.expanded - heights.expanded) > 1 else { return }
        fitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            applyFit(layer: layer, heights: heights, old: old)
        }
    }

    /// 詰めた高さを档へ。**選択中の档も同じ更新で移す**（最小档と同じ理屈）。
    private func applyFit(layer: SheetLayer, heights: SheetContentHeights, old: SheetContentHeights?) {
        let screenHeight = DesignScale.screenHeight
        let wasInitial = detent == layer.initialDetent(screenHeight: screenHeight, fitted: old)
        let wasMax = detent == layer.maxDetent(screenHeight: screenHeight, fitted: old)
        withAnimation(.anitabiSpring) {
            fittedHeights[layer] = heights
            guard layer == top.layer else { return }
            if wasInitial {
                detent = layer.initialDetent(screenHeight: screenHeight, fitted: heights)
            } else if wasMax {
                detent = layer.maxDetent(screenHeight: screenHeight, fitted: heights)
            }
        }
    }

    /// 迷你条の「中身の枠」と「可視カード」のズレ（`CompactBarRow` が上下余白に足す）。
    /// 一段式に居るときだけ意味がある値なので、それ以外は 0（＝素の余白）に落とす。
    private var compactBarInsets: CompactBarInsets {
        guard let cardFrame, stage(of: top) == .compact, sheetGeometry.height > 0 else {
            return CompactBarInsets()
        }
        let contentTop = sheetGeometry.minY
        let barBottom = contentTop + SheetLayout.minHeight(compactHeights[top.layer] ?? SheetLayout.compactContentFallback)
        // 0.5pt 未満は捨てる（実測値が毎フレーム微動するとレイアウトが揺れ続ける）。
        func quantized(_ value: CGFloat) -> CGFloat { (max(0, value) * 2).rounded() / 2 }
        return CompactBarInsets(
            top: quantized(cardFrame.minY - contentTop),
            bottom: quantized(barBottom - cardFrame.maxY)
        )
    }

    /// 两段式の档（層ごとの実測反映込み）。呈现・背景交互・镜头の全部がこれを使う。
    private func initialDetent(_ layer: SheetLayer) -> PresentationDetent {
        layer.initialDetent(screenHeight: DesignScale.screenHeight, fitted: fittedHeights[layer])
    }

    /// 三段式の档（同上）。
    private func maxDetent(_ layer: SheetLayer) -> PresentationDetent {
        layer.maxDetent(screenHeight: DesignScale.screenHeight, fitted: fittedHeights[layer])
    }

    @ViewBuilder
    private func sheetContent(_ entry: SheetContent) -> some View {
        switch entry {
        case .home:
            HomeSheet(
                store: store,
                router: router,
                locationProvider: locationProvider,
                cameraState: router.cameraState,
                homeDetent: $detent,
                stage: stage(of: entry),
                expandedDetent: maxDetent(.home),
                initialDetent: initialDetent(.home),
                onSelectPoint: { selectPointFromList($0) },
                onFocusCity: { city, collapsesSheet in focusCity(city, collapsesSheet: collapsesSheet) }
            )
        case .work(let selection):
            // `.equatable()` が肝 —— このカードは点数の多い作品で重く、拖动中は毎フレーム
            // ここが作り直される（`sheetGeometry` が毎フレーム変わるため）。値が同じなら
            // body ごと飛ばさせる（理由と安全性は `WorkCardSheet` の `Equatable` に）。
            WorkCardSheet(
                store: store,
                workID: selection.id,
                dataGeneration: store.dataGeneration,
                selectedPointID: router.pointCard?.id,
                isMinimized: stage(of: entry) == .compact,
                onSelectPoint: selectPointFromList,
                onClose: { router.closeWorkCard() },
                onRefit: { refitWork(selection.id) }
            )
            .equatable()
        case .point(let selection):
            PointCardSheet(
                store: store,
                router: router,
                locationProvider: locationProvider,
                selection: selection,
                stage: stage(of: entry),
                onSelectWork: { router.focusWork(id: $0) },
                onClose: { router.closePointCard() }
            )
        case .droppedPin(let pin):
            DroppedPinSheet(
                store: store,
                coordinate: pin.coordinate,
                currentZoom: router.cameraState?.zoom ?? 0,
                stage: stage(of: entry),
                onSelectPoint: { point in
                    router.droppedPin = nil
                    selectPointFromList(point)
                },
                onClose: { router.droppedPin = nil }
            )
        }
    }

    /// いま何段目に居るか。判定に `PresentationDetent` の等値比較を使わないのが肝 —— あれは
    /// **吸着した後**にしか変わらず、拖动の途中はカードが空のまま伸びて吸着した瞬間に中身が湧く。
    /// 生の高さで見れば指の動きにそのまま追従する。隠れている層は常に「中」。
    private func stage(of entry: SheetContent) -> SheetStage {
        guard entry.id == top.id, sheetGeometry.height > 0 else { return .medium }
        let layer = entry.layer
        let minHeight = SheetLayout.minHeight(compactHeights[layer] ?? SheetLayout.compactContentFallback)
        let initialHeight = layer.initialHeight(screenHeight: DesignScale.screenHeight, fitted: fittedHeights[layer])
        let maxHeight = layer.maxHeight(screenHeight: DesignScale.screenHeight, fitted: fittedHeights[layer])

        // 目標高さのうち、いま実際にいちばん近いものを採る（`.height()` で頼んだ値と実際の
        // 中身の高さには数 pt のズレがあるので、閾値では取りこぼす）。
        var targets: [(SheetStage, CGFloat)] = [(.compact, minHeight), (.medium, initialHeight)]
        // 三段目を持たない層では `.expanded` を候補に入れない —— 入れると行けもしない档に
        // 吸い寄せられて頭部や剧照が別物に化ける。
        if layer.hasExpandedStage { targets.append((.expanded, maxHeight)) }
        return targets.min { abs($0.1 - sheetGeometry.height) < abs($1.1 - sheetGeometry.height) }?.0 ?? .medium
    }

    // MARK: 呈现スタックの同期

    /// router の状態をそのまま積み上げた「本来あるべきスタック」。
    private var routerStack: [SheetContent] {
        var result: [SheetContent] = [.home]
        if let work = router.workCard { result.append(.work(work)) }
        if let point = router.pointCard { result.append(.point(point)) }
        if let pin = router.droppedPin { result.append(.droppedPin(pin)) }
        return result
    }

    /// 内容と档を 1 回のトランザクションで入れ替える。ここが呈现モデルの心臓部：
    /// **上へ開く**なら新しい層を初期档で出しつつ覆われる層の「今の档」を覚え、
    /// **下へ戻る**なら覚えていた档を復元する（記憶が無い層は初期档）。
    private func syncStack() {
        let next = routerStack
        let current = top
        guard let target = next.last, target.id != current.id else {
            // いちばん上が同じなら档は動かさない（下の層だけ入れ替わった場合）。
            if next != stack { stack = next }
            return
        }

        var memory = rememberedDetents
        memory[current.id] = detent

        let restored = target.layer < current.layer ? memory[target.id] : nil
        memory.removeValue(forKey: target.id)
        // スタックから外れた層の記憶は捨てる（作品を渡り歩いても増えないように）。
        let live = Set(next.map(\.id))
        rememberedDetents = memory.filter { live.contains($0.key) }

        // 蓋の実測値は層ごとに違う（两段式の高さが違う）ので、カードが差し替わったら捨てる。
        restingCardTopY = nil

        withAnimation(.anitabiSpring) {
            stack = next
            detent = restored ?? initialDetent(target.layer)
        }
    }

    // MARK: 動作

    /// 地図を触ったら、いちばん上のカードが最小档まで落ちる（Apple マップと同じ）。
    /// 定位钮の「アクティブ」見た目もここで外す。
    private func collapseTopSheet() {
        isLocationActive = false
        // 自分で地図を動かした人の画角は奪わない —— これから落ちる档の変化で枠へ寄せ直すと、
        // パンし始めた瞬間に镜头が戻ってしまう。
        stopWorkFitFollowing()
        stopPlacing()
        withAnimation(.anitabiSpring) {
            detent = top.layer.minDetent(measured: compactHeights[top.layer])
        }
    }

    /// 浮控の定位钮。授权済みなら镜头を寄せて「アクティブ」表示に、拒否済みなら設定アプリへ、
    /// 未決定ならまず権限要求だけ行う（このタップでは镜头を動かさない）。
    private func handleLocationTap() {
        switch locationProvider.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            stopWorkFitFollowing()
            stopPlacing()
            command = MapCameraCommand(kind: .userLocation(span: 0.01))
            withAnimation(.anitabiSpring) { isLocationActive = true }
        case .denied, .restricted:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        default:
            locationProvider.requestAuthorization()
        }
    }

    /// 左下の「随机作品」釦。剧照付きの地標が十分ある作品から 1 つ引いてその作品カードへ飛ぶ
    /// （候補の条件は `AnitabiStore.randomWork()`）。呈现は `syncStack()` が面倒を見る。
    private func rollRandomWork() {
        guard !isRandomCoolingDown, let work = store.randomWork() else { return }
        router.focusWork(id: work.id)
        refitWork(work.id)
        router.toast.show(String(localized: "已跳转到《\(work.displayName)》"), symbol: "dice.fill")
        isRandomCoolingDown = true
        Task { @MainActor in
            // 冷却は**镜头が滑り終わるまで**だけ。連打で飛行が上書きされるのを防ぐのが目的なので、
            // それ以上待たせると単に「押せない」と感じる。
            try? await Task.sleep(for: .seconds(MapCameraPlanner.flyDuration))
            isRandomCoolingDown = false
        }
    }

    /// 遠景では作品の広がりへ寄せ、視口作品 chips が使える近接レベルでは画角を保つ。
    /// 明示的な全景要求・深リンクのカメラは、通常選択の判定で上書きしない。
    private func didOpenWork(_ selection: WorkSelection?) {
        let hasExplicitCamera = selection != nil && explicitWorkCameraID == selection?.id
        explicitWorkCameraID = nil
        if workFitID != selection?.id { stopWorkFitFollowing() }
        guard let selection else { return }
        store.rememberVisit(bangumiID: selection.id)
        guard !hasExplicitCamera, workFitID != selection.id else { return }
        guard let zoom = currentWorkSelectionZoom, zoom >= MapCameraPlanner.preserveWorkViewportMinZoom else {
            refitWork(selection.id)
            return
        }
    }

    /// onCameraIdle は 120ms 防抖されるので、縮放直後の選択では生の地図を優先する。
    /// zoom は経度 span と幅だけから計算され、カード用の下余白には影響されない。
    /// 開局で地図もコールバックもまだ無い場合は nil とし、遠景と同じく作品へフィットする。
    private var currentWorkSelectionZoom: Double? {
        if let mapView, mapView.bounds.width > 0, mapView.region.span.longitudeDelta > 0 {
            return MapCameraPlanner.zoom(for: mapView.region, width: mapView.bounds.width)
        }
        return router.cameraState?.zoom
    }

    private func stopWorkFitFollowing() {
        workFitTask?.cancel()
        workFitTask = nil
        workFitID = nil
        lastWorkFitCardTop = nil
    }

    /// 作品の枠が丸ごと収まる画へ寄せ直す。収める相手は**圧暗レイヤーが実際に描いている多角形**
    /// —— 点群を直接渡すと `fitRect` が離群点を切り捨てて枠と镜头が別の点集合を見ることになる。
    /// カードに譲る帯は指定しない（`MapCanvas` が署名・浮控と同じ実測値を使う）。
    private func refitWork(_ id: Int, animated: Bool = true) {
        stopWorkFitFollowing()
        stopPlacing()
        let coordinates = (store.pointsByBangumi[id] ?? []).map(\.coordinate)
        guard !coordinates.isEmpty else { return }
        workFitID = id
        lastWorkFitCardTop = cardFrame?.minY
        if let hull = WorkRegionOverlay.hull(for: coordinates) {
            command = .fitWork(hull, trimsOutliers: false, animated: animated)
        } else {
            // 判定範囲外（海外点を含む）の作品は圧暗レイヤーも出ないので、点群フィットに落ちる。
            command = .fitWork(coordinates, animated: animated)
        }
    }

    /// 档が動いたら作品の枠を新しい可視域へ置き直す。**カードが動き終わってから測る**のが肝
    /// （`PresentationDetent` は吸着で即変わるが、可視カードはそこからバネで動く）。帯がほとんど
    /// 変わっていなければ動かさない —— でないと入場のフライトが着地寸前に上書きされて二度動く。
    private func scheduleWorkRefit() {
        guard let work = router.workCard, workFitID == work.id else { return }
        workFitTask?.cancel()
        workFitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(360))
            guard
                !Task.isCancelled,
                workFitID == work.id,
                router.workCard?.id == work.id,
                top.layer == .work,
                // 三段式はカードが地図をほぼ占めるので、枠を詰め込む意味が無い。
                detent != maxDetent(.work),
                let cardTop = cardFrame?.minY,
                abs(cardTop - (lastWorkFitCardTop ?? 0)) > Self.workRefitThreshold
            else { return }
            refitWork(work.id)
        }
    }

    /// この pt 以上カードの上縁が動いたときだけ枠を置き直す。
    private static let workRefitThreshold: CGFloat = 24

    /// 一覧・検索から地標を選んだ経路だけ镜头を寄せる。着地は**可視帯のど真ん中**（`.centered`）。
    ///
    /// 飛行に渡す上寄せ量は見積もりのままで構わない —— 最終的な縦位置は着地後の実測が決める。
    /// **`windowSize` は使わない**：あれは検索でキーボードが出ている間その高さぶん縮むので、
    /// 検索から選んだ点だけ上寄せが 4 割ほど足りず、カードの縁に貼り付いていた。
    private func selectPointFromList(_ point: ScenePoint) {
        stopWorkFitFollowing()
        router.selectPoint(point)
        command = .flyTo(
            point,
            verticalOffset: DesignScale.screenHeight * SheetLayout.pointFraction / 2
        )
        schedulePlacement(
            point, .centered,
            after: .milliseconds(Int(MapCameraPlanner.flyDuration * 1000) + 120)
        )
    }

    /// 地図の標注から選んだ経路。**镜头は動かさない** —— 画角はその人の持ち物なので、寄り引きも
    /// 左右も奪わない。ただしカードは点より高く立ち上がることがある（地標カード 0.531 は作品カード
    /// 0.417 より高い）ので、点が潜ってしまったぶんだけ後から流す。
    private func selectPointFromMap(_ point: ScenePoint) {
        stopWorkFitFollowing()
        router.selectPoint(point)
        schedulePlacement(point, .revealed, after: .milliseconds(360))
    }

    /// カードが停まってから点の位置を実測して置き直す。**待つのが肝** ——
    /// `PresentationDetent` は吸着で即変わるが、可視カードはそこからバネで動くので、早く測ると
    /// 古い上縁で判断してしまう（`scheduleWorkRefit` と同じ理屈・同じ待ち）。
    private func schedulePlacement(
        _ point: ScenePoint,
        _ placement: MapPointPlacement,
        after delay: Duration
    ) {
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            // 待っている間にカードが差し替わった／閉じたなら、もう置き直す相手が居ない。
            guard !Task.isCancelled, router.pointCard?.id == point.id else { return }
            command = .place(point.coordinate, placement)
        }
    }

    /// 自分で地図を動かし始めた人の画角は奪わない —— 待機中の補正は捨てる。
    private func stopPlacing() {
        revealTask?.cancel()
        revealTask = nil
    }

    /// 都市タイル／検索の都市行 tap の镜头移動。`CityTile.radius` は集計円の半径でしかないので、
    /// 2.4 倍して市域全体が収まるくらいの見開きにする（経験値）。
    /// `collapsesSheet` はブラウズ経路だけ true —— 検索から都市を選んだときは検索態のまま
    /// 「この都市の作品」を読ませるので、卡片は持ち上げたまま裏で镜头だけ飛ばす。
    private func focusCity(_ city: CityTile, collapsesSheet: Bool = true) {
        stopWorkFitFollowing()
        stopPlacing()
        let latDelta = min(max(city.radius * 2.4 / 111_320, 0.02), 4)
        let lngDelta = latDelta / max(cos(city.center.latitude * .pi / 180), 0.2)
        command = .region(
            MKCoordinateRegion(
                center: city.center,
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta)
            )
        )
        guard collapsesSheet else { return }
        // Apple マップ同様、都市へ寄せたら sheet は半开に落として地図を見せる。
        withAnimation(.anitabiSpring) {
            detent = initialDetent(.home)
        }
    }

    /// `version` は単調増加させること。同じ値だと地図エンジンが索引の建て直しを省く。
    private func reloadDataset() {
        dataset = MapDataset(store: store, version: dataset.version + 1)
    }

    // MARK: 深リンク

    /// `onOpenURL`/`onContinueUserActivity` の共通入口。データがまだ揃っていなければ預けておき、
    /// `resolveInitialState()` が拾う。揃っていれば即適用（＝アニメーション有り）。
    private func receive(deepLink link: MapDeepLink) {
        if isDataReady {
            apply(deepLink: link, animated: true)
        } else {
            pendingDeepLink = link
        }
    }

    /// `store.bootstrap()` が完走した瞬間の着地判定。優先順位は「着信していた深リンク →
    /// バックグラウンドへ落ちたときの状態 → 許可済みなら現在地 → 何もしない（日本全境）」。
    /// カメラはすべて無アニメーション —— 初めて絵になる瞬間なので飛んで見せる意味が無い。
    private func resolveInitialState() {
        if let pending = pendingDeepLink {
            pendingDeepLink = nil
            apply(deepLink: pending, animated: false)
            return
        }
        if let restored = MapDeepLink.loadPersisted() {
            apply(deepLink: restored, animated: false)
            return
        }
        if locationProvider.isAuthorized {
            command = MapCameraCommand(kind: .userLocation(span: 0.01), animated: false)
        }
        // それ以外は何もしない —— `MapCanvas.japanOverview` がそのまま出る。
    }

    /// 深リンク／状態復元／Handoff 着地の共通実行部。web 版の着地順そのまま `bids` → 作品 →
    /// 地標 → c/z で、見つからない id はトーストで知らせて他のパラメータの処理は続ける。
    /// 呈现側はここでは触らない —— router を書き換えれば `syncStack()` が組み立てる。
    private func apply(deepLink link: MapDeepLink, animated: Bool) {
        guard !link.isEmpty else { return }
        stopWorkFitFollowing()
        stopPlacing()

        if !link.bids.isEmpty {
            router.selectedWorkIDs = Set(link.bids)
        }

        let hasCameraTarget = link.center != nil && link.zoom != nil

        if let bangumiID = link.bangumiID {
            if store.bangumi(id: bangumiID) != nil {
                // 同じ作品では変更通知が来ないので、次の通常選択へ抑制を残さない。
                if router.workCard?.id != bangumiID { explicitWorkCameraID = bangumiID }
                router.focusWork(id: bangumiID)
                if !hasCameraTarget { refitWork(bangumiID, animated: animated) }
            } else {
                router.toast.show(String(localized: "链接的内容不存在或已删除"), symbol: "exclamationmark.triangle")
            }
        }

        if let pointID = link.pointID {
            if let point = store.points.first(where: { $0.id == pointID }) {
                // 初回の着地指令は保ち、地標から戻った後まで作品の追従を持ち越さない。
                stopWorkFitFollowing()
                router.selectPoint(point)
            } else {
                router.toast.show(String(localized: "链接的内容不存在或已删除"), symbol: "exclamationmark.triangle")
            }
        }

        if let coordinate = link.center, let zoom = link.zoom {
            command = MapCameraCommand(kind: .center(coordinate, zoom: zoom), animated: animated)
        }
    }

    // MARK: Handoff

    /// 選択状態・カメラを 1 つの `MapDeepLink` に写す。Handoff の発信にも状態保存にも同じ値を使う。
    private var currentDeepLink: MapDeepLink {
        MapDeepLink(
            bangumiID: router.workCard?.id,
            pointID: router.pointCard?.id,
            center: router.cameraState?.region.center,
            zoom: router.cameraState?.zoom,
            bids: router.selectedWorkIDs.sorted()
        )
    }

    /// 600ms 防抖。選択やカメラが動いている最中に毎回 `NSUserActivity` を作り直さない。
    private func scheduleHandoffUpdate() {
        handoffDebounceTask?.cancel()
        handoffDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let link = currentDeepLink
            handoffURL = link.isEmpty ? nil : link.canonicalURL
        }
    }
}
