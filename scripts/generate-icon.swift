import Foundation
import ImageIO

func fail(_ message: String) throws -> Never {
    throw NSError(domain: "DayOrder.Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func generateIcon() throws {
    guard CommandLine.arguments.count == 3 else {
        try fail("用法：swift scripts/generate-icon.swift <源 PNG> <输出 iconset 目录>")
    }
    let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        try fail("无法读取图标源文件：\(sourceURL.path)")
    }
    guard original.width == original.height, original.width >= 1024 else {
        try fail("图标源文件必须为至少 1024 × 1024 像素的正方形：\(sourceURL.path)")
    }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                try fail("无法缩放图标至 \(pixels) × \(pixels) 像素")
            }
            let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
            let outputURL = destination.appendingPathComponent(name)
            guard let output = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
                try fail("无法创建图标：\(outputURL.path)")
            }
            CGImageDestinationAddImage(output, image, nil)
            guard CGImageDestinationFinalize(output) else {
                try fail("无法写入图标：\(outputURL.path)")
            }
        }
    }
}

do {
    try generateIcon()
} catch {
    FileHandle.standardError.write(Data("图标生成失败：\(error.localizedDescription)\n".utf8))
    exit(1)
}
