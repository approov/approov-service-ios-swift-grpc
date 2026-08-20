// ApproovService for integrating Approov into apps using GRPC.
//
// MIT License
//
// Copyright (c) 2016-present, Critical Blue Ltd.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Approov
import Foundation
import GRPC
import NIO
import os.log

public class ApproovClientInterceptor<Request, Reply>: ClientInterceptor<Request, Reply> {

    // hostname/domain for which to add an Approov token to every GRPC request
    private let hostname: String

    public init(hostname: String) {
        self.hostname = hostname
    }

    public override func send(
        _ part: GRPCClientRequestPart<Request>,
        promise: EventLoopPromise<Void>?,
        context: ClientInterceptorContext<Request, Reply>
    ) {
        switch part {
        // The (user-provided) request headers, these are sent at the start of each RPC.
        case var .metadata(headers):
            do {
                // context.path is the RPC path (e.g. "/package.Service/Method") and is passed through
                // so message signing can include the @path / @target-uri derived components.
                headers = try ApproovService.updateRequestHeaders(headers: headers, hostname: hostname, path: context.path)
                // Forward the request part to the next interceptor.
                context.send(.metadata(headers), promise: promise)
            } catch {
                // Log at error first: grpc-swift's own invocation path passes `promise: nil`
                // (GRPC Call.swift `_send(.metadata(...), promise: nil)`), so `promise?.fail` is a
                // no-op there and the application sees only a cancelled RPC with this error - and
                // its rejection ARC - discarded. The log is the only place the cause survives.
                if ApproovService.loggingLevel >= .error {
                    os_log("ApproovService: request rejected before send for %@: %@", type: .error,
                           hostname, error.localizedDescription)
                }
                // Fail the send promise so a caller that did supply one observes the error...
                promise?.fail(error)
                // ...then cancel the RPC so the network request does not proceed. Pass a fresh
                // (nil) promise to cancel: reusing the already-failed `promise` would complete the
                // same EventLoopPromise twice, which traps in SwiftNIO and crashes the client.
                context.cancel(promise: nil)
            }

        // The request message and metadata (ignored here). For unary and server-streaming RPCs we
        // expect exactly one message, for client-streaming and bidirectional streaming RPCs any number
        // of messages is permitted.
        case .message:
            // Forward the request part to the next interceptor.
            context.send(part, promise: promise)

        // The end of the request stream: must be sent exactly once, after which no more messages may
        // be sent.
        case .end:
            // Forward the request part to the next interceptor.
            context.send(part, promise: promise)
        }
    }

}
