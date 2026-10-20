import OttoTools

/// Keeps the original schema, scopes and approval policy while resolving the run's resources.
public struct ContextualTool<T: OttoTool>: OttoTool {
  public typealias Input = T.Input
  public typealias Output = T.Output
  public static var definition: ToolDefinition { T.definition }
  private let resolve: @Sendable (ToolContext) async throws -> T
  public init(_ resolve: @escaping @Sendable (ToolContext) async throws -> T) {
    self.resolve = resolve
  }
  public func call(_ input: Input, context: ToolContext) async throws -> Output {
    try await resolve(context).call(input, context: context)
  }
}
