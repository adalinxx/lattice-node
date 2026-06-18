import XCTest
@testable import Lattice
import WAT

final class WasmPolicySanitizerTests: XCTestCase {
    func testTRE118RejectsAllocatorPointerPastMemoryBeforeHostCopy() throws {
        let wat = """
        (module
          (memory (export "memory") 1)
          (func (export "lattice_alloc") (param $len i32) (result i32)
            i32.const 70000)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)

        XCTAssertThrowsError(try WasmPolicyEvaluator.evaluate(
            policy: policy,
            contextData: Data(#"{"fee":100}"#.utf8),
            moduleBytes: Data(try wat2wasm(wat))
        )) { error in
            guard case WasmPolicyError.invalidAllocation = error else {
                XCTFail("expected invalidAllocation before copying host context into guest memory, got \(error)")
                return
            }
        }
    }

    func testTRE118RejectsOversizedContextBeforeAllocatorCall() throws {
        let wat = """
        (module
          (memory (export "memory") 1)
          (func (export "lattice_alloc") (param $len i32) (result i32)
            unreachable)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        let oversizedContext = Data(repeating: 0, count: WasmPolicyEvaluator.maxMemoryBytes + 1)

        XCTAssertThrowsError(try WasmPolicyEvaluator.evaluate(
            policy: policy,
            contextData: oversizedContext,
            moduleBytes: Data(try wat2wasm(wat))
        )) { error in
            guard case WasmPolicyError.invalidAllocation = error else {
                XCTFail("expected oversized context to fail before allocator call, got \(error)")
                return
            }
        }
    }
}
