import Foundation

/// A shared ephemeral session for live usage requests.
///
/// - Ephemeral: no cookies, no cached responses persisted.
/// - Redirects are refused, so a `Authorization: Bearer …` header can never be
///   forwarded to a different host.
final class LiveSession: NSObject, URLSessionTaskDelegate {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config, delegate: LiveSession(), delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
