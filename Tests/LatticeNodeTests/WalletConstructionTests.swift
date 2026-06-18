import XCTest
@testable import Lattice
@testable import LatticeNode

final class WalletConstructionTests: XCTestCase {
    func testBuildTransferDebitsAmountPlusFeeAndPreservesNonceSignerAndPath() throws {
        let sender = Wallet.create()
        let recipient = Wallet.create()

        let tx = try XCTUnwrap(sender.buildTransfer(
            to: recipient.address,
            amount: 25,
            fee: 3,
            nonce: 7,
            chainPath: ["Nexus", "Child"]
        ))
        let body = try XCTUnwrap(tx.body.node)

        XCTAssertEqual(body.fee, 3)
        XCTAssertEqual(body.nonce, 7)
        XCTAssertEqual(body.chainPath, ["Nexus", "Child"])
        XCTAssertEqual(body.signers, [sender.address])
        XCTAssertEqual(Set(tx.signatures.keys), Set([sender.publicKeyHex]))
        XCTAssertEqual(body.accountActions.count, 2)
        XCTAssertEqual(body.accountActions[0].owner, sender.address)
        XCTAssertEqual(body.accountActions[0].delta, -28)
        XCTAssertEqual(body.accountActions[1].owner, recipient.address)
        XCTAssertEqual(body.accountActions[1].delta, 25)
        XCTAssertEqual(netAccountDelta(body), -Int64(body.fee))

        let signature = try XCTUnwrap(tx.signatures[sender.publicKeyHex])
        XCTAssertTrue(TransactionSigning.verify(body: body, bodyCID: tx.body.rawCID, signature: signature, publicKeyHex: sender.publicKeyHex))
        XCTAssertFalse(CryptoUtils.verify(message: tx.body.rawCID, signature: signature, publicKeyHex: sender.publicKeyHex))
        XCTAssertTrue(tx.signaturesAreValid())
    }

    func testBuildActionTransactionDebitsOnlyFeeAndPreservesSignerContract() throws {
        let wallet = Wallet.create()
        let action = Action(key: "feature:enabled", oldValue: nil, newValue: "true")

        let tx = try XCTUnwrap(wallet.buildActionTransaction(
            actions: [action],
            fee: 9,
            nonce: 4,
            chainPath: ["Nexus"]
        ))
        let body = try XCTUnwrap(tx.body.node)

        XCTAssertEqual(body.actions.count, 1)
        XCTAssertEqual(body.actions[0].key, action.key)
        XCTAssertEqual(body.actions[0].oldValue, action.oldValue)
        XCTAssertEqual(body.actions[0].newValue, action.newValue)
        XCTAssertEqual(body.fee, 9)
        XCTAssertEqual(body.nonce, 4)
        XCTAssertEqual(body.chainPath, ["Nexus"])
        XCTAssertEqual(body.signers, [wallet.address])
        XCTAssertEqual(Set(tx.signatures.keys), Set([wallet.publicKeyHex]))
        XCTAssertEqual(body.accountActions.count, 1)
        XCTAssertEqual(body.accountActions[0].owner, wallet.address)
        XCTAssertEqual(body.accountActions[0].delta, -9)
        XCTAssertEqual(netAccountDelta(body), -Int64(body.fee))
        XCTAssertTrue(tx.signaturesAreValid())
    }

    func testBuildActionTransactionWithZeroFeeDoesNotCreatePhantomDebit() throws {
        let wallet = Wallet.create()
        let action = Action(key: "feature:enabled", oldValue: "false", newValue: "true")

        let tx = try XCTUnwrap(wallet.buildActionTransaction(
            actions: [action],
            fee: 0,
            nonce: 1,
            chainPath: ["Nexus"]
        ))
        let body = try XCTUnwrap(tx.body.node)

        XCTAssertEqual(body.accountActions.count, 0)
        XCTAssertEqual(body.actions.count, 1)
        XCTAssertEqual(body.actions[0].key, action.key)
        XCTAssertEqual(body.actions[0].oldValue, action.oldValue)
        XCTAssertEqual(body.actions[0].newValue, action.newValue)
        XCTAssertEqual(body.fee, 0)
        XCTAssertEqual(body.nonce, 1)
        XCTAssertEqual(body.signers, [wallet.address])
        XCTAssertEqual(Set(tx.signatures.keys), Set([wallet.publicKeyHex]))
        XCTAssertEqual(netAccountDelta(body), 0)
        XCTAssertTrue(tx.signaturesAreValid())
    }

    func testBuildTransferRejectsLossyOverflowAmounts() {
        let sender = Wallet.create()
        let recipient = Wallet.create()

        XCTAssertNil(sender.buildTransfer(
            to: recipient.address,
            amount: UInt64(Int64.max) + 1,
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
        ))
        XCTAssertNil(sender.buildTransfer(
            to: recipient.address,
            amount: UInt64.max,
            fee: 1,
            nonce: 0,
            chainPath: ["Nexus"]
        ))
    }

    func testBuildActionTransactionRejectsLossyFee() {
        let wallet = Wallet.create()
        let action = Action(key: "feature:enabled", oldValue: nil, newValue: "true")

        XCTAssertNil(wallet.buildActionTransaction(
            actions: [action],
            fee: UInt64(Int64.max) + 1,
            nonce: 0,
            chainPath: ["Nexus"]
        ))
    }

    private func netAccountDelta(_ body: TransactionBody) -> Int64 {
        body.accountActions.reduce(0) { $0 + $1.delta }
    }
}
