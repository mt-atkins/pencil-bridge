import SwiftUI
import AVFoundation

struct PairingScanner: UIViewControllerRepresentable {
    let onResult: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onResult = onResult
        return controller
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onResult: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "dev.pencilbridge.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var finished = false
    private var visible = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.visible else { return }
                    if allowed { self.configure() } else { self.showError("Allow Camera access in Settings to scan the Mac’s QR code. You can also pair using the four-digit code.") }
                }
            }
        default: showError("Allow Camera access in Settings to scan the Mac’s QR code. You can also pair using the four-digit code.")
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        visible = false
        stop()
    }
    private func configure() {
        guard preview == nil, visible else { return }
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        self.preview = preview
        view.layer.insertSublayer(preview, at: 0)
        view.setNeedsLayout()
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera), self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.showError("The camera is unavailable. Close the scanner and enter the four-digit code instead.") }
                return
            }
            self.session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard self.session.canAddOutput(output) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.showError("QR scanning is unavailable. Enter the four-digit code instead.") }
                return
            }
            self.session.addOutput(output)
            guard output.availableMetadataObjectTypes.contains(.qr) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.showError("QR scanning is unavailable. Enter the four-digit code instead.") }
                return
            }
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        if let connection = preview?.connection, connection.isVideoOrientationSupported {
            switch view.window?.windowScene?.interfaceOrientation {
            case .landscapeLeft: connection.videoOrientation = .landscapeLeft
            case .landscapeRight: connection.videoOrientation = .landscapeRight
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            default: connection.videoOrientation = .portrait
            }
        }
    }
    func stop() {
        let session = session
        captureQueue.async {
            if session.isRunning { session.stopRunning() }
            for output in session.outputs {
                (output as? AVCaptureMetadataOutput)?.setMetadataObjectsDelegate(nil, queue: nil)
            }
        }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard visible, !finished,
              let text = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first,
              PairingTicket(url: text) != nil else { return }
        finished = true
        stop()
        onResult?(text)
    }
    private func showError(_ text: String) {
        guard visible else { return }
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}
