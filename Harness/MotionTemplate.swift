import Foundation

/// Motion-graphics scenes for short videos, as sealed HTML pages that draw
/// themselves for a moment `t` through `window.renderFrame(t)` (see the app's
/// `HTMLMotionCapture`). The model picks words; the motion is fixed here, so
/// small models never write animation code. Every scene is deterministic: the
/// same `t` always gives the same frame.
public enum MotionTemplate {
    public enum Style: String, CaseIterable, Codable, Sendable {
        /// Photo full-bleed with a slow push-in, headline sliding up, caption after it.
        case headline
        /// Photo inside a rounded phone frame on a dark background: for screenshots.
        case device
        /// Big words on colour, no photo: for a hook or a closing line.
        case title
    }

    public struct Scene: Equatable, Sendable {
        public let style: Style
        public let headline: String
        public let caption: String
        public let seconds: Double
        public init(style: Style, headline: String, caption: String = "", seconds: Double) {
            self.style = style; self.headline = headline; self.caption = caption; self.seconds = seconds
        }
    }

    /// One scene's page. `photo` is a data URL (the page loads nothing else),
    /// `index`/`count` drive the progress bar across the whole video.
    public static func html(_ scene: Scene, photo: String?, index: Int, count: Int, accent: String = "#2bd4a3") -> String {
        let headline = CarouselPage.escape(scene.headline)
        let caption = CarouselPage.escape(scene.caption)
        let picture = photo.map { "url('\(CarouselPage.escape($0))')" } ?? "none"
        let length = max(0.5, scene.seconds)
        let layout: String
        switch scene.style {
        case .headline:
            layout = """
            <div id="photo" style="position:absolute;inset:-6%;background:\(picture) center/cover no-repeat"></div>
            <div style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(0,0,0,0) 40%,rgba(0,0,0,.85) 82%)"></div>
            <div id="words" style="position:absolute;left:7%;right:7%;bottom:12%">
              <div class="kicker"></div><h1 id="head">\(headline)</h1><p id="cap">\(caption)</p>
            </div>
            """
        case .device:
            layout = """
            <div style="position:absolute;inset:0;background:radial-gradient(circle at 50% 30%,#163a32,#050b0a 70%)"></div>
            <div id="photo" style="position:absolute;left:18%;right:18%;top:8%;height:58%;border-radius:6vw;border:1.6vw solid #1c1f20;
              box-shadow:0 4vw 10vw rgba(0,0,0,.6);background:\(picture) top/cover no-repeat"></div>
            <div id="words" style="position:absolute;left:7%;right:7%;bottom:9%;text-align:center">
              <h1 id="head">\(headline)</h1><p id="cap">\(caption)</p>
            </div>
            """
        case .title:
            layout = """
            <div id="photo" style="position:absolute;inset:0;background:linear-gradient(150deg,#0f3d33,#071311 60%,#1b0f2e)"></div>
            <div id="words" style="position:absolute;left:8%;right:8%;top:30%">
              <div class="kicker"></div><h1 id="head" style="font-size:15vw">\(headline)</h1><p id="cap">\(caption)</p>
            </div>
            """
        }
        return """
        <style>
        html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#050b0a;font-family:-apple-system,Helvetica,sans-serif}
        .kicker{width:14vw;height:1.6vw;background:\(accent);border-radius:1vw;margin-bottom:4vw}
        h1{margin:0;color:#fff;font-weight:900;font-size:11vw;line-height:1.02;letter-spacing:-.02em}
        p{margin:4vw 0 0;color:rgba(255,255,255,.92);font-size:5vw;line-height:1.3;font-weight:600}
        #bar{position:absolute;left:0;top:0;height:1vw;background:\(accent)}
        </style>
        \(layout)
        <div id="bar"></div>
        <script>
        const length=\(length),index=\(index),count=\(max(1, count)),style='\(scene.style.rawValue)';
        const ease=x=>1-Math.pow(1-Math.min(1,Math.max(0,x)),3);
        window.renderFrame=function(t){
          const p=Math.min(1,Math.max(0,t/length));
          const photo=document.getElementById('photo');
          if(style==='headline'){photo.style.transform='scale('+(1+0.08*p)+')';}
          if(style==='device'){photo.style.transform='translateY('+((1-ease(t/0.6))*6)+'vh)';}
          if(style==='title'){photo.style.filter='hue-rotate('+(p*40)+'deg)';}
          const head=document.getElementById('head'),cap=document.getElementById('cap');
          const inHead=ease(t/0.5),inCap=ease((t-0.35)/0.5);
          head.style.transform='translateY('+((1-inHead)*8)+'vh)';head.style.opacity=inHead;
          cap.style.transform='translateY('+((1-inCap)*4)+'vh)';cap.style.opacity=inCap;
          document.getElementById('bar').style.width=(((index+p)/count)*100)+'%';
        };
        </script>
        """
    }

    /// A style for each photo scene: screenshots (tall, with text) go in the
    /// phone frame, everything else full-bleed.
    public static func style(forPhotoNote note: String) -> Style {
        let lower = note.lowercased()
        return lower.contains("screenshot") ? .device : .headline
    }
}
