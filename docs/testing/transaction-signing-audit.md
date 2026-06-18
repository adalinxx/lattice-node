# Transaction signing audit

Transaction signatures are locked to a deterministic record envelope. Every production transaction signature must sign the `lattice-tx-v1` preimage, not a bare transaction body CID.

The preimage is UTF-8 text with length-prefixed variable fields:

```text
domain:13:lattice-tx-v1
chainPath.count:<component-count>
chainPath.component:<utf8-byte-count>:<component>
nonce:<account-nonce>
bodyCID:<utf8-byte-count>:<transaction-body-cid>
```

For multiple path components, repeat `chainPath.component` in order. This binds the signature to the transaction body, the chain path, and the per-account nonce.

Production signing is centralized in Lattice's `Sources/Lattice/Transaction/TransactionSigning.swift`. `TransactionSigningVectorTests.testProductionTransactionSigningIsCentralizedInEnvelopeHelper` scans `Sources/LatticeNode` and fails if node production code calls `CryptoUtils.sign(` directly instead of the shared envelope helper.

Known-answer vectors live in `docs/testing/transaction-signing-vectors.json` and are replayed by `TransactionSigningVectorTests`. The vector locks address derivation, body CID derivation, chain-path/nonce envelope construction, and a sample signature accepted by the verifier. Swift Crypto's platform signing path may emit different valid Ed25519 signatures for the same key and preimage, so the test verifies newly produced signatures instead of requiring byte-for-byte signature reuse.

The suite also proves:

- the vector signature verifies under its original `chainPath`;
- the same signature is rejected under a different `chainPath`;
- the same signature is rejected under a different nonce;
- the same signature is rejected when verified against the legacy raw body CID message.
