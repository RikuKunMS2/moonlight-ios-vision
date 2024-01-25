//

import SwiftUI

struct ComputerView: View {
    @EnvironmentObject private var viewModel: MainViewModel

    public var host: TemporaryHost

    var body: some View {
        // put pairing state here
        switch host.pairState {
        case PairState.paired:
            Text("Paired")
        case PairState.unpaired:
            Text(host.name).onAppear {
                viewModel.updateHost(host: host)
            }
            Button("Start Pairing") {
                host.name = "renamed"
//                    viewModel.tryPairHost(host)
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
}

#Preview {
    let viewModel = MainViewModel()
    viewModel.pairingInProgress = true
    var outerHost: TemporaryHost = TemporaryHost()
    outerHost.pairState = PairState.unpaired

    return ComputerView(host: outerHost).environmentObject(viewModel)
}
