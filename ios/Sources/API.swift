import Foundation

struct Person: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var role: String
    var org: String
    var facts: [String]
    var followups: [String]
    let has_voice: Bool
    let voice_samples: Int
    let first_met: Double
    let last_seen: Double
    let times_met: Int

    var headline: String {
        switch (role.isEmpty, org.isEmpty) {
        case (false, false): return "\(role) at \(org)"
        case (false, true): return role
        case (true, false): return org
        default: return "No details yet"
        }
    }
}

struct TurnReply: Codable {
    let session: String
    let speaker: String  // me | person | unknown
    let cluster: String?
    let person: Person?
    let sim: Double
    let speech_seconds: Double
    let event: String
    let text: String?
    let named_cluster: String?
    let whisper: String
}

struct Said: Codable, Hashable {
    let ts: Double
    let text: String
}

struct PersonDetail: Codable {
    let id: String
    let name: String
    let said: [Said]
}

struct Health: Codable {
    let ok: Bool
    let wearer_enrolled: Bool
    let people: Int
}

enum API {
    static let defaultBase = "http://MacBook-Pro-4.local:8100"

    static var base: String {
        get { UserDefaults.standard.string(forKey: "apiBase") ?? defaultBase }
        set { UserDefaults.standard.set(newValue, forKey: "apiBase") }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func call<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil,
                                           query: [String: String] = [:], timeout: Double = 30) async throws -> T {
        var c = URLComponents(string: base + path)
        if !query.isEmpty { c?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c?.url else { throw Failure(message: "Bad backend URL: \(base)") }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw Failure(message: "No response") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw Failure(message: detail ?? "HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func health() async throws -> Health { try await call("GET", "/health", timeout: 4) }

    static func turn(session: String?, text: String, wav: Data?) async throws -> TurnReply {
        var b: [String: Any] = ["text": text, "audio_b64": wav?.base64EncodedString() ?? "",
                                "ts": Date().timeIntervalSince1970]
        if let session { b["session"] = session }
        return try await call("POST", "/turn", body: b)
    }

    static func enrollMe(wav: Data, reset: Bool) async throws -> Int {
        struct R: Decodable { let samples: Int }
        let r: R = try await call("POST", "/enroll_me", body: ["audio_b64": wav.base64EncodedString(), "reset": reset])
        return r.samples
    }

    static func whois(session: String) async throws -> String {
        struct R: Decodable { let whisper: String }
        let r: R = try await call("GET", "/whois", query: ["session_id": session])
        return r.whisper
    }

    static func ask(_ q: String, session: String?) async throws -> String {
        struct R: Decodable { let answer: String }
        var b: [String: Any] = ["question": q]
        if let session { b["session"] = session }
        let r: R = try await call("POST", "/ask", body: b)
        return r.answer
    }

    static func endSession(_ s: String) async throws -> String {
        struct R: Decodable { let whisper: String }
        let r: R = try await call("POST", "/sessions/\(s)/end")
        return r.whisper
    }

    static func people() async throws -> [Person] { try await call("GET", "/people") }

    static func person(_ id: String) async throws -> PersonDetail { try await call("GET", "/people/\(id)") }

    static func update(_ p: Person) async throws -> Person {
        try await call("PATCH", "/people/\(p.id)", body: [
            "name": p.name, "role": p.role, "org": p.org, "facts": p.facts, "followups": p.followups,
        ])
    }

    static func delete(_ id: String) async throws {
        struct R: Decodable { let ok: Bool }
        let _: R = try await call("DELETE", "/people/\(id)")
    }
}
