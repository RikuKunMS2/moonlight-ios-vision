//

import SwiftUI

struct ComputerView: View {
    @EnvironmentObject private var viewModel: MainViewModel

    @Binding public var host: TemporaryHost?

    var body: some View {
        // put pairing state here
        if let host {
            switch host.pairState {
            case PairState.paired:
                Text("Paired")
            case PairState.unpaired:
                Button("Start Pairing") {
                    viewModel.tryPairHost(host);
                }.alert(
                    "Pairing",
                    isPresented: $viewModel.pairingInProgress
                ) {
                }
            default:
                Text("UNK")
            }
            ForEach(Array(host.appList as? Set<TemporaryApp> ?? []), id: \.self) { app in
                Text(app.name ?? "UNKNOWN")
            }
        }
    }
}

#Preview {
    struct Preview: View {
        @SwiftUI.State var host: TemporaryHost? = TemporaryHost()
        var body: some View {
            ComputerView(host: $host)
        }
    }

    return Preview()
}
