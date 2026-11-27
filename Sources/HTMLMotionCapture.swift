import AVFoundation
import UIKit
import WebKit

/// Turns an HTML animation into a silent `.mp4`, frame by frame. The page
/// defines `window.renderFrame(t)` (t in seconds) and draws itself for that
/// moment; nothing depends on real time, so a slow phone makes a slower
/// render, never a stuttering video. The page runs sealed: no network, no
/// storage. This is the measurement step before HTML motion templates for
/// the Videos screen: how long one 1080×1920 frame takes on a real iPhone.
@MainActor
final class HTMLMotionCapture: NSObject, WKNavigationDelegate {
    struct Stats: Equatable {
        let frames: Int
        let seconds: TimeInterval
        /// Average milliseconds per frame in each step, and in total.
        let scriptMs: Double
        let snapshotMs: Double
        let encodeMs: Double
        var frameMs: Double { frames > 0 ? seconds * 1000 / Double(frames) : 0 }

        var summary: String {
            String(format: "%d frames in %.1f s · %.0f ms a frame (page %.0f, snapshot %.0f, encode %.0f)",
                   frames, seconds, frameMs, scriptMs, snapshotMs, encodeMs)
        }
    }

    enum Failure: LocalizedError {
        case load, noRenderFrame, snapshot, writer(String)
        var errorDescription: String? {
            switch self {
            case .load: return "The animation page did not load."
            case .noRenderFrame: return "The animation page has no renderFrame(t) function."
            case .snapshot: return "A frame of the animation could not be captured."
            case .writer(let why): return "The video could not be written (\(why))."
            }
        }
    }

    /// No network, no remote fonts or images: only what is in the page.
    static let contentPolicy = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data: blob:; font-src data:"

    private var loaded: CheckedContinuation<Void, Error>?

    /// Renders `seconds` of the page at `width`×`height` pixels into `url`.
    func render(html: String, seconds: TimeInterval, width: Int = 1080, height: Int = 1920, fps: Int32 = 30,
                to url: URL, shouldContinue: @escaping () -> Bool = { true },
                progress: @escaping (Double) -> Void = { _ in }) async throws -> Stats {
        let scale = UIScreen.main.scale
        let points = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        let web = WKWebView(frame: CGRect(origin: .zero, size: points), configuration: configuration)
        web.isOpaque = true
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = self
        // A web view only draws inside a window: this one sits behind the app's.
        let window = Self.backstage(size: points)
        window.addSubview(web)
        window.isHidden = false
        defer { web.removeFromSuperview(); window.isHidden = true }

        let page = "<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"\(Self.contentPolicy)\">"
            + "<meta name=\"viewport\" content=\"width=\(Int(points.width)), initial-scale=1\">" + html
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            web.loadHTMLString(page, baseURL: nil)
        }
        guard (try? await web.evaluateJavaScript("typeof window.renderFrame === 'function'")) as? Bool == true else {
            throw Failure.noRenderFrame
        }

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure.writer("no video input") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        let total = max(1, Int((seconds * Double(fps)).rounded()))
        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = CGRect(origin: .zero, size: points)
        snapshot.snapshotWidth = NSNumber(value: Double(points.width))
        snapshot.afterScreenUpdates = true
        let began = Date()
        var scriptTime = 0.0, snapshotTime = 0.0, encodeTime = 0.0
        do {
            for frame in 0..<total {
                guard shouldContinue() else { throw CancellationError() }
                try Task.checkCancellation()
                let t = Double(frame) / Double(fps)
                var mark = Date()
                _ = try await web.evaluateJavaScript("window.renderFrame(\(t)); 0")
                scriptTime += Date().timeIntervalSince(mark); mark = Date()
                guard let image = try await web.takeSnapshot(configuration: snapshot).cgImage else { throw Failure.snapshot }
                snapshotTime += Date().timeIntervalSince(mark); mark = Date()
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no pixel buffer pool") }
                var made: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
                guard let buffer = made else { throw Failure.writer("no pixel buffer") }
                Self.draw(image, into: buffer, width: width, height: height)
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                    throw Failure.writer(writer.error?.localizedDescription ?? "append")
                }
                encodeTime += Date().timeIntervalSince(mark)
                if frame % 10 == 0 { progress(Double(frame) / Double(total)) }
            }
        } catch {
            input.markAsFinished()
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(total), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writer(writer.error?.localizedDescription ?? "finish") }
        progress(1)
        let count = Double(total)
        return Stats(frames: total, seconds: Date().timeIntervalSince(began),
                     scriptMs: scriptTime * 1000 / count, snapshotMs: snapshotTime * 1000 / count, encodeMs: encodeTime * 1000 / count)
    }

    private static func backstage(size: CGSize) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.isUserInteractionEnabled = false
        return window
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume(); loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: Failure.load); loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: Failure.load); loaded = nil
    }

    /// A motion-graphics page like the templates would be: a shifting
    /// gradient, a title that flies in, a caption, moving particles and a
    /// turning card. The square in the top-left corner is red for the first
    /// half and blue for the second, so tests can tell frames follow `t`.
    static func benchmarkPage(seconds: Double) -> String {
        """
        <style>
        html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#111;font-family:-apple-system,Helvetica,sans-serif}
        #bg{position:absolute;inset:0}
        #marker{position:absolute;left:0;top:0;width:10%;height:6%}
        #title{position:absolute;left:0;right:0;top:34%;text-align:center;color:#fff;font-weight:900;font-size:13vw;letter-spacing:-0.03em}
        #caption{position:absolute;left:8%;right:8%;top:62%;text-align:center;color:#ffe81a;font-weight:800;font-size:6vw}
        .dot{position:absolute;width:2.2vw;height:2.2vw;border-radius:50%;background:rgba(255,255,255,.7)}
        #card{position:absolute;left:25%;top:72%;width:50%;height:16%;border-radius:4vw;background:linear-gradient(135deg,#2bd4a3,#1a6cff)}
        </style>
        <div id="bg"></div><div id="title">KEEL</div><div id="caption">AI THAT STAYS ON YOUR PHONE</div><div id="card"></div><div id="marker"></div>
        <script>
        const dots=[];for(let i=0;i<40;i++){const d=document.createElement('div');d.className='dot';document.body.appendChild(d);dots.push(d)}
        const length=\(seconds);
        window.renderFrame=function(t){
          const p=Math.min(1,t/length);
          document.getElementById('bg').style.background='linear-gradient('+(160+p*120)+'deg,hsl('+(220+p*80)+',70%,18%),hsl('+(300+p*60)+',80%,8%))';
          const fly=Math.min(1,t/0.8),ease=1-Math.pow(1-fly,3);
          const title=document.getElementById('title');title.style.transform='translateY('+((1-ease)*40)+'vh) scale('+(0.6+0.4*ease)+')';title.style.opacity=ease;
          const cap=document.getElementById('caption');cap.style.opacity=Math.max(0,Math.min(1,(t-0.6)*2));
          dots.forEach((d,i)=>{const a=i*2.399+t*(0.4+i%5*0.1);d.style.left=(50+Math.cos(a)*(20+i))+'%';d.style.top=(45+Math.sin(a*1.3)*(15+i%7*4))+'%'});
          document.getElementById('card').style.transform='perspective(80vw) rotateY('+(Math.sin(t*1.5)*35)+'deg)';
          document.getElementById('marker').style.background=t<length/2?'rgb(255,0,0)':'rgb(0,0,255)';
        };
        </script>
        """
    }
}
