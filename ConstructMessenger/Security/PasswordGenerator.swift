//
//  PasswordGenerator.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import Security

/// Генератор сильных паролей с использованием криптографически безопасного генератора случайных чисел
class PasswordGenerator {
    static let shared = PasswordGenerator()
    private init() {}
    
    /// Генерирует сильный пароль заданной длины
    /// - Parameters:
    ///   - length: Длина пароля (по умолчанию 16 символов, минимум 8)
    ///   - includeSymbols: Включать ли специальные символы (по умолчанию true)
    /// - Returns: Сгенерированный пароль или nil в случае ошибки
    func generate(length: Int = 16, includeSymbols: Bool = true) -> String? {
        let minLength = max(8, length)
        let maxLength = 128
        
        guard minLength <= maxLength else {
            return nil
        }
        
        // Наборы символов
        let lowercase = "abcdefghijklmnopqrstuvwxyz"
        let uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let digits = "0123456789"
        let symbols = "!@#$%^&*()_+-=[]{}|;:,.<>?"
        
        var characterSet = lowercase + uppercase + digits
        if includeSymbols {
            characterSet += symbols
        }
        
        // Гарантируем наличие хотя бы одного символа из каждой категории
        var password = ""
        
        // Добавляем по одному символу из каждой категории
        password += randomCharacter(from: lowercase)
        password += randomCharacter(from: uppercase)
        password += randomCharacter(from: digits)
        if includeSymbols {
            password += randomCharacter(from: symbols)
        }
        
        // Заполняем оставшуюся длину случайными символами
        let remainingLength = minLength - password.count
        for _ in 0..<remainingLength {
            password += randomCharacter(from: characterSet)
        }
        
        // Перемешиваем символы для дополнительной безопасности
        return String(password.shuffled())
    }
    
    /// Генерирует пароль с настраиваемыми параметрами
    /// - Parameters:
    ///   - length: Длина пароля
    ///   - includeLowercase: Включать строчные буквы
    ///   - includeUppercase: Включать заглавные буквы
    ///   - includeDigits: Включать цифры
    ///   - includeSymbols: Включать специальные символы
    /// - Returns: Сгенерированный пароль или nil
    func generateCustom(
        length: Int = 16,
        includeLowercase: Bool = true,
        includeUppercase: Bool = true,
        includeDigits: Bool = true,
        includeSymbols: Bool = true
    ) -> String? {
        guard length >= 4 else { return nil }
        
        var characterSet = ""
        var requiredChars: [String] = []
        
        if includeLowercase {
            let lowercase = "abcdefghijklmnopqrstuvwxyz"
            characterSet += lowercase
            requiredChars.append(lowercase)
        }
        
        if includeUppercase {
            let uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            characterSet += uppercase
            requiredChars.append(uppercase)
        }
        
        if includeDigits {
            let digits = "0123456789"
            characterSet += digits
            requiredChars.append(digits)
        }
        
        if includeSymbols {
            let symbols = "!@#$%^&*()_+-=[]{}|;:,.<>?"
            characterSet += symbols
            requiredChars.append(symbols)
        }
        
        guard !characterSet.isEmpty else { return nil }
        
        var password = ""
        
        // Добавляем по одному символу из каждой включенной категории
        for charSet in requiredChars {
            password += randomCharacter(from: charSet)
        }
        
        // Заполняем оставшуюся длину
        let remainingLength = length - password.count
        for _ in 0..<remainingLength {
            password += randomCharacter(from: characterSet)
        }
        
        return String(password.shuffled())
    }
    
    /// Оценивает силу пароля
    /// - Parameter password: Пароль для оценки
    /// - Returns: Оценка от 0 (очень слабый) до 4 (очень сильный)
    func strength(of password: String) -> PasswordStrength {
        var score = 0
        
        // Длина
        if password.count >= 12 {
            score += 1
        } else if password.count >= 8 {
            score += 0
        } else {
            return .veryWeak
        }
        
        // Разнообразие символов
        var hasLowercase = false
        var hasUppercase = false
        var hasDigits = false
        var hasSymbols = false
        
        for char in password {
            if char.isLowercase { hasLowercase = true }
            if char.isUppercase { hasUppercase = true }
            if char.isNumber { hasDigits = true }
            if "!@#$%^&*()_+-=[]{}|;:,.<>?".contains(char) { hasSymbols = true }
        }
        
        let varietyCount = [hasLowercase, hasUppercase, hasDigits, hasSymbols].filter { $0 }.count
        if varietyCount >= 3 {
            score += 1
        }
        
        // Проверка на простые паттерны
        if !hasCommonPatterns(password) {
            score += 1
        }
        
        // Дополнительные баллы за длину
        if password.count >= 16 {
            score += 1
        }
        
        switch score {
        case 0...1:
            return .weak
        case 2:
            return .medium
        case 3:
            return .strong
        default:
            return .veryStrong
        }
    }
    
    // MARK: - Private Helpers
    
    private func randomCharacter(from string: String) -> String {
        guard let randomIndex = secureRandomIndex(max: string.count) else {
            // Fallback на обычный рандом (не должен использоваться в продакшене)
            return String(string.randomElement() ?? Character(""))
        }
        let index = string.index(string.startIndex, offsetBy: randomIndex)
        return String(string[index])
    }
    
    private func secureRandomIndex(max: Int) -> Int? {
        var randomBytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        
        guard status == errSecSuccess else { return nil }
        
        let randomValue = UInt32(randomBytes[0]) << 24 |
                         UInt32(randomBytes[1]) << 16 |
                         UInt32(randomBytes[2]) << 8 |
                         UInt32(randomBytes[3])
        
        return Int(randomValue % UInt32(max))
    }
    
    private func hasCommonPatterns(_ password: String) -> Bool {
        // Проверка на последовательности (123, abc, etc.)
        let sequences = ["123", "abc", "qwe", "asd", "password", "123456"]
        let lowercased = password.lowercased()
        
        for sequence in sequences {
            if lowercased.contains(sequence) {
                return true
            }
        }
        
        // Проверка на повторяющиеся символы (aaa, 111, etc.)
        var lastChar: Character?
        var repeatCount = 1
        
        for char in password {
            if char == lastChar {
                repeatCount += 1
                if repeatCount >= 3 {
                    return true
                }
            } else {
                repeatCount = 1
            }
            lastChar = char
        }
        
        return false
    }
}

// MARK: - Password Strength

enum PasswordStrength: Int {
    case veryWeak = 0
    case weak = 1
    case medium = 2
    case strong = 3
    case veryStrong = 4
    
    var description: String {
        switch self {
        case .veryWeak:
            return NSLocalizedString("password_strength_very_weak", comment: "Very weak password")
        case .weak:
            return NSLocalizedString("password_strength_weak", comment: "Weak password")
        case .medium:
            return NSLocalizedString("password_strength_medium", comment: "Medium password")
        case .strong:
            return NSLocalizedString("password_strength_strong", comment: "Strong password")
        case .veryStrong:
            return NSLocalizedString("password_strength_very_strong", comment: "Very strong password")
        }
    }
    
    var color: String {
        switch self {
        case .veryWeak, .weak:
            return "red"
        case .medium:
            return "orange"
        case .strong, .veryStrong:
            return "green"
        }
    }
}

