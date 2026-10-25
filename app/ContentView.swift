// Power Management Suite - Main Content View
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
//
//  ContentView.swift
//  app
//
//  Created by tsunami on 2025/3/22.
//

import SwiftUI
import SwiftUI
import AppKit

struct ContentView: View {
    // State for battery info and UI controls
    @StateObject private var batteryManager = BatteryInfoManager()
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @StateObject private var chargeController = ChargeController()
    @EnvironmentObject private var popoverState: PopoverState

    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    var body: some View {
        VStack(spacing: 10) {
            header

            if let error = chargeController.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            // --- Power Flow Visualization ---
            PowerFlowView(
                inputPower: batteryManager.inputwatt,
                batteryPower: batteryManager.batteryPower,
                systemLoad: batteryManager.loadwatt
            )
            .frame(minWidth: 300)
            .animation(.easeIn, value: batteryManager.batteryPower)

            InfoSection {
                InfoRow(icon: Icons.designCapacity, tint: .green, label: "design.capacity.label",
                        value: "\(batteryManager.designCapacity) mAh", detail: "100%")
                InfoRow(icon: Icons.serial, tint: .gray, label: "serial.number.label",
                        value: batteryManager.serialNumber)
            }

            InfoSection {
                InfoRow(icon: Icons.maxCapacity, tint: .pink, label: "max.capacity.label",
                        value: "\(batteryManager.batteryCapacity) mAh", detail: String(format: "%.0f%%", batteryManager.health))
                InfoRow(icon: Icons.cycleCount, tint: .blue, label: "cycle.count.label",
                        value: "\(batteryManager.cycleCount)")
                InfoRow(icon: Icons.temperature, tint: .orange, label: "battery.temperature.label",
                        value: String(format: "%.2f °C", batteryManager.temperature))
                InfoRow(icon: Icons.level(batteryManager.batteryPercent), tint: .green, label: "battery.level.label",
                        value: String(format: "%d%%", batteryManager.batteryPercent))
            }

            InfoSection {
                InfoRow(icon: Icons.charging, tint: .yellow, label: "charging.status.label",
                        value: NSLocalizedString(batteryManager.isCharging ? "yes" : "no", comment: ""))
                InfoRow(icon: Icons.power, tint: .yellow, label: "battery.power.label",
                        value: String(format: "%.2f W", abs(batteryManager.batteryPower)))
                InfoRow(icon: Icons.current, tint: .teal, label: "battery.amperage.label",
                        value: String(format: "%.3f A", abs(batteryManager.batteryAmperage)))
                InfoRow(icon: Icons.voltage, tint: .purple, label: "battery.voltage.label",
                        value: String(format: "%.2f V", batteryManager.batteryVoltage))
            }

            InfoSection {
                InfoRow(icon: Icons.systemLoad, tint: .indigo, label: "system.load.label",
                        value: String(format: "%.2f W", batteryManager.loadwatt))
                InfoRow(icon: Icons.adapter, tint: .yellow, label: "adapter.input.power.label",
                        value: String(format: "%.2f W", batteryManager.inputwatt))
                InfoRow(icon: Icons.current, tint: .teal, label: "adapter.input.amperage.label",
                        value: String(format: "%.3f A", batteryManager.amperage))
                InfoRow(icon: Icons.voltage, tint: .purple, label: "adapter.input.voltage.label",
                        value: String(format: "%.2f V", batteryManager.voltage))
            }
        }
        .padding(10)
        .onReceive(timer) { _ in
            if popoverState.isVisible {
                batteryManager.updateBatteryInfo()
                chargeController.refreshIfStale()
            }
        }
        .onChange(of: popoverState.isVisible) { _, isVisible in
            if isVisible {
                chargeController.refresh()
            }
        }
    }

    // Charging toggle and quit button
    private var header: some View {
        HStack(spacing: 8) {
            // Pause / allow battery charging while staying on adapter power
            HStack(spacing: 8) {
                Image(systemName: chargeController.isPaused ? Icons.chargingPaused : Icons.chargingAllowed)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(chargeController.isPaused ? Color.secondary : Color.yellow)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18)
                Text(LocalizedStringKey(chargeController.isPaused ? "charging.paused.label" : "charging.allowed.label"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if chargeController.isBusy {
                    ProgressView().controlSize(.small)
                }
                Toggle("", isOn: Binding(
                    get: { !chargeController.isPaused },
                    set: { chargeController.setChargingAllowed($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(chargeController.isBusy)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 36)
            .glassSurface(in: Capsule())
            .help(chargeController.holdLimit.map { String(format: NSLocalizedString("charging.hold.help", comment: "Tooltip while charging is paused"), $0) } ?? "")

            QuitButton(action: quitApp)
        }
    }
}

// A group of related rows on a subtle rounded background.
private struct InfoSection<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 6) {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// One labelled value with a tinted symbol.
private struct InfoRow: View {
    let icon: String
    let tint: Color
    let label: LocalizedStringKey
    let value: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .font(.system(size: 13))
        .monospacedDigit()
    }
}

private struct QuitButton: View {
    let action: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        } else {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThickMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }
}

extension View {
    // Liquid Glass on macOS 26 and later, a material on earlier versions.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThickMaterial, in: shape)
        }
    }
}

extension ContentView {
    // SF Symbols used by the rows
    struct Icons {
        static let chargingAllowed = "bolt.fill"
        static let chargingPaused = "bolt.slash.fill"
        static let designCapacity = "battery.100percent"
        static let serial = "number"
        static let maxCapacity = "heart.fill"
        static let cycleCount = "arrow.triangle.2.circlepath"
        static let temperature = "thermometer.medium"
        static let charging = "battery.100percent.bolt"
        static let power = "bolt.fill"
        static let current = "arrow.up.arrow.down"
        static let voltage = "gauge.medium"
        static let systemLoad = "laptopcomputer"
        static let adapter = "powerplug.portrait.fill"

        static func level(_ percent: Int) -> String {
            switch percent {
            case ..<13: return "battery.0percent"
            case ..<38: return "battery.25percent"
            case ..<63: return "battery.50percent"
            case ..<88: return "battery.75percent"
            default: return "battery.100percent"
            }
        }
    }
}
