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

    /// Shortest scene, so a very short line still animates.
    public static let minimumSeconds = 0.5

    /// One scene on its own page. `index`/`count` place it in a video of
    /// `count` equal scenes, for the progress bar.
    public static func html(_ scene: Scene, photo: String?, index: Int, count: Int, accent: String = "#2bd4a3") -> String {
        let length = max(minimumSeconds, scene.seconds)
        return page([(scene, photo)], accent: accent, barBase: Double(index) * length, barFull: Double(max(1, count)) * length)
    }

    /// A whole video as one page: the scenes play one after another for their
    /// own `seconds`, and the progress bar runs across all of them.
    public static func timeline(_ scenes: [(scene: Scene, photo: String?)], accent: String = "#2bd4a3") -> String {
        let total = scenes.reduce(0) { $0 + max(minimumSeconds, $1.scene.seconds) }
        return page(scenes, accent: accent, barBase: 0, barFull: max(minimumSeconds, total))
    }

    /// When each scene starts and how long it lasts, as the page plays them.
    public static func starts(_ scenes: [Scene]) -> [(start: Double, length: Double)] {
        var start = 0.0
        return scenes.map { scene in
            let length = max(minimumSeconds, scene.seconds)
            defer { start += length }
            return (start, length)
        }
    }

    private static func page(_ scenes: [(scene: Scene, photo: String?)], accent: String, barBase: Double, barFull: Double) -> String {
        let timing = starts(scenes.map(\.scene))
        let layers = scenes.enumerated().map { index, part in layer(part.scene, photo: part.photo, id: "s\(index)") }.joined(separator: "\n")
        let list = zip(scenes, timing).enumerated().map { index, pair in
            "{id:'s\(index)',start:\(number(pair.1.start)),length:\(number(pair.1.length)),style:'\(pair.0.scene.style.rawValue)'}"
        }.joined(separator: ",")
        return """
        <style>
        html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#050b0a;font-family:-apple-system,Helvetica,sans-serif}
        .scene{position:absolute;inset:0;display:none}
        .kicker{width:14vw;height:1.6vw;background:\(accent);border-radius:1vw;margin-bottom:4vw}
        h1{margin:0;color:#fff;font-weight:900;font-size:11vw;line-height:1.02;letter-spacing:-.02em}
        p{margin:4vw 0 0;color:rgba(255,255,255,.92);font-size:5vw;line-height:1.3;font-weight:600}
        #bar{position:absolute;left:0;top:0;height:1vw;background:\(accent)}
        </style>
        \(layers)
        <div id="bar"></div>
        <script>
        const scenes=[\(list)],barBase=\(number(barBase)),barFull=\(number(barFull));
        const ease=x=>1-Math.pow(1-Math.min(1,Math.max(0,x)),3);
        function animate(s,t){
          const p=Math.min(1,Math.max(0,t/s.length));
          const photo=document.getElementById(s.id+'-photo');
          if(s.style==='headline'){photo.style.transform='scale('+(1+0.08*p)+')';}
          if(s.style==='device'){photo.style.transform='translateY('+((1-ease(t/0.6))*6)+'vh)';}
          if(s.style==='title'){photo.style.filter='hue-rotate('+(p*40)+'deg)';}
          const head=document.getElementById(s.id+'-head'),cap=document.getElementById(s.id+'-cap');
          const inHead=ease(t/0.5),inCap=ease((t-0.35)/0.5);
          head.style.transform='translateY('+((1-inHead)*8)+'vh)';head.style.opacity=inHead;
          cap.style.transform='translateY('+((1-inCap)*4)+'vh)';cap.style.opacity=inCap;
        }
        window.renderFrame=function(t){
          scenes.forEach((s,i)=>{
            const last=i===scenes.length-1;
            const active=t>=s.start&&(t<s.start+s.length||last);
            document.getElementById(s.id).style.display=active?'block':'none';
            if(active)animate(s,t-s.start);
          });
          document.getElementById('bar').style.width=(Math.min(1,(barBase+t)/barFull)*100)+'%';
        };
        </script>
        """
    }

    private static func layer(_ scene: Scene, photo: String?, id: String) -> String {
        let headline = CarouselPage.escape(scene.headline)
        let caption = CarouselPage.escape(scene.caption)
        let picture = photo.map { "url('\(CarouselPage.escape($0))')" } ?? "none"
        switch scene.style {
        case .headline:
            return """
            <div class="scene" id="\(id)">
              <div id="\(id)-photo" style="position:absolute;inset:-6%;background:\(picture) center/cover no-repeat"></div>
              <div style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(0,0,0,0) 40%,rgba(0,0,0,.85) 82%)"></div>
              <div style="position:absolute;left:7%;right:7%;bottom:12%">
                <div class="kicker"></div><h1 id="\(id)-head">\(headline)</h1><p id="\(id)-cap">\(caption)</p>
              </div>
            </div>
            """
        case .device:
            return """
            <div class="scene" id="\(id)">
              <div style="position:absolute;inset:0;background:radial-gradient(circle at 50% 30%,#163a32,#050b0a 70%)"></div>
              <div id="\(id)-photo" style="position:absolute;left:18%;right:18%;top:8%;height:58%;border-radius:6vw;border:1.6vw solid #1c1f20;
                box-shadow:0 4vw 10vw rgba(0,0,0,.6);background:\(picture) top/cover no-repeat"></div>
              <div style="position:absolute;left:7%;right:7%;bottom:9%;text-align:center">
                <h1 id="\(id)-head">\(headline)</h1><p id="\(id)-cap">\(caption)</p>
              </div>
            </div>
            """
        case .title:
            return """
            <div class="scene" id="\(id)">
              <div id="\(id)-photo" style="position:absolute;inset:0;background:linear-gradient(150deg,#0f3d33,#071311 60%,#1b0f2e)"></div>
              <div style="position:absolute;left:8%;right:8%;top:30%">
                <div class="kicker"></div><h1 id="\(id)-head" style="font-size:15vw">\(headline)</h1><p id="\(id)-cap">\(caption)</p>
              </div>
            </div>
            """
        }
    }

    /// A number for the page script: plain decimal, never "nan" or "inf".
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    /// A style for each photo scene: screenshots (tall, with text) go in the
    /// phone frame, everything else full-bleed.
    public static func style(forPhotoNote note: String) -> Style {
        let lower = note.lowercased()
        return lower.contains("screenshot") ? .device : .headline
    }
}
