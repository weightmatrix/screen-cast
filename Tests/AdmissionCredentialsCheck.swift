import Foundation
@main enum AdmissionCredentialsCheck {
    static func main() {
        precondition(!AdmissionCredentials.validPassword("short"))
        precondition(AdmissionCredentials.validPassword("Fixture-only-71"))
        precondition(AdmissionCredentials.application("  ") == nil)
        precondition(AdmissionCredentials.application(String(repeating: "字", count: 201)) == nil)
        precondition(AdmissionCredentials.application("  合成申请\n用于测试  ") == "合成申请\n用于测试")
        precondition(AdmissionCredentials.invitation("https://example.test/#invite=61328407") == "61328407")
        let verifier = AdmissionCredentials.verifier(password: "Fixture-only-71", invitation: "61328407")
        let proof = AdmissionCredentials.proof(verifier: verifier, nonce: String(repeating: "a", count: 32))
        precondition(proof.count == 64)
        precondition(AdmissionCredentials.equalProof(proof, proof))
        precondition(!AdmissionCredentials.equalProof(proof, String(repeating: "0", count: 64)))
        precondition(AdmissionCredentials.verifier(password: "cafe\u{301}-123", invitation: "61328407") == AdmissionCredentials.verifier(password: "café-123", invitation: "61328407"))
        print("PASS admission password/application bounds, invitation parsing, Unicode normalization and challenge proof")
        precondition(proof == "df54b431b72fa4c33487e7f46901e0ab0147b2c406780fb963bf36c5668f99d7")
    }
}
