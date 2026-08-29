import ZetaCore

struct SQLiteUsageStatsDelta {
    var cachedTokens: Double
    var uncachedTokens: Double
    var totalTokens: Double
    var costTotal: Double
}

func sqliteUsageStatsDelta(_ payload: JSONValue) throws -> SQLiteUsageStatsDelta {
    guard case .object(let record) = payload,
        case .object(let usage)? = record["usage"],
        case .number(let input)? = usage["input"],
        case .number? = usage["output"],
        case .number(let cacheRead)? = usage["cacheRead"],
        case .number(let cacheWrite)? = usage["cacheWrite"],
        case .number(let totalTokens)? = usage["totalTokens"],
        case .object(let cost)? = usage["cost"],
        case .number(let costInput)? = cost["input"],
        case .number(let costOutput)? = cost["output"],
        case .number(let costCacheRead)? = cost["cacheRead"],
        case .number(let costCacheWrite)? = cost["cacheWrite"]
    else {
        throw SQLiteRepositoryError.execute("Invalid usage record payload")
    }
    let costTotal: Double
    if case .number(let value)? = cost["total"] {
        costTotal = value.doubleValue
    } else {
        costTotal =
            costInput.doubleValue + costOutput.doubleValue
            + costCacheRead.doubleValue + costCacheWrite.doubleValue
    }
    return SQLiteUsageStatsDelta(
        cachedTokens: cacheRead.doubleValue,
        uncachedTokens: input.doubleValue + cacheWrite.doubleValue,
        totalTokens: totalTokens.doubleValue,
        costTotal: costTotal
    )
}
