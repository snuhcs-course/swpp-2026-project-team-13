import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let output=URL(fileURLWithPath:CommandLine.arguments[1])
let color=CGColorSpace(name:CGColorSpace.sRGB)!
let context=CGContext(data:nil,width:1024,height:1024,bitsPerComponent:8,bytesPerRow:4096,space:color,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red:0.39,green:0.31,blue:0.85,alpha:1));context.fill(CGRect(x:0,y:0,width:1024,height:1024))
context.setStrokeColor(CGColor(red:1,green:1,blue:1,alpha:1));context.setLineWidth(55);context.setLineCap(.round)
for (i,height) in [180.0,330,480,330,180].enumerated() {
 let x=286.0+Double(i)*113
 context.move(to:CGPoint(x:x,y:512-height/2));context.addLine(to:CGPoint(x:x,y:512+height/2));context.strokePath()
}
let dest=CGImageDestinationCreateWithURL(output as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(dest,context.makeImage()!,nil);guard CGImageDestinationFinalize(dest) else {fatalError("PNG export failed")}
