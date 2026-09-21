import GRPCCore

enum MediaLoadFailureDisposition: Equatable {
    case retryable
    case permanentlyUnavailable
}

enum MediaLoadFailurePolicy {
    /// A missing object cannot recover by retrying from the same message descriptor. Transport
    /// failures may recover, so only those keep the retry affordance.
    static func disposition(forRPCCode code: RPCError.Code?) -> MediaLoadFailureDisposition {
        code == .notFound ? .permanentlyUnavailable : .retryable
    }

    static func disposition(for error: Error) -> MediaLoadFailureDisposition {
        disposition(forRPCCode: (error as? RPCError)?.code)
    }
}
