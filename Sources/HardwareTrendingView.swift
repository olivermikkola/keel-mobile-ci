import SwiftUI
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Hardware-aware Hugging Face trending feed: pick a target device once (or use
/// this device) and browse trending models filtered to what actually fits, with
/// the fitting runtime, estimated/measured speed, and one-tap import.
struct HardwareTrendingView: View {
    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var chat: LocalChat
    @EnvironmentObject private var hardware: HardwareRecommendationStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Picker("Target device", selection: $hardware.selectedProfileID) {
                    ForEach(hardware.availableProfiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .accessibilityIdentifier("hardwareProfilePicker")

                let profile = hardware.activeProfile
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(profile.chipName) · \(ModelFitEstimator.formatGB(profile.usableMemoryBytes)) usable memory · \(Int(profile.memoryBandwidthGBps.rounded())) GB/s bandwidth")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(profile.supportsMLX ? "Runtimes: llama.cpp and MLX" : "Runtime: llama.cpp")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Toggle("Show only models that fit", isOn: $hardware.onlyShowFitting)
                    .accessibilityIdentifier("onlyFittingTrendingToggle")
            } header: {
                Text("Device profile")
            } footer: {
                Text("Estimates weights + 10% overhead, KV cache for conversation room, OS headroom, and memory-bandwidth speed ceiling.")
            }
            .listRowBackground(KeelStyle.surface)

            Section {
                if hardware.isLoadingTrending {
                    HStack(spacing: 10) {
                        ProgressView().tint(KeelStyle.accent)
                        Text("Checking what is trending on Hugging Face…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } else if let error = hardware.trendingError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.subheadline).foregroundStyle(.orange)
                        Button("Try again") {
                            Task { await hardware.refreshTrending() }
                        }
                    }
                    .padding(.vertical, 4)
                } else if hardware.trending.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No trending models fit \(hardware.activeProfile.shortDeviceName) right now.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if hardware.onlyShowFitting {
                            Button("Show all trending models") {
                                hardware.onlyShowFitting = false
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(hardware.trending) { item in
                        TrendingModelRow(
                            item: item,
                            canImport: !chat.running && !models.isTransferring,
                            onImport: { link in
                                models.importModel(link: link.resolveURL.absoluteString)
                                dismiss()
                            }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Trending on Hugging Face")
                    Spacer()
                    Button {
                        Task { await hardware.refreshTrending() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(hardware.isLoadingTrending)
                    .accessibilityIdentifier("refreshTrending")
                }
            }
            .listRowBackground(KeelStyle.surface)

            Section {
                if hardware.calibration.entries.isEmpty {
                    Text("No runs measured yet on this device. Send a chat message or run the runtime benchmark and Keel will calibrate its speed predictions automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hardware.calibration.entries, id: \.key) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(entry.key.chipID) · \(entry.key.runtime.displayName) · \(entry.key.quantBucket) · \(entry.key.thermalLevel.label)")
                                .font(.caption.weight(.medium))
                            Text("Last measured \(InferenceTelemetry.formatRate(entry.lastObservedTokensPerSecond)) tok/s · correction \(String(format: "%.2f×", entry.multiplier)) (\(entry.sampleCount) run\(entry.sampleCount == 1 ? "" : "s"))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    Button("Reset learned speeds", role: .destructive) {
                        hardware.resetCalibration()
                    }
                    .accessibilityIdentifier("resetSpeedCalibration")
                }
            } header: {
                Text("Measured speeds on this device")
            }
            .listRowBackground(KeelStyle.surface)
        }
        .scrollContentBackground(.hidden)
        .background(KeelStyle.background)
        .navigationTitle("Trending for hardware")
        .task {
            hardware.reloadCalibration()
            if hardware.trending.isEmpty && !hardware.isLoadingTrending {
                await hardware.refreshTrending()
            }
        }
    }
}

private struct TrendingModelRow: View {
    let item: TrendingModelRecommendation
    let canImport: Bool
    let onImport: (HuggingFaceGGUFLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).font(.headline)
                    Text(item.author).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                fitBadge
            }

            Text(item.plainCapabilitySummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if item.fit.fits {
                let speed = Int(max(1, item.calibratedSpeed.tokensPerSecond.rounded()))
                let measuredNote = item.calibratedSpeed.isMeasured ? " (measured)" : ""
                Text("~\(speed) tok/s\(measuredNote) · \(item.fit.recommendedRuntime.displayName) · \(item.quantLabel) · ~\(ModelFitEstimator.formatGB(item.fit.requiredBytes)) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let reason = item.fit.reasonNotFitting {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let file = item.selectedFileName {
                Text(file)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                if item.fit.fits, item.keelTemplateSupported, let link = item.ggufLink {
                    Button("Import & Download") {
                        onImport(link)
                    }
                    .disabled(!canImport)
                    .accessibilityIdentifier("importTrending-\(item.repoID)")
                } else if let note = item.keelCompatibilityNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link("Hugging Face", destination: item.repoURL)
                    .font(.caption)
            }
        }
        .padding(.vertical, 6)
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var fitBadge: some View {
        let (title, color): (String, Color) = switch item.fit.tier {
        case .comfortable: ("Fits", KeelStyle.accent)
        case .tight: ("Tight fit", .orange)
        case .tooLarge: ("Too large", .secondary)
        }
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}
