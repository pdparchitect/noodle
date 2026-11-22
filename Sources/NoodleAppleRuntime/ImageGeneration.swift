import CoreGraphics
import Foundation
import ImageIO
import MLX
import NoodleCore
import StableDiffusion
import UniformTypeIdentifiers

/// One Stable Diffusion XL image from a downloaded model, offline. Runs in the helper so the
/// weights, several gigabytes, leave memory with the process when the image is done.
public enum ImageGeneration {
    public static func png(_ request: ImageGenerationRequest) throws -> Data {
        // Every catalogue model is an SDXL checkpoint stored where the SDXL Turbo preset looks.
        let configuration = StableDiffusionConfiguration.presetSDXLTurbo
        let directory = request.weights.appendingPathComponent(ImageModelStore.loaderPath)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("unet/diffusion_pytorch_model.safetensors").path) else {
            throw ToolProviderError("This image model's files are missing. Remove it and download it again in Settings > Tools > Image Generation.")
        }
        let generator: ImageGenerator
        let start: MLXArray?
        if let data = request.image {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let editor = try configuration.imageToImageGenerator(directory: directory, configuration: LoadConfiguration(float16: true)) else {
                throw ToolProviderError("This model cannot start from a picture.")
            }
            // Pixels to the −1…1 range the encoder takes.
            start = (Image(image: image).data.asType(.float32) / 255) * 2 - 1
            generator = editor
        } else {
            guard let maker = try configuration.textToImageGenerator(directory: directory, configuration: LoadConfiguration(float16: true)) else {
                throw ToolProviderError("This model cannot make images from text.")
            }
            start = nil
            generator = maker
        }
        generator.ensureLoaded()
        var parameters = configuration.defaultParameters()
        parameters.prompt = request.prompt
        parameters.negativePrompt = request.negativePrompt
        parameters.cfgWeight = Float(request.guidance)
        parameters.steps = request.steps
        parameters.seed = request.seed
        parameters.latentSize = [request.height / 8, request.width / 8]
        var latest: MLXArray?
        let latents = if let start, let editor = generator as? ImageToImageGenerator {
            editor.generateLatents(image: start, parameters: parameters, strength: Float(request.strength))
        } else if let maker = generator as? TextToImageGenerator {
            maker.generateLatents(parameters: parameters)
        } else { throw ToolProviderError("This model cannot make images.") }
        for xt in latents {
            eval(xt)
            latest = xt
        }
        guard let latest else { throw ToolProviderError("The model produced no image.") }
        let decoded = generator.decode(xt: latest)
        let raster = (decoded[0] * 255).asType(.uint8)
        eval(raster)
        let image = Image(raster).asCGImage()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolProviderError("The image could not be encoded.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ToolProviderError("The image could not be encoded.") }
        return data as Data
    }
}
