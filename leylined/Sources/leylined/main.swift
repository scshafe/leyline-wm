// Leyline 1.0.0 resident, local command client and isolated developer checks.
import Foundation
import LeylineModel

let arguments = CommandLine.arguments.dropFirst()

switch arguments.first {
case "version":
    print("leylined \(ResidentVersion.current)")
case "--dump-claims":
    exit(runResidentClaimsDump(Array(arguments.dropFirst())))
case "act", "result", "control", "control-result", "hello", "status", "snapshot", "health", "perf", "trace":
    #if LEYLINE_BUILD_TESTS
    if arguments.first == "perf", arguments.dropFirst().first == "--dump" {
        exit(runPerfDump(Array(arguments.dropFirst(2))))
    }
    #endif
    exit(runResidentCommandClient(arguments.first!, Array(arguments.dropFirst())))
case "install", "uninstall", "service-status", "service-start", "service-stop", "service-restart":
    exit(runResidentInstallation(Array(arguments)))
case "core":
    selfDisclaimReexecIfNeeded()
    exit(runCore(Array(arguments.dropFirst())))
#if LEYLINE_BUILD_TESTS
case "nav-explain":
    exit(runNavExplain(Array(arguments.dropFirst())))
case "projection":
    exit(runProjection(Array(arguments.dropFirst())))
case "model":
    switch arguments.dropFirst().first {
    case "store":
        exit(runModelStore(Array(arguments.dropFirst(2))))
    case "targets":
        exit(runModelTargets(Array(arguments.dropFirst(2))))
    case "bridge-targets":
        exit(runModelBridgeTargets(Array(arguments.dropFirst(2))))
    case "fn":
        exit(runModelFn(Array(arguments.dropFirst(2))))
    case "prune":
        exit(runModelPrune(Array(arguments.dropFirst(2))))
    case "adopt":
        exit(runModelAdopt(Array(arguments.dropFirst(2))))
    case "settle":
        exit(runModelSettle(Array(arguments.dropFirst(2))))
    case "storevalid":
        exit(runModelStoreValid(Array(arguments.dropFirst(2))))
    default:
        FileHandle.standardError.write(Data("usage: leylined model (store|targets|bridge-targets|fn) …\n".utf8))
        exit(64)
    }
case "self-test":
    let rest = Array(arguments.dropFirst())
    switch rest.first {
    case "model":
        exit(runModelSelfTest())
    case "decode":
        exit(runDecodeSelfTest(Array(rest.dropFirst())))
    case "fsm":
        exit(runFsmSelfTest(Array(rest.dropFirst())))
    case "perf":
        exit(runPerfSelfTest())
    case "store":
        exit(runStoreSelfTest())
    case "socket":
        exit(runSocketSelfTest())
    case "projection":
        exit(runProjectionSelfTest())
    case "feed":
        exit(runFeedSelfTest())
    case "responsiveness":
        exit(runResponsivenessSelfTest(Array(rest.dropFirst())))
    case "commands", "resident-commands":
        exit(runResidentCommandsSelfTest())
    case "effector":
        exit(runEffectorSelfTest())
    case "startup":
        exit(runStartupSelfTest())
    case "installation":
        exit(runResidentInstallationSelfTest())
    case "maintenance":
        exit(runMaintenanceSelfTest())
    case "space-partitions":
        exit(runSpacePartitionsSelfTest())
    case "resident-client":
        exit(runResidentClientSelfTest(Array(rest.dropFirst())))
    case "resident":
        exit(runResidentSelfTest(Array(rest.dropFirst())))
    case "presentation":
        exit(runPresentationSelfTest())
    case "input":
        exit(runResidentInputSelfTest(Array(rest.dropFirst())))
    case "claims", "resident-claims":
        exit(runResidentClaimsSelfTest())
    case "input-stop-barrier":
        exit(runInputStopBarrierSelfTest())
    case "shell":
        exit(runResidentShellSelfTest(Array(rest.dropFirst())))
    case nil:
        let model = runModelSelfTest()
        let decode = runDecodeSelfTest([])
        let fsm = runFsmSelfTest([])
        let perf = runPerfSelfTest()
        let store = runStoreSelfTest()
        let sock = runSocketSelfTest()
        let proj = runProjectionSelfTest()
        let feed = runFeedSelfTest()
        let responsiveness = runResponsivenessSelfTest([])
        let effector = runEffectorSelfTest()
        let resident = runResidentSelfTest([])
        let commands = runResidentCommandsSelfTest()
        let client = runResidentClientSelfTest([])
        exit(model == 0 && decode == 0 && fsm == 0 && perf == 0 && store == 0
             && sock == 0 && proj == 0 && feed == 0
             && responsiveness == 0 && effector == 0 && resident == 0 && commands == 0 && client == 0 ? 0 : 1)
    case let .some(unknown):
        FileHandle.standardError.write(Data("leylined: unknown self-test suite '\(unknown)'\n".utf8))
        exit(64)
    }
#endif
case nil:
    exit(runResidentInstallation(["install", "--start"]))
case let .some(unknown):
    FileHandle.standardError.write(Data("leylined: unknown subcommand '\(unknown)'\n".utf8))
    exit(64)
}
