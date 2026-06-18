import Hummingbird
import HTTPTypes
import Foundation

struct RejectBareChainMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard request.uri.queryParameters["chain"] == nil else {
            var headers = HTTPFields()
            headers.append(HTTPField(name: .contentType, value: "application/json"))
            return Response(
                status: .badRequest,
                headers: headers,
                body: .init(byteBuffer: .init(data: Data("{\"error\":\"Use chainPath=Nexus/...; bare chain is no longer supported\"}".utf8)))
            )
        }
        return try await next(request, context)
    }
}
