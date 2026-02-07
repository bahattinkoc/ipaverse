//
//  NetworkLogger.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 8.02.2026.
//

import Foundation

/// Network logger that logs all HTTP requests and responses in a detailed, formatted JSON format
final class NetworkLogger: NSObject {
    static let shared = NetworkLogger()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private override init() {
        super.init()
    }

    /// Logs the request details
    func logRequest(_ request: URLRequest) {
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
            logData["headers"] = headers
        }

        // Query parameters
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems, !queryItems.isEmpty {
            var queryParams: [String: String] = [:]
            for item in queryItems {
                queryParams[item.name] = item.value ?? ""
            }
            logData["queryParameters"] = queryParams
        }

        // Request body
        if let body = request.httpBody {
            logData["body"] = formatBody(body, contentType: request.value(forHTTPHeaderField: "Content-Type"))
        }

        printLog(logData)
    }

    /// Logs the response details
    func logResponse(_ response: URLResponse, data: Data?, error: Error?) {
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
            logData["headers"] = headers
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
    }

    /// Formats the body data based on content type
    private func formatBody(_ data: Data, contentType: String?) -> [String: Any] {
        var result: [String: Any] = [:]

        guard let contentType = contentType?.lowercased() else {
            // If content type is unknown, try to parse as JSON if it's text
            if let textString = String(data: data, encoding: .utf8),
               let jsonData = textString.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) {
                result["json"] = jsonObject
            } else {
                result["raw"] = data.base64EncodedString()
                result["note"] = "Unknown content type, showing base64"
            }
            return result
        }

        if contentType.contains("application/json") {
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
                result["json"] = json
            } else {
                result["raw"] = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
                result["note"] = "Failed to parse as JSON"
            }
        } else if contentType.contains("application/x-www-form-urlencoded") {
            if let string = String(data: data, encoding: .utf8) {
                result["formData"] = string
            } else {
                result["raw"] = data.base64EncodedString()
            }
        } else if contentType.contains("application/x-apple-plist") || contentType.contains("application/x-plist") {
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                result["plist"] = plist
            } else {
                result["raw"] = data.base64EncodedString()
                result["note"] = "Failed to parse as PLIST"
            }
        } else if contentType.contains("text/") {
            if let textString = String(data: data, encoding: .utf8) {
                // Check if text content is actually JSON
                if let jsonData = textString.data(using: .utf8),
                   let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) {
                    result["json"] = jsonObject
                } else {
                    result["text"] = textString
                }
            } else {
                result["raw"] = data.base64EncodedString()
            }
        } else {
            // For unknown content types, try to parse as JSON if it's text
            if let textString = String(data: data, encoding: .utf8),
               let jsonData = textString.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) {
                result["json"] = jsonObject
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
