import SwiftUI

struct IPAComparisonImageView: View {
    let before: Data?
    let after: Data?
    var beforeLabel = "A · Before"
    var afterLabel = "B · After"
    var beforeMissing = "Preview unavailable"
    var afterMissing = "Preview unavailable"
    @State private var mode = "A / B"
    @State private var position = 0.5
    @State private var difference: IPAComparisonImageDiff.Result?
    @State private var failure: String?
    private struct Inputs: Hashable { let before: Data?; let after: Data? }

    private var a: NSImage? { before.flatMap(NSImage.init(data:)) }
    private var b: NSImage? { after.flatMap(NSImage.init(data:)) }
    private var hasPair: Bool { a != nil && b != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Visual comparison", selection: $mode) {
                ForEach(["A / B", "Overlay", "Swipe", "Difference"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).disabled(!hasPair).accessibilityLabel("Visual comparison mode")
            if mode == "A / B" || !hasPair {
                HStack(alignment: .top, spacing: 14) {
                    single(a, label: beforeLabel, missing: beforeMissing)
                    single(b, label: afterLabel, missing: afterMissing)
                }
            } else {
                HStack {
                    Text(beforeLabel)
                    Spacer()
                    Text(afterLabel)
                }.font(.caption.bold())
                comparisonCanvas
                if mode == "Overlay" || mode == "Swipe" {
                    HStack {
                        Text(mode == "Overlay" ? "B opacity" : "Divider").font(.caption)
                        Slider(value: $position, in: 0...1).accessibilityLabel(mode == "Overlay" ? "B opacity" : "Comparison divider")
                        Text(position.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit()).frame(width: 40)
                    }
                }
                if mode == "Difference", let difference {
                    HStack(spacing: 6) {
                        Circle().fill(Color(red: 1, green: 30.0 / 255, blue: 180.0 / 255)).frame(width: 8, height: 8)
                        Text("\(difference.changedPixels.formatted()) / \(difference.comparedPixels.formatted()) preview pixels · \(difference.fraction.formatted(.percent.precision(.fractionLength(2)))) changed")
                    }.font(.caption).textSelection(.enabled)
                }
            }
            Text("Preview pixels · max 512 px" + (mode == "A / B" ? "" : " · top-left alignment"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: Inputs(before: before, after: after)) {
            difference = nil; failure = nil
            guard let before, let after else { return }
            let task = Task.detached(priority: .utility) { try IPAComparisonImageDiff.compare(before: before, after: after) }
            do {
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                difference = result
            } catch is CancellationError { }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }

    private func single(_ image: NSImage?, label: String, missing: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption.bold())
            ZStack {
                ComparisonCheckerboard()
                if let image { Image(nsImage: image).resizable().renderingMode(.original).scaledToFit().padding(12) }
                else { Text(missing).font(.caption).foregroundStyle(.secondary).padding() }
            }.frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 6))
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var comparisonCanvas: some View {
        GeometryReader { geometry in
            let aw = pixelSize(a), bw = pixelSize(b)
            let width = max(aw.width, bw.width, 1), height = max(aw.height, bw.height, 1)
            let scale = min((geometry.size.width - 24) / width, (geometry.size.height - 24) / height)
            let canvas = CGSize(width: width * scale, height: height * scale)
            ZStack {
                ComparisonCheckerboard()
                if mode == "Difference" {
                    if let difference, let image = NSImage(data: difference.png) {
                        Image(nsImage: image).resizable().renderingMode(.original).interpolation(.none)
                            .frame(width: canvas.width, height: canvas.height)
                    } else if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
                    else { ProgressView().controlSize(.small) }
                } else {
                    ZStack(alignment: .topLeading) {
                        aligned(a, pixels: aw, scale: scale, canvas: canvas)
                        aligned(b, pixels: bw, scale: scale, canvas: canvas)
                            .opacity(mode == "Overlay" ? position : 1)
                            .mask(alignment: .trailing) {
                                Rectangle().frame(width: mode == "Swipe" ? canvas.width * (1 - position) : canvas.width)
                            }
                        if mode == "Swipe" {
                            Rectangle().fill(Color.accentColor).frame(width: 2, height: canvas.height)
                                .offset(x: canvas.width * position - 1).allowsHitTesting(false)
                        }
                    }.frame(width: canvas.width, height: canvas.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if mode == "Swipe" { position = min(1, max(0, value.location.x / max(1, canvas.width))) }
                        })
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func aligned(_ image: NSImage?, pixels: CGSize, scale: CGFloat, canvas: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // Each side is complete, including transparency; a swipe must not
            // reveal A through a transparent pixel or a smaller extent in B.
            ComparisonCheckerboard()
            if let image {
                Image(nsImage: image).resizable().renderingMode(.original).interpolation(.none)
                    .frame(width: pixels.width * scale, height: pixels.height * scale)
            }
        }.frame(width: canvas.width, height: canvas.height)
    }
    private func pixelSize(_ image: NSImage?) -> CGSize {
        guard let representation = image?.representations.first else { return .zero }
        return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }
}

private struct ComparisonCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 12
            for y in 0...Int(max(0, size.height) / side) {
                for x in 0...Int(max(0, size.width) / side) {
                    let rect = CGRect(x: CGFloat(x) * side, y: CGFloat(y) * side, width: side, height: side)
                    context.fill(Path(rect), with: .color((x + y).isMultiple(of: 2) ? Color(white: 0.88) : Color(white: 0.7)))
                }
            }
        }.accessibilityHidden(true)
    }
}
