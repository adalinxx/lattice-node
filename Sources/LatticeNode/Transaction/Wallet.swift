import Lattice
import Foundation
import Crypto
import cashew
import Multikey

public struct Wallet: Sendable {
    public let privateKeyHex: String
    public let publicKeyHex: String
    public let address: String

    public init(privateKeyHex: String, publicKeyHex: String) {
        self.privateKeyHex = privateKeyHex
        self.publicKeyHex = publicKeyHex
        self.address = CryptoUtils.createAddress(from: publicKeyHex)
    }

    public static func create() -> Wallet {
        let keys = CryptoUtils.generateKeyPair()
        return Wallet(privateKeyHex: keys.privateKey, publicKeyHex: keys.publicKey)
    }

    public static func fromPrivateKey(_ hex: String) -> Wallet? {
        guard let data = Data(hex: hex),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            return nil
        }
        // Encode as Multikey (varint(0xed) + rawPubKey) to match generateKeyPair()
        let mk = Multikey(keyType: .ed25519, keyBytes: key.publicKey.rawRepresentation)
        return Wallet(privateKeyHex: hex, publicKeyHex: mk.hexEncoded)
    }

    public func sign(body: TransactionBody, bodyCID: String? = nil) -> String? {
        TransactionSigning.sign(body: body, bodyCID: bodyCID, privateKeyHex: privateKeyHex)
    }

    public func buildTransfer(
        to recipient: String,
        amount: UInt64,
        fee: UInt64 = 0,
        nonce: UInt64 = 0,
        chainPath: [String] = []
    ) -> Transaction? {
        let (total, overflow) = amount.addingReportingOverflow(fee)
        guard !overflow, total <= UInt64(Int64.max), amount <= UInt64(Int64.max) else { return nil }
        let senderAction = AccountAction(
            owner: address,
            delta: -Int64(total)
        )
        let recipientAction = AccountAction(
            owner: recipient,
            delta: Int64(amount)
        )

        let body = TransactionBody(
            accountActions: [senderAction, recipientAction],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [address],
            fee: fee,
            nonce: nonce,
            chainPath: chainPath
        )

        // known-valid local node; CID cannot fail
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
        guard let signature = sign(body: body, bodyCID: bodyHeader.rawCID) else { return nil }

        return Transaction(
            signatures: [publicKeyHex: signature],
            body: bodyHeader
        )
    }

    public func buildActionTransaction(
        actions: [Action],
        fee: UInt64 = 0,
        nonce: UInt64 = 0,
        chainPath: [String] = []
    ) -> Transaction? {
        guard fee <= UInt64(Int64.max) else { return nil }
        var accountActions: [AccountAction] = []
        if fee > 0 {
            accountActions.append(AccountAction(
                owner: address,
                delta: -Int64(fee)
            ))
        }

        let body = TransactionBody(
            accountActions: accountActions,
            actions: actions,
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [address],
            fee: fee,
            nonce: nonce,
            chainPath: chainPath
        )

        let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
        guard let signature = sign(body: body, bodyCID: bodyHeader.rawCID) else { return nil }

        return Transaction(
            signatures: [publicKeyHex: signature],
            body: bodyHeader
        )
    }
}
