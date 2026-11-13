import Foundation

/// Linear-light RGB in the capture color space (requested as extended linear sRGB).
struct LinearRGB {
    var r: Double, g: Double, b: Double

    func scaled(by factor: Double) -> LinearRGB {
        LinearRGB(r: r * factor, g: g * factor, b: b * factor)
    }

    /// Relative luminance (Y) with sRGB/Rec.709 primaries.
    var luminance: Double { 0.2126729 * r + 0.7151522 * g + 0.0721750 * b }

    var lab: Lab {
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = luminance
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        func f(_ t: Double) -> Double {
            let delta = 6.0 / 29.0
            return t > delta * delta * delta ? cbrt(t) : t / (3 * delta * delta) + 4.0 / 29.0
        }
        let fx = f(x / 0.95047), fy = f(y / 1.0), fz = f(z / 1.08883)
        return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }
}

struct Lab { var l: Double, a: Double, b: Double }

enum ColorMath {
    /// CIEDE2000 (Sharma, Wu, Dalal 2005).
    static func deltaE2000(_ c1: Lab, _ c2: Lab) -> Double {
        let c1ab: Double = hypot(c1.a, c1.b)
        let c2ab: Double = hypot(c2.a, c2.b)
        let cMean: Double = (c1ab + c2ab) / 2
        let g: Double = 0.5 * (1 - sqrt(seventh(cMean) / (seventh(cMean) + pow25to7)))
        let a1p: Double = (1 + g) * c1.a
        let a2p: Double = (1 + g) * c2.a
        let c1p: Double = hypot(a1p, c1.b)
        let c2p: Double = hypot(a2p, c2.b)
        let h1p: Double = hueDegrees(c1.b, a1p)
        let h2p: Double = hueDegrees(c2.b, a2p)
        let chromaProduct: Double = c1p * c2p

        let dLp: Double = c2.l - c1.l
        let dCp: Double = c2p - c1p
        var dhp: Double = 0
        if chromaProduct != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp: Double = 2 * sqrt(chromaProduct) * sin(radians(dhp / 2))

        let lMean: Double = (c1.l + c2.l) / 2
        let cpMean: Double = (c1p + c2p) / 2
        let hSum: Double = h1p + h2p
        var hpMean: Double = hSum
        if chromaProduct != 0 {
            if abs(h1p - h2p) > 180 {
                hpMean = hSum < 360 ? (hSum + 360) / 2 : (hSum - 360) / 2
            } else {
                hpMean = hSum / 2
            }
        }

        let t1: Double = 0.17 * cos(radians(hpMean - 30))
        let t2: Double = 0.24 * cos(radians(2 * hpMean))
        let t3: Double = 0.32 * cos(radians(3 * hpMean + 6))
        let t4: Double = 0.20 * cos(radians(4 * hpMean - 63))
        let t: Double = 1 - t1 + t2 + t3 - t4
        let thetaArg: Double = (hpMean - 275) / 25
        let dTheta: Double = 30 * exp(-(thetaArg * thetaArg))
        let rc: Double = 2 * sqrt(seventh(cpMean) / (seventh(cpMean) + pow25to7))
        let lOffset: Double = (lMean - 50) * (lMean - 50)
        let sl: Double = 1 + 0.015 * lOffset / sqrt(20 + lOffset)
        let sc: Double = 1 + 0.045 * cpMean
        let sh: Double = 1 + 0.015 * cpMean * t
        let rt: Double = -sin(radians(2 * dTheta)) * rc

        let dl: Double = dLp / sl
        let dc: Double = dCp / sc
        let dh: Double = dHp / sh
        let sum: Double = dl * dl + dc * dc + dh * dh + rt * dc * dh
        return sum.squareRoot()
    }

    private static let pow25to7: Double = 6_103_515_625 // 25^7

    private static func seventh(_ x: Double) -> Double {
        let x2 = x * x
        return x2 * x2 * x2 * x
    }

    private static func radians(_ degrees: Double) -> Double { degrees * Double.pi / 180 }

    private static func hueDegrees(_ b: Double, _ a: Double) -> Double {
        if a == 0, b == 0 { return 0 }
        let h = atan2(b, a) * 180 / Double.pi
        return h < 0 ? h + 360 : h
    }

    /// IEEE 754 half → Float without relying on Float16 (unavailable on x86_64 macOS).
    static func halfToFloat(_ half: UInt16) -> Float {
        let sign = UInt32(half & 0x8000) << 16
        let exponent = UInt32((half >> 10) & 0x1F)
        var mantissa = UInt32(half & 0x3FF)
        let bits: UInt32
        if exponent == 0 {
            if mantissa == 0 {
                bits = sign
            } else {
                var e: UInt32 = 113
                while mantissa & 0x400 == 0 {
                    mantissa <<= 1
                    e -= 1
                }
                bits = sign | (e << 23) | ((mantissa & 0x3FF) << 13)
            }
        } else if exponent == 31 {
            bits = sign | 0x7F80_0000 | (mantissa << 13)
        } else {
            bits = sign | ((exponent + 112) << 23) | (mantissa << 13)
        }
        return Float(bitPattern: bits)
    }
}
