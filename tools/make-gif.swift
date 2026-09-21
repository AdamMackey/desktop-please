// Turns a screen recording into a looping GIF for the README:
//   swift tools/make-gif.swift recording.mov docs/demo.gif [width] [fps]
// Defaults are 640 px wide at 10 frames a second, which keeps a few seconds of
// recording to a few MB. Uses only macOS's own frameworks, so no ffmpeg needed.
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: swift tools/make-gif.swift recording.mov output.gif [width=640] [fps=10]")
    exit(64)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let width = arguments.count > 3 ? Double(arguments[3]) ?? 640 : 640
let fps = arguments.count > 4 ? Double(arguments[4]) ?? 10 : 10

let asset = AVURLAsset(url: input)
let seconds = try await asset.load(.duration).seconds
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: width, height: 10_000)  // height follows the aspect ratio
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

let frameCount = max(1, Int(seconds * fps))
guard let gif = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
    fatalError("can't write \(output.path)")
}
let loopForever = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
CGImageDestinationSetProperties(gif, loopForever as CFDictionary)
let frameDelay = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 1 / fps]]
for index in 0..<frameCount {
    let (image, _) = try await generator.image(at: CMTime(seconds: Double(index) / fps, preferredTimescale: 600))
    CGImageDestinationAddImage(gif, image, frameDelay as CFDictionary)
}
guard CGImageDestinationFinalize(gif) else { fatalError("couldn't finish \(output.path)") }
let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
print("\(output.path): \(frameCount) frames, \(bytes / 1024) KB")
