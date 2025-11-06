// filepath: /Users/piulin/Documents/BattGUI/app/PopoverState.swift
// Tracks whether the popover/window is visible so we can pause background work when hidden.
import Foundation
import Combine

final class PopoverState: ObservableObject {
    @Published var isVisible: Bool = false
}
