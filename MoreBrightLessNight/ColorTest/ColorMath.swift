import Foundation

/// Linear-light RGB in the capture color space (requested as extended linear sRGB).
struct LinearRGB {
    var r: Double, g: Double, b: Double

    static func * (lhs: LinearRGB, rhs: Double) -> LinearRGB {
        LinearRGB(r: lhs.r * rhs, g: lhs.g * rhs, b: lhs.b * rhs)
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
        func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0, b == 0 { return 0 }
            let h = atan2(b, a) * 180 / .pi
            return h < 0 ? h + 360 : h
        }
        let pow25to7 = pow(25.0, 7)

        let c1ab = hypot(c1.a, c1.b), c2ab = hypot(c2.a, c2.b)
        let cMean = (c1ab + c2ab) / 2
        let g = 0.5 * (1 - sqrt(pow(cMean, 7) / (pow(cMean, 7) + pow25to7)))
        let a1p = (1 + g) * c1.a, a2p = (1 + g) * c2.a
        let c1p = hypot(a1p, c1.b), c2p = hypot(a2p, c2.b)
        let h1p = hue(c1.b, a1p), h2p = hue(c2.b, a2p)

        let dLp = c2.l - c1.l
        let dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * sqrt(c1p * c2p) * sin(rad(dhp / 2))

        let lMean = (c1.l + c2.l) / 2
        let cpMean = (c1p + c2p) / 2
        var hpMean = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) > 180 {
                hpMean = (h1p + h2p < 360) ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2
            } else {
                hpMean = (h1p + h2p) / 2
            }
        }

        let t = 1 - 0.17 * cos(rad(hpMean - 30)) + 0.24 * cos(rad(2 * hpMean))
            + 0.32 * cos(rad(3 * hpMean + 6)) - 0.20 * cos(rad(4 * hpMean - 63))
        let dTheta = 30 * exp(-pow((hpMean - 275) / 25, 2))
        let rc = 2 * sqrt(pow(cpMean, 7) / (pow(cpMean, 7) + pow25to7))
        let lTerm = pow(lMean - 50, 2)
        let sl = 1 + 0.015 * lTerm / sqrt(20 + lTerm)
        let sc = 1 + 0.045 * cpMean
        let sh = 1 + 0.015 * cpMean * t
        let rt = -sin(rad(2 * dTheta)) * rc

        let l = dLp / sl, c = dCp / sc, h = dHp / sh
        return sqrt(l * l + c * c + h * h + rt * c * h)
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
