//
//  SceneComparisonView.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/05/13.
//

import SwiftUI
import UIKit
import AVFoundation
import Photos
import PhotosUI

// MARK: - 主视图（横屏 · 比例取景框 · 实时叠加 / 洋葱皮对比相机）
struct SceneComparisonView: View {
    // MARK: - 场景信息
    let scenePhotoURL: URL
    let sceneName: String
    let sceneColor: String
    let sceneLocation: String

    // MARK: - 环境
    @Environment(\.dismiss) private var dismiss

    // MARK: - 参考图（动画原图）
    @State private var animeImageFull: UIImage? = nil      // 原寸，仅供最终合成使用
    @State private var animeImageDisplay: UIImage? = nil   // 降采样，叠加显示用
    @State private var animeAspect: CGFloat? = nil         // 宽高比（nil = 加载中 / 未知）
    @State private var isLoadingAnime = true
    @State private var animeLoadFailed = false

    // MARK: - 拍摄
    @State private var capturedFullRes: UIImage? = nil     // 已方向归一化、未裁切的原图（换底图后重裁用）
    @State private var capturedImage: UIImage? = nil        // 已裁切到比例 R 的实拍图
    @State private var isProcessingPhoto = false

    /// 相机传感器照片比例（.photo 预设恒为 4:3；本页锁横屏，即宽 4 高 3）。
    /// 画面区按此比例显示 → 预览呈现的就是拍到的完整照片，无任何视野裁切。
    private let cameraAspect: CGFloat = 4.0 / 3.0

    // MARK: - 叠加控制
    @State private var overlayOpacity: Double = 0.5
    @State private var isPeeking = false

    // MARK: - 自由变换（提交值 + 实时增量）
    @State private var committedOffset: CGSize = .zero
    @State private var committedScale: CGFloat = 1
    @State private var committedRotation: Angle = .zero
    @GestureState private var dragDelta: CGSize = .zero
    @GestureState private var magnifyDelta: CGFloat = 1
    @GestureState private var rotateDelta: Angle = .zero

    // MARK: - 入场/退场过渡
    // 「黑幕揭幕」：push 动画与强制横屏的整窗重排若直接暴露给用户会非常生硬，
    // 用一块顶层黑幕盖住全程（黑转黑不可见），安定后再淡出揭幕；返回时先淡入黑幕再 pop。
    @State private var veilOpacity: Double = 1
    @State private var enteredFromLandscape = false                                // 进入时已是横屏 → 零旋转，几乎立即揭幕
    @State private var entryOrientation: UIInterfaceOrientationMask = .portrait   // 进入前的方向，退出时原样恢复

    // MARK: - 弹窗 / 结果
    @State private var isShowingPermissionAlert = false
    @State private var permissionAlertData = PermissionAlertData()
    @State private var showGeneratedComparison = false
    @State private var combinedImage: UIImage? = nil
    @State private var generateErrorMessage: String? = nil

    // MARK: - 视图模型
    @StateObject private var cameraVM = CameraViewModel()

    // MARK: - 派生属性
    private var effectiveAspect: CGFloat { animeAspect ?? (16.0 / 9.0) }
    private var hasReference: Bool { animeImageDisplay != nil }
    private var liveScale: CGFloat { committedScale * magnifyDelta }
    private var liveRotation: Angle { committedRotation + rotateDelta }
    private var liveOffset: CGSize {
        CGSize(width: committedOffset.width + dragDelta.width,
               height: committedOffset.height + dragDelta.height)
    }
    private var displayedOpacity: Double { isPeeking ? 0 : overlayOpacity }
    private var isTransformed: Bool {
        committedOffset != .zero || committedScale != 1 || committedRotation != .zero
    }

    // MARK: - 主体视图
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 取景层（仿系统相机）：中央是「真实传感器比例 4:3」的相机画面——完整视野、不裁切两侧，
            // 左右黑边由比例自然留出（控件落在黑边上）。画面内居中「对比取景框」（=参考图比例），
            // 框外轻微调暗提示不会被保留。拍到的照片=完整画面，对比图取框内 → 中心裁切即精确映射。
            GeometryReader { fullGeo in
                let screen = fullGeo.size
                let feed = aspectFit(aspect: cameraAspect, into: screen)      // 相机完整视野区
                let frame = aspectFit(aspect: effectiveAspect, into: feed)    // 对比取景框
                ZStack {
                    if let captured = capturedImage {
                        // 已拍预览：实拍图（=框内画面）显示在取景框原位，四周黑。
                        Image(uiImage: captured)
                            .resizable()
                            .scaledToFill()
                            .frame(width: frame.width, height: frame.height)
                            .clipped()
                    } else {
                        // 容器比例=传感器比例 → aspectFill 恰好铺满且零裁切，所见=完整照片
                        CameraView(cameraVM: cameraVM)
                            .frame(width: feed.width, height: feed.height)
                            .clipped()

                        // 取景框外调暗（仅作用于相机画面内）：该区域拍得到但不进对比图
                        FrameMaskShape(holeSize: frame)
                            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                            .frame(width: feed.width, height: feed.height)
                            .allowsHitTesting(false)
                    }

                    // 参考图幽灵：限制在取景框内，自由变换的溢出部分被裁掉。
                    referenceOverlay
                        .frame(width: frame.width, height: frame.height)
                        .clipped()

                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.white.opacity(0.7), lineWidth: 1)
                        .frame(width: frame.width, height: frame.height)
                        .allowsHitTesting(false)
                }
                .frame(width: screen.width, height: screen.height)
            }
            .ignoresSafeArea()

            // 状态浮层（居中）
            statusOverlay

            // 控件层（遵守安全区）
            controlsLayer

            // 过渡黑幕（最顶层）：进入时盖住「推入 + 旋转」的重排过程，随后淡出揭幕。
            Color.black
                .ignoresSafeArea()
                .opacity(veilOpacity)
                .allowsHitTesting(veilOpacity > 0.01)
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        // 入室时强制横屏并锁定；离开时恢复（结果页用 fullScreenCover 覆盖，不会触发 onDisappear）。
        .onAppear {
            applyLandscapeLock()
            setupOnAppear()
            // 已横屏进入：无旋转，几乎立即揭幕；竖屏进入：等 push+旋转都结束（藏在黑幕后）再揭幕。
            let revealDelay = enteredFromLandscape ? 0.05 : 0.6
            DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay) {
                withAnimation(.easeOut(duration: 0.35)) { veilOpacity = 0 }
            }
        }
        .task { await loadInitialReference() }
        .onDisappear {
            releaseLandscapeLock()
            cameraVM.stopSession()
        }
        .alert(isPresented: $isShowingPermissionAlert) {
            createPermissionAlert()
        }
        .alert("生成失败", isPresented: Binding(
            get: { generateErrorMessage != nil },
            set: { if !$0 { generateErrorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { generateErrorMessage = nil }
        } message: {
            Text(generateErrorMessage ?? "")
        }
        .fullScreenCover(isPresented: $showGeneratedComparison) {
            if let combinedImage = combinedImage {
                ComparisonResultView(
                    comparisonImage: combinedImage,
                    sceneName: sceneName,
                    dismiss: { showGeneratedComparison = false }
                )
            }
        }
    }

    // MARK: - 参考图叠加（填满取景框，可平移/缩放/旋转做精细对齐；溢出由取景框裁剪）
    @ViewBuilder
    private var referenceOverlay: some View {
        if let display = animeImageDisplay {
            Image(uiImage: display)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(liveScale)
                .rotationEffect(liveRotation)
                .offset(liveOffset)
                .opacity(displayedOpacity)
                .gesture(transformGesture)
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { resetTransform() }
                }
                .allowsHitTesting(!isPeeking)
        }
    }

    // 平移 + 缩放 + 旋转 同时进行；增量在 @GestureState，结束时提交。
    private var transformGesture: some Gesture {
        let drag = DragGesture()
            .updating($dragDelta) { value, state, _ in state = value.translation }
            .onEnded { value in
                committedOffset.width += value.translation.width
                committedOffset.height += value.translation.height
            }
        let magnify = MagnifyGesture()
            .updating($magnifyDelta) { value, state, _ in state = value.magnification }
            .onEnded { value in
                committedScale = min(max(committedScale * value.magnification, 0.25), 5)
            }
        let rotate = RotateGesture()
            .updating($rotateDelta) { value, state, _ in state = value.rotation }
            .onEnded { value in committedRotation += value.rotation }
        return drag.simultaneously(with: magnify).simultaneously(with: rotate)
    }

    // MARK: - 状态浮层
    @ViewBuilder
    private var statusOverlay: some View {
        if cameraVM.cameraPermissionDenied {
            permissionDeniedOverlay
        } else if animeLoadFailed {
            referenceFailedCard
        } else if isLoadingAnime {
            centeredPill(text: String(localized: "正在加载参考图…"))
        } else if cameraVM.isSettingUp && capturedImage == nil {
            centeredPill(text: String(localized: "正在准备相机..."))
        }
    }

    private func centeredPill(text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
            Text(text).font(.subheadline).foregroundColor(.white)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(Capsule().fill(Color.black.opacity(0.6)))
    }

    private var permissionDeniedOverlay: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "camera.metering.unknown")
                    .font(.largeTitle)
                    .foregroundColor(.white)
                Text("无法访问相机")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("请在设备的\"设置\"中允许应用访问相机")
                    .font(.caption)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Button("前往设置") { openSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding()
        }
    }

    private var referenceFailedCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundColor(.white)
            Text("参考图加载失败")
                .font(.headline)
                .foregroundColor(.white)
            HStack(spacing: 16) {
                Button {
                    Task { await loadInitialReference(force: true) }
                } label: {
                    Text("重试").padding(.vertical, 6).padding(.horizontal, 18)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                cornerButton(systemName: "photo.on.rectangle.angled",
                             accessibility: String(localized: "更换参考图"))
                    .pickReferenceSheet(onPick: applyCustomReference)
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.75)))
    }

    // MARK: - 控件层（仿系统相机横持布局：左手拇指＝透明度，右手拇指＝焦段+快门；顶部信息角落）
    private var controlsLayer: some View {
        ZStack {
            VStack { topBar; Spacer() }

            if hasReference {
                HStack { opacityRail; Spacer() }
            }

            // 右侧拇指区：焦段竖排紧邻快门列（系统相机横持时变焦档就在快门旁）
            HStack(spacing: 10) {
                Spacer()
                if capturedImage == nil && cameraVM.availableLenses.count > 1 {
                    lensColumn
                }
                controlRail
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            backButton
            titlePill
            Spacer()
            cornerButton(systemName: "safari", accessibility: String(localized: "网页版"))
                .onTapGesture { openExternalGenerator() }
            if !isLoadingAnime {
                cornerButton(systemName: "photo.on.rectangle.angled",
                             accessibility: String(localized: "更换参考图"))
                    .pickReferenceSheet(onPick: applyCustomReference)
            }
        }
    }

    // 右侧竖直操作栏：速看 / 快门（或生成+重拍）/ 相册 / 重置对齐。
    private var controlRail: some View {
        VStack(spacing: 14) {
            Spacer()

            if hasReference { peekRailButton }

            if capturedImage != nil {
                railPrimaryButton(systemName: "wand.and.stars",
                                  accessibility: String(localized: "生成对比"),
                                  busy: isProcessingPhoto,
                                  disabled: isProcessingPhoto || !hasReference,
                                  action: generateComparison)
                railIconButton("arrow.counterclockwise", accessibility: String(localized: "重拍")) {
                    resetCamera()
                }
            } else {
                railShutter
                railIconLabel(systemName: "photo.stack", accessibility: String(localized: "相册"))
                    .pickCapturedSheet(onPick: applyLibraryPhoto)
            }

            if isTransformed {
                railIconButton("arrow.up.left.and.down.right.magnifyingglass",
                               accessibility: String(localized: "重置对齐")) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { resetTransform() }
                }
            }

            Spacer()
        }
    }

    private var backButton: some View {
        Button(action: dismissWithVeil) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .accessibilityLabel(Text("返回"))
    }

    private var titlePill: some View {
        Text(sceneName)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.vertical, 7)
            .padding(.horizontal, 14)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .frame(maxWidth: 220)
    }

    // 左侧竖直透明度滑杆：横持双手握机时，左手拇指原地上下滑即可调节，无需够到屏幕底部。
    private var opacityRail: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 14))
                .foregroundColor(.white)
            VerticalOpacitySlider(value: $overlayOpacity)
                .frame(width: 24, height: 140)
                .accessibilityElement()
                .accessibilityLabel(Text("叠加透明度"))
                .accessibilityValue(Text(overlayOpacity, format: .percent.precision(.fractionLength(0))))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: overlayOpacity = min(overlayOpacity + 0.1, 1)
                    case .decrement: overlayOpacity = max(overlayOpacity - 0.1, 0)
                    @unknown default: break
                    }
                }
            Text(overlayOpacity, format: .percent.precision(.fractionLength(0)))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.white)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 7)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    // MARK: - 可复用控件

    // 焦段切换器：竖排紧凑胶囊（0.5×/1×/2×…），选中档放大高亮——位于右手拇指区、快门旁。
    private var lensColumn: some View {
        VStack(spacing: 4) {
            ForEach(cameraVM.availableLenses) { lens in
                let isSelected = cameraVM.currentLensID == lens.id
                Button {
                    cameraVM.switchLens(to: lens)
                } label: {
                    Text(lens.label)
                        .font(.system(size: isSelected ? 13 : 11, weight: .semibold))
                        .foregroundColor(isSelected ? .yellow : .white)
                        .frame(width: isSelected ? 36 : 30, height: isSelected ? 36 : 30)
                        .background(Circle().fill(Color.black.opacity(isSelected ? 0.65 : 0.35)))
                }
                .accessibilityLabel(Text(lens.label))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .animation(.easeInOut(duration: 0.15), value: cameraVM.currentLensID)
    }

    private var peekRailButton: some View {
        Button {
            isPeeking.toggle()
        } label: {
            railIconLabel(systemName: isPeeking ? "eye.slash" : "eye",
                          accessibility: String(localized: "切换参考图显示"),
                          tint: isPeeking)
        }
    }

    private var railShutter: some View {
        Button(action: takePhoto) {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 62, height: 62)
                Circle().fill(Color.white).frame(width: 50, height: 50)
            }
        }
        .disabled(cameraVM.isSettingUp || isProcessingPhoto)
        .opacity((cameraVM.isSettingUp || isProcessingPhoto) ? 0.5 : 1.0)
        .accessibilityLabel(Text("拍照"))
    }

    private func railIconButton(_ systemName: String, accessibility: String,
                                tint: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            railIconLabel(systemName: systemName, accessibility: accessibility, tint: tint)
        }
    }

    private func railIconLabel(systemName: String, accessibility: String, tint: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(tint ? .yellow : .white)
            .frame(width: 46, height: 46)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .accessibilityLabel(Text(accessibility))
    }

    private func railPrimaryButton(systemName: String, accessibility: String, busy: Bool,
                                   disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white).frame(width: 56, height: 56)
                if busy {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .black))
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.black)
                }
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
        .accessibilityLabel(Text(accessibility))
    }

    private func cornerButton(systemName: String, accessibility: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .accessibilityLabel(Text(accessibility))
    }

    // MARK: - 向き制御

    private var activeWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private func applyLandscapeLock() {
        AppDelegate.orientationLock = .landscape
        guard let scene = activeWindowScene else { return }
        // 记录进入前的方向：已横屏则零旋转直接揭幕；退出时按原方向恢复。
        let current = scene.interfaceOrientation
        enteredFromLandscape = current.isLandscape
        switch current {
        case .landscapeLeft: entryOrientation = .landscapeLeft
        case .landscapeRight: entryOrientation = .landscapeRight
        default: entryOrientation = .portrait
        }
        // 用 .landscape 掩码而非写死 landscapeRight：横屏左进入时不会被硬翻 180°；竖屏进入由系统转到横屏。
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// 离开页面的兜底恢复（onDisappear）：先强制转回进入前方向（对 dismissWithVeil 路径是幂等重复，
    /// 对滑动返回等其它路径是唯一恢复点），随后放开为自由旋转。
    private func releaseLandscapeLock() {
        restoreEntryOrientation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            AppDelegate.orientationLock = .allButUpsideDown
            activeWindowScene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    // MARK: - 功能方法

    /// 返回：黑幕淡入 → 在幕后强制转回进入前的方向 → 再 pop。
    /// 地图重新出现时已经是原方向，不会滞留横屏、也看不到回转重排。
    private func dismissWithVeil() {
        withAnimation(.easeIn(duration: 0.18)) { veilOpacity = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            restoreEntryOrientation()
            // 已横屏进入无需回转，立即 pop；竖屏进入等回转完成（藏在黑幕后）。
            let rotationDelay = enteredFromLandscape ? 0.05 : 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + rotationDelay) { dismiss() }
        }
    }

    /// 强制转回进入前的方向。必须「收紧」方向掩码而不是宽掩码+偏好请求——
    /// 当前方向仍在掩码内时 requestGeometryUpdate 会被系统忽略（正是退出后滞留横屏的根因）。
    private func restoreEntryOrientation() {
        AppDelegate.orientationLock = entryOrientation
        guard let scene = activeWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: entryOrientation))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private func setupOnAppear() {
        cameraVM.checkPermissions { denied, type in
            if denied { showPermissionAlert(for: type) }
        }
    }

    /// 初次加载参考图（来自场景 URL）。已有参考图时不重复加载，除非 force。
    private func loadInitialReference(force: Bool = false) async {
        if animeImageFull != nil && !force { return }
        await MainActor.run {
            isLoadingAnime = true
            animeLoadFailed = false
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: scenePhotoURL)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = UIImage(data: data) else {
                throw URLError(.badServerResponse)
            }
            await MainActor.run { setReference(image) }
        } catch {
            await MainActor.run {
                isLoadingAnime = false
                animeLoadFailed = true
            }
        }
    }

    /// 用户从相册选择自定义参考图（换底图）。
    private func applyCustomReference(_ image: UIImage) {
        setReference(image)
        withAnimation { resetTransform() }
        recropCapturedIfNeeded()
    }

    /// 统一设置参考图：原寸供合成、降采样供叠加、并记录比例。
    private func setReference(_ image: UIImage) {
        let full = image.normalizedUp()
        animeImageFull = full
        animeImageDisplay = full.downscaled(maxDimension: 1600)
        animeAspect = full.aspectRatioValue
        isLoadingAnime = false
        animeLoadFailed = false
    }

    /// 比例变化后，用保存的未裁切原图按新比例中心重裁，避免强制重拍。
    /// 预览显示的就是完整照片、取景框是其同比例中心区域 → 中心裁切即精确映射（相机/相册同一套）。
    private func recropCapturedIfNeeded() {
        guard let full = capturedFullRes else { return }
        let aspect = effectiveAspect
        DispatchQueue.global(qos: .userInitiated).async {
            let cropped = full.cropped(toAspect: aspect)
            DispatchQueue.main.async { capturedImage = cropped }
        }
    }

    /// 从相册选一张已有照片直接作为“实拍图”（跳过实时对齐，按参考比例中心裁切）。
    private func applyLibraryPhoto(_ image: UIImage) {
        let aspect = effectiveAspect
        DispatchQueue.global(qos: .userInitiated).async {
            let normalized = image.normalizedUp()
            let cropped = normalized.cropped(toAspect: aspect)
            DispatchQueue.main.async {
                capturedFullRes = normalized
                withAnimation { capturedImage = cropped }
            }
        }
    }

    private func resetCamera() {
        withAnimation {
            capturedImage = nil
            capturedFullRes = nil
        }
        cameraVM.setupCamera()
    }

    private func resetTransform() {
        committedOffset = .zero
        committedScale = 1
        committedRotation = .zero
    }

    private func openExternalGenerator() {
        let encoded = scenePhotoURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scenePhotoURL.absoluteString
        if let url = URL(string: "https://lab.magiconch.com/image-merge/?url=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }

    private func takePhoto() {
        isProcessingPhoto = true
        let aspect = effectiveAspect
        cameraVM.capturePhoto { image in
            // capturePhoto 的 completion 已在主线程回调。
            guard let image = image else {
                self.isProcessingPhoto = false
                return
            }
            // 方向归一化 + 中心裁切到取景框比例。预览=完整照片、框=同比例中心区域，映射精确无偏差。
            DispatchQueue.global(qos: .userInitiated).async {
                let normalized = image.normalizedUp()
                let cropped = normalized.cropped(toAspect: aspect)
                DispatchQueue.main.async {
                    self.capturedFullRes = normalized
                    withAnimation { self.capturedImage = cropped }
                    self.isProcessingPhoto = false
                }
            }
        }
    }

    private func generateComparison() {
        guard let animeImageFull = animeImageFull, let userImage = capturedImage else { return }
        isProcessingPhoto = true
        let aspect = animeAspect ?? animeImageFull.aspectRatioValue
        let name = sceneName
        let location = sceneLocation
        let bgColor = UIColor(Color(hex: sceneColor)) // 在主线程把 SwiftUI Color 转成 UIColor

        DispatchQueue.global(qos: .userInitiated).async {
            let generator = ComparisonImageGenerator()
            let combined = generator.generateComparisonImage(
                animeImage: animeImageFull,
                userImage: userImage,
                sceneName: name,
                sceneColor: bgColor,
                sceneLocation: location,
                panelAspect: aspect
            )
            DispatchQueue.main.async {
                self.isProcessingPhoto = false
                if let combined = combined {
                    self.combinedImage = combined
                    self.showGeneratedComparison = true
                } else {
                    self.generateErrorMessage = String(localized: "对比图生成失败，请检查网络后重试")
                }
            }
        }
    }

    private func showPermissionAlert(for type: String) {
        permissionAlertData.title = String(localized: "\(type)访问受限")
        permissionAlertData.message = String(localized: "要使用该功能，请在设备的\"设置\"中允许应用访问\(type)")
        isShowingPermissionAlert = true
    }

    private func createPermissionAlert() -> Alert {
        Alert(
            title: Text(permissionAlertData.title),
            message: Text(permissionAlertData.message),
            primaryButton: .default(Text("前往设置"), action: openSettings),
            secondaryButton: .cancel(Text("取消"))
        )
    }

    private func openSettings() {
        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsURL)
        }
    }
}

// MARK: - 取景框遮罩（满屏矩形挖掉中央取景框，eoFill 填充框外区域）
private struct FrameMaskShape: Shape {
    let holeSize: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        let hole = CGRect(
            x: rect.midX - holeSize.width / 2,
            y: rect.midY - holeSize.height / 2,
            width: holeSize.width,
            height: holeSize.height
        )
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: 4, height: 4))
        return path
    }
}

// MARK: - 竖直透明度滑杆（自绘：轨道 + 填充 + 圆钮，整条区域可拖）
private struct VerticalOpacitySlider: View {
    @Binding var value: Double
    private let knobSize: CGFloat = 17

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.height - knobSize, 1)
            let fill = CGFloat(value) * travel
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.3)).frame(width: 5)
                Capsule().fill(Color.white).frame(width: 5, height: knobSize / 2 + fill)
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .offset(y: -fill)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let raw = 1 - (gesture.location.y - knobSize / 2) / travel
                        value = min(max(Double(raw), 0), 1)
                    }
            )
        }
    }
}

// MARK: - 选图 sheet 修饰符（参考图 / 实拍图各自独立，避免单视图多 sheet 冲突）
private extension View {
    func pickReferenceSheet(onPick: @escaping (UIImage) -> Void) -> some View {
        modifier(PhotoPickSheet(onPick: onPick))
    }
    func pickCapturedSheet(onPick: @escaping (UIImage) -> Void) -> some View {
        modifier(PhotoPickSheet(onPick: onPick))
    }
}

private struct PhotoPickSheet: ViewModifier {
    let onPick: (UIImage) -> Void
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onTapGesture { isPresented = true }
            .sheet(isPresented: $isPresented) {
                ImagePicker { image in onPick(image) }
            }
    }
}

// MARK: - 图片选择器
struct ImagePicker: UIViewControllerRepresentable {
    var selectedImage: (UIImage) -> Void
    @Environment(\.presentationMode) private var presentationMode

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.presentationMode.wrappedValue.dismiss()

            guard let result = results.first else { return }

            result.itemProvider.loadObject(ofClass: UIImage.self) { (object, error) in
                if let error = error {
                    print("图片加载错误: \(error.localizedDescription)")
                    return
                }
                if let image = object as? UIImage {
                    DispatchQueue.main.async {
                        self.parent.selectedImage(image)
                    }
                }
            }
        }
    }
}

#Preview {
    SceneComparisonView(
        scenePhotoURL: URL(string: "https://image.anitabi.cn/points/272510/39zlm4tj.jpg")!,
        sceneName: "东京塔夜景",
        sceneColor: "FF5733",
        sceneLocation: "东京都港区芝公园4丁目"
    )
}
