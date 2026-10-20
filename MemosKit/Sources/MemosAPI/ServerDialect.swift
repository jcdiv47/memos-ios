import Connect
import Foundation
import Synchronization

/// Which API a server speaks. Memos 0.31 serves `memos.api.v1`; later servers dropped the
/// version from the package and renumbered the fields. The client is generated from the later
/// API and reaches a 0.31 server through Connect's JSON encoding, which matches fields by name
/// rather than number, translating the few fields and methods 0.31 named differently.
public enum ServerDialect: String, Codable, Sendable {
    /// `memos.api`, spoken in binary protobuf.
    case current
    /// `memos.api.v1` (Memos 0.31), spoken in JSON.
    case v1

    var package: String {
        switch self {
        case .current: "memos.api"
        case .v1: "memos.api.v1"
        }
    }
}

/// The dialect one client speaks, read by its codec and HTTP client on every request.
final class DialectState: Sendable {
    private let value: Mutex<ServerDialect>

    init(_ dialect: ServerDialect) {
        value = Mutex(dialect)
    }

    var current: ServerDialect {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// Binary protobuf for current servers, JSON for 0.31.
struct DialectCodec: Codec {
    let state: DialectState
    private let proto = ProtoCodec()
    private let json = JSONCodec()

    private var codec: any Codec { state.current == .v1 ? json : proto }

    func name() -> String { codec.name() }

    func serialize<Input: ProtobufMessage>(message: Input) throws -> Data {
        try codec.serialize(message: message)
    }

    func deterministicallySerialize<Input: ProtobufMessage>(message: Input) throws -> Data {
        try codec.deterministicallySerialize(message: message)
    }

    func deserialize<Output: ProtobufMessage>(source: Data) throws -> Output {
        try codec.deserialize(source: source)
    }
}

/// Sends requests unchanged to current servers. For a 0.31 server it moves each request to the
/// `memos.api.v1` route and renames the fields 0.31 named differently, both ways.
struct DialectHTTPClient: HTTPClientInterface {
    let base: any HTTPClientInterface
    let state: DialectState

    @discardableResult
    func unary(
        request: HTTPRequest<Data?>,
        onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
        onResponse: @escaping @Sendable (HTTPResponse) -> Void
    ) -> Cancelable {
        guard state.current == .v1, let route = V1Route(url: request.url) else {
            return base.unary(request: request, onMetrics: onMetrics, onResponse: onResponse)
        }
        var headers = request.headers
        // Compressed responses would hide the JSON from the translation.
        headers["accept-encoding"] = ["identity"]
        let translated = HTTPRequest(
            url: route.url,
            headers: headers,
            message: request.message.map { V1Translation.request(route.method, $0) },
            method: request.method,
            trailers: request.trailers,
            idempotencyLevel: request.idempotencyLevel
        )
        return base.unary(request: translated, onMetrics: onMetrics) { response in
            guard response.code == .ok, let message = response.message else {
                onResponse(response)
                return
            }
            onResponse(HTTPResponse(
                code: response.code,
                headers: response.headers,
                message: V1Translation.response(route.method, message),
                trailers: response.trailers,
                error: response.error,
                tracingInfo: response.tracingInfo
            ))
        }
    }

    func stream(request: HTTPRequest<Data?>, responseCallbacks: ResponseCallbacks) -> RequestCallbacks<Data> {
        // The app makes no streaming calls.
        base.stream(request: request, responseCallbacks: responseCallbacks)
    }
}

/// A Connect route, `…/memos.api.MemoService/ListMemos`, moved to its 0.31 name.
struct V1Route {
    /// `MemoService/ListMemos`, the key into ``V1Translation``.
    let method: String
    let url: URL

    /// Methods 0.31 named differently.
    private static let renamedMethods = ["UserService/ListUserStats": "ListAllUserStats"]

    init?(url: URL) {
        var components = url.pathComponents
        guard components.count >= 2 else { return nil }
        let service = components[components.count - 2]
        let current = ServerDialect.current.package + "."
        guard service.hasPrefix(current) else { return nil }
        let serviceName = String(service.dropFirst(current.count))
        let methodName = components[components.count - 1]
        method = "\(serviceName)/\(methodName)"
        components[components.count - 2] = ServerDialect.v1.package + "." + serviceName
        components[components.count - 1] = Self.renamedMethods[method] ?? methodName

        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/" + components.dropFirst().joined(separator: "/")
        guard let moved = parts.url else { return nil }
        self.url = moved
    }
}

/// The fields Memos 0.31 named differently from the current API, by method. Bodies of other
/// methods pass through byte for byte. Keep the method sets in step with the switches.
enum V1Translation {
    private typealias Object = [String: Any]

    private static let requestMethods: Set = [
        "MemoService/CreateMemoComment", "MemoService/ListMemoComments", "MemoService/ListMemoReactions",
        "MemoService/UpsertMemoReaction", "MemoService/ListMemoRelations", "MemoService/ListMemoAttachments",
        "UserService/BatchGetUsers", "UserService/UpdateUserSetting", "InstanceService/UpdateInstanceSetting",
        "UserService/ListUserStats", "AuthService/SignIn",
    ]

    private static let responseMethods: Set = [
        "MemoService/ListMemoComments", "AuthService/SignIn", "AuthService/RefreshToken",
        "UserService/ListPersonalAccessTokens", "UserService/CreatePersonalAccessToken", "UserService/GetUserStats",
        "UserService/ListUserStats", "UserService/ListUserSettings", "InstanceService/BatchGetInstanceSettings",
    ]

    static func request(_ method: String, _ body: Data) -> Data {
        guard requestMethods.contains(method) else { return body }
        return transform(body) { json in
            switch method {
            case "MemoService/CreateMemoComment", "MemoService/ListMemoComments", "MemoService/ListMemoReactions",
                 "MemoService/UpsertMemoReaction", "MemoService/ListMemoRelations", "MemoService/ListMemoAttachments":
                rename(&json, "parent", to: "name")
            case "UserService/BatchGetUsers":
                // 0.31 takes bare usernames rather than resource names.
                if let names = json.removeValue(forKey: "names") as? [String] {
                    json["usernames"] = names.map { $0.hasPrefix("users/") ? String($0.dropFirst(6)) : $0 }
                }
            case "UserService/UpdateUserSetting":
                rename(&json, "userSetting", to: "setting")
            case "InstanceService/UpdateInstanceSetting":
                rename(&json, "instanceSetting", to: "setting")
            case "UserService/ListUserStats":
                json.removeValue(forKey: "parent")
            case "AuthService/SignIn":
                if var sso = json["ssoCredentials"] as? Object {
                    rename(&sso, "identityProvider", to: "idpName")
                    json["ssoCredentials"] = sso
                }
            default:
                break
            }
        }
    }

    static func response(_ method: String, _ body: Data) -> Data {
        guard responseMethods.contains(method) else { return body }
        return transform(body) { json in
            switch method {
            case "MemoService/ListMemoComments":
                rename(&json, "memos", to: "comments")
            case "AuthService/SignIn":
                rename(&json, "accessTokenExpiresAt", to: "accessTokenExpireTime")
            case "AuthService/RefreshToken":
                rename(&json, "expiresAt", to: "accessTokenExpireTime")
            case "UserService/ListPersonalAccessTokens":
                if let tokens = json["personalAccessTokens"] as? [Object] {
                    json["personalAccessTokens"] = tokens.map(accessToken)
                }
            case "UserService/CreatePersonalAccessToken":
                if let token = json["personalAccessToken"] as? Object {
                    json["personalAccessToken"] = accessToken(token)
                }
            case "UserService/GetUserStats":
                rename(&json, "tagCount", to: "tagCounts")
            case "UserService/ListUserStats":
                rename(&json, "stats", to: "userStats")
                if let stats = json["userStats"] as? [Object] {
                    json["userStats"] = stats.map { stat in
                        var stat = stat
                        rename(&stat, "tagCount", to: "tagCounts")
                        return stat
                    }
                }
            case "UserService/ListUserSettings":
                rename(&json, "settings", to: "userSettings")
            case "InstanceService/BatchGetInstanceSettings":
                rename(&json, "settings", to: "instanceSettings")
            default:
                break
            }
        }
    }

    private static func accessToken(_ token: Object) -> Object {
        var token = token
        rename(&token, "createdAt", to: "createTime")
        rename(&token, "expiresAt", to: "expireTime")
        rename(&token, "lastUsedAt", to: "lastUseTime")
        return token
    }

    private static func rename(_ json: inout Object, _ key: String, to newKey: String) {
        if let value = json.removeValue(forKey: key) { json[newKey] = value }
    }

    /// Applies `change` to a JSON object, or returns `body` untouched when it isn't one.
    private static func transform(_ body: Data, _ change: (inout Object) -> Void) -> Data {
        guard !body.isEmpty, var json = (try? JSONSerialization.jsonObject(with: body)) as? Object else { return body }
        change(&json)
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
    }
}
