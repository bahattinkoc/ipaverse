//
//  NetworkLogger.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 8.02.2026.
//

import Foundation

/// Network logger that logs all HTTP requests and responses in a detailed, formatted JSON format.
///
/// Logging only ever runs in DEBUG builds, and sensitive fields (passwords, tokens, DSIDs,
/// signatures, etc.) are redacted before printing so they never end up in Console.app,
/// crash reports, or screen recordings even during development.
final class NetworkLogger: NSObject {
    static let shared = NetworkLogger()

    /// Key name fragments (lowercased, separators stripped) that mark a header/body field as
    /// sensitive. Matching is substring-based, so e.g. "dsid" also catches "X-Dsid" and
    /// "iCloud-DSID", and "token" also catches "passwordToken" / "idmsToken".
    private let sensitiveKeyPatterns: [String] = [
        "password", "token", "pet", "spd", "authcode", "securitycode",
        "dsid", "directoryservicesid", "actionsignature", "secret",
        "identitytoken", "authorization"
    ]

    private let redactedPlaceholder = "***REDACTED***"

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private override init() {
        super.init()
    }

    /// Logs the request details. No-op outside DEBUG builds.
    func logRequest(_ request: URLRequest) {
        #if DEBUG
        guard let url = request.url,
              let method = request.httpMethod else {
            return
        }

        let timestamp = dateFormatter.string(from: Date())

        var logData: [String: Any] = [
            "timestamp": timestamp,
            "type": "REQUEST",
            "method": method,
            "url": url.absoluteString
        ]

        // Headers
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            logData["headers"] = redactSensitiveValues(headers)
        }

        // Query parameters
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems, !queryItems.isEmpty {
            var queryParams: [String: String] = [:]
            for item in queryItems {
                queryParams[item.name] = item.value ?? ""
            }
            logData["queryParameters"] = redactSensitiveValues(queryParams)
        }

        // Request body
        if let body = request.httpBody {
            logData["body"] = formatBody(body, contentType: request.value(forHTTPHeaderField: "Content-Type"))
        }

        printLog(logData)
        #endif
    }

    /// Logs the response details. No-op outside DEBUG builds.
    func logResponse(_ response: URLResponse, data: Data?, error: Error?) {
        #if DEBUG
        guard let httpResponse = response as? HTTPURLResponse,
              let url = httpResponse.url else {
            return
        }

        let timestamp = dateFormatter.string(from: Date())

        var logData: [String: Any] = [
            "timestamp": timestamp,
            "type": "RESPONSE",
            "url": url.absoluteString,
            "statusCode": httpResponse.statusCode
        ]

        // Response headers - directly from HTTPURLResponse
        if !httpResponse.allHeaderFields.isEmpty {
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                if let keyString = key as? String, let valueString = value as? String {
                    headers[keyString] = valueString
                }
            }
            logData["headers"] = redactSensitiveValues(headers)
        }

        // Response body - directly from response data
        if let data = data, !data.isEmpty {
            logData["body"] = formatBody(data, contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"))
        }

        // Error - only if present
        if let error = error {
            logData["error"] = [
                "domain": error.localizedDescription,
                "code": (error as NSError).code
            ]
        }

        printLog(logData)
        #endif
    }

    // MARK: - Redaction

    private func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        return sensitiveKeyPatterns.contains { normalized.contains($0) }
    }

    /// Recursively walks a JSON/plist-shaped value (dictionaries, arrays, scalars) and replaces
    /// any value whose key matches a sensitive pattern with a redaction placeholder.
    private func redactSensitiveValues(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, val) in dict {
                result[key] = isSensitiveKey(key) ? redactedPlaceholder : redactSensitiveValues(val)
            }
            return result
        } else if let dict = value as? [String: String] {
            var result: [String: String] = [:]
            for (key, val) in dict {
                result[key] = isSensitiveKey(key) ? redactedPlaceholder : val
            }
            return result
        } else if let array = value as? [Any] {
            return array.map { redactSensitiveValues($0) }
        }
        return value
    }

    /// Redacts sensitive values embedded in raw (unparsed) text bodies, covering both
    /// XML plist `<key>k</key><string>v</string>` pairs and `key=value&...` form-encoded pairs.
    private func redactRawText(_ text: String) -> String {
        var result = redactPlistKeyValuePairs(in: text)
        result = redactFormEncodedPairs(in: result)
        return result
    }

    private func redactPlistKeyValuePairs(in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<key>([^<]+)</key>\\s*<string>([^<]*)</string>",
            options: []
        ) else { return text }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges == 3 else { continue }
            let keyRange = match.range(at: 1)
            let valueRange = match.range(at: 2)
            let key = nsText.substring(with: keyRange)
            guard isSensitiveKey(key) else { continue }

            let fullRange = match.range(at: 0)
            let keyText = nsText.substring(with: keyRange)
            let replacement = "<key>\(keyText)</key><string>\(redactedPlaceholder)</string>"
            result = (result as NSString).replacingCharacters(in: fullRange, with: replacement)
            _ = valueRange // value not needed beyond locating the match
        }
        return result
    }

    private func redactFormEncodedPairs(in text: String) -> String {
        guard text.contains("=") else { return text }
        let pairs = text.components(separatedBy: "&")
        guard pairs.count > 0, pairs.allSatisfy({ !$0.isEmpty }) else { return text }

        let redactedPairs = pairs.map { pair -> String in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return pair }
            return isSensitiveKey(parts[0]) ? "\(parts[0])=\(redactedPlaceholder)" : pair
        }
        return redactedPairs.joined(separator: "&")
    }

    /// Formats the body data based on content type
    private func formatBody(_ data: Data, contentType: String?) -> [String: Any] {
        var result: [String: Any] = [:]

        guard let contentType = contentType?.lowercased() else {
            // If content type is unknown, try to parse as JSON if it's text
            if let textString = String(data: data, encoding: .utf8),
               let jsonData = textString.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) {
                result["json"] = redactSensitiveValues(jsonObject)
            } else {
                result["raw"] = data.base64EncodedString()
                result["note"] = "Unknown content type, showing base64"
            }
            return result
        }

        if contentType.contains("application/json") {
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
                result["json"] = redactSensitiveValues(json)
            } else {
                let rawString = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
                result["raw"] = redactRawText(rawString)
                result["note"] = "Failed to parse as JSON"
            }
        } else if contentType.contains("application/x-www-form-urlencoded") {
            if let string = String(data: data, encoding: .utf8) {
                result["formData"] = redactRawText(string)
            } else {
                result["raw"] = data.base64EncodedString()
            }
        } else if contentType.contains("application/x-apple-plist") || contentType.contains("application/x-plist") {
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                result["plist"] = redactSensitiveValues(plist)
            } else {
                result["raw"] = data.base64EncodedString()
                result["note"] = "Failed to parse as PLIST"
            }
        } else if contentType.contains("text/") {
            if let textString = String(data: data, encoding: .utf8) {
                // Check if text content is actually JSON
                if let jsonData = textString.data(using: .utf8),
                   let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) {
                    result["json"] = redactSensitiveValues(jsonObject)
                } else {
                    result["text"] = redactRawText(textString)
                }
            } else {
                result["raw"] = data.base64EncodedString()
            }
        } else {
            // For unknown content types, try to parse as JSON if it's text
            if let textString = String(data: data, encoding: .utf8),
               let jsonData = textString.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) {
                result["json"] = redactSensitiveValues(jsonObject)
            } else {
                result["raw"] = data.base64EncodedString()
                result["contentType"] = contentType
                result["note"] = "Binary or unknown content type"
            }
        }

        return result
    }

    /// Prints the log in a formatted JSON style
    private func printLog(_ data: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ Failed to serialize log data")
            return
        }

        let separator = String(repeating: "═", count: 80)
        let type = data["type"] as? String ?? "LOG"

        print("\n\(separator)")
        print("🌐 NETWORK \(type)")
        print(separator)
        print(jsonString)
        print("\(separator)\n")
    }
}
