//

import SwiftUI

struct ComputerView: View {
    @EnvironmentObject private var viewModel: MainViewModel

    public var host: TemporaryHost

    var body: some View {
        VStack {
            if host.updatePending {
                ProgressView()
            } else {
                // put pairing state here
                switch host.pairState {
                case PairState.paired:
                    Text("Paired")
                case PairState.unpaired:
                    Text(host.name)
                    Button("Start Pairing") {
                        viewModel.tryPairHost(host)
                    }.alert(
                        "Pairing",
                        isPresented: $viewModel.pairingInProgress
                    ) {
                        Button(role: .cancel) {
                            viewModel.endPairing()
                        } label: {
                            Text("Cancel")
                        }
                    } message: {
                        Text("""
                        Enter the following PIN on the host machine:
                        \(viewModel.currentPin).\n If your host PC is running Sunshine,
                        navigate to the Sunshine web UI to enter the PIN.
                        """)
                    }
                default:
                    Text("UNK")
                }
                ForEach(Array(host.appList as? Set<TemporaryApp> ?? []), id: \.self) { app in
                    Text(app.name ?? "UNKNOWN")
                }
            }
        }.task {
            await viewModel.updateHost(host: host)
        }
    }
}

#Preview {
    let viewModel = MainViewModel()
    viewModel.pairingInProgress = true
    var outerHost: TemporaryHost = .init()
    outerHost.pairState = PairState.unpaired

    return ComputerView(host: outerHost).environmentObject(viewModel)
}
