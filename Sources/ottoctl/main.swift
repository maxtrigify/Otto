import Foundation
import OttoCLI
import OttoControl
import OttoModels

@main
struct OttoControlCommand {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
      print(OttoCLIRunner.usage)
      return
    }
    let environment = ProcessInfo.processInfo.environment
    guard let socket = OttoEnvironment.value("CONTROL_SOCKET", in: environment),
      let token = OttoEnvironment.value("CONTROL_TOKEN", in: environment)
    else {
      FileHandle.standardError.write(
        Data("Otto is not running or this shell has no scoped control grant.\n".utf8))
      Foundation.exit(2)
    }

    do {
      let runner = OttoCLIRunner(
        client: ControlClient(
          socketPath: socket,
          token: token,
          sourceNodeID: OttoEnvironment.value("NODE_ID", in: environment).flatMap(
            UUID.init(uuidString:)),
          sourceCanvasID: OttoEnvironment.value("CANVAS_ID", in: environment).flatMap(
            UUID.init(uuidString:))
        ))
      let output = try runner.run(arguments: arguments)
      print(output)
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      Foundation.exit(1)
    }
  }
}
