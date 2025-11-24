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

public enum AuthError: Error {
    case invalidCredential
    case firestoreWriteFailed
    case missingDisplayName
    case verificationTimeout
    case noAuthenticatedUser
    case deletionFailedError
}

public enum FSError:Error{
    case dataNotFoundError
    case dataNotSetError
    case deletionFailedError
}


public actor SharedAuthService {
    public static let shared = SharedAuthService()

    private let db = Firestore.firestore()
    public var currentUser: User? = nil
    public var signedIn: Bool = false
   
        public func delete_firestore_auth_accounts(credential: AuthCredential?) async throws {
              guard let user = Auth.auth().currentUser else {
                  throw NSError(domain: "auth", code: 0, userInfo: [NSLocalizedDescriptionKey: "No signed-in user"])
              }

              // Reauthenticate if a credential is provided
              if let cred = credential {
                  do{
                      _ = try await user.reauthenticate(with: cred)}catch{
                          throw AuthError.invalidCredential
                      }
              }

              // 1) Delete Firestore doc
            do{try await Firestore.firestore()
                    .collection("registeredUsers")
                    .document(user.uid)
                    .delete()
            }catch{
                throw FSError.deletionFailedError
            }

              // 2) Delete Auth account
            do{
                try await user.delete()}catch{
                    throw AuthError.deletionFailedError
                }
          }
    
    
    public func create_auth_account_withVerification(displayName:String, email: String, password: String, gender:String="", initLevel:String="", confirmEmail:Bool=true) async throws-> User {
        do{let authResult=try await Auth.auth().createUser(withEmail: email, password: password)
            let user=authResult.user
            if(confirmEmail){
                
                try await user.sendEmailVerification()
                          let tries = 150 // ~5 min @ 2s
                          for _ in 0..<tries {
                              try await Task.sleep(nanoseconds: 2_000_000_000)
                              try await user.reload()
                              try Task.checkCancellation()
                              if user.isEmailVerified { break }
                          }
                          guard user.isEmailVerified else { throw AuthError.verificationTimeout }
            }
            self.currentUser=authResult.user
            self.currentUser!.displayName=displayName
            
            print("email verified")
            self.signedIn=true
            return user
        }catch{
                print("account creation failed")
                print(error.localizedDescription)
                
            throw AuthError.noAuthenticatedUser
            }
        
    }
   
    
    public func register_with_email_password(displayName: String, email: String, password: String) async throws -> User {
        let user = try await signIn_and_create_firestore_user_if_necessary(using: {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            return result.user
        })
        try await db.collection("registeredMembers")
            .document(user.uid)
            .setData(["displayName": displayName], merge: true)
        return user
    }

    
    public func signIn_and_create_firestore_user_if_necessary(
        using sign_in_func: @escaping () async throws -> User,
        gender: String = "",
        extraFields: [String: Any] = [:]
      //init_level: String = ""
    ) async throws -> User {
        let user = try await sign_in_func()

        let doc_ref = db.collection("registeredMembers").document(user.uid)
        let snapshot = try await doc_ref.getDocument()
        
        print("user.uid:", user.uid)
        print("checking path:", doc_ref.path)
        print("exists:", snapshot.exists)


        if !snapshot.exists {
            do{try await create_firestore_member_fromAuthUser(
                authUser: user,
                //                display_name: display_name,
                gender: gender,
                extraFields: extraFields
            )}catch{print("❌ Failed to create Firestore user: \(error.localizedDescription)");throw error}
        }
        self.currentUser=user
        self.signedIn=true
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


    // 1) New “real” implementation with the extra info
    public func signIn_withApple_and_isNew(
        appleAuth: ASAuthorization,
        nonce: String
    ) async throws -> (user: User, isNew: Bool) {
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
        let isNew = authResult.additionalUserInfo?.isNewUser ?? false

        self.currentUser = user
        self.signedIn = true

        return (user, isNew)
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

    public func create_firestore_member_fromAuthUser(
        authUser: User,
        gender: String? = nil,
        extraFields: [String: Any] = [:]
    ) async throws {
        let doc_ref = db.collection("registeredMembers").document(authUser.uid)
        var finalEmail:String=""
        if let emailUW=authUser.email{
            if(!emailUW.contains("@privaterelay.appleid.com")){
                finalEmail=emailUW
            }
        }
        var data: [String: Any] = [
            "uid": authUser.uid,
            "email": finalEmail,
            "createdAt": authUser.metadata.creationDate ?? Date()
        ]

        if let name = authUser.displayName {
            data["displayName"] = name
        } 

        if let g = gender {
            data["gender"] = g  // assuming Gender is RawRepresentable (e.g. String)
        }

        for (k, v) in extraFields {
               data[k] = v
           }
        
        do{try await Firestore.firestore()
                .collection("registeredMembers")
                .document(authUser.uid)
            .setData(data, merge: false)}catch{
                print(error)
                throw error
            }
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
