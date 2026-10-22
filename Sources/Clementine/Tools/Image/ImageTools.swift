import SwiftUI

/// Editors for the image tools: Adjust, Annotate, Background, Crop, Redact and Collage.
@MainActor
enum ImageTools: ToolGroup {
    static let tools: Set<FileTool> = [.editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .createCollage]

    static func makeEditor(for session: ToolSession) -> ToolEditor? {
        guard !session.urls.isEmpty else { return nil }
        switch session.tool {
        case .editImage:
            return ToolEditor(AdjustPhotoEditor(session: session),
                              size: CGSize(width: 940, height: 640), minSize: CGSize(width: 720, height: 500))
        case .annotateImage:
            return ToolEditor(AnnotatePhotoEditor(session: session),
                              size: CGSize(width: 1000, height: 720), minSize: CGSize(width: 860, height: 520))
        case .frameImage:
            return ToolEditor(ChangeBackgroundEditor(session: session),
                              size: CGSize(width: 980, height: 700), minSize: CGSize(width: 780, height: 560))
        case .cropImage:
            return ToolEditor(CropImageEditor(session: session),
                              size: CGSize(width: 960, height: 680), minSize: CGSize(width: 760, height: 520))
        case .redactImage:
            return ToolEditor(RedactPhotoEditor(session: session),
                              size: CGSize(width: 980, height: 700), minSize: CGSize(width: 760, height: 520))
        case .createCollage:
            return ToolEditor(CreateCollageEditor(session: session),
                              size: CGSize(width: 1000, height: 700), minSize: CGSize(width: 800, height: 560))
        default:
            return nil
        }
    }

    static func runImmediately(_ session: ToolSession) {
        ToolCoordinator.shared.showUnavailable(session)
    }

    static func registerSnapshots() {
        registerTests()
        ImageToolSnapshots.register()
    }

    // MARK: Headless processing tests (`--tool-test <name> <files…> key=value…`)

    private static func registerTests() {
        ToolTestRegistry.tests["editImage"] = { files, options, context in
            let adjustments = options.isEmpty
                ? PhotoAdjustments(options: ["exposure": "25", "contrast": "20", "vibrance": "30", "vignette": "40"])
                : PhotoAdjustments(options: options)
            var outputs: [URL] = []
            for url in files {
                outputs += try await PhotoAdjustProcessor.process(url, adjustments: adjustments, context: context)
            }
            return outputs
        }
        ToolTestRegistry.tests["annotateImage"] = { files, options, context in
            guard let url = files.first else { return [] }
            let size = ImageToolIO.uprightSize(of: url) ?? CGSize(width: 1000, height: 1000)
            let annotations = PhotoAnnotationProcessor.sampleAnnotations(for: size, text: options["text"] ?? "Look here")
            return try await PhotoAnnotationProcessor.process(url, annotations: annotations, imageSize: size, context: context)
        }
        ToolTestRegistry.tests["cropImage"] = { files, options, context in
            // rect=x,y,w,h (0…1), aspect=square|4:3|…, rotate=quarter turns. Default: centered square.
            let parse = ImageToolOptions(options)
            let aspect = options["aspect"].flatMap(ImageCropAspect.init(option:)) ?? (parse.rect("rect") == nil ? .square : .free)
            var outputs: [URL] = []
            for url in files {
                var state = ImageCropState()
                state.quarterTurns = parse.int("rotate", 0)
                if let rect = parse.rect("rect") { state.rect = rect }
                if let size = ImageToolIO.uprightSize(of: url) ?? (try? ImageIOHelpers.load(url).image).map({ CGSize(width: $0.width, height: $0.height) }),
                   let ratio = aspect.ratio(for: ImageCropState.rotatedSize(size, turns: state.quarterTurns)) {
                    let rotated = ImageCropState.rotatedSize(size, turns: state.quarterTurns)
                    state.rect = ImageCropState.fitted(ratio: ratio, imageSize: rotated, center: CGPoint(x: state.rect.midX, y: state.rect.midY))
                }
                outputs += try await ImageCropProcessor.process(url, state: state, context: context)
            }
            return outputs
        }
        ToolTestRegistry.tests["redactImage"] = { files, options, context in
            // regions=x,y,w,h;x,y,w,h (0…1), style=solid|blur, detect=faces,text (default both; "none" to skip).
            guard let url = files.first else { return [] }
            let style = PhotoRedactStyle(rawValue: options["style"] ?? "solid") ?? .solid
            let loaded = try ImageIOHelpers.load(url, maxPixel: 2400)
            let size = ImageToolIO.uprightSize(of: url) ?? CGSize(width: loaded.image.width, height: loaded.image.height)
            var regions: [CGRect] = []
            let detect = (options["detect"] ?? "faces,text").split(separator: ",").map(String.init)
            if detect.contains("faces") {
                let faces = try PhotoRedactProcessor.detectFaces(in: loaded.image)
                print("faces found: \(faces.count)")
                regions += PhotoRedactProcessor.regions(from: faces, imageSize: size, padding: 0.18)
            }
            if detect.contains("text") {
                let text = try PhotoRedactProcessor.detectText(in: loaded.image)
                print("text areas found: \(text.count)")
                regions += PhotoRedactProcessor.regions(from: text, imageSize: size, padding: 0.12)
            }
            for part in (options["regions"] ?? "").split(separator: ";") {
                let numbers = part.split(separator: ",").compactMap { Double($0) }
                guard numbers.count == 4 else { continue }
                regions.append(CGRect(x: numbers[0] * size.width, y: numbers[1] * size.height,
                                      width: numbers[2] * size.width, height: numbers[3] * size.height))
            }
            if regions.isEmpty {
                regions.append(CGRect(x: size.width * 0.3, y: size.height * 0.3, width: size.width * 0.4, height: size.height * 0.4))
            }
            return try await PhotoRedactProcessor.process(url, regions: regions, imageSize: size, style: style, context: context)
        }
        ToolTestRegistry.tests["createCollage"] = { files, options, context in
            // style=grid|horizontal|vertical|featured fit=fit|fill spacing= padding= radius= background=white|black|transparent|rrggbb size=2400
            try await PhotoCollageLayout.process(files, settings: PhotoCollageSettings(options: options), context: context)
        }
        ToolTestRegistry.tests["frameImage"] = { files, options, context in
            let style = PhotoBackgroundStyle(options: options)
            var outputs: [URL] = []
            for url in files {
                outputs += try await PhotoBackgroundRenderer.process(url, style: style, context: context)
            }
            return outputs
        }
    }
}
