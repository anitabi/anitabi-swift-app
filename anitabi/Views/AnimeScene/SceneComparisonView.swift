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

// MARK: - 主视图
struct SceneComparisonView: View {
    // MARK: - 属性
    
    // 场景信息
    let scenePhotoURL: URL
    let sceneName: String
    let sceneColor: String
    let sceneLocation: String
    
    // 环境
    @Environment(\.dismiss) private var dismiss
    
    // 状态
    @State private var capturedImage: UIImage? = nil
    @State private var isProcessingPhoto = false
    @State private var isShowingPermissionAlert = false
    @State private var permissionAlertData = PermissionAlertData()
    @State private var showGeneratedComparison = false
    @State private var combinedImage: UIImage? = nil
    @State private var isShowingPhotoPicker = false
    @State private var currentAnimeSceneURL: URL
    @State private var currentAnimeSceneImage: UIImage? = nil
    @State private var isShowingAnimeScenePicker = false
    @State private var generateErrorMessage: String? = nil
    
    // 视图模型
    @StateObject private var cameraVM = CameraViewModel()
    
    // 初始化
    init(scenePhotoURL: URL, sceneName: String, sceneColor: String, sceneLocation: String) {
        self.scenePhotoURL = scenePhotoURL
        self.sceneName = sceneName
        self.sceneColor = sceneColor
        self.sceneLocation = sceneLocation
        self._currentAnimeSceneURL = State(initialValue: scenePhotoURL)
    }
    
    // MARK: - 主体视图
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 背景
                Color(hex: sceneColor)
                    .ignoresSafeArea()
                
                // 内容
                VStack(spacing: 0) {
                    headerArea
                    imagesComparisonArea(geometry: geometry)
                    Spacer()
                    controlsArea(geometry: geometry)
                }
            }
        }
        .navigationBarHidden(true)
        // カメラのセットアップ起点はここ一箇所に集約する。
        // checkPermissions → 許可済みなら setupCamera を呼び、setupCamera は冪等なので
        // ComparisonResultView から戻ってきた際の再開もこの一本でカバーできる。
        .onAppear(perform: setupOnAppear)
        .onDisappear {
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
        .sheet(isPresented: $isShowingPhotoPicker) {
            ImagePicker { image in
                self.capturedImage = image
            }
        }
    }
    
    // MARK: - 子视图组件
    
    private var headerArea: some View {
        HStack {
            backButton
            Spacer()
            sceneNameLabel
            Spacer()
            infoButton
        }
        .padding(.top, 8)
    }
    
    private var backButton: some View {
        Button(action: dismiss.callAsFunction) {
            Image(systemName: "chevron.left")
                .font(.title3)
                .foregroundColor(.white)
                .padding(12)
                .background(Circle().fill(Color.black.opacity(0.6)))
        }
        .padding(.leading, 16)
    }
    
    private var sceneNameLabel: some View {
        Text(sceneName)
            .font(.headline)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .shadow(radius: 3, x: 0, y: 1)
    }
    
    private var infoButton: some View {
        Button {
            openExternalGenerator()
        } label: {
            Image(systemName: "safari")
                .font(.title3)
                .foregroundColor(.white)
                .padding(10)
                .background(Circle().fill(Color.black.opacity(0.6)))
        }
        .padding(.trailing, 16)
    }
    
    private func imagesComparisonArea(geometry: GeometryProxy) -> some View {
        VStack(spacing: 4) {
            // 动漫场景图片
            animeSceneImageView(geometry: geometry)
            
            // 用户照片区域
            userPhotoArea(geometry: geometry)
        }
        .padding(.top, 8)
    }
    
    private func animeSceneImageView(geometry: GeometryProxy) -> some View {
        let frameSize = calculateImageFrameSize(for: geometry)
        
        return Group {
            if let animeImage = currentAnimeSceneImage {
                imageWithOverlay(image: animeImage, frameSize: frameSize) {
                    isShowingAnimeScenePicker = true
                }
            } else {
                SceneImageView(url: currentAnimeSceneURL)
                    .frame(width: frameSize.width, height: frameSize.height)
                    .applyRoundedStyle()
                    .onTapGesture {
                        isShowingAnimeScenePicker = true
                    }
                    .overlay(
                        Button(action: { isShowingAnimeScenePicker = true }) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Circle().fill(Color.black.opacity(0.7)))
                        }
                        .padding(12),
                        alignment: .topTrailing
                    )
            }
        }
        .sheet(isPresented: $isShowingAnimeScenePicker) {
            ImagePicker { image in
                self.currentAnimeSceneImage = image
            }
        }
    }
    
    private func userPhotoArea(geometry: GeometryProxy) -> some View {
        let frameSize = calculateImageFrameSize(for: geometry)
        
        return Group {
            if let capturedImage = capturedImage {
                imageWithOverlay(image: capturedImage, frameSize: frameSize) {
                    resetCamera()
                }
            } else {
                CameraView(cameraVM: cameraVM)
                    .frame(width: frameSize.width, height: frameSize.height)
                    .applyRoundedStyle()
                    .overlay(
                        cameraOverlayView,
                        alignment: .center
                    )
                    .onTapGesture {
                        isShowingPhotoPicker = true
                    }
                    .overlay(
                        Button(action: { isShowingPhotoPicker = true }) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Circle().fill(Color.black.opacity(0.7)))
                        }
                        .padding(12),
                        alignment: .topTrailing
                    )
            }
        }
    }
    
    private func calculateImageFrameSize(for geometry: GeometryProxy) -> CGSize {
        let width = max(300, geometry.size.width - 16)
        let height = max(200, geometry.size.height * 0.38)
        return CGSize(width: width, height: height)
    }
    
    private func imageWithOverlay(image: UIImage, frameSize: CGSize, action: @escaping () -> Void) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: frameSize.width, height: frameSize.height)
            .applyRoundedStyle()
            .overlay(
                Button(action: action) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Circle().fill(Color.black.opacity(0.7)))
                }
                .padding(12),
                alignment: .topTrailing
            )
    }
    
    private var cameraOverlayView: some View {
        Group {
            if cameraVM.cameraPermissionDenied {
                cameraPermissionDeniedOverlay
            } else if cameraVM.isSettingUp {
                cameraSettingUpOverlay
            }
        }
    }
    
    private var cameraPermissionDeniedOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
            
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
                    .padding(.horizontal)
                
                Button("前往设置") {
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8)
    }
    
    private var cameraSettingUpOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
            
            VStack {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text("正在准备相机...")
                    .foregroundColor(.white)
                    .padding(.top, 8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8)
    }
    
    private func controlsArea(geometry: GeometryProxy) -> some View {
        VStack(spacing: 16) {
            locationInfoView

            if capturedImage != nil {
                capturedImageControlButtons
            } else if !cameraVM.cameraPermissionDenied {
                cameraControlsRow
            }
        }
        .padding(.bottom, 16)
    }
    
    private var cameraControlsRow: some View {
        ZStack {
            // 拍照按钮固定在正中间
            VStack {
                shutterButton
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    private var capturedImageControlButtons: some View {
        HStack(spacing: 40) {
            // 重拍按钮
            Button {
                resetCamera()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                    
                    Text("重拍")
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
            
            // 生成比较按钮
            Button(action: generateComparison) {
                VStack(spacing: 6) {
                    if isProcessingPhoto {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                    }
                    
                    Text("生成对比")
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
            .disabled(isProcessingPhoto)
        }
        .padding(.top, 8)
    }
    
    private var shutterButton: some View {
        Button(action: takePhoto) {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 70, height: 70)
                
                Circle()
                    .fill(Color.black.opacity(0.2))
                    .frame(width: 64, height: 64)
                
                Circle()
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: 80, height: 80)
            }
        }
        .disabled(cameraVM.isSettingUp)
        .opacity(cameraVM.isSettingUp ? 0.5 : 1.0)
        .padding(.horizontal, 20)
    }
    
    private var locationInfoView: some View {
        Group {
            if !sceneLocation.isEmpty {
                HStack {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(.white)
                    
                    Text(sceneLocation)
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .shadow(radius: 3, x: 0, y: 1)
            }
        }
    }
    
    // MARK: - 功能方法
    
    private func setupOnAppear() {
        cameraVM.checkPermissions { denied, type in
            if denied {
                showPermissionAlert(for: type)
            }
        }
    }

    private func resetCamera() {
        withAnimation {
            capturedImage = nil
            cameraVM.setupCamera()
        }
    }
    
    private func openExternalGenerator() {
        // クエリに URL をそのまま埋め込むと特殊文字で壊れるためエンコードする
        let encoded = scenePhotoURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scenePhotoURL.absoluteString
        if let url = URL(string: "https://lab.magiconch.com/image-merge/?url=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }
    
    private func takePhoto() {
        isProcessingPhoto = true
        cameraVM.capturePhoto { image in
            DispatchQueue.main.async {
                if let image = image {
                    withAnimation {
                        self.capturedImage = image
                    }
                }
                self.isProcessingPhoto = false
            }
        }
    }
    
    private func generateComparison() {
        guard let userImage = capturedImage else { return }

        isProcessingPhoto = true
        
        Task {
            do {
                // 获取动漫场景图片
                let animeImage: UIImage
                
                if let customImage = currentAnimeSceneImage {
                    // 使用已加载的自定义图片
                    animeImage = customImage
                } else {
                    // 从URL加载图片
                    let (data, response) = try await URLSession.shared.data(from: currentAnimeSceneURL)
                    
                    guard let httpResponse = response as? HTTPURLResponse, 
                          (200...299).contains(httpResponse.statusCode),
                          let loadedImage = UIImage(data: data) else {
                        throw URLError(.badServerResponse)
                    }
                    
                    animeImage = loadedImage
                }
                
                // 生成对比图片
                let comparisonGenerator = ComparisonImageGenerator()
                guard let combined = comparisonGenerator.generateComparisonImage(
                    animeImage: animeImage,
                    userImage: userImage,
                    sceneName: sceneName,
                    sceneColor: UIColor(Color(hex: sceneColor)),
                    sceneLocation: sceneLocation
                ) else {
                    throw NSError(domain: "ComparisonGeneratorError", code: 1, userInfo: nil)
                }
                
                // 更新UI
                await MainActor.run {
                    self.combinedImage = combined
                    self.isProcessingPhoto = false
                    self.showGeneratedComparison = true
                }
            } catch {
                // 错误反馈：提示用户而不是静默失败
                await MainActor.run {
                    self.isProcessingPhoto = false
                    self.generateErrorMessage = "对比图生成失败，请检查网络后重试"
                }
            }
        }
    }
    
    private func showPermissionAlert(for type: String) {
        permissionAlertData.title = "\(type)访问受限"
        permissionAlertData.message = "要使用该功能，请在设备的\"设置\"中允许应用访问\(type)"
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

// MARK: - 视图扩展

extension View {
    func applyRoundedStyle() -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 8)
            .shadow(radius: 5, x: 0, y: 2)
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
