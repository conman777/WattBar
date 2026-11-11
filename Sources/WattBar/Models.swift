import Foundation

struct PowerReading {
    static let desktopState = "Desktop / no system battery"

    let systemWatts: Double?
    let adapterInputWatts: Double?
    let powerState: String
    let batteryFlowWatts: Double?
    let source: String
    let details: String
    let updatedAt: Date
}

struct ActiveApp {
    let name: String
    let cpu: Double
    let memoryMB: Int
}

struct NetworkSpeedReading {
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let totalDownloadedBytes: UInt64
    let totalUploadedBytes: UInt64
}

