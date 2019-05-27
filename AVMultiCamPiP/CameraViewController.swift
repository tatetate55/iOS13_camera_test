/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Implements the view controller for the camera interface.
*/

import UIKit
import AVFoundation
import Photos

class ViewController: UIViewController, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
	
	// MARK: View Controller Life Cycle
	
	override func viewDidLoad() {
		super.viewDidLoad()
		
		// Allow users to double tap to switch between the front and back cameras being in a PiP
		let togglePiPDoubleTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(togglePiP))
		togglePiPDoubleTapGestureRecognizer.numberOfTapsRequired = 2
		view.addGestureRecognizer(togglePiPDoubleTapGestureRecognizer)
		
		// Disable UI. Enable the UI later, if and only if the session starts running.
		recordButton.isEnabled = false
		
		// Set up the back and front video preview views.
		backCameraVideoPreviewView.videoPreviewLayer.setSessionWithNoConnection(session)
		frontCameraVideoPreviewView.videoPreviewLayer.setSessionWithNoConnection(session)
		
		// Store the back and front video preview layers so we can connect them to their inputs
		backCameraVideoPreviewLayer = backCameraVideoPreviewView.videoPreviewLayer
		frontCameraVideoPreviewLayer = frontCameraVideoPreviewView.videoPreviewLayer
		
		// Store the location of the pip's frame in relation to the full screen video preview
		updateNormalizedPiPFrame()
		
		UIDevice.current.beginGeneratingDeviceOrientationNotifications()
		
		/*
		Configure the capture session.
		In general it is not safe to mutate an AVCaptureSession or any of its
		inputs, outputs, or connections from multiple threads at the same time.
		
		Don't do this on the main queue, because AVCaptureMultiCamSession.startRunning()
		is a blocking call, which can take a long time. Dispatch session setup
		to the sessionQueue so as not to block the main queue, which keeps the UI responsive.
		*/
		sessionQueue.async {
			self.configureSession()
		}
		
		// Keep the screen awake
		UIApplication.shared.isIdleTimerDisabled = true
	}
	
	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		
		sessionQueue.async {
			switch self.setupResult {
			case .success:
				// Only setup observers and start the session running if setup succeeded.
				self.addObservers()
				self.session.startRunning()
				self.isSessionRunning = self.session.isRunning
				
			case .notAuthorized:
				DispatchQueue.main.async {
					let changePrivacySetting = "\(Bundle.main.applicationName) doesn't have permission to use the camera, please change privacy settings"
					let message = NSLocalizedString(changePrivacySetting, comment: "Alert message when the user has denied access to the camera")
					let alertController = UIAlertController(title: Bundle.main.applicationName, message: message, preferredStyle: .alert)
					
					alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
															style: .cancel,
															handler: nil))
					
					alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
															style: .`default`,
															handler: { _ in
																if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
																	UIApplication.shared.open(settingsURL,
																							  options: [:],
																							  completionHandler: nil)
																}
					}))
					
					self.present(alertController, animated: true, completion: nil)
				}
				
			case .configurationFailed:
				DispatchQueue.main.async {
					let alertMsg = "Alert message when something goes wrong during capture session configuration"
					let message = NSLocalizedString("Unable to capture media", comment: alertMsg)
					let alertController = UIAlertController(title: Bundle.main.applicationName, message: message, preferredStyle: .alert)
					
					alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
															style: .cancel,
															handler: nil))
					
					self.present(alertController, animated: true, completion: nil)
				}
				
			case .multiCamNotSupported:
				DispatchQueue.main.async {
					let alertMessage = "Alert message when multi cam is not supported"
					let message = NSLocalizedString("Multi Cam Not Supported", comment: alertMessage)
					let alertController = UIAlertController(title: Bundle.main.applicationName, message: message, preferredStyle: .alert)
					
					self.present(alertController, animated: true, completion: nil)
				}
			}
		}
	}
	
	override func viewWillDisappear(_ animated: Bool) {
		sessionQueue.async {
			if self.setupResult == .success {
				self.session.stopRunning()
				self.isSessionRunning = self.session.isRunning
				self.removeObservers()
			}
		}
		
		super.viewWillDisappear(animated)
	}
	
	@objc // Expose to Objective-C for use with #selector()
	private func didEnterBackground(notification: NSNotification) {
		// Free up resources.
		dataOutputQueue.async {
			self.renderingEnabled = false
			self.videoMixer.reset()
			self.currentPiPSampleBuffer = nil
		}
	}
	
	@objc // Expose to Objective-C for use with #selector()
	func willEnterForground(notification: NSNotification) {
		dataOutputQueue.async {
			self.renderingEnabled = true
		}
	}
	
	// MARK: KVO and Notifications
	
	private var sessionRunningContext = 0
	
	private var keyValueObservations = [NSKeyValueObservation]()
	
	private func addObservers() {
		let keyValueObservation = session.observe(\.isRunning, options: .new) { _, change in
			guard let isSessionRunning = change.newValue else { return }
			
			DispatchQueue.main.async {
				self.recordButton.isEnabled = isSessionRunning
			}
		}
		keyValueObservations.append(keyValueObservation)
		
		let systemPressureStateObservation = observe(\.self.backCameraDeviceInput?.device.systemPressureState, options: .new) { _, change in
			guard let systemPressureState = change.newValue as? AVCaptureDevice.SystemPressureState else { return }
			self.setRecommendedFrameRateRangeForPressureState(systemPressureState)
		}
		keyValueObservations.append(systemPressureStateObservation)
		
		NotificationCenter.default.addObserver(self,
											   selector: #selector(didEnterBackground),
											   name: UIApplication.didEnterBackgroundNotification,
											   object: nil)
		
		NotificationCenter.default.addObserver(self,
											   selector: #selector(willEnterForground),
											   name: UIApplication.willEnterForegroundNotification,
											   object: nil)
		
		NotificationCenter.default.addObserver(self,
											   selector: #selector(sessionRuntimeError),
											   name: .AVCaptureSessionRuntimeError,
											   object: session)
		
		// A session can run only when the app is full screen. It will be interrupted in a multi-app layout.
		// Add observers to handle these session interruptions and inform the user.
		// See AVCaptureSessionWasInterruptedNotification for other interruption reasons.
		
		NotificationCenter.default.addObserver(self,
											   selector: #selector(sessionWasInterrupted),
											   name: .AVCaptureSessionWasInterrupted,
											   object: session)
		
		NotificationCenter.default.addObserver(self,
											   selector: #selector(sessionInterruptionEnded),
											   name: .AVCaptureSessionInterruptionEnded,
											   object: session)
	}
	
	private func removeObservers() {
		for keyValueObservation in keyValueObservations {
			keyValueObservation.invalidate()
		}
		
		keyValueObservations.removeAll()
	}
	
	// MARK: Video Preview PiP Management
	
	private var pipDevicePosition: AVCaptureDevice.Position = .front
	
	private var normalizedPipFrame = CGRect.zero
	
	@IBOutlet private var frontCameraPiPConstraints: [NSLayoutConstraint]!
	
	@IBOutlet private var backCameraPiPConstraints: [NSLayoutConstraint]!
	
	@objc // Expose to Objective-C for use with #selector()
	private func togglePiP() {
		// Disable animations so the views move immediately
		CATransaction.begin()
		UIView.setAnimationsEnabled(false)
		CATransaction.setDisableActions(true)
		
		if pipDevicePosition == .front {
			NSLayoutConstraint.deactivate(frontCameraPiPConstraints)
			NSLayoutConstraint.activate(backCameraPiPConstraints)
			view.sendSubviewToBack(frontCameraVideoPreviewView)
			pipDevicePosition = .back
		} else {
			NSLayoutConstraint.deactivate(backCameraPiPConstraints)
			NSLayoutConstraint.activate(frontCameraPiPConstraints)
			view.sendSubviewToBack(backCameraVideoPreviewView)
			pipDevicePosition = .front
		}
		
		CATransaction.commit()
	}
	
	private func updateNormalizedPiPFrame() {
		let fullScreenVideoPreviewView: PreviewView
		let pipVideoPreviewView: PreviewView
		
		if pipDevicePosition == .back {
			fullScreenVideoPreviewView = frontCameraVideoPreviewView
			pipVideoPreviewView = backCameraVideoPreviewView
		} else if pipDevicePosition == .front {
			fullScreenVideoPreviewView = backCameraVideoPreviewView
			pipVideoPreviewView = frontCameraVideoPreviewView
		} else {
			fatalError("Unexpected pip device position: \(pipDevicePosition)")
		}
		
		let pipFrameInFullScreenVideoPreview = pipVideoPreviewView.convert(pipVideoPreviewView.bounds, to: fullScreenVideoPreviewView)
		let normalizedTransform = CGAffineTransform(scaleX: 1.0 / fullScreenVideoPreviewView.frame.width, y: 1.0 / fullScreenVideoPreviewView.frame.height)
		
		normalizedPipFrame = pipFrameInFullScreenVideoPreview.applying(normalizedTransform)
	}
	
	// MARK: Capture Session Management
	
	@IBOutlet private var resumeButton: UIButton!
	
	@IBOutlet private var cameraUnavailableLabel: UILabel!
	
	private enum SessionSetupResult {
		case success
		case notAuthorized
		case configurationFailed
		case multiCamNotSupported
	}
	
	private let session = AVCaptureMultiCamSession()
	
	private var isSessionRunning = false
	
	private let sessionQueue = DispatchQueue(label: "session queue") // Communicate with the session and other session objects on this queue.
	
	private let dataOutputQueue = DispatchQueue(label: "data output queue")
	
	private var setupResult: SessionSetupResult = .success
	
	@objc dynamic private(set) var backCameraDeviceInput: AVCaptureDeviceInput?
	
	private let backCameraVideoDataOutput = AVCaptureVideoDataOutput()
	
	@IBOutlet private var backCameraVideoPreviewView: PreviewView!
	
	private weak var backCameraVideoPreviewLayer: AVCaptureVideoPreviewLayer?
	
	private var frontCameraDeviceInput: AVCaptureDeviceInput?
	
	private let frontCameraVideoDataOutput = AVCaptureVideoDataOutput()
	
	@IBOutlet private var frontCameraVideoPreviewView: PreviewView!
	
	private weak var frontCameraVideoPreviewLayer: AVCaptureVideoPreviewLayer?
	
	private var microphoneDeviceInput: AVCaptureDeviceInput?
	
	private let backMicrophoneAudioDataOutput = AVCaptureAudioDataOutput()
	
	private let frontMicrophoneAudioDataOutput = AVCaptureAudioDataOutput()
	
	// Must be called on the session queue
	private func configureSession() {
		guard setupResult == .success else { return }
		
		guard AVCaptureMultiCamSession.isMultiCamSupported else {
			print("MultiCam not supported on this device")
			setupResult = .multiCamNotSupported
			return
		}
		
		// When using AVCaptureMultiCamSession, it is best to manually add connections from AVCaptureInputs to AVCaptureOutputs
		session.beginConfiguration()
		defer {
			session.commitConfiguration()
			if setupResult == .success {
				checkSystemCost()
			}
		}

		guard configureBackCamera() else {
			setupResult = .configurationFailed
			return
		}
		
		guard configureFrontCamera() else {
			setupResult = .configurationFailed
			return
		}
		
		guard configureMicrophone() else {
			setupResult = .configurationFailed
			return
		}
	}
	
	private func configureBackCamera() -> Bool {
		session.beginConfiguration()
		defer {
			session.commitConfiguration()
		}
		
		// Find the back camera
		guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
			print("Could not find the back camera")
			return false
		}
		
		// Add the back camera input to the session
		do {
			backCameraDeviceInput = try AVCaptureDeviceInput(device: backCamera)
			
			guard let backCameraDeviceInput = backCameraDeviceInput,
				session.canAddInput(backCameraDeviceInput) else {
					print("Could not add back camera device input")
					return false
			}
			session.addInputWithNoConnections(backCameraDeviceInput)
		} catch {
			print("Could not create back camera device input: \(error)")
			return false
		}
		
		// Find the back camera device input's video port
		guard let backCameraDeviceInput = backCameraDeviceInput,
			let backCameraVideoPort = backCameraDeviceInput.ports(for: .video,
															  sourceDeviceType: backCamera.deviceType,
															  sourceDevicePosition: backCamera.position).first else {
																print("Could not find the back camera device input's video port")
																return false
		}
		
		// Add the back camera video data output
		guard session.canAddOutput(backCameraVideoDataOutput) else {
			print("Could not add the back camera video data output")
			return false
		}
		session.addOutputWithNoConnections(backCameraVideoDataOutput)
		backCameraVideoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
		backCameraVideoDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
		
		// Connect the back camera device input to the back camera video data output
		let backCameraVideoDataOutputConnection = AVCaptureConnection(inputPorts: [backCameraVideoPort], output: backCameraVideoDataOutput)
		guard session.canAddConnection(backCameraVideoDataOutputConnection) else {
			print("Could not add a connection to the back camera video data output")
			return false
		}
		session.addConnection(backCameraVideoDataOutputConnection)
		backCameraVideoDataOutputConnection.videoOrientation = .portrait

		// Connect the back camera device input to the back camera video preview layer
		guard let backCameraVideoPreviewLayer = backCameraVideoPreviewLayer else {
			return false
		}
		let backCameraVideoPreviewLayerConnection = AVCaptureConnection(inputPort: backCameraVideoPort, videoPreviewLayer: backCameraVideoPreviewLayer)
		guard session.canAddConnection(backCameraVideoPreviewLayerConnection) else {
			print("Could not add a connection to the back camera video preview layer")
			return false
		}
		session.addConnection(backCameraVideoPreviewLayerConnection)
		
		return true
	}
	
	private func configureFrontCamera() -> Bool {
		session.beginConfiguration()
		defer {
			session.commitConfiguration()
		}
		
		// Find the front camera
		guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
			print("Could not find the front camera")
			return false
		}
		
		// Add the front camera input to the session
		do {
			frontCameraDeviceInput = try AVCaptureDeviceInput(device: frontCamera)
			
			guard let frontCameraDeviceInput = frontCameraDeviceInput,
				session.canAddInput(frontCameraDeviceInput) else {
					print("Could not add front camera device input")
					return false
			}
			session.addInputWithNoConnections(frontCameraDeviceInput)
		} catch {
			print("Could not create front camera device input: \(error)")
			return false
		}
		
		// Find the front camera device input's video port
		guard let frontCameraDeviceInput = frontCameraDeviceInput,
			let frontCameraVideoPort = frontCameraDeviceInput.ports(for: .video,
																	sourceDeviceType: frontCamera.deviceType,
																	sourceDevicePosition: frontCamera.position).first else {
																		print("Could not find the front camera device input's video port")
																		return false
		}
		
		// Add the front camera video data output
		guard session.canAddOutput(frontCameraVideoDataOutput) else {
			print("Could not add the front camera video data output")
			return false
		}
		session.addOutputWithNoConnections(frontCameraVideoDataOutput)
		frontCameraVideoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
		frontCameraVideoDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
		
		// Connect the front camera device input to the front camera video data output
		let frontCameraVideoDataOutputConnection = AVCaptureConnection(inputPorts: [frontCameraVideoPort], output: frontCameraVideoDataOutput)
		guard session.canAddConnection(frontCameraVideoDataOutputConnection) else {
			print("Could not add a connection to the front camera video data output")
			return false
		}
		session.addConnection(frontCameraVideoDataOutputConnection)
		frontCameraVideoDataOutputConnection.videoOrientation = .portrait
		frontCameraVideoDataOutputConnection.automaticallyAdjustsVideoMirroring = false
		frontCameraVideoDataOutputConnection.isVideoMirrored = true

		// Connect the front camera device input to the front camera video preview layer
		guard let frontCameraVideoPreviewLayer = frontCameraVideoPreviewLayer else {
			return false
		}
		let frontCameraVideoPreviewLayerConnection = AVCaptureConnection(inputPort: frontCameraVideoPort, videoPreviewLayer: frontCameraVideoPreviewLayer)
		guard session.canAddConnection(frontCameraVideoPreviewLayerConnection) else {
			print("Could not add a connection to the front camera video preview layer")
			return false
		}
		session.addConnection(frontCameraVideoPreviewLayerConnection)
		frontCameraVideoPreviewLayerConnection.automaticallyAdjustsVideoMirroring = false
		frontCameraVideoPreviewLayerConnection.isVideoMirrored = true
		
		return true
	}
	
	private func configureMicrophone() -> Bool {
		session.beginConfiguration()
		defer {
			session.commitConfiguration()
		}
		
		// Find the microphone
		guard let microphone = AVCaptureDevice.default(for: .audio) else {
			print("Could not find the microphone")
			return false
		}
		
		// Add the microphone input to the session
		do {
			microphoneDeviceInput = try AVCaptureDeviceInput(device: microphone)
			
			guard let microphoneDeviceInput = microphoneDeviceInput,
				session.canAddInput(microphoneDeviceInput) else {
					print("Could not add microphone device input")
					return false
			}
			session.addInputWithNoConnections(microphoneDeviceInput)
		} catch {
			print("Could not create microphone input: \(error)")
			return false
		}
		
		// Find the audio device input's back audio port
		guard let microphoneDeviceInput = microphoneDeviceInput,
			let backMicrophonePort = microphoneDeviceInput.ports(for: .audio,
																 sourceDeviceType: microphone.deviceType,
																 sourceDevicePosition: .back).first else {
																	print("Could not find the back camera device input's audio port")
																	return false
		}
		
		// Find the audio device input's front audio port
		guard let frontMicrophonePort = microphoneDeviceInput.ports(for: .audio,
																	sourceDeviceType: microphone.deviceType,
																	sourceDevicePosition: .front).first else {
			print("Could not find the front camera device input's audio port")
			return false
		}
		
		// Add the back microphone audio data output
		guard session.canAddOutput(backMicrophoneAudioDataOutput) else {
			print("Could not add the back microphone audio data output")
			return false
		}
		session.addOutputWithNoConnections(backMicrophoneAudioDataOutput)
		backMicrophoneAudioDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
		
		// Add the front microphone audio data output
		guard session.canAddOutput(frontMicrophoneAudioDataOutput) else {
			print("Could not add the front microphone audio data output")
			return false
		}
		session.addOutputWithNoConnections(frontMicrophoneAudioDataOutput)
		frontMicrophoneAudioDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
		
		// Connect the back microphone to the back audio data output
		let backMicrophoneAudioDataOutputConnection = AVCaptureConnection(inputPorts: [backMicrophonePort], output: backMicrophoneAudioDataOutput)
		guard session.canAddConnection(backMicrophoneAudioDataOutputConnection) else {
			print("Could not add a connection to the back microphone audio data output")
			return false
		}
		session.addConnection(backMicrophoneAudioDataOutputConnection)
		
		// Connect the front microphone to the back audio data output
		let frontMicrophoneAudioDataOutputConnection = AVCaptureConnection(inputPorts: [frontMicrophonePort], output: frontMicrophoneAudioDataOutput)
		guard session.canAddConnection(frontMicrophoneAudioDataOutputConnection) else {
			print("Could not add a connection to the front microphone audio data output")
			return false
		}
		session.addConnection(frontMicrophoneAudioDataOutputConnection)
		
		return true
	}
	
	@objc // Expose to Objective-C for use with #selector()
	private func sessionWasInterrupted(notification: NSNotification) {
		// In iOS 9 and later, the userInfo dictionary contains information on why the session was interrupted.
		if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
			let reasonIntegerValue = userInfoValue.integerValue,
			let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
			print("Capture session was interrupted (\(reason))")
			
			if reason == .videoDeviceInUseByAnotherClient {
				// Simply fade-in a button to enable the user to try to resume the session running.
				resumeButton.isHidden = false
				resumeButton.alpha = 0.0
				UIView.animate(withDuration: 0.25) {
					self.resumeButton.alpha = 1.0
				}
			} else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
				// Simply fade-in a label to inform the user that the camera is unavailable.
				cameraUnavailableLabel.isHidden = false
				cameraUnavailableLabel.alpha = 0.0
				UIView.animate(withDuration: 0.25) {
					self.cameraUnavailableLabel.alpha = 1.0
				}
			}
		}
	}
	
	@objc // Expose to Objective-C for use with #selector()
	private func sessionInterruptionEnded(notification: NSNotification) {
		if !resumeButton.isHidden {
			UIView.animate(withDuration: 0.25,
						   animations: {
							self.resumeButton.alpha = 0
			}, completion: { _ in
				self.resumeButton.isHidden = true
			})
		}
		if !cameraUnavailableLabel.isHidden {
			UIView.animate(withDuration: 0.25,
						   animations: {
							self.cameraUnavailableLabel.alpha = 0
			}, completion: { _ in
				self.cameraUnavailableLabel.isHidden = true
			})
		}
	}
	
	@objc // Expose to Objective-C for use with #selector()
	private func sessionRuntimeError(notification: NSNotification) {
		guard let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
			return
		}
		
		let error = AVError(_nsError: errorValue)
		print("Capture session runtime error: \(error)")
		
		/*
		Automatically try to restart the session running if media services were
		reset and the last start running succeeded. Otherwise, enable the user
		to try to resume the session running.
		*/
		if error.code == .mediaServicesWereReset {
			sessionQueue.async {
				if self.isSessionRunning {
					self.session.startRunning()
					self.isSessionRunning = self.session.isRunning
				} else {
					DispatchQueue.main.async {
						self.resumeButton.isHidden = false
					}
				}
			}
		} else {
			resumeButton.isHidden = false
		}
	}
	
	@IBAction private func resumeInterruptedSession(_ sender: UIButton) {
		sessionQueue.async {
			/*
			The session might fail to start running. A failure to start the session running will be communicated via
			a session runtime error notification. To avoid repeatedly failing to start the session
			running, we only try to restart the session running in the session runtime error handler
			if we aren't trying to resume the session running.
			*/
			self.session.startRunning()
			self.isSessionRunning = self.session.isRunning
			if !self.session.isRunning {
				DispatchQueue.main.async {
					let message = NSLocalizedString("Unable to resume", comment: "Alert message when unable to resume the session running")
					let actions = [
						UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
									  style: .cancel,
									  handler: nil)]
					self.alert(title: Bundle.main.applicationName, message: message, actions: actions)
				}
			} else {
				DispatchQueue.main.async {
					self.resumeButton.isHidden = true
				}
			}
		}
	}
	
	func alert(title: String, message: String, actions: [UIAlertAction]) {
		let alertController = UIAlertController(title: title,
												message: message,
												preferredStyle: .alert)
		
		actions.forEach {
			alertController.addAction($0)
		}
		
		self.present(alertController, animated: true, completion: nil)
	}
	
	// MARK: Recording Movies
	
	private var movieRecorder: MovieRecorder?
	
	private var currentPiPSampleBuffer: CMSampleBuffer?
	
	private var backgroundRecordingID: UIBackgroundTaskIdentifier?
	
	@IBOutlet private var recordButton: UIButton!
	
	private var renderingEnabled = true
	
	private var videoMixer = PiPVideoMixer()
	
	private var videoTrackSourceFormatDescription: CMFormatDescription?
	
	private func updateRecordButtonWithRecordingState(_ isRecording: Bool) {
		let color = isRecording ? UIColor.red : UIColor.yellow
		let title = isRecording ? "Stop" : "Record"

		recordButton.tintColor = color
		recordButton.setTitleColor(color, for: .normal)
		recordButton.setTitle(title, for: .normal)
	}
	
	@IBAction private func toggleMovieRecording(_ recordButton: UIButton) {
		recordButton.isEnabled = false
		
		dataOutputQueue.async {
			defer {
				DispatchQueue.main.async {
					recordButton.isEnabled = true
					
					if let recorder = self.movieRecorder {
						self.updateRecordButtonWithRecordingState(recorder.isRecording)
					}
				}
			}
			
			let isRecording = self.movieRecorder?.isRecording ?? false
			if !isRecording {
				if UIDevice.current.isMultitaskingSupported {
					self.backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
				}
				
				guard let audioSettings = self.createAudioSettings() else {
					print("Could not create audio settings")
					return
				}
				
				guard let videoSettings = self.createVideoSettings() else {
					print("Could not create video settings")
					return
				}
				
				guard let videoTransform = self.createVideoTransform() else {
					print("Could not create video transform")
					return
				}

				self.movieRecorder = MovieRecorder(audioSettings: audioSettings,
												   videoSettings: videoSettings,
												   videoTransform: videoTransform)
				
				self.movieRecorder?.startRecording()
			} else {
				self.movieRecorder?.stopRecording { movieURL in
					self.saveMovieToPhotoLibrary(movieURL)
				}
			}
		}
	}
	
	private func createAudioSettings() -> [String: NSObject]? {
		guard let backMicrophoneAudioSettings = backMicrophoneAudioDataOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: NSObject] else {
			print("Could not get back microphone audio settings")
			return nil
		}
		guard let frontMicrophoneAudioSettings = frontMicrophoneAudioDataOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: NSObject] else {
			print("Could not get front microphone audio settings")
			return nil
		}
		
		if backMicrophoneAudioSettings == frontMicrophoneAudioSettings {
			// The front and back microphone audio settings are equal, so return either one
			return backMicrophoneAudioSettings
		} else {
			print("Front and back microphone audio settings are not equal. Check your AVCaptureAudioDataOutput configuration.")
			return nil
		}
	}
	
	private func createVideoSettings() -> [String: NSObject]? {
		guard let backCameraVideoSettings = backCameraVideoDataOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov) as? [String: NSObject] else {
			print("Could not get back camera video settings")
			return nil
		}
		guard let frontCameraVideoSettings = frontCameraVideoDataOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov) as? [String: NSObject] else {
			print("Could not get front camera video settings")
			return nil
		}
		
		if backCameraVideoSettings == frontCameraVideoSettings {
			// The front and back camera video settings are equal, so return either one
			return backCameraVideoSettings
		} else {
			print("Front and back camera video settings are not equal. Check your AVCaptureVideoDataOutput configuration.")
			return nil
		}
	}
	
	private func createVideoTransform() -> CGAffineTransform? {
		guard let backCameraVideoConnection = backCameraVideoDataOutput.connection(with: .video) else {
				print("Could not find the back and front camera video connections")
				return nil
		}
		
		let deviceOrientation = UIDevice.current.orientation
		let videoOrientation = AVCaptureVideoOrientation(deviceOrientation: deviceOrientation) ?? .portrait
		
		// Compute transforms from the back camera's video orientation to the device's orientation
		let backCameraTransform = backCameraVideoConnection.videoOrientationTransform(relativeTo: videoOrientation)

		return backCameraTransform

	}
	
	private func saveMovieToPhotoLibrary(_ movieURL: URL) {
		PHPhotoLibrary.requestAuthorization { status in
			if status == .authorized {
				// Save the movie file to the photo library and clean up.
				PHPhotoLibrary.shared().performChanges({
					let options = PHAssetResourceCreationOptions()
					options.shouldMoveFile = true
					let creationRequest = PHAssetCreationRequest.forAsset()
					creationRequest.addResource(with: .video, fileURL: movieURL, options: options)
				}, completionHandler: { success, error in
					if !success {
						print("\(Bundle.main.applicationName) couldn't save the movie to your photo library: \(String(describing: error))")
					} else {
						// Clean up
						if FileManager.default.fileExists(atPath: movieURL.path) {
							do {
								try FileManager.default.removeItem(atPath: movieURL.path)
							} catch {
								print("Could not remove file at url: \(movieURL)")
							}
						}
						
						if let currentBackgroundRecordingID = self.backgroundRecordingID {
							self.backgroundRecordingID = UIBackgroundTaskIdentifier.invalid
							
							if currentBackgroundRecordingID != UIBackgroundTaskIdentifier.invalid {
								UIApplication.shared.endBackgroundTask(currentBackgroundRecordingID)
							}
						}
					}
				})
			} else {
				DispatchQueue.main.async {
					let alertMessage = "Alert message when the user has not authorized photo library access"
					let message = NSLocalizedString("\(Bundle.main.applicationName) does not have permission to access the photo library", comment: alertMessage)
					let alertController = UIAlertController(title: Bundle.main.applicationName, message: message, preferredStyle: .alert)
					self.present(alertController, animated: true, completion: nil)
				}
			}
		}
	}
	
	func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		if let videoDataOutput = output as? AVCaptureVideoDataOutput {
			processVideoSampleBuffer(sampleBuffer, fromOutput: videoDataOutput)
		} else if let audioDataOutput = output as? AVCaptureAudioDataOutput {
			processsAudioSampleBuffer(sampleBuffer, fromOutput: audioDataOutput)
		}
	}
	
	private func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, fromOutput videoDataOutput: AVCaptureVideoDataOutput) {
		if videoTrackSourceFormatDescription == nil {
			videoTrackSourceFormatDescription = CMSampleBufferGetFormatDescription( sampleBuffer )
		}
		
		// Determine:
		// - which camera the sample buffer came from
		// - if the sample buffer is for the PiP
		var fullScreenSampleBuffer: CMSampleBuffer?
		var pipSampleBuffer: CMSampleBuffer?
		
		if pipDevicePosition == .back && videoDataOutput == backCameraVideoDataOutput {
			pipSampleBuffer = sampleBuffer
		} else if pipDevicePosition == .back && videoDataOutput == frontCameraVideoDataOutput {
			fullScreenSampleBuffer = sampleBuffer
		} else if pipDevicePosition == .front && videoDataOutput == backCameraVideoDataOutput {
			fullScreenSampleBuffer = sampleBuffer
		} else if pipDevicePosition == .front && videoDataOutput == frontCameraVideoDataOutput {
			pipSampleBuffer = sampleBuffer
		}
		
		if let fullScreenSampleBuffer = fullScreenSampleBuffer {
			processFullScreenSampleBuffer(fullScreenSampleBuffer)
		}
		
		if let pipSampleBuffer = pipSampleBuffer {
			processPiPSampleBuffer(pipSampleBuffer)
		}
	}
	
	private func processFullScreenSampleBuffer(_ fullScreenSampleBuffer: CMSampleBuffer) {
		guard renderingEnabled else {
			return
		}
		
		guard let fullScreenPixelBuffer = CMSampleBufferGetImageBuffer(fullScreenSampleBuffer),
			let formatDescription = CMSampleBufferGetFormatDescription(fullScreenSampleBuffer) else {
				return
		}
		
		guard let pipSampleBuffer = currentPiPSampleBuffer,
			let pipPixelBuffer = CMSampleBufferGetImageBuffer(pipSampleBuffer) else {
				return
		}
		
		if !videoMixer.isPrepared {
			videoMixer.prepare(with: formatDescription, outputRetainedBufferCountHint: 3)
		}
		
		videoMixer.pipFrame = normalizedPipFrame
		
		// Mix the full screen pixel buffer with the pip pixel buffer
		// When the PIP is the back camera, the primaryPixelBuffer is the front camera
		guard let mixedPixelBuffer = videoMixer.mix(fullScreenPixelBuffer: fullScreenPixelBuffer,
													pipPixelBuffer: pipPixelBuffer,
													fullScreenPixelBufferIsFrontCamera: pipDevicePosition == .back) else {
														print("Unable to combine video")
														return
		}
		
		// If we're recording, append this buffer to the movie
		if let recorder = movieRecorder,
			recorder.isRecording {
			guard let finalVideoSampleBuffer = createVideoSampleBufferWithPixelBuffer(mixedPixelBuffer,
																						   presentationTime: CMSampleBufferGetPresentationTimeStamp(fullScreenSampleBuffer)) else {
																							print("Error: Unable to create sample buffer from pixelbuffer")
																							return
			}
			
			recorder.recordVideo(sampleBuffer: finalVideoSampleBuffer)
		}
	}
	
	private func processPiPSampleBuffer(_ pipSampleBuffer: CMSampleBuffer) {
		guard renderingEnabled else {
			return
		}
		
		currentPiPSampleBuffer = pipSampleBuffer
	}
	
	private func processsAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, fromOutput audioDataOutput: AVCaptureAudioDataOutput) {
		
		guard (pipDevicePosition == .back && audioDataOutput == backMicrophoneAudioDataOutput) ||
			(pipDevicePosition == .front && audioDataOutput == frontMicrophoneAudioDataOutput) else {
				// Ignoring audio sample buffer
				return
		}
		
		// If we're recording, append this buffer to the movie
		if let recorder = movieRecorder,
			recorder.isRecording {
			recorder.recordAudio(sampleBuffer: sampleBuffer)
		}
	}
	
	private func createVideoSampleBufferWithPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
		guard let videoTrackSourceFormatDescription = videoTrackSourceFormatDescription else {
			return nil
		}
		
		var sampleBuffer: CMSampleBuffer?
		var timingInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
		
		let err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
													 imageBuffer: pixelBuffer,
													 dataReady: true,
													 makeDataReadyCallback: nil,
													 refcon: nil,
													 formatDescription: videoTrackSourceFormatDescription,
													 sampleTiming: &timingInfo,
													 sampleBufferOut: &sampleBuffer)
		if sampleBuffer == nil {
			print("Error: Sample buffer creation failed (error code: \(err))")
		}
		
		return sampleBuffer
	}
	
	// MARK: - Session Cost Check
	
	struct ExceededCaptureSessionCosts: OptionSet {
		let rawValue: Int
		
		static let systemPressureCost = ExceededCaptureSessionCosts(rawValue: 1 << 0)
		static let hardwareCost = ExceededCaptureSessionCosts(rawValue: 1 << 1)
	}
	
	func checkSystemCost() {
		var exceededSessionCosts: ExceededCaptureSessionCosts = []
		
		if session.systemPressureCost > 1.0 {
			exceededSessionCosts.insert(.systemPressureCost)
		}
		
		if session.hardwareCost > 1.0 {
			exceededSessionCosts.insert(.hardwareCost)
		}
		
		switch exceededSessionCosts {
			
		case .systemPressureCost:
			// Choice #1: Reduce front camera resolution
			if reduceResolutionForCamera(.front) {
				checkSystemCost()
			}
				
			// Choice 2: Reduce the number of video input ports
			else if reduceVideoInputPorts() {
				checkSystemCost()
			}
				
			// Choice #3: Reduce back camera resolution
			else if reduceResolutionForCamera(.back) {
				checkSystemCost()
			}
				
			// Choice #4: Reduce front camera frame rate
			else if reduceFrameRateForCamera(.front) {
				checkSystemCost()
			}
				
			// Choice #5: Reduce frame rate of back camera
			else if reduceFrameRateForCamera(.back) {
				checkSystemCost()
			} else {
				print("Unable to further reduce session cost.")
			}
			
		case .hardwareCost:
			// Choice #1: Reduce front camera resolution
			if reduceResolutionForCamera(.front) {
				checkSystemCost()
			}
				
			// Choice 2: Reduce back camera resolution
			else if reduceResolutionForCamera(.back) {
				checkSystemCost()
			}
				
			// Choice #3: Reduce front camera frame rate
			else if reduceFrameRateForCamera(.front) {
				checkSystemCost()
			}
				
			// Choice #4: Reduce back camera frame rate
			else if reduceFrameRateForCamera(.back) {
				checkSystemCost()
			} else {
				print("Unable to further reduce session cost.")
			}
			
		case [.systemPressureCost, .hardwareCost]:
			// Choice #1: Reduce front camera resolution
			if reduceResolutionForCamera(.front) {
				checkSystemCost()
			}
				
			// Choice #2: Reduce back camera resolution
			else if reduceResolutionForCamera(.back) {
				checkSystemCost()
			}
				
			// Choice #3: Reduce front camera frame rate
			else if reduceFrameRateForCamera(.front) {
				checkSystemCost()
			}
				
			// Choice #4: Reduce back camera frame rate
			else if reduceFrameRateForCamera(.back) {
				checkSystemCost()
			} else {
				print("Unable to further reduce session cost.")
			}
			
		default:
			break
		}
	}
	
	func reduceResolutionForCamera(_ position: AVCaptureDevice.Position) -> Bool {
		for connection in session.connections {
			for inputPort in connection.inputPorts {
				if inputPort.mediaType == .video && inputPort.sourceDevicePosition == position {
					guard let videoDeviceInput: AVCaptureDeviceInput = inputPort.input as? AVCaptureDeviceInput else {
						return false
					}
					
					var dims: CMVideoDimensions
					
					var width: Int32
					var height: Int32
					var activeWidth: Int32
					var activeHeight: Int32
					
					dims = CMVideoFormatDescriptionGetDimensions(videoDeviceInput.device.activeFormat.formatDescription)
					activeWidth = dims.width
					activeHeight = dims.height
					
					if ( activeHeight <= 480 ) && ( activeWidth <= 640 ) {
						return false
					}
					
					let formats = videoDeviceInput.device.formats
					if let formatIndex = formats.firstIndex(of: videoDeviceInput.device.activeFormat) {
						
						for index in (0..<formatIndex).reversed() {
							let format = videoDeviceInput.device.formats[index]
							if format.isMultiCamSupported {
								dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
								width = dims.width
								height = dims.height
								
								if width < activeWidth || height < activeHeight {
									do {
										try videoDeviceInput.device.lockForConfiguration()
										videoDeviceInput.device.activeFormat = format
										
										videoDeviceInput.device.unlockForConfiguration()
										
										print("reduced width = \(width), reduced height = \(height)")
										
										return true
									} catch {
										print("Could not lock device for configuration: \(error)")
										
										return false
									}
									
								} else {
									continue
								}
							}
						}
					}
				}
			}
		}
		
		return false
	}
	
	func reduceFrameRateForCamera(_ position: AVCaptureDevice.Position) -> Bool {
		for connection in session.connections {
			for inputPort in connection.inputPorts {
				
				if inputPort.mediaType == .video && inputPort.sourceDevicePosition == position {
					guard let videoDeviceInput: AVCaptureDeviceInput = inputPort.input as? AVCaptureDeviceInput else {
						return false
					}
					let activeMinFrameDuration = videoDeviceInput.device.activeVideoMinFrameDuration
					var activeMaxFrameRate: Double = Double(activeMinFrameDuration.timescale) / Double(activeMinFrameDuration.value)
					activeMaxFrameRate -= 10.0
					
					// Cap the device frame rate to this new max, never allowing it to go below 15 fps
					if activeMaxFrameRate >= 15.0 {
						do {
							try videoDeviceInput.device.lockForConfiguration()
							videoDeviceInput.videoMinFrameDurationOverride = CMTimeMake(value: 1, timescale: Int32(activeMaxFrameRate))
							
							videoDeviceInput.device.unlockForConfiguration()
							
							print("reduced fps = \(activeMaxFrameRate)")
							
							return true
						} catch {
							print("Could not lock device for configuration: \(error)")
							return false
						}
					} else {
						return false
					}
				}
			}
		}
		
		return false
	}
	
	func reduceVideoInputPorts () -> Bool {
		var newConnection: AVCaptureConnection
		var result = false
		
		for connection in session.connections {
			for inputPort in connection.inputPorts where inputPort.sourceDeviceType == .builtInDualCamera {
				print("Changing input from dual to single camera")
				
				guard let videoDeviceInput: AVCaptureDeviceInput = inputPort.input as? AVCaptureDeviceInput,
					let wideCameraPort: AVCaptureInput.Port = videoDeviceInput.ports(for: .video,
																					 sourceDeviceType: .builtInWideAngleCamera,
																					 sourceDevicePosition: videoDeviceInput.device.position).first else {
																						return false
				}
				
				if let previewLayer = connection.videoPreviewLayer {
					newConnection = AVCaptureConnection(inputPort: wideCameraPort, videoPreviewLayer: previewLayer)
				} else if let savedOutput = connection.output {
					newConnection = AVCaptureConnection(inputPorts: [wideCameraPort], output: savedOutput)
				} else {
					continue
				}
				session.beginConfiguration()
				
				session.removeConnection(connection)
				
				if session.canAddConnection(newConnection) {
					session.addConnection(newConnection)
					
					session.commitConfiguration()
					result = true
				} else {
					print("Could not add new connection to the session")
					session.commitConfiguration()
					return false
				}
			}
		}
		return result
	}
	
	private func setRecommendedFrameRateRangeForPressureState(_ systemPressureState: AVCaptureDevice.SystemPressureState) {
		// The frame rates used here are for demonstrative purposes only for this app.
		// Your frame rate throttling may be different depending on your app's camera configuration.
		let pressureLevel = systemPressureState.level
		if pressureLevel == .serious || pressureLevel == .critical {
			if self.movieRecorder == nil || self.movieRecorder?.isRecording == false {
				do {
					try self.backCameraDeviceInput?.device.lockForConfiguration()
					
					print("WARNING: Reached elevated system pressure level: \(pressureLevel). Throttling frame rate.")
					
					self.backCameraDeviceInput?.device.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: 20 )
					self.backCameraDeviceInput?.device.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: 15 )
					
					self.backCameraDeviceInput?.device.unlockForConfiguration()
				} catch {
					print("Could not lock device for configuration: \(error)")
				}
			}
		} else if pressureLevel == .shutdown {
			print("Session stopped running due to system pressure level.")
		}
	}
}
