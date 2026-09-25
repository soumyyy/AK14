extension Array where Element: Sendable {
    /// Maps with at most `limit` concurrent tasks and returns results in input order.
    public func concurrentMap<T: Sendable>(
        limit: Int, _ transform: @escaping @Sendable (Element) async throws -> T
    ) async throws -> [T] {
        precondition(limit > 0)
        return try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var results = [T?](repeating: nil, count: count)
            var next = 0
            while next < Swift.min(limit, count) {
                let i = next, element = self[i]
                group.addTask { (i, try await transform(element)) }
                next += 1
            }
            while let (i, value) = try await group.next() {
                results[i] = value
                if next < count {
                    let j = next, element = self[j]
                    group.addTask { (j, try await transform(element)) }
                    next += 1
                }
            }
            return results.map { $0! }
        }
    }
}

extension Duration {
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
