import Foundation
import AuthenticationServices
import UIKit

@MainActor
final class RovieAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = RovieAuthSession()
    private var currentSession: ASWebAuthenticationSession?

    func startLogin(completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "\(RovieChannel.defaultPortalURL)/signin?next=/auth/mobile") else {
            completion(.failure(NSError(domain: "RovieAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid auth URL"])))
            return
        }

        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "rovie") { callbackURL, error in
            DispatchQueue.main.async {
                if let error = error {
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                        completion(.failure(error))
                    }
                    return
                }
                guard let callbackURL = callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let key = components.queryItems?.first(where: { $0.name == "key" || $0.name == "apiKey" })?.value,
                      !key.isEmpty else {
                    completion(.failure(NSError(domain: "RovieAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: "No API key found in callback"])))
                    return
                }
                completion(.success(key))
            }
        }

        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.currentSession = session
        if !session.start() {
            completion(.failure(NSError(domain: "RovieAuth", code: -3, userInfo: [NSLocalizedDescriptionKey: "Could not start auth session"])))
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}

