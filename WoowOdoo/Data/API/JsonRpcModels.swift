import Foundation

// MARK: - JSON-RPC 2.0 Protocol Models
// Ported from OdooJsonRpcClient: entities/dataset/callkw/

/// Standard JSON-RPC 2.0 request envelope.
struct JsonRpcRequest<Params: Encodable>: Encodable {
    let jsonrpc: String = "2.0"
    let method: String = "call"
    let id: String
    let params: Params
}

/// JSON-RPC 2.0 response envelope.
struct JsonRpcResponse<Result: Decodable>: Decodable {
    let result: Result?
    let error: JsonRpcError?
}

/// JSON-RPC error structure (Odoo-specific).
struct JsonRpcError: Decodable {
    let message: String?
    let code: Int?
    let data: JsonRpcErrorData?
}

struct JsonRpcErrorData: Decodable {
    let name: String?
    let message: String?
    let debug: String?
    let exceptionType: String?
    let arguments: [String]?

    enum CodingKeys: String, CodingKey {
        case name, message, debug, arguments
        case exceptionType = "exception_type"
    }
}

// MARK: - Authentication
// Ported from OdooJsonRpcClient: entities/session/authenticate/

struct AuthenticateParams: Encodable {
    let db: String
    let login: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case db, login, password
    }
}

struct AuthenticateResult: Decodable {
    let uid: Int?
    let sessionId: String?
    let name: String?
    let username: String?
    let db: String?
    let partnerId: Int?
    let companyId: Int?
    let serverVersion: String?
    let isSuperuser: Bool?
    let userContext: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case uid, name, username, db
        case sessionId = "session_id"
        case partnerId = "partner_id"
        case companyId = "company_id"
        case serverVersion = "server_version"
        case isSuperuser = "is_superuser"
        case userContext = "user_context"
    }
}

// MARK: - CallKw (Generic CRUD)
// Ported from OdooJsonRpcClient: entities/dataset/callkw/

struct CallKwParams: Encodable {
    let model: String
    let method: String
    let args: [AnyCodable]
    let kwargs: [String: AnyCodable]

    init(model: String, method: String, args: [Any] = [], kwargs: [String: Any] = [:]) {
        self.model = model
        self.method = method
        self.args = args.map { AnyCodable($0) }
        self.kwargs = kwargs.mapValues { AnyCodable($0) }
    }
}

// MARK: - SearchRead
// Ported from OdooJsonRpcClient: entities/dataset/searchread/

struct SearchReadParams: Encodable {
    let model: String
    let fields: [String]
    let domain: [AnyCodable]
    let offset: Int
    let limit: Int
    let sort: String

    init(model: String, fields: [String], domain: [[Any]] = [], offset: Int = 0, limit: Int = 80, sort: String = "") {
        self.model = model
        self.fields = fields
        self.domain = domain.map { AnyCodable($0) }
        self.offset = offset
        self.limit = limit
        self.sort = sort
    }
}

// MARK: - AnyCodable (Type-erased Codable wrapper)

/// Wraps any JSON-compatible value for encoding/decoding.
/// Needed because Odoo JSON-RPC uses heterogeneous arrays and maps.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
