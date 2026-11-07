import CoreGraphics

struct DisplayPair {
    let laptop: CGDirectDisplayID
    let monitor: CGDirectDisplayID

    var sizes: ScreenSizes {
        let l = CGDisplayBounds(laptop).size, m = CGDisplayBounds(monitor).size
        return ScreenSizes(laptopW: Double(l.width), laptopH: Double(l.height),
                           monitorW: Double(m.width), monitorH: Double(m.height))
    }

    static func current() throws -> DisplayPair {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let active = ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }

        guard let laptop = active.first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            throw AppError("Open your laptop lid. ScreenSense uses the laptop's screen and camera.")
        }
        let others = active.filter { $0 != laptop }
        guard let monitor = others.first else { throw AppError("No external monitor connected.") }
        guard others.count == 1 else { throw AppError("Only one external monitor is supported.") }
        return DisplayPair(laptop: laptop, monitor: monitor)
    }

    /// Moves the monitor to `offset` relative to the laptop. Whichever display
    /// holds the menu bar has to stay at (0, 0).
    func arrange(monitorAt offset: (x: Int, y: Int)) throws {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let c = config else {
            throw AppError("macOS didn't accept the new arrangement.")
        }
        let laptopIsMain = CGDisplayIsMain(laptop) != 0
        let l = laptopIsMain ? (0, 0) : (-offset.x, -offset.y)
        let m = laptopIsMain ? (offset.x, offset.y) : (0, 0)
        CGConfigureDisplayOrigin(c, laptop, Int32(l.0), Int32(l.1))
        CGConfigureDisplayOrigin(c, monitor, Int32(m.0), Int32(m.1))
        guard CGCompleteDisplayConfiguration(c, .permanently) == .success else {
            throw AppError("macOS didn't accept the new arrangement.")
        }
    }
}
