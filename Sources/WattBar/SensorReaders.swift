import Foundation

// The C entry points are declared in Tools/WattBarSensors.h.
final class GPUReader {
    func read() -> Double? {
        let watts = wattbar_gpu_watts()
        return watts >= 0 ? watts : nil
    }
}

final class CPUTemperatureReader {
    func read() -> Double? {
        let celsius = wattbar_cpu_temperature_celsius()
        return celsius >= 0 ? celsius : nil
    }
}

final class FanSpeedReader {
    func read() -> Double? {
        let rpm = wattbar_fan_rpm()
        return rpm >= 0 ? rpm : nil
    }
}

