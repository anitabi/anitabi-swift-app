//
//  CameraViewModel.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/05/13.
//

import SwiftUI
import AVFoundation
import Photos

// MARK: - 结构体
struct PermissionAlertData {
    var title: String = ""
    var message: String = ""
}

// MARK: - 镜头（焦段）选项
/// 后置焦段档位（0.5× / 1× / 2× / 3×…）。label 用于按钮显示，zoomFactor 是要设到虚拟相机上的 videoZoomFactor。
/// 采用「虚拟多摄设备 + videoZoomFactor」方案：系统在物理镜头间平滑切换，并能提供计算变焦档（如主摄裁切出的 2×）。
struct LensOption: Identifiable, Equatable {
    let id: String            // 用 label 作唯一键（列表内唯一）
    let label: String         // "0.5×" / "1×" / "2×"
    let zoomFactor: CGFloat   // 对应的 videoZoomFactor
    static func == (lhs: LensOption, rhs: LensOption) -> Bool { lhs.id == rhs.id }
}

// MARK: - 视图模型
class CameraViewModel: ObservableObject {
    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.meikenn.anitabi.sessionQueue")
    private var photoDelegate: PhotoCaptureDelegate?

    /// 预览层在 init 就创建并挂到「尚未配置、未运行」的会话上（零成本、无竞争）。
    /// 千万不要在会话启动后再从主线程挂载——那会让主线程等待会话队列，整页冻结（本次卡顿的根因）。
    let previewLayer: AVCaptureVideoPreviewLayer

    // 端末の向き（横向き左右）に追従してプレビュー／撮影を水平基準で回転させる。
    private var videoDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    
    @Published var isSettingUp: Bool = true
    @Published var cameraPermissionDenied: Bool = false
    @Published private(set) var isCameraReady: Bool = false

    // 镜头（焦段）：可用焦段档位与当前选中。模拟器无相机时为空 → UI 不显示切换器。
    @Published private(set) var availableLenses: [LensOption] = []
    @Published private(set) var currentLensID: String = ""
    private var desiredZoomFactor: CGFloat?   // 用户选中的焦段（在 sessionQueue 上读取，重配会话时沿用）

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
    }

    func checkPermissions(completion: @escaping (Bool, String) -> Void) {
        checkCameraAuthorization { [weak self] denied in
            if denied {
                DispatchQueue.main.async {
                    self?.cameraPermissionDenied = true
                    completion(true, String(localized: "相机"))
                }
            } else {
                // 相册権限はここでは要求しない。
                // 写真選択は PHPicker（権限不要）で行い、保存は対比結果画面で実際に保存する時に要求する。
                // これにより「入室直後にいきなり相册権限ダイアログ」を避ける。
                self?.setupCamera()
            }
        }
    }

    private func checkCameraAuthorization(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(false)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                completion(!granted)
            }
        case .denied, .restricted:
            completion(true)
        @unknown default:
            completion(true)
        }
    }

    func setupCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            // 已在运行：无需重复配置，仅同步状态。
            // 避免「重拍 / 多次 onAppear / updateUIView」反复重置会话，导致预览闪烁与竞态。
            if self.captureSession.isRunning {
                DispatchQueue.main.async {
                    self.isSettingUp = false
                    self.isCameraReady = true
                }
                return
            }

            DispatchQueue.main.async { self.isSettingUp = true }

            self.resetCaptureSession()

            // 配置失败时 configureCaptureSession 内部已更新状态（isCameraReady = false），这里直接返回，
            // 不再无条件把 isCameraReady 置为 true。
            guard self.configureCaptureSession() else { return }

            // セッションの開始はメインスレッドで行わない
            self.captureSession.startRunning()

            DispatchQueue.main.async {
                self.isSettingUp = false
                self.isCameraReady = true
                self.setupRotationCoordinatorIfNeeded()
            }
        }
    }

    // MARK: - 向き追従（RotationCoordinator）

    /// device と previewLayer が揃ったら一度だけ RotationCoordinator を構築し、
    /// プレビューの水平基準角を購読してリアルタイムに反映する。
    private func setupRotationCoordinatorIfNeeded() {
        guard rotationCoordinator == nil,
              let device = videoDevice else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation()
        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview, options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyPreviewRotation() }
        }
    }

    private func applyPreviewRotation() {
        guard let coordinator = rotationCoordinator,
              let connection = previewLayer.connection else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    // MARK: - 镜头（焦段）切换（虚拟多摄 + videoZoomFactor）

    /// 选最合适的后置相机：三摄 → 双广角 → 广角+长焦 → 单广角。
    /// 虚拟设备（前三种）会随 videoZoomFactor 在物理镜头间平滑切换，并支持计算变焦档（如主摄裁切出的 2×）。
    private func bestBackCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// 由虚拟设备的构成镜头与切换阈值推导焦段档位，并返回「1× 广角」对应的 baseZoom。
    /// ・有超广角 → 加 0.5×；恒有 1×；每颗长焦按其光学倍率加 2×/3×/5×；并始终保证含常用计算变焦 2×。
    /// ・单物理镜头（如 SE / XR，无 constituents）→ 只有 1×（上层据 count>1 隐藏切换器）。
    private func buildLensOptions(for device: AVCaptureDevice) -> (options: [LensOption], baseZoom: CGFloat) {
        let constituents = device.constituentDevices
        guard !constituents.isEmpty else {
            return ([LensOption(id: "1×", label: "1×", zoomFactor: 1)], 1)
        }
        let switchovers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = constituents.contains { $0.deviceType == .builtInUltraWideCamera }
        // 1× 广角对应的 videoZoomFactor：含超广角时 = 超广角→广角切换阈值（通常 2.0），否则 = 1.0。
        let baseZoom: CGFloat = hasUltraWide ? (switchovers.first ?? 2) : 1

        var multipliers = Set<CGFloat>()
        if hasUltraWide { multipliers.insert(0.5) }
        multipliers.insert(1)
        // 光学长焦档：baseZoom 以上的切换阈值 → 相对 1× 的倍率（2/3/5…）。
        for factor in switchovers where factor > baseZoom + 0.01 {
            multipliers.insert((factor / baseZoom).rounded())
        }
        // 常用计算变焦 2×（若已有 2× 光学档则自动去重）。
        multipliers.insert(2)

        let options = multipliers.sorted().map { multiplier -> LensOption in
            let label = zoomLabel(multiplier)
            return LensOption(id: label, label: label, zoomFactor: baseZoom * multiplier)
        }
        return (options, baseZoom)
    }

    /// UI 倍率 → 标签："0.5×" / "1×" / "2×"。
    private func zoomLabel(_ multiplier: CGFloat) -> String {
        multiplier < 1 ? String(format: "%.1f×", Double(multiplier)) : "\(Int(multiplier))×"
    }

    /// 把目标 videoZoomFactor 钳制到设备允许范围。
    private func clampZoom(_ factor: CGFloat, for device: AVCaptureDevice) -> CGFloat {
        max(device.minAvailableVideoZoomFactor, min(factor, device.maxAvailableVideoZoomFactor))
    }

    /// 切换到指定焦段：设置虚拟设备的 videoZoomFactor（系统据阈值自动切换物理镜头，含计算变焦档）。
    func switchLens(to option: LensOption) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else { return }
            self.desiredZoomFactor = option.zoomFactor
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = self.clampZoom(option.zoomFactor, for: device)
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.currentLensID = option.id }
            } catch {
                print("切换焦段失败: \(error.localizedDescription)")
            }
        }
    }

    private func resetCaptureSession() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        
        if !captureSession.inputs.isEmpty {
            captureSession.beginConfiguration()
            captureSession.inputs.forEach { captureSession.removeInput($0) }
            captureSession.outputs.forEach { captureSession.removeOutput($0) }
            captureSession.commitConfiguration()
        }
    }
    
    @discardableResult
    private func configureCaptureSession() -> Bool {
        captureSession.beginConfiguration()

        // 高品質な写真を撮影するための設定
        if captureSession.canSetSessionPreset(.photo) {
            captureSession.sessionPreset = .photo
        }

        // 后置相机：优先选虚拟多摄设备（三摄/双摄），以便系统在物理镜头间平滑切换并提供计算变焦档。
        guard let videoDevice = bestBackCamera() else {
            handleCameraSetupFailure("Failed to get back camera")
            return false
        }
        self.videoDevice = videoDevice

        // 由虚拟设备构成镜头 + 切换阈值推导焦段档位（0.5×/1×/2×/3×…），并确定起始焦段。
        let (lenses, baseZoom) = buildLensOptions(for: videoDevice)
        let initialZoom = desiredZoomFactor ?? baseZoom
        let currentLens = lenses.min {
            abs($0.zoomFactor - initialZoom) < abs($1.zoomFactor - initialZoom)
        }
        DispatchQueue.main.async {
            self.availableLenses = lenses
            self.currentLensID = currentLens?.id ?? ""
        }

        do {
            // 自動フォーカスと露出の設定
            try videoDevice.lockForConfiguration()
            if videoDevice.isFocusModeSupported(.continuousAutoFocus) {
                videoDevice.focusMode = .continuousAutoFocus
            }
            if videoDevice.isExposureModeSupported(.continuousAutoExposure) {
                videoDevice.exposureMode = .continuousAutoExposure
            }
            videoDevice.unlockForConfiguration()

            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            
            guard captureSession.canAddInput(videoInput) else {
                handleCameraSetupFailure("Failed to add video input")
                return false
            }
            captureSession.addInput(videoInput)

            guard captureSession.canAddOutput(photoOutput) else {
                handleCameraSetupFailure("Failed to add photo output")
                return false
            }

            // 高品質な写真出力の設定
            photoOutput.maxPhotoQualityPrioritization = .quality

            captureSession.addOutput(photoOutput)

            captureSession.commitConfiguration()

            // 起始焦段必须在 commit 之后设置：带 sessionPreset 的会话在纳入 input 时会接管设备、
            // 重新配置其 activeFormat，videoZoomFactor 随之被重置回 1.0（三摄上 1.0 = 超广角 0.5×）。
            // 在 commit 之前写入会被覆盖，表现为「UI 显示 1× 但实际是 0.5×」。
            // （三摄的 1× 广角对应 videoZoomFactor ≈ 2.0，见 buildLensOptions 的 baseZoom。）
            do {
                try videoDevice.lockForConfiguration()
                videoDevice.videoZoomFactor = clampZoom(initialZoom, for: videoDevice)
                videoDevice.unlockForConfiguration()
            } catch {
                // 焦段设置失败不影响拍摄本身，不中断相机启动
                print("设置起始焦段失败: \(error.localizedDescription)")
            }
            return true
        } catch {
            handleCameraSetupFailure("Error setting up camera: \(error.localizedDescription)")
            return false
        }
    }
    
    private func handleCameraSetupFailure(_ message: String) {
        print(message)
        captureSession.commitConfiguration()
        DispatchQueue.main.async {
            self.isSettingUp = false
            self.isCameraReady = false
        }
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
            self.photoDelegate = nil
        }
    }

    deinit {
        previewRotationObservation?.invalidate()
    }
    
    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self, self.captureSession.isRunning else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            // 撮影の向きをプレビュー（水平基準）に合わせる。写真とプレビューのフレーミングが一致し、
            // cropToAspect の中心クロップがそのまま再現される。
            if let connection = self.photoOutput.connection(with: .video) {
                let angle = self.rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
                    ?? connection.videoRotationAngle
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }

            // 写真設定の構成
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])

            // 利用可能なフラッシュモードを確認して設定
            if self.photoOutput.supportedFlashModes.contains(.auto) {
                settings.flashMode = .auto
            }
            
            self.photoDelegate = PhotoCaptureDelegate { image in
                DispatchQueue.main.async {
                    completion(image)
                    self.photoDelegate = nil
                }
            }
            
            self.photoOutput.capturePhoto(with: settings, delegate: self.photoDelegate!)
        }
    }
}

// MARK: - 照片捕获代理
class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?) -> Void
    
    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
        super.init()
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            print("Error capturing photo: \(error.localizedDescription)")
            completion(nil)
            return
        }
        
        guard let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            print("Failed to get photo data")
            completion(nil)
            return
        }

        // 撮影した生画像は自動保存しない。
        // 保存はユーザーが対比結果画面（ComparisonResultView）で明示的に行う。
        completion(image)
    }
}

