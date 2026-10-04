import Foundation

// The geometry value types CGFloat, CGPoint, CGSize, CGRect (and CGAffineTransform) come from swift-corelibs-foundation
// on Windows and Linux (CGAffineTransform from CGAffineTransformShim.swift). On Apple platforms `import Foundation`
// exposes the type names but not their CoreGraphics members (`minY`, `.zero`, `init(x:y:width:height:)`, `applying`),
// so this is the one place the core imports CoreGraphics. Only those geometry value types may be used from it:
// scripts/check_core_portable.sh rejects every other CoreGraphics API and every other import.
#if canImport(CoreGraphics)
@_exported import CoreGraphics
#endif
