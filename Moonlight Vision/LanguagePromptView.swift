//
//  LanguagePromptView.swift
//  Moonlight Vision
//
//  Created on 2/2/25.
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct LanguagePromptView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @State private var selection: AppLanguage = .english

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(viewModel.localized("choose_language"))
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .padding(.top)

                Picker(viewModel.localized("language"), selection: $selection) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.inline)

                Button {
                    viewModel.updateLanguage(selection)
                } label: {
                    Text(viewModel.localized("continue"))
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

