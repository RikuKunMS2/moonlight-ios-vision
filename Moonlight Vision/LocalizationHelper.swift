//
//  LocalizationHelper.swift
//  Moonlight Vision
//
//  Created by Linggan-ua on 2025/11/16.

import Foundation
import SwiftUI

extension Bundle {
    /// Returns the bundle for the specified language
    static func bundle(for language: AppLanguage) -> Bundle {
        guard let path = Bundle.main.path(forResource: language.localeIdentifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main
        }
        return bundle
    }
}

extension AppLanguage {
    /// Returns the locale identifier for the language
    var localeIdentifier: String {
        switch self {
        case .english:
            return "en"
        case .chinese:
            return "zh-Hans"
        }
    }
}

extension String {
    /// Localizes the string using the specified language
    func localized(for language: AppLanguage) -> String {
        let bundle = Bundle.bundle(for: language)
        return NSLocalizedString(self, bundle: bundle, comment: "")
    }
    
    /// Localizes the string with format arguments
    func localized(for language: AppLanguage, _ arguments: CVarArg...) -> String {
        let format = localized(for: language)
        return String(format: format, arguments: arguments)
    }
}

