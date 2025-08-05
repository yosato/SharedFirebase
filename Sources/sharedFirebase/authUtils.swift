//
//  File.swift
//  SharedFirebase
//
//  Created by Yo Sato on 2025/08/01.
//


import FirebaseAuth
import FirebaseFirestore
import AuthenticationServices
import UIKit
import CryptoKit

public func generate_nonce(length: Int = 32) -> String {
    precondition(length > 0)
    let charset: [Character] =
        Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
    var result = ""
    var remainingLength = length

    while remainingLength > 0 {
        let randoms: [UInt8] = (0..<16).map { _ in
            var random: UInt8 = 0
            let error = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if error != errSecSuccess { fatalError("Unable to generate nonce. SecRandomCopyBytes failed.") }
            return random
        }

        randoms.forEach { random in
            if remainingLength == 0 { return }
            if random < charset.count {
                result.append(charset[Int(random)])
                remainingLength -= 1
            }
        }
    }

    return result
}

enum AuthError: Error {
    case invalidCredential
    case firestoreWriteFailed
    case missingDisplayName
}


//public protocol AuthLogic: Actor {
//    var currentUser: User? { get }
//    var signedIn: Bool { get }
//    func signIn_withApple() async throws -> User
//    func create_firestore_user(user: User, gender: String?, extraFields: [String:Any]) async throws
//}

public actor SharedAuthService {
    public static let shared = SharedAuthService()

    private let db = Firestore.firestore()
    public var currentUser: User? = nil
    public var signedIn: Bool = false

    public func signIn_and_create_firestore_user_if_necessary(
        using sign_in_func: @escaping () async throws -> User,
        gender: String = "",
        extraFields: [String: Any] = [:]
      //init_level: String = ""
    ) async throws -> User {
        let user = try await sign_in_func()

        let doc_ref = Firestore.firestore().collection("registeredMembers").document(user.uid)
        let snapshot = try await doc_ref.getDocument()
        
        print("user.uid:", user.uid)
        print("checking path:", doc_ref.path)
        print("exists:", snapshot.exists)


        if !snapshot.exists {
            do{try await create_firestore_user(
                user: user,
                //                display_name: display_name,
                gender: gender,
                extraFields: extraFields
            )}catch{print("❌ Failed to create Firestore user: \(error.localizedDescription)");throw error}
        }

        return user
    }
    
    private func get_apple_id_credential() async throws -> ASAuthorizationAppleIDCredential {
        return try await withCheckedThrowingContinuation { continuation in
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            let delegate = AppleSignInDelegate(continuation: continuation)
            controller.delegate = delegate
            controller.presentationContextProvider = delegate
            controller.performRequests()
        }
    }


    public func signIn_withApple(appleAuth: ASAuthorization, nonce: String) async throws -> User {
        guard let credential = appleAuth.credential as? ASAuthorizationAppleIDCredential else {
            throw AuthError.invalidCredential
        }

        guard let id_token_data = credential.identityToken,
              let id_token_string = String(data: id_token_data, encoding: .utf8) else {
            throw AuthError.invalidCredential
        }

        let firebaseCredential = OAuthProvider.credential(
            withProviderID: "apple.com",
            idToken: id_token_string,
            rawNonce: nonce
        )

        let authResult = try await Auth.auth().signIn(with: firebaseCredential)
        let user = authResult.user
        self.currentUser = user
        self.signedIn = true

        return user
    }

    public func create_firestore_user(
        user: User,
        gender: String? = nil,
        extraFields: [String: Any] = [:]
    ) async throws {
        let doc_ref = db.collection("registeredMembers").document(user.uid)
        var data: [String: Any] = [
            "uid": user.uid,
            "email": user.email ?? "",
            "createdAt": user.metadata.creationDate ?? Date()
        ]

        if let name = user.displayName {
            data["displayName"] = name
        } 

        if let g = gender {
            data["gender"] = g  // assuming Gender is RawRepresentable (e.g. String)
        }

        for (k, v) in extraFields {
               data[k] = v
           }
        
        try await Firestore.firestore()
            .collection("registeredMembers")
            .document(user.uid)
            .setData(data, merge: false)
    }
    
}

final class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>

    init(continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) {
        self.continuation = continuation
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Most reliable key window on modern iOS:
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            continuation.resume(returning: credential)
        } else {
            continuation.resume(throwing: AuthError.invalidCredential)
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        continuation.resume(throwing: error)
    }
}

public func sha256(_ input: String) -> String {
    let inputData = Data(input.utf8)
    let hashed = SHA256.hash(data: inputData)
    return hashed.compactMap { String(format: "%02x", $0) }.joined()
}
