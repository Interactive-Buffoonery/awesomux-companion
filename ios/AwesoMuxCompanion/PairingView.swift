import SwiftUI
import UIKit
import VisionKit

/// Welcome and Pair Again: scan the Mac's code or paste its link, then confirm the words.
struct PairingView: View {
    let store: CompanionStore
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    switch store.pairingStep {
                    case .idle, .failed: welcome
                    case .connecting(let macName): connecting(macName)
                    case .confirm(let words, let macName, let transport): confirm(words, macName: macName, transport: transport)
                    }
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .background(Cat.page)
            .toolbar {
                if store.record != nil || store.pairingStep != .idle {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { store.cancelPairing(); store.showingPairing = false }
                    }
                }
            }
            .sheet(isPresented: $scanning) {
                QRScannerSheet { text in
                    scanning = false
                    open(text)
                }
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(Cat.accent)
                .frame(width: 120, height: 120)
                .background(Cat.card, in: RoundedRectangle(cornerRadius: 24))
                .accessibilityHidden(true)
                .padding(.top, 24)
            Text("Connect to your Mac")
                .font(.title2.weight(.semibold)).foregroundStyle(Cat.text)
            Text("Open awesoMux on your Mac, go to Settings → awesoMux Companion, and choose Pair iPhone.")
                .font(.body).foregroundStyle(Cat.subtext0).multilineTextAlignment(.center)
            if case .failed(let message) = store.pairingStep {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(Cat.text)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Cat.card, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("pairing-error")
            }
            Button {
                scanning = true
            } label: {
                Label("Scan Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .foregroundStyle(Cat.crust)
            Button {
                open(UIPasteboard.general.string ?? "")
            } label: {
                Label("Paste Pairing Link", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
    }

    private func connecting(_ macName: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large).padding(.top, 64)
            Text("Connecting to \(macName)…").font(.headline).foregroundStyle(Cat.text)
        }
    }

    private func confirm(_ words: [String], macName: String, transport: CompanionTransport) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Cat.green)
                .frame(width: 64, height: 64)
                .background(Cat.card, in: Circle())
                .accessibilityHidden(true)
                .padding(.top, 32)
            Text("Confirm on your Mac").font(.title2.weight(.semibold)).foregroundStyle(Cat.text)
            Text("Make sure these words match what **\(macName)** shows.")
                .foregroundStyle(Cat.subtext0).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                ForEach(words, id: \.self) { word in
                    Text(word)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Cat.text)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Cat.card, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(words.joined(separator: ", "))
            .accessibilityIdentifier("confirmation-words")
            Text("Connecting over \(transport.title)").font(.footnote).foregroundStyle(Cat.subtext0)
        }
    }

    private func open(_ text: String) {
        do throws(PairingLink.Failure) {
            store.startPairing(try PairingLink(text))
        } catch {
            store.showPairingError(error.message)
        }
    }
}

private struct QRScannerSheet: View {
    let found: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScanner(found: found).ignoresSafeArea()
                } else {
                    ContentUnavailableView("Camera unavailable", systemImage: "camera.fill",
                        description: Text("Allow camera access for awesoMux in Settings, or use Paste Pairing Link."))
                }
            }
            .navigationTitle("Scan Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var delivered = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in addedItems {
                guard !delivered, let text = barcode.payloadStringValue else { continue }
                delivered = true
                dataScanner.stopScanning()
                found(text)
            }
        }
    }
}
