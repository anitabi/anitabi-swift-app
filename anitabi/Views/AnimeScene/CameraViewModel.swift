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

// MARK: - 视图模型
class CameraViewModel: ObservableObject {
    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let sessionQueue = DispatchQueue(label: "com.meikenn.anitabi.sessionQueue")
    private var photoDelegate: PhotoCaptureDelegate?
    
    @Published var isSettingUp: Bool = true
    @Published var cameraPermissionDenied: Bool = false
    @Published private(set) var isCameraReady: Bool = false
    
    // セッションが実行中かどうかを確認するプロパティ
    var isSessionRunning: Bool {
        return captureSession.isRunning
    }
    
    // カメラが使用可能かどうかを確認
    var isCameraAvailable: Bool {
        return !isSettingUp && !cameraPermissionDenied && AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }
    
    func checkPermissions(completion: @escaping (Bool, String) -> Void) {
        checkCameraAuthorization { [weak self] denied in
            if denied {
                DispatchQueue.main.async {
                    self?.cameraPermissionDenied = true
                    completion(true, "相机")
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

        // バックカメラの設定
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            handleCameraSetupFailure("Failed to get back camera")
            return false
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
    
    func setupPreviewLayer(for view: UIView) {
        // プレビューレイヤーがまだ設定されていない場合のみ設定する
        if self.previewLayer == nil {
            let layer = AVCaptureVideoPreviewLayer(session: self.captureSession)
            layer.videoGravity = .resizeAspectFill
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // レイヤーの境界を正確に設定
                layer.frame = view.bounds
                
                // キャプチャセッションの現在の状態を確認
                if !self.captureSession.isRunning {
                    self.sessionQueue.async {
                        if !self.captureSession.isRunning {
                            self.captureSession.startRunning()
                        }
                    }
                }
                
                // プレビューレイヤーをビューに追加
                view.layer.sublayers?.forEach { if $0 is AVCaptureVideoPreviewLayer { $0.removeFromSuperlayer() } }
                view.layer.addSublayer(layer)
                self.previewLayer = layer
            }
        } else {
            // 既存のプレビューレイヤーがある場合は更新
            updatePreviewFrame(for: view)
        }
    }
    
    func updatePreviewFrame(for view: UIView) {
        DispatchQueue.main.async { [weak self] in
            guard let layer = self?.previewLayer else { return }
            layer.frame = view.bounds
            
            // キャプチャセッションが実行されていることを確認
            if let captureSession = self?.captureSession, !captureSession.isRunning {
                self?.sessionQueue.async {
                    if !captureSession.isRunning {
                        captureSession.startRunning()
                    }
                }
            }
        }
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
            self.photoDelegate = nil
        }
    }
    
    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self, self.captureSession.isRunning else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
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

