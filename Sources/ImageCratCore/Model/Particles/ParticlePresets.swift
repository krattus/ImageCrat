import Foundation

/// Built-in presets. Each builds a tuned `ParticleEffect` for a canvas aspect ratio (width / height); everything
/// stays editable in the editor.
package struct ParticlePreset: Identifiable {
    package let id: String
    package let category: String
    package let name: String
    package let make: (Double) -> ParticleEffect
    package init(id: String, category: String, name: String, make: @escaping (Double) -> ParticleEffect) {
        self.id = id; self.category = category; self.name = name; self.make = make
    }
}

package enum ParticlePresets {
    package static let categories = ["Weather", "Fire & Energy", "Light", "Smoke & Fluids", "Celebration", "Abstract"]

    package static func preset(_ id: String) -> ParticlePreset? { all.first { $0.id == id } }

    package static func effect(_ id: String, aspect: Double) -> ParticleEffect? {
        guard let p = preset(id) else { return nil }
        var e = p.make(aspect)
        e.name = p.name
        e.category = p.category
        return e
    }

    // MARK: Builders

    package typealias S = ParticleSystemSettings

    private static func sys(_ name: String, _ blend: PBlend, _ f: (inout S) -> Void) -> S {
        var s = S()
        s.name = name
        s.blend = blend
        f(&s)
        return s
    }

    private static func fx(time: Double, duration: Double = 4, _ systems: [S], _ f: ((inout ParticleEffect) -> Void)? = nil) -> ParticleEffect {
        var e = ParticleEffect()
        e.systems = systems
        e.time = time
        e.duration = duration
        f?(&e)
        return e
    }

    /// Size (fractions of canvas width / height) of a box measuring `w` × `h` short-side lengths.
    private static func box(_ w: Double, _ h: Double, _ a: Double) -> CGSize {
        a >= 1 ? CGSize(width: w / a, height: h) : CGSize(width: w, height: h * a)
    }

    private static func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
    private static func g(_ stops: String...) -> ColorGradient {
        var out: [GradientStop] = []
        for (i, s) in stops.enumerated() {
            let parts = s.split(separator: "@")
            let loc = parts.count > 1 ? Double(parts[1]) ?? 0 : (stops.count > 1 ? Double(i) / Double(stops.count - 1) : 0)
            out.append(GradientStop(location: loc, color: RGBA(hex: String(parts[0])) ?? .white))
        }
        return ColorGradient(name: "Particles", stops: out)
    }

    // Shared building blocks -------------------------------------------------

    private static func snow(_ name: String, rate: Double, size: (Double, Double), speed: (Double, Double), dir: Double, turb: Double, a: Double) -> S {
        sys(name, .normal) { s in
            s.shape = .line; s.pos = pt(0.5, -0.06); s.size = CGSize(width: 1.7, height: 0)
            s.emission = .rate; s.rate = rate; s.prewarm = true
            s.lifeMin = 12; s.lifeMax = 15
            s.direction = dir; s.spread = 14; s.speedMin = speed.0; s.speedMax = speed.1
            s.turbulence = turb; s.turbulenceScale = 320; s.turbulenceSpeed = 0.25
            s.sprite = .softDisc; s.spriteSoftness = 0.75
            s.sizeMin = size.0; s.sizeMax = size.1; s.sizeBias = 1.6
            s.rotationRandom = 180
            s.opacity = 1; s.opacityRandom = 0.2; s.opacityCurve = .pts((0, 1), (0.95, 1), (1, 0))
            s.depth = 0.55; s.focus = 0.62; s.dofBlur = 0.35; s.atmosphere = 0.25
        }
    }

    private static func rain(_ name: String, rate: Double, len: (Double, Double), speed: (Double, Double), dir: Double, opacity: Double) -> S {
        sys(name, .normal) { s in
            s.shape = .line; s.pos = pt(0.5 + cos(dir * .pi / 180) * -0.6, -0.08); s.size = CGSize(width: 2.2, height: 0)
            s.emission = .rate; s.rate = rate; s.prewarm = true
            s.lifeMin = 1.6; s.lifeMax = 1.6
            s.direction = dir; s.spread = 2.5; s.speedMin = speed.0; s.speedMax = speed.1
            s.sprite = .raindrop; s.spriteAspect = 0.06; s.alignToVelocity = true
            s.sizeMin = len.0; s.sizeMax = len.1
            s.gradient = g("DCEBFF", "C4DAF5")
            s.opacity = opacity; s.opacityRandom = 0.5; s.opacityCurve = .flat
            s.depth = 0.5; s.atmosphere = 0.5; s.focus = 0.4; s.dofBlur = 0.12
        }
    }

    private static func shell(_ name: String, interval: Double, start: Double, palette: ColorGradient, width: Double, child: S) -> S {
        sys(name, .additive) { s in
            s.shape = .line; s.pos = pt(0.5, 1.02); s.size = CGSize(width: width, height: 0)
            s.emission = .burst; s.count = 1; s.burstInterval = interval; s.startTime = start; s.prewarm = true
            s.lifeMin = 1.05; s.lifeMax = 1.45
            s.direction = 90; s.spread = 24; s.speedMin = 700; s.speedMax = 940; s.gravity = 470
            s.sprite = .ember; s.sizeMin = 5; s.sizeMax = 7
            s.colorBase = .palette; s.palette = palette
            s.gradient = g("FFE9B0", "FFC46B")
            s.opacity = 0.75; s.opacityCurve = .pts((0, 1), (0.8, 0.8), (1, 0.2))
            s.trail = .ribbon; s.trailLength = 0.28; s.trailSegments = 10; s.trailWidth = 0.7
            s.sub = [child]
        }
    }

    private static func burstChild(count: Double, speed: (Double, Double), life: (Double, Double), gravity: Double, drag: Double, f: ((inout S) -> Void)? = nil) -> S {
        sys("Burst", .additive) { c in
            c.count = count; c.spread = 360; c.speedMin = speed.0; c.speedMax = speed.1
            c.lifeMin = life.0; c.lifeMax = life.1; c.gravity = gravity; c.drag = drag
            c.colorBase = .parent
            c.gradient = g("FFFFFF", "FFFFFF@0.55", "FFFFFF00@1")
            c.sprite = .ember; c.sizeMin = 7; c.sizeMax = 11
            c.opacityCurve = .pts((0, 1), (0.6, 0.9), (1, 0))
            c.trail = .ribbon; c.trailLength = 0.22; c.trailSegments = 8; c.trailWidth = 0.55
            c.twinkle = 0.35; c.twinkleSpeed = 9
            c.inheritVelocity = 0.15
            f?(&c)
        }
    }

    private static let festive = g("FF3B30", "FF9500", "FFCC00", "34C759", "5AC8FA", "007AFF", "AF52DE", "FF2D55")

    // MARK: Catalogue

    package static let all: [ParticlePreset] = weather + fire + light + smoke + celebration + abstract

    // MARK: Weather

    package static let weather: [ParticlePreset] = [
        ParticlePreset(id: "snow.light", category: "Weather", name: "Snow – Light") { a in
            var crystals = snow("Snow crystals", rate: 5, size: (26, 44), speed: (95, 130), dir: 268, turb: 30, a: a)
            crystals.sprite = .snowflake; crystals.spinRandom = 40; crystals.depth = 0.25; crystals.dofBlur = 0.1; crystals.atmosphere = 0; crystals.opacity = 0.95
            return fx(time: 4, duration: 6, [snow("Snow", rate: 55, size: (7, 15), speed: (90, 135), dir: 268, turb: 28, a: a), crystals])
        },
        ParticlePreset(id: "snow.heavy", category: "Weather", name: "Snow – Heavy") { a in
            fx(time: 4, duration: 6, [
                snow("Far snow", rate: 330, size: (5, 11), speed: (100, 170), dir: 262, turb: 40, a: a),
                snow("Near flakes", rate: 40, size: (14, 26), speed: (130, 210), dir: 260, turb: 55, a: a),
            ])
        },
        ParticlePreset(id: "snow.blizzard", category: "Weather", name: "Snow – Blizzard") { a in
            fx(time: 4, duration: 4, [
                sys("Haze", .normal) { s in
                    s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.5, height: 1.2)
                    s.rate = 22; s.lifeMin = 3; s.lifeMax = 5
                    s.direction = 196; s.spread = 10; s.speedMin = 260; s.speedMax = 420
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.spriteAspect = 0.6; s.sizeMin = 700; s.sizeMax = 1300; s.rotation = 16; s.rotationRandom = 6
                    s.gradient = g("F2F6FA", "F2F6FA"); s.opacity = 0.16; s.opacityCurve = .fadeInOut
                    s.turbulence = 60
                },
                sys("Driven snow", .normal) { s in
                    s.shape = .rectangle; s.pos = pt(0.85, 0.35); s.size = CGSize(width: 1.9, height: 1.7)
                    s.rate = 2400; s.lifeMin = 1.1; s.lifeMax = 2.0
                    s.direction = 198; s.spread = 16; s.speedMin = 520; s.speedMax = 900
                    s.turbulence = 170; s.turbulenceScale = 260; s.turbulenceSpeed = 0.6
                    s.sprite = .softDisc; s.spriteSoftness = 0.7; s.sizeMin = 4; s.sizeMax = 11; s.sizeBias = 1.8
                    s.trail = .stretch; s.trailLength = 0.02
                    s.opacity = 1; s.opacityRandom = 0.3; s.opacityCurve = .fadeInOut
                    s.depth = 0.6; s.focus = 0.6; s.dofBlur = 0.4; s.atmosphere = 0.25
                },
            ])
        },
        ParticlePreset(id: "rain.drizzle", category: "Weather", name: "Rain – Drizzle") { a in
            fx(time: 3, [rain("Drizzle", rate: 900, len: (34, 64), speed: (850, 1100), dir: 264, opacity: 0.85)])
        },
        ParticlePreset(id: "rain.downpour", category: "Weather", name: "Rain – Downpour") { a in
            fx(time: 3, [
                rain("Far rain", rate: 1700, len: (34, 66), speed: (1100, 1400), dir: 260, opacity: 0.45),
                rain("Near rain", rate: 460, len: (90, 160), speed: (1700, 2100), dir: 259, opacity: 0.7),
            ])
        },
        ParticlePreset(id: "rain.storm", category: "Weather", name: "Rain – Storm with Splashes") { a in
            var r = rain("Storm rain", rate: 1400, len: (80, 150), speed: (1700, 2300), dir: 247, opacity: 0.62)
            r.floorEnabled = true; r.floorY = 0.93; r.dieOnCollision = true; r.depth = 0; r.atmosphere = 0; r.dofBlur = 0
            r.lifeMin = 1.4; r.lifeMax = 1.4
            r.sub = [sys("Splash", .normal) { c in
                c.count = 5; c.direction = 90; c.spread = 130; c.speedMin = 90; c.speedMax = 300; c.gravity = 1100
                c.lifeMin = 0.14; c.lifeMax = 0.32
                c.sprite = .softDisc; c.spriteSoftness = 0.5; c.sizeMin = 2.5; c.sizeMax = 5
                c.gradient = g("E6F1FF", "E6F1FF"); c.opacity = 0.7; c.opacityCurve = .fadeOut
                c.trail = .stretch; c.trailLength = 0.02
            }]
            return fx(time: 3, [
                sys("Mist", .normal) { s in
                    s.shape = .rectangle; s.pos = pt(0.5, 0.9); s.size = CGSize(width: 1.5, height: 0.22)
                    s.rate = 7; s.lifeMin = 3; s.lifeMax = 5; s.direction = 180; s.spread = 20; s.speedMin = 60; s.speedMax = 140
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.spriteAspect = 0.5; s.sizeMin = 420; s.sizeMax = 800; s.rotationRandom = 8
                    s.gradient = g("D5E0EC", "D5E0EC"); s.opacity = 0.2; s.opacityCurve = .fadeInOut
                },
                rain("Far rain", rate: 1700, len: (34, 66), speed: (1200, 1500), dir: 250, opacity: 0.4),
                r,
            ])
        },
        ParticlePreset(id: "hail", category: "Weather", name: "Hail") { a in
            fx(time: 3, [sys("Hail", .normal) { s in
                s.shape = .line; s.pos = pt(0.6, -0.06); s.size = CGSize(width: 1.8, height: 0)
                s.rate = 170; s.lifeMin = 2.2; s.lifeMax = 2.8
                s.direction = 258; s.spread = 6; s.speedMin = 900; s.speedMax = 1300; s.gravity = 1400
                s.floorEnabled = true; s.floorY = 0.94; s.restitution = 0.42; s.friction = 0.25
                s.sprite = .softDisc; s.spriteSoftness = 0.3; s.sizeMin = 5; s.sizeMax = 11
                s.gradient = g("FFFFFF", "E4EEF8"); s.opacity = 0.95; s.opacityCurve = .pts((0, 1), (0.85, 1), (1, 0))
                s.trail = .stretch; s.trailLength = 0.006
            }])
        },
        ParticlePreset(id: "fog", category: "Weather", name: "Fog / Mist Drift") { a in
            fx(time: 6, duration: 8, [sys("Fog", .normal) { s in
                s.shape = .rectangle; s.pos = pt(0.5, 0.62); s.size = CGSize(width: 1.5, height: 0.8)
                s.rate = 7; s.lifeMin = 9; s.lifeMax = 14
                s.direction = 0; s.spread = 20; s.speedMin = 10; s.speedMax = 34
                s.turbulence = 14; s.turbulenceScale = 500
                s.sprite = .smoke; s.sizeMin = 520; s.sizeMax = 980; s.rotationRandom = 180; s.spinRandom = 4
                s.gradient = g("EEF2F5", "EEF2F5"); s.opacity = 0.2; s.opacityRandom = 0.4; s.opacityCurve = .pts((0, 0), (0.25, 1), (0.7, 1), (1, 0))
            }])
        },
        ParticlePreset(id: "leaves", category: "Weather", name: "Falling Leaves") { a in
            fx(time: 6, duration: 8, [sys("Leaves", .normal) { s in
                s.shape = .line; s.pos = pt(0.45, -0.08); s.size = CGSize(width: 1.7, height: 0)
                s.rate = 11; s.lifeMin = 10; s.lifeMax = 12
                s.direction = 280; s.spread = 30; s.speedMin = 115; s.speedMax = 180; s.gravity = 6
                s.turbulence = 85; s.turbulenceScale = 330; s.turbulenceSpeed = 0.3
                s.sprite = .leaf; s.sizeMin = 34; s.sizeMax = 66; s.spriteAspect = 1
                s.rotationRandom = 180; s.spinRandom = 90; s.tumble = 0.35
                s.colorBase = .palette; s.palette = g("C0561B", "E2A12B", "8C3B12", "D9731C", "B5451B", "E8B84A")
                s.brightnessVariation = 0.2
                s.opacity = 1; s.opacityCurve = .pts((0, 1), (0.92, 1), (1, 0))
                s.depth = 0.3; s.focus = 0.55; s.dofBlur = 0.3
            }])
        },
        ParticlePreset(id: "petals", category: "Weather", name: "Petals") { a in
            fx(time: 6, duration: 8, [sys("Petals", .normal) { s in
                s.shape = .line; s.pos = pt(0.35, -0.06); s.size = CGSize(width: 1.8, height: 0)
                s.rate = 26; s.lifeMin = 11; s.lifeMax = 13
                s.direction = 290; s.spread = 30; s.speedMin = 100; s.speedMax = 150
                s.turbulence = 75; s.turbulenceScale = 300; s.turbulenceSpeed = 0.3; s.wind = 3
                s.sprite = .petal; s.sizeMin = 18; s.sizeMax = 36
                s.rotationRandom = 180; s.spinRandom = 120; s.tumble = 0.45
                s.colorBase = .palette; s.palette = g("FFD1DC", "FFB7C5", "FFF0F5", "F8A5C2", "FFC9DE")
                s.opacity = 0.97; s.opacityCurve = .pts((0, 1), (0.92, 1), (1, 0))
                s.depth = 0.35; s.focus = 0.55; s.dofBlur = 0.35
            }])
        },
        ParticlePreset(id: "dust.motes", category: "Weather", name: "Dust Motes") { a in
            fx(time: 5, duration: 8, [sys("Motes", .additive) { s in
                s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.1, height: 1.1)
                s.rate = 110; s.lifeMin = 5; s.lifeMax = 9
                s.spread = 360; s.speedMin = 3; s.speedMax = 16
                s.turbulence = 14; s.turbulenceScale = 260; s.turbulenceSpeed = 0.2
                s.sprite = .dust; s.sizeMin = 8; s.sizeMax = 24; s.sizeBias = 2
                s.gradient = g("FFF3D6", "FFEFC4"); s.opacity = 1; s.opacityRandom = 0.4; s.opacityCurve = .fadeInOut
                s.twinkle = 0.5; s.twinkleSpeed = 0.5
                s.depth = 0.6; s.focus = 0.6; s.dofBlur = 0.8
            }])
        },
        ParticlePreset(id: "sandstorm", category: "Weather", name: "Sand Storm") { a in
            fx(time: 3, [
                sys("Dust cloud", .normal) { s in
                    s.shape = .rectangle; s.pos = pt(0.4, 0.6); s.size = CGSize(width: 1.8, height: 1.0)
                    s.rate = 16; s.lifeMin = 2.5; s.lifeMax = 4; s.direction = 4; s.spread = 12; s.speedMin = 260; s.speedMax = 480
                    s.turbulence = 90
                    s.sprite = .smoke; s.sizeMin = 420; s.sizeMax = 860; s.rotationRandom = 180
                    s.gradient = g("D2A86A", "C79A58"); s.opacity = 0.3; s.opacityCurve = .fadeInOut
                },
                sys("Grains", .normal) { s in
                    s.shape = .rectangle; s.pos = pt(0.2, 0.55); s.size = CGSize(width: 1.9, height: 1.3)
                    s.rate = 3200; s.lifeMin = 0.9; s.lifeMax = 1.7
                    s.direction = 3; s.spread = 14; s.speedMin = 700; s.speedMax = 1300
                    s.turbulence = 190; s.turbulenceScale = 220; s.turbulenceSpeed = 0.7
                    s.sprite = .softDisc; s.spriteSoftness = 0.5; s.sizeMin = 1.6; s.sizeMax = 4.5; s.sizeBias = 1.6
                    s.trail = .stretch; s.trailLength = 0.02
                    s.colorBase = .palette; s.palette = g("E8C890", "D9B37A", "C49A5A", "F2DDB0")
                    s.opacity = 0.7; s.opacityRandom = 0.5; s.opacityCurve = .fadeInOut
                    s.depth = 0.4; s.atmosphere = 0.4
                },
            ])
        },
    ]

    // MARK: Fire & Energy

    package static let fire: [ParticlePreset] = [
        ParticlePreset(id: "fire", category: "Fire & Energy", name: "Fire") { a in
            let pull = [PAttractor(pos: pt(0.5, 0.25), strength: 560, radius: 320)]
            return fx(time: 3, [
                sys("Smoke", .normal) { s in
                    s.shape = .line; s.pos = pt(0.5, 0.56); s.size = box(0.16, 0, a)
                    s.rate = 13; s.lifeMin = 2.4; s.lifeMax = 3.6
                    s.direction = 90; s.spread = 24; s.speedMin = 110; s.speedMax = 190; s.gravity = -30
                    s.turbulence = 60; s.turbulenceScale = 200
                    s.sprite = .smoke; s.sizeMin = 190; s.sizeMax = 330; s.sizeCurve = .pts((0, 0.35), (1, 1)); s.rotationRandom = 180; s.spinRandom = 20
                    s.gradient = g("2C2622", "201D1B"); s.brightnessVariation = 0.3; s.opacity = 0.5; s.opacityCurve = .pts((0, 0), (0.25, 1), (0.6, 0.7), (1, 0))
                },
                sys("Glow", .additive) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.8); s.emission = .burst; s.count = 2; s.immortal = true; s.lifeMin = 0.25; s.lifeMax = 0.5
                    s.speedMin = 0; s.speedMax = 0
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.sizeMin = 560; s.sizeMax = 760
                    s.gradient = g("FF7A1A", "FF5A10"); s.opacity = 0.13; s.opacityCurve = .pts((0, 0.7), (0.5, 1), (1, 0.7))
                },
                sys("Flame body", .additive) { s in
                    s.shape = .circle; s.pos = pt(0.5, 0.86); s.size = box(0.2, 0.05, a)
                    s.rate = 200; s.lifeMin = 0.65; s.lifeMax = 1.3
                    s.direction = 90; s.spread = 20; s.speedMin = 250; s.speedMax = 470; s.gravity = -140
                    s.turbulence = 95; s.turbulenceScale = 120; s.turbulenceSpeed = 1
                    s.attractors = pull
                    s.sprite = .smoke; s.sizeMin = 95; s.sizeMax = 175; s.sizeCurve = .pts((0, 0.7), (0.3, 1), (1, 0.15)); s.rotationRandom = 180; s.spinRandom = 60
                    s.gradient = g("FFE9A0@0", "FFB838@0.2", "FF7A14@0.45", "C2260A@0.75", "3A0A00@1")
                    s.opacity = 0.25; s.opacityCurve = .pts((0, 0), (0.3, 1), (0.65, 0.85), (1, 0))
                },
                sys("Flame tongues", .additive) { s in
                    s.shape = .circle; s.pos = pt(0.5, 0.86); s.size = box(0.17, 0.04, a)
                    s.rate = 65; s.lifeMin = 0.5; s.lifeMax = 0.95
                    s.direction = 90; s.spread = 18; s.speedMin = 280; s.speedMax = 520; s.gravity = -170
                    s.turbulence = 75; s.turbulenceScale = 120; s.turbulenceSpeed = 1
                    s.attractors = pull
                    s.sprite = .flame; s.alignToVelocity = true; s.rotation = -90; s.spriteAspect = 0.7
                    s.sizeMin = 120; s.sizeMax = 210; s.sizeCurve = .pts((0, 0.6), (0.35, 1), (1, 0.3))
                    s.gradient = g("FFE9A6@0", "FF9A22@0.4", "D6360F@0.8", "5A0E00@1")
                    s.opacity = 0.36; s.opacityCurve = .pts((0, 0), (0.2, 1), (0.6, 0.8), (1, 0))
                },
                sys("Hot core", .additive) { s in
                    s.shape = .circle; s.pos = pt(0.5, 0.86); s.size = box(0.1, 0.03, a)
                    s.rate = 40; s.lifeMin = 0.3; s.lifeMax = 0.55
                    s.direction = 90; s.spread = 16; s.speedMin = 140; s.speedMax = 260
                    s.turbulence = 60; s.turbulenceScale = 90; s.turbulenceSpeed = 1.2
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.sizeMin = 80; s.sizeMax = 130; s.sizeCurve = .pts((0, 1), (1, 0.2))
                    s.gradient = g("FFF8DC", "FFD468"); s.opacity = 0.12; s.opacityCurve = .pts((0, 0), (0.2, 1), (1, 0))
                },
                sys("Embers", .additive) { s in
                    s.shape = .line; s.pos = pt(0.5, 0.78); s.size = box(0.18, 0, a)
                    s.rate = 50; s.lifeMin = 1; s.lifeMax = 2.4
                    s.direction = 90; s.spread = 34; s.speedMin = 240; s.speedMax = 480; s.gravity = -40
                    s.turbulence = 170; s.turbulenceScale = 150; s.turbulenceSpeed = 0.8
                    s.sprite = .ember; s.sizeMin = 5; s.sizeMax = 11; s.sizeCurve = .shrink
                    s.gradient = g("FFE08A", "FF8A1E@0.5", "D6360F@1"); s.opacityCurve = .pts((0, 1), (0.7, 1), (1, 0))
                    s.twinkle = 0.5; s.twinkleSpeed = 6; s.trail = .stretch; s.trailLength = 0.025
                },
            ])
        },
        ParticlePreset(id: "embers", category: "Fire & Energy", name: "Campfire Embers") { a in
            fx(time: 4, duration: 6, [
                sys("Glow", .additive) { s in
                    s.shape = .line; s.pos = pt(0.5, 1.05); s.size = CGSize(width: 0.25, height: 0)
                    s.emission = .burst; s.count = 5; s.immortal = true; s.lifeMin = 1.5; s.lifeMax = 3; s.speedMin = 0; s.speedMax = 0
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.spriteAspect = 0.6; s.sizeMin = 1100; s.sizeMax = 1600; s.rotationRandom = 0
                    s.gradient = g("FF7A1A", "E0481A"); s.opacity = 0.22; s.opacityCurve = .pts((0, 0.7), (0.5, 1), (1, 0.7))
                },
                sys("Embers", .additive) { s in
                    s.shape = .line; s.pos = pt(0.5, 1.02); s.size = CGSize(width: 0.55, height: 0)
                    s.rate = 210; s.lifeMin = 2.2; s.lifeMax = 4.5
                    s.direction = 90; s.spread = 40; s.speedMin = 150; s.speedMax = 380; s.gravity = -25; s.wind = 12
                    s.turbulence = 190; s.turbulenceScale = 190; s.turbulenceSpeed = 0.6
                    s.sprite = .ember; s.sizeMin = 9; s.sizeMax = 22; s.sizeBias = 1.8; s.sizeCurve = .pts((0, 1), (0.7, 0.8), (1, 0.3))
                    s.gradient = g("FFE9A0@0", "FFA22E@0.35", "F0501A@0.75", "A01808@1")
                    s.opacityCurve = .pts((0, 0), (0.05, 1), (0.7, 0.9), (1, 0))
                    s.twinkle = 0.65; s.twinkleSpeed = 5; s.trail = .stretch; s.trailLength = 0.035
                    s.depth = 0.4; s.focus = 0.55; s.dofBlur = 0.7
                },
            ])
        },
        ParticlePreset(id: "sparks.welding", category: "Fire & Energy", name: "Sparks – Welding") { a in
            fx(time: 2, [
                sys("Arc glow", .additive) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.62)
                    s.emission = .burst; s.count = 3; s.immortal = true; s.lifeMin = 0.12; s.lifeMax = 0.2
                    s.speedMin = 0; s.speedMax = 0
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.sizeMin = 240; s.sizeMax = 420
                    s.gradient = g("CFE4FF", "9FC4FF"); s.opacity = 0.6; s.opacityCurve = .pts((0, 0.6), (0.5, 1), (1, 0.6))
                },
                sys("Arc", .additive) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.62)
                    s.emission = .burst; s.count = 1; s.immortal = true; s.speedMin = 0; s.speedMax = 0
                    s.sprite = .sparkle; s.spritePoints = 8; s.sizeMin = 300; s.sizeMax = 300; s.rotationRandom = 0; s.rotation = 12
                    s.gradient = g("FFFFFF", "EAF2FF"); s.opacityCurve = .flat
                },
                sys("Sparks", .additive) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.62)
                    s.rate = 900; s.lifeMin = 0.35; s.lifeMax = 1.0
                    s.direction = 75; s.spread = 150; s.speedMin = 350; s.speedMax = 1400; s.gravity = 1500; s.drag = 0.9
                    s.floorEnabled = true; s.floorY = 0.9; s.restitution = 0.4; s.friction = 0.3
                    s.sprite = .softDisc; s.sizeMin = 2.5; s.sizeMax = 5
                    s.gradient = g("FFFFFF@0", "FFE88A@0.2", "FF9A2E@0.6", "D6360F@1")
                    s.opacityCurve = .pts((0, 1), (0.7, 0.9), (1, 0))
                    s.trail = .streak; s.trailLength = 0.06; s.trailWidth = 0.9
                },
            ])
        },
        ParticlePreset(id: "sparks.grinder", category: "Fire & Energy", name: "Sparks – Grinder") { a in
            fx(time: 2, [
                sys("Contact glow", .additive) { s in
                    s.shape = .point; s.pos = pt(0.72, 0.5); s.emission = .burst; s.count = 2; s.immortal = true
                    s.speedMin = 0; s.speedMax = 0
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.sizeMin = 120; s.sizeMax = 200
                    s.gradient = g("FFD890", "FFB040"); s.opacity = 0.7; s.opacityCurve = .flat
                },
                sys("Sparks", .additive) { s in
                    s.shape = .point; s.pos = pt(0.72, 0.5)
                    s.rate = 2200; s.lifeMin = 0.3; s.lifeMax = 0.85
                    s.direction = 196; s.spread = 26; s.speedMin = 800; s.speedMax = 1900; s.gravity = 1000; s.drag = 0.8
                    s.floorEnabled = true; s.floorY = 0.9; s.restitution = 0.35; s.friction = 0.2
                    s.sprite = .softDisc; s.sizeMin = 2; s.sizeMax = 4.5
                    s.gradient = g("FFFFFF@0", "FFE27A@0.15", "FF9A2E@0.55", "E0481A@1")
                    s.opacityCurve = .pts((0, 1), (0.6, 0.9), (1, 0))
                    s.trail = .streak; s.trailLength = 0.07; s.trailWidth = 0.85
                },
            ])
        },
        ParticlePreset(id: "explosion", category: "Fire & Energy", name: "Explosion") { a in
            fx(time: 0.5, duration: 3, [
                sys("Smoke", .normal) { s in
                    s.shape = .circle; s.pos = pt(0.5, 0.55); s.size = box(0.1, 0.1, a)
                    s.emission = .burst; s.count = 90; s.lifeMin = 2.2; s.lifeMax = 3.6
                    s.spread = 360; s.speedMin = 0; s.speedMax = 60; s.radialSpeed = 700; s.drag = 2.6; s.gravity = -40
                    s.turbulence = 40
                    s.sprite = .smoke; s.sizeMin = 230; s.sizeMax = 400; s.sizeCurve = .pts((0, 0.3), (0.3, 0.8), (1, 1)); s.rotationRandom = 180; s.spinRandom = 30
                    s.gradient = g("6A3410@0", "3A2C24@0.25", "2A2826@1"); s.opacity = 0.6; s.opacityCurve = .pts((0, 0), (0.06, 1), (0.5, 0.75), (1, 0))
                },
                sys("Fireball", .additive) { s in
                    s.shape = .circle; s.pos = pt(0.5, 0.55); s.size = box(0.06, 0.06, a)
                    s.emission = .burst; s.count = 170; s.lifeMin = 0.6; s.lifeMax = 1.5
                    s.spread = 360; s.speedMin = 0; s.speedMax = 80; s.radialSpeed = 560; s.drag = 3.2
                    s.turbulence = 60; s.turbulenceScale = 120
                    s.sprite = .smoke; s.sizeMin = 110; s.sizeMax = 250; s.sizeCurve = .pts((0, 0.35), (0.25, 1), (1, 0.7)); s.rotationRandom = 180
                    s.gradient = g("FFF6D0@0", "FFC040@0.15", "FF6A12@0.4", "B8200A@0.7", "300800@1")
                    s.opacity = 0.3; s.opacityCurve = .pts((0, 1), (0.5, 0.85), (1, 0))
                },
                sys("Sparks", .additive) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.55)
                    s.emission = .burst; s.count = 320; s.lifeMin = 0.7; s.lifeMax = 1.8
                    s.spread = 360; s.speedMin = 400; s.speedMax = 1700; s.drag = 1.3; s.gravity = 520
                    s.sprite = .softDisc; s.sizeMin = 2.5; s.sizeMax = 5.5
                    s.gradient = g("FFF4C4@0", "FFB03A@0.4", "E0481A@1"); s.opacityCurve = .pts((0, 1), (0.7, 0.9), (1, 0))
                    s.trail = .streak; s.trailLength = 0.06
                },
                sys("Debris", .normal) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.55)
                    s.emission = .burst; s.count = 46; s.lifeMin = 2; s.lifeMax = 3
                    s.direction = 90; s.spread = 260; s.speedMin = 300; s.speedMax = 1000; s.drag = 0.6; s.gravity = 900
                    s.sprite = .confettiTriangle; s.sizeMin = 6; s.sizeMax = 16; s.spinRandom = 500; s.tumble = 1.5
                    s.gradient = g("1E1A18", "2A2420"); s.opacityCurve = .pts((0, 1), (0.85, 1), (1, 0))
                },
                sys("Flash", .additive) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.55)
                    s.emission = .burst; s.count = 1; s.lifeMin = 0.9; s.lifeMax = 0.9; s.speedMin = 0; s.speedMax = 0
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.sizeMin = 560; s.sizeMax = 560; s.sizeCurve = .pts((0, 0.5), (0.2, 1), (1, 0.8))
                    s.gradient = g("FFFFFF@0", "FFD890@0.3", "FF8A30@1"); s.opacity = 0.75; s.opacityCurve = .pts((0, 1), (0.3, 0.45), (1, 0))
                },
            ])
        },
        ParticlePreset(id: "fireworks.peony", category: "Fire & Energy", name: "Fireworks – Peony") { a in
            fx(time: 3.2, duration: 6, [
                shell("Shells", interval: 0.62, start: 0, palette: g("FF3B5C", "FFD23F", "3BE8B0", "4DA3FF", "C77DFF", "FF8A3D"), width: 0.75,
                      child: burstChild(count: 220, speed: (60, 470), life: (1.3, 2.0), gravity: 150, drag: 1.7)),
            ])
        },
        ParticlePreset(id: "fireworks.willow", category: "Fire & Energy", name: "Fireworks – Willow") { a in
            fx(time: 3.6, duration: 7, [
                shell("Shells", interval: 1.05, start: 0.2, palette: g("FFD27A", "FFC04A", "FFE2A0"), width: 0.6,
                      child: burstChild(count: 110, speed: (150, 420), life: (2.4, 3.3), gravity: 230, drag: 1.25) { c in
                          c.trail = .ribbon; c.trailLength = 1.0; c.trailSegments = 22; c.trailWidth = 0.75
                          c.gradient = g("FFF1C8@0", "FFC862@0.3", "D88A1E@0.8", "8A4A0800@1")
                          c.sizeMin = 3.5; c.sizeMax = 5.5; c.twinkle = 0.5; c.twinkleSpeed = 12
                      }),
            ])
        },
        ParticlePreset(id: "fireworks.ring", category: "Fire & Energy", name: "Fireworks – Ring & Crackle") { a in
            let crackle = sys("Crackle", .additive) { c in
                c.count = 4; c.spread = 360; c.speedMin = 20; c.speedMax = 90; c.lifeMin = 0.25; c.lifeMax = 0.7; c.gravity = 120; c.burstSpread = 0.35
                c.sprite = .sparkle; c.sizeMin = 8; c.sizeMax = 20
                c.gradient = g("FFFFFF", "FFF2C0"); c.opacityCurve = .pts((0, 1), (0.5, 1), (1, 0)); c.twinkle = 0.9; c.twinkleSpeed = 18
            }
            return fx(time: 3.4, duration: 6, [
                shell("Ring shells", interval: 0.8, start: 0, palette: g("FF4D6D", "4DD2FF", "B5FF4D", "FFB84D", "D24DFF"), width: 0.7,
                      child: burstChild(count: 150, speed: (335, 350), life: (1.3, 1.6), gravity: 110, drag: 1.5) { c in
                          c.sub = [crackle]; c.trailLength = 0.1; c.trailSegments = 5
                      }),
                shell("Inner shells", interval: 0.8, start: 0.4, palette: g("FFFFFF", "FFE9A8"), width: 0.7,
                      child: burstChild(count: 90, speed: (40, 180), life: (0.9, 1.4), gravity: 130, drag: 1.8)),
            ])
        },
        ParticlePreset(id: "fireworks.finale", category: "Fire & Energy", name: "Fireworks – Grand Finale") { a in
            fx(time: 3.4, duration: 6, [
                shell("Gold willows", interval: 0.9, start: 0.1, palette: g("FFD27A", "FFC04A"), width: 0.9,
                      child: burstChild(count: 90, speed: (150, 400), life: (2.0, 2.8), gravity: 230, drag: 1.3) { c in
                          c.trail = .ribbon; c.trailLength = 0.8; c.trailSegments = 18; c.trailWidth = 0.7
                          c.gradient = g("FFF1C8@0", "FFC862@0.3", "D88A1E@0.8", "8A4A0800@1")
                      }),
                shell("Peonies", interval: 0.34, start: 0, palette: g("FF3B5C", "FFD23F", "3BE8B0", "4DA3FF", "C77DFF", "FF8A3D", "FFFFFF"), width: 0.95,
                      child: burstChild(count: 190, speed: (60, 440), life: (1.2, 1.9), gravity: 150, drag: 1.7)),
                shell("Rings", interval: 0.7, start: 0.25, palette: g("4DD2FF", "B5FF4D", "FF4DA6"), width: 0.8,
                      child: burstChild(count: 120, speed: (300, 312), life: (1.1, 1.5), gravity: 110, drag: 1.5)),
            ])
        },
        ParticlePreset(id: "lightning", category: "Fire & Energy", name: "Lightning Sparks") { a in
            func arcs(_ name: String, count: Double, speed: (Double, Double), life: (Double, Double), width: Double, force: Double, opacity: Double) -> S {
                sys(name, .additive) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.5)
                    s.emission = .burst; s.count = count; s.burstInterval = 0.5; s.prewarm = true
                    s.lifeMin = life.0; s.lifeMax = life.1
                    s.spread = 360; s.speedMin = speed.0; s.speedMax = speed.1; s.drag = 1.5
                    // a very fine noise scale makes every step an independent kick: jagged, electric paths
                    s.noiseForce = force; s.turbulenceScale = 6; s.turbulenceSpeed = 8
                    s.sprite = .softDisc; s.spriteSoftness = 0.9; s.sizeMin = width; s.sizeMax = width * 1.4
                    s.gradient = g("FFFFFF", "CFE0FF"); s.opacity = opacity; s.opacityCurve = .pts((0, 1), (0.75, 1), (1, 0))
                    s.trail = .ribbon; s.trailLength = life.1 * 1.1; s.trailSegments = 44; s.trailWidth = 1
                }
            }
            return fx(time: 0.22, duration: 1, [
                sys("Core", .additive) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.5); s.emission = .burst; s.count = 2; s.immortal = true; s.speedMin = 0; s.speedMax = 0
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.sizeMin = 220; s.sizeMax = 380
                    s.gradient = g("DDE8FF", "8FB4FF"); s.opacity = 0.8; s.opacityCurve = .flat
                },
                arcs("Main arcs", count: 10, speed: (1400, 2500), life: (0.3, 0.36), width: 6, force: 70000, opacity: 1),
                arcs("Fine arcs", count: 30, speed: (700, 1900), life: (0.24, 0.34), width: 3, force: 90000, opacity: 0.8),
                sys("Sparks", .additive) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.5); s.emission = .burst; s.count = 90; s.burstInterval = 0.5; s.prewarm = true
                    s.lifeMin = 0.2; s.lifeMax = 0.5; s.spread = 360; s.speedMin = 300; s.speedMax = 1500; s.drag = 2; s.gravity = 300
                    s.sprite = .softDisc; s.sizeMin = 2.5; s.sizeMax = 4.5
                    s.gradient = g("FFFFFF", "9FC0FF"); s.opacityCurve = .fadeOut; s.trail = .streak; s.trailLength = 0.04
                },
            ])
        },
        ParticlePreset(id: "magic", category: "Fire & Energy", name: "Magic Sparkles / Fairy Dust") { a in
            let curve: [CGPoint] = (0...40).map { i in
                let t = Double(i) / 40
                return pt(0.12 + 0.76 * t, 0.5 + 0.26 * sin(t * 2 * .pi) * (1 - 0.3 * t))
            }
            return fx(time: 3, duration: 5, [
                sys("Dust", .additive) { s in
                    s.shape = .path; s.pathPoints = curve
                    s.rate = 1500; s.lifeMin = 0.8; s.lifeMax = 2.4
                    s.spread = 360; s.speedMin = 4; s.speedMax = 85; s.gravity = 55; s.drag = 0.8
                    s.turbulence = 40; s.turbulenceScale = 140
                    s.sprite = .ember; s.sizeMin = 5; s.sizeMax = 16; s.sizeBias = 2
                    s.colorBase = .palette; s.palette = g("FFF7C2", "FFD86B", "FFB3E6", "FFFFFF", "BFE3FF")
                    s.opacity = 0.9; s.opacityCurve = .quickInSlowOut; s.twinkle = 0.7; s.twinkleSpeed = 6
                },
                sys("Sparkles", .additive) { s in
                    s.shape = .path; s.pathPoints = curve
                    s.rate = 150; s.lifeMin = 0.6; s.lifeMax = 1.6
                    s.spread = 360; s.speedMin = 4; s.speedMax = 60; s.gravity = 35
                    s.sprite = .sparkle; s.spritePoints = 4; s.sizeMin = 22; s.sizeMax = 90; s.sizeBias = 2.2
                    s.sizeCurve = .pts((0, 0.2), (0.3, 1), (1, 0.1)); s.rotationRandom = 20; s.spinRandom = 40
                    s.colorBase = .palette; s.palette = g("FFF7C2", "FFE08A", "FFC6EE", "FFFFFF")
                    s.opacityCurve = .pts((0, 0), (0.2, 1), (0.7, 0.8), (1, 0)); s.twinkle = 0.6; s.twinkleSpeed = 5
                },
            ])
        },
        ParticlePreset(id: "orbs", category: "Fire & Energy", name: "Energy Orbs") { a in
            fx(time: 3, duration: 5, [
                sys("Halo", .additive) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.5); s.emission = .burst; s.count = 1; s.immortal = true; s.speedMin = 0; s.speedMax = 0
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.sizeMin = 620; s.sizeMax = 620
                    s.gradient = g("3A7BFF", "3A7BFF"); s.opacity = 0.55; s.opacityCurve = .flat
                },
                sys("Core", .additive) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.5); s.emission = .burst; s.count = 3; s.immortal = true; s.speedMin = 0; s.speedMax = 0
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.sizeMin = 200; s.sizeMax = 300
                    s.gradient = g("E8FBFF", "9FE8FF"); s.opacity = 0.9; s.opacityCurve = .pts((0, 0.8), (0.5, 1), (1, 0.8)); s.lifeMin = 0.6; s.lifeMax = 1.1
                },
                sys("Orbiting sparks", .additive) { s in
                    s.shape = .ring; s.pos = pt(0.5, 0.5); s.size = box(0.34, 0.34, a)
                    s.rate = 120; s.lifeMin = 1.2; s.lifeMax = 2.4
                    s.spread = 360; s.speedMin = 0; s.speedMax = 40; s.tangentialSpeed = 120
                    s.vortex = 210; s.vortexRadius = 420; s.vortexPull = 40; s.turbulence = 40; s.turbulenceScale = 160
                    s.sprite = .ember; s.sizeMin = 4; s.sizeMax = 9
                    s.gradient = g("FFFFFF@0", "8FE9FF@0.3", "3A6BFF@1"); s.opacityCurve = .fadeInOut
                    s.trail = .ribbon; s.trailLength = 0.45; s.trailSegments = 18; s.trailWidth = 0.8
                },
                sys("Glints", .additive) { s in
                    s.shape = .circle; s.pos = pt(0.5, 0.5); s.size = box(0.5, 0.5, a)
                    s.rate = 26; s.lifeMin = 0.5; s.lifeMax = 1.2; s.speedMin = 0; s.speedMax = 20; s.spread = 360
                    s.sprite = .sparkle; s.sizeMin = 12; s.sizeMax = 40; s.sizeBias = 2; s.rotationRandom = 10
                    s.gradient = g("FFFFFF", "BFEFFF"); s.opacityCurve = .pts((0, 0), (0.3, 1), (1, 0)); s.twinkle = 0.5; s.twinkleSpeed = 7
                },
            ])
        },
        ParticlePreset(id: "plasma", category: "Fire & Energy", name: "Plasma") { a in
            fx(time: 4, duration: 6, [
                sys("Plasma cloud", .additive) { s in
                    s.shape = .circle; s.pos = pt(0.5, 0.5); s.size = box(0.62, 0.62, a)
                    s.rate = 70; s.lifeMin = 3; s.lifeMax = 5; s.spread = 360; s.speedMin = 0; s.speedMax = 30
                    s.turbulence = 110; s.turbulenceScale = 300; s.turbulenceSpeed = 0.25
                    s.sprite = .smoke; s.sizeMin = 160; s.sizeMax = 330; s.rotationRandom = 180; s.spinRandom = 25
                    s.colorBase = .palette; s.palette = g("FF3CAC", "784BA0", "2B86C5", "00E5FF", "B04CFF")
                    s.opacity = 0.2; s.opacityCurve = .fadeInOut
                },
                sys("Filaments", .additive) { s in
                    s.shape = .circle; s.pos = pt(0.5, 0.5); s.size = box(0.56, 0.56, a)
                    s.rate = 260; s.lifeMin = 1.6; s.lifeMax = 3.2; s.spread = 360; s.speedMin = 0; s.speedMax = 20
                    s.turbulence = 300; s.turbulenceScale = 170; s.turbulenceSpeed = 0.18
                    s.attractors = [PAttractor(pos: pt(0.5, 0.5), strength: 260, radius: 380)]
                    s.sprite = .softDisc; s.sizeMin = 2.5; s.sizeMax = 4.5
                    s.colorBase = .palette; s.palette = g("FFD0F2", "FF7AD9", "B9A0FF", "8FE9FF")
                    s.opacity = 0.75; s.opacityCurve = .fadeInOut
                    s.trail = .ribbon; s.trailLength = 0.55; s.trailSegments = 16; s.trailWidth = 0.9
                },
            ])
        },
        ParticlePreset(id: "portal", category: "Fire & Energy", name: "Portal Swirl") { a in
            fx(time: 3, duration: 5, [
                sys("Ring glow", .additive) { s in
                    s.shape = .ring; s.pos = pt(0.5, 0.5); s.size = box(0.62, 0.62, a)
                    s.rate = 320; s.lifeMin = 0.4; s.lifeMax = 0.9; s.speedMin = 0; s.speedMax = 12; s.spread = 360; s.tangentialSpeed = -180
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.sizeMin = 40; s.sizeMax = 90
                    s.gradient = g("FFD08A", "FF7A1A@0.5", "D6360F@1"); s.opacity = 0.2; s.opacityCurve = .fadeInOut
                },
                sys("Sparks", .additive) { s in
                    s.shape = .ring; s.pos = pt(0.5, 0.5); s.size = box(0.62, 0.62, a)
                    s.rate = 2300; s.lifeMin = 0.35; s.lifeMax = 1.0
                    s.spread = 360; s.speedMin = 0; s.speedMax = 50; s.tangentialSpeed = -560; s.radialSpeed = 90; s.gravity = 130; s.drag = 0.8
                    s.turbulence = 50
                    s.sprite = .softDisc; s.sizeMin = 2; s.sizeMax = 4.5
                    s.gradient = g("FFFFFF@0", "FFE08A@0.12", "FF9A2E@0.5", "E0481A@1"); s.opacityCurve = .pts((0, 1), (0.6, 0.9), (1, 0))
                    s.trail = .streak; s.trailLength = 0.07
                },
                sys("Inner swirl", .additive) { s in
                    s.shape = .circle; s.pos = pt(0.5, 0.5); s.size = box(0.56, 0.56, a)
                    s.rate = 190; s.lifeMin = 1.2; s.lifeMax = 2.4; s.speedMin = 0; s.speedMax = 10; s.spread = 360
                    s.vortex = -150; s.vortexRadius = 330; s.vortexPull = 60
                    s.sprite = .softDisc; s.sizeMin = 2; s.sizeMax = 4
                    s.gradient = g("FFD89A", "FF8A2E"); s.opacity = 0.5; s.opacityCurve = .fadeInOut
                    s.trail = .ribbon; s.trailLength = 0.5; s.trailSegments = 14; s.trailWidth = 0.8
                },
            ])
        },
    ]

    // MARK: Light

    private static func bokeh(_ name: String, blades: Double, aspect: Double, palette: ColorGradient, count: Double) -> S {
        sys(name, .additive) { s in
            s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.15, height: 1.15)
            s.emission = .burst; s.count = count; s.immortal = true; s.lifeMin = 3; s.lifeMax = 7
            s.spread = 360; s.speedMin = 1; s.speedMax = 8
            s.sprite = .bokeh; s.spritePoints = blades; s.spriteSoftness = 0.25; s.spriteAspect = aspect
            s.sizeMin = 45; s.sizeMax = 220; s.sizeBias = 1.5; s.rotationRandom = 0; s.rotation = 8
            s.colorBase = .palette; s.palette = palette; s.brightnessVariation = 0.25
            s.opacity = 0.55; s.opacityRandom = 0.7; s.opacityCurve = .pts((0, 0.75), (0.5, 1), (1, 0.75))
            s.densityNoise = 0.55; s.densityNoiseScale = 420
        }
    }

    package static let light: [ParticlePreset] = [
        ParticlePreset(id: "bokeh.circle", category: "Light", name: "Bokeh – Circular") { a in
            fx(time: 2, duration: 6, [bokeh("Bokeh", blades: 0, aspect: 1, palette: g("FFD9A0", "FFB870", "FFE8C8", "FF9E80", "FFC4A0", "A0D8FF"), count: 80)])
        },
        ParticlePreset(id: "bokeh.hex", category: "Light", name: "Bokeh – Hexagonal") { a in
            fx(time: 2, duration: 6, [bokeh("Bokeh", blades: 6, aspect: 1, palette: g("8AD8FF", "FF8AD8", "FFE08A", "B08AFF", "8AFFD0"), count: 75)])
        },
        ParticlePreset(id: "bokeh.anamorphic", category: "Light", name: "Bokeh – Anamorphic") { a in
            fx(time: 2, duration: 6, [
                bokeh("Oval bokeh", blades: 0, aspect: 1.6, palette: g("7FC8FF", "A0E0FF", "FFD2A0", "FFFFFF", "6FA8FF"), count: 60),
                sys("Flares", .additive) { s in
                    s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 0.9, height: 0.8)
                    s.emission = .burst; s.count = 7; s.immortal = true; s.speedMin = 0; s.speedMax = 3
                    s.sprite = .streak; s.spriteAspect = 0.035; s.sizeMin = 700; s.sizeMax = 1500; s.rotationRandom = 0
                    s.gradient = g("5AA8FF", "5AA8FF"); s.opacity = 0.55; s.opacityRandom = 0.5; s.opacityCurve = .flat
                },
            ])
        },
        ParticlePreset(id: "lens.dust", category: "Light", name: "Lens Dust") { a in
            fx(time: 1, [
                sys("Dirt rings", .additive) { s in
                    s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.1, height: 1.1)
                    s.emission = .burst; s.count = 46; s.immortal = true; s.speedMin = 0; s.speedMax = 0
                    s.sprite = .lensDirt; s.sizeMin = 40; s.sizeMax = 190; s.sizeBias = 1.6; s.rotationRandom = 180
                    s.gradient = g("FFFFFF", "FFFFFF"); s.opacity = 0.3; s.opacityRandom = 0.7; s.opacityCurve = .flat
                    s.densityNoise = 0.5; s.densityNoiseScale = 380
                },
                sys("Specks", .additive) { s in
                    s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.1, height: 1.1)
                    s.emission = .burst; s.count = 170; s.immortal = true; s.speedMin = 0; s.speedMax = 0
                    s.sprite = .dust; s.sizeMin = 4; s.sizeMax = 18; s.sizeBias = 2.2
                    s.gradient = g("FFFFFF", "FFFFFF"); s.opacity = 0.4; s.opacityRandom = 0.7; s.opacityCurve = .flat
                },
            ])
        },
        ParticlePreset(id: "light.leaks", category: "Light", name: "Light Leaks & Specks") { a in
            fx(time: 1, duration: 4, [
                sys("Leaks", .additive) { s in
                    s.shape = .frame; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.05, height: 1.05)
                    s.emission = .burst; s.count = 9; s.immortal = true; s.speedMin = 0; s.speedMax = 4; s.lifeMin = 4; s.lifeMax = 7
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.spriteAspect = 0.7; s.sizeMin = 700; s.sizeMax = 1500; s.rotationRandom = 180
                    s.colorBase = .palette; s.palette = g("FF5A1F", "FF9A3C", "FFD36B", "FF3D6E", "FF7A2E")
                    s.opacity = 0.6; s.opacityRandom = 0.4; s.opacityCurve = .pts((0, 0.8), (0.5, 1), (1, 0.8))
                },
                sys("Specks", .additive) { s in
                    s.shape = .frame; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 0.95, height: 0.95)
                    s.emission = .burst; s.count = 90; s.immortal = true; s.speedMin = 0; s.speedMax = 40; s.spread = 360
                    s.sprite = .bokeh; s.spritePoints = 0; s.sizeMin = 8; s.sizeMax = 60; s.sizeBias = 2.2
                    s.colorBase = .palette; s.palette = g("FFD9A0", "FFB870", "FF9E80", "FFE8C8")
                    s.opacity = 0.5; s.opacityRandom = 0.6; s.opacityCurve = .flat
                },
            ])
        },
        ParticlePreset(id: "glitter", category: "Light", name: "Glitter") { a in
            fx(time: 1, duration: 3, [
                sys("Glitter", .additive) { s in
                    s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.05, height: 1.05)
                    s.emission = .burst; s.count = 26000; s.immortal = true; s.speedMin = 0; s.speedMax = 0; s.lifeMin = 0.6; s.lifeMax = 2
                    s.sprite = .hardDisc; s.sizeMin = 2.2; s.sizeMax = 7; s.sizeBias = 2
                    s.colorBase = .palette; s.palette = g("FFE7A3", "FFC94D", "FFF6D8", "D9A441", "FFFFFF")
                    s.opacity = 1; s.opacityRandom = 0.3; s.opacityCurve = .flat; s.twinkle = 0.92; s.twinkleSpeed = 1.2
                    s.hueVariation = 0.06; s.densityNoise = 0.9; s.densityNoiseScale = 300
                },
                sys("Glints", .additive) { s in
                    s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.05, height: 1.05)
                    s.emission = .burst; s.count = 420; s.immortal = true; s.speedMin = 0; s.speedMax = 0; s.lifeMin = 0.6; s.lifeMax = 1.6
                    s.sprite = .sparkle; s.spritePoints = 4; s.sizeMin = 18; s.sizeMax = 90; s.sizeBias = 2.4; s.rotationRandom = 25
                    s.colorBase = .palette; s.palette = g("FFF6D8", "FFE7A3", "FFFFFF")
                    s.opacityCurve = .flat; s.twinkle = 0.85; s.twinkleSpeed = 1.5
                    s.densityNoise = 0.9; s.densityNoiseScale = 300
                },
            ])
        },
        ParticlePreset(id: "stars", category: "Light", name: "Star Field with Nebula") { a in
            fx(time: 2, duration: 6, [
                sys("Nebula", .additive) { s in
                    s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.2, height: 1.2)
                    s.emission = .burst; s.count = 150; s.immortal = true; s.speedMin = 0; s.speedMax = 2; s.lifeMin = 6; s.lifeMax = 9
                    s.sprite = .smoke; s.sizeMin = 300; s.sizeMax = 700; s.rotationRandom = 180
                    s.colorBase = .palette; s.palette = g("5A2EA6", "2E56C8", "A62E86", "1F8AA8", "3A2EA6")
                    s.opacity = 0.17; s.opacityRandom = 0.5; s.opacityCurve = .flat
                    s.densityNoise = 0.95; s.densityNoiseScale = 520
                },
                sys("Stars", .additive) { s in
                    s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.05, height: 1.05)
                    s.emission = .burst; s.count = 3200; s.immortal = true; s.speedMin = 0; s.speedMax = 0; s.lifeMin = 1; s.lifeMax = 3
                    s.sprite = .softDisc; s.spriteSoftness = 0.6; s.sizeMin = 1.6; s.sizeMax = 6; s.sizeBias = 3.2
                    s.colorBase = .palette; s.palette = g("FFFFFF", "CFE0FF", "FFE9C9", "FFD2A1", "BFD0FF")
                    s.opacity = 1; s.opacityRandom = 0.7; s.opacityCurve = .flat; s.twinkle = 0.5; s.twinkleSpeed = 0.8
                },
                sys("Bright stars", .additive) { s in
                    s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.0, height: 1.0)
                    s.emission = .burst; s.count = 30; s.immortal = true; s.speedMin = 0; s.speedMax = 0; s.lifeMin = 1; s.lifeMax = 3
                    s.sprite = .sparkle; s.spritePoints = 4; s.sizeMin = 18; s.sizeMax = 60; s.sizeBias = 2; s.rotationRandom = 0
                    s.colorBase = .palette; s.palette = g("FFFFFF", "CFE0FF", "FFE9C9")
                    s.opacityCurve = .flat; s.twinkle = 0.4; s.twinkleSpeed = 0.9
                },
            ])
        },
        ParticlePreset(id: "shooting.stars", category: "Light", name: "Shooting Stars") { a in
            fx(time: 2.4, duration: 5, [
                sys("Stars", .additive) { s in
                    s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.05, height: 1.05)
                    s.emission = .burst; s.count = 900; s.immortal = true; s.speedMin = 0; s.speedMax = 0; s.lifeMin = 1; s.lifeMax = 3
                    s.sprite = .softDisc; s.spriteSoftness = 0.6; s.sizeMin = 1.5; s.sizeMax = 5; s.sizeBias = 3
                    s.gradient = g("FFFFFF", "DDE8FF"); s.opacityRandom = 0.7; s.opacityCurve = .flat; s.twinkle = 0.4; s.twinkleSpeed = 0.8
                },
                sys("Meteors", .additive) { s in
                    s.shape = .rectangle; s.pos = pt(0.72, 0.2); s.size = CGSize(width: 0.8, height: 0.45)
                    s.rate = 3.2; s.lifeMin = 0.55; s.lifeMax = 1.0
                    s.direction = 214; s.spread = 7; s.speedMin = 900; s.speedMax = 1500; s.drag = 0.4
                    s.sprite = .sparkle; s.spritePoints = 4; s.sizeMin = 18; s.sizeMax = 34; s.rotationRandom = 0
                    s.gradient = g("FFFFFF", "CFE4FF"); s.opacityCurve = .pts((0, 0), (0.2, 1), (0.7, 1), (1, 0))
                    s.trail = .ribbon; s.trailLength = 0.38; s.trailSegments = 26; s.trailWidth = 0.22
                },
            ])
        },
        ParticlePreset(id: "godrays", category: "Light", name: "God-Ray Dust") { a in
            fx(time: 4, duration: 8, [
                sys("Rays", .additive) { s in
                    s.shape = .line; s.pos = pt(0.34, 0.12); s.size = CGSize(width: 0.62, height: 0); s.emitterRotation = 0
                    s.emission = .burst; s.count = 11; s.immortal = true; s.speedMin = 0; s.speedMax = 0; s.lifeMin = 4; s.lifeMax = 8
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.spriteAspect = 0.075; s.sizeMin = 2200; s.sizeMax = 3200
                    s.rotation = -52; s.rotationRandom = 3
                    s.gradient = g("FFF1CC", "FFF1CC"); s.opacity = 0.34; s.opacityRandom = 0.6; s.opacityCurve = .pts((0, 0.6), (0.5, 1), (1, 0.6))
                },
                sys("Dust", .additive) { s in
                    s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 0.46, height: 1.7); s.emitterRotation = 38
                    s.rate = 260; s.lifeMin = 4; s.lifeMax = 8; s.spread = 360; s.speedMin = 2; s.speedMax = 14
                    s.turbulence = 12; s.turbulenceScale = 240
                    s.sprite = .dust; s.sizeMin = 5; s.sizeMax = 15; s.sizeBias = 2.2
                    s.gradient = g("FFF6DC", "FFEFC0"); s.opacity = 0.95; s.opacityRandom = 0.4; s.opacityCurve = .fadeInOut
                    s.twinkle = 0.6; s.twinkleSpeed = 0.6; s.depth = 0.5; s.focus = 0.6; s.dofBlur = 0.7
                },
            ])
        },
    ]

    // MARK: Smoke & Fluids

    package static let smoke: [ParticlePreset] = [
        ParticlePreset(id: "smoke.plume", category: "Smoke & Fluids", name: "Smoke Plume") { a in
            fx(time: 6, duration: 8, [sys("Smoke", .normal) { s in
                s.shape = .line; s.pos = pt(0.5, 0.94); s.size = box(0.05, 0, a)
                s.rate = 30; s.lifeMin = 4; s.lifeMax = 6
                s.direction = 90; s.spread = 12; s.speedMin = 120; s.speedMax = 180; s.gravity = -12; s.drag = 0.12; s.wind = 5
                s.turbulence = 75; s.turbulenceScale = 230; s.turbulenceSpeed = 0.25
                s.sprite = .smoke; s.sizeMin = 300; s.sizeMax = 460; s.sizeCurve = .pts((0, 0.14), (0.4, 0.55), (1, 1)); s.rotationRandom = 180; s.spinRandom = 25
                s.gradient = g("C8C8C8@0", "9A9A9A@0.4", "787878@1"); s.brightnessVariation = 0.5
                s.opacity = 0.46; s.opacityCurve = .pts((0, 0), (0.08, 1), (0.5, 0.6), (1, 0))
            }])
        },
        ParticlePreset(id: "steam", category: "Smoke & Fluids", name: "Steam") { a in
            fx(time: 4, duration: 6, [sys("Steam", .normal) { s in
                s.shape = .line; s.pos = pt(0.5, 0.9); s.size = box(0.14, 0, a)
                s.rate = 70; s.lifeMin = 1.8; s.lifeMax = 3.2
                s.direction = 90; s.spread = 20; s.speedMin = 190; s.speedMax = 330; s.gravity = -30; s.drag = 0.7
                s.turbulence = 95; s.turbulenceScale = 170; s.turbulenceSpeed = 0.5
                s.sprite = .smoke; s.sizeMin = 170; s.sizeMax = 300; s.sizeCurve = .pts((0, 0.2), (1, 1)); s.rotationRandom = 180; s.spinRandom = 40
                s.gradient = g("FFFFFF", "F2F6FA"); s.opacity = 0.24; s.opacityCurve = .pts((0, 0), (0.1, 1), (0.4, 0.5), (1, 0))
            }])
        },
        ParticlePreset(id: "clouds", category: "Smoke & Fluids", name: "Cloud Puffs") { a in
            fx(time: 2, duration: 8, [
                sys("Cloud shadows", .normal) { s in
                    s.shape = .circle; s.pos = pt(0.5, 0.4); s.size = CGSize(width: 0.95, height: 0.22)
                    s.emission = .burst; s.count = 60; s.immortal = true; s.direction = 0; s.spread = 0; s.speedMin = 5; s.speedMax = 9
                    s.sprite = .smoke; s.sizeMin = 220; s.sizeMax = 420; s.rotationRandom = 180
                    s.gradient = g("A9B4C4", "A9B4C4"); s.opacity = 0.5; s.opacityRandom = 0.3; s.opacityCurve = .flat
                    s.densityNoise = 0.85; s.densityNoiseScale = 380
                },
                sys("Clouds", .normal) { s in
                    s.shape = .circle; s.pos = pt(0.5, 0.36); s.size = CGSize(width: 0.95, height: 0.2)
                    s.emission = .burst; s.count = 120; s.immortal = true; s.direction = 0; s.spread = 0; s.speedMin = 5; s.speedMax = 9
                    s.sprite = .smoke; s.sizeMin = 180; s.sizeMax = 400; s.rotationRandom = 180
                    s.gradient = g("FFFFFF", "FFFFFF"); s.opacity = 0.7; s.opacityRandom = 0.3; s.opacityCurve = .flat
                    s.densityNoise = 0.85; s.densityNoiseScale = 380
                },
            ])
        },
        ParticlePreset(id: "bubbles.water", category: "Smoke & Fluids", name: "Bubbles – Underwater") { a in
            fx(time: 6, duration: 8, [sys("Bubbles", .additive) { s in
                s.shape = .line; s.pos = pt(0.5, 1.05); s.size = CGSize(width: 1.1, height: 0)
                s.rate = 30; s.lifeMin = 7; s.lifeMax = 10
                s.direction = 90; s.spread = 10; s.speedMin = 90; s.speedMax = 210; s.gravity = -6
                s.turbulence = 45; s.turbulenceScale = 130; s.turbulenceSpeed = 0.5
                s.sprite = .bubble; s.sizeMin = 8; s.sizeMax = 46; s.sizeBias = 2.2; s.rotationRandom = 12
                s.gradient = g("D8F3FF", "BFE9FF"); s.opacity = 0.9; s.opacityRandom = 0.3; s.opacityCurve = .pts((0, 0), (0.05, 1), (0.9, 1), (1, 0))
                s.depth = 0.45; s.focus = 0.55; s.dofBlur = 0.55
                s.densityNoise = 0.5; s.densityNoiseScale = 250
            }])
        },
        ParticlePreset(id: "bubbles.soap", category: "Smoke & Fluids", name: "Bubbles – Soap") { a in
            fx(time: 3, duration: 8, [sys("Soap bubbles", .additive) { s in
                s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.0, height: 1.0)
                s.emission = .burst; s.count = 30; s.immortal = true; s.lifeMin = 5; s.lifeMax = 9
                s.spread = 360; s.speedMin = 6; s.speedMax = 26; s.gravity = -2; s.turbulence = 18; s.turbulenceScale = 300
                s.sprite = .bubble; s.sizeMin = 50; s.sizeMax = 200; s.sizeBias = 1.6; s.rotationRandom = 20
                s.colorBase = .palette; s.palette = g("FFC8F0", "C8F0FF", "FFF4C8", "D0C8FF", "C8FFE0"); s.hueVariation = 0.2
                s.opacity = 0.95; s.opacityRandom = 0.2; s.opacityCurve = .flat
            }])
        },
        ParticlePreset(id: "splash", category: "Smoke & Fluids", name: "Water Splash / Spray") { a in
            fx(time: 0.42, duration: 2, [
                sys("Mist", .normal) { s in
                    s.shape = .line; s.pos = pt(0.5, 0.82); s.size = box(0.2, 0, a)
                    s.emission = .burst; s.count = 50; s.lifeMin = 0.9; s.lifeMax = 1.6
                    s.direction = 90; s.spread = 90; s.speedMin = 100; s.speedMax = 520; s.drag = 2.4; s.gravity = 120
                    s.sprite = .smoke; s.sizeMin = 120; s.sizeMax = 280; s.sizeCurve = .pts((0, 0.3), (1, 1)); s.rotationRandom = 180
                    s.gradient = g("FFFFFF", "EAF6FF"); s.opacity = 0.2; s.opacityCurve = .pts((0, 0), (0.1, 1), (1, 0))
                },
                sys("Droplets", .normal) { s in
                    s.shape = .line; s.pos = pt(0.5, 0.82); s.size = box(0.12, 0, a)
                    s.emission = .burst; s.count = 1900; s.burstSpread = 0.1; s.lifeMin = 0.9; s.lifeMax = 1.8
                    s.direction = 90; s.spread = 70; s.speedMin = 250; s.speedMax = 1500; s.gravity = 1900; s.drag = 0.5
                    s.sprite = .softDisc; s.spriteSoftness = 0.45; s.sizeMin = 2.5; s.sizeMax = 8; s.sizeBias = 2.6
                    s.gradient = g("FFFFFF", "D6EEFF"); s.opacity = 0.9; s.opacityRandom = 0.3; s.opacityCurve = .pts((0, 1), (0.8, 1), (1, 0))
                    s.trail = .stretch; s.trailLength = 0.016
                },
                sys("Crown", .normal) { s in
                    s.shape = .line; s.pos = pt(0.5, 0.83); s.size = box(0.3, 0, a)
                    s.emission = .burst; s.count = 520; s.burstSpread = 0.05; s.lifeMin = 0.5; s.lifeMax = 1.0
                    s.direction = 90; s.spread = 150; s.speedMin = 200; s.speedMax = 700; s.gravity = 1900
                    s.sprite = .softDisc; s.spriteSoftness = 0.4; s.sizeMin = 2.5; s.sizeMax = 6
                    s.gradient = g("FFFFFF", "D6EEFF"); s.opacity = 0.85; s.opacityCurve = .pts((0, 1), (0.8, 1), (1, 0))
                    s.trail = .stretch; s.trailLength = 0.02
                },
            ])
        },
        ParticlePreset(id: "ink", category: "Smoke & Fluids", name: "Ink in Water") { a in
            fx(time: 4.5, duration: 7, [sys("Ink", .normal) { s in
                s.shape = .circle; s.pos = pt(0.5, 0.08); s.size = box(0.06, 0.04, a)
                s.rate = 260; s.emitDuration = 3.2; s.prewarm = false; s.lifeMin = 5; s.lifeMax = 7
                s.direction = 270; s.spread = 50; s.speedMin = 90; s.speedMax = 330; s.drag = 1.0; s.gravity = 26
                s.turbulence = 150; s.turbulenceScale = 190; s.turbulenceSpeed = 0.12
                s.sprite = .smoke; s.sizeMin = 90; s.sizeMax = 190; s.sizeCurve = .pts((0, 0.18), (0.5, 0.7), (1, 1)); s.rotationRandom = 180; s.spinRandom = 30
                s.colorBase = .palette; s.palette = g("2438C8", "0A6CFF", "B0268A", "1B1464", "2438C8")
                s.opacity = 0.5; s.opacityCurve = .pts((0, 0), (0.05, 1), (0.6, 0.75), (1, 0))
            }])
        },
    ]

    // MARK: Celebration

    private static func confetti(_ name: String, sprite: PSprite, f: (inout S) -> Void) -> S {
        sys(name, .normal) { s in
            s.sprite = sprite; s.spriteAspect = sprite == .confettiRect ? 0.6 : 1
            s.sizeMin = 10; s.sizeMax = 19
            s.rotationRandom = 180; s.spinRandom = 360; s.tumble = 1.6
            s.colorBase = .palette; s.palette = festive
            s.opacity = 1; s.opacityCurve = .pts((0, 1), (0.9, 1), (1, 0))
            s.turbulence = 50; s.turbulenceScale = 180; s.turbulenceSpeed = 0.5
            f(&s)
        }
    }

    package static let celebration: [ParticlePreset] = [
        ParticlePreset(id: "confetti.burst", category: "Celebration", name: "Confetti – Burst") { a in
            func cannon(_ name: String, _ sprite: PSprite, _ count: Double) -> S {
                confetti(name, sprite: sprite) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.78)
                    s.emission = .burst; s.count = count; s.burstSpread = 0.12; s.lifeMin = 3; s.lifeMax = 5
                    s.direction = 90; s.spread = 80; s.speedMin = 600; s.speedMax = 2300; s.gravity = 620; s.drag = 2.4
                }
            }
            return fx(time: 1.0, duration: 4, [cannon("Rectangles", .confettiRect, 900), cannon("Triangles", .confettiTriangle, 320)])
        },
        ParticlePreset(id: "confetti.fall", category: "Celebration", name: "Confetti – Falling") { a in
            func fall(_ name: String, _ sprite: PSprite, _ rate: Double) -> S {
                confetti(name, sprite: sprite) { s in
                    s.shape = .line; s.pos = pt(0.5, -0.06); s.size = CGSize(width: 1.4, height: 0)
                    s.rate = rate; s.lifeMin = 7; s.lifeMax = 9
                    s.direction = 270; s.spread = 40; s.speedMin = 130; s.speedMax = 280; s.gravity = 20; s.drag = 0.1
                    s.turbulence = 90
                    s.depth = 0.35; s.focus = 0.5; s.dofBlur = 0.35
                }
            }
            return fx(time: 5, duration: 6, [fall("Rectangles", .confettiRect, 80), fall("Triangles", .confettiTriangle, 26)])
        },
        ParticlePreset(id: "streamers", category: "Celebration", name: "Streamers") { a in
            fx(time: 1.5, duration: 4, [sys("Streamers", .normal) { s in
                s.shape = .line; s.pos = pt(0.5, 1.0); s.size = CGSize(width: 0.9, height: 0)
                s.emission = .burst; s.count = 44; s.burstSpread = 0.5; s.lifeMin = 3; s.lifeMax = 4
                s.direction = 90; s.spread = 50; s.speedMin = 1100; s.speedMax = 1900; s.gravity = 640; s.drag = 1.5
                s.noiseForce = 3400; s.turbulenceScale = 90; s.turbulenceSpeed = 1.5
                s.sprite = .hardDisc; s.sizeMin = 9; s.sizeMax = 14
                s.colorBase = .palette; s.palette = festive
                s.opacity = 1; s.opacityCurve = .pts((0, 1), (0.9, 1), (1, 0))
                s.trail = .ribbon; s.trailLength = 1.35; s.trailSegments = 56; s.trailWidth = 1.0
            }])
        },
        ParticlePreset(id: "balloons", category: "Celebration", name: "Balloons") { a in
            fx(time: 8, duration: 10, [sys("Balloons", .normal) { s in
                s.shape = .line; s.pos = pt(0.5, 1.15); s.size = CGSize(width: 1.0, height: 0)
                s.rate = 2.4; s.lifeMin = 14; s.lifeMax = 18
                s.direction = 90; s.spread = 12; s.speedMin = 70; s.speedMax = 130
                s.turbulence = 22; s.turbulenceScale = 300
                s.sprite = .balloon; s.sizeMin = 130; s.sizeMax = 230; s.rotationRandom = 9
                s.colorBase = .palette; s.palette = g("FF3B30", "FF9500", "FFCC00", "34C759", "5AC8FA", "007AFF", "AF52DE", "FF2D55")
                s.opacity = 1; s.opacityCurve = .flat
                s.depth = 0.25
            }])
        },
        ParticlePreset(id: "hearts", category: "Celebration", name: "Hearts") { a in
            fx(time: 5, duration: 6, [sys("Hearts", .normal) { s in
                s.shape = .line; s.pos = pt(0.5, 1.05); s.size = CGSize(width: 1.0, height: 0)
                s.rate = 13; s.lifeMin = 5; s.lifeMax = 8
                s.direction = 90; s.spread = 24; s.speedMin = 90; s.speedMax = 210
                s.turbulence = 60; s.turbulenceScale = 240; s.turbulenceSpeed = 0.35
                s.sprite = .heart; s.sizeMin = 22; s.sizeMax = 84; s.sizeBias = 1.7; s.rotationRandom = 22; s.spinRandom = 16
                s.sizeCurve = .pts((0, 0.4), (0.15, 1), (1, 1))
                s.colorBase = .palette; s.palette = g("FF2D55", "FF6B81", "FF8FA3", "E0245E", "FF4D6D"); s.brightnessVariation = 0.1
                s.opacity = 0.95; s.opacityCurve = .pts((0, 0), (0.08, 1), (0.7, 1), (1, 0))
                s.depth = 0.3; s.focus = 0.45; s.dofBlur = 0.35
            }])
        },
        ParticlePreset(id: "snowglobe", category: "Celebration", name: "Snow-Globe") { a in
            fx(time: 4, duration: 8, [
                sys("Globe snow", .normal) { s in
                    s.shape = .circle; s.pos = pt(0.5, 0.5); s.size = box(0.72, 0.72, a)
                    s.emission = .burst; s.count = 1300; s.immortal = true; s.lifeMin = 4; s.lifeMax = 8
                    s.spread = 360; s.speedMin = 10; s.speedMax = 60; s.gravity = 22; s.drag = 0.9
                    s.vortex = 22; s.vortexRadius = 260; s.vortexPull = 14; s.turbulence = 120; s.turbulenceScale = 170; s.turbulenceSpeed = 0.4
                    s.confine = true; s.restitution = 0.5
                    s.sprite = .softDisc; s.spriteSoftness = 0.7; s.sizeMin = 3; s.sizeMax = 10; s.sizeBias = 1.8
                    s.opacity = 0.95; s.opacityRandom = 0.3; s.opacityCurve = .flat
                    s.dofBlur = 0.3; s.focus = 0.6
                },
                sys("Glass", .additive) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.5); s.emission = .burst; s.count = 1; s.immortal = true; s.speedMin = 0; s.speedMax = 0
                    s.sprite = .bubble; s.sizeMin = 760; s.sizeMax = 760; s.rotationRandom = 0
                    s.gradient = g("E8F4FF", "E8F4FF"); s.opacity = 0.75; s.opacityCurve = .flat
                },
            ])
        },
    ]

    // MARK: Abstract

    package static let abstract: [ParticlePreset] = [
        ParticlePreset(id: "flowfield", category: "Abstract", name: "Swarm / Flow Field") { a in
            fx(time: 4, duration: 6, [sys("Swarm", .additive) { s in
                s.shape = .rectangle; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.1, height: 1.1)
                s.rate = 1700; s.lifeMin = 2.5; s.lifeMax = 4.5; s.speedMin = 0; s.speedMax = 0
                s.turbulence = 300; s.turbulenceScale = 330; s.turbulenceSpeed = 0.04
                s.sprite = .softDisc; s.sizeMin = 2; s.sizeMax = 3.4
                s.colorBase = .palette; s.palette = g("00F5D4", "00BBF9", "FEE440", "F15BB5", "9B5DE5")
                s.opacity = 0.34; s.opacityCurve = .fadeInOut
                s.trail = .ribbon; s.trailLength = 0.7; s.trailSegments = 16; s.trailWidth = 1
            }])
        },
        ParticlePreset(id: "galaxy", category: "Abstract", name: "Galaxy Spiral") { a in
            func arm(_ name: String, _ f: (inout S) -> Void) -> S {
                sys(name, .additive) { s in
                    s.shape = .spiral; s.pos = pt(0.5, 0.5); s.size = box(0.95, 0.58, a); s.emitterRotation = -18
                    s.arms = 2; s.twist = 2.7
                    s.emission = .burst; s.immortal = true; s.speedMin = 0; s.speedMax = 0
                    s.vortex = 5; s.vortexRadius = 300
                    f(&s)
                }
            }
            return fx(time: 2, duration: 8, [
                arm("Dust lanes", { s in
                    s.count = 420; s.sprite = .smoke; s.sizeMin = 70; s.sizeMax = 200; s.rotationRandom = 180
                    s.colorBase = .palette; s.palette = g("6A3CC8", "2E56C8", "B03C9A", "3C7AC8")
                    s.opacity = 0.11; s.opacityRandom = 0.4; s.opacityCurve = .flat; s.lifeMin = 5; s.lifeMax = 8
                }),
                arm("Stars", { s in
                    s.count = 30000; s.sprite = .softDisc; s.spriteSoftness = 0.6; s.sizeMin = 1.5; s.sizeMax = 5; s.sizeBias = 3
                    s.colorBase = .palette; s.palette = g("FFFFFF", "BFD7FF", "FFE3B8", "FFB0A0", "9FB8FF")
                    s.opacity = 0.9; s.opacityRandom = 0.6; s.opacityCurve = .flat; s.twinkle = 0.3; s.twinkleSpeed = 0.7; s.lifeMin = 1; s.lifeMax = 3
                }),
                sys("Core", .additive) { s in
                    s.shape = .point; s.pos = pt(0.5, 0.5); s.emission = .burst; s.count = 2; s.immortal = true; s.speedMin = 0; s.speedMax = 0
                    s.sprite = .softDisc; s.spriteSoftness = 1; s.spriteAspect = 0.7; s.sizeMin = 280; s.sizeMax = 420; s.rotation = 18; s.rotationRandom = 0
                    s.gradient = g("FFF2D8", "FFE0B0"); s.opacity = 0.8; s.opacityCurve = .flat
                },
            ])
        },
        ParticlePreset(id: "dispersion", category: "Abstract", name: "Dispersion of Active Layer") { a in
            fx(time: 1.6, duration: 4, [
                sys("Fragments", .normal) { s in
                    s.shape = .layerAlpha
                    s.emission = .burst; s.count = 90000; s.prewarm = false
                    s.sweep = 3.2; s.sweepAngle = 0; s.sweepNoise = 0.45
                    s.lifeMin = 1.2; s.lifeMax = 2.8
                    s.direction = 8; s.spread = 50; s.speedMin = 30; s.speedMax = 420; s.wind = 260; s.gravity = -40; s.drag = 0.5
                    s.turbulence = 150; s.turbulenceScale = 200; s.turbulenceSpeed = 0.4
                    s.sprite = .square; s.sizeMin = 2.5; s.sizeMax = 11; s.sizeBias = 2.4; s.sizeCurve = .pts((0, 1), (0.6, 0.8), (1, 0.25))
                    s.rotationRandom = 180; s.spinRandom = 200
                    s.colorBase = .image
                    s.opacity = 1; s.opacityCurve = .pts((0, 1), (0.7, 1), (1, 0))
                },
            ]) { e in e.maskSourceLayer = true }
        },
        ParticlePreset(id: "text", category: "Abstract", name: "Text Made of Particles") { a in
            fx(time: 2, duration: 5, [
                sys("Text dust", .additive) { s in
                    s.shape = .text; s.text = "IMAGECRAT"; s.textFont = "Helvetica-Bold"; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 0.8, height: 0.42)
                    s.emission = .burst; s.count = 22000; s.immortal = true; s.lifeMin = 1; s.lifeMax = 3
                    s.spread = 360; s.speedMin = 0; s.speedMax = 1.5
                    s.sprite = .softDisc; s.spriteSoftness = 0.7; s.sizeMin = 3; s.sizeMax = 9; s.sizeBias = 2
                    s.colorBase = .palette; s.palette = g("FFFFFF", "8FE9FF", "FF9AE0", "FFE9A0")
                    s.opacity = 1; s.opacityRandom = 0.3; s.opacityCurve = .flat; s.twinkle = 0.35; s.twinkleSpeed = 1.2
                },
                sys("Escaping dust", .additive) { s in
                    s.shape = .text; s.text = "IMAGECRAT"; s.textFont = "Helvetica-Bold"; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 0.8, height: 0.42)
                    s.rate = 900; s.lifeMin = 1; s.lifeMax = 2.6
                    s.direction = 90; s.spread = 80; s.speedMin = 10; s.speedMax = 90; s.gravity = -30
                    s.turbulence = 80; s.turbulenceScale = 170
                    s.sprite = .softDisc; s.spriteSoftness = 0.8; s.sizeMin = 1.6; s.sizeMax = 4.5
                    s.colorBase = .palette; s.palette = g("FFFFFF", "8FE9FF", "FF9AE0", "FFE9A0")
                    s.opacity = 0.7; s.opacityCurve = .pts((0, 0), (0.1, 1), (1, 0))
                },
                sys("Glints", .additive) { s in
                    s.shape = .text; s.text = "IMAGECRAT"; s.textFont = "Helvetica-Bold"; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 0.8, height: 0.42)
                    s.emission = .burst; s.count = 46; s.immortal = true; s.speedMin = 0; s.speedMax = 0; s.lifeMin = 0.8; s.lifeMax = 2
                    s.sprite = .sparkle; s.sizeMin = 16; s.sizeMax = 54; s.sizeBias = 2; s.rotationRandom = 0
                    s.gradient = g("FFFFFF", "FFFFFF"); s.opacityCurve = .pts((0, 0.2), (0.5, 1), (1, 0.2)); s.twinkle = 0.6; s.twinkleSpeed = 1.4
                },
            ])
        },
        ParticlePreset(id: "halftone", category: "Abstract", name: "Halftone Dots Burst") { a in
            fx(time: 1, duration: 3, [sys("Dots", .normal) { s in
                s.shape = .grid; s.pos = pt(0.5, 0.5); s.size = CGSize(width: 1.04, height: 1.04)
                s.emission = .burst; s.count = 2600; s.immortal = true; s.speedMin = 0; s.speedMax = 0; s.lifeMin = 2; s.lifeMax = 2
                s.sprite = .hardDisc; s.sizeMin = 27; s.sizeMax = 27; s.sizeByDistance = 0.78; s.rotationRandom = 0
                s.gradient = g("FF2D6F", "FF2D6F"); s.opacity = 1; s.opacityCurve = .flat
            }])
        },
        ParticlePreset(id: "matrix", category: "Abstract", name: "Matrix Rain") { a in
            fx(time: 4, duration: 6, [sys("Glyph rain", .additive) { s in
                s.shape = .line; s.pos = pt(0.5, -0.05); s.size = CGSize(width: 1.1, height: 0)
                s.rate = 46; s.lifeMin = 4.5; s.lifeMax = 4.5
                s.direction = 270; s.spread = 0; s.speedMin = 260; s.speedMax = 560
                s.sprite = .glyph; s.spriteFont = "Hiragino Sans"
                s.spriteText = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎ0123456789Z:=*+<>"
                s.sizeMin = 24; s.sizeMax = 24; s.rotationRandom = 0
                s.gradient = g("EFFFF0@0", "5CFF7E@0.1", "18C83C@0.5", "0A5A1E@1"); s.trailGradient = true
                s.opacity = 1; s.opacityCurve = .pts((0, 1), (0.9, 1), (1, 0))
                s.trail = .echo; s.trailLength = 1.6; s.trailSegments = 26; s.snapGrid = 24
                s.depth = 0.0
            }])
        },
    ]
}
