import AppKit
import CoreText
let base = CommandLine.arguments[1]
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [CGFloat((hex>>16)&255)/255, CGFloat((hex>>8)&255)/255, CGFloat(hex&255)/255,a])! }
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect:r,cornerWidth:radius,cornerHeight:radius,transform:nil) }
func gradient(_ c: CGContext,_ colors:[CGColor],_ start:CGPoint,_ end:CGPoint) { c.drawLinearGradient(CGGradient(colorsSpace:cs,colors:colors as CFArray,locations:nil)!,start:start,end:end,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation]) }
func promptPath() -> CGPath { let p=CGMutablePath(); p.move(to:CGPoint(x:258,y:310)); p.addLine(to:CGPoint(x:420,y:472)); p.addLine(to:CGPoint(x:258,y:634)); p.addLine(to:CGPoint(x:737,y:634)); return p.copy(strokingWithWidth:88,lineCap:.round,lineJoin:.round,miterLimit:10) }
let endpoint = rounded(CGRect(x:700,y:559,width:150,height:150),30)
func mark(_ c:CGContext, mono:Bool=false, tinted:Bool=false, depth:Bool=true) {
 let p = promptPath().union(endpoint)
 if depth { c.saveGState();c.setShadow(offset:CGSize(width:0,height:10),blur:18,color:color(0x000000,0.36));c.addPath(p);c.setFillColor(color(0x0bbfa9));c.fillPath();c.restoreGState() }
 c.saveGState();c.addPath(p);c.clip()
 if mono { c.setFillColor(color(0x000000));c.fill(CGRect(x:0,y:0,width:1024,height:1024)) }
 else { gradient(c,tinted ? [color(0xffffff),color(0xaab4b7)] : [color(0xc4ffed),color(0x51fbd4),color(0x12c6b6)],CGPoint(x:330,y:265),CGPoint(x:730,y:730)) }
 c.restoreGState()
 if depth { c.saveGState();c.addPath(p);c.clip();c.translateBy(x:0,y:2);c.addPath(p);c.setStrokeColor(color(0xffffff,0.28));c.setLineWidth(3);c.strokePath();c.restoreGState() }
}
func context(_ w:Int,_ h:Int,opaque:Bool=false)->CGContext { let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:cs,bitmapInfo:opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!; c.translateBy(x:0,y:CGFloat(h));c.scaleBy(x:1,y:-1);return c }
func save(_ c:CGContext,_ path:String) { let rep=NSBitmapImageRep(cgImage:c.makeImage()!);try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:base+"/"+path)) }
func appIcon(_ size:Int,_ mode:String)->CGContext {
 let mac=mode == "mac";let dark=mode == "dark";let tinted=mode == "tinted"
 let c=context(size,size,opaque: !mac);c.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
 let r=mac ? CGRect(x:100,y:100,width:824,height:824) : CGRect(x:0,y:0,width:1024,height:1024)
 let tile=rounded(r,mac ? 184 : 0)
 if mac { c.saveGState();c.setShadow(offset:CGSize(width:0,height:14),blur:22,color:color(0x000000,0.3));c.addPath(tile);c.setFillColor(color(0x081322));c.fillPath();c.restoreGState() }
 c.saveGState();c.addPath(tile);c.clip()
 gradient(c,tinted ? [color(0x252a2e),color(0x080b0e)] : dark ? [color(0x111f32),color(0x030b13)] : [color(0x233d60),color(0x0c1d33),color(0x050e18)],CGPoint(x:150,y:40),CGPoint(x:850,y:1024))
 if mac { c.addPath(tile);c.setLineWidth(6);c.setStrokeColor(color(0xa9c8f6,0.20));c.strokePath() }
 c.restoreGState()
 if mac { c.translateBy(x:100,y:100);c.scaleBy(x:0.8046875,y:0.8046875) }
 mark(c,tinted:tinted,depth:mac)
 return c
}
for s in [16,32,128,256,512] { save(appIcon(s,"mac"),"macOS/Tether.iconset/icon_\(s)x\(s).png");save(appIcon(s*2,"mac"),"macOS/Tether.iconset/icon_\(s)x\(s)@2x.png") }
save(appIcon(1024,"mac"),"macOS/Tether-1024.png")
for mode in ["default","dark","tinted"] { save(appIcon(1024,mode),"iOS/AppIcon.appiconset/Tether-\(mode).png") }
func menu(_ c:CGContext) {
 let p=CGMutablePath();p.move(to:CGPoint(x:3.5,y:4));p.addLine(to:CGPoint(x:8.25,y:8.75));p.addLine(to:CGPoint(x:3.5,y:13.5));p.addLine(to:CGPoint(x:15.75,y:13.5))
 c.addPath(p);c.setLineWidth(2.5);c.setLineCap(.round);c.setLineJoin(.round);c.setStrokeColor(color(0x000000));c.strokePath();c.addPath(rounded(CGRect(x:14.5,y:10.5,width:5.5,height:5.5),1.2));c.setFillColor(color(0));c.fillPath()
}
for scale in 1...3 { let c=context(22*scale,22*scale);c.scaleBy(x:CGFloat(scale),y:CGFloat(scale));menu(c);save(c,"MenuBar/TetherMenuBar.imageset/TetherMenuBar\(scale==1 ? "" : "@\(scale)x").png") }
var media=CGRect(x:0,y:0,width:22,height:22)
let pdfURL=URL(fileURLWithPath:base+"/MenuBar/TetherMenuBar.pdf")
let pdf=CGContext(pdfURL as CFURL,mediaBox:&media,nil)!;pdf.beginPDFPage(nil);pdf.translateBy(x:0,y:22);pdf.scaleBy(x:1,y:-1);menu(pdf);pdf.endPDFPage();pdf.closePDF()
let fg=context(1024,1024);mark(fg,depth:false);save(fg,"IconComposer-Layers/Foreground.png")
let bg=context(1024,1024,opaque:true);gradient(bg,[color(0x233d60),color(0x0c1d33),color(0x050e18)],CGPoint(x:150,y:40),CGPoint(x:850,y:1024));save(bg,"IconComposer-Layers/Background.png")
func text(_ c:CGContext,_ string:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ hex:UInt32=0x132239) { c.saveGState();c.translateBy(x:x,y:y);c.scaleBy(x:1,y:-1);c.textPosition = .zero;let attrs:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:size,weight:.medium),.foregroundColor:NSColor(cgColor:color(hex))!];let line=CTLineCreateWithAttributedString(NSAttributedString(string:string,attributes:attrs));CTLineDraw(line,c);c.restoreGState() }
func draw(_ c:CGContext,_ image:CGImage,_ r:CGRect) {c.saveGState();c.translateBy(x:r.minX,y:r.maxY);c.scaleBy(x:1,y:-1);c.draw(image,in:CGRect(x:0,y:0,width:r.width,height:r.height));c.restoreGState()}
let preview=context(1600,1100,opaque:true);preview.setFillColor(color(0xf5f5f2));preview.fill(CGRect(x:0,y:0,width:1600,height:1100))
text(preview,"Tether",80,100,48);text(preview,"Connected prompt · Icon suite",80,144,22,0x536175)
text(preview,"macOS Dock",100,230,25);text(preview,"iOS",620,230,25);text(preview,"Menu bar",1140,230,25)
draw(preview,appIcon(1024,"mac").makeImage()!,CGRect(x:55,y:250,width:490,height:490))
preview.saveGState();preview.addPath(rounded(CGRect(x:620,y:296,width:400,height:400),90));preview.clip();draw(preview,appIcon(1024,"default").makeImage()!,CGRect(x:620,y:296,width:400,height:400));preview.restoreGState()
for (index,dark) in [false,true].enumerated() {let y=CGFloat(310+index*150);let r=CGRect(x:1140,y:y,width:360,height:110);preview.addPath(rounded(r,18));preview.setFillColor(color(dark ? 0x162336 : 0xe3e7e9));preview.fillPath();preview.saveGState();preview.translateBy(x:1180,y:y+31);preview.scaleBy(x:2,y:2);if dark {preview.beginTransparencyLayer(auxiliaryInfo:nil)};menu(preview);if dark {preview.setBlendMode(.sourceIn);preview.setFillColor(color(0xffffff));preview.fill(CGRect(x:0,y:0,width:22,height:22));preview.endTransparencyLayer()};preview.restoreGState();text(preview,dark ? "Dark appearance" : "Light appearance",1245,y+63,19,dark ? 0xffffff : 0x263649)}
text(preview,"Dock sizes",100,810,22)
for (i,s) in [16,32,64,128].enumerated() {let x=CGFloat(100+i*115);draw(preview,appIcon(s*2,"mac").makeImage()!,CGRect(x:x,y:840,width:CGFloat(s),height:CGFloat(s)));text(preview,"\(s) pt",x,1000,16,0x536175)}
text(preview,"iOS appearances",620,810,22)
for (i,m) in ["default","dark","tinted"].enumerated() {let r=CGRect(x:620+i*145,y:845,width:112,height:112);preview.saveGState();preview.addPath(rounded(r,25));preview.clip();draw(preview,appIcon(224,m).makeImage()!,r);preview.restoreGState();text(preview,m.capitalized,r.minX,1000,16,0x536175)}
text(preview,"Actual menu bar size",1140,810,22)
preview.saveGState();preview.translateBy(x:1140,y:845);menu(preview);preview.restoreGState();text(preview,"22 pt · template",1180,862,17,0x536175)
save(preview,"Tether-Preview.png")
print("Rendered macOS, iOS, menu bar, layer sources, and preview.")
