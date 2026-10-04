import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageCratCore

struct SwatchColor: Equatable {
    var name: String
    var color: RGBA
}

struct SwatchLibrary {
    var name: String
    var colors: [SwatchColor]
}

enum SwatchIOError: LocalizedError {
    case badFormat
    var errorDescription: String? { "The swatch file could not be read." }
}

/// Adobe Color Swatch (.aco), Adobe Swatch Exchange (.ase) and Color Table (.act) reading / writing.
enum SwatchIO {
    static func load(url: URL) throws -> SwatchLibrary {
        let d = try Data(contentsOf: url)
        let name = url.deletingPathExtension().lastPathComponent
        switch url.pathExtension.lowercased() {
        case "aco": return SwatchLibrary(name: name, colors: try parseACO(d))
        case "ase": return SwatchLibrary(name: name, colors: try parseASE(d))
        case "act": return SwatchLibrary(name: name, colors: parseACT(d).enumerated().map { SwatchColor(name: "Color \($0.offset + 1)", color: $0.element) })
        default:
            if d.starts(with: Data("ASEF".utf8)) { return SwatchLibrary(name: name, colors: try parseASE(d)) }
            return SwatchLibrary(name: name, colors: try parseACO(d))
        }
    }

    // MARK: Big-endian reader

    struct Reader {
        let d: Data
        var i = 0
        init(_ d: Data) { self.d = d }
        var remaining: Int { d.count - i }
        mutating func u8() throws -> UInt8 { guard i < d.count else { throw SwatchIOError.badFormat }; defer { i += 1 }; return d[d.startIndex + i] }
        mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
        mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }
        mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
        mutating func utf16(_ units: Int) throws -> String {
            var cs: [UInt16] = []
            for _ in 0..<units { cs.append(try u16()) }
            while cs.last == 0 { cs.removeLast() }
            return String(decoding: cs, as: UTF16.self)
        }
        mutating func skip(_ n: Int) throws { guard i + n <= d.count else { throw SwatchIOError.badFormat }; i += n }
    }

    // MARK: ACO

    static func acoColor(space: UInt16, _ w: UInt16, _ x: UInt16, _ y: UInt16, _ z: UInt16) -> RGBA? {
        switch space {
        case 0: return RGBA(r: Double(w) / 65535, g: Double(x) / 65535, b: Double(y) / 65535)
        case 1: return RGBA(h: Double(w) / 65536, s: Double(x) / 65535, v: Double(y) / 65535)
        case 2:   // CMYK: 0 = 100 % ink
            let c = 1 - Double(w) / 65535, m = 1 - Double(x) / 65535, yy = 1 - Double(y) / 65535, k = 1 - Double(z) / 65535
            return cmykToRGB(c, m, yy, k)
        case 7:
            let L = Double(w) / 100, a = Double(Int16(bitPattern: x)) / 100, b = Double(Int16(bitPattern: y)) / 100
            let v = Quantizer.rgb(fromLab: SIMD3(L, a, b)) / 255
            return RGBA(r: v.x, g: v.y, b: v.z)
        case 8: let g = 1 - Double(w) / 10000; return RGBA(gray: clamp(g, 0, 1))
        case 9:
            return cmykToRGB(Double(w) / 10000, Double(x) / 10000, Double(y) / 10000, Double(z) / 10000)
        default: return nil
        }
    }

    static func cmykToRGB(_ c: Double, _ m: Double, _ y: Double, _ k: Double) -> RGBA {
        let cs = ColorProfiles.space(named: ColorProfiles.cmykName)
        if cs.model == .cmyk, let col = CGColor(colorSpace: cs, components: [c, m, y, k, 1]),
           let conv = col.converted(to: sRGBSpace, intent: .relativeColorimetric, options: nil), let p = conv.components, p.count >= 3 {
            return RGBA(r: Double(p[0]), g: Double(p[1]), b: Double(p[2]))
        }
        return RGBA(r: (1 - c) * (1 - k), g: (1 - m) * (1 - k), b: (1 - y) * (1 - k))
    }

    static func parseACO(_ d: Data) throws -> [SwatchColor] {
        var r = Reader(d)
        var v1: [SwatchColor] = []
        var v2: [SwatchColor] = []
        while r.remaining >= 4 {
            let version = try r.u16()
            let count = Int(try r.u16())
            guard version == 1 || version == 2 else { throw SwatchIOError.badFormat }
            var list: [SwatchColor] = []
            for n in 0..<count {
                let sp = try r.u16(), w = try r.u16(), x = try r.u16(), y = try r.u16(), z = try r.u16()
                var name = "Swatch \(n + 1)"
                if version == 2 {
                    let len = Int(try r.u32())
                    name = try r.utf16(len)
                }
                if let c = acoColor(space: sp, w, x, y, z) { list.append(SwatchColor(name: name, color: c)) }
            }
            if version == 1 { v1 = list } else { v2 = list }
        }
        if v1.isEmpty && v2.isEmpty && d.count >= 4 { throw SwatchIOError.badFormat }
        return v2.isEmpty ? v1 : v2
    }

    static func writeACO(_ colors: [SwatchColor]) -> Data {
        var d = Data()
        func u16(_ v: Int) { d.append(UInt8((v >> 8) & 255)); d.append(UInt8(v & 255)) }
        func u32(_ v: Int) { u16(v >> 16); u16(v & 0xFFFF) }
        for version in 1...2 {
            u16(version); u16(colors.count)
            for c in colors {
                u16(0)
                u16(Int((clamp(c.color.r, 0, 1) * 65535).rounded())); u16(Int((clamp(c.color.g, 0, 1) * 65535).rounded())); u16(Int((clamp(c.color.b, 0, 1) * 65535).rounded())); u16(0)
                if version == 2 {
                    let units = Array(c.name.utf16)
                    u32(units.count + 1)
                    for u in units { u16(Int(u)) }
                    u16(0)
                }
            }
        }
        return d
    }

    // MARK: ASE

    static func parseASE(_ d: Data) throws -> [SwatchColor] {
        var r = Reader(d)
        guard try r.u32() == 0x41534546 else { throw SwatchIOError.badFormat }   // "ASEF"
        _ = try r.u16(); _ = try r.u16()
        let blocks = Int(try r.u32())
        var out: [SwatchColor] = []
        for _ in 0..<blocks {
            guard r.remaining >= 6 else { break }
            let type = try r.u16()
            let len = Int(try r.u32())
            let start = r.i
            if type == 0x0001 {
                let nlen = Int(try r.u16())
                let name = try r.utf16(nlen)
                let model = String(bytes: [try r.u8(), try r.u8(), try r.u8(), try r.u8()], encoding: .ascii) ?? ""
                var c: RGBA?
                switch model {
                case "RGB ": c = RGBA(r: Double(try r.f32()), g: Double(try r.f32()), b: Double(try r.f32()))
                case "CMYK": c = cmykToRGB(Double(try r.f32()), Double(try r.f32()), Double(try r.f32()), Double(try r.f32()))
                case "LAB ":
                    var L = Double(try r.f32()); let a = Double(try r.f32()), b = Double(try r.f32())
                    if L <= 1.0001 { L *= 100 }
                    let v = Quantizer.rgb(fromLab: SIMD3(L, a, b)) / 255
                    c = RGBA(r: v.x, g: v.y, b: v.z)
                case "Gray": c = RGBA(gray: Double(try r.f32()))
                default: break
                }
                if let c { out.append(SwatchColor(name: name, color: RGBA(r: clamp(c.r, 0, 1), g: clamp(c.g, 0, 1), b: clamp(c.b, 0, 1)))) }
            }
            r.i = start + len
        }
        return out
    }

    static func writeASE(_ colors: [SwatchColor], groupName: String? = nil) -> Data {
        var d = Data("ASEF".utf8)
        func u16(_ v: Int, _ into: inout Data) { into.append(UInt8((v >> 8) & 255)); into.append(UInt8(v & 255)) }
        func u32(_ v: Int, _ into: inout Data) { u16(v >> 16, &into); u16(v & 0xFFFF, &into) }
        func f32(_ v: Double, _ into: inout Data) { u32(Int(Float(v).bitPattern), &into) }
        func name(_ s: String, _ into: inout Data) { let u = Array(s.utf16); u16(u.count + 1, &into); for c in u { u16(Int(c), &into) }; u16(0, &into) }
        u16(1, &d); u16(0, &d)
        u32(colors.count + (groupName != nil ? 2 : 0), &d)
        if let g = groupName {
            var b = Data(); name(g, &b)
            u16(0xC001, &d); u32(b.count, &d); d.append(b)
        }
        for c in colors {
            var b = Data()
            name(c.name, &b)
            b.append(Data("RGB ".utf8))
            f32(c.color.r, &b); f32(c.color.g, &b); f32(c.color.b, &b)
            u16(2, &b)
            u16(0x0001, &d); u32(b.count, &d); d.append(b)
        }
        if groupName != nil { u16(0xC002, &d); u32(0, &d) }
        return d
    }

    // MARK: ACT

    static func parseACT(_ d: Data) -> [RGBA] {
        guard d.count >= 768 else { return [] }
        var n = 256
        if d.count >= 772 { n = max(1, min(256, Int(d[d.startIndex + 768]) << 8 | Int(d[d.startIndex + 769]))) }
        return (0..<n).map { i in RGBA(r8: d[d.startIndex + i * 3], g8: d[d.startIndex + i * 3 + 1], b8: d[d.startIndex + i * 3 + 2]) }
    }

    static func writeACT(_ colors: [RGBA], transparentIndex: Int?) -> Data {
        var d = Data(count: 772)
        for (i, c) in colors.prefix(256).enumerated() { d[i * 3] = UInt8(c.r8); d[i * 3 + 1] = UInt8(c.g8); d[i * 3 + 2] = UInt8(c.b8) }
        let n = min(256, colors.count)
        d[768] = UInt8(n >> 8); d[769] = UInt8(n & 255)
        let t = transparentIndex ?? 0xFFFF
        d[770] = UInt8((t >> 8) & 255); d[771] = UInt8(t & 255)
        return d
    }
}

// MARK: - Built-in libraries (free / public colour lists; no Pantone data)

enum SwatchLibraries {
    static func lib(_ name: String, _ pairs: [(String, String)]) -> SwatchLibrary {
        SwatchLibrary(name: name, colors: pairs.compactMap { p in RGBA(hex: p.1).map { SwatchColor(name: p.0, color: $0) } })
    }

    static var builtIn: [SwatchLibrary] { [html, material, ral, grays] }

    static let grays: SwatchLibrary = SwatchLibrary(name: "Grays (10 %)", colors: (0...10).map { SwatchColor(name: "\($0 * 10)% Gray", color: RGBA(gray: 1 - Double($0) / 10)) })

    static let html: SwatchLibrary = lib("HTML Named Colors", [
        ("AliceBlue", "F0F8FF"), ("AntiqueWhite", "FAEBD7"), ("Aqua", "00FFFF"), ("Aquamarine", "7FFFD4"), ("Azure", "F0FFFF"), ("Beige", "F5F5DC"),
        ("Bisque", "FFE4C4"), ("Black", "000000"), ("BlanchedAlmond", "FFEBCD"), ("Blue", "0000FF"), ("BlueViolet", "8A2BE2"), ("Brown", "A52A2A"),
        ("BurlyWood", "DEB887"), ("CadetBlue", "5F9EA0"), ("Chartreuse", "7FFF00"), ("Chocolate", "D2691E"), ("Coral", "FF7F50"), ("CornflowerBlue", "6495ED"),
        ("Cornsilk", "FFF8DC"), ("Crimson", "DC143C"), ("Cyan", "00FFFF"), ("DarkBlue", "00008B"), ("DarkCyan", "008B8B"), ("DarkGoldenRod", "B8860B"),
        ("DarkGray", "A9A9A9"), ("DarkGreen", "006400"), ("DarkKhaki", "BDB76B"), ("DarkMagenta", "8B008B"), ("DarkOliveGreen", "556B2F"), ("DarkOrange", "FF8C00"),
        ("DarkOrchid", "9932CC"), ("DarkRed", "8B0000"), ("DarkSalmon", "E9967A"), ("DarkSeaGreen", "8FBC8F"), ("DarkSlateBlue", "483D8B"), ("DarkSlateGray", "2F4F4F"),
        ("DarkTurquoise", "00CED1"), ("DarkViolet", "9400D3"), ("DeepPink", "FF1493"), ("DeepSkyBlue", "00BFFF"), ("DimGray", "696969"), ("DodgerBlue", "1E90FF"),
        ("FireBrick", "B22222"), ("FloralWhite", "FFFAF0"), ("ForestGreen", "228B22"), ("Fuchsia", "FF00FF"), ("Gainsboro", "DCDCDC"), ("GhostWhite", "F8F8FF"),
        ("Gold", "FFD700"), ("GoldenRod", "DAA520"), ("Gray", "808080"), ("Green", "008000"), ("GreenYellow", "ADFF2F"), ("HoneyDew", "F0FFF0"),
        ("HotPink", "FF69B4"), ("IndianRed", "CD5C5C"), ("Indigo", "4B0082"), ("Ivory", "FFFFF0"), ("Khaki", "F0E68C"), ("Lavender", "E6E6FA"),
        ("LavenderBlush", "FFF0F5"), ("LawnGreen", "7CFC00"), ("LemonChiffon", "FFFACD"), ("LightBlue", "ADD8E6"), ("LightCoral", "F08080"), ("LightCyan", "E0FFFF"),
        ("LightGoldenRodYellow", "FAFAD2"), ("LightGray", "D3D3D3"), ("LightGreen", "90EE90"), ("LightPink", "FFB6C1"), ("LightSalmon", "FFA07A"), ("LightSeaGreen", "20B2AA"),
        ("LightSkyBlue", "87CEFA"), ("LightSlateGray", "778899"), ("LightSteelBlue", "B0C4DE"), ("LightYellow", "FFFFE0"), ("Lime", "00FF00"), ("LimeGreen", "32CD32"),
        ("Linen", "FAF0E6"), ("Magenta", "FF00FF"), ("Maroon", "800000"), ("MediumAquaMarine", "66CDAA"), ("MediumBlue", "0000CD"), ("MediumOrchid", "BA55D3"),
        ("MediumPurple", "9370DB"), ("MediumSeaGreen", "3CB371"), ("MediumSlateBlue", "7B68EE"), ("MediumSpringGreen", "00FA9A"), ("MediumTurquoise", "48D1CC"), ("MediumVioletRed", "C71585"),
        ("MidnightBlue", "191970"), ("MintCream", "F5FFFA"), ("MistyRose", "FFE4E1"), ("Moccasin", "FFE4B5"), ("NavajoWhite", "FFDEAD"), ("Navy", "000080"),
        ("OldLace", "FDF5E6"), ("Olive", "808000"), ("OliveDrab", "6B8E23"), ("Orange", "FFA500"), ("OrangeRed", "FF4500"), ("Orchid", "DA70D6"),
        ("PaleGoldenRod", "EEE8AA"), ("PaleGreen", "98FB98"), ("PaleTurquoise", "AFEEEE"), ("PaleVioletRed", "DB7093"), ("PapayaWhip", "FFEFD5"), ("PeachPuff", "FFDAB9"),
        ("Peru", "CD853F"), ("Pink", "FFC0CB"), ("Plum", "DDA0DD"), ("PowderBlue", "B0E0E6"), ("Purple", "800080"), ("RebeccaPurple", "663399"),
        ("Red", "FF0000"), ("RosyBrown", "BC8F8F"), ("RoyalBlue", "4169E1"), ("SaddleBrown", "8B4513"), ("Salmon", "FA8072"), ("SandyBrown", "F4A460"),
        ("SeaGreen", "2E8B57"), ("SeaShell", "FFF5EE"), ("Sienna", "A0522D"), ("Silver", "C0C0C0"), ("SkyBlue", "87CEEB"), ("SlateBlue", "6A5ACD"),
        ("SlateGray", "708090"), ("Snow", "FFFAFA"), ("SpringGreen", "00FF7F"), ("SteelBlue", "4682B4"), ("Tan", "D2B48C"), ("Teal", "008080"),
        ("Thistle", "D8BFD8"), ("Tomato", "FF6347"), ("Turquoise", "40E0D0"), ("Violet", "EE82EE"), ("Wheat", "F5DEB3"), ("White", "FFFFFF"),
        ("WhiteSmoke", "F5F5F5"), ("Yellow", "FFFF00"), ("YellowGreen", "9ACD32"),
    ])

    static let material: SwatchLibrary = {
        let shades = ["50", "100", "200", "300", "400", "500", "600", "700", "800", "900"]
        let table: [(String, String)] = [
            ("Red", "FFEBEE FFCDD2 EF9A9A E57373 EF5350 F44336 E53935 D32F2F C62828 B71C1C"),
            ("Pink", "FCE4EC F8BBD0 F48FB1 F06292 EC407A E91E63 D81B60 C2185B AD1457 880E4F"),
            ("Purple", "F3E5F5 E1BEE7 CE93D8 BA68C8 AB47BC 9C27B0 8E24AA 7B1FA2 6A1B9A 4A148C"),
            ("Deep Purple", "EDE7F6 D1C4E9 B39DDB 9575CD 7E57C2 673AB7 5E35B1 512DA8 4527A0 311B92"),
            ("Indigo", "E8EAF6 C5CAE9 9FA8DA 7986CB 5C6BC0 3F51B5 3949AB 303F9F 283593 1A237E"),
            ("Blue", "E3F2FD BBDEFB 90CAF9 64B5F6 42A5F5 2196F3 1E88E5 1976D2 1565C0 0D47A1"),
            ("Light Blue", "E1F5FE B3E5FC 81D4FA 4FC3F7 29B6F6 03A9F4 039BE5 0288D1 0277BD 01579B"),
            ("Cyan", "E0F7FA B2EBF2 80DEEA 4DD0E1 26C6DA 00BCD4 00ACC1 0097A7 00838F 006064"),
            ("Teal", "E0F2F1 B2DFDB 80CBC4 4DB6AC 26A69A 009688 00897B 00796B 00695C 004D40"),
            ("Green", "E8F5E9 C8E6C9 A5D6A7 81C784 66BB6A 4CAF50 43A047 388E3C 2E7D32 1B5E20"),
            ("Light Green", "F1F8E9 DCEDC8 C5E1A5 AED581 9CCC65 8BC34A 7CB342 689F38 558B2F 33691E"),
            ("Lime", "F9FBE7 F0F4C3 E6EE9C DCE775 D4E157 CDDC39 C0CA33 AFB42B 9E9D24 827717"),
            ("Yellow", "FFFDE7 FFF9C4 FFF59D FFF176 FFEE58 FFEB3B FDD835 FBC02D F9A825 F57F17"),
            ("Amber", "FFF8E1 FFECB3 FFE082 FFD54F FFCA28 FFC107 FFB300 FFA000 FF8F00 FF6F00"),
            ("Orange", "FFF3E0 FFE0B2 FFCC80 FFB74D FFA726 FF9800 FB8C00 F57C00 EF6C00 E65100"),
            ("Deep Orange", "FBE9E7 FFCCBC FFAB91 FF8A65 FF7043 FF5722 F4511E E64A19 D84315 BF360C"),
            ("Brown", "EFEBE9 D7CCC8 BCAAA4 A1887F 8D6E63 795548 6D4C41 5D4037 4E342E 3E2723"),
            ("Grey", "FAFAFA F5F5F5 EEEEEE E0E0E0 BDBDBD 9E9E9E 757575 616161 424242 212121"),
            ("Blue Grey", "ECEFF1 CFD8DC B0BEC5 90A4AE 78909C 607D8B 546E7A 455A64 37474F 263238"),
        ]
        var pairs: [(String, String)] = []
        for (hue, list) in table {
            for (i, hex) in list.split(separator: " ").enumerated() { pairs.append(("\(hue) \(shades[i])", String(hex))) }
        }
        return lib("Material Colors", pairs)
    }()

    /// RAL Classic-like reference colours (commonly published sRGB approximations).
    static let ral: SwatchLibrary = {
        let s = """
        1000 Green beige BEBD7F|1001 Beige C2B078|1002 Sand yellow C6A664|1003 Signal yellow E5BE01|1004 Golden yellow CDA434|1005 Honey yellow A98307|\
        1006 Maize yellow E4A010|1007 Daffodil yellow DC9D00|1011 Brown beige 8A6642|1012 Lemon yellow C7B446|1013 Oyster white EAE6CA|1014 Ivory E1CC4F|\
        1015 Light ivory E6D690|1016 Sulfur yellow EDFF21|1017 Saffron yellow F5D033|1018 Zinc yellow F8F32B|1019 Grey beige 9E9764|1020 Olive yellow 999950|\
        1021 Rape yellow F3DA0B|1023 Traffic yellow FAD201|1024 Ochre yellow AEA04B|1027 Curry 9D9101|1028 Melon yellow F4A900|1032 Broom yellow D6AE01|\
        1033 Dahlia yellow F3A505|1034 Pastel yellow EFA94A|2000 Yellow orange ED760E|2001 Red orange C93C20|2002 Vermilion CB2821|2003 Pastel orange FF7514|\
        2004 Pure orange F44611|2008 Bright red orange F75E25|2009 Traffic orange F54021|2010 Signal orange D84B20|2011 Deep orange EC7C26|2012 Salmon orange E55137|\
        3000 Flame red AF2B1E|3001 Signal red A52019|3002 Carmine red A2231D|3003 Ruby red 9B111E|3004 Purple red 75151E|3005 Wine red 5E2129|\
        3007 Black red 412227|3009 Oxide red 642424|3011 Brown red 781F19|3012 Beige red C1876B|3013 Tomato red A12312|3014 Antique pink D36E70|\
        3015 Light pink EA899A|3016 Coral red B32821|3017 Rose E63244|3018 Strawberry red D53032|3020 Traffic red CC0605|3022 Salmon pink D95030|\
        3027 Raspberry red C51D34|3031 Orient red B32428|4001 Red lilac 6D3F5B|4002 Red violet 922B3E|4003 Heather violet DE4C8A|4004 Claret violet 641C34|\
        4005 Blue lilac 6C4675|4006 Traffic purple A03472|4007 Purple violet 4A192C|4008 Signal violet 924E7D|4009 Pastel violet A18594|4010 Telemagenta CF3476|\
        5000 Violet blue 354D73|5001 Green blue 1F3438|5002 Ultramarine blue 20214F|5003 Sapphire blue 1D1E33|5004 Black blue 18171C|5005 Signal blue 1E2460|\
        5007 Brilliant blue 3E5F8A|5008 Grey blue 26252D|5009 Azure blue 025669|5010 Gentian blue 0E294B|5011 Steel blue 231A24|5012 Light blue 3B83BD|\
        5013 Cobalt blue 1E213D|5014 Pigeon blue 606E8C|5015 Sky blue 2271B3|5017 Traffic blue 063971|5018 Turquoise blue 3F888F|5019 Capri blue 1B5583|\
        5020 Ocean blue 1D334A|5021 Water blue 256D7B|5022 Night blue 252850|5023 Distant blue 49678D|5024 Pastel blue 5D9B9B|6000 Patina green 316650|\
        6001 Emerald green 287233|6002 Leaf green 2D572C|6003 Olive green 424632|6004 Blue green 1F3A3D|6005 Moss green 2F4538|6006 Grey olive 3E3B32|\
        6007 Bottle green 343B29|6008 Brown green 39352A|6009 Fir green 31372B|6010 Grass green 35682D|6011 Reseda green 587246|6012 Black green 343E40|\
        6013 Reed green 6C7156|6014 Yellow olive 47402E|6015 Black olive 3B3C36|6016 Turquoise green 1E5945|6017 May green 4C9141|6018 Yellow green 57A639|\
        6019 Pastel green BDECB6|6020 Chrome green 2E3A23|6021 Pale green 89AC76|6024 Traffic green 308446|6025 Fern green 3D642D|6026 Opal green 015D52|\
        6027 Light green 84C3BE|6028 Pine green 2C5545|6029 Mint green 20603D|6032 Signal green 317F43|6033 Mint turquoise 497E76|6034 Pastel turquoise 7FB5B5|\
        7000 Squirrel grey 78858B|7001 Silver grey 8A9597|7002 Olive grey 7E7B52|7003 Moss grey 6C7059|7004 Signal grey 969992|7005 Mouse grey 646B63|\
        7006 Beige grey 6D6552|7008 Khaki grey 6A5F31|7009 Green grey 4D5645|7010 Tarpaulin grey 4C514A|7011 Iron grey 434B4D|7012 Basalt grey 4E5754|\
        7013 Brown grey 464531|7015 Slate grey 434750|7016 Anthracite grey 293133|7021 Black grey 23282B|7022 Umbra grey 332F2C|7023 Concrete grey 686C5E|\
        7024 Graphite grey 474A51|7026 Granite grey 2F353B|7030 Stone grey 8B8C7A|7031 Blue grey 474B4E|7032 Pebble grey B8B799|7033 Cement grey 7D8471|\
        7034 Yellow grey 8F8B66|7035 Light grey CBD0CC|7036 Platinum grey 7F7679|7037 Dusty grey 7D7F7D|7038 Agate grey B5B8B1|7039 Quartz grey 6C6960|\
        7040 Window grey 9DA1AA|7042 Traffic grey A 8D948D|7043 Traffic grey B 4E5452|7044 Silk grey CAC4B0|7045 Telegrey 1 909090|7046 Telegrey 2 82898F|\
        7047 Telegrey 4 D0D0D0|8000 Green brown 826C34|8001 Ochre brown 955F20|8002 Signal brown 6C3B2A|8003 Clay brown 734222|8004 Copper brown 8E402A|\
        8007 Fawn brown 59351F|8008 Olive brown 6F4F28|8011 Nut brown 5B3A29|8012 Red brown 592321|8014 Sepia brown 382C1E|8015 Chestnut brown 633A34|\
        8016 Mahogany brown 4C2F27|8017 Chocolate brown 45322E|8019 Grey brown 403A3A|8022 Black brown 212121|8023 Orange brown A65E2E|8024 Beige brown 79553D|\
        8025 Pale brown 755C48|8028 Terra brown 4E3B31|9001 Cream FDF4E3|9002 Grey white E7EBDA|9003 Signal white F4F4F4|9004 Signal black 282828|\
        9005 Jet black 0A0A0A|9006 White aluminium A5A5A5|9007 Grey aluminium 8F8F8F|9010 Pure white FFFFFF|9011 Graphite black 1C1C1C|9016 Traffic white F6F6F6|\
        9017 Traffic black 1E1E1E|9018 Papyrus white D7D7D7
        """
        let pairs: [(String, String)] = s.split(separator: "|").compactMap { e in
            let parts = e.split(separator: " ")
            guard let hex = parts.last else { return nil }
            return ("RAL " + parts.dropLast().joined(separator: " "), String(hex))
        }
        return lib("RAL Classic (approx.)", pairs)
    }()

    /// Names of swatches added from libraries / files (hex → name), for tooltips.
    static var names: [String: String] = [:]

    static func append(_ l: SwatchLibrary, replace: Bool) {
        let app = AppModel.shared
        if replace { app.swatches = [] }
        for c in l.colors { app.swatches.append(c.color); names[c.color.hex] = c.name }
        app.setStatus("Loaded \(l.colors.count) swatches from \(l.name)")
    }

    static func importPanel(replace: Bool = false) {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["aco", "ase", "act"].compactMap { UTType(filenameExtension: $0) }
        p.allowsMultipleSelection = true
        UIBlock.begin(p) { r in
            guard r == .OK else { return }
            for (i, u) in p.urls.enumerated() {
                do { append(try SwatchIO.load(url: u), replace: replace && i == 0) }
                catch { AppActions.alert("Could not import “\(u.lastPathComponent)”.", error.localizedDescription) }
            }
        }
    }

    static func exportPanel() {
        let p = NSSavePanel()
        p.allowedContentTypes = ["aco", "ase"].compactMap { UTType(filenameExtension: $0) }
        p.nameFieldStringValue = "Swatches.ase"
        UIBlock.begin(p) { r in
            guard r == .OK, let u = p.url else { return }
            let colors = AppModel.shared.swatches.enumerated().map { SwatchColor(name: names[$0.element.hex] ?? "Swatch \($0.offset + 1)", color: $0.element) }
            let data = u.pathExtension.lowercased() == "aco" ? SwatchIO.writeACO(colors) : SwatchIO.writeASE(colors, groupName: Brand.name)
            do { try data.write(to: u) } catch { AppActions.alert("Could not export swatches.", error.localizedDescription) }
        }
    }
}

/// Library / import controls shown at the bottom of the Swatches panel.
struct SwatchLibraryControls: View {
    var body: some View {
        WrappingHStack(spacing: 6) {   // (the buttons wrap in a narrow column)
            Menu("Libraries") {
                ForEach(SwatchLibraries.builtIn, id: \.name) { l in
                    Menu(l.name) {
                        Button("Append") { SwatchLibraries.append(l, replace: false) }
                        Button("Replace") { SwatchLibraries.append(l, replace: true) }
                    }
                }
                Divider()
                Button("Reset Swatches") { AppModel.shared.swatches = AppModel.defaultSwatches }
            }
            .menuStyle(.borderlessButton).fixedSize()
            Button("Import Swatches…") { SwatchLibraries.importPanel() }.buttonStyle(PanelButtonStyle())
            Button("Export…") { SwatchLibraries.exportPanel() }.buttonStyle(PanelButtonStyle())
        }
        .font(Theme.font)
    }
}
