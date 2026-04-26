//
//  LanguagePromptView.swift
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Created on 2/2/25.
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
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

