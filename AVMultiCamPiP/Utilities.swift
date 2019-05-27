/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Utilities
*/

import AVFoundation
import CoreMedia
import Foundation
import UIKit

// Use bundle name instead of hard-coding app name in alerts
extension Bundle {
	
	var applicationName: String {
		if let name = object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
			return name
		} else if let name = object(forInfoDictionaryKey: "CFBundleName") as? String {
			return name
		}
		
		return "-"
	}
}

extension AVCaptureVideoOrientation {
	
	init?(deviceOrientation: UIDeviceOrientation) {
		switch deviceOrientation {
		case .portrait: self = .portrait
		case .portraitUpsideDown: self = .portraitUpsideDown
		case .landscapeLeft: self = .landscapeRight
		case .landscapeRight: self = .landscapeLeft
		default: return nil
		}
	}
	
	init?(interfaceOrientation: UIInterfaceOrientation) {
		switch interfaceOrientation {
		case .portrait: self = .portrait
		case .portraitUpsideDown: self = .portraitUpsideDown
		case .landscapeLeft: self = .landscapeLeft
		case .landscapeRight: self = .landscapeRight
		default: return nil
		}
	}
	
	func angleOffsetFromPortraitOrientation(at position: AVCaptureDevice.Position) -> Double {
		switch self {
		case .portrait:
			return position == .front ? .pi : 0
		case .portraitUpsideDown:
			return position == .front ? 0 : .pi
		case .landscapeRight:
			return -.pi / 2.0
		case .landscapeLeft:
			return .pi / 2.0
		default:
			return 0
		}
	}
}

extension AVCaptureConnection {
	func videoOrientationTransform(relativeTo destinationVideoOrientation: AVCaptureVideoOrientation) -> CGAffineTransform {
		let videoDevice: AVCaptureDevice
		if let deviceInput = inputPorts.first?.input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.video) {
			videoDevice = deviceInput.device
		} else {
			// Fatal error? Programmer error?
			print("Video data output's video connection does not have a video device")
			return .identity
		}
		
		let fromAngleOffset = videoOrientation.angleOffsetFromPortraitOrientation(at: videoDevice.position)
		let toAngleOffset = destinationVideoOrientation.angleOffsetFromPortraitOrientation(at: videoDevice.position)
		let angleOffset = CGFloat(toAngleOffset - fromAngleOffset)
		let transform = CGAffineTransform(rotationAngle: angleOffset)
		
		return transform
	}
}

extension AVCaptureSession.InterruptionReason: CustomStringConvertible {
	public var description: String {
		var descriptionString = ""
		
		switch self {
		case .videoDeviceNotAvailableInBackground:
			descriptionString = "video device is not available in the background"
		case .audioDeviceInUseByAnotherClient:
			descriptionString = "audio device is in use by another client"
		case .videoDeviceInUseByAnotherClient:
			descriptionString = "video device is in use by another client"
		case .videoDeviceNotAvailableWithMultipleForegroundApps:
			descriptionString = "video device is not available with multiple foreground apps"
		case .videoDeviceNotAvailableDueToSystemPressure:
			descriptionString = "video device is not available due to system pressure"
		@unknown default:
			descriptionString = "unknown (\(self.rawValue)"
		}
		
		return descriptionString
	}
}

func allocateOutputBufferPool(with inputFormatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) -> (
	outputBufferPool: CVPixelBufferPool?,
	outputColorSpace: CGColorSpace?,
	outputFormatDescription: CMFormatDescription?) {
		
		let inputMediaSubType = CMFormatDescriptionGetMediaSubType(inputFormatDescription)
		if inputMediaSubType != kCVPixelFormatType_32BGRA {
			assertionFailure("Invalid input pixel buffer type \(inputMediaSubType)")
			return (nil, nil, nil)
		}
		
		let inputDimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription)
		var pixelBufferAttributes: [String: Any] = [
			kCVPixelBufferPixelFormatTypeKey as String: UInt(inputMediaSubType),
			kCVPixelBufferWidthKey as String: Int(inputDimensions.width),
			kCVPixelBufferHeightKey as String: Int(inputDimensions.height),
			kCVPixelBufferIOSurfacePropertiesKey as String: [:]
		]
		
		// Get pixel buffer attributes and color space from the input format description
		var cgColorSpace: CGColorSpace? = CGColorSpaceCreateDeviceRGB()
		if let inputFormatDescriptionExtension = CMFormatDescriptionGetExtensions(inputFormatDescription) as Dictionary? {
			let colorPrimaries = inputFormatDescriptionExtension[kCVImageBufferColorPrimariesKey]
			
			if let colorPrimaries = colorPrimaries {
				var colorSpaceProperties: [String: AnyObject] = [kCVImageBufferColorPrimariesKey as String: colorPrimaries]
				
				if let yCbCrMatrix = inputFormatDescriptionExtension[kCVImageBufferYCbCrMatrixKey] {
					colorSpaceProperties[kCVImageBufferYCbCrMatrixKey as String] = yCbCrMatrix
				}
				
				if let transferFunction = inputFormatDescriptionExtension[kCVImageBufferTransferFunctionKey] {
					colorSpaceProperties[kCVImageBufferTransferFunctionKey as String] = transferFunction
				}
				
				pixelBufferAttributes[kCVBufferPropagatedAttachmentsKey as String] = colorSpaceProperties
			}
			
			if let cvColorspace = inputFormatDescriptionExtension[kCVImageBufferCGColorSpaceKey],
				CFGetTypeID(cvColorspace) == CGColorSpace.typeID {
				cgColorSpace = (cvColorspace as! CGColorSpace)
			} else if (colorPrimaries as? String) == (kCVImageBufferColorPrimaries_P3_D65 as String) {
				cgColorSpace = CGColorSpace(name: CGColorSpace.displayP3)
			}
		}
		
		// Create a pixel buffer pool with the same pixel attributes as the input format description.
		let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: outputRetainedBufferCountHint]
		var cvPixelBufferPool: CVPixelBufferPool?
		CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as NSDictionary?, pixelBufferAttributes as NSDictionary?, &cvPixelBufferPool)
		guard let pixelBufferPool = cvPixelBufferPool else {
			assertionFailure("Allocation failure: Could not allocate pixel buffer pool.")
			return (nil, nil, nil)
		}
		
		preallocateBuffers(pool: pixelBufferPool, allocationThreshold: outputRetainedBufferCountHint)
		
		// Get the output format description
		var pixelBuffer: CVPixelBuffer?
		var outputFormatDescription: CMFormatDescription?
		let auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: outputRetainedBufferCountHint] as NSDictionary
		CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pixelBufferPool, auxAttributes, &pixelBuffer)
		if let pixelBuffer = pixelBuffer {
			CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
														 imageBuffer: pixelBuffer,
														 formatDescriptionOut: &outputFormatDescription)
		}
		pixelBuffer = nil
		
		return (pixelBufferPool, cgColorSpace, outputFormatDescription)
}

private func preallocateBuffers(pool: CVPixelBufferPool, allocationThreshold: Int) {
	var pixelBuffers = [CVPixelBuffer]()
	var error: CVReturn = kCVReturnSuccess
	let auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: allocationThreshold] as NSDictionary
	var pixelBuffer: CVPixelBuffer?
	while error == kCVReturnSuccess {
		error = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &pixelBuffer)
		if let pixelBuffer = pixelBuffer {
			pixelBuffers.append(pixelBuffer)
		}
		pixelBuffer = nil
	}
	pixelBuffers.removeAll()
}
