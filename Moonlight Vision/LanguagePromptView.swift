import SwiftUI

struct LanguagePromptView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @State private var selection: AppLanguage = .english

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(viewModel.localized(english: "Choose your language", chinese: "请选择界面语言"))
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .padding(.top)

                Picker(viewModel.localized(english: "Language", chinese: "语言"), selection: $selection) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.inline)

                Button {
                    viewModel.updateLanguage(selection)
                } label: {
                    Text(viewModel.localized(english: "Continue", chinese: "继续"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }
            .padding()
            .onAppear { selection = viewModel.currentLanguage }
        }
    }
}
