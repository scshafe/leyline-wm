// Leyline resident, local command client and isolated developer checks.
import Foundation
import LeylineModel

let arguments = CommandLine.arguments.dropFirst()

switch arguments.first {
case "version":
    print("leylined \(ResidentVersion.current)")
case let operation? where residentClientOperations.contains(operation):
    exit(runResidentCommandClient(operation, Array(arguments.dropFirst())))
case let operation? where residentInstallationOperations.contains(operation):
    exit(runResidentInstallation(Array(arguments)))
case "core":
    selfDisclaimReexecIfNeeded()
    exit(runCore(Array(arguments.dropFirst())))
#if LEYLINE_BUILD_TESTS
case "nav-explain":
    exit(runNavExplain(Array(arguments.dropFirst())))
case "model":
    switch arguments.dropFirst().first {
    case "fn":
        exit(runModelFn(Array(arguments.dropFirst(2))))
    case "adopt":
        exit(runModelAdopt(Array(arguments.dropFirst(2))))
    default:
        FileHandle.standardError.write(Data("usage: leylined model (fn|adopt) --fixture FILE\n".utf8))
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
    case "timeline":
        exit(runTimelineSelfTest())
    case "socket":
        exit(runSocketSelfTest())
    case "projection":
        let options = Array(rest.dropFirst())
        if options.isEmpty { exit(runProjectionSelfTest()) }
        guard options.count == 2, options[0] == "--render-samples" else {
            FileHandle.standardError.write(Data("usage: leylined self-test projection [--render-samples DIRECTORY]\n".utf8))
            exit(64)
        }
        exit(runProjectionSelfTest(sampleDirectory: options[1]))
    case "feed":
        exit(runFeedSelfTest())
    case "responsiveness":
        exit(runResponsivenessSelfTest(Array(rest.dropFirst())))
    case "resident-commands":
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
    case "presentation":
        exit(runPresentationSelfTest())
    case "input":
        exit(runResidentInputSelfTest(Array(rest.dropFirst())))
    case "claims":
        exit(runResidentClaimsSelfTest())
    case "input-stop-barrier":
        exit(runInputStopBarrierSelfTest())
    case "shell":
        exit(runResidentShellSelfTest(Array(rest.dropFirst())))
    case let unknown:
        FileHandle.standardError.write(Data("leylined: unknown self-test suite '\(unknown ?? "")'\n".utf8))
        exit(64)
    }
#endif
case nil:
    exit(runResidentInstallation(["install", "--start"]))
case let .some(unknown):
    FileHandle.standardError.write(Data("leylined: unknown subcommand '\(unknown)'\n".utf8))
    exit(64)
}
