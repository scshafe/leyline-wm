// Finder-double-clickable recovery for the sole leylined resident.
// Direct launchctl remains usable when its socket, input tap, or runtime is wedged.
// This app requests no Accessibility or Input Monitoring grant.
import AppKit
import Foundation
import Darwin

enum RecoveryAction { case bounce, disable, enable }
struct RecoveryResult {
    let dispatch: String
    let rc: Int32
    let detail: String
    let targetLabel: String
}
func runSync(_ executable: String, _ arguments: [String]) -> Int32 {
    let process=Process(); process.executableURL=URL(fileURLWithPath: executable)
    process.arguments=arguments; process.standardInput=FileHandle.nullDevice
    process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
    do { try process.run() } catch { return -1 }
    let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(20_000) }
    if process.isRunning {
        process.terminate()
        let grace = DispatchTime.now().uptimeNanoseconds + 250_000_000
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < grace { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit(); return -1
    }
    process.waitUntilExit(); return process.terminationStatus
}
enum RecoveryResident {
    static let coreLabel="org.leyline.leylined"
    typealias Executor=(String,[String])->Int32
    static func recover(_ action: RecoveryAction, plan: Bool,
                        home: String=NSHomeDirectory(), execute: Executor={ runSync($0,$1) },
                        pause: ()->Void={ usleep(50_000) }) -> RecoveryResult {
        let service="gui/\(getuid())/\(coreLabel)"
        let command: [String] = action == .bounce ? ["kickstart","-k",service]
            : action == .disable ? ["bootout",service]
            : ["bootstrap","gui/\(getuid())",home+"/Library/LaunchAgents/"+coreLabel+".plist"]
        func result(_ rc: Int32,_ detail: String)->RecoveryResult {
            RecoveryResult(dispatch:"launchctl",rc:rc,detail:detail,targetLabel:coreLabel)
        }
        if plan { return result(0,"PLAN direct launchctl "+command.joined(separator:" ")) }
        let rc: Int32
        if action == .enable, execute("/bin/launchctl",["print",service]) == 0 { rc=0 }
        else { rc=execute("/bin/launchctl",command) }
        if action == .disable {
            var down=verifyDown(service,execute:execute,pause:pause)
            if !down { _=execute("/bin/launchctl",command);down=verifyDown(service,execute:execute,pause:pause) }
            return result(down ? 0 : 3,down ? "core de-registered (verified down); re-enable from Finder recovery"
                : "core still registered after bootout; launchctl bootout "+service)
        }
        return result(rc,rc == 0 ? "launchctl accepted "+command.joined(separator:" ")
            : "launchctl failed (rc=\(rc)): "+command.joined(separator:" "))
    }
    static func verifyDown(_ service: String,execute: Executor,pause: ()->Void)->Bool {
        for _ in 0..<40 {
            let rc=execute("/bin/launchctl",["print",service])
            if rc == 113 { return true }
            if rc != 0 { return false }
            pause()
        }
        return false
    }
    #if LEYLINE_BUILD_TESTS
    static func selfTest()->Int32 {
        var checks:[Bool]=[]
        func check(_ passed:Bool,_ name:String) { checks.append(passed);print("\(passed ? "ok" : "not ok") recovery/\(name)") }
        var calls:[[String]]=[]
        let bounce=recover(.bounce,plan:false,execute:{ exe,args in calls.append([exe]+args);return 0 },pause:{})
        check(bounce.rc == 0 && calls == [["/bin/launchctl","kickstart","-k","gui/\(getuid())/\(coreLabel)"]],"bounce-direct-permanent-resident")
        calls=[]
        let disable=recover(.disable,plan:false,execute:{ exe,args in calls.append([exe]+args);return args.first == "print" ? 113 : 0 },pause:{})
        check(disable.rc == 0 && calls.count == 2 && calls[0].contains("bootout"),"disable-verifies-deregistration")
        check(recover(.disable,plan:false,execute:{ _,_ in 0 },pause:{}).rc == 3,"registered-after-bootout-fails")
        check(recover(.disable,plan:false,execute:{ _,_ in -1 },pause:{}).rc == 3,"spawn-failure-does-not-mean-down")
        check(recover(.disable,plan:false,execute:{ _,_ in 5 },pause:{}).rc == 3,"domain-failure-does-not-mean-down")
        calls=[]
        let enabled=recover(.enable,plan:false,home:"/private/test",execute:{ exe,args in calls.append([exe]+args);return args.first == "print" ? 113 : 0 },pause:{})
        check(enabled.rc == 0 && calls.last == ["/bin/launchctl","bootstrap","gui/\(getuid())","/private/test/Library/LaunchAgents/"+coreLabel+".plist"],"enable-bootstraps-canonical-plist")
        calls=[]
        check(recover(.enable,plan:false,execute:{ exe,args in calls.append([exe]+args);return 0 },pause:{}).rc == 0 && calls.count == 1,"enable-already-registered-does-not-bootstrap")
        calls=[]
        check(recover(.disable,plan:true,execute:{ exe,args in calls.append([exe]+args);return 0 },pause:{}).rc == 0 && calls.isEmpty,"plan-does-not-actuate")
        check(recover(.bounce,plan:false,execute:{ _,_ in 7 },pause:{}).rc == 7,"bounce-preserves-launchctl-failure")
        print("recovery self-test: \(checks.filter{$0}.count)/\(checks.count) ok; live commands=0")
        return checks.count == 9 && checks.allSatisfy{$0} ? 0 : 1
    }
    #endif
}
func recover(_ action: RecoveryAction,plan:Bool=false)->RecoveryResult {
    RecoveryResident.recover(action,plan:plan)
}

// ── headless verbs: --bounce / --disable [--plan] → print JSON, exit (no GUI) ──
// --plan is the test-safe variant (resolve + report, actuate nothing).
func headless(_ action: RecoveryAction, plan: Bool) -> Never {
    let r = recover(action, plan: plan)
    let obj: [String: Any] = [
        "action": action == .bounce ? "bounce" : action == .enable ? "enable" : "disable",
        "plan": plan,
        "dispatch": r.dispatch, "rc": Int(r.rc), "detail": r.detail,
        "target_label": r.targetLabel,
    ]
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
       let s = String(data: d, encoding: .utf8) { print(s) }
    exit(r.rc)
}

let cliArgs = CommandLine.arguments
#if LEYLINE_BUILD_TESTS
if cliArgs == [cliArgs[0], "--self-test-core"] { exit(RecoveryResident.selfTest()) }
#endif
let supportedArgs: Set<String> = ["--bounce", "--disable", "--enable", "--plan"]
if cliArgs.dropFirst().contains(where: { !supportedArgs.contains($0) }) {
    FileHandle.standardError.write(Data("Usage: Leyline Recovery [--bounce|--disable|--enable] [--plan]\n".utf8)); exit(64)
}
let planMode = cliArgs.contains("--plan")
if cliArgs.contains("--bounce") { headless(.bounce, plan: planMode) }
if cliArgs.contains("--disable") { headless(.disable, plan: planMode) }
if cliArgs.contains("--enable") { headless(.enable, plan: planMode) }

// On-demand recovery controls take focus and exit when their window closes.
final class RecoveryWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let status: NSTextField

    override init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Leyline Recovery"
        w.center()
        self.window = w
        self.status = NSTextField(wrappingLabelWithString:
            "Leyline wedged? Bounce first. Disable stops respawn; Re-enable restores the parked service.")
        super.init()
        w.delegate = self

        let content = NSView(frame: w.contentRect(forFrameRect: w.frame))
        status.frame = NSRect(x: 20, y: 175, width: 420, height: 44)
        status.isEditable = false
        status.isBordered = false
        status.drawsBackground = false
        content.addSubview(status)

        let bounce = NSButton(title: "Bounce  (transient wedge)", target: self, action: #selector(onBounce))
        bounce.frame = NSRect(x: 20, y: 120, width: 420, height: 36)
        bounce.bezelStyle = .rounded
        bounce.keyEquivalent = "\r"   // default button
        content.addSubview(bounce)

        let disable = NSButton(title: "Disable  (stop respawn — bootout floor)", target: self, action: #selector(onDisable))
        disable.frame = NSRect(x: 20, y: 70, width: 420, height: 36)
        disable.bezelStyle = .rounded
        content.addSubview(disable)

        let enable = NSButton(title: "Re-enable Leyline", target: self, action: #selector(onEnable))
        enable.frame = NSRect(x: 20, y: 20, width: 420, height: 36)
        enable.bezelStyle = .rounded
        content.addSubview(enable)

        w.contentView = content
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }

    @objc func onBounce() {
        status.stringValue = "Bouncing…"
        DispatchQueue.global().async {
            let r = recover(.bounce)
            DispatchQueue.main.async {
                self.status.stringValue = r.rc == 0 ? "Restart requested for \(r.targetLabel)." : "Restart failed: \(r.detail)"
            }
        }
    }
    @objc func onDisable() {
        // The disable FLOOR runs SYNC (verify de-registration) on a background queue — never
        // fire-and-forget with a hardcoded success. The label reflects the REAL outcome so the
        // operator is never told "respawn off" while the keyboard is still locked (audit BLOCKING).
        status.stringValue = "Disabling…"
        DispatchQueue.global().async {
            let r = recover(.disable)
            DispatchQueue.main.async {
                self.status.stringValue = r.rc == 0
                  ? "Disabled — respawn off (de-registered). Use Re-enable Leyline when ready."
                  : "DISABLE FAILED: \(r.detail)"
            }
        }
    }
    @objc func onEnable() {
        status.stringValue = "Re-enabling…"
        DispatchQueue.global().async {
            let r = recover(.enable)
            DispatchQueue.main.async {
                self.status.stringValue = r.rc == 0 ? "Service registered. Check Leyline's menu for readiness." : "Re-enable failed: \(r.detail)"
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)   // a real foreground app: it SHOWS a window + takes focus
let recoveryMenu = NSMenu()
let recoveryMenuItem = NSMenuItem()
let recoveryApplicationMenu = NSMenu()
recoveryApplicationMenu.addItem(withTitle: "Quit Leyline Recovery", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
recoveryMenuItem.submenu = recoveryApplicationMenu
recoveryMenu.addItem(recoveryMenuItem)
app.mainMenu = recoveryMenu
let wc = RecoveryWindowController()
_ = wc
wc.window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
withExtendedLifetime(wc) { app.run() }
