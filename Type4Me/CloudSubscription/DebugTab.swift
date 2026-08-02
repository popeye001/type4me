// Developer-only diagnostics panel.
// Hidden by default. Enable with: defaults write com.type4me.app tf_debug_panel -bool true
// Disable with: defaults delete com.type4me.app tf_debug_panel

import SwiftUI
import os

struct DebugTab: View, SettingsCardHelpers {

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "tf_debug_panel")
    }

    @State private var cnMs: String = "—"
    @State private var usMs: String = "—"
    @State private var pinging = false
    @State private var currentRegion = CloudConfig.currentRegion

    private let logger = Logger(subsystem: "com.type4me.app", category: "DebugTab")

    var body: some View {
        SettingsSectionHeader(
            label: "DEBUG",
            title: "Diagnostics",
            description: "Region switching, latency testing, endpoint info."
        )

        regionCard
        Spacer().frame(height: 16)
        endpointsCard
    }

    // MARK: - Region Card

    private var regionCard: some View {
        settingsGroupCard("Region", icon: "network") {
            HStack {
                Text("Active Region")
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                Spacer()
                Text(currentRegion.rawValue.uppercased())
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(TF.settingsAccentGreen)
            }

            SettingsDivider()

            HStack(spacing: 20) {
                latencyColumn("CN (Beijing)", ms: cnMs, active: currentRegion == .cn)
                latencyColumn("US (Los Angeles)", ms: usMs, active: currentRegion == .overseas)
                Spacer()
                secondaryButton(pinging ? "Pinging..." : "Ping Both") {
                    pingBoth()
                }
                .disabled(pinging)
            }

            SettingsDivider()

            HStack(spacing: 8) {
                regionButton("Force CN", region: .cn)
                regionButton("Force US", region: .overseas)
                secondaryButton("Auto Detect") {
                    UserDefaults.standard.removeObject(forKey: "tf_cloud_region_override")
                    Task {
                        let r = await RegionDetector.detect()
                        currentRegion = r
                        pingBoth()
                    }
                }
            }

            if UserDefaults.standard.string(forKey: "tf_cloud_region_override") != nil {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("Manual override active. Auto-detect disabled.")
                        .font(.system(size: 11))
                }
                .foregroundStyle(TF.settingsAccentAmber)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Endpoints Card

    private var endpointsCard: some View {
        settingsGroupCard("Endpoints", icon: "server.rack") {
            endpointRow("CN API", value: CloudConfig.cnAPIEndpoint)
            SettingsDivider()
            endpointRow("US API", value: CloudConfig.usAPIEndpoint)
            SettingsDivider()
            endpointRow("Active", value: CloudConfig.apiEndpoint)
        }
    }

    // MARK: - Helpers

    private func latencyColumn(_ label: String, ms: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
            Text(ms)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(active ? TF.settingsAccentGreen : TF.settingsText)
        }
    }

    private func regionButton(_ label: String, region: CloudRegion) -> some View {
        let isActive = currentRegion == region
        return Button(label) {
            UserDefaults.standard.set(region.rawValue, forKey: "tf_cloud_region_override")
            CloudConfig.currentRegion = region
            currentRegion = region
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: isActive ? .bold : .medium))
        .foregroundStyle(isActive ? TF.settingsAccentGreen : TF.settingsTextSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? TF.settingsAccentGreen.opacity(0.15) : TF.settingsCardAlt)
        )
    }

    private func endpointRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(TF.settingsText)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func pingBoth() {
        pinging = true
        cnMs = "..."
        usMs = "..."
        Task {
            async let cn = ping(CloudConfig.cnAPIEndpoint + "/health")
            async let us = ping(CloudConfig.usAPIEndpoint + "/health")
            let cnResult = await cn
            let usResult = await us
            cnMs = cnResult.map { String(format: "%.0fms", $0) } ?? "timeout"
            usMs = usResult.map { String(format: "%.0fms", $0) } ?? "timeout"
            pinging = false
            logger.info("Ping results: CN=\(cnMs), US=\(usMs)")
        }
    }

    private func ping(_ urlString: String) async -> Double? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        } catch {
            return nil
        }
    }
}
