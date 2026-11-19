import KernelCore
import LumiFactory
import XCTest
@testable import Lode

/// 内核装配测试基类：数据根经 `LODE_UI_TEST_DATA_ROOT` 隔离到临时目录
/// （DEBUG 生效），不触碰用户真实数据。
@MainActor
class LodeKernelTestCase: XCTestCase {
    private var dataRoot: URL!

    override func setUp() async throws {
        dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LodeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        setenv("LODE_UI_TEST_DATA_ROOT", dataRoot.path, 1)
    }

    override func tearDown() async throws {
        unsetenv("LODE_UI_TEST_DATA_ROOT")
        try? FileManager.default.removeItem(at: dataRoot)
        dataRoot = nil
    }

    /// 共享装配引擎解释 Lode 清单后的真实内核。
    func makeKernel() async throws -> KernelCoreContainer {
        try await KernelAssembler.makeKernel(manifest: LodeHostManifest.make())
    }
}