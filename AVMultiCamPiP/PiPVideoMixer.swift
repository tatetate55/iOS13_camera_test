/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Combines video frames from two different sources.
*/

import CoreMedia
import CoreVideo

class PiPVideoMixer {
	
	var description = "Video Mixer"
	
	private(set) var isPrepared = false
	
	/// A normalized CGRect representing the position and size of the PiP in relation to the full screen video preview
	var pipFrame = CGRect.zero

	private(set) var inputFormatDescription: CMFormatDescription?
	
	private(set) var outputFormatDescription: CMFormatDescription?
	
	private var outputPixelBufferPool: CVPixelBufferPool?
	
	private let metalDevice = MTLCreateSystemDefaultDevice()

	private var textureCache: CVMetalTextureCache?
	
	private lazy var commandQueue: MTLCommandQueue? = {
		guard let metalDevice = metalDevice else {
			return nil
		}
		
		return metalDevice.makeCommandQueue()
	}()
	
	private var fullRangeVertexBuffer: MTLBuffer?

	private var computePipelineState: MTLComputePipelineState?

	init() {
		guard let metalDevice = metalDevice,
			let defaultLibrary = metalDevice.makeDefaultLibrary(),
			let kernelFunction = defaultLibrary.makeFunction(name: "reporterMixer") else {
				return
		}
		
		do {
			computePipelineState = try metalDevice.makeComputePipelineState(function: kernelFunction)
		} catch {
			print("Could not create compute pipeline state: \(error)")
		}
	}
	
	func prepare(with videoFormatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) {
		reset()
		
		(outputPixelBufferPool, _, outputFormatDescription) = allocateOutputBufferPool(with: videoFormatDescription,
																					   outputRetainedBufferCountHint: outputRetainedBufferCountHint)
		if outputPixelBufferPool == nil {
			return
		}
		inputFormatDescription = videoFormatDescription
		
		guard let metalDevice = metalDevice else {
				return
		}
		
		var metalTextureCache: CVMetalTextureCache?
		if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &metalTextureCache) != kCVReturnSuccess {
			assertionFailure("Unable to allocate video mixer texture cache")
		} else {
			textureCache = metalTextureCache
		}
		
		isPrepared = true
	}
	
	func reset() {
		outputPixelBufferPool = nil
		outputFormatDescription = nil
		inputFormatDescription = nil
		textureCache = nil
		isPrepared = false
	}
	
	struct MixerParameters {
		var pipPosition: SIMD2<Float>
		var pipSize: SIMD2<Float>
	}
	
	func mix(fullScreenPixelBuffer: CVPixelBuffer, pipPixelBuffer: CVPixelBuffer, fullScreenPixelBufferIsFrontCamera: Bool) -> CVPixelBuffer? {
		guard isPrepared,
			let outputPixelBufferPool = outputPixelBufferPool else {
				assertionFailure("Invalid state: Not prepared")
				return nil
		}
		
		var newPixelBuffer: CVPixelBuffer?
		CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPixelBufferPool, &newPixelBuffer)
		guard let outputPixelBuffer = newPixelBuffer else {
			print("Allocation failure: Could not get pixel buffer from pool (\(self.description))")
			return nil
		}
		
		guard let outputTexture = makeTextureFromCVPixelBuffer(pixelBuffer: outputPixelBuffer),
			let fullScreenTexture = makeTextureFromCVPixelBuffer(pixelBuffer: fullScreenPixelBuffer),
			let pipTexture = makeTextureFromCVPixelBuffer(pixelBuffer: pipPixelBuffer) else {
				return nil
		}

		let pipPosition = SIMD2(Float(pipFrame.origin.x) * Float(fullScreenTexture.width), Float(pipFrame.origin.y) * Float(fullScreenTexture.height))
		let pipSize = SIMD2(Float(pipFrame.size.width) * Float(pipTexture.width), Float(pipFrame.size.height) * Float(pipTexture.height))
		var parameters = MixerParameters(pipPosition: pipPosition, pipSize: pipSize)
		
		// Set up command queue, buffer, and encoder
		guard let commandQueue = commandQueue,
			let commandBuffer = commandQueue.makeCommandBuffer(),
			let commandEncoder = commandBuffer.makeComputeCommandEncoder(),
			let computePipelineState = computePipelineState else {
				print("Failed to create Metal command encoder")
				
				if let textureCache = textureCache {
					CVMetalTextureCacheFlush(textureCache, 0)
				}
				
				return nil
		}
		
		commandEncoder.label = "pip Video Mixer"
		commandEncoder.setComputePipelineState(computePipelineState)
		commandEncoder.setTexture(fullScreenTexture, index: 0)
		commandEncoder.setTexture(pipTexture, index: 1)
		commandEncoder.setTexture(outputTexture, index: 2)
		commandEncoder.setBytes(UnsafeMutableRawPointer(&parameters), length: MemoryLayout<MixerParameters>.size, index: 0)
		
		// Set up thread groups as described in https://developer.apple.com/reference/metal/mtlcomputecommandencoder
		let width = computePipelineState.threadExecutionWidth
		let height = computePipelineState.maxTotalThreadsPerThreadgroup / width
		let threadsPerThreadgroup = MTLSizeMake(width, height, 1)
		let threadgroupsPerGrid = MTLSize(width: (fullScreenTexture.width + width - 1) / width,
										  height: (fullScreenTexture.height + height - 1) / height,
										  depth: 1)
		commandEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
		
		commandEncoder.endEncoding()
		commandBuffer.commit()
		
		return outputPixelBuffer
	}
	
	private func makeTextureFromCVPixelBuffer(pixelBuffer: CVPixelBuffer) -> MTLTexture? {
		guard let textureCache = textureCache else {
			print("No texture cache")
			return nil
		}
		
		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)
		
		// Create a Metal texture from the image buffer
		var cvTextureOut: CVMetalTexture?
		CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTextureOut)
		guard let cvTexture = cvTextureOut, let texture = CVMetalTextureGetTexture(cvTexture) else {
			print("Video mixer failed to create preview texture")
			
			CVMetalTextureCacheFlush(textureCache, 0)
			return nil
		}
		
		return texture
	}
}
