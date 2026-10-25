// Power Management Suite - Battery Information Manager
// Copyright (C) 2025 <Your Name or Organization>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

// Original file info:
//  Battery.swift
//  app
//
//  Created by tsunami on 2025/4/1.
//

import Foundation
import IOKit
import SwiftUI

// Manages fetching and parsing battery and power information from system commands.
//
// This class acts as an `ObservableObject`, providing published properties
// that SwiftUI views can observe to display real-time battery and power metrics.
// It reads the SMC and the AppleSmartBattery IORegistry entry directly.
class BatteryInfoManager: ObservableObject {
    // The current maximum capacity of the battery in mAh (AppleRawMaxCapacity).
    @Published var batteryCapacity: Int = 0
    // The original design capacity of the battery in mAh.
    @Published var designCapacity: Int = 0
    // The number of charge cycles the battery has undergone.
    @Published var cycleCount: Int = 0
    // The battery's health percentage, calculated as `(batteryCapacity / designCapacity) * 100`.
    @Published var health: Double = 0.0
    // Indicates whether the battery is currently charging.
    @Published var isCharging: Bool = false
    // The current charge percentage of the battery (CurrentCapacity).
    @Published var batteryPercent: Int = 0
    // The voltage being supplied by the power adapter in Volts.
    @Published var voltage: Double = 0.0
    // The amperage being supplied by the power adapter in Amps.
    @Published var amperage: Double = 0.0
    // The current power consumption of the entire system in Watts.
    @Published var loadwatt: Double = 0.0
    // The power being drawn from the power adapter in Watts.
    @Published var inputwatt: Double = 0.0
    // The battery's internal temperature in degrees Celsius.
    @Published var temperature: Double = 0.0
    // The current power draw from/to the battery in Watts. Positive means charging, negative means discharging.
    @Published var batteryPower: Double = 0.0
    // The current voltage of the battery in Volts.
    @Published var batteryVoltage: Double = 0.0
    // The current amperage flow from/to the battery in Amps. Positive means charging, negative means discharging.
    @Published var batteryAmperage: Double = 0.0
    // The serial number of the battery.
    @Published var serialNumber: String = "--"
    
    @Published var batteryVoltage_mV: UInt16 = 0
    @Published var batteryAmperage_mA: Int16 = 0
    
    // Initializes the manager and triggers the first battery info update.
    init() {
        updateBatteryInfo()
    }
    
    // Fetches and updates all battery information properties from the SMC
    // and the AppleSmartBattery registry entry.
    func updateBatteryInfo() {
        // Core power metrics via SMC (keep calls minimal; derive where possible)
        loadwatt = Double(getRawSystemPower())
        voltage = Double(getAdapterVoltage())
        inputwatt = Double(getAdapterPower())
        // Derive adapter amperage from power/voltage to avoid extra SMC read
        amperage = voltage > 0.01 ? (inputwatt / voltage) : 0.0
        
        // Battery metrics
        batteryVoltage = Double(getBatteryVoltage())
        batteryAmperage = Double(getBatteryAmperage())
        // Derive battery power and charging state from existing values
        batteryPower = batteryVoltage * batteryAmperage
        isCharging = batteryAmperage > 0.05
        
        // Battery details from the AppleSmartBattery registry entry (read
        // directly, no ioreg process).
        guard let battery = BatteryRegistry() else { return }
        defer { battery.release() }
        let data = battery.dictionary("BatteryData")
        designCapacity = data["DesignCapacity"] as? Int ?? 0
        // NominalChargeCapacity replaces AppleRawMaxCapacity, which macOS 27 no longer publishes.
        batteryCapacity = data["NominalChargeCapacity"] as? Int ?? 0
        health = designCapacity > 0 ? Double(batteryCapacity) / Double(designCapacity) * 100 : 0
        cycleCount = battery.int("CycleCount") ?? 0
        batteryPercent = battery.int("CurrentCapacity") ?? 0
        serialNumber = battery.string("Serial") ?? "--"
        let batteryTemperature = getBatteryTemperature()
        temperature = batteryTemperature > -999 ? Double(batteryTemperature) : 0
    }
}

// Reads properties of the AppleSmartBattery IORegistry entry.
private struct BatteryRegistry {
    private let service: io_service_t

    init?() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
    }

    func release() {
        IOObjectRelease(service)
    }

    private func value(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    func int(_ key: String) -> Int? { value(key) as? Int }
    func string(_ key: String) -> String? { value(key) as? String }
    func dictionary(_ key: String) -> [String: Any] { value(key) as? [String: Any] ?? [:] }
}
